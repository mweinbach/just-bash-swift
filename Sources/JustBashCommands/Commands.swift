import Foundation
import CryptoKit
import JustBashFS
import SQLite3
import zlib

public struct ExecResult: Sendable, Equatable {
    public var stdout: String
    public var stderr: String
    public var exitCode: Int

    public init(stdout: String = "", stderr: String = "", exitCode: Int = 0) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }

    public static func success(_ stdout: String = "") -> ExecResult {
        ExecResult(stdout: stdout, stderr: "", exitCode: 0)
    }

    public static func failure(_ stderr: String, exitCode: Int = 1) -> ExecResult {
        ExecResult(stdout: "", stderr: stderr.hasSuffix("\n") ? stderr : stderr + "\n", exitCode: exitCode)
    }
}

public typealias SubshellExecutor = @Sendable (String) async -> ExecResult
public typealias CommandHandler = @Sendable ([String], CommandContext) async -> ExecResult

public struct CommandContext: @unchecked Sendable {
    public let fileSystem: VirtualFileSystem
    public let cwd: String
    public let environment: [String: String]
    public let stdin: String
    public let executeSubshell: SubshellExecutor?

    public init(
        fileSystem: VirtualFileSystem,
        cwd: String,
        environment: [String: String],
        stdin: String,
        executeSubshell: SubshellExecutor? = nil
    ) {
        self.fileSystem = fileSystem
        self.cwd = cwd
        self.environment = environment
        self.stdin = stdin
        self.executeSubshell = executeSubshell
    }
}

public struct AnyBashCommand: @unchecked Sendable {
    public let name: String
    public let execute: CommandHandler

    public init(name: String, execute: @escaping CommandHandler) {
        self.name = name
        self.execute = execute
    }
}

public final class CommandRegistry: @unchecked Sendable {
    private var commands: [String: AnyBashCommand] = [:]

    public init(commands: [AnyBashCommand] = []) {
        for command in commands {
            register(command)
        }
    }

    public func register(_ command: AnyBashCommand) {
        commands[command.name] = command
    }

    public func command(named name: String) -> AnyBashCommand? {
        commands[name]
    }

    public func contains(_ name: String) -> Bool {
        commands[name] != nil
    }

    public var names: [String] {
        commands.keys.sorted()
    }

    public static func builtins() -> CommandRegistry {
        CommandRegistry(commands: builtinCommands())
    }

    public static func builtinCommands() -> [AnyBashCommand] {
        [
            // Core I/O
            cat(), tee(),
            // File operations
            ls(), mkdir(), touch(), rm(), rmdir(), cp(), mv(), ln(), chmod(), stat(), tree(), split(),
            // File info
            find(), du(), realpath(), readlink(), basename(), dirname(), file(), strings(),
            // Text processing
            grep(), egrep(), fgrep(), rg(), sed(), awk(), sort(), uniq(), tr(), cut(), paste(), join(),
            wc(), head(), tail(), tac(), rev(), nl(), fold(), expand(), unexpand(), column(), od(),
            // Data
            seq(), yes(), base64(), expr(), md5sum(), sha1sum(), sha256sum(), gzip(), gunzip(), zcat(), tar(), sqlite3(), jq(), yq(),
            // Misc
            xargs(), diff(), comm(), date(), sleep_(), uname(), hostname(), whoami(), clear(), help(), history(), bash(), sh(), time(), timeout(), curl(), htmlToMarkdown(),
        ]
    }
}

// MARK: - Core I/O

private func cat() -> AnyBashCommand {
    AnyBashCommand(name: "cat") { args, ctx in
        var showLineNumbers = false
        var showEnds = false
        var paths: [String] = []
        for arg in args {
            switch arg {
            case "-n": showLineNumbers = true
            case "-E": showEnds = true
            case "-b": showLineNumbers = true // non-blank
            default: paths.append(arg)
            }
        }
        do {
            let content: String
            if paths.isEmpty {
                content = ctx.stdin
            } else {
                content = try paths.map { path -> String in
                    if path == "-" { return ctx.stdin }
                    return try ctx.fileSystem.readFile(path, relativeTo: ctx.cwd)
                }.joined()
            }
            if showLineNumbers {
                let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
                let numbered = lines.enumerated().map { (i, line) in
                    let suffix = showEnds ? "\(line)$" : String(line)
                    return String(format: "%6d\t%@", i + 1, suffix)
                }
                return ExecResult.success(numbered.joined(separator: "\n") + (content.hasSuffix("\n") ? "\n" : ""))
            }
            return ExecResult.success(content)
        } catch {
            return ExecResult.failure("cat: \(error.localizedDescription)")
        }
    }
}

private func tee() -> AnyBashCommand {
    AnyBashCommand(name: "tee") { args, ctx in
        var appendMode = false
        var files: [String] = []
        for arg in args {
            if arg == "-a" { appendMode = true }
            else { files.append(arg) }
        }
        for file in files {
            do {
                try ctx.fileSystem.writeFile(ctx.stdin, to: file, relativeTo: ctx.cwd, append: appendMode)
            } catch {
                return ExecResult.failure("tee: \(error.localizedDescription)")
            }
        }
        return ExecResult.success(ctx.stdin)
    }
}

// MARK: - File Operations

private func ls() -> AnyBashCommand {
    AnyBashCommand(name: "ls") { args, ctx in
        var includeHidden = false
        var longFormat = false
        let filtered = args.filter { arg in
            for ch in arg.dropFirst() where arg.hasPrefix("-") {
                switch ch {
                case "a": includeHidden = true
                case "l": longFormat = true
                default: break
                }
            }
            return !arg.hasPrefix("-")
        }
        let targets = filtered.isEmpty ? [ctx.cwd] : filtered
        do {
            var lines: [String] = []
            for (index, target) in targets.enumerated() {
                let path = VirtualPath.normalize(target, relativeTo: ctx.cwd)
                let info = try ctx.fileSystem.fileInfo(path)
                if info.kind == .directory {
                    let entries = try ctx.fileSystem.listDirectory(path, includeHidden: includeHidden)
                    if targets.count > 1 {
                        if index > 0 { lines.append("") }
                        lines.append("\(path):")
                    }
                    for entry in entries {
                        if longFormat {
                            let eInfo = try? ctx.fileSystem.fileInfo(entry.path)
                            let kind = entry.isDirectory ? "d" : "-"
                            let size = eInfo?.size ?? 0
                            lines.append("\(kind)rwxr-xr-x 1 user user \(size) Jan  1 00:00 \(entry.name)")
                        } else {
                            lines.append(entry.name)
                        }
                    }
                } else {
                    lines.append(VirtualPath.basename(path))
                }
            }
            return ExecResult.success(lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n"))
        } catch {
            return ExecResult.failure("ls: \(error.localizedDescription)")
        }
    }
}

private func mkdir() -> AnyBashCommand {
    AnyBashCommand(name: "mkdir") { args, ctx in
        var recursive = false
        let paths = args.filter { arg in
            if arg == "-p" { recursive = true; return false }
            return !arg.hasPrefix("-")
        }
        guard !paths.isEmpty else { return ExecResult.failure("mkdir: missing operand") }
        do {
            for path in paths {
                try ctx.fileSystem.createDirectory(path, relativeTo: ctx.cwd, recursive: recursive)
            }
            return ExecResult.success()
        } catch {
            return ExecResult.failure("mkdir: \(error.localizedDescription)")
        }
    }
}

private func touch() -> AnyBashCommand {
    AnyBashCommand(name: "touch") { args, ctx in
        guard !args.isEmpty else { return ExecResult.failure("touch: missing file operand") }
        do {
            for path in args where !path.hasPrefix("-") {
                if ctx.fileSystem.exists(path, relativeTo: ctx.cwd) {
                    let content = (try? ctx.fileSystem.readFile(path, relativeTo: ctx.cwd)) ?? ""
                    try ctx.fileSystem.writeFile(content, to: path, relativeTo: ctx.cwd)
                } else {
                    try ctx.fileSystem.writeFile("", to: path, relativeTo: ctx.cwd)
                }
            }
            return ExecResult.success()
        } catch {
            return ExecResult.failure("touch: \(error.localizedDescription)")
        }
    }
}

private func rm() -> AnyBashCommand {
    AnyBashCommand(name: "rm") { args, ctx in
        var recursive = false
        var force = false
        let paths = args.filter { arg in
            if arg.hasPrefix("-") {
                for ch in arg.dropFirst() {
                    switch ch {
                    case "r", "R": recursive = true
                    case "f": force = true
                    default: break
                    }
                }
                return false
            }
            return true
        }
        guard !paths.isEmpty else {
            if force { return ExecResult.success() }
            return ExecResult.failure("rm: missing operand")
        }
        do {
            for path in paths {
                try ctx.fileSystem.removeItem(path, relativeTo: ctx.cwd, recursive: recursive, force: force)
            }
            return ExecResult.success()
        } catch {
            return ExecResult.failure("rm: \(error.localizedDescription)")
        }
    }
}

private func rmdir() -> AnyBashCommand {
    AnyBashCommand(name: "rmdir") { args, ctx in
        let paths = args.filter { !$0.hasPrefix("-") }
        guard !paths.isEmpty else { return ExecResult.failure("rmdir: missing operand") }
        do {
            for path in paths {
                let normalized = VirtualPath.normalize(path, relativeTo: ctx.cwd)
                guard ctx.fileSystem.isDirectory(normalized) else {
                    return ExecResult.failure("rmdir: not a directory: \(path)")
                }
                try ctx.fileSystem.removeItem(path, relativeTo: ctx.cwd, recursive: false, force: false)
            }
            return ExecResult.success()
        } catch {
            return ExecResult.failure("rmdir: \(error.localizedDescription)")
        }
    }
}

private func cp() -> AnyBashCommand {
    AnyBashCommand(name: "cp") { args, ctx in
        let filtered = args.filter { arg in
            // -r/-R/-a flags accepted but copy is always recursive in virtual FS
            return !arg.hasPrefix("-")
        }
        guard filtered.count >= 2 else { return ExecResult.failure("cp: missing file operand") }
        let dest = filtered.last!
        let sources = filtered.dropLast()
        do {
            for source in sources {
                try ctx.fileSystem.copyItem(from: source, to: dest, relativeTo: ctx.cwd)
            }
            return ExecResult.success()
        } catch {
            return ExecResult.failure("cp: \(error.localizedDescription)")
        }
    }
}

private func mv() -> AnyBashCommand {
    AnyBashCommand(name: "mv") { args, ctx in
        let filtered = args.filter { !$0.hasPrefix("-") }
        guard filtered.count >= 2 else { return ExecResult.failure("mv: missing file operand") }
        let dest = filtered.last!
        let sources = filtered.dropLast()
        do {
            for source in sources {
                try ctx.fileSystem.moveItem(from: source, to: dest, relativeTo: ctx.cwd)
            }
            return ExecResult.success()
        } catch {
            return ExecResult.failure("mv: \(error.localizedDescription)")
        }
    }
}

private func ln() -> AnyBashCommand {
    AnyBashCommand(name: "ln") { args, ctx in
        var symbolic = false
        var force = false
        let filtered = args.filter { arg in
            if arg.hasPrefix("-") {
                for ch in arg.dropFirst() {
                    if ch == "s" { symbolic = true }
                    if ch == "f" { force = true }
                }
                return false
            }
            return true
        }
        guard filtered.count >= 2 else { return ExecResult.failure("ln: missing file operand") }
        do {
            if symbolic {
                if force { try? ctx.fileSystem.removeItem(filtered[1], relativeTo: ctx.cwd, recursive: false, force: true) }
                try ctx.fileSystem.createSymlink(filtered[0], at: filtered[1], relativeTo: ctx.cwd)
            } else {
                try ctx.fileSystem.copyItem(from: filtered[0], to: filtered[1], relativeTo: ctx.cwd)
            }
            return ExecResult.success()
        } catch {
            return ExecResult.failure("ln: \(error.localizedDescription)")
        }
    }
}

private func chmod() -> AnyBashCommand {
    AnyBashCommand(name: "chmod") { args, ctx in
        let filtered = args.filter { !$0.hasPrefix("-") }
        guard filtered.count >= 2 else { return ExecResult.failure("chmod: missing operand") }
        // Simplified: just accept but don't really change permissions
        return ExecResult.success()
    }
}

private func stat() -> AnyBashCommand {
    AnyBashCommand(name: "stat") { args, ctx in
        let filtered = args.filter { !$0.hasPrefix("-") }
        guard let path = filtered.first else { return ExecResult.failure("stat: missing operand") }
        do {
            let info = try ctx.fileSystem.fileInfo(path, relativeTo: ctx.cwd)
            let lines = [
                "  File: \(path)",
                "  Size: \(info.size)\tBlocks: 0\tIO Block: 4096\t\(info.kind == .directory ? "directory" : "regular file")",
            ]
            return ExecResult.success(lines.joined(separator: "\n") + "\n")
        } catch {
            return ExecResult.failure("stat: \(error.localizedDescription)")
        }
    }
}

private func tree() -> AnyBashCommand {
    AnyBashCommand(name: "tree") { args, ctx in
        let target = args.first(where: { !$0.hasPrefix("-") }) ?? "."
        let path = VirtualPath.normalize(target, relativeTo: ctx.cwd)
        guard ctx.fileSystem.exists(path) else { return ExecResult.failure("tree: no such file or directory: \(target)") }

        var lines: [String] = [VirtualPath.basename(path)]

        func walk(_ current: String, prefix: String) {
            guard let entries = try? ctx.fileSystem.listDirectory(current, includeHidden: false) else { return }
            for (index, entry) in entries.enumerated() {
                let isLast = index == entries.count - 1
                let branch = isLast ? "`-- " : "|-- "
                lines.append(prefix + branch + entry.name)
                if entry.isDirectory {
                    walk(entry.path, prefix: prefix + (isLast ? "    " : "|   "))
                }
            }
        }

        if ctx.fileSystem.isDirectory(path) {
            walk(path, prefix: "")
        }

        return ExecResult.success(lines.joined(separator: "\n") + "\n")
    }
}

// MARK: - File Info

private func find() -> AnyBashCommand {
    AnyBashCommand(name: "find") { args, ctx in
        var start = "."
        var nameFilter: String?
        var typeFilter: String?
        var maxDepth = Int.max
        var index = 0
        if index < args.count && !args[index].hasPrefix("-") {
            start = args[index]; index += 1
        }
        while index < args.count {
            switch args[index] {
            case "-name": if index + 1 < args.count { nameFilter = args[index + 1]; index += 2 } else { index += 1 }
            case "-type": if index + 1 < args.count { typeFilter = args[index + 1]; index += 2 } else { index += 1 }
            case "-maxdepth": if index + 1 < args.count { maxDepth = Int(args[index + 1]) ?? Int.max; index += 2 } else { index += 1 }
            default: index += 1
            }
        }
        do {
            let paths = try ctx.fileSystem.walk(start, relativeTo: ctx.cwd)
            let basePath = VirtualPath.normalize(start, relativeTo: ctx.cwd)
            let filtered = paths.filter { path in
                // Depth check
                let relative = path.hasPrefix(basePath) ? String(path.dropFirst(basePath.count)) : path
                let depth = relative.split(separator: "/").count
                if depth > maxDepth { return false }
                // Name check
                if let filter = nameFilter {
                    if !VirtualFileSystem.globMatch(name: VirtualPath.basename(path), pattern: filter) { return false }
                }
                // Type check
                if let type = typeFilter {
                    switch type {
                    case "f": if ctx.fileSystem.isDirectory(path) { return false }
                    case "d": if !ctx.fileSystem.isDirectory(path) { return false }
                    default: break
                    }
                }
                return true
            }
            return ExecResult.success(filtered.joined(separator: "\n") + (filtered.isEmpty ? "" : "\n"))
        } catch {
            return ExecResult.failure("find: \(error.localizedDescription)")
        }
    }
}

private func du() -> AnyBashCommand {
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

private func realpath() -> AnyBashCommand {
    AnyBashCommand(name: "realpath") { args, ctx in
        let filtered = args.filter { !$0.hasPrefix("-") }
        guard let path = filtered.first else { return ExecResult.failure("realpath: missing operand") }
        return ExecResult.success(VirtualPath.normalize(path, relativeTo: ctx.cwd) + "\n")
    }
}

private func readlink() -> AnyBashCommand {
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

private func basename() -> AnyBashCommand {
    AnyBashCommand(name: "basename") { args, ctx in
        guard let path = args.first else { return ExecResult.failure("basename: missing operand") }
        var name = VirtualPath.basename(path)
        if args.count > 1 {
            let suffix = args[1]
            if name.hasSuffix(suffix) && name != suffix {
                name = String(name.dropLast(suffix.count))
            }
        }
        return ExecResult.success(name + "\n")
    }
}

private func dirname() -> AnyBashCommand {
    AnyBashCommand(name: "dirname") { args, ctx in
        guard let path = args.first else { return ExecResult.failure("dirname: missing operand") }
        return ExecResult.success(VirtualPath.dirname(path) + "\n")
    }
}

private func file() -> AnyBashCommand {
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

private func strings() -> AnyBashCommand {
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

// MARK: - Text Processing

private func grep() -> AnyBashCommand {
    AnyBashCommand(name: "grep") { args, ctx in
        var lineNumbers = false
        var caseInsensitive = false
        var invert = false
        var countOnly = false
        var filesOnly = false
        var recursive = false
        var fixedStrings = false
        var maxCount = Int.max
        var remaining = args

        while !remaining.isEmpty {
            let arg = remaining[0]
            if !arg.hasPrefix("-") || arg == "-" { break }
            if arg == "--" { remaining.removeFirst(); break }
            remaining.removeFirst()
            if arg == "-m" { if !remaining.isEmpty { maxCount = Int(remaining.removeFirst()) ?? Int.max }; continue }
            if arg == "-e" { break } // next arg is pattern
            for ch in arg.dropFirst() {
                switch ch {
                case "n": lineNumbers = true
                case "i": caseInsensitive = true
                case "v": invert = true
                case "c": countOnly = true
                case "l": filesOnly = true
                case "r", "R": recursive = true
                case "F": fixedStrings = true
                case "E": break // extended regex (default)
                case "H": break // print filename
                case "h": break // suppress filename
                default: break
                }
            }
        }

        guard let pattern = remaining.first else { return ExecResult.failure("grep: missing pattern") }
        let paths = Array(remaining.dropFirst())

        let regex: NSRegularExpression?
        if fixedStrings {
            regex = try? NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: pattern),
                                             options: caseInsensitive ? [.caseInsensitive] : [])
        } else {
            regex = try? NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
        }
        guard let regex else { return ExecResult.failure("grep: invalid pattern") }

        let sources: [(String?, String)]
        do {
            if paths.isEmpty {
                sources = [(nil, ctx.stdin)]
            } else {
                var collected: [(String?, String)] = []
                for path in paths {
                    let normalized = VirtualPath.normalize(path, relativeTo: ctx.cwd)
                    if recursive && ctx.fileSystem.isDirectory(normalized) {
                        let walked = (try? ctx.fileSystem.walk(path, relativeTo: ctx.cwd)) ?? []
                        for child in walked {
                            if !ctx.fileSystem.isDirectory(child) {
                                if let content = try? ctx.fileSystem.readFile(child) {
                                    collected.append((child, content))
                                }
                            }
                        }
                    } else {
                        collected.append((path, try ctx.fileSystem.readFile(path, relativeTo: ctx.cwd)))
                    }
                }
                sources = collected
            }
        } catch {
            return ExecResult.failure("grep: \(error.localizedDescription)")
        }

        var output: [String] = []
        var matchCount = 0
        var matchedFiles: Set<String> = []
        let multiFile = sources.count > 1

        for (label, content) in sources {
            var fileCount = 0
            let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
            for (index, line) in lines.enumerated() {
                if matchCount >= maxCount { break }
                let string = String(line)
                let range = NSRange(location: 0, length: string.utf16.count)
                let hasMatch = regex.firstMatch(in: string, range: range) != nil
                if hasMatch == invert { continue }

                matchCount += 1
                fileCount += 1
                if filesOnly {
                    if let label { matchedFiles.insert(label) }
                    break
                }
                if !countOnly {
                    var rendered = string
                    if lineNumbers { rendered = "\(index + 1):\(rendered)" }
                    if let label, multiFile { rendered = "\(label):\(rendered)" }
                    output.append(rendered)
                }
            }
            if countOnly {
                if let label, multiFile {
                    output.append("\(label):\(fileCount)")
                } else {
                    output.append("\(fileCount)")
                }
            }
        }

        if filesOnly {
            output = matchedFiles.sorted()
        }

        if output.isEmpty && !countOnly { return ExecResult(stdout: "", stderr: "", exitCode: 1) }
        return ExecResult.success(output.joined(separator: "\n") + "\n")
    }
}

private func egrep() -> AnyBashCommand {
    AnyBashCommand(name: "egrep") { args, ctx in
        await grep().execute(args, ctx)
    }
}

private func fgrep() -> AnyBashCommand {
    AnyBashCommand(name: "fgrep") { args, ctx in
        await grep().execute(["-F"] + args, ctx)
    }
}

private func rg() -> AnyBashCommand {
    AnyBashCommand(name: "rg") { args, ctx in
        await grep().execute(["-r"] + args, ctx)
    }
}

private func sed() -> AnyBashCommand {
    AnyBashCommand(name: "sed") { args, ctx in
        var inPlace = false
        var scripts: [String] = []
        var files: [String] = []
        var i = 0
        while i < args.count {
            switch args[i] {
            case "-i": inPlace = true; i += 1
            case "-e": if i + 1 < args.count { scripts.append(args[i + 1]); i += 2 } else { i += 1 }
            case "-n": i += 1 // suppress auto-print (simplified)
            default:
                if scripts.isEmpty && !args[i].hasPrefix("-") && files.isEmpty {
                    scripts.append(args[i])
                } else {
                    files.append(args[i])
                }
                i += 1
            }
        }

        let content: String
        do {
            if files.isEmpty {
                content = ctx.stdin
            } else {
                content = try files.map { try ctx.fileSystem.readFile($0, relativeTo: ctx.cwd) }.joined()
            }
        } catch {
            return ExecResult.failure("sed: \(error.localizedDescription)")
        }

        var result = content
        for script in scripts {
            result = applySedScript(script, to: result)
        }

        if inPlace && !files.isEmpty {
            for file in files {
                try? ctx.fileSystem.writeFile(result, to: file, relativeTo: ctx.cwd)
            }
            return ExecResult.success()
        }
        return ExecResult.success(result)
    }
}

private func applySedScript(_ script: String, to input: String) -> String {
    let chars = Array(script)
    guard chars.count >= 2 else { return input }

    // Handle s/pattern/replacement/flags
    if chars[0] == "s" {
        let delim = chars[1]
        var parts: [String] = []
        var current = ""
        var i = 2
        while i < chars.count && parts.count < 3 {
            if chars[i] == delim {
                parts.append(current); current = ""; i += 1
            } else if chars[i] == "\\" && i + 1 < chars.count {
                current.append(chars[i + 1]); i += 2
            } else {
                current.append(chars[i]); i += 1
            }
        }
        if parts.count < 2 { parts.append(current) }
        if parts.count < 3 { parts.append(current) }

        let pattern = parts[0]
        let replacement = parts[1]
        let flags = parts.count > 2 ? parts[2] : ""
        let globalReplace = flags.contains("g")

        let lines = input.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let processed = lines.map { line -> String in
            do {
                let regex = try NSRegularExpression(pattern: pattern)
                let range = NSRange(line.startIndex..., in: line)
                // Convert sed replacement syntax (\1, &) to NSRegularExpression syntax ($1, $0)
                let nsReplacement = replacement
                    .replacingOccurrences(of: "\\\\", with: "<<BACKSLASH>>")
                    .replacingOccurrences(of: "&", with: "$0")
                    .replacingOccurrences(of: "<<BACKSLASH>>", with: "\\\\")
                if globalReplace {
                    return regex.stringByReplacingMatches(in: line, range: range, withTemplate: nsReplacement)
                } else {
                    guard let match = regex.firstMatch(in: line, range: range) else { return line }
                    return regex.stringByReplacingMatches(in: line, range: match.range, withTemplate: nsReplacement)
                }
            } catch {
                return line
            }
        }
        return processed.joined(separator: "\n")
    }

    // Handle d (delete lines matching pattern)
    if let slashIdx = script.firstIndex(of: "/"), script.hasSuffix("/d") {
        let pattern = String(script[script.index(after: slashIdx)..<script.index(script.endIndex, offsetBy: -2)])
        let lines = input.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let filtered = lines.filter { line in
            let regex = try? NSRegularExpression(pattern: pattern)
            let range = NSRange(line.startIndex..., in: line)
            return regex?.firstMatch(in: line, range: range) == nil
        }
        return filtered.joined(separator: "\n") + (input.hasSuffix("\n") ? "\n" : "")
    }

    return input
}

private func awk() -> AnyBashCommand {
    AnyBashCommand(name: "awk") { args, ctx in
        var program = ""
        var fieldSep = " "
        var files: [String] = []
        var i = 0
        while i < args.count {
            switch args[i] {
            case "-F": if i + 1 < args.count { fieldSep = args[i + 1]; i += 2 } else { i += 1 }
            case "-f": i += 2 // skip file (not supported in simplified version)
            default:
                if program.isEmpty && !args[i].hasPrefix("-") {
                    program = args[i]
                } else {
                    files.append(args[i])
                }
                i += 1
            }
        }

        let content: String
        do {
            if files.isEmpty {
                content = ctx.stdin
            } else {
                content = try files.map { try ctx.fileSystem.readFile($0, relativeTo: ctx.cwd) }.joined()
            }
        } catch {
            return ExecResult.failure("awk: \(error.localizedDescription)")
        }

        // Simplified awk: handle common patterns
        // {print $N}, {print $N, $M}, BEGIN{}/END{}, /pattern/{action}
        return ExecResult.success(executeSimpleAwk(program: program, input: content, fieldSep: fieldSep))
    }
}

private func executeSimpleAwk(program: String, input: String, fieldSep: String) -> String {
    let lines = input.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var output: [String] = []

    // Parse simple program: {print ...} or /pattern/{print ...}
    let trimmed = program.trimmingCharacters(in: .whitespaces)

    // Handle simple {print $N} patterns
    var pattern: String? = nil
    var action = trimmed

    if trimmed.hasPrefix("/") {
        if let endSlash = trimmed.dropFirst().firstIndex(of: "/") {
            pattern = String(trimmed[trimmed.index(after: trimmed.startIndex)..<endSlash])
            action = String(trimmed[trimmed.index(after: endSlash)...]).trimmingCharacters(in: .whitespaces)
        }
    }

    // Remove { } wrapper
    if action.hasPrefix("{") && action.hasSuffix("}") {
        action = String(action.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
    }

    for (lineIdx, line) in lines.enumerated() {
        if line.isEmpty && lineIdx == lines.count - 1 && input.hasSuffix("\n") { continue }

        // Pattern match
        if let pat = pattern {
            let regex = try? NSRegularExpression(pattern: pat)
            let range = NSRange(line.startIndex..., in: line)
            if regex?.firstMatch(in: line, range: range) == nil { continue }
        }

        // Split fields
        let fields: [String]
        if fieldSep == " " {
            fields = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        } else {
            fields = line.components(separatedBy: fieldSep)
        }

        // Execute action
        if action.hasPrefix("print") {
            let printArgs = String(action.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            if printArgs.isEmpty {
                output.append(line)
            } else {
                // Parse print arguments
                let parts = parsePrintArgs(printArgs)
                var lineOutput = ""
                for (pIdx, part) in parts.enumerated() {
                    if part.hasPrefix("$") {
                        let numStr = String(part.dropFirst())
                        if let n = Int(numStr) {
                            if n == 0 { lineOutput += line }
                            else if n > 0 && n <= fields.count { lineOutput += fields[n - 1] }
                        } else if numStr == "NF" {
                            lineOutput += String(fields.count)
                        } else if numStr == "NR" {
                            lineOutput += String(lineIdx + 1)
                        }
                    } else if part == "NF" {
                        lineOutput += String(fields.count)
                    } else if part == "NR" {
                        lineOutput += String(lineIdx + 1)
                    } else if part.hasPrefix("\"") && part.hasSuffix("\"") {
                        lineOutput += String(part.dropFirst().dropLast())
                            .replacingOccurrences(of: "\\n", with: "\n")
                            .replacingOccurrences(of: "\\t", with: "\t")
                    } else {
                        lineOutput += part
                    }
                    if pIdx < parts.count - 1 && !lineOutput.hasSuffix(" ") {
                        // OFS
                        lineOutput += " "
                    }
                }
                output.append(lineOutput)
            }
        }
    }

    if output.isEmpty { return "" }
    return output.joined(separator: "\n") + "\n"
}

private func parsePrintArgs(_ args: String) -> [String] {
    var parts: [String] = []
    var current = ""
    var inQuote = false
    for ch in args {
        if ch == "\"" { inQuote.toggle(); current.append(ch); continue }
        if inQuote { current.append(ch); continue }
        if ch == "," || ch == " " {
            if !current.isEmpty { parts.append(current.trimmingCharacters(in: .whitespaces)); current = "" }
            continue
        }
        current.append(ch)
    }
    if !current.isEmpty { parts.append(current.trimmingCharacters(in: .whitespaces)) }
    return parts
}

private func sort() -> AnyBashCommand {
    AnyBashCommand(name: "sort") { args, ctx in
        var reverse = false
        var numeric = false
        var unique = false
        var key: Int? = nil
        var delimiter: Character? = nil
        var files: [String] = []
        var i = 0
        while i < args.count {
            switch args[i] {
            case "-r": reverse = true; i += 1
            case "-n": numeric = true; i += 1
            case "-u": unique = true; i += 1
            case "-k": if i + 1 < args.count { key = Int(args[i + 1].split(separator: ",").first ?? "") ?? Int(args[i + 1]); i += 2 } else { i += 1 }
            case "-t": if i + 1 < args.count { delimiter = args[i + 1].first; i += 2 } else { i += 1 }
            default: files.append(args[i]); i += 1
            }
        }

        let content: String
        do {
            if files.isEmpty { content = ctx.stdin }
            else { content = try files.map { try ctx.fileSystem.readFile($0, relativeTo: ctx.cwd) }.joined() }
        } catch {
            return ExecResult.failure("sort: \(error.localizedDescription)")
        }

        var lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }

        lines.sort { a, b in
            let aKey: String
            let bKey: String
            if let k = key {
                let delim = delimiter ?? Character(" ")
                let aFields = a.split(separator: delim, omittingEmptySubsequences: false).map(String.init)
                let bFields = b.split(separator: delim, omittingEmptySubsequences: false).map(String.init)
                aKey = k > 0 && k <= aFields.count ? aFields[k - 1] : a
                bKey = k > 0 && k <= bFields.count ? bFields[k - 1] : b
            } else {
                aKey = a; bKey = b
            }
            if numeric {
                return (Double(aKey.trimmingCharacters(in: .whitespaces)) ?? 0) < (Double(bKey.trimmingCharacters(in: .whitespaces)) ?? 0)
            }
            return aKey < bKey
        }

        if reverse { lines.reverse() }
        if unique { lines = Array(NSOrderedSet(array: lines)) as! [String] }

        if lines.isEmpty { return ExecResult.success() }
        return ExecResult.success(lines.joined(separator: "\n") + "\n")
    }
}

private func uniq() -> AnyBashCommand {
    AnyBashCommand(name: "uniq") { args, ctx in
        var countMode = false
        var duplicateOnly = false
        var unique = false
        var files: [String] = []
        for arg in args {
            switch arg {
            case "-c": countMode = true
            case "-d": duplicateOnly = true
            case "-u": unique = true
            default: files.append(arg)
            }
        }

        let content: String
        do {
            if files.isEmpty { content = ctx.stdin }
            else { content = try ctx.fileSystem.readFile(files[0], relativeTo: ctx.cwd) }
        } catch {
            return ExecResult.failure("uniq: \(error.localizedDescription)")
        }

        var lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }

        var output: [String] = []
        var i = 0
        while i < lines.count {
            var count = 1
            while i + count < lines.count && lines[i] == lines[i + count] { count += 1 }
            if duplicateOnly && count == 1 { i += count; continue }
            if unique && count > 1 { i += count; continue }
            if countMode {
                output.append(String(format: "%7d %@", count, lines[i]))
            } else {
                output.append(lines[i])
            }
            i += count
        }

        if output.isEmpty { return ExecResult.success() }
        return ExecResult.success(output.joined(separator: "\n") + "\n")
    }
}

private func tr() -> AnyBashCommand {
    AnyBashCommand(name: "tr") { args, ctx in
        var delete = false
        var squeeze = false
        var remaining = args
        while let first = remaining.first, first.hasPrefix("-") {
            for ch in first.dropFirst() {
                if ch == "d" { delete = true }
                if ch == "s" { squeeze = true }
            }
            remaining.removeFirst()
        }

        if delete {
            guard let set = remaining.first else { return ExecResult.failure("tr: missing operand") }
            let chars = expandTrSet(set)
            let result = String(ctx.stdin.filter { !chars.contains($0) })
            return ExecResult.success(result)
        }

        guard remaining.count >= 2 else {
            return ExecResult.failure("tr: missing operand")
        }
        let set1 = expandTrSet(remaining[0])
        let set2 = expandTrSet(remaining[1])

        var mapping: [Character: Character] = [:]
        for (i, ch) in set1.enumerated() {
            let replacement = i < set2.count ? set2[set2.index(set2.startIndex, offsetBy: i)] : set2.last!
            mapping[ch] = replacement
        }

        var result = ""
        var lastChar: Character?
        for ch in ctx.stdin {
            let mapped = mapping[ch] ?? ch
            if squeeze && mapped == lastChar && set2.contains(mapped) { continue }
            result.append(mapped)
            lastChar = mapped
        }

        return ExecResult.success(result)
    }
}

private func expandTrSet(_ set: String) -> [Character] {
    var chars: [Character] = []
    var i = set.startIndex
    while i < set.endIndex {
        if set[i] == "\\" && set.index(after: i) < set.endIndex {
            let next = set[set.index(after: i)]
            switch next {
            case "n": chars.append("\n")
            case "t": chars.append("\t")
            case "r": chars.append("\r")
            case "\\": chars.append("\\")
            default: chars.append(next)
            }
            i = set.index(i, offsetBy: 2)
        } else if set.index(i, offsetBy: 2, limitedBy: set.endIndex) != nil &&
                    set.index(i, offsetBy: 2) < set.endIndex &&
                    set[set.index(after: i)] == "-" {
            let start = set[i]
            let end = set[set.index(i, offsetBy: 2)]
            if start <= end {
                for code in start.asciiValue!...end.asciiValue! {
                    chars.append(Character(UnicodeScalar(code)))
                }
            }
            i = set.index(i, offsetBy: 3)
        } else if set[i...].hasPrefix("[:upper:]") {
            chars.append(contentsOf: "ABCDEFGHIJKLMNOPQRSTUVWXYZ")
            i = set.index(i, offsetBy: 9)
        } else if set[i...].hasPrefix("[:lower:]") {
            chars.append(contentsOf: "abcdefghijklmnopqrstuvwxyz")
            i = set.index(i, offsetBy: 9)
        } else if set[i...].hasPrefix("[:digit:]") {
            chars.append(contentsOf: "0123456789")
            i = set.index(i, offsetBy: 9)
        } else if set[i...].hasPrefix("[:space:]") {
            chars.append(contentsOf: " \t\n\r")
            i = set.index(i, offsetBy: 9)
        } else if set[i...].hasPrefix("[:alpha:]") {
            chars.append(contentsOf: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
            i = set.index(i, offsetBy: 9)
        } else {
            chars.append(set[i])
            i = set.index(after: i)
        }
    }
    return chars
}

private func cut() -> AnyBashCommand {
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

private func paste() -> AnyBashCommand {
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

private func join() -> AnyBashCommand {
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

private func wc() -> AnyBashCommand {
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
            let content: String
            let label: String
            if paths.isEmpty {
                content = ctx.stdin; label = ""
            } else {
                content = try ctx.fileSystem.readFile(paths[0], relativeTo: ctx.cwd)
                label = " \(paths[0])"
            }
            let lines = content.isEmpty ? 0 : content.split(separator: "\n", omittingEmptySubsequences: false).count - (content.hasSuffix("\n") ? 1 : 0)
            let words = content.split(whereSeparator: \.isWhitespace).count
            let bytes = content.utf8.count
            let chars = content.count
            let output: String
            switch (lineOnly, wordOnly, byteOnly, charOnly) {
            case (true, false, false, false): output = "\(lines)\(label)\n"
            case (false, true, false, false): output = "\(words)\(label)\n"
            case (false, false, true, false): output = "\(bytes)\(label)\n"
            case (false, false, false, true): output = "\(chars)\(label)\n"
            default: output = "\(lines) \(words) \(bytes)\(label)\n"
            }
            return ExecResult.success(output)
        } catch {
            return ExecResult.failure("wc: \(error.localizedDescription)")
        }
    }
}

private func head() -> AnyBashCommand {
    AnyBashCommand(name: "head") { args, ctx in
        runLineSlicer(command: "head", args: args, ctx: ctx, tailMode: false)
    }
}

private func tail() -> AnyBashCommand {
    AnyBashCommand(name: "tail") { args, ctx in
        runLineSlicer(command: "tail", args: args, ctx: ctx, tailMode: true)
    }
}

private func tac() -> AnyBashCommand {
    AnyBashCommand(name: "tac") { args, ctx in
        let content: String
        do {
            if args.isEmpty { content = ctx.stdin }
            else { content = try args.map { try ctx.fileSystem.readFile($0, relativeTo: ctx.cwd) }.joined() }
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
        else { content = try paths.map { try ctx.fileSystem.readFile($0, relativeTo: ctx.cwd) }.joined() }
    } catch {
        return ExecResult.failure("\(command): \(error.localizedDescription)")
    }

    let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let slice = tailMode ? Array(lines.suffix(count)) : Array(lines.prefix(count))
    let joined = slice.joined(separator: "\n")
    if joined.isEmpty { return ExecResult.success() }
    return ExecResult.success(joined + (content.hasSuffix("\n") || slice.count < lines.count ? "\n" : ""))
}

private func rev() -> AnyBashCommand {
    AnyBashCommand(name: "rev") { args, ctx in
        let content: String
        do {
            if args.isEmpty { content = ctx.stdin }
            else { content = try args.map { try ctx.fileSystem.readFile($0, relativeTo: ctx.cwd) }.joined() }
        } catch {
            return ExecResult.failure("rev: \(error.localizedDescription)")
        }
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map { String($0.reversed()) }
        return ExecResult.success(lines.joined(separator: "\n"))
    }
}

private func nl() -> AnyBashCommand {
    AnyBashCommand(name: "nl") { args, ctx in
        let content: String
        do {
            if args.isEmpty || args.allSatisfy({ $0.hasPrefix("-") }) { content = ctx.stdin }
            else { content = try ctx.fileSystem.readFile(args.last!, relativeTo: ctx.cwd) }
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

private func fold() -> AnyBashCommand {
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
            else { content = try files.map { try ctx.fileSystem.readFile($0, relativeTo: ctx.cwd) }.joined() }
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

private func expand() -> AnyBashCommand {
    AnyBashCommand(name: "expand") { args, ctx in
        let content: String
        do {
            let files = args.filter { !$0.hasPrefix("-") }
            if files.isEmpty { content = ctx.stdin }
            else { content = try files.map { try ctx.fileSystem.readFile($0, relativeTo: ctx.cwd) }.joined() }
        } catch {
            return ExecResult.failure("expand: \(error.localizedDescription)")
        }
        return ExecResult.success(content.replacingOccurrences(of: "\t", with: "        "))
    }
}

private func unexpand() -> AnyBashCommand {
    AnyBashCommand(name: "unexpand") { args, ctx in
        let content: String
        do {
            let files = args.filter { !$0.hasPrefix("-") }
            if files.isEmpty { content = ctx.stdin }
            else { content = try files.map { try ctx.fileSystem.readFile($0, relativeTo: ctx.cwd) }.joined() }
        } catch {
            return ExecResult.failure("unexpand: \(error.localizedDescription)")
        }
        return ExecResult.success(content.replacingOccurrences(of: "        ", with: "\t"))
    }
}

private func column() -> AnyBashCommand {
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
            else { content = try files.map { try ctx.fileSystem.readFile($0, relativeTo: ctx.cwd) }.joined() }
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

private func od() -> AnyBashCommand {
    AnyBashCommand(name: "od") { args, ctx in
        let files = args.filter { !$0.hasPrefix("-") }
        let content: String
        do {
            if files.isEmpty { content = ctx.stdin }
            else { content = try files.map { try ctx.fileSystem.readFile($0, relativeTo: ctx.cwd) }.joined() }
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

// MARK: - Data

private func seq() -> AnyBashCommand {
    AnyBashCommand(name: "seq") { args, ctx in
        var separator = "\n"
        var nums: [Double] = []
        var i = 0
        while i < args.count {
            if args[i] == "-s" { if i + 1 < args.count { separator = args[i + 1]; i += 2 } else { i += 1 } }
            else { if let n = Double(args[i]) { nums.append(n) }; i += 1 }
        }
        let start: Double, end: Double, step: Double
        switch nums.count {
        case 1: start = 1; end = nums[0]; step = 1
        case 2: start = nums[0]; end = nums[1]; step = start <= end ? 1 : -1
        case 3: start = nums[0]; step = nums[1]; end = nums[2]
        default: return ExecResult.failure("seq: missing operand")
        }
        var values: [String] = []
        var current = start
        if step > 0 {
            while current <= end + 0.0001 { // floating point tolerance
                values.append(current == Double(Int(current)) ? String(Int(current)) : String(current))
                current += step
            }
        } else if step < 0 {
            while current >= end - 0.0001 {
                values.append(current == Double(Int(current)) ? String(Int(current)) : String(current))
                current += step
            }
        }
        return ExecResult.success(values.joined(separator: separator) + "\n")
    }
}

private func yes() -> AnyBashCommand {
    AnyBashCommand(name: "yes") { args, ctx in
        let text = args.isEmpty ? "y" : args.joined(separator: " ")
        // In a sandbox, just output a reasonable amount
        let output = (0..<100).map { _ in text }.joined(separator: "\n") + "\n"
        return ExecResult.success(output)
    }
}

private func base64() -> AnyBashCommand {
    AnyBashCommand(name: "base64") { args, ctx in
        let decode = args.contains("-d") || args.contains("--decode")
        let files = args.filter { !$0.hasPrefix("-") }
        let content: String
        do {
            if files.isEmpty { content = ctx.stdin }
            else { content = try files.map { try ctx.fileSystem.readFile($0, relativeTo: ctx.cwd) }.joined() }
        } catch {
            return ExecResult.failure("base64: \(error.localizedDescription)")
        }

        if decode {
            guard let data = Data(base64Encoded: content.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                return ExecResult.failure("base64: invalid input")
            }
            return ExecResult.success(String(decoding: data, as: UTF8.self))
        }

        let encoded = Data(content.utf8).base64EncodedString()
        return ExecResult.success(encoded + "\n")
    }
}

private func expr() -> AnyBashCommand {
    AnyBashCommand(name: "expr") { args, _ in
        guard !args.isEmpty else { return ExecResult.failure("expr: missing operand") }
        if args.count >= 3, let lhs = Int(args[0]), let rhs = Int(args[2]) {
            let op = args[1]
            switch op {
            case "+": return ExecResult.success("\(lhs + rhs)\n")
            case "-": return ExecResult.success("\(lhs - rhs)\n")
            case "*": return ExecResult.success("\(lhs * rhs)\n")
            case "/": return rhs == 0 ? ExecResult.failure("expr: division by zero") : ExecResult.success("\(lhs / rhs)\n")
            case "%": return rhs == 0 ? ExecResult.failure("expr: division by zero") : ExecResult.success("\(lhs % rhs)\n")
            case "=": return ExecResult.success(lhs == rhs ? "1\n" : "0\n")
            case "!=": return ExecResult.success(lhs != rhs ? "1\n" : "0\n")
            case "<": return ExecResult.success(lhs < rhs ? "1\n" : "0\n")
            case "<=": return ExecResult.success(lhs <= rhs ? "1\n" : "0\n")
            case ">": return ExecResult.success(lhs > rhs ? "1\n" : "0\n")
            case ">=": return ExecResult.success(lhs >= rhs ? "1\n" : "0\n")
            default: break
            }
        }
        return ExecResult.success(args.joined(separator: " ") + "\n")
    }
}

private func md5sum() -> AnyBashCommand {
    checksumCommand(name: "md5sum", hash: { data in
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    })
}

private func sha1sum() -> AnyBashCommand {
    checksumCommand(name: "sha1sum", hash: { data in
        Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
    })
}

private func sha256sum() -> AnyBashCommand {
    checksumCommand(name: "sha256sum", hash: { data in
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    })
}

private func gzip() -> AnyBashCommand {
    gzipFamilyCommand(name: "gzip", defaultDecompress: false, alwaysStdout: false)
}

private func gunzip() -> AnyBashCommand {
    gzipFamilyCommand(name: "gunzip", defaultDecompress: true, alwaysStdout: false)
}

private func zcat() -> AnyBashCommand {
    gzipFamilyCommand(name: "zcat", defaultDecompress: true, alwaysStdout: true)
}

private func tar() -> AnyBashCommand {
    AnyBashCommand(name: "tar") { args, ctx in
        var mode: Character?
        var archivePath: String?
        var verbose = false
        var gzipMode = false
        var changeDir: String?
        var stripComponents = 0
        var paths: [String] = []
        var index = 0

        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--help":
                return ExecResult.success(tarHelpText())
            case "-f":
                index += 1
                if index >= args.count { return ExecResult.failure("tar: option requires an argument -- f", exitCode: 2) }
                archivePath = args[index]
            case "-C":
                index += 1
                if index >= args.count { return ExecResult.failure("tar: option requires an argument -- C", exitCode: 2) }
                changeDir = args[index]
            case let option where option.hasPrefix("--strip-components="):
                stripComponents = Int(option.split(separator: "=").last ?? "") ?? 0
            case let option where option.hasPrefix("--strip="):
                stripComponents = Int(option.split(separator: "=").last ?? "") ?? 0
            case let option where option.hasPrefix("-"):
                let chars = Array(option.dropFirst())
                var shortIndex = 0
                while shortIndex < chars.count {
                    let ch = chars[shortIndex]
                    switch ch {
                    case "c", "t", "x":
                        if mode != nil, mode != ch {
                            return ExecResult.failure("tar: You may not specify more than one operation mode", exitCode: 2)
                        }
                        mode = ch
                    case "v":
                        verbose = true
                    case "z":
                        gzipMode = true
                    case "f":
                        if shortIndex + 1 < chars.count {
                            archivePath = String(chars[(shortIndex + 1)...])
                            shortIndex = chars.count
                            continue
                        }
                        index += 1
                        if index >= args.count {
                            return ExecResult.failure("tar: option requires an argument -- f", exitCode: 2)
                        }
                        archivePath = args[index]
                    default:
                        break
                    }
                    shortIndex += 1
                }
            default:
                paths.append(arg)
            }
            index += 1
        }

        guard let mode else {
            return ExecResult.failure("tar: You must specify one of -c, -r, -u, -x, or -t", exitCode: 2)
        }
        guard let archivePath else {
            return ExecResult.failure("tar: option requires an argument -- f", exitCode: 2)
        }

        do {
            switch mode {
            case "c":
                guard !paths.isEmpty else {
                    return ExecResult.failure("tar: Cowardly refusing to create an empty archive", exitCode: 2)
                }
                let entries = try buildTarEntries(paths: paths, changeDir: changeDir, ctx: ctx)
                var data = buildTarArchive(entries)
                if gzipMode {
                    data = try gzipData(data)
                }
                try ctx.fileSystem.writeFile(stringFromVirtualData(data, preferUTF8: false), to: archivePath, relativeTo: ctx.cwd)
                let stderr = verbose ? entries.map(\.name).joined(separator: "\n") + (entries.isEmpty ? "" : "\n") : ""
                return ExecResult(stdout: "", stderr: stderr, exitCode: 0)
            case "t":
                let data = try loadTarArchiveData(path: archivePath, relativeTo: ctx.cwd, fileSystem: ctx.fileSystem)
                let entries = try parseTarArchive(data)
                let listed = filterTarEntries(entries, paths: paths, stripComponents: 0).map(\.name)
                return ExecResult.success(listed.joined(separator: "\n") + (listed.isEmpty ? "" : "\n"))
            case "x":
                let data = try loadTarArchiveData(path: archivePath, relativeTo: ctx.cwd, fileSystem: ctx.fileSystem)
                let entries = try parseTarArchive(data)
                let filtered = filterTarEntries(entries, paths: paths, stripComponents: stripComponents)
                let targetBase = VirtualPath.normalize(changeDir ?? ctx.cwd, relativeTo: ctx.cwd)
                if !ctx.fileSystem.isDirectory(targetBase) {
                    try ctx.fileSystem.createDirectory(targetBase, recursive: true)
                }
                for entry in filtered {
                    let dest = targetBase == "/" ? "/\(entry.name)" : "\(targetBase)/\(entry.name)"
                    if entry.isDirectory {
                        try ctx.fileSystem.createDirectory(dest, recursive: true)
                    } else {
                        try ctx.fileSystem.createDirectory(VirtualPath.dirname(dest), recursive: true)
                        try ctx.fileSystem.writeFile(stringFromVirtualData(entry.data, preferUTF8: false), to: dest)
                    }
                }
                let stderr = verbose ? filtered.map(\.name).joined(separator: "\n") + (filtered.isEmpty ? "" : "\n") : ""
                return ExecResult(stdout: "", stderr: stderr, exitCode: 0)
            default:
                return ExecResult.failure("tar: unsupported operation", exitCode: 2)
            }
        } catch {
            let message = (error as NSError).localizedDescription
            let exitCode = message.contains("Cannot open") || message.contains("Cowardly") ? 2 : 1
            return ExecResult.failure("tar: \(message)", exitCode: exitCode)
        }
    }
}

private func sqlite3() -> AnyBashCommand {
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

        if !useMemory, ctx.fileSystem.exists(databaseArg, relativeTo: ctx.cwd) {
            do {
                let stored = try ctx.fileSystem.readFile(databaseArg, relativeTo: ctx.cwd)
                try dataFromVirtualString(stored, treatAsBinary: true).write(to: tempURL)
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
                    try ctx.fileSystem.writeFile(stringFromVirtualData(data, preferUTF8: false), to: databaseArg, relativeTo: ctx.cwd)
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
                try ctx.fileSystem.writeFile(stringFromVirtualData(data, preferUTF8: false), to: databaseArg, relativeTo: ctx.cwd)
            }
            return result
        } catch {
            return ExecResult(stdout: "Error: \(error.localizedDescription)\n", stderr: "", exitCode: 0)
        }
    }
}

private func jq() -> AnyBashCommand {
    AnyBashCommand(name: "jq") { args, ctx in
        var rawOutput = false
        var compact = false
        var filter: String?
        var files: [String] = []

        for arg in args {
            switch arg {
            case "--help":
                return ExecResult.success("jq FILTER [FILE]\n  -c   compact output\n  -r   raw string output\n")
            case "-c", "--compact-output":
                compact = true
            case "-r", "--raw-output":
                rawOutput = true
            case let option where option.hasPrefix("-"):
                return ExecResult.failure("jq: unknown option: \(option)")
            default:
                if filter == nil {
                    filter = arg
                } else {
                    files.append(arg)
                }
            }
        }

        let program = filter ?? "."
        let inputText: String
        do {
            if files.isEmpty {
                inputText = ctx.stdin
            } else {
                inputText = try files.map { try ctx.fileSystem.readFile($0, relativeTo: ctx.cwd) }.joined(separator: "\n")
            }
        } catch {
            return ExecResult.failure("jq: \(error.localizedDescription)")
        }

        do {
            let inputs = try parseJQInputValues(inputText)
            var outputs: [Any] = []
            for input in inputs {
                outputs.append(contentsOf: try evaluateJQFilter(program, input: input))
            }
            let rendered = outputs.map { renderJQValue($0, compact: compact, raw: rawOutput) }.joined(separator: "\n")
            return ExecResult.success(rendered + (rendered.isEmpty ? "" : "\n"))
        } catch {
            return ExecResult.failure("jq: \(error.localizedDescription)")
        }
    }
}

private func yq() -> AnyBashCommand {
    AnyBashCommand(name: "yq") { args, ctx in
        var rawOutput = false
        var compact = false
        var outputJSON = false
        var parseJSON = false
        var nullInput = false
        var filter: String?
        var files: [String] = []
        var index = 0

        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--help":
                return ExecResult.success("yq FILTER [FILE]\n  -o json   output JSON\n  -c        compact JSON output\n  -r        raw string output\n  -p json   parse JSON input\n  -n        null input\n")
            case "-c":
                compact = true
            case "-r":
                rawOutput = true
            case "-n":
                nullInput = true
            case "-o":
                index += 1
                if index < args.count, args[index] == "json" {
                    outputJSON = true
                }
            case "-p":
                index += 1
                if index < args.count, args[index] == "json" {
                    parseJSON = true
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
            let inputValue: Any
            if nullInput {
                inputValue = NSNull()
            } else if parseJSON {
                inputValue = try parseJQInputValues(sourceText).first ?? NSNull()
            } else {
                inputValue = try parseSimpleYAML(sourceText)
            }

            let outputs = try evaluateJQFilter(program, input: inputValue)
            let rendered: String
            if outputJSON {
                rendered = outputs.map { renderJQValue($0, compact: compact, raw: rawOutput) }.joined(separator: "\n")
            } else {
                rendered = outputs.map { renderYAMLValue($0) }.joined(separator: "\n")
            }
            return ExecResult.success(rendered + (rendered.isEmpty ? "" : "\n"))
        } catch {
            return ExecResult.failure("yq: \(error.localizedDescription)")
        }
    }
}

// MARK: - Misc

private func xargs() -> AnyBashCommand {
    AnyBashCommand(name: "xargs") { args, ctx in
        var command = ["echo"]
        var maxArgs = Int.max
        var delimiter: Character = "\n"
        var i = 0
        while i < args.count {
            switch args[i] {
            case "-n": if i + 1 < args.count { maxArgs = Int(args[i + 1]) ?? Int.max; i += 2 } else { i += 1 }
            case "-d": if i + 1 < args.count { delimiter = args[i + 1].first ?? "\n"; i += 2 } else { i += 1 }
            case "-0": delimiter = "\0"; i += 1
            case "-I": i += 2 // skip placeholder (simplified)
            default: command = Array(args[i...]); i = args.count
            }
        }

        let items = ctx.stdin.split(separator: delimiter).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard let executor = ctx.executeSubshell else {
            // Fallback: just concatenate
            let fullCommand = (command + items).joined(separator: " ")
            return ExecResult.success(fullCommand + "\n")
        }

        var combined = ExecResult()
        let chunks = items.chunked(into: maxArgs)
        for chunk in chunks {
            let script = (command + chunk).map { $0.contains(" ") ? "'\($0)'" : $0 }.joined(separator: " ")
            let result = await executor(script)
            combined.stdout += result.stdout
            combined.stderr += result.stderr
            combined.exitCode = result.exitCode
        }
        return combined
    }
}

private func diff() -> AnyBashCommand {
    AnyBashCommand(name: "diff") { args, ctx in
        let files = args.filter { !$0.hasPrefix("-") }
        guard files.count >= 2 else { return ExecResult.failure("diff: missing operand") }
        do {
            let a = try ctx.fileSystem.readFile(files[0], relativeTo: ctx.cwd)
            let b = try ctx.fileSystem.readFile(files[1], relativeTo: ctx.cwd)
            if a == b { return ExecResult.success() }
            let aLines = a.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let bLines = b.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            var output = ""
            // Simple line-by-line diff
            let maxLines = max(aLines.count, bLines.count)
            for i in 0..<maxLines {
                let aLine = i < aLines.count ? aLines[i] : nil
                let bLine = i < bLines.count ? bLines[i] : nil
                if aLine != bLine {
                    if let a = aLine { output += "< \(a)\n" }
                    output += "---\n"
                    if let b = bLine { output += "> \(b)\n" }
                }
            }
            return ExecResult(stdout: output, stderr: "", exitCode: 1)
        } catch {
            return ExecResult.failure("diff: \(error.localizedDescription)")
        }
    }
}

private func comm() -> AnyBashCommand {
    AnyBashCommand(name: "comm") { args, ctx in
        let files = args.filter { !$0.hasPrefix("-") }
        guard files.count >= 2 else { return ExecResult.failure("comm: missing operand") }
        do {
            let a = try ctx.fileSystem.readFile(files[0], relativeTo: ctx.cwd).split(separator: "\n").map(String.init)
            let b = try ctx.fileSystem.readFile(files[1], relativeTo: ctx.cwd).split(separator: "\n").map(String.init)
            let setA = Set(a), setB = Set(b)
            var output: [String] = []
            let all = (setA.union(setB)).sorted()
            for item in all {
                let inA = setA.contains(item), inB = setB.contains(item)
                if inA && inB { output.append("\t\t\(item)") }
                else if inA { output.append(item) }
                else { output.append("\t\(item)") }
            }
            return ExecResult.success(output.joined(separator: "\n") + "\n")
        } catch {
            return ExecResult.failure("comm: \(error.localizedDescription)")
        }
    }
}

private func date() -> AnyBashCommand {
    AnyBashCommand(name: "date") { args, ctx in
        let formatter = DateFormatter()
        if let formatArg = args.first(where: { $0.hasPrefix("+") }) {
            var format = String(formatArg.dropFirst())
            format = format.replacingOccurrences(of: "%Y", with: "yyyy")
            format = format.replacingOccurrences(of: "%m", with: "MM")
            format = format.replacingOccurrences(of: "%d", with: "dd")
            format = format.replacingOccurrences(of: "%H", with: "HH")
            format = format.replacingOccurrences(of: "%M", with: "mm")
            format = format.replacingOccurrences(of: "%S", with: "ss")
            format = format.replacingOccurrences(of: "%s", with: "")
            formatter.dateFormat = format
            if format.isEmpty {
                return ExecResult.success(String(Int(Date().timeIntervalSince1970)) + "\n")
            }
        } else {
            formatter.dateFormat = "EEE MMM dd HH:mm:ss zzz yyyy"
        }
        return ExecResult.success(formatter.string(from: Date()) + "\n")
    }
}

private func sleep_() -> AnyBashCommand {
    AnyBashCommand(name: "sleep") { args, _ in
        // In sandbox, sleep is a no-op (don't actually block)
        if args.isEmpty { return ExecResult.failure("sleep: missing operand") }
        return ExecResult.success()
    }
}

private func uname() -> AnyBashCommand {
    AnyBashCommand(name: "uname") { args, _ in
        if args.contains("-a") {
            return ExecResult.success("Swift Virtual Kernel 1.0 just-bash-swift aarch64\n")
        }
        if args.contains("-r") { return ExecResult.success("1.0\n") }
        if args.contains("-m") { return ExecResult.success("aarch64\n") }
        if args.contains("-n") { return ExecResult.success("localhost\n") }
        return ExecResult.success("Swift\n")
    }
}

private func hostname() -> AnyBashCommand {
    AnyBashCommand(name: "hostname") { _, _ in
        ExecResult.success("localhost\n")
    }
}

private func whoami() -> AnyBashCommand {
    AnyBashCommand(name: "whoami") { _, ctx in
        ExecResult.success((ctx.environment["USER"] ?? "user") + "\n")
    }
}

private func clear() -> AnyBashCommand {
    AnyBashCommand(name: "clear") { _, _ in
        ExecResult.success()
    }
}

private func help() -> AnyBashCommand {
    AnyBashCommand(name: "help") { args, _ in
        if let topic = args.first {
            return ExecResult.success("help: \(topic): no detailed help available in just-bash-swift yet\n")
        }
        let summary = [
            "Supported utility commands include file, text, data, and shell helpers.",
            "Try: cat, grep, sed, awk, sort, base64, md5sum, sha256sum, tree, split, join, help"
        ].joined(separator: "\n")
        return ExecResult.success(summary + "\n")
    }
}

private func history() -> AnyBashCommand {
    AnyBashCommand(name: "history") { _, _ in
        ExecResult.success()
    }
}

private func bash() -> AnyBashCommand {
    shellRunnerCommand(named: "bash")
}

private func sh() -> AnyBashCommand {
    shellRunnerCommand(named: "sh")
}

private func time() -> AnyBashCommand {
    AnyBashCommand(name: "time") { args, ctx in
        guard !args.isEmpty else { return ExecResult.failure("time: missing command") }
        guard let executor = ctx.executeSubshell else {
            return ExecResult.failure("time: shell execution unavailable")
        }
        let result = await executor(args.joined(separator: " "))
        return ExecResult(stdout: result.stdout, stderr: result.stderr + "real 0.000\nuser 0.000\nsys 0.000\n", exitCode: result.exitCode)
    }
}

private func timeout() -> AnyBashCommand {
    AnyBashCommand(name: "timeout") { args, ctx in
        guard args.count >= 2 else { return ExecResult.failure("timeout: missing command") }
        guard let executor = ctx.executeSubshell else {
            return ExecResult.failure("timeout: shell execution unavailable")
        }
        return await executor(args.dropFirst().joined(separator: " "))
    }
}

private func curl() -> AnyBashCommand {
    AnyBashCommand(name: "curl") { args, ctx in
        var outputPath: String?
        var headOnly = false
        var urls: [String] = []
        var index = 0

        while index < args.count {
            switch args[index] {
            case "--help":
                return ExecResult.success("curl URL\n  -o FILE   write body to file\n  -I        head request\n")
            case "-o", "--output":
                index += 1
                if index < args.count { outputPath = args[index] }
            case "-I", "--head":
                headOnly = true
            default:
                if !args[index].hasPrefix("-") {
                    urls.append(args[index])
                }
            }
            index += 1
        }

        guard let urlString = urls.first else { return ExecResult.failure("curl: no URL specified") }
        let (headers, body): (String, Data)
        do {
            (headers, body) = try await fetchURLPayload(urlString)
        } catch {
            return ExecResult.failure("curl: \(error.localizedDescription)")
        }

        let stdout: String
        if headOnly {
            stdout = headers
        } else if let outputPath {
            do {
                try ctx.fileSystem.writeFile(stringFromVirtualData(body, preferUTF8: false), to: outputPath, relativeTo: ctx.cwd)
                stdout = ""
            } catch {
                return ExecResult.failure("curl: \(error.localizedDescription)")
            }
        } else {
            stdout = stringFromVirtualData(body, preferUTF8: true)
        }

        return ExecResult.success(stdout + (stdout.isEmpty || stdout.hasSuffix("\n") ? "" : "\n"))
    }
}

private func htmlToMarkdown() -> AnyBashCommand {
    AnyBashCommand(name: "html-to-markdown") { args, ctx in
        let files = args.filter { !$0.hasPrefix("-") }
        let html: String
        do {
            if files.isEmpty {
                html = ctx.stdin
            } else {
                html = try files.map { try ctx.fileSystem.readFile($0, relativeTo: ctx.cwd) }.joined()
            }
        } catch {
            return ExecResult.failure("html-to-markdown: \(error.localizedDescription)")
        }
        return ExecResult.success(convertHTMLToMarkdown(html))
    }
}

// MARK: - Helpers

private func gzipFamilyCommand(name: String, defaultDecompress: Bool, alwaysStdout: Bool) -> AnyBashCommand {
    AnyBashCommand(name: name) { args, ctx in
        var writeStdout = alwaysStdout
        var decompress = defaultDecompress
        var keepOriginal = alwaysStdout
        var force = false
        var suffix = ".gz"
        var files: [String] = []
        var index = 0

        while index < args.count {
            switch args[index] {
            case "-c", "--stdout", "--to-stdout":
                writeStdout = true
                index += 1
            case "-d", "--decompress", "--uncompress":
                decompress = true
                index += 1
            case "-k", "--keep":
                keepOriginal = true
                index += 1
            case "-f", "--force":
                force = true
                index += 1
            case "-S", "--suffix":
                if index + 1 < args.count {
                    suffix = args[index + 1]
                    index += 2
                } else {
                    return ExecResult.failure("\(name): option requires an argument -- S")
                }
            case let option where option.hasPrefix("-S") && option.count > 2:
                suffix = String(option.dropFirst(2))
                index += 1
            case "--help":
                return ExecResult.success(gzipHelp(name: name))
            case let option where option.hasPrefix("-"):
                if option == "-" {
                    files.append(option)
                } else {
                    index += 1
                    continue
                }
                index += 1
            default:
                files.append(args[index])
                index += 1
            }
        }

        if files.isEmpty {
            files = ["-"]
            writeStdout = true
        }

        var combined = ExecResult()
        for file in files {
            let isStdin = file == "-"
            let inputData: Data
            let originalLabel = isStdin ? "stdin" : file

            do {
                if isStdin {
                    inputData = dataFromVirtualString(ctx.stdin, treatAsBinary: decompress)
                } else {
                    let content = try ctx.fileSystem.readFile(file, relativeTo: ctx.cwd)
                    inputData = dataFromVirtualString(content, treatAsBinary: decompress || file.hasSuffix(suffix))
                }
            } catch {
                return ExecResult.failure("\(name): \(error.localizedDescription)")
            }

            do {
                if decompress {
                    let outputData = try gunzipData(inputData)
                    let outputString = stringFromVirtualData(outputData, preferUTF8: true)
                    if writeStdout {
                        combined.stdout += outputString
                    } else {
                        guard !isStdin else {
                            combined.stdout += outputString
                            continue
                        }
                        guard file.hasSuffix(suffix) else {
                            return ExecResult.failure("\(name): unknown suffix -- \(file)")
                        }
                        let outputPath = String(file.dropLast(suffix.count))
                        if ctx.fileSystem.exists(outputPath, relativeTo: ctx.cwd) && !force {
                            return ExecResult.failure("\(name): \(outputPath) already exists")
                        }
                        try ctx.fileSystem.writeFile(outputString, to: outputPath, relativeTo: ctx.cwd)
                        if !keepOriginal {
                            try ctx.fileSystem.removeItem(file, relativeTo: ctx.cwd, recursive: false, force: false)
                        }
                    }
                } else {
                    let outputData = try gzipData(inputData)
                    let outputString = stringFromVirtualData(outputData, preferUTF8: false)
                    if writeStdout {
                        combined.stdout += outputString
                    } else {
                        guard !isStdin else {
                            combined.stdout += outputString
                            continue
                        }
                        if file.hasSuffix(suffix) {
                            return ExecResult.failure("\(name): \(file) already has \(suffix) suffix -- unchanged")
                        }
                        let outputPath = file + suffix
                        if ctx.fileSystem.exists(outputPath, relativeTo: ctx.cwd) && !force {
                            return ExecResult.failure("\(name): \(outputPath) already exists")
                        }
                        try ctx.fileSystem.writeFile(outputString, to: outputPath, relativeTo: ctx.cwd)
                        if !keepOriginal {
                            try ctx.fileSystem.removeItem(file, relativeTo: ctx.cwd, recursive: false, force: false)
                        }
                    }
                }
            } catch {
                let errorText = error.localizedDescription
                if errorText.hasPrefix(name + ":") {
                    return ExecResult.failure(errorText)
                }
                if errorText == "invalid gzip data" {
                    return ExecResult.failure("\(name): \(originalLabel): not in gzip format")
                }
                return ExecResult.failure("\(name): \(errorText)")
            }
        }

        return combined
    }
}

private func split() -> AnyBashCommand {
    AnyBashCommand(name: "split") { args, ctx in
        var linesPerFile = 1000
        var files: [String] = []
        var index = 0
        while index < args.count {
            if args[index] == "-l", index + 1 < args.count {
                linesPerFile = Int(args[index + 1]) ?? linesPerFile
                index += 2
            } else {
                files.append(args[index])
                index += 1
            }
        }

        let inputPath = files.first
        let prefix = files.count > 1 ? files[1] : "x"
        let content: String
        do {
            if let inputPath {
                if inputPath == "-" {
                    content = ctx.stdin
                } else {
                    content = try ctx.fileSystem.readFile(inputPath, relativeTo: ctx.cwd)
                }
            } else {
                content = ctx.stdin
            }
        } catch {
            return ExecResult.failure("split: \(error.localizedDescription)")
        }

        var lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" && content.hasSuffix("\n") {
            lines.removeLast()
        }
        let chunks = stride(from: 0, to: lines.count, by: max(1, linesPerFile)).map { Array(lines[$0..<Swift.min($0 + max(1, linesPerFile), lines.count)]) }
        do {
            for (index, chunk) in chunks.enumerated() {
                let suffix = splitFileSuffix(index)
                try ctx.fileSystem.writeFile(chunk.joined(separator: "\n") + "\n", to: prefix + suffix, relativeTo: ctx.cwd)
            }
            return ExecResult.success()
        } catch {
            return ExecResult.failure("split: \(error.localizedDescription)")
        }
    }
}

private func checksumCommand(name: String, hash: @escaping @Sendable (Data) -> String) -> AnyBashCommand {
    AnyBashCommand(name: name) { args, ctx in
        let files = args.filter { !$0.hasPrefix("-") }
        do {
            if files.isEmpty {
                let data = Data(ctx.stdin.utf8)
                return ExecResult.success("\(hash(data))  -\n")
            }
            let lines = try files.map { path -> String in
                let data = Data(try ctx.fileSystem.readFile(path, relativeTo: ctx.cwd).utf8)
                return "\(hash(data))  \(path)"
            }
            return ExecResult.success(lines.joined(separator: "\n") + "\n")
        } catch {
            return ExecResult.failure("\(name): \(error.localizedDescription)")
        }
    }
}

private func shellRunnerCommand(named name: String) -> AnyBashCommand {
    AnyBashCommand(name: name) { args, ctx in
        guard let executor = ctx.executeSubshell else {
            return ExecResult.failure("\(name): shell execution unavailable")
        }
        if args.isEmpty {
            return ExecResult.success()
        }
        return await executor(args.joined(separator: " "))
    }
}

private func splitFileSuffix(_ index: Int) -> String {
    let alphabet = Array("abcdefghijklmnopqrstuvwxyz")
    let first = alphabet[(index / alphabet.count) % alphabet.count]
    let second = alphabet[index % alphabet.count]
    return "\(first)\(second)"
}

private func fetchURLPayload(_ urlString: String) async throws -> (String, Data) {
    if urlString.hasPrefix("data:") {
        guard let comma = urlString.firstIndex(of: ",") else {
            throw NSError(domain: "curl", code: 1, userInfo: [NSLocalizedDescriptionKey: "invalid data URL"])
        }
        let metadata = String(urlString[..<comma])
        let payload = String(urlString[urlString.index(after: comma)...])
        if metadata.contains(";base64"), let data = Data(base64Encoded: payload) {
            return ("HTTP/1.1 200 OK\n", data)
        }
        return ("HTTP/1.1 200 OK\n", Data(payload.removingPercentEncoding?.utf8 ?? payload.utf8))
    }

    guard let url = URL(string: urlString) else {
        throw NSError(domain: "curl", code: 1, userInfo: [NSLocalizedDescriptionKey: "invalid URL"])
    }

    if url.isFileURL {
        let data = try Data(contentsOf: url)
        return ("HTTP/1.1 200 OK\n", data)
    }

    let (data, response) = try await URLSession.shared.data(from: url)
    let headerText: String
    if let http = response as? HTTPURLResponse {
        let lines = ["HTTP/1.1 \(http.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: http.statusCode))"] +
            http.allHeaderFields.map { "\($0.key): \($0.value)" }
        headerText = lines.joined(separator: "\n") + "\n"
    } else {
        headerText = "HTTP/1.1 200 OK\n"
    }
    return (headerText, data)
}

private func convertHTMLToMarkdown(_ html: String) -> String {
    var result = html
    let replacements: [(String, String)] = [
        ("(?is)<h1>(.*?)</h1>", "# $1\n\n"),
        ("(?is)<h2>(.*?)</h2>", "## $1\n\n"),
        ("(?is)<strong>(.*?)</strong>", "**$1**"),
        ("(?is)<b>(.*?)</b>", "**$1**"),
        ("(?is)<em>(.*?)</em>", "_$1_"),
        ("(?is)<i>(.*?)</i>", "_$1_"),
        ("(?is)<code>(.*?)</code>", "`$1`"),
        ("(?is)<a[^>]*href=[\"']([^\"']+)[\"'][^>]*>(.*?)</a>", "[$2]($1)"),
        ("(?is)<li>(.*?)</li>", "- $1\n"),
        ("(?is)<p>(.*?)</p>", "$1\n\n"),
        ("(?is)<br\\s*/?>", "\n")
    ]

    for (pattern, template) in replacements {
        let regex = try? NSRegularExpression(pattern: pattern)
        let range = NSRange(result.startIndex..., in: result)
        result = regex?.stringByReplacingMatches(in: result, range: range, withTemplate: template) ?? result
    }

    let tagRegex = try? NSRegularExpression(pattern: "(?is)<[^>]+>")
    if let tagRegex {
        let range = NSRange(result.startIndex..., in: result)
        result = tagRegex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
    }

    result = result
        .replacingOccurrences(of: "&amp;", with: "&")
        .replacingOccurrences(of: "&lt;", with: "<")
        .replacingOccurrences(of: "&gt;", with: ">")

    return result.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
}

private func gzipHelp(name: String) -> String {
    let summary: String
    switch name {
    case "gunzip":
        summary = "gunzip - decompress files\n"
    case "zcat":
        summary = "zcat - decompress files to stdout\n"
    default:
        summary = "gzip - compress or decompress files\n"
    }
    return summary + "options: -c -d -k -f -S SUF --help\n"
}

private func dataFromVirtualString(_ text: String, treatAsBinary: Bool) -> Data {
    if treatAsBinary {
        return text.data(using: .isoLatin1) ?? Data(text.utf8)
    }
    return Data(text.utf8)
}

private func stringFromVirtualData(_ data: Data, preferUTF8: Bool) -> String {
    if preferUTF8, let utf8 = String(data: data, encoding: .utf8) {
        return utf8
    }
    return String(data: data, encoding: .isoLatin1) ?? String(decoding: data, as: UTF8.self)
}

private func gzipData(_ data: Data) throws -> Data {
    var stream = z_stream()
    let initStatus = deflateInit2_(
        &stream,
        Z_DEFAULT_COMPRESSION,
        Z_DEFLATED,
        MAX_WBITS + 16,
        MAX_MEM_LEVEL,
        Z_DEFAULT_STRATEGY,
        ZLIB_VERSION,
        Int32(MemoryLayout<z_stream>.size)
    )
    guard initStatus == Z_OK else {
        throw NSError(domain: "gzip", code: Int(initStatus), userInfo: [NSLocalizedDescriptionKey: "failed to initialize compressor"])
    }
    defer { deflateEnd(&stream) }

    return try data.withUnsafeBytes { rawBuffer in
        guard let baseAddress = rawBuffer.bindMemory(to: Bytef.self).baseAddress else {
            return Data()
        }
        stream.next_in = UnsafeMutablePointer(mutating: baseAddress)
        stream.avail_in = uInt(data.count)

        let bound = Int(deflateBound(&stream, uLong(data.count)))
        var output = Data(count: max(bound, 64))
        let status = output.withUnsafeMutableBytes { rawOutput -> Int32 in
            let outputBuffer = rawOutput.bindMemory(to: Bytef.self)
            stream.next_out = outputBuffer.baseAddress
            stream.avail_out = uInt(outputBuffer.count)
            return deflate(&stream, Z_FINISH)
        }
        guard status == Z_STREAM_END else {
            throw NSError(domain: "gzip", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "compression failed"])
        }
        output.count = Int(stream.total_out)
        return output
    }
}

private func gunzipData(_ data: Data) throws -> Data {
    guard !data.isEmpty else { return Data() }
    var stream = z_stream()
    let initStatus = inflateInit2_(
        &stream,
        MAX_WBITS + 32,
        ZLIB_VERSION,
        Int32(MemoryLayout<z_stream>.size)
    )
    guard initStatus == Z_OK else {
        throw NSError(domain: "gzip", code: Int(initStatus), userInfo: [NSLocalizedDescriptionKey: "failed to initialize decompressor"])
    }
    defer { inflateEnd(&stream) }

    return try data.withUnsafeBytes { rawBuffer in
        guard let baseAddress = rawBuffer.bindMemory(to: Bytef.self).baseAddress else {
            return Data()
        }
        stream.next_in = UnsafeMutablePointer(mutating: baseAddress)
        stream.avail_in = uInt(data.count)

        let chunkSize = 64 * 1024
        var output = Data()
        while true {
            var chunk = Data(count: chunkSize)
            let status: Int32 = chunk.withUnsafeMutableBytes { rawOutput in
                let outputBuffer = rawOutput.bindMemory(to: Bytef.self)
                stream.next_out = outputBuffer.baseAddress
                stream.avail_out = uInt(outputBuffer.count)
                return inflate(&stream, Z_NO_FLUSH)
            }
            let produced = chunkSize - Int(stream.avail_out)
            if produced > 0 {
                output.append(chunk.prefix(produced))
            }
            if status == Z_STREAM_END {
                return output
            }
            guard status == Z_OK else {
                throw NSError(domain: "gzip", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "invalid gzip data"])
            }
        }
    }
}

private struct TarEntry {
    let name: String
    let data: Data
    let isDirectory: Bool
}

private struct OrderedJSONObject {
    let entries: [(String, Any)]
}

private func tarHelpText() -> String {
    """
    tar - manipulate tape archives
      -c, --create
      -t, --list
      -x, --extract
      -f FILE
      -C DIR
      -z
      --strip-components=N
    """
}

private func buildTarEntries(paths: [String], changeDir: String?, ctx: CommandContext) throws -> [TarEntry] {
    let baseDir = changeDir.map { VirtualPath.normalize($0, relativeTo: ctx.cwd) } ?? ctx.cwd
    var entries: [TarEntry] = []

    for requested in paths {
        let source = VirtualPath.normalize(requested, relativeTo: baseDir)
        guard ctx.fileSystem.exists(source) else {
            throw NSError(domain: "tar", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot stat: \(requested)"])
        }
        let archiveRoot = requested.hasPrefix("/") ? String(source.drop(while: { $0 == "/" })) : requested

        if ctx.fileSystem.isDirectory(source) {
            entries.append(TarEntry(name: archiveRoot.hasSuffix("/") ? archiveRoot : archiveRoot + "/", data: Data(), isDirectory: true))
            let walked = try ctx.fileSystem.walk(source)
            for path in walked where path != source {
                let relative = String(path.dropFirst(source.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                guard !relative.isEmpty else { continue }
                let name = archiveRoot.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + relative
                if ctx.fileSystem.isDirectory(path) {
                    entries.append(TarEntry(name: name.hasSuffix("/") ? name : name + "/", data: Data(), isDirectory: true))
                } else {
                    let content = try ctx.fileSystem.readFile(path)
                    entries.append(TarEntry(name: name, data: dataFromVirtualString(content, treatAsBinary: true), isDirectory: false))
                }
            }
        } else {
            let content = try ctx.fileSystem.readFile(source)
            entries.append(TarEntry(name: archiveRoot, data: dataFromVirtualString(content, treatAsBinary: true), isDirectory: false))
        }
    }

    return entries
}

private func buildTarArchive(_ entries: [TarEntry]) -> Data {
    var archive = Data()
    for entry in entries {
        archive.append(makeTarHeader(for: entry))
        if !entry.isDirectory {
            archive.append(entry.data)
            let remainder = entry.data.count % 512
            if remainder != 0 {
                archive.append(Data(repeating: 0, count: 512 - remainder))
            }
        }
    }
    archive.append(Data(repeating: 0, count: 1024))
    return archive
}

private func makeTarHeader(for entry: TarEntry) -> Data {
    var header = Data(repeating: 0, count: 512)
    let normalizedName = entry.isDirectory && !entry.name.hasSuffix("/") ? entry.name + "/" : entry.name
    writeTarField(normalizedName, into: &header, offset: 0, length: 100)
    writeTarOctal(entry.isDirectory ? 0o755 : 0o644, into: &header, offset: 100, length: 8)
    writeTarOctal(0, into: &header, offset: 108, length: 8)
    writeTarOctal(0, into: &header, offset: 116, length: 8)
    writeTarOctal(entry.isDirectory ? 0 : entry.data.count, into: &header, offset: 124, length: 12)
    writeTarOctal(Int(Date().timeIntervalSince1970), into: &header, offset: 136, length: 12)
    for index in 148..<156 { header[index] = 32 }
    header[156] = entry.isDirectory ? UInt8(ascii: "5") : UInt8(ascii: "0")
    writeTarField("ustar", into: &header, offset: 257, length: 6)
    writeTarField("00", into: &header, offset: 263, length: 2)
    writeTarField("user", into: &header, offset: 265, length: 32)
    writeTarField("group", into: &header, offset: 297, length: 32)
    let checksum = header.reduce(0) { $0 + Int($1) }
    writeTarChecksum(checksum, into: &header, offset: 148)
    return header
}

private func writeTarField(_ value: String, into header: inout Data, offset: Int, length: Int) {
    let bytes = Array(value.utf8.prefix(length))
    for (index, byte) in bytes.enumerated() {
        header[offset + index] = byte
    }
}

private func writeTarOctal(_ value: Int, into header: inout Data, offset: Int, length: Int) {
    let string = String(format: "%0*o", max(length - 1, 1), value)
    writeTarField(string, into: &header, offset: offset, length: length - 1)
    header[offset + length - 1] = 0
}

private func writeTarChecksum(_ value: Int, into header: inout Data, offset: Int) {
    let string = String(format: "%06o", value)
    writeTarField(string, into: &header, offset: offset, length: 6)
    header[offset + 6] = 0
    header[offset + 7] = 32
}

private func loadTarArchiveData(path: String, relativeTo cwd: String, fileSystem: VirtualFileSystem) throws -> Data {
    let content = try fileSystem.readFile(path, relativeTo: cwd)
    var data = dataFromVirtualString(content, treatAsBinary: true)
    if data.count >= 2 && data[0] == 0x1f && data[1] == 0x8b {
        data = try gunzipData(data)
    }
    return data
}

private func parseTarArchive(_ data: Data) throws -> [TarEntry] {
    var entries: [TarEntry] = []
    var offset = 0
    while offset + 512 <= data.count {
        let header = data[offset..<(offset + 512)]
        if header.allSatisfy({ $0 == 0 }) { break }

        let name = tarString(from: header, offset: 0, length: 100)
        let size = tarOctal(from: header, offset: 124, length: 12)
        let typeFlag = header[header.index(header.startIndex, offsetBy: 156)]
        let isDirectory = typeFlag == UInt8(ascii: "5") || name.hasSuffix("/")
        offset += 512

        let fileData: Data
        if isDirectory {
            fileData = Data()
        } else {
            guard offset + size <= data.count else {
                throw NSError(domain: "tar", code: 1, userInfo: [NSLocalizedDescriptionKey: "Corrupt archive"])
            }
            fileData = data[offset..<(offset + size)]
            let padded = ((size + 511) / 512) * 512
            offset += padded
        }

        entries.append(TarEntry(name: name, data: Data(fileData), isDirectory: isDirectory))
    }
    return entries
}

private func tarString(from header: Data.SubSequence, offset: Int, length: Int) -> String {
    let start = header.index(header.startIndex, offsetBy: offset)
    let end = header.index(start, offsetBy: length)
    let bytes = header[start..<end].prefix { $0 != 0 }
    return String(decoding: bytes, as: UTF8.self)
}

private func tarOctal(from header: Data.SubSequence, offset: Int, length: Int) -> Int {
    let string = tarString(from: header, offset: offset, length: length).trimmingCharacters(in: .whitespacesAndNewlines)
    return Int(string, radix: 8) ?? 0
}

private func filterTarEntries(_ entries: [TarEntry], paths: [String], stripComponents: Int) -> [TarEntry] {
    entries.compactMap { entry in
        if !paths.isEmpty {
            let matches = paths.contains { path in
                let requested = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                return entry.name == requested || entry.name.hasPrefix(requested + "/")
            }
            if !matches { return nil }
        }
        let components = entry.name.split(separator: "/").map(String.init)
        guard stripComponents < components.count || (entry.isDirectory && stripComponents == components.count) else { return nil }
        let strippedComponents = Array(components.dropFirst(stripComponents))
        let strippedName = strippedComponents.joined(separator: "/") + (entry.isDirectory && !strippedComponents.isEmpty ? "/" : "")
        guard !strippedName.contains("..") else { return nil }
        guard !strippedName.isEmpty else { return nil }
        return TarEntry(name: strippedName, data: entry.data, isDirectory: entry.isDirectory)
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

private func escapeJSONString(_ value: String) -> String {
    value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\r")
        .replacingOccurrences(of: "\t", with: "\\t")
}

private func parseJQInputValues(_ input: String) throws -> [Any] {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [NSNull()] }
    let data = Data(trimmed.utf8)
    let value = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    return [value]
}

private func evaluateJQFilter(_ filter: String, input: Any, bindings: [String: Any] = [:]) throws -> [Any] {
    let trimmed = filter.trimmingCharacters(in: .whitespacesAndNewlines)

    if let binding = parseJQBinding(trimmed) {
        let boundValue = try evaluateJQFilter(binding.source, input: input, bindings: bindings).first ?? input
        var nextBindings = bindings
        nextBindings[binding.name] = boundValue
        return try evaluateJQFilter(binding.rest, input: input, bindings: nextBindings)
    }

    if let commaParts = splitTopLevelJQ(trimmed, separator: ",") {
        return try commaParts.flatMap { try evaluateJQFilter($0, input: input, bindings: bindings) }
    }

    if let pipeParts = splitTopLevelJQ(trimmed, separator: "|") {
        var values: [Any] = [input]
        for part in pipeParts {
            values = try values.flatMap { try evaluateJQFilter(part, input: $0, bindings: bindings) }
        }
        return values
    }

    if trimmed == "." {
        return [input]
    }

    if trimmed == ".[]" {
        return iterateJQValues(input)
    }

    if trimmed == "length" {
        return [jqLength(input)]
    }

    if trimmed == "keys" {
        return [jqKeys(input)]
    }

    if trimmed == "add" {
        return [jqAdd(input)]
    }

    if trimmed.hasPrefix("if "), trimmed.hasSuffix(" end") {
        return [try evaluateJQConditional(trimmed, input: input, bindings: bindings)]
    }

    if trimmed.hasPrefix("any("), trimmed.hasSuffix(")") {
        let inner = String(trimmed.dropFirst(4).dropLast())
        guard let array = input as? [Any] else { return [false] }
        return [try array.contains { try evaluateJQFilter(inner, input: $0, bindings: bindings).contains(where: jqTruthy) }]
    }

    if trimmed.hasPrefix("all("), trimmed.hasSuffix(")") {
        let inner = String(trimmed.dropFirst(4).dropLast())
        guard let array = input as? [Any] else { return [false] }
        return [try array.allSatisfy { try evaluateJQFilter(inner, input: $0, bindings: bindings).contains(where: jqTruthy) }]
    }

    if trimmed.hasPrefix("contains("), trimmed.hasSuffix(")") {
        let inner = String(trimmed.dropFirst(9).dropLast())
        let rhs = try evaluateJQFilter(inner, input: input, bindings: bindings).first ?? NSNull()
        return [jqContains(input, rhs)]
    }

    if let op = parseJQBinaryOperator(trimmed) {
        let lhsValues = try evaluateJQFilter(op.left, input: input, bindings: bindings)
        let rhsValues = try evaluateJQFilter(op.right, input: input, bindings: bindings)
        let lhs = lhsValues.first ?? NSNull()
        let rhs = rhsValues.first ?? NSNull()
        return [try evaluateJQBinary(lhs: lhs, rhs: rhs, op: op.op)]
    }

    if trimmed.hasPrefix("{"), trimmed.hasSuffix("}") {
        return [try evaluateJQObject(trimmed, input: input, bindings: bindings)]
    }

    if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
        let inner = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        let collected = inner.isEmpty ? [] : try evaluateJQFilter(inner, input: input, bindings: bindings)
        return [collected]
    }

    if trimmed.hasPrefix("map("), trimmed.hasSuffix(")") {
        let inner = String(trimmed.dropFirst(4).dropLast())
        guard let array = input as? [Any] else { return [NSNull()] }
        let mapped = try array.flatMap { try evaluateJQFilter(inner, input: $0, bindings: bindings) }
        return [mapped]
    }

    if trimmed.hasPrefix("select("), trimmed.hasSuffix(")") {
        let inner = String(trimmed.dropFirst(7).dropLast())
        let predicateValues = try evaluateJQFilter(inner, input: input, bindings: bindings)
        if predicateValues.contains(where: jqTruthy) {
            return [input]
        }
        return []
    }

    if trimmed.hasPrefix("has("), trimmed.hasSuffix(")") {
        let inner = String(trimmed.dropFirst(4).dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        return [jqHas(input, argument: inner)]
    }

    if trimmed.hasPrefix(".") {
        return try evaluateJQPath(trimmed, input: input)
    }

    if trimmed.hasPrefix("$"), let bound = bindings[String(trimmed.dropFirst())] {
        return [bound]
    }

    if let literal = parseJQLiteral(trimmed) {
        return [literal]
    }

    throw NSError(domain: "jq", code: 1, userInfo: [NSLocalizedDescriptionKey: "unsupported filter: \(trimmed)"])
}

private func parseJQBinding(_ text: String) -> (source: String, name: String, rest: String)? {
    guard let range = text.range(of: " as $") else { return nil }
    let source = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
    let after = text[range.upperBound...]
    guard let pipeRange = after.range(of: " | ") else { return nil }
    let name = String(after[..<pipeRange.lowerBound]).trimmingCharacters(in: .whitespaces)
    let rest = String(after[pipeRange.upperBound...]).trimmingCharacters(in: .whitespaces)
    guard !source.isEmpty, !name.isEmpty, !rest.isEmpty else { return nil }
    return (source, name, rest)
}

private func evaluateJQObject(_ filter: String, input: Any, bindings: [String: Any]) throws -> OrderedJSONObject {
    let inner = String(filter.dropFirst().dropLast())
    let parts = splitTopLevelJQ(inner, separator: ",") ?? [inner]
    var entries: [(String, Any)] = []
    for part in parts {
        guard let colonIndex = topLevelJQColonIndex(part) else {
            throw NSError(domain: "jq", code: 1, userInfo: [NSLocalizedDescriptionKey: "invalid object constructor"])
        }
        let key = String(part[..<colonIndex]).trimmingCharacters(in: .whitespaces)
        var valueExpr = String(part[part.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
        if valueExpr.hasPrefix("("), valueExpr.hasSuffix(")") {
            valueExpr = String(valueExpr.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        let normalizedKey = key.replacingOccurrences(of: "\"", with: "")
        entries.append((normalizedKey, try evaluateJQFilter(valueExpr, input: input, bindings: bindings).first ?? NSNull()))
    }
    return OrderedJSONObject(entries: entries)
}

private func topLevelJQColonIndex(_ text: String) -> String.Index? {
    var depthParen = 0
    var depthBracket = 0
    var depthBrace = 0
    var inString = false
    var escaped = false
    var index = text.startIndex
    while index < text.endIndex {
        let ch = text[index]
        if escaped {
            escaped = false
            index = text.index(after: index)
            continue
        }
        if ch == "\\" {
            escaped = true
            index = text.index(after: index)
            continue
        }
        if ch == "\"" {
            inString.toggle()
            index = text.index(after: index)
            continue
        }
        if !inString {
            switch ch {
            case "(":
                depthParen += 1
            case ")":
                depthParen -= 1
            case "[":
                depthBracket += 1
            case "]":
                depthBracket -= 1
            case "{":
                depthBrace += 1
            case "}":
                depthBrace -= 1
            case ":" where depthParen == 0 && depthBracket == 0 && depthBrace == 0:
                return index
            default:
                break
            }
        }
        index = text.index(after: index)
    }
    return nil
}

private func splitTopLevelJQ(_ text: String, separator: Character) -> [String]? {
    var depthParen = 0
    var depthBracket = 0
    var depthBrace = 0
    var inString = false
    var escaped = false
    var current = ""
    var parts: [String] = []
    var sawSeparator = false

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
            switch ch {
            case "(":
                depthParen += 1
            case ")":
                depthParen -= 1
            case "[":
                depthBracket += 1
            case "]":
                depthBracket -= 1
            case "{":
                depthBrace += 1
            case "}":
                depthBrace -= 1
            default:
                break
            }
            if ch == separator, depthParen == 0, depthBracket == 0, depthBrace == 0 {
                parts.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                sawSeparator = true
                continue
            }
        }
        current.append(ch)
    }

    guard sawSeparator else { return nil }
    parts.append(current.trimmingCharacters(in: .whitespaces))
    return parts
}

private func evaluateJQPath(_ filter: String, input: Any) throws -> [Any] {
    if filter == "." { return [input] }
    var currentValues: [Any] = [input]
    var index = filter.startIndex
    guard filter[index] == "." else { return [input] }
    index = filter.index(after: index)

    while index < filter.endIndex {
        if filter[index] == "[" {
            guard let closing = filter[index...].firstIndex(of: "]") else {
                throw NSError(domain: "jq", code: 1, userInfo: [NSLocalizedDescriptionKey: "bad path"])
            }
            let content = String(filter[filter.index(after: index)..<closing])
            if content.isEmpty {
                currentValues = currentValues.flatMap(iterateJQValues)
            } else if content.contains(":") {
                currentValues = currentValues.map { jqSlice($0, spec: content) }
            } else if let number = Int(content) {
                currentValues = currentValues.map { jqArrayIndex($0, number) ?? NSNull() }
            } else {
                currentValues = currentValues.map { _ in NSNull() }
            }
            index = filter.index(after: closing)
            if index < filter.endIndex, filter[index] == "." {
                index = filter.index(after: index)
            }
            continue
        }

        let start = index
        while index < filter.endIndex, filter[index] != ".", filter[index] != "[" {
            index = filter.index(after: index)
        }
        let key = String(filter[start..<index])
        if !key.isEmpty {
            let normalizedKey = key.hasSuffix("?") ? String(key.dropLast()) : key
            currentValues = currentValues.map { value in
                if let object = value as? [String: Any] {
                    return object[normalizedKey] ?? NSNull()
                }
                if let object = value as? NSDictionary {
                    return object.object(forKey: normalizedKey) ?? NSNull()
                }
                return NSNull()
            }
        }
        if index < filter.endIndex, filter[index] == "." {
            index = filter.index(after: index)
        }
    }

    return currentValues
}

private func iterateJQValues(_ value: Any) -> [Any] {
    if let array = value as? [Any] {
        return array
    }
    if let object = value as? [String: Any] {
        return object.keys.sorted().compactMap { object[$0] }
    }
    return [NSNull()]
}

private func jqArrayIndex(_ value: Any, _ index: Int) -> Any? {
    guard let array = value as? [Any], !array.isEmpty else { return nil }
    let resolved = index >= 0 ? index : array.count + index
    guard resolved >= 0, resolved < array.count else { return nil }
    return array[resolved]
}

private func jqSlice(_ value: Any, spec: String) -> Any {
    let parts = spec.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 2 else { return NSNull() }
    let start = parts[0].isEmpty ? nil : Int(parts[0])
    let end = parts[1].isEmpty ? nil : Int(parts[1])

    if let array = value as? [Any] {
        let lower = resolvedJQIndex(start, count: array.count, defaultValue: 0)
        let upper = resolvedJQIndex(end, count: array.count, defaultValue: array.count)
        guard lower <= upper else { return [] }
        return Array(array[lower..<upper])
    }

    if let string = value as? String {
        let chars = Array(string)
        let lower = resolvedJQIndex(start, count: chars.count, defaultValue: 0)
        let upper = resolvedJQIndex(end, count: chars.count, defaultValue: chars.count)
        guard lower <= upper else { return "" }
        return String(chars[lower..<upper])
    }

    return NSNull()
}

private func resolvedJQIndex(_ value: Int?, count: Int, defaultValue: Int) -> Int {
    guard let value else { return defaultValue }
    let resolved = value >= 0 ? value : count + value
    return max(0, min(count, resolved))
}

private func jqHas(_ value: Any, argument: String) -> Bool {
    if let key = parseJQLiteral(argument) as? String {
        if let object = value as? [String: Any] {
            return object[key] != nil
        }
        if let object = value as? NSDictionary {
            return object.object(forKey: key) != nil
        }
    }
    if let array = value as? [Any], let index = Int(argument) {
        return index >= 0 && index < array.count
    }
    return false
}

private func jqTruthy(_ value: Any) -> Bool {
    if value is NSNull { return false }
    if let bool = value as? Bool { return bool }
    return true
}

private func jqContains(_ lhs: Any, _ rhs: Any) -> Bool {
    if let lhsArray = lhs as? [Any], let rhsArray = rhs as? [Any] {
        return rhsArray.allSatisfy { rhsValue in lhsArray.contains(where: { jqEqual($0, rhsValue) }) }
    }
    if let lhsObject = jqObjectDictionary(lhs), let rhsObject = jqObjectDictionary(rhs) {
        return rhsObject.allSatisfy { key, rhsValue in
            guard let lhsValue = lhsObject[key] else { return false }
            return jqEqual(lhsValue, rhsValue)
        }
    }
    return jqEqual(lhs, rhs)
}

private func jqEqual(_ lhs: Any, _ rhs: Any) -> Bool {
    switch (lhs, rhs) {
    case (_ as NSNull, _ as NSNull):
        return true
    case let (l as NSNumber, r as NSNumber):
        return l == r
    case let (l as String, r as String):
        return l == r
    case let (l as [Any], r as [Any]):
        return l.count == r.count && zip(l, r).allSatisfy { jqEqual($0, $1) }
    case let (l as [String: Any], r as [String: Any]):
        return l.keys == r.keys && l.keys.allSatisfy { key in jqEqual(l[key] as Any, r[key] as Any) }
    default:
        if let l = jqObjectDictionary(lhs), let r = jqObjectDictionary(rhs) {
            return l.keys == r.keys && l.keys.allSatisfy { key in jqEqual(l[key] as Any, r[key] as Any) }
        }
        return false
    }
}

private func jqLength(_ value: Any) -> Any {
    if let array = value as? [Any] { return array.count }
    if let string = value as? String { return string.count }
    if let object = jqObjectDictionary(value) { return object.count }
    return 0
}

private func jqKeys(_ value: Any) -> Any {
    if let object = jqObjectDictionary(value) {
        return object.keys.sorted()
    }
    return []
}

private func jqAdd(_ value: Any) -> Any {
    if let array = value as? [Any] {
        if array.allSatisfy({ ($0 as? NSNumber) != nil }) {
            return array.compactMap { ($0 as? NSNumber)?.doubleValue }.reduce(0.0, +)
        }
        if array.allSatisfy({ $0 is String }) {
            return array.compactMap { $0 as? String }.joined()
        }
    }
    return NSNull()
}

private func jqObjectDictionary(_ value: Any) -> [String: Any]? {
    if let value = value as? OrderedJSONObject {
        return Dictionary(uniqueKeysWithValues: value.entries)
    }
    if let value = value as? [String: Any] {
        return value
    }
    if let dict = value as? NSDictionary {
        var result: [String: Any] = [:]
        for (key, value) in dict {
            guard let key = key as? String else { return nil }
            result[key] = value
        }
        return result
    }
    return nil
}

private func evaluateJQConditional(_ filter: String, input: Any, bindings: [String: Any]) throws -> Any {
    let patterns = [
        #"^if\s+(.+?)\s+then\s+(.+?)\s+elif\s+(.+?)\s+then\s+(.+?)\s+else\s+(.+?)\s+end$"#,
        #"^if\s+(.+?)\s+then\s+(.+?)\s+else\s+(.+?)\s+end$"#
    ]

    for pattern in patterns {
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(filter.startIndex..<filter.endIndex, in: filter)
        guard let match = regex.firstMatch(in: filter, options: [], range: range) else { continue }
        let captures = (1..<match.numberOfRanges).compactMap { idx -> String? in
            guard let range = Range(match.range(at: idx), in: filter) else { return nil }
            return String(filter[range]).trimmingCharacters(in: .whitespaces)
        }

        let branches: [(String, String)]
        let elseExpr: String
        if captures.count == 5 {
            branches = [(captures[0], captures[1]), (captures[2], captures[3])]
            elseExpr = captures[4]
        } else if captures.count == 3 {
            branches = [(captures[0], captures[1])]
            elseExpr = captures[2]
        } else {
            break
        }

        for (condition, valueExpr) in branches {
            let conditionValue = try evaluateJQFilter(condition, input: input, bindings: bindings).first ?? NSNull()
            if jqTruthy(conditionValue) {
                return try evaluateJQFilter(valueExpr, input: input, bindings: bindings).first ?? NSNull()
            }
        }
        return try evaluateJQFilter(elseExpr, input: input, bindings: bindings).first ?? NSNull()
    }

    throw NSError(domain: "jq", code: 1, userInfo: [NSLocalizedDescriptionKey: "invalid conditional"])
}

private func splitTopLevelJQKeyword(_ text: String, keyword: String) -> (left: String, right: String)? {
    let parts = splitTopLevelJQKeywordAll(text, keyword: keyword)
    guard parts.count >= 2 else { return nil }
    return (parts[0], parts[1...].joined(separator: keyword).trimmingCharacters(in: .whitespaces))
}

private func splitTopLevelJQKeywordAll(_ text: String, keyword: String) -> [String] {
    var depthParen = 0
    var depthBracket = 0
    var depthBrace = 0
    var inString = false
    var escaped = false
    var current = ""
    var parts: [String] = []
    let chars = Array(text)
    let keywordChars = Array(keyword)
    var index = 0

    while index < chars.count {
        let ch = chars[index]
        if escaped {
            current.append(ch)
            escaped = false
            index += 1
            continue
        }
        if ch == "\\" {
            current.append(ch)
            escaped = true
            index += 1
            continue
        }
        if ch == "\"" {
            inString.toggle()
            current.append(ch)
            index += 1
            continue
        }
        if !inString {
            switch ch {
            case "(":
                depthParen += 1
            case ")":
                depthParen -= 1
            case "[":
                depthBracket += 1
            case "]":
                depthBracket -= 1
            case "{":
                depthBrace += 1
            case "}":
                depthBrace -= 1
            default:
                break
            }
            if depthParen == 0, depthBracket == 0, depthBrace == 0,
               index + keywordChars.count <= chars.count,
               Array(chars[index..<(index + keywordChars.count)]) == keywordChars {
                parts.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                index += keywordChars.count
                continue
            }
        }
        current.append(ch)
        index += 1
    }

    parts.append(current.trimmingCharacters(in: .whitespaces))
    return parts
}

private func parseJQBinaryOperator(_ text: String) -> (left: String, op: String, right: String)? {
    for op in ["==", "!=", ">=", "<=", ">", "<", "*", "/", "+", "-"] {
        if let split = splitTopLevelJQOperator(text, op: op) {
            return split
        }
    }
    return nil
}

private func splitTopLevelJQOperator(_ text: String, op: String) -> (left: String, op: String, right: String)? {
    var depthParen = 0
    var depthBracket = 0
    var depthBrace = 0
    var inString = false
    var escaped = false
    let chars = Array(text)
    var index = 0
    while index < chars.count {
        let ch = chars[index]
        if escaped {
            escaped = false
            index += 1
            continue
        }
        if ch == "\\" {
            escaped = true
            index += 1
            continue
        }
        if ch == "\"" {
            inString.toggle()
            index += 1
            continue
        }
        if !inString {
            switch ch {
            case "(":
                depthParen += 1
            case ")":
                depthParen -= 1
            case "[":
                depthBracket += 1
            case "]":
                depthBracket -= 1
            case "{":
                depthBrace += 1
            case "}":
                depthBrace -= 1
            default:
                break
            }
            let currentIndex = text.index(text.startIndex, offsetBy: index)
            if depthParen == 0, depthBracket == 0, depthBrace == 0,
               text[currentIndex...].hasPrefix(op) {
                let left = String(text[..<currentIndex]).trimmingCharacters(in: .whitespaces)
                let rightStart = text.index(currentIndex, offsetBy: op.count)
                let right = String(text[rightStart...]).trimmingCharacters(in: .whitespaces)
                guard !left.isEmpty, !right.isEmpty else { return nil }
                return (left, op, right)
            }
        }
        index += 1
    }
    return nil
}

private func evaluateJQBinary(lhs: Any, rhs: Any, op: String) throws -> Any {
    switch op {
    case "*":
        return jqDouble(lhs) * jqDouble(rhs)
    case "+":
        return jqDouble(lhs) + jqDouble(rhs)
    case "-":
        return jqDouble(lhs) - jqDouble(rhs)
    case "/":
        return jqDouble(lhs) / jqDouble(rhs)
    case ">":
        return jqDouble(lhs) > jqDouble(rhs)
    case "<":
        return jqDouble(lhs) < jqDouble(rhs)
    case ">=":
        return jqDouble(lhs) >= jqDouble(rhs)
    case "<=":
        return jqDouble(lhs) <= jqDouble(rhs)
    case "==":
        return String(describing: lhs) == String(describing: rhs)
    case "!=":
        return String(describing: lhs) != String(describing: rhs)
    default:
        throw NSError(domain: "jq", code: 1, userInfo: [NSLocalizedDescriptionKey: "unsupported operator: \(op)"])
    }
}

private func jqDouble(_ value: Any) -> Double {
    if let number = value as? NSNumber { return number.doubleValue }
    if let int = value as? Int { return Double(int) }
    if let double = value as? Double { return double }
    return 0
}

private func parseJQLiteral(_ text: String) -> Any? {
    if text == "null" { return NSNull() }
    if text == "true" { return true }
    if text == "false" { return false }
    if let int = Int(text) { return int }
    if let double = Double(text) { return double }
    if (text.hasPrefix("{") && text.hasSuffix("}")) || (text.hasPrefix("[") && text.hasSuffix("]")) {
        if let data = text.data(using: .utf8),
           let value = try? JSONSerialization.jsonObject(with: data) {
            return value
        }
    }
    if text.hasPrefix("\""), text.hasSuffix("\"") {
        return String(text.dropFirst().dropLast())
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\t", with: "\t")
    }
    return nil
}

private func renderJQValue(_ value: Any, compact: Bool, raw: Bool) -> String {
    if raw, let string = value as? String {
        return string
    }
    if value is NSNull { return "null" }
    if let object = value as? OrderedJSONObject {
        if compact {
            let rendered = object.entries.map { key, value in
                "\"\(escapeJSONString(key))\":" + renderJQValue(value, compact: true, raw: false)
            }.joined(separator: ",")
            return "{\(rendered)}"
        }
        let rendered = object.entries.map { key, value in
            "  \"\(escapeJSONString(key))\": " + renderJQValue(value, compact: false, raw: false)
        }.joined(separator: ",\n")
        return "{\n\(rendered)\n}"
    }
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
    if JSONSerialization.isValidJSONObject(value) {
        let options: JSONSerialization.WritingOptions = compact ? [] : [.prettyPrinted]
        let data = try? JSONSerialization.data(withJSONObject: value, options: options)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "null"
    }
    return String(describing: value)
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

extension Array {
    fileprivate func chunked(into size: Int) -> [[Element]] {
        if size >= count { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
