import Foundation
import CryptoKit

func seq() -> AnyBashCommand {
    AnyBashCommand(name: "seq") { args, ctx in
        var separator = "\n"
        var format: String? = nil
        var nums: [Double] = []
        var i = 0
        while i < args.count {
            if args[i] == "-s" { if i + 1 < args.count { separator = args[i + 1]; i += 2 } else { i += 1 } }
            else if args[i] == "-f" { if i + 1 < args.count { format = args[i + 1]; i += 2 } else { i += 1 } }
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
            while current <= end + 0.0001 {
                if let fmt = format {
                    values.append(String(format: fmt, current))
                } else {
                    values.append(current == Double(Int(current)) ? String(Int(current)) : String(current))
                }
                current += step
            }
        } else if step < 0 {
            while current >= end - 0.0001 {
                if let fmt = format {
                    values.append(String(format: fmt, current))
                } else {
                    values.append(current == Double(Int(current)) ? String(Int(current)) : String(current))
                }
                current += step
            }
        }
        return ExecResult.success(values.joined(separator: separator) + "\n")
    }
}

func yes() -> AnyBashCommand {
    AnyBashCommand(name: "yes") { args, ctx in
        let text = args.isEmpty ? "y" : args.joined(separator: " ")
        let output = (0..<100).map { _ in text }.joined(separator: "\n") + "\n"
        return ExecResult.success(output)
    }
}

func base64() -> AnyBashCommand {
    AnyBashCommand(name: "base64") { args, ctx in
        var decode = false
        var wrapWidth = 76
        var files: [String] = []
        var i = 0
        while i < args.count {
            switch args[i] {
            case "-d", "--decode":
                decode = true; i += 1
            case "-w", "--wrap":
                if i + 1 < args.count { wrapWidth = Int(args[i + 1]) ?? 76; i += 2 } else { i += 1 }
            default:
                if args[i].hasPrefix("-") { i += 1 } else { files.append(args[i]); i += 1 }
            }
        }
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

        var encoded = Data(content.utf8).base64EncodedString()
        if wrapWidth > 0 {
            var wrapped = ""
            for (i, ch) in encoded.enumerated() {
                wrapped.append(ch)
                if (i + 1) % wrapWidth == 0 { wrapped.append("\n") }
            }
            encoded = wrapped
        }
        return ExecResult.success(encoded + "\n")
    }
}

func expr() -> AnyBashCommand {
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

func md5sum() -> AnyBashCommand {
    checksumCommand(name: "md5sum", hash: { data in
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    })
}

func sha1sum() -> AnyBashCommand {
    checksumCommand(name: "sha1sum", hash: { data in
        Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
    })
}

func sha256sum() -> AnyBashCommand {
    checksumCommand(name: "sha256sum", hash: { data in
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    })
}

func bc() -> AnyBashCommand {
    AnyBashCommand(name: "bc") { args, ctx in
        let input = args.filter({ !$0.hasPrefix("-") }).isEmpty ? ctx.stdin : args.filter({ !$0.hasPrefix("-") }).joined(separator: "\n")
        var scale = args.contains("-l") ? 20 : 0
        var output: [String] = []

        for line in input.split(separator: "\n").map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed == "quit" || trimmed == "halt" { continue }
            if trimmed.hasPrefix("scale=") {
                scale = Int(String(trimmed.dropFirst(6))) ?? scale
                continue
            }
            let result = evaluateBCExpression(trimmed, scale: scale)
            if let result { output.append(result) }
        }

        if output.isEmpty { return ExecResult.success() }
        return ExecResult.success(output.joined(separator: "\n") + "\n")
    }
}

private func evaluateBCExpression(_ expr: String, scale: Int) -> String? {
    var pos = expr.startIndex

    func peek() -> Character? {
        pos < expr.endIndex ? expr[pos] : nil
    }

    func advance() {
        pos = expr.index(after: pos)
    }

    func skipSpaces() {
        while let ch = peek(), ch == " " { advance() }
    }

    func parseNumber() -> Double? {
        skipSpaces()
        var numStr = ""
        if peek() == "-" {
            // Only treat as unary minus if at start or after operator
            numStr.append("-")
            advance()
        }
        while let ch = peek(), ch.isNumber || ch == "." {
            numStr.append(ch)
            advance()
        }
        return Double(numStr)
    }

    func parseAtom() -> Double? {
        skipSpaces()
        guard let ch = peek() else { return nil }

        // Handle sqrt(...)
        if ch == "s" {
            let remaining = String(expr[pos...])
            if remaining.hasPrefix("sqrt(") {
                for _ in 0..<5 { advance() }
                guard let inner = parseExpression() else { return nil }
                skipSpaces()
                if peek() == ")" { advance() }
                return Foundation.sqrt(inner)
            }
        }

        // Handle parentheses
        if ch == "(" {
            advance()
            let val = parseExpression()
            skipSpaces()
            if peek() == ")" { advance() }
            return val
        }

        // Handle unary minus
        if ch == "-" {
            advance()
            guard let atom = parseAtom() else { return nil }
            return -atom
        }

        return parseNumber()
    }

    func parsePower() -> Double? {
        guard var left = parseAtom() else { return nil }
        skipSpaces()
        if peek() == "^" {
            advance()
            guard let right = parsePower() else { return left }
            left = Foundation.pow(left, right)
        }
        return left
    }

    func parseMulDiv() -> Double? {
        guard var left = parsePower() else { return nil }
        while true {
            skipSpaces()
            guard let op = peek() else { break }
            if op == "*" || op == "/" || op == "%" {
                advance()
                guard let right = parsePower() else { break }
                switch op {
                case "*": left *= right
                case "/": left = right == 0 ? 0 : left / right
                case "%": left = right == 0 ? 0 : left.truncatingRemainder(dividingBy: right)
                default: break
                }
            } else {
                break
            }
        }
        return left
    }

    func parseExpression() -> Double? {
        guard var left = parseMulDiv() else { return nil }
        while true {
            skipSpaces()
            guard let op = peek() else { break }
            if op == "+" || op == "-" {
                advance()
                guard let right = parseMulDiv() else { break }
                if op == "+" { left += right } else { left -= right }
            } else {
                break
            }
        }
        return left
    }

    guard let result = parseExpression() else { return nil }

    if scale == 0 {
        return String(Int(result))
    } else {
        return String(format: "%.\(scale)f", result)
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
