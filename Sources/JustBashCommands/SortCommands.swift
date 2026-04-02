import Foundation
import JustBashFS

func sort() -> AnyBashCommand {
    AnyBashCommand(name: "sort") { args, ctx in
        var reverse = false
        var numeric = false
        var unique = false
        var foldCase = false
        var versionSort = false
        var humanNumeric = false
        var key: Int? = nil
        var delimiter: Character? = nil
        var files: [String] = []
        var i = 0
        while i < args.count {
            switch args[i] {
            case "-r": reverse = true; i += 1
            case "-n": numeric = true; i += 1
            case "-u": unique = true; i += 1
            case "-f": foldCase = true; i += 1
            case "-V": versionSort = true; i += 1
            case "-h": humanNumeric = true; i += 1
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
            if humanNumeric {
                return parseHumanSize(aKey.trimmingCharacters(in: .whitespaces)) < parseHumanSize(bKey.trimmingCharacters(in: .whitespaces))
            }
            if versionSort {
                return versionCompare(aKey, bKey)
            }
            if numeric {
                return (Double(aKey.trimmingCharacters(in: .whitespaces)) ?? 0) < (Double(bKey.trimmingCharacters(in: .whitespaces)) ?? 0)
            }
            if foldCase {
                return aKey.lowercased() < bKey.lowercased()
            }
            return aKey < bKey
        }

        if reverse { lines.reverse() }
        if unique { lines = Array(NSOrderedSet(array: lines)) as! [String] }

        if lines.isEmpty { return ExecResult.success() }
        return ExecResult.success(lines.joined(separator: "\n") + "\n")
    }
}

private func parseHumanSize(_ s: String) -> Double {
    let trimmed = s.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return 0 }
    let last = trimmed.last!
    let multipliers: [Character: Double] = ["K": 1024, "M": 1024*1024, "G": 1024*1024*1024, "T": 1024*1024*1024*1024]
    if let mult = multipliers[last.uppercased().first!], last.isLetter {
        return (Double(String(trimmed.dropLast())) ?? 0) * mult
    }
    return Double(trimmed) ?? 0
}

private func versionCompare(_ a: String, _ b: String) -> Bool {
    let aSegments = splitVersionSegments(a)
    let bSegments = splitVersionSegments(b)
    let count = max(aSegments.count, bSegments.count)
    for i in 0..<count {
        if i >= aSegments.count { return true }
        if i >= bSegments.count { return false }
        let (aStr, aNum) = aSegments[i]
        let (bStr, bNum) = bSegments[i]
        if let an = aNum, let bn = bNum {
            if an != bn { return an < bn }
        } else if aNum != nil && bNum == nil {
            return true
        } else if aNum == nil && bNum != nil {
            return false
        } else {
            if aStr != bStr { return aStr < bStr }
        }
    }
    return false
}

private func splitVersionSegments(_ s: String) -> [(String, Int?)] {
    var segments: [(String, Int?)] = []
    var current = ""
    var inDigits = false
    for ch in s {
        let isDigit = ch.isNumber
        if current.isEmpty {
            current.append(ch)
            inDigits = isDigit
        } else if isDigit == inDigits {
            current.append(ch)
        } else {
            if inDigits {
                segments.append((current, Int(current)))
            } else {
                segments.append((current, nil))
            }
            current = String(ch)
            inDigits = isDigit
        }
    }
    if !current.isEmpty {
        if inDigits {
            segments.append((current, Int(current)))
        } else {
            segments.append((current, nil))
        }
    }
    return segments
}

func uniq() -> AnyBashCommand {
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
