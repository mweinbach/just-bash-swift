import Foundation
import JustBashFS

func grep() -> AnyBashCommand {
    AnyBashCommand(name: "grep") { args, ctx in
        var lineNumbers = false
        var caseInsensitive = false
        var invert = false
        var countOnly = false
        var filesOnly = false
        var recursive = false
        var fixedStrings = false
        var wholeWord = false
        var onlyMatching = false
        var quiet = false
        var maxCount = Int.max
        var beforeContext = 0
        var afterContext = 0
        var includePattern: String? = nil
        var excludePattern: String? = nil
        var remaining = args

        while !remaining.isEmpty {
            let arg = remaining[0]
            if !arg.hasPrefix("-") || arg == "-" { break }
            if arg == "--" { remaining.removeFirst(); break }
            remaining.removeFirst()
            if arg.hasPrefix("--include=") { includePattern = String(arg.dropFirst(10)); continue }
            if arg.hasPrefix("--exclude=") { excludePattern = String(arg.dropFirst(10)); continue }
            if arg == "-m" { if !remaining.isEmpty { maxCount = Int(remaining.removeFirst()) ?? Int.max }; continue }
            if arg == "-A" { if !remaining.isEmpty { afterContext = Int(remaining.removeFirst()) ?? 0 }; continue }
            if arg == "-B" { if !remaining.isEmpty { beforeContext = Int(remaining.removeFirst()) ?? 0 }; continue }
            if arg == "-C" { if !remaining.isEmpty { let n = Int(remaining.removeFirst()) ?? 0; beforeContext = n; afterContext = n }; continue }
            if arg == "-e" { break }
            for ch in arg.dropFirst() {
                switch ch {
                case "n": lineNumbers = true
                case "i": caseInsensitive = true
                case "v": invert = true
                case "c": countOnly = true
                case "l": filesOnly = true
                case "r", "R": recursive = true
                case "F": fixedStrings = true
                case "w": wholeWord = true
                case "o": onlyMatching = true
                case "q": quiet = true
                case "E": break
                case "H": break
                case "h": break
                default: break
                }
            }
        }

        guard let pattern = remaining.first else { return ExecResult.failure("grep: missing pattern") }
        let paths = Array(remaining.dropFirst())

        let effectivePattern: String
        if fixedStrings {
            let escaped = NSRegularExpression.escapedPattern(for: pattern)
            effectivePattern = wholeWord ? "\\b\(escaped)\\b" : escaped
        } else {
            effectivePattern = wholeWord ? "\\b\(pattern)\\b" : pattern
        }

        let regex: NSRegularExpression?
        regex = try? NSRegularExpression(pattern: effectivePattern, options: caseInsensitive ? [.caseInsensitive] : [])
        guard let regex else { return ExecResult.failure("grep: invalid pattern") }

        let sources: [(String?, String)]
        do {
            if paths.isEmpty {
                sources = [(nil, ctx.stdin)]
            } else {
                var collected: [(String?, String)] = []
                for path in paths {
                    let normalized = VirtualPath.normalize(path, relativeTo: ctx.cwd)
                    if recursive && ctx.fileSystem.isDirectory(path: normalized, relativeTo: ctx.cwd) {
                        let walked = (try? ctx.fileSystem.walk(path: path, relativeTo: ctx.cwd)) ?? []
                        for child in walked {
                            if !ctx.fileSystem.isDirectory(path: child, relativeTo: ctx.cwd) {
                                let baseName = VirtualPath.basename(child)
                                if let inc = includePattern, !VirtualFileSystem.globMatch(name: baseName, pattern: inc) { continue }
                                if let exc = excludePattern, VirtualFileSystem.globMatch(name: baseName, pattern: exc) { continue }
                                if let content = try? ctx.fileSystem.readFile(path: child, relativeTo: ctx.cwd) {
                                    let contentStr = String(decoding: content, as: UTF8.self)
                                    collected.append((child, contentStr))
                                }
                            }
                        }
                    } else {
                        let data = try ctx.fileSystem.readFile(path: path, relativeTo: ctx.cwd)
                        let content = String(decoding: data, as: UTF8.self)
                        collected.append((path, content))
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
        let useContext = (beforeContext > 0 || afterContext > 0) && !countOnly && !filesOnly

        for (label, content) in sources {
            var fileCount = 0
            let lines = content.split(separator: "\n", omittingEmptySubsequences: false)

            if useContext {
                // First pass: find matching line indices
                var matchingIndices: Set<Int> = []
                for (index, line) in lines.enumerated() {
                    if matchCount + matchingIndices.count >= maxCount { break }
                    let string = String(line)
                    let range = NSRange(location: 0, length: string.utf16.count)
                    let hasMatch = regex.firstMatch(in: string, range: range) != nil
                    if hasMatch != invert {
                        matchingIndices.insert(index)
                    }
                }

                // Second pass: expand to include context lines
                var includedIndices: Set<Int> = []
                for idx in matchingIndices {
                    let start = max(0, idx - beforeContext)
                    let end = min(lines.count - 1, idx + afterContext)
                    for i in start...end {
                        includedIndices.insert(i)
                    }
                }

                // Output included lines with group separators
                let sortedIndices = includedIndices.sorted()
                var prevIndex = -2
                for idx in sortedIndices {
                    if prevIndex >= 0 && idx > prevIndex + 1 {
                        output.append("--")
                    }
                    let string = String(lines[idx])
                    let isMatch = matchingIndices.contains(idx)
                    let separator: String = isMatch ? ":" : "-"
                    var rendered = string
                    if lineNumbers { rendered = "\(idx + 1)\(separator)\(rendered)" }
                    if let label, multiFile { rendered = "\(label)\(separator)\(rendered)" }
                    output.append(rendered)
                    if isMatch { fileCount += 1 }
                    prevIndex = idx
                }
                matchCount += fileCount
            } else {
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
                    if !countOnly && !quiet {
                        if onlyMatching && !invert {
                            let nsRange = NSRange(location: 0, length: string.utf16.count)
                            regex.enumerateMatches(in: string, range: nsRange) { match, _, _ in
                                if let match, let swiftRange = Range(match.range, in: string) {
                                    var rendered = String(string[swiftRange])
                                    if lineNumbers { rendered = "\(index + 1):\(rendered)" }
                                    if let label, multiFile { rendered = "\(label):\(rendered)" }
                                    output.append(rendered)
                                }
                            }
                        } else {
                            var rendered = string
                            if lineNumbers { rendered = "\(index + 1):\(rendered)" }
                            if let label, multiFile { rendered = "\(label):\(rendered)" }
                            output.append(rendered)
                        }
                    }
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

        if quiet {
            return ExecResult(stdout: "", stderr: "", exitCode: matchCount > 0 ? 0 : 1)
        }

        if filesOnly {
            output = matchedFiles.sorted()
        }

        if output.isEmpty && !countOnly { return ExecResult(stdout: "", stderr: "", exitCode: 1) }
        return ExecResult.success(output.joined(separator: "\n") + "\n")
    }
}

func egrep() -> AnyBashCommand {
    AnyBashCommand(name: "egrep") { args, ctx in
        await grep().execute(args, ctx)
    }
}

func fgrep() -> AnyBashCommand {
    AnyBashCommand(name: "fgrep") { args, ctx in
        await grep().execute(["-F"] + args, ctx)
    }
}

func rg() -> AnyBashCommand {
    AnyBashCommand(name: "rg") { args, ctx in
        await grep().execute(["-r"] + args, ctx)
    }
}
