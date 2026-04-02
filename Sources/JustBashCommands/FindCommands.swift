import Foundation
import JustBashFS

func find() -> AnyBashCommand {
    AnyBashCommand(name: "find") { args, ctx in
        var start = "."
        var nameFilter: String?
        var typeFilter: String?
        var maxDepth = Int.max
        var print0 = false
        var execTemplate: [String]? = nil
        var execBatch = false
        var index = 0
        if index < args.count && !args[index].hasPrefix("-") {
            start = args[index]; index += 1
        }
        while index < args.count {
            switch args[index] {
            case "-name": if index + 1 < args.count { nameFilter = args[index + 1]; index += 2 } else { index += 1 }
            case "-type": if index + 1 < args.count { typeFilter = args[index + 1]; index += 2 } else { index += 1 }
            case "-maxdepth": if index + 1 < args.count { maxDepth = Int(args[index + 1]) ?? Int.max; index += 2 } else { index += 1 }
            case "-mtime": if index + 1 < args.count { index += 2 } else { index += 1 }
            case "-print0": print0 = true; index += 1
            case "-exec":
                index += 1
                var template: [String] = []
                while index < args.count {
                    if args[index] == ";" || args[index] == "\\;" {
                        break
                    }
                    if args[index] == "+" {
                        execBatch = true
                        break
                    }
                    template.append(args[index])
                    index += 1
                }
                execTemplate = template
                index += 1
            default: index += 1
            }
        }
        do {
            let paths = try ctx.fileSystem.walk(start, relativeTo: ctx.cwd)
            let basePath = VirtualPath.normalize(start, relativeTo: ctx.cwd)
            let filtered = paths.filter { path in
                let relative = path.hasPrefix(basePath) ? String(path.dropFirst(basePath.count)) : path
                let depth = relative.split(separator: "/").count
                if depth > maxDepth { return false }
                if let filter = nameFilter {
                    if !VirtualFileSystem.globMatch(name: VirtualPath.basename(path), pattern: filter) { return false }
                }
                if let type = typeFilter {
                    switch type {
                    case "f": if ctx.fileSystem.isDirectory(path) { return false }
                    case "d": if !ctx.fileSystem.isDirectory(path) { return false }
                    default: break
                    }
                }
                return true
            }

            if let template = execTemplate {
                guard let executor = ctx.executeSubshell else {
                    return ExecResult.failure("find: -exec requires shell execution")
                }
                var combined = ExecResult()
                if execBatch {
                    let cmdParts = template.map { part -> String in
                        if part == "{}" { return filtered.joined(separator: " ") }
                        return part
                    }
                    let result = await executor(cmdParts.joined(separator: " "))
                    combined.stdout += result.stdout
                    combined.stderr += result.stderr
                    combined.exitCode = result.exitCode
                } else {
                    for path in filtered {
                        let cmdParts = template.map { part -> String in
                            if part == "{}" { return path }
                            return part
                        }
                        let result = await executor(cmdParts.joined(separator: " "))
                        combined.stdout += result.stdout
                        combined.stderr += result.stderr
                        if result.exitCode != 0 { combined.exitCode = result.exitCode }
                    }
                }
                return combined
            }

            let separator = print0 ? "\0" : "\n"
            return ExecResult.success(filtered.joined(separator: separator) + (filtered.isEmpty ? "" : (print0 ? "\0" : "\n")))
        } catch {
            return ExecResult.failure("find: \(error.localizedDescription)")
        }
    }
}

func du() -> AnyBashCommand {
    AnyBashCommand(name: "du") { args, ctx in
        var human = false
        let paths = args.filter { arg in
            if arg.hasPrefix("-") {
                for ch in arg.dropFirst() {
                    if ch == "h" { human = true }
                }
                return false
            }
            return true
        }
        let targets = paths.isEmpty ? ["."] : paths
        var lines: [String] = []
        for target in targets {
            do {
                let walked = try ctx.fileSystem.walk(target, relativeTo: ctx.cwd)
                var total = 0
                for path in walked {
                    if let info = try? ctx.fileSystem.fileInfo(path), info.kind == .file { total += info.size }
                }
                let size = human ? formatSize(total) : String(total / 1024)
                lines.append("\(size)\t\(target)")
            } catch {
                return ExecResult.failure("du: \(error.localizedDescription)")
            }
        }
        return ExecResult.success(lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n"))
    }
}

private func formatSize(_ bytes: Int) -> String {
    if bytes < 1024 { return "\(bytes)" }
    if bytes < 1024 * 1024 { return "\(bytes / 1024)K" }
    if bytes < 1024 * 1024 * 1024 { return "\(bytes / (1024 * 1024))M" }
    return "\(bytes / (1024 * 1024 * 1024))G"
}

func realpath() -> AnyBashCommand {
    AnyBashCommand(name: "realpath") { args, ctx in
        let filtered = args.filter { !$0.hasPrefix("-") }
        guard let path = filtered.first else { return ExecResult.failure("realpath: missing operand") }
        return ExecResult.success(VirtualPath.normalize(path, relativeTo: ctx.cwd) + "\n")
    }
}

func readlink() -> AnyBashCommand {
    AnyBashCommand(name: "readlink") { args, ctx in
        var canonicalize = false
        let filtered = args.filter { arg in
            if arg == "-f" || arg == "-m" || arg == "-e" { canonicalize = true; return false }
            return !arg.hasPrefix("-")
        }
        guard let path = filtered.first else { return ExecResult.failure("readlink: missing operand") }
        if canonicalize {
            return ExecResult.success(VirtualPath.normalize(path, relativeTo: ctx.cwd) + "\n")
        }
        do {
            let target = try ctx.fileSystem.readlink(path, relativeTo: ctx.cwd)
            return ExecResult.success(target + "\n")
        } catch {
            return ExecResult.failure("readlink: \(error.localizedDescription)")
        }
    }
}

func basename() -> AnyBashCommand {
    AnyBashCommand(name: "basename") { args, ctx in
        var suffix: String? = nil
        var paths: [String] = []
        var i = 0
        while i < args.count {
            if args[i] == "-s" && i + 1 < args.count {
                suffix = args[i + 1]
                i += 2
            } else if args[i] == "-a" {
                i += 1
            } else if args[i].hasPrefix("-s") {
                // Handle -sSUFFIX (merged form)
                suffix = String(args[i].dropFirst(2))
                i += 1
            } else if !args[i].hasPrefix("-") {
                paths.append(args[i])
                i += 1
            } else {
                i += 1
            }
        }
        guard !paths.isEmpty else { return ExecResult.failure("basename: missing operand") }

        // If no -s flag but exactly 2 non-option args, second is suffix (traditional form)
        if suffix == nil && paths.count == 2 {
            suffix = paths.removeLast()
        }

        var lines: [String] = []
        for path in paths {
            var name = VirtualPath.basename(path)
            if let sfx = suffix, name.hasSuffix(sfx) && name != sfx {
                name = String(name.dropLast(sfx.count))
            }
            lines.append(name)
        }
        return ExecResult.success(lines.joined(separator: "\n") + "\n")
    }
}

func dirname() -> AnyBashCommand {
    AnyBashCommand(name: "dirname") { args, ctx in
        let paths = args.filter { !$0.hasPrefix("-") }
        guard !paths.isEmpty else { return ExecResult.failure("dirname: missing operand") }
        let lines = paths.map { VirtualPath.dirname($0) }
        return ExecResult.success(lines.joined(separator: "\n") + "\n")
    }
}

func file() -> AnyBashCommand {
    AnyBashCommand(name: "file") { args, ctx in
        let paths = args.filter { !$0.hasPrefix("-") }
        guard !paths.isEmpty else { return ExecResult.failure("file: missing operand") }
        do {
            let lines = try paths.map { path -> String in
                let info = try ctx.fileSystem.fileInfo(path, relativeTo: ctx.cwd)
                let description: String
                switch info.kind {
                case .directory:
                    description = "directory"
                case .symlink:
                    description = "symbolic link"
                case .file:
                    let name = VirtualPath.basename(path).lowercased()
                    if name.hasSuffix(".json") {
                        description = "JSON text"
                    } else if name.hasSuffix(".md") {
                        description = "Markdown text"
                    } else if name.hasSuffix(".txt") || name.hasSuffix(".log") {
                        description = "ASCII text"
                    } else if name.hasSuffix(".sh") {
                        description = "shell script"
                    } else {
                        description = info.size == 0 ? "empty" : "data"
                    }
                }
                return "\(path): \(description)"
            }
            return ExecResult.success(lines.joined(separator: "\n") + "\n")
        } catch {
            return ExecResult.failure("file: \(error.localizedDescription)")
        }
    }
}

func strings() -> AnyBashCommand {
    AnyBashCommand(name: "strings") { args, ctx in
        let files = args.filter { !$0.hasPrefix("-") }
        let content: String
        do {
            if files.isEmpty { content = ctx.stdin }
            else { content = try files.map { try ctx.fileSystem.readFile($0, relativeTo: ctx.cwd) }.joined() }
        } catch {
            return ExecResult.failure("strings: \(error.localizedDescription)")
        }

        var results: [String] = []
        var current = ""
        for ch in content {
            let isPrintableASCII = ch.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value <= 126 }
            if isPrintableASCII {
                current.append(ch)
            } else {
                if current.count >= 4 { results.append(current) }
                current = ""
            }
        }
        if current.count >= 4 { results.append(current) }
        return ExecResult.success(results.joined(separator: "\n") + (results.isEmpty ? "" : "\n"))
    }
}
