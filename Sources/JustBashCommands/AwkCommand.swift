import Foundation
import JustBashFS

func awk() -> AnyBashCommand {
    AnyBashCommand(name: "awk") { args, ctx in
        var program = ""
        var fieldSep = " "
        var files: [String] = []
        var i = 0
        while i < args.count {
            switch args[i] {
            case "-F": if i + 1 < args.count { fieldSep = args[i + 1]; i += 2 } else { i += 1 }
            case "-f": i += 2
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

        return ExecResult.success(executeSimpleAwk(program: program, input: content, fieldSep: fieldSep))
    }
}

// MARK: - Awk Types

private enum AwkCondition {
    case always
    case begin
    case end
    case pattern(String)
    case expression(String)
}

private struct AwkRule {
    let condition: AwkCondition
    let action: String
}

private struct AwkState {
    var variables: [String: String] = [:]
    var FS: String = " "
    var OFS: String = " "
    var ORS: String = "\n"
    var NR: Int = 0
    var NF: Int = 0
    var fields: [String] = []
    var currentLine: String = ""
    var output: [String] = []

    mutating func setVariable(_ name: String, _ value: String) {
        variables[name] = value
    }

    func getVariable(_ name: String) -> String {
        return variables[name] ?? "0"
    }
}

// MARK: - Awk Parsing

private func parseAwkProgram(_ program: String) -> [AwkRule] {
    var rules: [AwkRule] = []
    let trimmed = program.trimmingCharacters(in: .whitespaces)
    var i = trimmed.startIndex

    while i < trimmed.endIndex {
        // Skip whitespace and semicolons
        while i < trimmed.endIndex && (trimmed[i] == " " || trimmed[i] == "\t" || trimmed[i] == "\n" || trimmed[i] == ";") {
            i = trimmed.index(after: i)
        }
        guard i < trimmed.endIndex else { break }

        // Check for BEGIN
        if trimmed[i...].hasPrefix("BEGIN") {
            let afterBegin = trimmed.index(i, offsetBy: 5)
            let rest = String(trimmed[afterBegin...]).trimmingCharacters(in: .whitespaces)
            if rest.hasPrefix("{") {
                let actionBody = extractBraceBlock(String(trimmed[afterBegin...]).trimmingCharacters(in: .whitespaces))
                rules.append(AwkRule(condition: .begin, action: actionBody.body))
                i = trimmed.index(afterBegin, offsetBy: actionBody.consumed, limitedBy: trimmed.endIndex) ?? trimmed.endIndex
                // Skip whitespace after block
                let skipped = String(trimmed[i...]).trimmingCharacters(in: .whitespaces)
                if skipped.count < String(trimmed[i...]).count {
                    let diff = String(trimmed[i...]).count - skipped.count
                    i = trimmed.index(i, offsetBy: diff, limitedBy: trimmed.endIndex) ?? trimmed.endIndex
                }
                continue
            }
        }

        // Check for END
        if trimmed[i...].hasPrefix("END") {
            let afterEnd = trimmed.index(i, offsetBy: 3)
            let rest = String(trimmed[afterEnd...]).trimmingCharacters(in: .whitespaces)
            if rest.hasPrefix("{") {
                let actionBody = extractBraceBlock(String(trimmed[afterEnd...]).trimmingCharacters(in: .whitespaces))
                rules.append(AwkRule(condition: .end, action: actionBody.body))
                i = trimmed.index(afterEnd, offsetBy: actionBody.consumed, limitedBy: trimmed.endIndex) ?? trimmed.endIndex
                let skipped = String(trimmed[i...]).trimmingCharacters(in: .whitespaces)
                if skipped.count < String(trimmed[i...]).count {
                    let diff = String(trimmed[i...]).count - skipped.count
                    i = trimmed.index(i, offsetBy: diff, limitedBy: trimmed.endIndex) ?? trimmed.endIndex
                }
                continue
            }
        }

        // Check for /pattern/{action}
        if trimmed[i] == "/" {
            let patEnd = findClosingSlash(trimmed, from: trimmed.index(after: i))
            if let patEnd = patEnd {
                let pattern = String(trimmed[trimmed.index(after: i)..<patEnd])
                var afterPat = trimmed.index(after: patEnd)
                // Skip whitespace
                while afterPat < trimmed.endIndex && (trimmed[afterPat] == " " || trimmed[afterPat] == "\t") {
                    afterPat = trimmed.index(after: afterPat)
                }
                if afterPat < trimmed.endIndex && trimmed[afterPat] == "{" {
                    let actionBody = extractBraceBlock(String(trimmed[afterPat...]))
                    rules.append(AwkRule(condition: .pattern(pattern), action: actionBody.body))
                    i = trimmed.index(afterPat, offsetBy: actionBody.consumed, limitedBy: trimmed.endIndex) ?? trimmed.endIndex
                    continue
                } else {
                    // Pattern with no action means print
                    rules.append(AwkRule(condition: .pattern(pattern), action: "print"))
                    i = afterPat
                    continue
                }
            }
        }

        // Check for expression condition like ($1 > 10)
        if trimmed[i] == "$" || trimmed[i] == "(" || trimmed[i].isNumber {
            // Try to parse an expression condition before a {
            let remaining = String(trimmed[i...])
            if let braceIdx = findTopLevelBrace(remaining) {
                let exprStr = String(remaining[remaining.startIndex..<remaining.index(remaining.startIndex, offsetBy: braceIdx)]).trimmingCharacters(in: .whitespaces)
                let actionBody = extractBraceBlock(String(remaining[remaining.index(remaining.startIndex, offsetBy: braceIdx)...]))
                rules.append(AwkRule(condition: .expression(exprStr), action: actionBody.body))
                i = trimmed.index(i, offsetBy: braceIdx + actionBody.consumed, limitedBy: trimmed.endIndex) ?? trimmed.endIndex
                continue
            }
        }

        // Check for bare {action}
        if trimmed[i] == "{" {
            let actionBody = extractBraceBlock(String(trimmed[i...]))
            rules.append(AwkRule(condition: .always, action: actionBody.body))
            i = trimmed.index(i, offsetBy: actionBody.consumed, limitedBy: trimmed.endIndex) ?? trimmed.endIndex
            continue
        }

        // Fallback: skip character
        i = trimmed.index(after: i)
    }

    return rules
}

private func findClosingSlash(_ str: String, from start: String.Index) -> String.Index? {
    var i = start
    while i < str.endIndex {
        if str[i] == "\\" {
            i = str.index(after: i)
            if i < str.endIndex { i = str.index(after: i) }
            continue
        }
        if str[i] == "/" { return i }
        i = str.index(after: i)
    }
    return nil
}

private func findTopLevelBrace(_ str: String) -> Int? {
    var i = 0
    let chars = Array(str)
    var parenDepth = 0
    while i < chars.count {
        if chars[i] == "(" { parenDepth += 1 }
        else if chars[i] == ")" { parenDepth -= 1 }
        else if chars[i] == "{" && parenDepth == 0 { return i }
        i += 1
    }
    return nil
}

private struct BraceBlock {
    let body: String
    let consumed: Int
}

private func extractBraceBlock(_ str: String) -> BraceBlock {
    let chars = Array(str)
    guard !chars.isEmpty && chars[0] == "{" else { return BraceBlock(body: str, consumed: str.count) }
    var depth = 0
    var i = 0
    var inQuote = false
    while i < chars.count {
        if chars[i] == "\"" && (i == 0 || chars[i - 1] != "\\") { inQuote.toggle() }
        if !inQuote {
            if chars[i] == "{" { depth += 1 }
            else if chars[i] == "}" {
                depth -= 1
                if depth == 0 {
                    let body = String(chars[1..<i]).trimmingCharacters(in: .whitespaces)
                    return BraceBlock(body: body, consumed: i + 1)
                }
            }
        }
        i += 1
    }
    // Unmatched brace, take everything
    let body = String(chars[1...]).trimmingCharacters(in: .whitespaces)
    return BraceBlock(body: body, consumed: chars.count)
}

// MARK: - Awk Execution

private func executeSimpleAwk(program: String, input: String, fieldSep: String) -> String {
    let rules = parseAwkProgram(program)
    guard !rules.isEmpty else { return "" }

    var state = AwkState()
    state.FS = fieldSep

    // Execute BEGIN rules
    for rule in rules {
        if case .begin = rule.condition {
            executeAwkAction(rule.action, state: &state)
        }
    }

    let lines = input.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let dataRules = rules.filter { rule in
        if case .begin = rule.condition { return false }
        if case .end = rule.condition { return false }
        return true
    }

    for (lineIdx, line) in lines.enumerated() {
        if line.isEmpty && lineIdx == lines.count - 1 && input.hasSuffix("\n") { continue }

        state.NR = lineIdx + 1
        state.currentLine = line

        if state.FS == " " {
            state.fields = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        } else {
            state.fields = line.components(separatedBy: state.FS)
        }
        state.NF = state.fields.count

        for rule in dataRules {
            if matchesAwkCondition(rule.condition, state: state) {
                executeAwkAction(rule.action, state: &state)
            }
        }
    }

    // Execute END rules
    for rule in rules {
        if case .end = rule.condition {
            executeAwkAction(rule.action, state: &state)
        }
    }

    if state.output.isEmpty { return "" }
    return state.output.joined(separator: "") + ""
}

private func matchesAwkCondition(_ condition: AwkCondition, state: AwkState) -> Bool {
    switch condition {
    case .always:
        return true
    case .begin, .end:
        return false
    case .pattern(let pat):
        guard let regex = try? NSRegularExpression(pattern: pat) else { return false }
        let range = NSRange(state.currentLine.startIndex..., in: state.currentLine)
        return regex.firstMatch(in: state.currentLine, range: range) != nil
    case .expression(let expr):
        return evaluateAwkConditionExpr(expr, state: state)
    }
}

private func evaluateAwkConditionExpr(_ expr: String, state: AwkState) -> Bool {
    let trimmed = expr.trimmingCharacters(in: .whitespaces)

    // Handle parenthesized expression
    var e = trimmed
    if e.hasPrefix("(") && e.hasSuffix(")") {
        e = String(e.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
    }

    // Try comparison operators: >, <, >=, <=, ==, !=, ~
    for op in [">=", "<=", "!=", "==", ">", "<", "~", "!~"] {
        if let range = e.range(of: " \(op) ") ?? e.range(of: "\(op)") {
            let lhs = String(e[e.startIndex..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            let rhs = String(e[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            let lVal = resolveAwkValue(lhs, state: state)
            let rVal = resolveAwkValue(rhs, state: state)

            if op == "~" || op == "!~" {
                // Regex match
                var pattern = rVal
                if pattern.hasPrefix("/") && pattern.hasSuffix("/") {
                    pattern = String(pattern.dropFirst().dropLast())
                }
                let matches: Bool
                if let regex = try? NSRegularExpression(pattern: pattern) {
                    let nsRange = NSRange(lVal.startIndex..., in: lVal)
                    matches = regex.firstMatch(in: lVal, range: nsRange) != nil
                } else {
                    matches = false
                }
                return op == "~" ? matches : !matches
            }

            let lNum = Double(lVal)
            let rNum = Double(rVal)
            if let l = lNum, let r = rNum {
                switch op {
                case ">": return l > r
                case "<": return l < r
                case ">=": return l >= r
                case "<=": return l <= r
                case "==": return l == r
                case "!=": return l != r
                default: return false
                }
            } else {
                switch op {
                case "==": return lVal == rVal
                case "!=": return lVal != rVal
                case ">": return lVal > rVal
                case "<": return lVal < rVal
                case ">=": return lVal >= rVal
                case "<=": return lVal <= rVal
                default: return false
                }
            }
        }
    }

    // Non-zero/non-empty is true
    let val = resolveAwkValue(e, state: state)
    if let num = Double(val) { return num != 0 }
    return !val.isEmpty
}

private func resolveAwkValue(_ token: String, state: AwkState) -> String {
    let t = token.trimmingCharacters(in: .whitespaces)

    if t.hasPrefix("\"") && t.hasSuffix("\"") && t.count >= 2 {
        return String(t.dropFirst().dropLast())
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\t", with: "\t")
    }

    if t.hasPrefix("$") {
        let rest = String(t.dropFirst())
        if rest == "0" { return state.currentLine }
        if rest == "NF" {
            if state.NF > 0 && state.NF <= state.fields.count { return state.fields[state.NF - 1] }
            return ""
        }
        if let n = Int(rest), n > 0, n <= state.fields.count {
            return state.fields[n - 1]
        }
        return ""
    }

    switch t {
    case "NR": return String(state.NR)
    case "NF": return String(state.NF)
    case "FS": return state.FS
    case "OFS": return state.OFS
    case "ORS": return state.ORS
    default:
        // Check user variables
        if let val = state.variables[t] { return val }
        return t
    }
}

// MARK: - Awk Action Execution

private func executeAwkAction(_ action: String, state: inout AwkState) {
    let statements = splitAwkStatements(action)
    for stmt in statements {
        executeAwkStatement(stmt.trimmingCharacters(in: .whitespaces), state: &state)
    }
}

private func splitAwkStatements(_ action: String) -> [String] {
    var stmts: [String] = []
    var current = ""
    var depth = 0
    var inQuote = false
    let chars = Array(action)
    var i = 0

    while i < chars.count {
        let ch = chars[i]
        if ch == "\"" && (i == 0 || chars[i - 1] != "\\") { inQuote.toggle() }
        if !inQuote {
            if ch == "{" { depth += 1 }
            else if ch == "}" { depth -= 1 }
            else if ch == ";" && depth == 0 {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { stmts.append(trimmed) }
                current = ""
                i += 1
                continue
            }
        }
        current.append(ch)
        i += 1
    }
    let trimmed = current.trimmingCharacters(in: .whitespaces)
    if !trimmed.isEmpty { stmts.append(trimmed) }
    return stmts
}

private func executeAwkStatement(_ stmt: String, state: inout AwkState) {
    let trimmed = stmt.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return }

    // Handle if statement
    if trimmed.hasPrefix("if ") || trimmed.hasPrefix("if(") {
        executeAwkIf(trimmed, state: &state)
        return
    }

    // Handle variable assignment: var = expr
    if let eqRange = findAssignment(trimmed) {
        let varName = String(trimmed[trimmed.startIndex..<eqRange.lowerBound]).trimmingCharacters(in: .whitespaces)
        let valueExpr = String(trimmed[eqRange.upperBound...]).trimmingCharacters(in: .whitespaces)
        if varName == "OFS" {
            state.OFS = evaluateAwkExpr(valueExpr, state: state)
        } else if varName == "ORS" {
            state.ORS = evaluateAwkExpr(valueExpr, state: state)
        } else if varName == "FS" {
            state.FS = evaluateAwkExpr(valueExpr, state: state)
        } else {
            state.setVariable(varName, evaluateAwkExpr(valueExpr, state: state))
        }
        return
    }

    // Handle printf
    if trimmed.hasPrefix("printf ") || trimmed.hasPrefix("printf(") {
        executeAwkPrintf(trimmed, state: &state)
        return
    }

    // Handle print
    if trimmed == "print" || trimmed.hasPrefix("print ") || trimmed.hasPrefix("print(") {
        executeAwkPrint(trimmed, state: &state)
        return
    }

    // Handle bare expression (e.g., count++ or count += 1)
    if trimmed.hasSuffix("++") {
        let varName = String(trimmed.dropLast(2)).trimmingCharacters(in: .whitespaces)
        let current = Int(state.getVariable(varName)) ?? 0
        state.setVariable(varName, String(current + 1))
        return
    }
    if trimmed.hasSuffix("--") {
        let varName = String(trimmed.dropLast(2)).trimmingCharacters(in: .whitespaces)
        let current = Int(state.getVariable(varName)) ?? 0
        state.setVariable(varName, String(current - 1))
        return
    }
    if let addEq = trimmed.range(of: "+=") {
        let varName = String(trimmed[trimmed.startIndex..<addEq.lowerBound]).trimmingCharacters(in: .whitespaces)
        let valueExpr = String(trimmed[addEq.upperBound...]).trimmingCharacters(in: .whitespaces)
        let current = Double(state.getVariable(varName)) ?? 0
        let addVal = Double(evaluateAwkExpr(valueExpr, state: state)) ?? 0
        let result = current + addVal
        state.setVariable(varName, formatAwkNumber(result))
        return
    }
    if let subEq = trimmed.range(of: "-=") {
        let varName = String(trimmed[trimmed.startIndex..<subEq.lowerBound]).trimmingCharacters(in: .whitespaces)
        let valueExpr = String(trimmed[subEq.upperBound...]).trimmingCharacters(in: .whitespaces)
        let current = Double(state.getVariable(varName)) ?? 0
        let subVal = Double(evaluateAwkExpr(valueExpr, state: state)) ?? 0
        let result = current - subVal
        state.setVariable(varName, formatAwkNumber(result))
        return
    }
}

private func findAssignment(_ stmt: String) -> Range<String.Index>? {
    // Look for = that's not ==, !=, >=, <=, +=, -=
    let chars = Array(stmt)
    var i = 0
    var inQuote = false
    // Skip field refs and keywords at start
    while i < chars.count {
        if chars[i] == "\"" { inQuote.toggle() }
        if !inQuote && chars[i] == "=" {
            if i > 0 && (chars[i - 1] == "!" || chars[i - 1] == ">" || chars[i - 1] == "<" || chars[i - 1] == "+" || chars[i - 1] == "-") {
                i += 1; continue
            }
            if i + 1 < chars.count && chars[i + 1] == "=" { i += 2; continue }
            // Valid assignment
            let startIdx = stmt.index(stmt.startIndex, offsetBy: i)
            let endIdx = stmt.index(startIdx, offsetBy: 1)
            // Verify LHS is a simple variable name
            let lhs = String(stmt[stmt.startIndex..<startIdx]).trimmingCharacters(in: .whitespaces)
            if !lhs.isEmpty && !lhs.contains(" ") && !lhs.hasPrefix("$") && !lhs.hasPrefix("\"") {
                return startIdx..<endIdx
            }
        }
        i += 1
    }
    return nil
}

private func executeAwkIf(_ stmt: String, state: inout AwkState) {
    // Parse: if (condition) { action } or if (condition) action
    var rest = stmt
    if rest.hasPrefix("if ") { rest = String(rest.dropFirst(3)).trimmingCharacters(in: .whitespaces) }
    else if rest.hasPrefix("if(") { rest = String(rest.dropFirst(2)).trimmingCharacters(in: .whitespaces) }

    guard rest.hasPrefix("(") else { return }
    // Find matching )
    var depth = 0
    var condEnd = rest.startIndex
    for idx in rest.indices {
        if rest[idx] == "(" { depth += 1 }
        else if rest[idx] == ")" {
            depth -= 1
            if depth == 0 { condEnd = idx; break }
        }
    }

    let condition = String(rest[rest.index(after: rest.startIndex)..<condEnd]).trimmingCharacters(in: .whitespaces)
    var body = String(rest[rest.index(after: condEnd)...]).trimmingCharacters(in: .whitespaces)

    // Check for else
    var elseBody: String? = nil
    if body.hasPrefix("{") {
        let remaining = body
        let blk = extractBraceBlock(remaining)
        body = blk.body
        let afterBrace = String(remaining.dropFirst(blk.consumed)).trimmingCharacters(in: .whitespaces)
        if afterBrace.hasPrefix("else") {
            let elsePart = String(afterBrace.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            if elsePart.hasPrefix("{") {
                let elseBlock = extractBraceBlock(elsePart)
                elseBody = elseBlock.body
            } else {
                elseBody = elsePart
            }
        }
    }

    if evaluateAwkConditionExpr(condition, state: state) {
        executeAwkAction(body, state: &state)
    } else if let eb = elseBody {
        executeAwkAction(eb, state: &state)
    }
}

private func executeAwkPrint(_ stmt: String, state: inout AwkState) {
    var printArgs: String
    if stmt == "print" {
        state.output.append(state.currentLine + state.ORS)
        return
    } else if stmt.hasPrefix("print(") && stmt.hasSuffix(")") {
        printArgs = String(stmt.dropFirst(6).dropLast())
    } else {
        printArgs = String(stmt.dropFirst(6)) // "print "
    }

    printArgs = printArgs.trimmingCharacters(in: .whitespaces)
    if printArgs.isEmpty {
        state.output.append(state.currentLine + state.ORS)
        return
    }

    let parts = parseAwkPrintArgs(printArgs)
    var lineOutput = ""
    for (pIdx, part) in parts.enumerated() {
        let val = evaluateAwkExpr(part, state: state)
        lineOutput += val
        if pIdx < parts.count - 1 {
            lineOutput += state.OFS
        }
    }
    state.output.append(lineOutput + state.ORS)
}

private func executeAwkPrintf(_ stmt: String, state: inout AwkState) {
    var printfArgs: String
    if stmt.hasPrefix("printf(") && stmt.hasSuffix(")") {
        printfArgs = String(stmt.dropFirst(7).dropLast())
    } else {
        printfArgs = String(stmt.dropFirst(7)) // "printf "
    }

    let parts = parseAwkPrintArgs(printfArgs)
    guard !parts.isEmpty else { return }

    let format = evaluateAwkExpr(parts[0], state: state)
    let args = Array(parts.dropFirst()).map { evaluateAwkExpr($0, state: state) }

    let result = applyAwkPrintf(format: format, args: args)
    state.output.append(result)
}

private func applyAwkPrintf(format: String, args: [String]) -> String {
    var result = ""
    let chars = Array(format)
    var i = 0
    var argIdx = 0

    while i < chars.count {
        if chars[i] == "\\" && i + 1 < chars.count {
            switch chars[i + 1] {
            case "n": result.append("\n")
            case "t": result.append("\t")
            case "\\": result.append("\\")
            default: result.append(chars[i]); result.append(chars[i + 1])
            }
            i += 2
            continue
        }

        if chars[i] == "%" && i + 1 < chars.count {
            if chars[i + 1] == "%" { result.append("%"); i += 2; continue }

            // Parse format specifier
            var fmtSpec = "%"
            i += 1
            // Flags
            while i < chars.count && "-+ 0#".contains(chars[i]) {
                fmtSpec.append(chars[i]); i += 1
            }
            // Width
            while i < chars.count && chars[i].isNumber {
                fmtSpec.append(chars[i]); i += 1
            }
            // Precision
            if i < chars.count && chars[i] == "." {
                fmtSpec.append(chars[i]); i += 1
                while i < chars.count && chars[i].isNumber {
                    fmtSpec.append(chars[i]); i += 1
                }
            }
            // Conversion
            guard i < chars.count else { break }
            let conv = chars[i]
            fmtSpec.append(conv)
            i += 1

            let arg = argIdx < args.count ? args[argIdx] : ""
            argIdx += 1

            switch conv {
            case "d", "i":
                let num = Int(Double(arg) ?? 0)
                let normalized = fmtSpec.replacingOccurrences(of: String(conv), with: "d")
                result += String(format: normalized, num)
            case "f":
                let num = Double(arg) ?? 0
                result += String(format: fmtSpec, num)
            case "s":
                // Use %@ instead of %s for Swift String(format:) – %s expects a C pointer
                let swiftFmtSpec = String(fmtSpec.dropLast()) + "@"
                result += String(format: swiftFmtSpec, arg as NSString)
            case "c":
                if let firstChar = arg.first {
                    result.append(firstChar)
                }
            case "x", "X", "o":
                let num = Int(Double(arg) ?? 0)
                result += String(format: fmtSpec, num)
            default:
                result += arg
            }
            continue
        }

        result.append(chars[i])
        i += 1
    }

    return result
}

// MARK: - Awk Expression Evaluation

private func evaluateAwkExpr(_ expr: String, state: AwkState) -> String {
    let trimmed = expr.trimmingCharacters(in: .whitespaces)

    // String literal
    if trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"") && trimmed.count >= 2 {
        return String(trimmed.dropFirst().dropLast())
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\t", with: "\t")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    // String concatenation: "text" expr or expr "text" or expr expr
    // Check for concatenation (adjacent expressions separated by spaces, but not inside strings)
    let concatParts = parseAwkConcatParts(trimmed)
    if concatParts.count > 1 {
        return concatParts.map { evaluateAwkExpr($0, state: state) }.joined()
    }

    // Built-in function calls
    if let result = evaluateAwkFunctionCall(trimmed, state: state) {
        return result
    }

    // Arithmetic: check for +, -, *, /
    if let result = evaluateArithmeticExpr(trimmed, state: state) {
        return result
    }

    return resolveAwkValue(trimmed, state: state)
}

private func parseAwkConcatParts(_ expr: String) -> [String] {
    // Split expression into concatenation parts
    // Parts are separated by spaces that aren't inside quotes and don't form operators
    var parts: [String] = []
    var current = ""
    var inQuote = false
    let chars = Array(expr)
    var i = 0

    while i < chars.count {
        if chars[i] == "\"" && (i == 0 || chars[i - 1] != "\\") {
            inQuote.toggle()
            current.append(chars[i])
            i += 1
            continue
        }

        if inQuote {
            current.append(chars[i])
            i += 1
            continue
        }

        // Check for space that might be concatenation
        if chars[i] == " " || chars[i] == "\t" {
            let trimmedCurrent = current.trimmingCharacters(in: .whitespaces)
            if !trimmedCurrent.isEmpty {
                // Look ahead: is the next non-space char starting a new value?
                var j = i + 1
                while j < chars.count && (chars[j] == " " || chars[j] == "\t") { j += 1 }
                if j < chars.count {
                    let nextChar = chars[j]
                    // If next is a value start (quote, $, letter, digit) and current doesn't end with an operator
                    let endsWithOp = trimmedCurrent.hasSuffix("+") || trimmedCurrent.hasSuffix("-") || trimmedCurrent.hasSuffix("*") || trimmedCurrent.hasSuffix("/") || trimmedCurrent.hasSuffix(",")
                    let nextIsValue = nextChar == "\"" || nextChar == "$" || nextChar.isLetter || nextChar.isNumber
                    let nextIsOp = nextChar == "+" || nextChar == "-" || nextChar == "*" || nextChar == "/"

                    if !endsWithOp && nextIsValue && !nextIsOp {
                        // Check if this looks like an arithmetic expression with spaces around operators
                        // e.g., "$1 + $2" should be arithmetic, not concatenation
                        // Look ahead for operator pattern
                        var k = j
                        var tempToken = ""
                        while k < chars.count && chars[k] != " " && chars[k] != "\t" { tempToken.append(chars[k]); k += 1 }
                        // Skip spaces
                        while k < chars.count && (chars[k] == " " || chars[k] == "\t") { k += 1 }
                        if k < chars.count && (chars[k] == "+" || chars[k] == "-" || chars[k] == "*" || chars[k] == "/") {
                            // This is arithmetic with spaces, not concatenation
                            current.append(chars[i])
                            i += 1
                            continue
                        }

                        // This is string concatenation
                        parts.append(trimmedCurrent)
                        current = ""
                        i = j
                        continue
                    }
                }
            }
            current.append(chars[i])
            i += 1
            continue
        }

        current.append(chars[i])
        i += 1
    }

    let trimmedCurrent = current.trimmingCharacters(in: .whitespaces)
    if !trimmedCurrent.isEmpty { parts.append(trimmedCurrent) }

    return parts
}

private func evaluateArithmeticExpr(_ expr: String, state: AwkState) -> String? {
    let trimmed = expr.trimmingCharacters(in: .whitespaces)

    // Look for top-level + or - (not inside parens/quotes)
    // Process left to right, lower precedence first
    var depth = 0
    var inQuote = false
    let chars = Array(trimmed)

    // Find rightmost + or - at depth 0 (for left-to-right evaluation)
    var lastAddSub: Int? = nil
    for i in 0..<chars.count {
        if chars[i] == "\"" { inQuote.toggle(); continue }
        if inQuote { continue }
        if chars[i] == "(" { depth += 1; continue }
        if chars[i] == ")" { depth -= 1; continue }
        if depth == 0 && (chars[i] == "+" || chars[i] == "-") {
            // Don't count unary minus at start or after operator
            if i == 0 { continue }
            if chars[i - 1] == "+" || chars[i - 1] == "-" || chars[i - 1] == "*" || chars[i - 1] == "/" { continue }
            lastAddSub = i
        }
    }

    if let idx = lastAddSub {
        let lhs = String(chars[0..<idx]).trimmingCharacters(in: .whitespaces)
        let op = chars[idx]
        let rhs = String(chars[(idx + 1)...]).trimmingCharacters(in: .whitespaces)
        let lVal = evaluateAwkExpr(lhs, state: state)
        let rVal = evaluateAwkExpr(rhs, state: state)
        let l = Double(lVal) ?? 0
        let r = Double(rVal) ?? 0
        let result = op == "+" ? l + r : l - r
        return formatAwkNumber(result)
    }

    // Find rightmost * or / at depth 0
    depth = 0; inQuote = false
    var lastMulDiv: Int? = nil
    for i in 0..<chars.count {
        if chars[i] == "\"" { inQuote.toggle(); continue }
        if inQuote { continue }
        if chars[i] == "(" { depth += 1; continue }
        if chars[i] == ")" { depth -= 1; continue }
        if depth == 0 && (chars[i] == "*" || chars[i] == "/") {
            lastMulDiv = i
        }
    }

    if let idx = lastMulDiv {
        let lhs = String(chars[0..<idx]).trimmingCharacters(in: .whitespaces)
        let op = chars[idx]
        let rhs = String(chars[(idx + 1)...]).trimmingCharacters(in: .whitespaces)
        let lVal = evaluateAwkExpr(lhs, state: state)
        let rVal = evaluateAwkExpr(rhs, state: state)
        let l = Double(lVal) ?? 0
        let r = Double(rVal) ?? 0
        let result: Double
        if op == "*" { result = l * r }
        else { result = r != 0 ? l / r : 0 }
        return formatAwkNumber(result)
    }

    // Find % (modulo)
    depth = 0; inQuote = false
    var lastMod: Int? = nil
    for i in 0..<chars.count {
        if chars[i] == "\"" { inQuote.toggle(); continue }
        if inQuote { continue }
        if chars[i] == "(" { depth += 1; continue }
        if chars[i] == ")" { depth -= 1; continue }
        if depth == 0 && chars[i] == "%" && !(i + 1 < chars.count && chars[i + 1].isLetter) {
            lastMod = i
        }
    }

    if let idx = lastMod {
        let lhs = String(chars[0..<idx]).trimmingCharacters(in: .whitespaces)
        let rhs = String(chars[(idx + 1)...]).trimmingCharacters(in: .whitespaces)
        let lVal = evaluateAwkExpr(lhs, state: state)
        let rVal = evaluateAwkExpr(rhs, state: state)
        let l = Int(Double(lVal) ?? 0)
        let r = Int(Double(rVal) ?? 0)
        return r != 0 ? String(l % r) : "0"
    }

    return nil
}

private func formatAwkNumber(_ value: Double) -> String {
    if value == value.rounded() && abs(value) < 1e15 {
        return String(Int(value))
    }
    return String(value)
}

private func parseAwkPrintArgs(_ args: String) -> [String] {
    var parts: [String] = []
    var current = ""
    var inQuote = false
    var depth = 0
    let chars = Array(args)
    var i = 0

    while i < chars.count {
        let ch = chars[i]
        if ch == "\"" && (i == 0 || chars[i - 1] != "\\") {
            inQuote.toggle()
            current.append(ch)
            i += 1
            continue
        }
        if inQuote { current.append(ch); i += 1; continue }
        if ch == "(" { depth += 1; current.append(ch); i += 1; continue }
        if ch == ")" { depth -= 1; current.append(ch); i += 1; continue }
        if ch == "," && depth == 0 {
            let trimmed = current.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { parts.append(trimmed) }
            current = ""
            i += 1
            continue
        }
        current.append(ch)
        i += 1
    }
    let trimmed = current.trimmingCharacters(in: .whitespaces)
    if !trimmed.isEmpty { parts.append(trimmed) }
    return parts
}

// MARK: - Awk Built-in Functions

private func evaluateAwkFunctionCall(_ expr: String, state: AwkState) -> String? {
    let trimmed = expr.trimmingCharacters(in: .whitespaces)

    // Match function_name(...) pattern
    guard let parenStart = trimmed.firstIndex(of: "("),
          trimmed.hasSuffix(")") else {
        // Handle bare "length" (no parens) -> length of $0
        if trimmed == "length" {
            return String(state.currentLine.count)
        }
        return nil
    }

    let funcName = String(trimmed[trimmed.startIndex..<parenStart]).trimmingCharacters(in: .whitespaces)
    let argsStr = String(trimmed[trimmed.index(after: parenStart)..<trimmed.index(before: trimmed.endIndex)])
    let funcArgs = parseAwkPrintArgs(argsStr)

    switch funcName {
    case "length":
        if funcArgs.isEmpty {
            return String(state.currentLine.count)
        }
        let s = evaluateAwkExpr(funcArgs[0], state: state)
        return String(s.count)

    case "substr":
        guard funcArgs.count >= 2 else { return nil }
        let s = evaluateAwkExpr(funcArgs[0], state: state)
        let startPos = Int(evaluateAwkExpr(funcArgs[1], state: state)) ?? 1
        let start = max(startPos - 1, 0) // awk is 1-based
        guard start < s.count else { return "" }
        let startIdx = s.index(s.startIndex, offsetBy: start)
        if funcArgs.count >= 3 {
            let len = Int(evaluateAwkExpr(funcArgs[2], state: state)) ?? s.count
            let endOffset = min(start + len, s.count)
            let endIdx = s.index(s.startIndex, offsetBy: endOffset)
            return String(s[startIdx..<endIdx])
        }
        return String(s[startIdx...])

    case "index":
        guard funcArgs.count >= 2 else { return nil }
        let s = evaluateAwkExpr(funcArgs[0], state: state)
        let t = evaluateAwkExpr(funcArgs[1], state: state)
        if let range = s.range(of: t) {
            return String(s.distance(from: s.startIndex, to: range.lowerBound) + 1)
        }
        return "0"

    case "split":
        guard funcArgs.count >= 3 else { return nil }
        let s = evaluateAwkExpr(funcArgs[0], state: state)
        let sep = funcArgs.count >= 3 ? evaluateAwkExpr(funcArgs[2], state: state) : state.FS
        let parts = s.components(separatedBy: sep)
        // Note: awk split populates an associative array, but we return count
        return String(parts.count)

    case "sub":
        // sub modifies in place; in our model we return the result
        guard funcArgs.count >= 3 else { return nil }
        let pattern = evaluateAwkExpr(funcArgs[0], state: state)
        let replacement = evaluateAwkExpr(funcArgs[1], state: state)
        let target = evaluateAwkExpr(funcArgs[2], state: state)
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return target }
        let nsRange = NSRange(target.startIndex..., in: target)
        if let match = regex.firstMatch(in: target, range: nsRange) {
            let mutable = NSMutableString(string: target)
            regex.replaceMatches(in: mutable, range: match.range, withTemplate: replacement)
            return mutable as String
        }
        return target

    case "gsub":
        guard funcArgs.count >= 3 else { return nil }
        let pattern = evaluateAwkExpr(funcArgs[0], state: state)
        let replacement = evaluateAwkExpr(funcArgs[1], state: state)
        let target = evaluateAwkExpr(funcArgs[2], state: state)
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return target }
        let nsRange = NSRange(target.startIndex..., in: target)
        return regex.stringByReplacingMatches(in: target, range: nsRange, withTemplate: replacement)

    case "match":
        guard funcArgs.count >= 2 else { return nil }
        let s = evaluateAwkExpr(funcArgs[0], state: state)
        var pattern = evaluateAwkExpr(funcArgs[1], state: state)
        if pattern.hasPrefix("/") && pattern.hasSuffix("/") && pattern.count >= 2 {
            pattern = String(pattern.dropFirst().dropLast())
        }
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return "0" }
        let nsRange = NSRange(s.startIndex..., in: s)
        if let m = regex.firstMatch(in: s, range: nsRange) {
            return String(m.range.location + 1) // 1-based
        }
        return "0"

    case "tolower":
        guard funcArgs.count >= 1 else { return nil }
        return evaluateAwkExpr(funcArgs[0], state: state).lowercased()

    case "toupper":
        guard funcArgs.count >= 1 else { return nil }
        return evaluateAwkExpr(funcArgs[0], state: state).uppercased()

    case "sprintf":
        guard funcArgs.count >= 1 else { return nil }
        let format = evaluateAwkExpr(funcArgs[0], state: state)
        let sprintfArgs = Array(funcArgs.dropFirst()).map { evaluateAwkExpr($0, state: state) }
        return applyAwkPrintf(format: format, args: sprintfArgs)

    default:
        return nil
    }
}
