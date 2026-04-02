import Foundation
import JustBashFS

func cat() -> AnyBashCommand {
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

func tee() -> AnyBashCommand {
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
