import Foundation

func yq() -> AnyBashCommand {
    AnyBashCommand(name: "yq") { args, ctx in
        var rawOutput = false
        var compact = false
        var outputJSON = false
        var outputCSV = false
        var outputINI = false
        var outputTOML = false
        var outputXML = false
        var parseJSON = false
        var parseCSV = false
        var parseINI = false
        var parseTOML = false
        var explicitInputFormat = false
        var nullInput = false
        var slurp = false
        var joinOutput = false
        var exitStatusMode = false
        var indent = 2
        var csvDelimiter = ","
        var filter: String?
        var files: [String] = []
        var index = 0

        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--help":
                return ExecResult.success("yq FILTER [FILE]\n  -o json   output JSON\n  -o csv    output CSV\n  -o ini    output INI\n  -o toml   output TOML\n  -o xml    output XML\n  -c        compact JSON output\n  -r        raw string output\n  -p json   parse JSON input\n  -p csv    parse CSV input\n  -p ini    parse INI input\n  -p toml   parse TOML input\n  --csv-delimiter=CHAR\n  -n        null input\n  -s        slurp documents into an array\n  -j        join outputs without separators\n  -e        set exit status from truthiness\n  -I N      JSON indentation width\n")
            case "-c":
                compact = true
            case "-r":
                rawOutput = true
            case "-n":
                nullInput = true
            case "-s":
                slurp = true
            case "-j":
                joinOutput = true
            case "-e":
                exitStatusMode = true
            case "-I":
                index += 1
                if index < args.count {
                    indent = Int(args[index]) ?? indent
                }
            case "-o":
                index += 1
                if index < args.count {
                    switch args[index] {
                    case "json":
                        outputJSON = true
                    case "csv":
                        outputCSV = true
                    case "ini":
                        outputINI = true
                    case "toml":
                        outputTOML = true
                    case "xml":
                        outputXML = true
                    default:
                        break
                    }
                }
            case "-p":
                index += 1
                explicitInputFormat = true
                if index < args.count {
                    switch args[index] {
                    case "json":
                        parseJSON = true
                    case "csv":
                        parseCSV = true
                    case "ini":
                        parseINI = true
                    case "toml":
                        parseTOML = true
                    default:
                        break
                    }
                }
            case let option where option.hasPrefix("--csv-delimiter="):
                csvDelimiter = String(option.dropFirst("--csv-delimiter=".count))
            case let option where option.hasPrefix("-") && option.count > 2:
                let flags = Array(option.dropFirst())
                var handled = true
                for flag in flags {
                    switch flag {
                    case "c":
                        compact = true
                    case "r":
                        rawOutput = true
                    case "n":
                        nullInput = true
                    case "s":
                        slurp = true
                    case "j":
                        joinOutput = true
                    case "e":
                        exitStatusMode = true
                    default:
                        handled = false
                    }
                }
                if !handled {
                    if !arg.hasPrefix("-"), filter == nil {
                        filter = arg
                    } else if !arg.hasPrefix("-") || arg == "-" {
                        files.append(arg)
                    }
                }
            default:
                if !arg.hasPrefix("-"), filter == nil {
                    filter = arg
                } else if !arg.hasPrefix("-") || arg == "-" {
                    files.append(arg)
                }
            }
            index += 1
        }

        let program = filter ?? "."
        let sourceText: String
        do {
            if nullInput {
                sourceText = ""
            } else if files.isEmpty {
                sourceText = ctx.stdin
            } else {
                sourceText = try files.map { file in
                    if file == "-" { return ctx.stdin }
                    return try ctx.fileSystem.readFile(file, relativeTo: ctx.cwd)
                }.joined(separator: "\n")
            }
        } catch {
            return ExecResult.failure("yq: \(error.localizedDescription)")
        }

        do {
            if !explicitInputFormat, let firstFile = files.first, firstFile != "-" {
                let lowercased = firstFile.lowercased()
                if lowercased.hasSuffix(".json") {
                    parseJSON = true
                } else if lowercased.hasSuffix(".csv") {
                    parseCSV = true
                } else if lowercased.hasSuffix(".tsv") {
                    parseCSV = true
                    csvDelimiter = "\\t"
                } else if lowercased.hasSuffix(".ini") {
                    parseINI = true
                } else if lowercased.hasSuffix(".toml") {
                    parseTOML = true
                }
            }

            let inputValue: Any
            if nullInput {
                inputValue = NSNull()
            } else if slurp {
                if parseJSON {
                    inputValue = try parseJQInputValues(sourceText)
                } else if parseCSV {
                    inputValue = [try parseCSVInput(sourceText, delimiter: decodeYQDelimiter(csvDelimiter))]
                } else if parseINI {
                    inputValue = [try parseINIInput(sourceText)]
                } else if parseTOML {
                    inputValue = [try parseTOMLInput(sourceText)]
                } else {
                    inputValue = try parseYAMLDocuments(sourceText)
                }
            } else if parseJSON {
                inputValue = try parseJQInputValues(sourceText).first ?? NSNull()
            } else if parseCSV {
                inputValue = try parseCSVInput(sourceText, delimiter: decodeYQDelimiter(csvDelimiter))
            } else if parseINI {
                inputValue = try parseINIInput(sourceText)
            } else if parseTOML {
                inputValue = try parseTOMLInput(sourceText)
            } else {
                inputValue = try parseSimpleYAML(sourceText)
            }

            let outputs: [Any]
            if yqProgramUsesNavigation(program) {
                outputs = try evaluateYQNavigationFilter(program, input: inputValue)
            } else {
                outputs = try evaluateJQFilter(program, input: inputValue)
            }
            let rendered: String
            if outputJSON {
                let separator = joinOutput ? "" : "\n"
                rendered = outputs.map { renderYQJSONValue($0, compact: compact, raw: rawOutput, indent: indent) }.joined(separator: separator)
            } else if outputCSV {
                let separator = joinOutput ? "" : "\n"
                rendered = outputs.map { renderCSVValue($0, delimiter: decodeYQDelimiter(csvDelimiter)) }.joined(separator: separator)
            } else if outputINI {
                let separator = joinOutput ? "" : "\n"
                rendered = outputs.map(renderINIValue).joined(separator: separator)
            } else if outputTOML {
                let separator = joinOutput ? "" : "\n"
                rendered = outputs.map(renderTOMLValue).joined(separator: separator)
            } else if outputXML {
                let separator = joinOutput ? "" : "\n"
                rendered = outputs.map(renderXMLValue).joined(separator: separator)
            } else {
                let separator = joinOutput ? "" : "\n"
                rendered = outputs.map { renderYAMLValue($0) }.joined(separator: separator)
            }
            let stdout = joinOutput ? rendered : rendered + (rendered.isEmpty ? "" : "\n")
            let exitCode = exitStatusMode && !outputs.contains(where: jqTruthy) ? 1 : 0
            return ExecResult(stdout: stdout, stderr: "", exitCode: exitCode)
        } catch {
            return ExecResult.failure("yq: \(error.localizedDescription)")
        }
    }
}

private struct YQCursor {
    let value: Any
    let trail: [Any]
}

private enum YQPathStep {
    case key(String)
    case index(Int)
    case iterate
}

private func yqProgramUsesNavigation(_ program: String) -> Bool {
    let parts = splitTopLevelJQ(program, separator: "|") ?? [program]
    return parts.contains { part in
        let trimmed = part.trimmingCharacters(in: .whitespaces)
        return trimmed == "root" || trimmed == "parents" || trimmed == "parent" || (trimmed.hasPrefix("parent(") && trimmed.hasSuffix(")"))
    }
}

private func evaluateYQNavigationFilter(_ program: String, input: Any) throws -> [Any] {
    let parts = splitTopLevelJQ(program, separator: "|") ?? [program]
    var cursors = [YQCursor(value: input, trail: [input])]

    for part in parts {
        let trimmed = part.trimmingCharacters(in: .whitespaces)
        switch trimmed {
        case "root":
            cursors = cursors.map { YQCursor(value: $0.trail.first ?? $0.value, trail: [$0.trail.first ?? $0.value]) }
        case "parents":
            cursors = cursors.map {
                let parents = Array($0.trail.dropLast()).reversed()
                return YQCursor(value: Array(parents), trail: [])
            }
        case "parent":
            cursors = cursors.compactMap { yqParentCursor($0, levels: 1) }
        default:
            if trimmed.hasPrefix("parent("), trimmed.hasSuffix(")") {
                let inner = String(trimmed.dropFirst(7).dropLast())
                let levels = Int(inner.trimmingCharacters(in: .whitespaces)) ?? 1
                cursors = cursors.compactMap { yqParentCursor($0, levels: levels) }
            } else if trimmed.hasPrefix(".") {
                cursors = try cursors.flatMap { try navigateYQPath(trimmed, from: $0) }
            } else {
                cursors = try cursors.flatMap { cursor in
                    try evaluateJQFilter(trimmed, input: cursor.value).map { YQCursor(value: $0, trail: []) }
                }
            }
        }
    }

    return cursors.map(\.value)
}

private func yqParentCursor(_ cursor: YQCursor, levels: Int) -> YQCursor? {
    let currentDepth = cursor.trail.count - 1
    let targetIndex: Int

    if levels >= 0 {
        targetIndex = currentDepth - levels
    } else {
        targetIndex = (-levels) - 1
    }

    guard targetIndex >= 0, targetIndex < cursor.trail.count else { return nil }
    let value = cursor.trail[targetIndex]
    let trail = Array(cursor.trail.prefix(targetIndex + 1))
    return YQCursor(value: value, trail: trail)
}

private func navigateYQPath(_ filter: String, from cursor: YQCursor) throws -> [YQCursor] {
    if filter == "." { return [cursor] }
    let steps = try parseYQPathSteps(filter)
    var cursors = [cursor]

    for step in steps {
        cursors = cursors.flatMap { current -> [YQCursor] in
            switch step {
            case let .key(key):
                let child = jqObjectLookup(current.value, key: key)
                guard !(child is NSNull) else { return [YQCursor]() }
                return [YQCursor(value: child, trail: current.trail + [child])]
            case let .index(index):
                guard let child = jqArrayIndex(current.value, index) else { return [YQCursor]() }
                return [YQCursor(value: child, trail: current.trail + [child])]
            case .iterate:
                guard let array = current.value as? [Any] else { return [YQCursor]() }
                return array.map { YQCursor(value: $0, trail: current.trail + [$0]) }
            }
        }
    }

    return cursors
}

private func parseYQPathSteps(_ filter: String) throws -> [YQPathStep] {
    guard filter.first == "." else {
        throw NSError(domain: "yq", code: 1, userInfo: [NSLocalizedDescriptionKey: "unsupported navigation path"])
    }

    var steps: [YQPathStep] = []
    var index = filter.index(after: filter.startIndex)

    while index < filter.endIndex {
        if filter[index] == "." {
            index = filter.index(after: index)
            while index < filter.endIndex, filter[index].isWhitespace {
                index = filter.index(after: index)
            }
            continue
        }

        if filter[index] == "[" {
            guard let closing = filter[index...].firstIndex(of: "]") else {
                throw NSError(domain: "yq", code: 1, userInfo: [NSLocalizedDescriptionKey: "bad navigation path"])
            }
            let content = String(filter[filter.index(after: index)..<closing]).trimmingCharacters(in: .whitespaces)
            if content.isEmpty {
                steps.append(.iterate)
            } else if let number = Int(content) {
                steps.append(.index(number))
            } else if let key = parseJQLiteral(content) as? String {
                steps.append(.key(key))
            } else {
                throw NSError(domain: "yq", code: 1, userInfo: [NSLocalizedDescriptionKey: "bad navigation path"])
            }
            index = filter.index(after: closing)
            continue
        }

        if filter[index] == "\"" {
            let stringStart = index
            index = filter.index(after: index)
            var escaped = false
            while index < filter.endIndex {
                let ch = filter[index]
                if escaped {
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "\"" {
                    break
                }
                index = filter.index(after: index)
            }
            guard index < filter.endIndex,
                  let key = parseJQLiteral(String(filter[stringStart...index])) as? String else {
                throw NSError(domain: "yq", code: 1, userInfo: [NSLocalizedDescriptionKey: "bad navigation path"])
            }
            steps.append(.key(key))
            index = filter.index(after: index)
            continue
        }

        let start = index
        while index < filter.endIndex, filter[index] != ".", filter[index] != "[" {
            index = filter.index(after: index)
        }
        let key = String(filter[start..<index]).trimmingCharacters(in: .whitespaces)
        if !key.isEmpty {
            steps.append(.key(key))
        }
    }

    return steps
}

private func renderYQJSONValue(_ value: Any, compact: Bool, raw: Bool, indent: Int) -> String {
    if compact || raw || indent == 2 {
        return renderJQValue(value, compact: compact, raw: raw)
    }
    return renderYQStructuredJSON(value, indent: indent, level: 0)
}

private func renderYQStructuredJSON(_ value: Any, indent: Int, level: Int) -> String {
    if value is NSNull { return "null" }
    if let string = value as? String { return "\"\(escapeJSONString(string))\"" }
    if let number = value as? NSNumber {
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue ? "true" : "false"
        }
        if floor(number.doubleValue) == number.doubleValue {
            return String(number.intValue)
        }
        return String(number.doubleValue)
    }
    if let bool = value as? Bool { return bool ? "true" : "false" }
    if let int = value as? Int { return String(int) }
    if let double = value as? Double { return String(double) }
    if let orderedArray = value as? [OrderedJSONObject] {
        return renderYQStructuredJSON(orderedArray.map { $0 as Any }, indent: indent, level: level)
    }
    if let array = value as? [Any] {
        if array.isEmpty { return "[]" }
        let prefix = String(repeating: " ", count: indent * (level + 1))
        let closing = String(repeating: " ", count: indent * level)
        let rendered = array.map { prefix + renderYQStructuredJSON($0, indent: indent, level: level + 1) }
        return "[\n" + rendered.joined(separator: ",\n") + "\n" + closing + "]"
    }
    if let object = value as? OrderedJSONObject {
        return renderYQStructuredJSONObject(object.entries, indent: indent, level: level)
    }
    if let object = jqObjectDictionary(value) {
        let entries = object.keys.sorted().map { ($0, object[$0] as Any) }
        return renderYQStructuredJSONObject(entries, indent: indent, level: level)
    }
    return renderJQValue(value, compact: false, raw: false)
}

private func renderYQStructuredJSONObject(_ entries: [(String, Any)], indent: Int, level: Int) -> String {
    if entries.isEmpty { return "{}" }
    let prefix = String(repeating: " ", count: indent * (level + 1))
    let closing = String(repeating: " ", count: indent * level)
    let rendered = entries.map { key, value in
        prefix + "\"\(escapeJSONString(key))\": " + renderYQStructuredJSON(value, indent: indent, level: level + 1)
    }
    return "{\n" + rendered.joined(separator: ",\n") + "\n" + closing + "}"
}

private struct YAMLLine {
    let indent: Int
    let text: String
}

private func parseSimpleYAML(_ text: String) throws -> Any {
    let lines = text
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init)
        .compactMap { raw -> YAMLLine? in
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), trimmed != "---" else { return nil }
            let indent = raw.prefix { $0 == " " }.count
            return YAMLLine(indent: indent, text: trimmed)
        }

    if lines.isEmpty { return NSNull() }
    var index = 0
    return try parseYAMLBlock(lines, index: &index, indent: lines[0].indent)
}

private func parseYAMLDocuments(_ text: String) throws -> [Any] {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var documents: [String] = []
    var current: [String] = []

    for line in lines {
        if line.trimmingCharacters(in: .whitespaces) == "---" {
            let document = current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !document.isEmpty {
                documents.append(document)
            }
            current = []
        } else {
            current.append(line)
        }
    }

    let tail = current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    if !tail.isEmpty {
        documents.append(tail)
    }

    if documents.isEmpty {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? [] : [try parseSimpleYAML(trimmed)]
    }

    return try documents.map(parseSimpleYAML)
}

private func parseCSVInput(_ text: String, delimiter: Character) throws -> [[String: Any]] {
    let lines = text
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init)
        .filter { !$0.isEmpty }
    guard let headerLine = lines.first else { return [] }

    let headers = parseCSVRow(headerLine, delimiter: delimiter)
    return lines.dropFirst().map { line in
        let fields = parseCSVRow(line, delimiter: delimiter)
        var row: [String: Any] = [:]
        for (index, header) in headers.enumerated() {
            row[header] = index < fields.count ? parseYQCSVScalar(fields[index]) : NSNull()
        }
        return row
    }
}

private func parseCSVRow(_ line: String, delimiter: Character) -> [String] {
    var fields: [String] = []
    var current = ""
    var inQuotes = false
    let chars = Array(line)
    var index = 0

    while index < chars.count {
        let ch = chars[index]
        if ch == "\"" {
            if inQuotes, index + 1 < chars.count, chars[index + 1] == "\"" {
                current.append("\"")
                index += 2
                continue
            }
            inQuotes.toggle()
            index += 1
            continue
        }
        if ch == delimiter, !inQuotes {
            fields.append(current)
            current = ""
            index += 1
            continue
        }
        current.append(ch)
        index += 1
    }

    fields.append(current)
    return fields
}

private func parseINIInput(_ text: String) throws -> [String: Any] {
    var result: [String: Any] = [:]
    var currentSection: String?

    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") {
            continue
        }
        if line.hasPrefix("["), line.hasSuffix("]") {
            let section = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            currentSection = section
            if result[section] == nil {
                result[section] = [String: Any]()
            }
            continue
        }
        guard let equal = line.firstIndex(of: "=") else { continue }
        let key = String(line[..<equal]).trimmingCharacters(in: .whitespaces)
        let value = parseINIScalar(String(line[line.index(after: equal)...]).trimmingCharacters(in: .whitespaces))

        if let currentSection {
            var sectionObject = (result[currentSection] as? [String: Any]) ?? [:]
            sectionObject[key] = value
            result[currentSection] = sectionObject
        } else {
            result[key] = value
        }
    }

    return result
}

private func parseTOMLInput(_ text: String) throws -> [String: Any] {
    var result: [String: Any] = [:]
    var currentPath: [String] = []

    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty || line.hasPrefix("#") {
            continue
        }
        if line.hasPrefix("["), line.hasSuffix("]") {
            let section = String(line.dropFirst().dropLast())
            currentPath = section.split(separator: ".").map { $0.trimmingCharacters(in: .whitespaces) }
            continue
        }
        guard let equal = line.firstIndex(of: "=") else { continue }
        let key = String(line[..<equal]).trimmingCharacters(in: .whitespaces)
        let value = parseTOMLScalar(String(line[line.index(after: equal)...]).trimmingCharacters(in: .whitespaces))
        setNestedObjectValue(&result, path: currentPath + [key], value: value)
    }

    return result
}

private func parseYAMLBlock(_ lines: [YAMLLine], index: inout Int, indent: Int) throws -> Any {
    guard index < lines.count else { return NSNull() }
    if lines[index].text.hasPrefix("- ") {
        return try parseYAMLArray(lines, index: &index, indent: indent)
    }
    return try parseYAMLObject(lines, index: &index, indent: indent)
}

private func parseYAMLObject(_ lines: [YAMLLine], index: inout Int, indent: Int) throws -> [String: Any] {
    var result: [String: Any] = [:]
    while index < lines.count {
        let line = lines[index]
        if line.indent < indent || line.text.hasPrefix("- ") {
            break
        }
        guard line.indent == indent, let colon = line.text.firstIndex(of: ":") else {
            break
        }
        let key = String(line.text[..<colon]).trimmingCharacters(in: .whitespaces)
        let remainder = String(line.text[line.text.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        index += 1
        if remainder.isEmpty {
            if index < lines.count, lines[index].indent > indent {
                result[key] = try parseYAMLBlock(lines, index: &index, indent: lines[index].indent)
            } else {
                result[key] = NSNull()
            }
        } else {
            result[key] = parseYAMLScalar(remainder)
        }
    }
    return result
}

private func parseYAMLArray(_ lines: [YAMLLine], index: inout Int, indent: Int) throws -> [Any] {
    var result: [Any] = []
    while index < lines.count {
        let line = lines[index]
        guard line.indent == indent, line.text.hasPrefix("- ") else { break }
        let remainder = String(line.text.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        index += 1
        if remainder.isEmpty {
            if index < lines.count, lines[index].indent > indent {
                result.append(try parseYAMLBlock(lines, index: &index, indent: lines[index].indent))
            } else {
                result.append(NSNull())
            }
            continue
        }
        if let colon = remainder.firstIndex(of: ":"), !remainder.hasPrefix("\""), !remainder.hasPrefix("'") {
            let key = String(remainder[..<colon]).trimmingCharacters(in: .whitespaces)
            let valueText = String(remainder[remainder.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            var object: [String: Any] = [key: valueText.isEmpty ? NSNull() : parseYAMLScalar(valueText)]
            while index < lines.count, lines[index].indent > indent {
                let nested = lines[index]
                guard let nestedColon = nested.text.firstIndex(of: ":") else { break }
                let nestedKey = String(nested.text[..<nestedColon]).trimmingCharacters(in: .whitespaces)
                let nestedValueText = String(nested.text[nested.text.index(after: nestedColon)...]).trimmingCharacters(in: .whitespaces)
                index += 1
                if nestedValueText.isEmpty, index < lines.count, lines[index].indent > nested.indent {
                    object[nestedKey] = try parseYAMLBlock(lines, index: &index, indent: lines[index].indent)
                } else {
                    object[nestedKey] = nestedValueText.isEmpty ? NSNull() : parseYAMLScalar(nestedValueText)
                }
            }
            result.append(object)
        } else {
            result.append(parseYAMLScalar(remainder))
        }
    }
    return result
}

private func parseYAMLScalar(_ text: String) -> Any {
    if text == "null" { return NSNull() }
    if text == "true" { return true }
    if text == "false" { return false }
    if let int = Int(text) { return int }
    if let double = Double(text) { return double }
    if text.hasPrefix("\""), text.hasSuffix("\"") {
        return String(text.dropFirst().dropLast())
    }
    if text.hasPrefix("'"), text.hasSuffix("'") {
        return String(text.dropFirst().dropLast())
    }
    return text
}

private func parseYQCSVScalar(_ text: String) -> Any {
    if let int = Int(text) { return int }
    if let double = Double(text) { return double }
    if text == "true" { return true }
    if text == "false" { return false }
    return text
}

private func parseINIScalar(_ text: String) -> Any {
    if text == "true" { return true }
    if text == "false" { return false }
    if text.hasPrefix("\""), text.hasSuffix("\"") {
        return String(text.dropFirst().dropLast())
    }
    if text.hasPrefix("'"), text.hasSuffix("'") {
        return String(text.dropFirst().dropLast())
    }
    return text
}

private func parseTOMLScalar(_ text: String) -> Any {
    if text == "true" { return true }
    if text == "false" { return false }
    if let int = Int(text) { return int }
    if let double = Double(text) { return double }
    if text.hasPrefix("\""), text.hasSuffix("\"") {
        return String(text.dropFirst().dropLast())
    }
    if text.hasPrefix("'"), text.hasSuffix("'") {
        return String(text.dropFirst().dropLast())
    }
    if text.hasPrefix("[") && text.hasSuffix("]") {
        let inner = String(text.dropFirst().dropLast())
        let parts = splitTopLevelList(inner)
        return parts.map { parseTOMLScalar($0.trimmingCharacters(in: .whitespaces)) }
    }
    return text
}

private func renderYAMLValue(_ value: Any, indent: Int = 0) -> String {
    let indentText = String(repeating: "  ", count: indent)
    if value is NSNull { return "null" }
    if let string = value as? String { return string }
    if let number = value as? NSNumber {
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue ? "true" : "false"
        }
        if floor(number.doubleValue) == number.doubleValue {
            return String(number.intValue)
        }
        return String(number.doubleValue)
    }
    if let array = value as? [Any] {
        return array.map { item in
            if item is [String: Any] || item is [Any] {
                return "\(indentText)- \(renderYAMLValue(item, indent: indent + 1).replacingOccurrences(of: "\n", with: "\n" + indentText + "  "))"
            }
            return "\(indentText)- \(renderYAMLValue(item, indent: indent + 1))"
        }.joined(separator: "\n")
    }
    if let object = value as? [String: Any] {
        return object.keys.sorted().map { key in
            let rendered = renderYAMLValue(object[key] as Any, indent: indent + 1)
            if object[key] is [String: Any] || object[key] is [Any] {
                return "\(indentText)\(key):\n\(rendered)"
            }
            return "\(indentText)\(key): \(rendered)"
        }.joined(separator: "\n")
    }
    if let object = value as? OrderedJSONObject {
        return object.entries.map { key, child in
            let rendered = renderYAMLValue(child, indent: indent + 1)
            if child is [String: Any] || child is [Any] || child is OrderedJSONObject {
                return "\(indentText)\(key):\n\(rendered)"
            }
            return "\(indentText)\(key): \(rendered)"
        }.joined(separator: "\n")
    }
    return String(describing: value)
}

private func renderCSVValue(_ value: Any, delimiter: Character) -> String {
    let delimiterString = String(delimiter)

    if let rows = value as? [Any] {
        if rows.isEmpty { return "" }

        if let firstObject = jqObjectDictionary(rows[0]) {
            let headers = Array(firstObject.keys).sorted()
            let headerLine = headers.map(jqCSVField).joined(separator: delimiterString)
            let dataLines = rows.map { row -> String in
                let object = jqObjectDictionary(row) ?? [:]
                return headers.map { header in
                    jqCSVField(object[header] as Any)
                }.joined(separator: delimiterString)
            }
            return ([headerLine] + dataLines).joined(separator: "\n")
        }

        return rows.map { row in
            if let array = row as? [Any] {
                return array.map(jqCSVField).joined(separator: delimiterString)
            }
            return jqCSVField(row)
        }.joined(separator: "\n")
    }

    return jqCSVField(value)
}

private func decodeYQDelimiter(_ text: String) -> Character {
    if text == "\\t" { return "\t" }
    return text.first ?? ","
}

private func renderINIValue(_ value: Any) -> String {
    guard let object = jqObjectDictionary(value) else { return "" }
    var lines: [String] = []

    for key in object.keys.sorted() {
        if let childObject = jqObjectDictionary(object[key] as Any) {
            lines.append("[\(key)]")
            for childKey in childObject.keys.sorted() {
                lines.append("\(childKey)=\(jqPlainTextValue(childObject[childKey] as Any))")
            }
            lines.append("")
        } else {
            lines.append("\(key)=\(jqPlainTextValue(object[key] as Any))")
        }
    }

    if lines.last == "" {
        lines.removeLast()
    }
    return lines.joined(separator: "\n")
}

private func renderTOMLValue(_ value: Any) -> String {
    guard let object = jqObjectDictionary(value) else { return "" }
    var lines: [String] = []
    renderTOMLObject(object, path: [], lines: &lines)
    return lines.joined(separator: "\n")
}

private func renderTOMLObject(_ object: [String: Any], path: [String], lines: inout [String]) {
    let scalarKeys = object.keys.sorted().filter { !(jqObjectDictionary(object[$0] as Any) != nil) }
    let objectKeys = object.keys.sorted().filter { jqObjectDictionary(object[$0] as Any) != nil }

    if !path.isEmpty {
        if !lines.isEmpty { lines.append("") }
        lines.append("[\(path.joined(separator: "."))]")
    }

    for key in scalarKeys {
        lines.append("\(key) = \(renderTOMLScalar(object[key] as Any))")
    }

    for key in objectKeys {
        if let child = jqObjectDictionary(object[key] as Any) {
            renderTOMLObject(child, path: path + [key], lines: &lines)
        }
    }
}

private func renderTOMLScalar(_ value: Any) -> String {
    if value is NSNull { return "\"\"" }
    if let string = value as? String { return "\"\(escapeJSONString(string))\"" }
    if let number = value as? NSNumber {
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue ? "true" : "false"
        }
        if floor(number.doubleValue) == number.doubleValue {
            return String(number.intValue)
        }
        return String(number.doubleValue)
    }
    if let bool = value as? Bool { return bool ? "true" : "false" }
    if let int = value as? Int { return String(int) }
    if let double = value as? Double { return String(double) }
    if let array = value as? [Any] {
        return "[" + array.map(renderTOMLScalar).joined(separator: ", ") + "]"
    }
    return "\"\(escapeJSONString(String(describing: value)))\""
}

private func splitTopLevelList(_ text: String) -> [String] {
    var parts: [String] = []
    var current = ""
    var depth = 0
    var inString = false
    var escaped = false

    for ch in text {
        if escaped {
            current.append(ch)
            escaped = false
            continue
        }
        if ch == "\\" {
            current.append(ch)
            escaped = true
            continue
        }
        if ch == "\"" {
            inString.toggle()
            current.append(ch)
            continue
        }
        if !inString {
            if ch == "[" { depth += 1 }
            if ch == "]" { depth -= 1 }
            if ch == ",", depth == 0 {
                parts.append(current)
                current = ""
                continue
            }
        }
        current.append(ch)
    }

    if !current.isEmpty || text.isEmpty {
        parts.append(current)
    }
    return parts
}

private func setNestedObjectValue(_ object: inout [String: Any], path: [String], value: Any) {
    guard let key = path.first else { return }
    if path.count == 1 {
        object[key] = value
        return
    }

    var child = (object[key] as? [String: Any]) ?? [:]
    setNestedObjectValue(&child, path: Array(path.dropFirst()), value: value)
    object[key] = child
}

// MARK: - XML Output

private func escapeXMLText(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
}

private func renderXMLValue(_ value: Any) -> String {
    renderXMLNode(value, tag: nil, indent: 0)
}

private func renderXMLNode(_ value: Any, tag: String?, indent: Int) -> String {
    let prefix = String(repeating: "  ", count: indent)

    if let object = value as? OrderedJSONObject {
        var lines: [String] = []
        if let tag { lines.append("\(prefix)<\(tag)>") }
        for (key, child) in object.entries {
            lines.append(renderXMLNode(child, tag: key, indent: indent + (tag != nil ? 1 : 0)))
        }
        if let tag { lines.append("\(prefix)</\(tag)>") }
        return lines.joined(separator: "\n")
    }

    if let object = jqObjectDictionary(value) {
        var lines: [String] = []
        if let tag { lines.append("\(prefix)<\(tag)>") }
        for key in object.keys.sorted() {
            lines.append(renderXMLNode(object[key] as Any, tag: key, indent: indent + (tag != nil ? 1 : 0)))
        }
        if let tag { lines.append("\(prefix)</\(tag)>") }
        return lines.joined(separator: "\n")
    }

    if let array = value as? [Any] {
        guard let tag else {
            return array.map { renderXMLNode($0, tag: "item", indent: indent) }.joined(separator: "\n")
        }
        return array.map { renderXMLNode($0, tag: tag, indent: indent) }.joined(separator: "\n")
    }

    let text: String
    if value is NSNull {
        text = ""
    } else if let string = value as? String {
        text = escapeXMLText(string)
    } else if let number = value as? NSNumber {
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            text = number.boolValue ? "true" : "false"
        } else if floor(number.doubleValue) == number.doubleValue {
            text = String(number.intValue)
        } else {
            text = String(number.doubleValue)
        }
    } else if let bool = value as? Bool {
        text = bool ? "true" : "false"
    } else if let int = value as? Int {
        text = String(int)
    } else if let double = value as? Double {
        text = String(double)
    } else {
        text = escapeXMLText(String(describing: value))
    }

    guard let tag else { return "\(prefix)\(text)" }
    return "\(prefix)<\(tag)>\(text)</\(tag)>"
}
