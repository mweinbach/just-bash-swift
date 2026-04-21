import Foundation
import JustBashFS
import SQLite3

func sqlite3() -> AnyBashCommand {
    AnyBashCommand(name: "sqlite3") { args, ctx in
        var jsonMode = false
        var remaining: [String] = []

        for arg in args {
            switch arg {
            case "--help", "-help":
                return ExecResult.success("""
                sqlite3 DATABASE [SQL]
                  -json       output query results as JSON
                  -help       show help
                """)
            case "-json":
                jsonMode = true
            case let option where option.hasPrefix("-"):
                return ExecResult.failure("sqlite3: Error: unknown option: \(option)\nUse -help for a list of options.")
            default:
                remaining.append(arg)
            }
        }

        guard let databaseArg = remaining.first else {
            return ExecResult.failure("sqlite3: missing database argument")
        }

        let sqlText = remaining.dropFirst().isEmpty ? ctx.stdin : remaining.dropFirst().joined(separator: " ")
        let useMemory = databaseArg == ":memory:"
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("just-bash-swift-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        if !useMemory, ctx.fileSystem.fileExists(path: databaseArg, relativeTo: ctx.cwd) {
            do {
                let stored = try ctx.fileSystem.readFile(path: databaseArg, relativeTo: ctx.cwd)
                try stored.write(to: tempURL)
            } catch {
                return ExecResult.failure("sqlite3: \(error.localizedDescription)")
            }
        }

        let path = useMemory ? ":memory:" : tempURL.path
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK, let db else {
            return ExecResult.failure("sqlite3: failed to open database")
        }
        defer { sqlite3_close(db) }

        if sqlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if !useMemory {
                do {
                    let data = (try? Data(contentsOf: tempURL)) ?? Data()
                    try ctx.fileSystem.writeFile(path: databaseArg, content: data, relativeTo: ctx.cwd)
                } catch {
                    return ExecResult.failure("sqlite3: \(error.localizedDescription)")
                }
            }
            return ExecResult.success()
        }

        do {
            let result = try runSQLiteStatements(db: db, sql: sqlText, jsonMode: jsonMode)
            if !useMemory {
                let data = (try? Data(contentsOf: tempURL)) ?? Data()
                try ctx.fileSystem.writeFile(path: databaseArg, content: data, relativeTo: ctx.cwd)
            }
            return result
        } catch {
            return ExecResult(stdout: "Error: \(error.localizedDescription)\n", stderr: "", exitCode: 0)
        }
    }
}

private func runSQLiteStatements(db: OpaquePointer, sql: String, jsonMode: Bool) throws -> ExecResult {
    var remaining = sql
    var textLines: [String] = []
    var jsonRows: [[(String, Any)]] = []

    while !remaining.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        var statement: OpaquePointer?
        var nextSQL = ""
        let prepareCode = remaining.withCString { cString -> Int32 in
            var tail: UnsafePointer<Int8>?
            let code = sqlite3_prepare_v2(db, cString, -1, &statement, &tail)
            if let tail {
                nextSQL = String(cString: tail)
            }
            return code
        }

        guard prepareCode == SQLITE_OK else {
            throw NSError(domain: "sqlite3", code: Int(prepareCode), userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }

        guard let statement else {
            remaining = nextSQL
            continue
        }
        defer { sqlite3_finalize(statement) }

        let columnCount = Int(sqlite3_column_count(statement))
        while true {
            let stepCode = sqlite3_step(statement)
            if stepCode == SQLITE_ROW {
                if jsonMode {
                    var row: [(String, Any)] = []
                    for index in 0..<columnCount {
                        let name = String(cString: sqlite3_column_name(statement, Int32(index)))
                        row.append((name, sqliteColumnValue(statement, index: index)))
                    }
                    jsonRows.append(row)
                } else {
                    let columns = (0..<columnCount).map { index -> String in
                        let value = sqliteColumnValue(statement, index: index)
                        if value is NSNull { return "" }
                        return String(describing: value)
                    }
                    textLines.append(columns.joined(separator: "|"))
                }
            } else if stepCode == SQLITE_DONE {
                break
            } else {
                throw NSError(domain: "sqlite3", code: Int(stepCode), userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
            }
        }

        remaining = nextSQL
    }

    if jsonMode {
        let renderedRows = jsonRows.map { row in
            "{" + row.map { key, value in
                "\"\(escapeJSONString(key))\":" + renderSQLiteJSONValue(value)
            }.joined(separator: ",") + "}"
        }
        return ExecResult.success("[" + renderedRows.joined(separator: ",") + "]\n")
    }

    return ExecResult.success(textLines.joined(separator: "\n") + (textLines.isEmpty ? "" : "\n"))
}

private func sqliteColumnValue(_ statement: OpaquePointer, index: Int) -> Any {
    switch sqlite3_column_type(statement, Int32(index)) {
    case SQLITE_INTEGER:
        return Int(sqlite3_column_int64(statement, Int32(index)))
    case SQLITE_FLOAT:
        return sqlite3_column_double(statement, Int32(index))
    case SQLITE_NULL:
        return NSNull()
    default:
        guard let value = sqlite3_column_text(statement, Int32(index)) else { return "" }
        return String(cString: value)
    }
}

private func renderSQLiteJSONValue(_ value: Any) -> String {
    if value is NSNull { return "null" }
    if let string = value as? String {
        return "\"\(escapeJSONString(string))\""
    }
    if let number = value as? Double {
        return String(number)
    }
    if let number = value as? Int {
        return String(number)
    }
    return "\"\(escapeJSONString(String(describing: value)))\""
}
