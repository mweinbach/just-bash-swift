import Foundation
import JustBashFS

func cut() -> AnyBashCommand {
    AnyBashCommand(name: "cut") { args, ctx in
        var delimiter = "\t"
        var fields: [Int] = []
        var charPositions: [Int] = []
        var files: [String] = []
        var i = 0
        while i < args.count {
            let arg = args[i]
            if arg == "-d" {
                if i + 1 < args.count { delimiter = args[i + 1]; i += 2 } else { i += 1 }
            } else if arg.hasPrefix("-d") && arg.count > 2 {
                delimiter = String(arg.dropFirst(2)); i += 1
            } else if arg == "-f" {
                if i + 1 < args.count { fields = parseRangeSpec(args[i + 1]); i += 2 } else { i += 1 }
            } else if arg.hasPrefix("-f") && arg.count > 2 {
                fields = parseRangeSpec(String(arg.dropFirst(2))); i += 1
            } else if arg == "-c" {
                if i + 1 < args.count { charPositions = parseRangeSpec(args[i + 1]); i += 2 } else { i += 1 }
            } else {
                files.append(arg); i += 1
            }
        }

        let content: String
        do {
            if files.isEmpty { content = ctx.stdin }
            else { content = try files.map { try ctx.fileSystem.readFile($0, relativeTo: ctx.cwd) }.joined() }
        } catch {
            return ExecResult.failure("cut: \(error.localizedDescription)")
        }

        var lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" && content.hasSuffix("\n") { lines.removeLast() }

        let output = lines.map { line -> String in
            if !charPositions.isEmpty {
                let arr = Array(line)
                return charPositions.compactMap { pos in pos > 0 && pos <= arr.count ? String(arr[pos - 1]) : nil }.joined()
            }
            if !fields.isEmpty {
                let parts = line.components(separatedBy: delimiter)
                return fields.compactMap { f in f > 0 && f <= parts.count ? parts[f - 1] : nil }.joined(separator: delimiter)
            }
            return line
        }

        return ExecResult.success(output.joined(separator: "\n") + "\n")
    }
}

private func parseRangeSpec(_ spec: String) -> [Int] {
    var result: [Int] = []
    for part in spec.split(separator: ",") {
        if part.contains("-") {
            let range = part.split(separator: "-")
            if range.count == 2, let start = Int(range[0]), let end = Int(range[1]) {
                result.append(contentsOf: start...end)
            } else if part.hasPrefix("-"), let end = Int(range[0]) {
                result.append(contentsOf: 1...end)
            } else if part.hasSuffix("-"), let start = Int(range[0]) {
                result.append(contentsOf: start...100)
            }
        } else if let n = Int(part) {
            result.append(n)
        }
    }
    return result
}

func paste() -> AnyBashCommand {
    AnyBashCommand(name: "paste") { args, ctx in
        var delimiter = "\t"
        var serial = false
        var files: [String] = []
        var i = 0
        while i < args.count {
            switch args[i] {
            case "-d": if i + 1 < args.count { delimiter = args[i + 1]; i += 2 } else { i += 1 }
            case "-s": serial = true; i += 1
            default: files.append(args[i]); i += 1
            }
        }

        do {
            let contents = try files.map { file -> [String] in
                let content = file == "-" ? ctx.stdin : try ctx.fileSystem.readFile(file, relativeTo: ctx.cwd)
                return content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            }
            if serial {
                let output = contents.map { $0.joined(separator: delimiter) }
                return ExecResult.success(output.joined(separator: "\n") + "\n")
            }
            let maxLines = contents.map(\.count).max() ?? 0
            var output: [String] = []
            for i in 0..<maxLines {
                let line = contents.map { i < $0.count ? $0[i] : "" }.joined(separator: delimiter)
                output.append(line)
            }
            return ExecResult.success(output.joined(separator: "\n") + "\n")
        } catch {
            return ExecResult.failure("paste: \(error.localizedDescription)")
        }
    }
}

func join() -> AnyBashCommand {
    AnyBashCommand(name: "join") { args, ctx in
        var delimiter: Character? = nil
        var files: [String] = []
        var index = 0
        while index < args.count {
            if args[index] == "-t", index + 1 < args.count {
                delimiter = args[index + 1].first
                index += 2
            } else {
                files.append(args[index])
                index += 1
            }
        }
        guard files.count >= 2 else { return ExecResult.failure("join: missing file operand") }
        do {
            let lhs = try ctx.fileSystem.readFile(files[0], relativeTo: ctx.cwd)
            let rhs = try ctx.fileSystem.readFile(files[1], relativeTo: ctx.cwd)
            let splitLine: (String) -> [String] = { line in
                if let delimiter {
                    return line.split(separator: delimiter, omittingEmptySubsequences: false).map(String.init)
                }
                return line.split(whereSeparator: \.isWhitespace).map(String.init)
            }
            let rightRows = rhs.split(separator: "\n").map(String.init).map(splitLine)
            var rightByKey: [String: [[String]]] = [:]
            for row in rightRows where !row.isEmpty {
                rightByKey[row[0], default: []].append(row)
            }

            var output: [String] = []
            for row in lhs.split(separator: "\n").map(String.init).map(splitLine) where !row.isEmpty {
                guard let matches = rightByKey[row[0]] else { continue }
                for match in matches {
                    output.append(([row[0]] + Array(row.dropFirst()) + Array(match.dropFirst())).joined(separator: delimiter.map(String.init) ?? " "))
                }
            }
            return ExecResult.success(output.joined(separator: "\n") + (output.isEmpty ? "" : "\n"))
        } catch {
            return ExecResult.failure("join: \(error.localizedDescription)")
        }
    }
}
