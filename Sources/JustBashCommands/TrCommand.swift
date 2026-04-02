import Foundation

func tr() -> AnyBashCommand {
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
