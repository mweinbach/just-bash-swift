import Foundation
import JustBashFS

func ls() -> AnyBashCommand {
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

func mkdir() -> AnyBashCommand {
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

func touch() -> AnyBashCommand {
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

func rm() -> AnyBashCommand {
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

func rmdir() -> AnyBashCommand {
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

func cp() -> AnyBashCommand {
    AnyBashCommand(name: "cp") { args, ctx in
        var noOverwrite = false
        let filtered = args.filter { arg in
            if arg.hasPrefix("-") {
                for ch in arg.dropFirst() {
                    if ch == "n" { noOverwrite = true }
                }
                return false
            }
            return true
        }
        guard filtered.count >= 2 else { return ExecResult.failure("cp: missing file operand") }
        let dest = filtered.last!
        let sources = filtered.dropLast()
        do {
            for source in sources {
                if noOverwrite {
                    let destPath = VirtualPath.normalize(dest, relativeTo: ctx.cwd)
                    if ctx.fileSystem.exists(destPath) { continue }
                }
                try ctx.fileSystem.copyItem(from: source, to: dest, relativeTo: ctx.cwd)
            }
            return ExecResult.success()
        } catch {
            return ExecResult.failure("cp: \(error.localizedDescription)")
        }
    }
}

func mv() -> AnyBashCommand {
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

func ln() -> AnyBashCommand {
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

func chmod() -> AnyBashCommand {
    AnyBashCommand(name: "chmod") { args, ctx in
        let filtered = args.filter { !$0.hasPrefix("-") }
        guard filtered.count >= 2 else { return ExecResult.failure("chmod: missing operand") }
        return ExecResult.success()
    }
}

func stat() -> AnyBashCommand {
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

func tree() -> AnyBashCommand {
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

func split() -> AnyBashCommand {
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

private func splitFileSuffix(_ index: Int) -> String {
    let alphabet = Array("abcdefghijklmnopqrstuvwxyz")
    let first = alphabet[(index / alphabet.count) % alphabet.count]
    let second = alphabet[index % alphabet.count]
    return "\(first)\(second)"
}

func mktemp() -> AnyBashCommand {
    AnyBashCommand(name: "mktemp") { args, ctx in
        var directory = false
        var template = "tmp.XXXXXXXXXX"
        for arg in args {
            if arg == "-d" { directory = true }
            else if !arg.hasPrefix("-") { template = arg }
        }

        let name = template.replacingOccurrences(of: "XXXXXXXXXX", with: String((0..<10).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement()! }))
            .replacingOccurrences(of: "XXXXXX", with: String((0..<6).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement()! }))
            .replacingOccurrences(of: "XXX", with: String((0..<3).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement()! }))

        let path = "/tmp/\(name)"
        do {
            if directory {
                try ctx.fileSystem.createDirectory(path, recursive: true)
            } else {
                try ctx.fileSystem.writeFile("", to: path)
            }
            return ExecResult.success(path + "\n")
        } catch {
            return ExecResult.failure("mktemp: \(error.localizedDescription)")
        }
    }
}
