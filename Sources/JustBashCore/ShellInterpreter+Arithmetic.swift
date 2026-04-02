import Foundation

extension ShellInterpreter {

    // MARK: - Arithmetic

    func evaluateArithmetic(_ expr: String, session: inout ShellSession) -> Int {
        let expanded = expandArithDollarVars(expr, session: session)
        return parseArithExpr(expanded, session: &session)
    }

    private func expandArithDollarVars(_ expr: String, session: ShellSession) -> String {
        // Only expand $var and ${var} forms; bare variable names are handled by the parser
        var result = ""
        let chars = Array(expr)
        var i = 0
        while i < chars.count {
            if chars[i] == "$" {
                i += 1
                if i < chars.count && chars[i] == "{" {
                    i += 1
                    var name = ""
                    while i < chars.count && chars[i] != "}" { name.append(chars[i]); i += 1 }
                    if i < chars.count { i += 1 }
                    result += session.getVariable(name) ?? "0"
                } else {
                    var name = ""
                    while i < chars.count && (chars[i].isLetter || chars[i].isNumber || chars[i] == "_") {
                        name.append(chars[i]); i += 1
                    }
                    result += session.getVariable(name) ?? "0"
                }
            } else {
                result.append(chars[i]); i += 1
            }
        }
        return result
    }

    private func parseArithExpr(_ expr: String, session: inout ShellSession) -> Int {
        var tokens = tokenizeArith(expr)
        return parseArithTernary(&tokens, session: &session)
    }

    private struct ArithToken {
        enum Kind { case number(Int), op(String), variable(String) }
        var kind: Kind
    }

    private func tokenizeArith(_ expr: String) -> [ArithToken] {
        var tokens: [ArithToken] = []
        let chars = Array(expr.trimmingCharacters(in: .whitespaces))
        var i = 0
        while i < chars.count {
            if chars[i].isWhitespace { i += 1; continue }
            // Variable names (identifiers)
            if chars[i].isLetter || chars[i] == "_" {
                var name = ""
                while i < chars.count && (chars[i].isLetter || chars[i].isNumber || chars[i] == "_") {
                    name.append(chars[i]); i += 1
                }
                tokens.append(ArithToken(kind: .variable(name)))
            } else if chars[i].isNumber || (chars[i] == "-" && (tokens.isEmpty || { if case .op = tokens.last?.kind { return true }; return false }())) {
                var numStr = ""
                if chars[i] == "-" { numStr.append("-"); i += 1 }
                if i < chars.count && chars[i] == "0" && i + 1 < chars.count && (chars[i + 1] == "x" || chars[i + 1] == "X") {
                    i += 2
                    while i < chars.count && chars[i].isHexDigit { numStr.append(chars[i]); i += 1 }
                    tokens.append(ArithToken(kind: .number(Int(numStr, radix: 16) ?? 0)))
                } else {
                    while i < chars.count && chars[i].isNumber { numStr.append(chars[i]); i += 1 }
                    tokens.append(ArithToken(kind: .number(Int(numStr) ?? 0)))
                }
            } else {
                let twoChar = i + 1 < chars.count ? String(chars[i]) + String(chars[i + 1]) : ""
                let threeChar = i + 2 < chars.count ? twoChar + String(chars[i + 2]) : ""
                if ["<<=", ">>="].contains(threeChar) {
                    tokens.append(ArithToken(kind: .op(threeChar))); i += 3
                } else if ["==", "!=", "<=", ">=", "&&", "||", "<<", ">>", "**", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "++", "--"].contains(twoChar) {
                    tokens.append(ArithToken(kind: .op(twoChar))); i += 2
                } else {
                    tokens.append(ArithToken(kind: .op(String(chars[i])))); i += 1
                }
            }
        }
        return tokens
    }

    private func parseArithTernary(_ tokens: inout [ArithToken], session: inout ShellSession) -> Int {
        let val = parseArithOr(&tokens, session: &session)
        if tokens.first.map({ if case .op("?") = $0.kind { return true }; return false }) == true {
            tokens.removeFirst()
            let trueVal = parseArithTernary(&tokens, session: &session)
            if tokens.first.map({ if case .op(":") = $0.kind { return true }; return false }) == true {
                tokens.removeFirst()
            }
            let falseVal = parseArithTernary(&tokens, session: &session)
            return val != 0 ? trueVal : falseVal
        }
        return val
    }

    private func parseArithOr(_ tokens: inout [ArithToken], session: inout ShellSession) -> Int {
        var val = parseArithAnd(&tokens, session: &session)
        while tokens.first.map({ if case .op("||") = $0.kind { return true }; return false }) == true {
            tokens.removeFirst()
            let right = parseArithAnd(&tokens, session: &session)
            val = (val != 0 || right != 0) ? 1 : 0
        }
        return val
    }

    private func parseArithAnd(_ tokens: inout [ArithToken], session: inout ShellSession) -> Int {
        var val = parseArithBitOr(&tokens, session: &session)
        while tokens.first.map({ if case .op("&&") = $0.kind { return true }; return false }) == true {
            tokens.removeFirst()
            let right = parseArithBitOr(&tokens, session: &session)
            val = (val != 0 && right != 0) ? 1 : 0
        }
        return val
    }

    private func parseArithBitOr(_ tokens: inout [ArithToken], session: inout ShellSession) -> Int {
        var val = parseArithBitXor(&tokens, session: &session)
        while tokens.first.map({ if case .op("|") = $0.kind { return true }; return false }) == true {
            tokens.removeFirst(); val |= parseArithBitXor(&tokens, session: &session)
        }
        return val
    }

    private func parseArithBitXor(_ tokens: inout [ArithToken], session: inout ShellSession) -> Int {
        var val = parseArithBitAnd(&tokens, session: &session)
        while tokens.first.map({ if case .op("^") = $0.kind { return true }; return false }) == true {
            tokens.removeFirst(); val ^= parseArithBitAnd(&tokens, session: &session)
        }
        return val
    }

    private func parseArithBitAnd(_ tokens: inout [ArithToken], session: inout ShellSession) -> Int {
        var val = parseArithEquality(&tokens, session: &session)
        while tokens.first.map({ if case .op("&") = $0.kind { return true }; return false }) == true {
            tokens.removeFirst(); val &= parseArithEquality(&tokens, session: &session)
        }
        return val
    }

    private func parseArithEquality(_ tokens: inout [ArithToken], session: inout ShellSession) -> Int {
        var val = parseArithComparison(&tokens, session: &session)
        while let tok = tokens.first {
            if case .op(let op) = tok.kind, op == "==" || op == "!=" {
                tokens.removeFirst()
                let right = parseArithComparison(&tokens, session: &session)
                val = op == "==" ? (val == right ? 1 : 0) : (val != right ? 1 : 0)
            } else { break }
        }
        return val
    }

    private func parseArithComparison(_ tokens: inout [ArithToken], session: inout ShellSession) -> Int {
        var val = parseArithShift(&tokens, session: &session)
        while let tok = tokens.first {
            if case .op(let op) = tok.kind, ["<", ">", "<=", ">="].contains(op) {
                tokens.removeFirst()
                let right = parseArithShift(&tokens, session: &session)
                switch op {
                case "<": val = val < right ? 1 : 0
                case ">": val = val > right ? 1 : 0
                case "<=": val = val <= right ? 1 : 0
                case ">=": val = val >= right ? 1 : 0
                default: break
                }
            } else { break }
        }
        return val
    }

    private func parseArithShift(_ tokens: inout [ArithToken], session: inout ShellSession) -> Int {
        var val = parseArithAdd(&tokens, session: &session)
        while let tok = tokens.first {
            if case .op(let op) = tok.kind, op == "<<" || op == ">>" {
                tokens.removeFirst()
                let right = parseArithAdd(&tokens, session: &session)
                val = op == "<<" ? val << right : val >> right
            } else { break }
        }
        return val
    }

    private func parseArithAdd(_ tokens: inout [ArithToken], session: inout ShellSession) -> Int {
        var val = parseArithMul(&tokens, session: &session)
        while let tok = tokens.first {
            if case .op(let op) = tok.kind, op == "+" || op == "-" {
                tokens.removeFirst()
                let right = parseArithMul(&tokens, session: &session)
                val = op == "+" ? val + right : val - right
            } else { break }
        }
        return val
    }

    private func parseArithMul(_ tokens: inout [ArithToken], session: inout ShellSession) -> Int {
        var val = parseArithPower(&tokens, session: &session)
        while let tok = tokens.first {
            if case .op(let op) = tok.kind, op == "*" || op == "/" || op == "%" {
                tokens.removeFirst()
                let right = parseArithPower(&tokens, session: &session)
                switch op {
                case "*": val = val * right
                case "/": val = right == 0 ? 0 : val / right
                case "%": val = right == 0 ? 0 : val % right
                default: break
                }
            } else { break }
        }
        return val
    }

    private func parseArithPower(_ tokens: inout [ArithToken], session: inout ShellSession) -> Int {
        let base = parseArithUnary(&tokens, session: &session)
        if tokens.first.map({ if case .op("**") = $0.kind { return true }; return false }) == true {
            tokens.removeFirst()
            let exp = parseArithPower(&tokens, session: &session)
            if exp < 0 { return 0 }
            var result = 1
            for _ in 0..<exp { result *= base }
            return result
        }
        return base
    }

    private func parseArithUnary(_ tokens: inout [ArithToken], session: inout ShellSession) -> Int {
        if let tok = tokens.first {
            if case .op(let op) = tok.kind {
                if op == "!" { tokens.removeFirst(); return parseArithUnary(&tokens, session: &session) == 0 ? 1 : 0 }
                if op == "~" { tokens.removeFirst(); return ~parseArithUnary(&tokens, session: &session) }
                if op == "+" { tokens.removeFirst(); return parseArithUnary(&tokens, session: &session) }
                if op == "-" { tokens.removeFirst(); return -parseArithUnary(&tokens, session: &session) }
                if op == "++" {
                    // Pre-increment: ++var
                    tokens.removeFirst()
                    if case .variable(let name) = tokens.first?.kind {
                        tokens.removeFirst()
                        let val = Int(session.getVariable(name) ?? "0") ?? 0
                        let newVal = val + 1
                        session.setVariable(name, String(newVal))
                        return newVal
                    }
                    return 0
                }
                if op == "--" {
                    // Pre-decrement: --var
                    tokens.removeFirst()
                    if case .variable(let name) = tokens.first?.kind {
                        tokens.removeFirst()
                        let val = Int(session.getVariable(name) ?? "0") ?? 0
                        let newVal = val - 1
                        session.setVariable(name, String(newVal))
                        return newVal
                    }
                    return 0
                }
                if op == "(" {
                    tokens.removeFirst()
                    let val = parseArithTernary(&tokens, session: &session)
                    if tokens.first.map({ if case .op(")") = $0.kind { return true }; return false }) == true {
                        tokens.removeFirst()
                    }
                    return val
                }
            }
            if case .variable(let name) = tok.kind {
                tokens.removeFirst()
                let currentVal = Int(session.getVariable(name) ?? "0") ?? 0
                // Check for postfix ++ / --
                if let nextTok = tokens.first, case .op(let op) = nextTok.kind {
                    if op == "++" {
                        tokens.removeFirst()
                        session.setVariable(name, String(currentVal + 1))
                        return currentVal // post-increment returns old value
                    }
                    if op == "--" {
                        tokens.removeFirst()
                        session.setVariable(name, String(currentVal - 1))
                        return currentVal // post-decrement returns old value
                    }
                    // Assignment operators
                    if op == "=" {
                        tokens.removeFirst()
                        let rhs = parseArithTernary(&tokens, session: &session)
                        session.setVariable(name, String(rhs))
                        return rhs
                    }
                    if op == "+=" {
                        tokens.removeFirst()
                        let rhs = parseArithTernary(&tokens, session: &session)
                        let newVal = currentVal + rhs
                        session.setVariable(name, String(newVal))
                        return newVal
                    }
                    if op == "-=" {
                        tokens.removeFirst()
                        let rhs = parseArithTernary(&tokens, session: &session)
                        let newVal = currentVal - rhs
                        session.setVariable(name, String(newVal))
                        return newVal
                    }
                    if op == "*=" {
                        tokens.removeFirst()
                        let rhs = parseArithTernary(&tokens, session: &session)
                        let newVal = currentVal * rhs
                        session.setVariable(name, String(newVal))
                        return newVal
                    }
                    if op == "/=" {
                        tokens.removeFirst()
                        let rhs = parseArithTernary(&tokens, session: &session)
                        let newVal = rhs == 0 ? 0 : currentVal / rhs
                        session.setVariable(name, String(newVal))
                        return newVal
                    }
                    if op == "%=" {
                        tokens.removeFirst()
                        let rhs = parseArithTernary(&tokens, session: &session)
                        let newVal = rhs == 0 ? 0 : currentVal % rhs
                        session.setVariable(name, String(newVal))
                        return newVal
                    }
                }
                return currentVal
            }
            if case .number(let n) = tok.kind { tokens.removeFirst(); return n }
        }
        return 0
    }
}
