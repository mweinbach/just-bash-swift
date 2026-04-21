import Foundation
import JustBashFS

func wc() -> AnyBashCommand {
    AnyBashCommand(name: "wc") { args, ctx in
        var lineOnly = false, wordOnly = false, byteOnly = false, charOnly = false
        let paths = args.filter { arg in
            for ch in arg.dropFirst() where arg.hasPrefix("-") {
                switch ch {
                case "l": lineOnly = true
                case "w": wordOnly = true
                case "c": byteOnly = true
                case "m": charOnly = true
                default: break
                }
            }
            return !arg.hasPrefix("-")
        }
        do {
            var entries: [(content: String, label: String)] = []
            if paths.isEmpty {
                entries.append((content: ctx.stdin, label: ""))
            } else {
                for path in paths {
                    let data = try ctx.fileSystem.readFile(path: path, relativeTo: ctx.cwd)
                    let content = String(decoding: data, as: UTF8.self)
                    entries.append((content: content, label: " \(path)"))
                }
            }

            func formatEntry(_ content: String, _ label: String) -> String {
                let lines = content.isEmpty ? 0 : content.split(separator: "\n", omittingEmptySubsequences: false).count - (content.hasSuffix("\n") ? 1 : 0)
                let words = content.split(whereSeparator: \.isWhitespace).count
                let bytes = content.utf8.count
                let chars = content.count
                switch (lineOnly, wordOnly, byteOnly, charOnly) {
                case (true, false, false, false): return "\(lines)\(label)\n"
                case (false, true, false, false): return "\(words)\(label)\n"
                case (false, false, true, false): return "\(bytes)\(label)\n"
                case (false, false, false, true): return "\(chars)\(label)\n"
                default: return "\(lines) \(words) \(bytes)\(label)\n"
                }
            }

            var output = ""
            var totalLines = 0, totalWords = 0, totalBytes = 0, totalChars = 0
            for entry in entries {
                output += formatEntry(entry.content, entry.label)
                let content = entry.content
                totalLines += content.isEmpty ? 0 : content.split(separator: "\n", omittingEmptySubsequences: false).count - (content.hasSuffix("\n") ? 1 : 0)
                totalWords += content.split(whereSeparator: \.isWhitespace).count
                totalBytes += content.utf8.count
                totalChars += content.count
            }

            if entries.count > 1 {
                switch (lineOnly, wordOnly, byteOnly, charOnly) {
                case (true, false, false, false): output += "\(totalLines) total\n"
                case (false, true, false, false): output += "\(totalWords) total\n"
                case (false, false, true, false): output += "\(totalBytes) total\n"
                case (false, false, false, true): output += "\(totalChars) total\n"
                default: output += "\(totalLines) \(totalWords) \(totalBytes) total\n"
                }
            }

            return ExecResult.success(output)
        } catch {
            return ExecResult.failure("wc: \(error.localizedDescription)")
        }
    }
}

func head() -> AnyBashCommand {
    AnyBashCommand(name: "head") { args, ctx in
        runLineSlicer(command: "head", args: args, ctx: ctx, tailMode: false)
    }
}

func tail() -> AnyBashCommand {
    AnyBashCommand(name: "tail") { args, ctx in
        runLineSlicer(command: "tail", args: args, ctx: ctx, tailMode: true)
    }
}

func tac() -> AnyBashCommand {
    AnyBashCommand(name: "tac") { args, ctx in
        let content: String
        do {
            if args.isEmpty { content = ctx.stdin }
            else { 
                content = try args.map { 
                    let data = try ctx.fileSystem.readFile(path: $0, relativeTo: ctx.cwd)
                    return String(decoding: data, as: UTF8.self)
                }.joined() 
            }
        } catch {
            return ExecResult.failure("tac: \(error.localizedDescription)")
        }
        var lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" && content.hasSuffix("\n") { lines.removeLast() }
        lines.reverse()
        return ExecResult.success(lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n"))
    }
}

private func runLineSlicer(command: String, args: [String], ctx: CommandContext, tailMode: Bool) -> ExecResult {
    var count = 10
    var paths: [String] = []
    var index = 0
    while index < args.count {
        if args[index] == "-f" || args[index] == "--follow" {
            index += 1; continue
        }
        if args[index] == "-n", index + 1 < args.count {
            count = Int(args[index + 1]) ?? 10; index += 2
        } else if args[index].hasPrefix("-") && args[index] != "-" {
            if let n = Int(String(args[index].dropFirst())) { count = abs(n) }
            index += 1
        } else {
            paths.append(args[index]); index += 1
        }
    }

    let content: String
    do {
        if paths.isEmpty { content = ctx.stdin }
        else { 
            content = try paths.map { 
                let data = try ctx.fileSystem.readFile(path: $0, relativeTo: ctx.cwd)
                return String(decoding: data, as: UTF8.self)
            }.joined() 
        }
    } catch {
        return ExecResult.failure("\(command): \(error.localizedDescription)")
    }

    let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let slice = tailMode ? Array(lines.suffix(count)) : Array(lines.prefix(count))
    let joined = slice.joined(separator: "\n")
    if joined.isEmpty { return ExecResult.success() }
    return ExecResult.success(joined + (content.hasSuffix("\n") || slice.count < lines.count ? "\n" : ""))
}

func rev() -> AnyBashCommand {
    AnyBashCommand(name: "rev") { args, ctx in
        let content: String
        do {
            if args.isEmpty { content = ctx.stdin }
            else { 
                content = try args.map { 
                    let data = try ctx.fileSystem.readFile(path: $0, relativeTo: ctx.cwd)
                    return String(decoding: data, as: UTF8.self)
                }.joined() 
            }
        } catch {
            return ExecResult.failure("rev: \(error.localizedDescription)")
        }
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map { String($0.reversed()) }
        return ExecResult.success(lines.joined(separator: "\n"))
    }
}

func nl() -> AnyBashCommand {
    AnyBashCommand(name: "nl") { args, ctx in
        let content: String
        do {
            if args.isEmpty || args.allSatisfy({ $0.hasPrefix("-") }) { content = ctx.stdin }
            else { 
                let data = try ctx.fileSystem.readFile(path: args.last!, relativeTo: ctx.cwd)
                content = String(decoding: data, as: UTF8.self)
            }
        } catch {
            return ExecResult.failure("nl: \(error.localizedDescription)")
        }
        var lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last?.isEmpty == true && content.hasSuffix("\n") { lines.removeLast() }
        var num = 1
        let output = lines.map { line -> String in
            if line.isEmpty { return "       \(line)" }
            let result = String(format: "%6d\t%@", num, line)
            num += 1
            return result
        }
        return ExecResult.success(output.joined(separator: "\n") + "\n")
    }
}

func fold() -> AnyBashCommand {
    AnyBashCommand(name: "fold") { args, ctx in
        var width = 80
        var i = 0; var files: [String] = []
        while i < args.count {
            if args[i] == "-w" { if i + 1 < args.count { width = Int(args[i + 1]) ?? 80; i += 2 } else { i += 1 } }
            else { files.append(args[i]); i += 1 }
        }
        let content: String
        do {
            if files.isEmpty { content = ctx.stdin }
            else { 
                content = try files.map { 
                    let data = try ctx.fileSystem.readFile(path: $0, relativeTo: ctx.cwd)
                    return String(decoding: data, as: UTF8.self)
                }.joined() 
            }
        } catch {
            return ExecResult.failure("fold: \(error.localizedDescription)")
        }
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var output: [String] = []
        for line in lines {
            var remaining = line
            while remaining.count > width {
                output.append(String(remaining.prefix(width)))
                remaining = String(remaining.dropFirst(width))
            }
            output.append(remaining)
        }
        return ExecResult.success(output.joined(separator: "\n"))
    }
}

func expand() -> AnyBashCommand {
    AnyBashCommand(name: "expand") { args, ctx in
        let content: String
        do {
            let files = args.filter { !$0.hasPrefix("-") }
            if files.isEmpty { content = ctx.stdin }
            else { 
                content = try files.map { 
                    let data = try ctx.fileSystem.readFile(path: $0, relativeTo: ctx.cwd)
                    return String(decoding: data, as: UTF8.self)
                }.joined() 
            }
        } catch {
            return ExecResult.failure("expand: \(error.localizedDescription)")
        }
        return ExecResult.success(content.replacingOccurrences(of: "\t", with: "        "))
    }
}

func unexpand() -> AnyBashCommand {
    AnyBashCommand(name: "unexpand") { args, ctx in
        let content: String
        do {
            let files = args.filter { !$0.hasPrefix("-") }
            if files.isEmpty { content = ctx.stdin }
            else { 
                content = try files.map { 
                    let data = try ctx.fileSystem.readFile(path: $0, relativeTo: ctx.cwd)
                    return String(decoding: data, as: UTF8.self)
                }.joined() 
            }
        } catch {
            return ExecResult.failure("unexpand: \(error.localizedDescription)")
        }
        return ExecResult.success(content.replacingOccurrences(of: "        ", with: "\t"))
    }
}

func column() -> AnyBashCommand {
    AnyBashCommand(name: "column") { args, ctx in
        var tableMode = false
        var separator = " "
        var i = 0; var files: [String] = []
        while i < args.count {
            if args[i] == "-t" { tableMode = true; i += 1 }
            else if args[i] == "-s" { if i + 1 < args.count { separator = args[i + 1]; i += 2 } else { i += 1 } }
            else { files.append(args[i]); i += 1 }
        }
        let content: String
        do {
            if files.isEmpty { content = ctx.stdin }
            else { 
                content = try files.map { 
                    let data = try ctx.fileSystem.readFile(path: $0, relativeTo: ctx.cwd)
                    return String(decoding: data, as: UTF8.self)
                }.joined() 
            }
        } catch {
            return ExecResult.failure("column: \(error.localizedDescription)")
        }
        if !tableMode { return ExecResult.success(content) }
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let rows = lines.map { $0.components(separatedBy: separator).filter { !$0.isEmpty } }
        let maxCols = rows.map(\.count).max() ?? 0
        var widths = Array(repeating: 0, count: maxCols)
        for row in rows {
            for (i, col) in row.enumerated() { widths[i] = max(widths[i], col.count) }
        }
        let output = rows.map { row in
            row.enumerated().map { (i, col) in col.padding(toLength: widths[i] + 2, withPad: " ", startingAt: 0) }.joined().trimmingCharacters(in: .whitespaces)
        }
        return ExecResult.success(output.joined(separator: "\n") + "\n")
    }
}

func od() -> AnyBashCommand {
    AnyBashCommand(name: "od") { args, ctx in
        let files = args.filter { !$0.hasPrefix("-") }
        let content: String
        do {
            if files.isEmpty { content = ctx.stdin }
            else { 
                content = try files.map { 
                    let data = try ctx.fileSystem.readFile(path: $0, relativeTo: ctx.cwd)
                    return String(decoding: data, as: UTF8.self)
                }.joined() 
            }
        } catch {
            return ExecResult.failure("od: \(error.localizedDescription)")
        }

        let bytes = Array(content.utf8)
        guard !bytes.isEmpty else { return ExecResult.success() }
        var lines: [String] = []
        for offset in stride(from: 0, to: bytes.count, by: 16) {
            let chunk = bytes[offset..<Swift.min(offset + 16, bytes.count)]
            let hex = chunk.map { String(format: "%02x", $0) }.joined(separator: " ")
            lines.append(String(format: "%07o %@", offset, hex))
        }
        return ExecResult.success(lines.joined(separator: "\n") + "\n")
    }
}
