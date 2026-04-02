import Foundation
import JustBashFS

func xargs() -> AnyBashCommand {
    AnyBashCommand(name: "xargs") { args, ctx in
        var command = ["echo"]
        var maxArgs = Int.max
        var delimiter: Character = "\n"
        var replaceString: String? = nil
        var i = 0
        while i < args.count {
            switch args[i] {
            case "-n": if i + 1 < args.count { maxArgs = Int(args[i + 1]) ?? Int.max; i += 2 } else { i += 1 }
            case "-d": if i + 1 < args.count { delimiter = args[i + 1].first ?? "\n"; i += 2 } else { i += 1 }
            case "-0": delimiter = "\0"; i += 1
            case "-I":
                if i + 1 < args.count { replaceString = args[i + 1]; i += 2 }
                else { i += 1 }
            default: command = Array(args[i...]); i = args.count
            }
        }

        let items = ctx.stdin.split(separator: delimiter).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard let executor = ctx.executeSubshell else {
            let fullCommand = (command + items).joined(separator: " ")
            return ExecResult.success(fullCommand + "\n")
        }

        var combined = ExecResult()

        if let replaceStr = replaceString {
            for item in items {
                let script = command.joined(separator: " ").replacingOccurrences(of: replaceStr, with: item)
                let result = await executor(script)
                combined.stdout += result.stdout
                combined.stderr += result.stderr
                combined.exitCode = result.exitCode
            }
            return combined
        }

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

func diff() -> AnyBashCommand {
    AnyBashCommand(name: "diff") { args, ctx in
        var unified = false
        var files: [String] = []
        for arg in args {
            if arg == "-u" { unified = true }
            else if !arg.hasPrefix("-") { files.append(arg) }
        }
        guard files.count >= 2 else { return ExecResult.failure("diff: missing operand") }
        do {
            let a = try ctx.fileSystem.readFile(files[0], relativeTo: ctx.cwd)
            let b = try ctx.fileSystem.readFile(files[1], relativeTo: ctx.cwd)
            if a == b { return ExecResult.success() }
            let aLines = a.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let bLines = b.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

            if unified {
                var output = "--- \(files[0])\n+++ \(files[1])\n"

                // Build diff lines via simple walk
                var aIdx = 0, bIdx = 0
                var diffLines: [(tag: Character, line: String)] = []
                while aIdx < aLines.count || bIdx < bLines.count {
                    if aIdx < aLines.count && bIdx < bLines.count && aLines[aIdx] == bLines[bIdx] {
                        diffLines.append((" ", aLines[aIdx]))
                        aIdx += 1; bIdx += 1
                    } else if bIdx < bLines.count && (aIdx >= aLines.count || (bIdx + 1 < bLines.count && aIdx < aLines.count && aLines[aIdx] == bLines[bIdx + 1])) {
                        diffLines.append(("+", bLines[bIdx]))
                        bIdx += 1
                    } else if aIdx < aLines.count {
                        diffLines.append(("-", aLines[aIdx]))
                        aIdx += 1
                    } else {
                        diffLines.append(("+", bLines[bIdx]))
                        bIdx += 1
                    }
                }

                // Group into hunks with 3 lines of context
                let contextSize = 3
                var hunkRanges: [(start: Int, end: Int)] = []
                for (i, dl) in diffLines.enumerated() {
                    if dl.tag != " " {
                        let start = max(0, i - contextSize)
                        let end = min(diffLines.count - 1, i + contextSize)
                        if let last = hunkRanges.last, start <= last.end + 1 {
                            hunkRanges[hunkRanges.count - 1] = (last.start, end)
                        } else {
                            hunkRanges.append((start, end))
                        }
                    }
                }

                if hunkRanges.isEmpty {
                    hunkRanges = [(0, diffLines.count - 1)]
                }

                for range in hunkRanges {
                    var aCount = 0, bCount = 0
                    var aCur = 0, bCur = 0
                    for i in 0..<range.start {
                        if diffLines[i].tag == " " || diffLines[i].tag == "-" { aCur += 1 }
                        if diffLines[i].tag == " " || diffLines[i].tag == "+" { bCur += 1 }
                    }
                    let aStart = aCur + 1
                    let bStart = bCur + 1
                    for i in range.start...range.end {
                        if diffLines[i].tag == " " || diffLines[i].tag == "-" { aCount += 1 }
                        if diffLines[i].tag == " " || diffLines[i].tag == "+" { bCount += 1 }
                    }
                    output += "@@ -\(aStart),\(aCount) +\(bStart),\(bCount) @@\n"
                    for i in range.start...range.end {
                        output += "\(diffLines[i].tag)\(diffLines[i].line)\n"
                    }
                }

                return ExecResult(stdout: output, stderr: "", exitCode: 1)
            } else {
                var output = ""
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
            }
        } catch {
            return ExecResult.failure("diff: \(error.localizedDescription)")
        }
    }
}

func comm() -> AnyBashCommand {
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

func date() -> AnyBashCommand {
    AnyBashCommand(name: "date") { args, ctx in
        let now = Date()
        let formatter = DateFormatter()
        if let formatArg = args.first(where: { $0.hasPrefix("+") }) {
            var format = String(formatArg.dropFirst())
            let epochStr = String(Int(now.timeIntervalSince1970))
            // Replace %s with the epoch seconds value before converting other specifiers
            format = format.replacingOccurrences(of: "%Y", with: "yyyy")
            format = format.replacingOccurrences(of: "%m", with: "MM")
            format = format.replacingOccurrences(of: "%d", with: "dd")
            format = format.replacingOccurrences(of: "%H", with: "HH")
            format = format.replacingOccurrences(of: "%M", with: "mm")
            format = format.replacingOccurrences(of: "%S", with: "ss")
            let hasEpoch = format.contains("%s")
            format = format.replacingOccurrences(of: "%s", with: "")
            if format.isEmpty && hasEpoch {
                return ExecResult.success(epochStr + "\n")
            }
            formatter.dateFormat = format
            var result = formatter.string(from: now)
            if hasEpoch {
                // The %s was embedded in a larger format; we removed it from the DateFormatter
                // format string. Re-insert epoch at the position where %s was.
                // Rebuild: replace %s placeholder in the original translated format with epochStr.
                // Simpler approach: re-process the original format string with %s replaced by epoch value.
                var rebuiltFormat = String(formatArg.dropFirst())
                rebuiltFormat = rebuiltFormat.replacingOccurrences(of: "%s", with: "'\(epochStr)'")
                rebuiltFormat = rebuiltFormat.replacingOccurrences(of: "%Y", with: "yyyy")
                rebuiltFormat = rebuiltFormat.replacingOccurrences(of: "%m", with: "MM")
                rebuiltFormat = rebuiltFormat.replacingOccurrences(of: "%d", with: "dd")
                rebuiltFormat = rebuiltFormat.replacingOccurrences(of: "%H", with: "HH")
                rebuiltFormat = rebuiltFormat.replacingOccurrences(of: "%M", with: "mm")
                rebuiltFormat = rebuiltFormat.replacingOccurrences(of: "%S", with: "ss")
                formatter.dateFormat = rebuiltFormat
                result = formatter.string(from: now)
            }
            return ExecResult.success(result + "\n")
        } else {
            formatter.dateFormat = "EEE MMM dd HH:mm:ss zzz yyyy"
        }
        return ExecResult.success(formatter.string(from: now) + "\n")
    }
}

func sleep_() -> AnyBashCommand {
    AnyBashCommand(name: "sleep") { args, _ in
        if args.isEmpty { return ExecResult.failure("sleep: missing operand") }
        return ExecResult.success()
    }
}

func uname() -> AnyBashCommand {
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

func hostname() -> AnyBashCommand {
    AnyBashCommand(name: "hostname") { _, _ in
        ExecResult.success("localhost\n")
    }
}

func whoami() -> AnyBashCommand {
    AnyBashCommand(name: "whoami") { _, ctx in
        ExecResult.success((ctx.environment["USER"] ?? "user") + "\n")
    }
}

func clear() -> AnyBashCommand {
    AnyBashCommand(name: "clear") { _, _ in
        ExecResult.success()
    }
}

func help() -> AnyBashCommand {
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

func history() -> AnyBashCommand {
    AnyBashCommand(name: "history") { _, _ in
        ExecResult.success()
    }
}

func tput() -> AnyBashCommand {
    AnyBashCommand(name: "tput") { args, _ in
        guard let cap = args.first else { return ExecResult.failure("tput: missing operand") }
        switch cap {
        case "cols": return ExecResult.success("80\n")
        case "lines": return ExecResult.success("24\n")
        case "colors": return ExecResult.success("256\n")
        case "setaf":
            let code = args.count > 1 ? (Int(args[1]) ?? 0) : 0
            return ExecResult.success("\u{1B}[3\(code)m")
        case "setab":
            let code = args.count > 1 ? (Int(args[1]) ?? 0) : 0
            return ExecResult.success("\u{1B}[4\(code)m")
        case "sgr0": return ExecResult.success("\u{1B}[0m")
        case "bold": return ExecResult.success("\u{1B}[1m")
        case "smul": return ExecResult.success("\u{1B}[4m")
        case "rmul": return ExecResult.success("\u{1B}[24m")
        case "rev": return ExecResult.success("\u{1B}[7m")
        case "sc": return ExecResult.success("\u{1B}[s")
        case "rc": return ExecResult.success("\u{1B}[u")
        case "clear", "cl": return ExecResult.success("\u{1B}[H\u{1B}[2J")
        case "el": return ExecResult.success("\u{1B}[K")
        case "cup":
            let row = args.count > 1 ? (Int(args[1]) ?? 0) : 0
            let col = args.count > 2 ? (Int(args[2]) ?? 0) : 0
            return ExecResult.success("\u{1B}[\(row + 1);\(col + 1)H")
        case "civis": return ExecResult.success("\u{1B}[?25l")
        case "cnorm": return ExecResult.success("\u{1B}[?25h")
        default: return ExecResult.success("")
        }
    }
}

func getconf() -> AnyBashCommand {
    AnyBashCommand(name: "getconf") { args, _ in
        guard let key = args.first else { return ExecResult.failure("getconf: missing operand") }
        switch key {
        case "_NPROCESSORS_ONLN", "NPROCESSORS_ONLN": return ExecResult.success("4\n")
        case "_NPROCESSORS_CONF", "NPROCESSORS_CONF": return ExecResult.success("4\n")
        case "PAGE_SIZE", "PAGESIZE": return ExecResult.success("4096\n")
        case "LONG_BIT": return ExecResult.success("64\n")
        case "INT_MAX": return ExecResult.success("2147483647\n")
        case "UINT_MAX": return ExecResult.success("4294967295\n")
        case "PATH_MAX": return ExecResult.success("4096\n")
        case "NAME_MAX": return ExecResult.success("255\n")
        case "LINE_MAX": return ExecResult.success("2048\n")
        case "CHAR_BIT": return ExecResult.success("8\n")
        case "CLK_TCK": return ExecResult.success("100\n")
        default: return ExecResult.failure("getconf: unrecognized variable `\(key)'")
        }
    }
}

func nproc() -> AnyBashCommand {
    AnyBashCommand(name: "nproc") { _, _ in
        ExecResult.success("4\n")
    }
}

func env() -> AnyBashCommand {
    AnyBashCommand(name: "env") { args, ctx in
        var cleanEnv = false
        var envOverrides: [(String, String)] = []
        var commandArgs: [String] = []
        var i = 0
        while i < args.count {
            if args[i] == "-i" || args[i] == "--ignore-environment" {
                cleanEnv = true
                i += 1
            } else if args[i] == "-u" || args[i] == "--unset" {
                i += 1  // skip -u
                i += 1  // skip the var name (we don't track unsets beyond clean)
            } else if args[i].contains("=") && commandArgs.isEmpty {
                let parts = args[i].split(separator: "=", maxSplits: 1)
                envOverrides.append((String(parts[0]), parts.count > 1 ? String(parts[1]) : ""))
                i += 1
            } else {
                commandArgs = Array(args[i...])
                break
            }
        }

        // If no command, print environment
        if commandArgs.isEmpty {
            var env = cleanEnv ? [String: String]() : ctx.environment
            for (k, v) in envOverrides { env[k] = v }
            let rendered = env.keys.sorted().map { "\($0)=\(env[$0] ?? "")" }.joined(separator: "\n")
            return ExecResult.success(rendered + (rendered.isEmpty ? "" : "\n"))
        }

        // Execute command with modified environment
        guard let executor = ctx.executeSubshell else {
            return ExecResult.failure("env: shell execution unavailable")
        }
        // Build env prefix for the subshell
        var prefix = ""
        if cleanEnv { prefix += "env -i " }
        for (k, v) in envOverrides { prefix += "\(k)=\(v) " }
        let script = prefix + commandArgs.joined(separator: " ")
        return await executor(script)
    }
}
