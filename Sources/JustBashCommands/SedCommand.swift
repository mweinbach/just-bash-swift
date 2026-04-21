import Foundation
import JustBashFS

func sed() -> AnyBashCommand {
    AnyBashCommand(name: "sed") { args, ctx in
        var inPlace = false
        var scripts: [String] = []
        var files: [String] = []
        var suppressAutoPrint = false
        var i = 0
        while i < args.count {
            switch args[i] {
            case "-i": inPlace = true; i += 1
            case "-e": if i + 1 < args.count { scripts.append(args[i + 1]); i += 2 } else { i += 1 }
            case "-n": suppressAutoPrint = true; i += 1
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
                content = try files.map { 
                    let data = try ctx.fileSystem.readFile(path: $0, relativeTo: ctx.cwd)
                    return String(decoding: data, as: UTF8.self)
                }.joined()
            }
        } catch {
            return ExecResult.failure("sed: \(error.localizedDescription)")
        }

        var result = content
        for script in scripts {
            result = applySedScript(script, to: result, suppressAutoPrint: suppressAutoPrint)
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

// MARK: - Sed Types

private enum SedAddress {
    case none
    case line(Int)
    case lineRange(Int, Int)
    case regex(String)
}

private enum SedCommandType {
    case substitute(pattern: String, replacement: String, flags: String)
    case delete
    case print
    case transliterate(from: String, to: String)
    case quit
    case append(String)
    case insert(String)
    case change(String)
}

private struct SedCommand {
    let address: SedAddress
    let type: SedCommandType
}

// MARK: - Sed Parsing

private func parseSedCommands(_ script: String) -> [SedCommand] {
    // Split on ; or newlines, but not inside regex delimiters
    let rawCommands = splitSedScript(script)
    return rawCommands.compactMap { parseSingleSedCommand($0.trimmingCharacters(in: .whitespaces)) }
}

private func splitSedScript(_ script: String) -> [String] {
    var commands: [String] = []
    var current = ""
    var inDelimited = false
    var delimCount = 0
    var delim: Character = "/"
    let chars = Array(script)
    var i = 0

    while i < chars.count {
        let ch = chars[i]

        if ch == "\\" && i + 1 < chars.count {
            current.append(ch)
            current.append(chars[i + 1])
            i += 2
            continue
        }

        if !inDelimited && (ch == "s" || ch == "y") && i + 1 < chars.count && !chars[i + 1].isNumber {
            // Start of s or y command with delimiter
            inDelimited = true
            delimCount = 0
            delim = chars[i + 1]
            current.append(ch)
            i += 1
            continue
        }

        if inDelimited && ch == delim {
            delimCount += 1
            current.append(ch)
            // s needs 3 delimiters (s/pat/repl/), y needs 3 (y/a/b/)
            if delimCount >= 3 {
                // Consume any trailing flags
                i += 1
                while i < chars.count && chars[i].isLetter {
                    current.append(chars[i])
                    i += 1
                }
                inDelimited = false
                continue
            }
            i += 1
            continue
        }

        if !inDelimited && (ch == ";" || ch == "\n") {
            let trimmed = current.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { commands.append(trimmed) }
            current = ""
            i += 1
            continue
        }

        current.append(ch)
        i += 1
    }

    let trimmed = current.trimmingCharacters(in: .whitespaces)
    if !trimmed.isEmpty { commands.append(trimmed) }
    return commands
}

private func parseSingleSedCommand(_ cmd: String) -> SedCommand? {
    guard !cmd.isEmpty else { return nil }
    let chars = Array(cmd)
    var i = 0

    // Parse address
    let address: SedAddress
    (address, i) = parseAddress(chars, startAt: 0)

    guard i < chars.count else { return nil }

    // Parse command character
    let cmdChar = chars[i]
    switch cmdChar {
    case "s":
        // Substitute
        guard i + 1 < chars.count else { return nil }
        let delim = chars[i + 1]
        var parts: [String] = []
        var current = ""
        var j = i + 2
        while j < chars.count && parts.count < 3 {
            if chars[j] == delim {
                parts.append(current); current = ""; j += 1
            } else if chars[j] == "\\" && j + 1 < chars.count {
                current.append(chars[j + 1]); j += 2
            } else {
                current.append(chars[j]); j += 1
            }
        }
        if parts.count < 2 { parts.append(current) }
        if parts.count < 3 { parts.append(current) }
        let pattern = parts[0]
        let replacement = parts[1]
        let flags = parts.count > 2 ? parts[2] : ""
        return SedCommand(address: address, type: .substitute(pattern: pattern, replacement: replacement, flags: flags))

    case "d":
        return SedCommand(address: address, type: .delete)

    case "p":
        return SedCommand(address: address, type: .print)

    case "q":
        return SedCommand(address: address, type: .quit)

    case "y":
        guard i + 1 < chars.count else { return nil }
        let delim = chars[i + 1]
        var parts: [String] = []
        var current = ""
        var j = i + 2
        while j < chars.count && parts.count < 3 {
            if chars[j] == delim {
                parts.append(current); current = ""; j += 1
            } else if chars[j] == "\\" && j + 1 < chars.count {
                current.append(chars[j + 1]); j += 2
            } else {
                current.append(chars[j]); j += 1
            }
        }
        if parts.count < 2 { parts.append(current) }
        let from = parts[0]
        let to = parts.count > 1 ? parts[1] : ""
        return SedCommand(address: address, type: .transliterate(from: from, to: to))

    case "a":
        let text = extractBackslashText(chars, from: i + 1)
        return SedCommand(address: address, type: .append(text))

    case "i":
        let text = extractBackslashText(chars, from: i + 1)
        return SedCommand(address: address, type: .insert(text))

    case "c":
        let text = extractBackslashText(chars, from: i + 1)
        return SedCommand(address: address, type: .change(text))

    default:
        return nil
    }
}

private func extractBackslashText(_ chars: [Character], from start: Int) -> String {
    var i = start
    // Skip optional backslash
    if i < chars.count && chars[i] == "\\" { i += 1 }
    // Skip optional space
    if i < chars.count && chars[i] == " " { i += 1 }
    return String(chars[i...])
}

private func parseAddress(_ chars: [Character], startAt start: Int) -> (SedAddress, Int) {
    var i = start

    // Skip whitespace
    while i < chars.count && chars[i] == " " { i += 1 }

    guard i < chars.count else { return (.none, i) }

    // Regex address: /pattern/
    if chars[i] == "/" {
        var pattern = ""
        var j = i + 1
        while j < chars.count && chars[j] != "/" {
            if chars[j] == "\\" && j + 1 < chars.count {
                pattern.append(chars[j])
                pattern.append(chars[j + 1])
                j += 2
            } else {
                pattern.append(chars[j])
                j += 1
            }
        }
        if j < chars.count { j += 1 } // skip closing /
        return (.regex(pattern), j)
    }

    // Numeric address
    if chars[i].isNumber {
        var numStr = ""
        while i < chars.count && chars[i].isNumber {
            numStr.append(chars[i])
            i += 1
        }
        guard let lineNum = Int(numStr) else { return (.none, start) }

        // Check for range (N,M)
        if i < chars.count && chars[i] == "," {
            i += 1
            var endStr = ""
            while i < chars.count && chars[i].isNumber {
                endStr.append(chars[i])
                i += 1
            }
            if let endNum = Int(endStr) {
                return (.lineRange(lineNum, endNum), i)
            }
            return (.line(lineNum), i)
        }
        return (.line(lineNum), i)
    }

    return (.none, i)
}

// MARK: - Sed Execution

private func matchesAddress(_ address: SedAddress, line: String, lineNum: Int) -> Bool {
    switch address {
    case .none:
        return true
    case .line(let n):
        return lineNum == n
    case .lineRange(let start, let end):
        return lineNum >= start && lineNum <= end
    case .regex(let pattern):
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(line.startIndex..., in: line)
        return regex.firstMatch(in: line, range: range) != nil
    }
}

private func applySedSubstitute(_ line: String, pattern: String, replacement: String, flags: String) -> String {
    let globalReplace = flags.contains("g")
    do {
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(line.startIndex..., in: line)
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

private func applySedTransliterate(_ line: String, from: String, to: String) -> String {
    let fromChars = Array(from)
    let toChars = Array(to)
    guard fromChars.count == toChars.count else { return line }
    var mapping: [Character: Character] = [:]
    for (f, t) in zip(fromChars, toChars) {
        mapping[f] = t
    }
    return String(line.map { mapping[$0] ?? $0 })
}

private func applySedScript(_ script: String, to input: String, suppressAutoPrint: Bool) -> String {
    let commands = parseSedCommands(script)
    guard !commands.isEmpty else { return input }

    var lines = input.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    if lines.last == "" && input.hasSuffix("\n") { lines.removeLast() }

    var output: [String] = []

    for (lineIdx, line) in lines.enumerated() {
        let lineNum = lineIdx + 1
        var current = line
        var printed = false
        var deleted = false

        for cmd in commands {
            if deleted { break }
            if !matchesAddress(cmd.address, line: current, lineNum: lineNum) { continue }

            switch cmd.type {
            case .substitute(let pattern, let replacement, let flags):
                current = applySedSubstitute(current, pattern: pattern, replacement: replacement, flags: flags)

            case .delete:
                deleted = true

            case .print:
                output.append(current)
                printed = true

            case .transliterate(let from, let to):
                current = applySedTransliterate(current, from: from, to: to)

            case .quit:
                if !suppressAutoPrint { output.append(current) }
                return output.joined(separator: "\n") + (output.isEmpty ? "" : "\n")

            case .append(let text):
                if !suppressAutoPrint && !printed {
                    output.append(current)
                    printed = true
                }
                output.append(text)

            case .insert(let text):
                output.append(text)

            case .change(let text):
                output.append(text)
                deleted = true
            }
        }

        if !deleted && !suppressAutoPrint && !printed {
            output.append(current)
        } else if !deleted && suppressAutoPrint && !printed {
            // In suppress mode, substituted lines are not auto-printed
        }
    }

    return output.joined(separator: "\n") + (output.isEmpty ? "" : "\n")
}
