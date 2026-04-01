import Foundation

// MARK: - Parse Errors

public enum ParseError: Error, LocalizedError {
    case inputTooLarge(Int)
    case tooManyTokens(Int)
    case unexpectedToken(String)
    case expectedToken(String)
    case unterminatedQuote
    case unterminatedSubstitution
    case unterminatedHeredoc(String)
    case invalidRedirection(String)
    case maxDepthExceeded

    public var errorDescription: String? {
        switch self {
        case .inputTooLarge(let n): return "input too large (\(n) bytes)"
        case .tooManyTokens(let n): return "too many tokens (\(n))"
        case .unexpectedToken(let t): return "syntax error near unexpected token `\(t)'"
        case .expectedToken(let t): return "expected `\(t)'"
        case .unterminatedQuote: return "unterminated quote"
        case .unterminatedSubstitution: return "unterminated command substitution"
        case .unterminatedHeredoc(let d): return "here-document delimited by `\(d)' not found"
        case .invalidRedirection(let s): return "invalid redirection: \(s)"
        case .maxDepthExceeded: return "maximum nesting depth exceeded"
        }
    }
}

// MARK: - Token

private enum Token: CustomStringConvertible {
    case word(ShellWord)
    case assignment(String, ShellWord, Bool)  // name=value or name+=value
    case newline
    case semi           // ;
    case amp            // &
    case pipe           // |
    case pipeAmp        // |&
    case andIf          // &&
    case orIf           // ||
    case lparen         // (
    case rparen         // )
    case bang           // !
    case dsemi          // ;;
    case semiAmp        // ;&
    case dsemiAmp       // ;;&
    case less           // <
    case great          // >
    case dless          // <<
    case dgreat         // >>
    case lessAnd        // <&
    case greatAnd       // >&
    case lessGreat      // <>
    case dlessDash      // <<-
    case tless          // <<<
    case clobber        // >|
    case ioNumber(Int)  // digit before redirection
    case heredocBody(String, Bool) // content, quoted (suppress expansion)
    case eof

    var description: String {
        switch self {
        case .word(let w): return w.rawText
        case .assignment(let n, let v, let append):
            return append ? "\(n)+=\(v.rawText)" : "\(n)=\(v.rawText)"
        case .newline: return "newline"
        case .semi: return ";"
        case .amp: return "&"
        case .pipe: return "|"
        case .pipeAmp: return "|&"
        case .andIf: return "&&"
        case .orIf: return "||"
        case .lparen: return "("
        case .rparen: return ")"
        case .bang: return "!"
        case .dsemi: return ";;"
        case .semiAmp: return ";&"
        case .dsemiAmp: return ";;&"
        case .less: return "<"
        case .great: return ">"
        case .dless: return "<<"
        case .dgreat: return ">>"
        case .lessAnd: return "<&"
        case .greatAnd: return ">&"
        case .lessGreat: return "<>"
        case .dlessDash: return "<<-"
        case .tless: return "<<<"
        case .clobber: return ">|"
        case .ioNumber(let n): return "\(n)"
        case .heredocBody: return "<<BODY>>"
        case .eof: return "EOF"
        }
    }

    var isWord: Bool {
        if case .word = self { return true }
        return false
    }

    var wordValue: ShellWord? {
        if case .word(let w) = self { return w }
        return nil
    }

    var isCommandTerminator: Bool {
        switch self {
        case .newline, .semi, .amp, .eof, .dsemi, .semiAmp, .dsemiAmp: return true
        default: return false
        }
    }
}

// MARK: - Reserved Words

private let reservedWords: Set<String> = [
    "if", "then", "elif", "else", "fi",
    "for", "in", "do", "done",
    "while", "until",
    "case", "esac",
    "select",
    "function",
    "{", "}",
    "[[", "]]",
    "!", "time",
]

private func isReservedWord(_ word: ShellWord) -> String? {
    guard word.parts.count == 1, case .literal(let text) = word.parts[0] else { return nil }
    return reservedWords.contains(text) ? text : nil
}

private func wordText(_ word: ShellWord) -> String? {
    guard word.parts.count == 1, case .literal(let text) = word.parts[0] else { return nil }
    return text
}

// MARK: - Tokenizer

public struct ShellParser: Sendable {
    private let limits: ExecutionLimits

    public init(limits: ExecutionLimits = .init()) { self.limits = limits }

    public func parse(_ input: String) throws -> Script {
        guard input.utf8.count <= limits.maxInputLength else {
            throw ParseError.inputTooLarge(input.utf8.count)
        }
        var tokenizer = Tokenizer(input: input)
        let tokens = try tokenizer.tokenize()
        guard tokens.count <= limits.maxTokenCount else {
            throw ParseError.tooManyTokens(tokens.count)
        }
        var parser = ParserState(tokens: tokens, limits: limits)
        return try parser.parseScript()
    }
}

private struct Tokenizer {
    let chars: [Character]
    var pos: Int = 0
    var tokens: [Token] = []
    var pendingHeredocs: [(delimiter: String, stripTabs: Bool, quoted: Bool)] = []

    init(input: String) {
        self.chars = Array(input)
    }

    mutating func tokenize() throws -> [Token] {
        while pos < chars.count {
            skipSpacesAndTabs()
            if pos >= chars.count { break }

            let ch = chars[pos]

            // Comments
            if ch == "#" {
                while pos < chars.count && chars[pos] != "\n" { pos += 1 }
                continue
            }

            // Newline — pending heredoc bodies must appear before the logical newline
            if ch == "\n" {
                pos += 1
                try processPendingHeredocs()
                tokens.append(.newline)
                continue
            }

            // Operators
            if let tok = try scanOperator() {
                // Check if this was a heredoc operator — record pending heredoc
                switch tok {
                case .dless, .dlessDash:
                    let stripped: Bool
                    if case .dlessDash = tok {
                        stripped = true
                    } else {
                        stripped = false
                    }
                    tokens.append(tok)
                    skipSpacesAndTabs()
                    let (delim, quoted) = try scanHeredocDelimiter()
                    pendingHeredocs.append((delim, stripped, quoted))
                    continue
                default:
                    break
                }
                if case .tless = tok {
                    // Here-string: next word is the string value
                    tokens.append(tok)
                    continue
                }
                tokens.append(tok)
                continue
            }

            // IO number: digit(s) immediately followed by < or >
            if ch.isNumber {
                let startPos = pos
                var numStr = ""
                while pos < chars.count && chars[pos].isNumber {
                    numStr.append(chars[pos])
                    pos += 1
                }
                if pos < chars.count && (chars[pos] == "<" || chars[pos] == ">") {
                    if let num = Int(numStr) {
                        tokens.append(.ioNumber(num))
                        continue
                    }
                }
                // Not an io number, put it back and scan as word
                pos = startPos
            }

            // Word
            let word = try scanWord()
            // Check if it's an assignment (name=value or name+=value)
            if let (name, value, append) = detectAssignment(word) {
                tokens.append(.assignment(name, value, append))
                continue
            }
            tokens.append(.word(word))
        }
        tokens.append(.eof)
        return tokens
    }

    private mutating func skipSpacesAndTabs() {
        while pos < chars.count && (chars[pos] == " " || chars[pos] == "\t") {
            pos += 1
        }
    }

    private func peek(offset: Int = 0) -> Character? {
        let i = pos + offset
        return i < chars.count ? chars[i] : nil
    }

    // MARK: Operator scanning

    private mutating func scanOperator() throws -> Token? {
        guard pos < chars.count else { return nil }
        let ch = chars[pos]
        let next = peek(offset: 1)

        switch ch {
        case ";":
            if next == ";" {
                if peek(offset: 2) == "&" { pos += 3; return .dsemiAmp }
                pos += 2; return .dsemi
            }
            if next == "&" { pos += 2; return .semiAmp }
            pos += 1; return .semi

        case "&":
            if next == "&" { pos += 2; return .andIf }
            pos += 1; return .amp

        case "|":
            if next == "|" { pos += 2; return .orIf }
            if next == "&" { pos += 2; return .pipeAmp }
            pos += 1; return .pipe

        case "(":
            pos += 1; return .lparen

        case ")":
            pos += 1; return .rparen

        case "<":
            if next == "<" {
                if peek(offset: 2) == "<" { pos += 3; return .tless }
                if peek(offset: 2) == "-" { pos += 3; return .dlessDash }
                pos += 2; return .dless
            }
            if next == "&" { pos += 2; return .lessAnd }
            if next == ">" { pos += 2; return .lessGreat }
            pos += 1; return .less

        case ">":
            if next == ">" { pos += 2; return .dgreat }
            if next == "&" { pos += 2; return .greatAnd }
            if next == "|" { pos += 2; return .clobber }
            pos += 1; return .great

        default:
            return nil
        }
    }

    // MARK: Word scanning

    private mutating func scanWord() throws -> ShellWord {
        var parts: [WordPart] = []
        var literal = ""

        func flushLiteral() {
            if !literal.isEmpty {
                parts.append(.literal(literal))
                literal = ""
            }
        }

        while pos < chars.count {
            let ch = chars[pos]

            // Word-breaking characters
            if ch == " " || ch == "\t" || ch == "\n" { break }
            if ch == ";" || ch == "&" || ch == "|" || ch == "(" || ch == ")" { break }
            if ch == "<" || ch == ">" { break }
            if ch == "#" && !parts.isEmpty && literal.isEmpty {
                // # after whitespace starts comment, but mid-word is literal
                // Actually # only starts a comment at the start of a word position
                // If we've accumulated parts, this # is in a word
                if parts.isEmpty && literal.isEmpty { break }
            }

            // Escaping
            if ch == "\\" {
                pos += 1
                if pos < chars.count {
                    if chars[pos] == "\n" {
                        // Line continuation
                        pos += 1
                        continue
                    }
                    flushLiteral()
                    parts.append(.escapedChar(chars[pos]))
                    pos += 1
                } else {
                    literal.append("\\")
                }
                continue
            }

            // Single quotes
            if ch == "'" {
                flushLiteral()
                pos += 1
                var content = ""
                while pos < chars.count && chars[pos] != "'" {
                    content.append(chars[pos])
                    pos += 1
                }
                guard pos < chars.count else { throw ParseError.unterminatedQuote }
                pos += 1 // skip closing '
                parts.append(.singleQuoted(content))
                continue
            }

            // Double quotes
            if ch == "\"" {
                flushLiteral()
                let innerParts = try scanDoubleQuoted()
                parts.append(.doubleQuoted(innerParts))
                continue
            }

            // $'...' ANSI-C quoting
            if ch == "$" && peek(offset: 1) == "'" {
                flushLiteral()
                pos += 2
                let content = try scanAnsiCQuoted()
                parts.append(.dollarSingleQuoted(content))
                continue
            }

            // $"..." locale quoting (treat as regular double quote)
            if ch == "$" && peek(offset: 1) == "\"" {
                flushLiteral()
                pos += 1 // skip $, then scanDoubleQuoted handles the "
                let innerParts = try scanDoubleQuoted()
                parts.append(.doubleQuoted(innerParts))
                continue
            }

            // Dollar expansions
            if ch == "$" {
                flushLiteral()
                let part = try scanDollar()
                parts.append(part)
                continue
            }

            // Backtick substitution
            if ch == "`" {
                flushLiteral()
                pos += 1
                var content = ""
                while pos < chars.count && chars[pos] != "`" {
                    if chars[pos] == "\\" && pos + 1 < chars.count {
                        let next = chars[pos + 1]
                        if next == "`" || next == "\\" || next == "$" {
                            content.append(next)
                            pos += 2
                            continue
                        }
                    }
                    content.append(chars[pos])
                    pos += 1
                }
                guard pos < chars.count else { throw ParseError.unterminatedSubstitution }
                pos += 1
                parts.append(.backtickSub(content))
                continue
            }

            // Tilde at start of word
            if ch == "~" && parts.isEmpty && literal.isEmpty {
                pos += 1
                var user = ""
                while pos < chars.count {
                    let c = chars[pos]
                    if c == "/" || c == " " || c == "\t" || c == "\n" || c == ":" { break }
                    if c == ";" || c == "&" || c == "|" || c == "(" || c == ")" { break }
                    user.append(c)
                    pos += 1
                }
                parts.append(.tilde(user))
                continue
            }

            // Regular character
            literal.append(ch)
            pos += 1
        }

        flushLiteral()
        return ShellWord(parts)
    }

    // MARK: Dollar expansion

    private mutating func scanDollar() throws -> WordPart {
        pos += 1 // skip $
        guard pos < chars.count else { return .literal("$") }
        let ch = chars[pos]

        // $(( )) arithmetic
        if ch == "(" && peek(offset: 1) == "(" {
            pos += 2
            var depth = 1
            var expr = ""
            while pos < chars.count && depth > 0 {
                if chars[pos] == "(" && peek(offset: 1) == "(" { depth += 1; expr.append("(("); pos += 2; continue }
                if chars[pos] == ")" && peek(offset: 1) == ")" { depth -= 1; if depth > 0 { expr.append("))") }; pos += 2; continue }
                expr.append(chars[pos])
                pos += 1
            }
            return .arithmeticSub(expr)
        }

        // $( ) command substitution
        if ch == "(" {
            pos += 1
            let content = try scanNestedParens()
            return .commandSub(content)
        }

        // ${...} braced variable
        if ch == "{" {
            pos += 1
            return try scanBracedVariable()
        }

        // Special variables: $? $# $@ $* $$ $! $- $0
        if "?#@*$!-0".contains(ch) {
            pos += 1
            return .variable(.special(ch))
        }

        // Positional: $1-$9
        if ch.isNumber && ch != "0" {
            pos += 1
            return .variable(.positional(Int(String(ch))!))
        }

        // Named variable: $name
        if ch.isLetter || ch == "_" {
            var name = ""
            while pos < chars.count && (chars[pos].isLetter || chars[pos].isNumber || chars[pos] == "_") {
                name.append(chars[pos])
                pos += 1
            }
            return .variable(.named(name))
        }

        return .literal("$")
    }

    /// Scan inside double quotes
    private mutating func scanDoubleQuoted() throws -> [WordPart] {
        pos += 1 // skip opening "
        var parts: [WordPart] = []
        var literal = ""

        func flushLiteral() {
            if !literal.isEmpty {
                parts.append(.literal(literal))
                literal = ""
            }
        }

        while pos < chars.count {
            let ch = chars[pos]
            if ch == "\"" {
                pos += 1
                flushLiteral()
                return parts
            }
            if ch == "\\" {
                pos += 1
                if pos < chars.count {
                    let next = chars[pos]
                    // Only these are special inside double quotes
                    if "$`\"\\".contains(next) || next == "\n" {
                        if next == "\n" { pos += 1; continue } // line continuation
                        flushLiteral()
                        parts.append(.escapedChar(next))
                        pos += 1
                    } else {
                        literal.append("\\")
                        literal.append(next)
                        pos += 1
                    }
                } else {
                    literal.append("\\")
                }
                continue
            }
            if ch == "$" {
                flushLiteral()
                let part = try scanDollar()
                parts.append(part)
                continue
            }
            if ch == "`" {
                flushLiteral()
                pos += 1
                var content = ""
                while pos < chars.count && chars[pos] != "`" {
                    if chars[pos] == "\\" && pos + 1 < chars.count {
                        let next = chars[pos + 1]
                        if next == "`" || next == "\\" || next == "$" {
                            content.append(next)
                            pos += 2
                            continue
                        }
                    }
                    content.append(chars[pos])
                    pos += 1
                }
                guard pos < chars.count else { throw ParseError.unterminatedSubstitution }
                pos += 1
                parts.append(.backtickSub(content))
                continue
            }
            literal.append(ch)
            pos += 1
        }
        throw ParseError.unterminatedQuote
    }

    /// Scan $'...' ANSI-C quoted string
    private mutating func scanAnsiCQuoted() throws -> String {
        var result = ""
        while pos < chars.count && chars[pos] != "'" {
            if chars[pos] == "\\" && pos + 1 < chars.count {
                pos += 1
                switch chars[pos] {
                case "n": result.append("\n"); pos += 1
                case "t": result.append("\t"); pos += 1
                case "r": result.append("\r"); pos += 1
                case "a": result.append("\u{07}"); pos += 1
                case "b": result.append("\u{08}"); pos += 1
                case "e", "E": result.append("\u{1B}"); pos += 1
                case "\\": result.append("\\"); pos += 1
                case "'": result.append("'"); pos += 1
                case "\"": result.append("\""); pos += 1
                case "0":
                    pos += 1
                    var octal = ""
                    while octal.count < 3 && pos < chars.count && "01234567".contains(chars[pos]) {
                        octal.append(chars[pos]); pos += 1
                    }
                    if let val = UInt32(octal.isEmpty ? "0" : octal, radix: 8), let scalar = Unicode.Scalar(val) {
                        result.append(Character(scalar))
                    }
                case "x":
                    pos += 1
                    var hex = ""
                    while hex.count < 2 && pos < chars.count && chars[pos].isHexDigit {
                        hex.append(chars[pos]); pos += 1
                    }
                    if let val = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(val) {
                        result.append(Character(scalar))
                    }
                default:
                    result.append("\\")
                    result.append(chars[pos])
                    pos += 1
                }
            } else {
                result.append(chars[pos])
                pos += 1
            }
        }
        guard pos < chars.count else { throw ParseError.unterminatedQuote }
        pos += 1 // skip closing '
        return result
    }

    /// Scan nested parens for $(...)
    private mutating func scanNestedParens() throws -> String {
        var depth = 1
        var content = ""
        while pos < chars.count && depth > 0 {
            let ch = chars[pos]
            if ch == "(" { depth += 1 }
            else if ch == ")" {
                depth -= 1
                if depth == 0 { pos += 1; return content }
            }
            else if ch == "'" {
                content.append(ch); pos += 1
                while pos < chars.count && chars[pos] != "'" {
                    content.append(chars[pos]); pos += 1
                }
                if pos < chars.count { content.append(chars[pos]); pos += 1 }
                continue
            }
            else if ch == "\"" {
                content.append(ch); pos += 1
                while pos < chars.count && chars[pos] != "\"" {
                    if chars[pos] == "\\" && pos + 1 < chars.count {
                        content.append(chars[pos]); pos += 1
                    }
                    content.append(chars[pos]); pos += 1
                }
                if pos < chars.count { content.append(chars[pos]); pos += 1 }
                continue
            }
            else if ch == "\\" && pos + 1 < chars.count {
                content.append(ch); pos += 1
                content.append(chars[pos])
            }
            content.append(ch)
            pos += 1
        }
        if depth > 0 { throw ParseError.unterminatedSubstitution }
        return content
    }

    /// Scan ${...} braced variable expansion
    private mutating func scanBracedVariable() throws -> WordPart {
        guard pos < chars.count else { return .literal("${") }

        // ${!name} indirect
        // ${#name} length
        // ${name op word}
        var name = ""

        // Check for # (length) or ! (indirect) prefix
        let prefix = chars[pos]
        if prefix == "#" {
            pos += 1
            // Could be ${#} (special) or ${#name} (length)
            if pos < chars.count && chars[pos] == "}" {
                pos += 1
                return .variable(.special("#"))
            }
            // ${#name}
            name = scanVarName()
            if pos < chars.count && chars[pos] == "[" {
                // ${#arr[@]} or ${#arr[*]}
                pos += 1
                if pos < chars.count && (chars[pos] == "@" || chars[pos] == "*") {
                    pos += 1 // skip @ or *
                    if pos < chars.count && chars[pos] == "]" { pos += 1 }
                }
                if pos < chars.count && chars[pos] == "}" { pos += 1 }
                return .variable(.length(name))
            }
            if pos < chars.count && chars[pos] == "}" { pos += 1 }
            return .variable(.length(name))
        }

        // Special single-char variables in braces
        if "?@*$!-0".contains(prefix) && pos + 1 < chars.count && chars[pos + 1] == "}" {
            pos += 2
            return .variable(.special(prefix))
        }

        // Positional in braces: ${10}, ${1}
        if prefix.isNumber {
            var numStr = String(prefix)
            pos += 1
            while pos < chars.count && chars[pos].isNumber {
                numStr.append(chars[pos]); pos += 1
            }
            if pos < chars.count && chars[pos] == "}" {
                pos += 1
                if let n = Int(numStr) { return .variable(.positional(n)) }
            }
            // Has an operator after the number
            if let n = Int(numStr), n < 10 {
                name = numStr
            } else {
                if pos < chars.count && chars[pos] == "}" { pos += 1 }
                return .variable(.positional(Int(numStr) ?? 0))
            }
        }

        if name.isEmpty {
            name = scanVarName()
        }

        guard pos < chars.count else { return .variable(.named(name)) }

        // Simple close
        if chars[pos] == "}" {
            pos += 1
            return .variable(.named(name))
        }

        // Array element: ${arr[idx]}
        if chars[pos] == "[" {
            pos += 1
            if pos < chars.count && (chars[pos] == "@" || chars[pos] == "*") {
                let allType = chars[pos]
                pos += 1
                if pos < chars.count && chars[pos] == "]" { pos += 1 }
                if pos < chars.count && chars[pos] == "}" { pos += 1 }
                return .variable(.arrayAll(name, allType == "@"))
            }
            // Index expression
            var idx = ""
            var depth = 1
            while pos < chars.count && depth > 0 {
                if chars[pos] == "[" { depth += 1 }
                if chars[pos] == "]" { depth -= 1; if depth == 0 { break } }
                idx.append(chars[pos]); pos += 1
            }
            if pos < chars.count && chars[pos] == "]" { pos += 1 }
            if pos < chars.count && chars[pos] == "}" { pos += 1 }
            return .variable(.arrayElement(name, ShellWord(literal: idx)))
        }

        // Operators
        let op = try scanVarOp(name: name)
        return .variable(.withOp(name, op))
    }

    private mutating func scanVarName() -> String {
        var name = ""
        while pos < chars.count && (chars[pos].isLetter || chars[pos].isNumber || chars[pos] == "_") {
            name.append(chars[pos]); pos += 1
        }
        return name
    }

    private mutating func scanVarOp(name: String) throws -> VarOp {
        guard pos < chars.count else { throw ParseError.unterminatedSubstitution }
        let ch = chars[pos]

        // Substring: ${v:offset} or ${v:offset:length}
        if ch == ":" {
            let next = pos + 1 < chars.count ? chars[pos + 1] : Character("\0")
            // Check for :-, :=, :+, :?
            if next == "-" { pos += 2; let w = scanVarOpWord(); return .defaultValue(w, colonForm: true) }
            if next == "=" { pos += 2; let w = scanVarOpWord(); return .assignDefault(w, colonForm: true) }
            if next == "+" { pos += 2; let w = scanVarOpWord(); return .useAlternative(w, colonForm: true) }
            if next == "?" { pos += 2; let w = scanVarOpWord(); return .errorIfUnset(w, colonForm: true) }
            // Substring
            pos += 1
            var offset = ""
            while pos < chars.count && chars[pos] != ":" && chars[pos] != "}" {
                offset.append(chars[pos]); pos += 1
            }
            var length: String? = nil
            if pos < chars.count && chars[pos] == ":" {
                pos += 1
                var len = ""
                while pos < chars.count && chars[pos] != "}" {
                    len.append(chars[pos]); pos += 1
                }
                length = len
            }
            if pos < chars.count && chars[pos] == "}" { pos += 1 }
            return .substring(offset, length)
        }

        if ch == "-" { pos += 1; let w = scanVarOpWord(); return .defaultValue(w, colonForm: false) }
        if ch == "=" { pos += 1; let w = scanVarOpWord(); return .assignDefault(w, colonForm: false) }
        if ch == "+" { pos += 1; let w = scanVarOpWord(); return .useAlternative(w, colonForm: false) }
        if ch == "?" { pos += 1; let w = scanVarOpWord(); return .errorIfUnset(w, colonForm: false) }

        // Pattern removal
        if ch == "#" {
            pos += 1
            if pos < chars.count && chars[pos] == "#" {
                pos += 1; let p = scanVarOpPattern(); return .removeLargestPrefix(p)
            }
            let p = scanVarOpPattern(); return .removeSmallestPrefix(p)
        }
        if ch == "%" {
            pos += 1
            if pos < chars.count && chars[pos] == "%" {
                pos += 1; let p = scanVarOpPattern(); return .removeLargestSuffix(p)
            }
            let p = scanVarOpPattern(); return .removeSmallestSuffix(p)
        }

        // Replacement
        if ch == "/" {
            pos += 1
            var all = false
            var prefix = false
            var suffix = false
            if pos < chars.count {
                if chars[pos] == "/" { all = true; pos += 1 }
                else if chars[pos] == "#" { prefix = true; pos += 1 }
                else if chars[pos] == "%" { suffix = true; pos += 1 }
            }
            var pattern = ""
            while pos < chars.count && chars[pos] != "/" && chars[pos] != "}" {
                if chars[pos] == "\\" && pos + 1 < chars.count { pattern.append(chars[pos + 1]); pos += 2; continue }
                pattern.append(chars[pos]); pos += 1
            }
            var replacement = ""
            if pos < chars.count && chars[pos] == "/" {
                pos += 1
                while pos < chars.count && chars[pos] != "}" {
                    if chars[pos] == "\\" && pos + 1 < chars.count { replacement.append(chars[pos + 1]); pos += 2; continue }
                    replacement.append(chars[pos]); pos += 1
                }
            }
            if pos < chars.count && chars[pos] == "}" { pos += 1 }
            if prefix { return .replacePrefix(pattern, replacement) }
            if suffix { return .replaceSuffix(pattern, replacement) }
            return .replace(pattern, replacement, all: all)
        }

        // Case modification
        if ch == "^" {
            pos += 1
            let all = pos < chars.count && chars[pos] == "^"
            if all { pos += 1 }
            if pos < chars.count && chars[pos] == "}" { pos += 1 }
            return .uppercase(all: all)
        }
        if ch == "," {
            pos += 1
            let all = pos < chars.count && chars[pos] == ","
            if all { pos += 1 }
            if pos < chars.count && chars[pos] == "}" { pos += 1 }
            return .lowercase(all: all)
        }

        // Unknown operator, skip to }
        while pos < chars.count && chars[pos] != "}" { pos += 1 }
        if pos < chars.count { pos += 1 }
        return .defaultValue([], colonForm: false)
    }

    /// Scan word parts until } for ${var op word}
    private mutating func scanVarOpWord() -> [WordPart] {
        var parts: [WordPart] = []
        var literal = ""
        func flushLiteral() {
            if !literal.isEmpty { parts.append(.literal(literal)); literal = "" }
        }
        while pos < chars.count && chars[pos] != "}" {
            let ch = chars[pos]
            if ch == "\\" && pos + 1 < chars.count && chars[pos + 1] == "}" {
                literal.append("}"); pos += 2; continue
            }
            if ch == "$" {
                flushLiteral()
                if let part = try? scanDollar() { parts.append(part) }
                continue
            }
            if ch == "'" {
                flushLiteral()
                pos += 1
                var content = ""
                while pos < chars.count && chars[pos] != "'" { content.append(chars[pos]); pos += 1 }
                if pos < chars.count { pos += 1 }
                parts.append(.singleQuoted(content))
                continue
            }
            if ch == "\"" {
                flushLiteral()
                if let inner = try? scanDoubleQuoted() { parts.append(.doubleQuoted(inner)) }
                continue
            }
            literal.append(ch); pos += 1
        }
        flushLiteral()
        if pos < chars.count && chars[pos] == "}" { pos += 1 }
        return parts
    }

    private mutating func scanVarOpPattern() -> String {
        var pattern = ""
        while pos < chars.count && chars[pos] != "}" {
            if chars[pos] == "\\" && pos + 1 < chars.count {
                pattern.append(chars[pos + 1]); pos += 2; continue
            }
            pattern.append(chars[pos]); pos += 1
        }
        if pos < chars.count && chars[pos] == "}" { pos += 1 }
        return pattern
    }

    // MARK: Heredocs

    private mutating func scanHeredocDelimiter() throws -> (String, Bool) {
        var quoted = false
        var delimiter = ""

        if pos < chars.count && chars[pos] == "'" {
            quoted = true
            pos += 1
            while pos < chars.count && chars[pos] != "'" {
                delimiter.append(chars[pos]); pos += 1
            }
            if pos < chars.count { pos += 1 }
        } else if pos < chars.count && chars[pos] == "\"" {
            quoted = true
            pos += 1
            while pos < chars.count && chars[pos] != "\"" {
                delimiter.append(chars[pos]); pos += 1
            }
            if pos < chars.count { pos += 1 }
        } else {
            while pos < chars.count && !chars[pos].isWhitespace && chars[pos] != ";" && chars[pos] != "&" && chars[pos] != "|" {
                if chars[pos] == "\\" { quoted = true; pos += 1; if pos < chars.count { delimiter.append(chars[pos]); pos += 1 }; continue }
                delimiter.append(chars[pos]); pos += 1
            }
        }

        return (delimiter, quoted)
    }

    private mutating func processPendingHeredocs() throws {
        for heredoc in pendingHeredocs {
            var body = ""
            while pos < chars.count {
                var line = ""
                while pos < chars.count && chars[pos] != "\n" {
                    line.append(chars[pos]); pos += 1
                }
                if pos < chars.count { pos += 1 } // skip \n

                let trimmed = heredoc.stripTabs ? String(line.drop(while: { $0 == "\t" })) : line
                if trimmed == heredoc.delimiter {
                    break
                }
                body += line + "\n"
            }
            tokens.append(.heredocBody(body, heredoc.quoted))
        }
        pendingHeredocs.removeAll()
    }

    // MARK: Assignment detection

    private func detectAssignment(_ word: ShellWord) -> (String, ShellWord, Bool)? {
        // Assignment: NAME=VALUE or NAME+=VALUE
        // The first part must be a literal containing = and a valid name before it
        guard let firstPart = word.parts.first else { return nil }
        guard case .literal(let text) = firstPart else { return nil }
        guard let eqIdx = text.firstIndex(of: "=") else { return nil }

        var name = String(text[..<eqIdx])
        var append = false
        if name.hasSuffix("+") {
            name = String(name.dropLast())
            append = true
        }

        guard !name.isEmpty else { return nil }
        if let bracket = name.firstIndex(of: "["), name.hasSuffix("]") {
            let base = String(name[..<bracket])
            let indexText = String(name[name.index(after: bracket)..<name.index(before: name.endIndex)])
            guard !base.isEmpty else { return nil }
            guard base.first!.isLetter || base.first! == "_" else { return nil }
            guard base.dropFirst().allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return nil }
            guard Int(indexText.trimmingCharacters(in: .whitespacesAndNewlines)) != nil else { return nil }
        } else {
            guard name.first!.isLetter || name.first! == "_" else { return nil }
            guard name.dropFirst().allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return nil }
        }

        let valueText = String(text[text.index(after: eqIdx)...])
        var valueParts: [WordPart] = []
        if !valueText.isEmpty {
            valueParts.append(.literal(valueText))
        }
        valueParts.append(contentsOf: word.parts.dropFirst())

        return (name, ShellWord(valueParts), append)
    }
}

// MARK: - Recursive Descent Parser

private struct ParserState {
    var tokens: [Token]
    var pos: Int = 0
    var depth: Int = 0
    let limits: ExecutionLimits

    var current: Token { tokens[pos] }
    var isAtEnd: Bool { pos >= tokens.count - 1 }

    mutating func advance() {
        if pos < tokens.count - 1 { pos += 1 }
    }

    mutating func expect(_ check: (Token) -> Bool, _ message: String) throws {
        guard check(current) else { throw ParseError.expectedToken(message) }
        advance()
    }

    mutating func skipNewlines() {
        while case .newline = current { advance() }
    }

    mutating func skipTerminators() {
        while true {
            switch current {
            case .newline, .semi: advance()
            default: return
            }
        }
    }

    func isWordWithText(_ text: String) -> Bool {
        if case .word(let w) = current, wordText(w) == text { return true }
        return false
    }

    mutating func expectWord(_ text: String) throws {
        guard isWordWithText(text) else {
            throw ParseError.expectedToken(text)
        }
        advance()
    }

    // MARK: Top-level

    mutating func parseScript() throws -> Script {
        skipNewlines()
        var entries: [ListEntry] = []
        while !isAtEnd {
            if case .eof = current { break }
            // Stop at closing tokens
            if isWordWithText("fi") || isWordWithText("done") || isWordWithText("esac") ||
               isWordWithText("}") || isWordWithText("]]") || isWordWithText("then") ||
               isWordWithText("elif") || isWordWithText("else") || isWordWithText("do") {
                break
            }
            if case .rparen = current { break }
            if case .dsemi = current { break }
            if case .semiAmp = current { break }
            if case .dsemiAmp = current { break }

            let entry = try parseListEntry()
            entries.append(entry)
            skipTerminators()
        }
        return Script(entries)
    }

    mutating func parseListEntry() throws -> ListEntry {
        let andOr = try parseAndOrList()
        var background = false
        if case .amp = current {
            background = true
            advance()
        }
        return ListEntry(andOr, background: background)
    }

    mutating func parseAndOrList() throws -> AndOrList {
        let first = try parsePipeline()
        var rest: [(AndOrOp, PipelineDef)] = []
        while true {
            switch current {
            case .andIf:
                advance(); skipNewlines()
                rest.append((.and, try parsePipeline()))
            case .orIf:
                advance(); skipNewlines()
                rest.append((.or, try parsePipeline()))
            default:
                return AndOrList(first, rest: rest)
            }
        }
    }

    mutating func parsePipeline() throws -> PipelineDef {
        var negated = false
        if case .bang = current {
            negated = true
            advance()
            skipNewlines()
        }
        // Also check for ! as a word
        if isWordWithText("!") {
            negated = true
            advance()
            skipNewlines()
        }

        var commands: [Command] = []
        var pipeStandardError: [Bool] = []
        commands.append(try parseCommand())

        while true {
            if case .pipe = current {
                advance(); skipNewlines()
                commands.append(try parseCommand())
                pipeStandardError.append(false)
                guard commands.count <= limits.maxPipelineLength else {
                    throw ParseError.tooManyTokens(commands.count)
                }
            } else if case .pipeAmp = current {
                advance(); skipNewlines()
                commands.append(try parseCommand())
                pipeStandardError.append(true)
                guard commands.count <= limits.maxPipelineLength else {
                    throw ParseError.tooManyTokens(commands.count)
                }
            } else {
                break
            }
        }

        return PipelineDef(negated: negated, commands, pipeStandardError: pipeStandardError)
    }

    mutating func parseCommand() throws -> Command {
        depth += 1
        defer { depth -= 1 }
        guard depth <= limits.maxCallDepth else { throw ParseError.maxDepthExceeded }

        // Check for compound commands by reserved word
        if let rw = currentReservedWord() {
            switch rw {
            case "if": return .compound(try parseIf(), [])
            case "for": return .compound(try parseFor(), [])
            case "while": return .compound(try parseWhile(), [])
            case "until": return .compound(try parseUntil(), [])
            case "case": return .compound(try parseCase(), [])
            case "select": return .compound(try parseSelect(), [])
            case "{": return .compound(try parseBraceGroup(), [])
            case "[[": return .compound(try parseCondCommand(), [])
            case "function": return try parseFunctionDef()
            default: break
            }
        }

        // Check for (( )) arithmetic command
        if case .lparen = current {
            let savedPos = pos
            advance()
            if case .lparen = current {
                // (( expr ))
                advance()
                var expr = ""
                var depth = 1
                while depth > 0 {
                    if case .rparen = current {
                        if depth == 1 {
                            advance()
                            if case .rparen = current {
                                advance()
                                depth = 0
                            } else {
                                expr.append(")")
                            }
                        } else {
                            depth -= 1
                            expr.append(")")
                            advance()
                        }
                    } else if case .lparen = current {
                        depth += 1
                        expr.append("(")
                        advance()
                    } else {
                        expr.append(current.description)
                        advance()
                    }
                    if case .eof = current { break }
                }
                let redirects = try parseRedirections()
                return .compound(.arithCommand(expr.trimmingCharacters(in: .whitespaces)), redirects)
            }
            // Subshell
            pos = savedPos
            return .compound(try parseSubshell(), [])
        }

        // Function def: name () { ... }
        if case .word(let w) = current {
            let savedPos = pos
            if let name = wordText(w) {
                advance()
                if case .lparen = current {
                    advance()
                    if case .rparen = current {
                        advance()
                        skipNewlines()
                        let body = try parseCommand()
                        return .functionDef(FunctionDef(name: name, body: body))
                    }
                }
            }
            pos = savedPos
        }

        // Simple command
        return .simple(try parseSimpleCommand())
    }

    // MARK: Simple command

    mutating func parseSimpleCommand() throws -> SimpleCommand {
        var assignments: [Assignment] = []
        var words: [ShellWord] = []
        var redirections: [Redirection] = []

        // Leading assignments
        while case .assignment(let name, let value, let append) = current {
            advance()
            if !append, value.isEmpty, case .lparen = current {
                assignments.append(Assignment(name: name, arrayValues: try parseArrayLiteral()))
            } else {
                assignments.append(Assignment(name: name, value: value, append: append))
            }
        }

        // Words and redirections
        loop: while true {
            switch current {
            case .word(let w):
                // Reserved words are only special at command position (before any arguments)
                if words.isEmpty && assignments.isEmpty {
                    if let rw = isReservedWord(w) {
                        if ["then", "fi", "elif", "else", "do", "done", "esac", "}", "]]", "in"].contains(rw) {
                            break loop
                        }
                    }
                }
                words.append(w)
                advance()

            case .assignment(let name, let value, let append):
                advance()
                if words.isEmpty {
                    if !append, value.isEmpty, case .lparen = current {
                        assignments.append(Assignment(name: name, arrayValues: try parseArrayLiteral()))
                    } else {
                        assignments.append(Assignment(name: name, value: value, append: append))
                    }
                } else {
                    if !append, value.isEmpty, case .lparen = current {
                        let arrayValues = try parseArrayLiteral()
                        let raw = arrayValues.map(\.rawText).joined(separator: " ")
                        words.append(ShellWord([.singleQuoted("\(name)=(\(raw))")]))
                    } else {
                        // After the first word, treat as a regular word
                        let operatorText = append ? "+=" : "="
                        words.append(ShellWord([.literal("\(name)\(operatorText)")] + value.parts))
                    }
                }

            case .ioNumber(let fd):
                advance()
                let redir = try parseRedirection(fd: fd)
                redirections.append(redir)

            case .less, .great, .dgreat, .lessAnd, .greatAnd, .lessGreat, .clobber, .tless, .dless, .dlessDash:
                let redir = try parseRedirection(fd: nil)
                redirections.append(redir)

            default:
                break loop
            }
        }

        return SimpleCommand(assignments: assignments, words: words, redirections: redirections)
    }

    mutating func parseArrayLiteral() throws -> [ShellWord] {
        guard case .lparen = current else { return [] }
        advance()
        var values: [ShellWord] = []
        while !isAtEnd {
            switch current {
            case .rparen:
                advance()
                return values
            case .newline:
                advance()
            case .word(let word):
                values.append(word)
                advance()
            default:
                throw ParseError.expectedToken("array element or )")
            }
        }
        throw ParseError.expectedToken(")")
    }

    mutating func parseRedirection(fd: Int?) throws -> Redirection {
        let op: RedirectionOp
        switch current {
        case .less: op = .input; advance()
        case .great: op = .output; advance()
        case .dgreat: op = .append; advance()
        case .lessAnd: op = .duplicateInput; advance()
        case .greatAnd: op = .duplicateOutput; advance()
        case .lessGreat: op = .inputOutput; advance()
        case .clobber: op = .clobber; advance()
        case .tless: op = .herestring; advance()
        case .dless: op = .heredoc; advance()
        case .dlessDash: op = .heredocStripTabs; advance()
        default:
            throw ParseError.invalidRedirection(current.description)
        }

        // For heredoc, the next token should be the heredoc body
        if op == .heredoc || op == .heredocStripTabs {
            if case .heredocBody(let body, let quoted) = current {
                advance()
                return Redirection(
                    fd: fd,
                    op: op,
                    target: ShellWord(literal: body),
                    heredocSuppressExpansion: quoted
                )
            }
            // If no body yet (might happen), use empty
            return Redirection(fd: fd, op: op, target: .empty)
        }

        // Handle >&2, >&1, etc.
        if op == .duplicateOutput || op == .duplicateInput {
            if case .word(let w) = current {
                advance()
                return Redirection(fd: fd, op: op, target: w)
            }
            // >&  without target = redirect stderr to stdout (shorthand)
            // Actually >& by itself is ambiguous. Default to duplication.
            return Redirection(fd: fd, op: op, target: ShellWord(literal: "1"))
        }

        guard case .word(let target) = current else {
            throw ParseError.expectedToken("filename for redirection")
        }
        advance()
        return Redirection(fd: fd, op: op, target: target)
    }

    mutating func parseRedirections() throws -> [Redirection] {
        var redirections: [Redirection] = []
        while true {
            switch current {
            case .ioNumber(let fd):
                advance()
                redirections.append(try parseRedirection(fd: fd))
            case .less, .great, .dgreat, .lessAnd, .greatAnd, .lessGreat, .clobber, .tless, .dless, .dlessDash:
                redirections.append(try parseRedirection(fd: nil))
            default:
                return redirections
            }
        }
    }

    // MARK: Compound commands

    mutating func parseIf() throws -> CompoundCommand {
        try expectWord("if")
        skipNewlines()
        var conditions: [(condition: Script, body: Script)] = []
        let condition = try parseScript()
        try expectWord("then")
        skipNewlines()
        let body = try parseScript()
        conditions.append((condition, body))

        while isWordWithText("elif") {
            advance(); skipNewlines()
            let elifCond = try parseScript()
            try expectWord("then")
            skipNewlines()
            let elifBody = try parseScript()
            conditions.append((elifCond, elifBody))
        }

        var elseBody: Script? = nil
        if isWordWithText("else") {
            advance(); skipNewlines()
            elseBody = try parseScript()
        }

        try expectWord("fi")
        return .ifClause(IfClause(conditions: conditions, elseBody: elseBody))
    }

    mutating func parseFor() throws -> CompoundCommand {
        try expectWord("for")
        skipNewlines()
        guard case .word(let varWord) = current, let varName = wordText(varWord) else {
            throw ParseError.expectedToken("variable name")
        }
        advance()
        skipNewlines()

        // Check for C-style for: for (( init; cond; update ))
        // This would be detected earlier as (( so handle here if needed

        var words: [ShellWord]? = nil
        if isWordWithText("in") {
            advance()
            var wordList: [ShellWord] = []
            while !current.isCommandTerminator && !isWordWithText("do") {
                if case .word(let w) = current {
                    wordList.append(w)
                    advance()
                } else {
                    break
                }
            }
            words = wordList
        }

        // Skip ; or newline before do
        skipTerminators()
        try expectWord("do")
        skipNewlines()
        let body = try parseScript()
        try expectWord("done")
        return .forClause(ForClause(variable: varName, words: words, body: body))
    }

    mutating func parseWhile() throws -> CompoundCommand {
        try expectWord("while")
        skipNewlines()
        let condition = try parseScript()
        try expectWord("do")
        skipNewlines()
        let body = try parseScript()
        try expectWord("done")
        return .whileClause(LoopClause(condition: condition, body: body))
    }

    mutating func parseUntil() throws -> CompoundCommand {
        try expectWord("until")
        skipNewlines()
        let condition = try parseScript()
        try expectWord("do")
        skipNewlines()
        let body = try parseScript()
        try expectWord("done")
        return .untilClause(LoopClause(condition: condition, body: body))
    }

    mutating func parseCase() throws -> CompoundCommand {
        try expectWord("case")
        guard case .word(let w) = current else { throw ParseError.expectedToken("word") }
        advance()
        skipNewlines()
        try expectWord("in")
        skipNewlines()

        var items: [CaseItem] = []
        while !isWordWithText("esac") && !isAtEnd {
            skipNewlines()
            if isWordWithText("esac") { break }

            // Parse patterns: pat1 | pat2 | pat3)
            if case .lparen = current { advance() } // optional leading (
            var patterns: [ShellWord] = []
            while true {
                guard case .word(let p) = current else { break }
                patterns.append(p)
                advance()
                if case .pipe = current { advance(); continue }
                break
            }
            // Expect )
            if case .rparen = current { advance() }
            skipNewlines()

            let body = try parseScript()
            skipNewlines()

            let terminator: CaseTerminator
            switch current {
            case .dsemi: terminator = .break_; advance()
            case .semiAmp: terminator = .fallthrough_; advance()
            case .dsemiAmp: terminator = .testNext; advance()
            default: terminator = .break_
            }
            skipNewlines()

            items.append(CaseItem(patterns: patterns, body: body.isEmpty ? nil : body, terminator: terminator))
        }

        try expectWord("esac")
        return .caseClause(CaseClause(word: w, items: items))
    }

    mutating func parseSelect() throws -> CompoundCommand {
        try expectWord("select")
        guard case .word(let varWord) = current, let varName = wordText(varWord) else {
            throw ParseError.expectedToken("variable name")
        }
        advance()

        var words: [ShellWord]? = nil
        if isWordWithText("in") {
            advance()
            var wordList: [ShellWord] = []
            while !current.isCommandTerminator && !isWordWithText("do") {
                if case .word(let w) = current { wordList.append(w); advance() } else { break }
            }
            words = wordList
        }

        skipTerminators()
        try expectWord("do")
        skipNewlines()
        let body = try parseScript()
        try expectWord("done")
        return .selectClause(SelectClause(variable: varName, words: words, body: body))
    }

    mutating func parseBraceGroup() throws -> CompoundCommand {
        try expectWord("{")
        skipNewlines()
        let body = try parseScript()
        try expectWord("}")
        return .braceGroup(body)
    }

    mutating func parseSubshell() throws -> CompoundCommand {
        guard case .lparen = current else { throw ParseError.expectedToken("(") }
        advance()
        skipNewlines()
        let body = try parseScript()
        guard case .rparen = current else { throw ParseError.expectedToken(")") }
        advance()
        return .subshell(body)
    }

    mutating func parseCondCommand() throws -> CompoundCommand {
        try expectWord("[[")
        let expr = try parseCondExpr()
        try expectWord("]]")
        return .condCommand(expr)
    }

    // MARK: Conditional expression parsing [[ ... ]]

    mutating func parseCondExpr() throws -> CondExpr {
        try parseCondOr()
    }

    mutating func parseCondOr() throws -> CondExpr {
        var left = try parseCondAnd()
        while isWordWithText("||") || { if case .orIf = current { return true }; return false }() {
            advance(); skipNewlines()
            let right = try parseCondAnd()
            left = .or(left, right)
        }
        return left
    }

    mutating func parseCondAnd() throws -> CondExpr {
        var left = try parseCondNot()
        while isWordWithText("&&") || { if case .andIf = current { return true }; return false }() {
            advance(); skipNewlines()
            let right = try parseCondNot()
            left = .and(left, right)
        }
        return left
    }

    mutating func parseCondNot() throws -> CondExpr {
        if isWordWithText("!") || { if case .bang = current { return true }; return false }() {
            advance(); skipNewlines()
            return .not(try parseCondPrimary())
        }
        return try parseCondPrimary()
    }

    mutating func parseCondPrimary() throws -> CondExpr {
        // ( expr )
        if case .lparen = current {
            advance(); skipNewlines()
            let inner = try parseCondExpr()
            if case .rparen = current { advance() }
            return .paren(inner)
        }

        // Unary operators: -f, -d, -z, -n, etc.
        if case .word(let w) = current, let text = wordText(w), text.hasPrefix("-") && text.count >= 2 && text.count <= 3 {
            let op = text
            advance()
            guard case .word(let operand) = current else {
                // Could be a standalone word that starts with -
                return .word(w)
            }
            // Check if the NEXT token is a binary operator or ]]
            // If so, this might be a unary test
            let unaryOps: Set<String> = ["-f", "-d", "-e", "-s", "-r", "-w", "-x", "-L", "-h", "-p", "-S", "-b", "-c", "-t", "-g", "-u", "-k", "-O", "-G", "-N", "-z", "-n", "-v", "-a"]
            if unaryOps.contains(op) {
                advance()
                return .unary(op, operand)
            }
            // Not a known unary op, treat as word for binary
            // Put back and handle as binary
        }

        // Get left word
        guard case .word(let left) = current else {
            if isWordWithText("]]") { return .word(.empty) }
            throw ParseError.expectedToken("expression")
        }
        advance()

        // Check for binary operator
        let binaryOps: Set<String> = ["==", "!=", "=", "=~", "<", ">", "-eq", "-ne", "-lt", "-le", "-gt", "-ge", "-nt", "-ot", "-ef"]
        if case .word(let opWord) = current, let opText = wordText(opWord), binaryOps.contains(opText) {
            advance()
            guard case .word(let right) = current else { throw ParseError.expectedToken("operand") }
            advance()
            if opText == "=~" {
                return .binary(left, "=~", right)
            }
            return .binary(left, opText, right)
        }

        // Standalone word (true if non-empty)
        return .word(left)
    }

    // MARK: Function definition

    mutating func parseFunctionDef() throws -> Command {
        try expectWord("function")
        guard case .word(let nameWord) = current, let name = wordText(nameWord) else {
            throw ParseError.expectedToken("function name")
        }
        advance()
        // Optional ()
        if case .lparen = current {
            advance()
            if case .rparen = current { advance() }
        }
        skipNewlines()
        let body = try parseCommand()
        return .functionDef(FunctionDef(name: name, body: body))
    }

    // MARK: Helpers

    func currentReservedWord() -> String? {
        guard case .word(let w) = current else { return nil }
        return isReservedWord(w)
    }
}
