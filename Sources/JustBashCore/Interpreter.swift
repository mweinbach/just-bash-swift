import Foundation
import JustBashCommands
import JustBashFS

public final class ShellInterpreter: @unchecked Sendable {
    private let fileSystem: VirtualFileSystem
    private let registry: CommandRegistry
    private let limits: ExecutionLimits

    public init(fileSystem: VirtualFileSystem, registry: CommandRegistry, limits: ExecutionLimits) {
        self.fileSystem = fileSystem
        self.registry = registry
        self.limits = limits
    }

    // MARK: - Public

    public func execute(script: Script, session: inout ShellSession, stdin: String = "") async -> ExecResult {
        do {
            return try await executeScript(script, session: &session, stdin: stdin)
        } catch ControlFlow.exit(let code) {
            return ExecResult(stdout: "", stderr: "", exitCode: code)
        } catch {
            return ExecResult(stdout: "", stderr: "bash: \(error.localizedDescription)\n", exitCode: 1)
        }
    }

    // MARK: - Script execution

    private func executeScript(_ script: Script, session: inout ShellSession, stdin: String) async throws -> ExecResult {
        var combined = ExecResult()
        for entry in script.entries {
            let result = try await executeListEntry(entry, session: &session, stdin: stdin)
            combined.stdout += result.stdout
            combined.stderr += result.stderr
            combined.exitCode = result.exitCode
            combined = enforceOutputLimit(combined)
            session.lastExitCode = combined.exitCode

            if session.options.errexit && combined.exitCode != 0 {
                throw ControlFlow.exit(combined.exitCode)
            }
        }
        return combined
    }

    private func executeListEntry(_ entry: ListEntry, session: inout ShellSession, stdin: String) async throws -> ExecResult {
        let result = try await executeAndOr(entry.andOr, session: &session, stdin: stdin)
        // Background execution is a no-op in our sandbox (no real concurrency)
        return result
    }

    private func executeAndOr(_ andOr: AndOrList, session: inout ShellSession, stdin: String) async throws -> ExecResult {
        var result = try await executePipeline(andOr.first, session: &session, stdin: stdin)
        session.lastExitCode = result.exitCode

        for (op, pipeline) in andOr.rest {
            switch op {
            case .and:
                if result.exitCode == 0 {
                    let next = try await executePipeline(pipeline, session: &session, stdin: stdin)
                    result.stdout += next.stdout
                    result.stderr += next.stderr
                    result.exitCode = next.exitCode
                    session.lastExitCode = next.exitCode
                }
            case .or:
                if result.exitCode != 0 {
                    let next = try await executePipeline(pipeline, session: &session, stdin: stdin)
                    result.stdout += next.stdout
                    result.stderr += next.stderr
                    result.exitCode = next.exitCode
                    session.lastExitCode = next.exitCode
                }
            }
        }
        return result
    }

    private func executePipeline(_ pipeline: PipelineDef, session: inout ShellSession, stdin: String) async throws -> ExecResult {
        var pipedInput = stdin
        var allStderr = ""
        var lastResult = ExecResult()
        var pipelineExitCodes: [Int] = []

        for (index, command) in pipeline.commands.enumerated() {
            session.commandCount += 1
            if session.commandCount > limits.maxCommandCount {
                return ExecResult.failure("maximum command count exceeded", exitCode: 1)
            }
            let result = enforceOutputLimit(try await executeCommand(command, session: &session, stdin: pipedInput))
            let pipeStderr = index < pipeline.pipeStandardError.count ? pipeline.pipeStandardError[index] : false
            if pipeStderr {
                pipedInput = result.stdout + result.stderr
            } else {
                allStderr += result.stderr
                pipedInput = result.stdout
            }
            lastResult = result
            pipelineExitCodes.append(result.exitCode)
        }

        var exitCode = lastResult.exitCode
        if session.options.pipefail {
            exitCode = pipelineExitCodes.last(where: { $0 != 0 }) ?? 0
        }
        if pipeline.negated {
            exitCode = exitCode == 0 ? 1 : 0
        }

        return ExecResult(stdout: lastResult.stdout, stderr: allStderr, exitCode: exitCode)
    }

    // MARK: - Command dispatch

    private func executeCommand(_ command: Command, session: inout ShellSession, stdin: String) async throws -> ExecResult {
        switch command {
        case .simple(let simple):
            return try await executeSimple(simple, session: &session, stdin: stdin)
        case .compound(let compound, let redirects):
            let result = try await executeCompound(compound, session: &session, stdin: stdin)
            return try await applyRedirections(result, redirects: redirects, session: &session, stdin: stdin)
        case .functionDef(let funcDef):
            session.functions[funcDef.name] = funcDef.body
            return ExecResult.success()
        }
    }

    // MARK: - Simple command

    private func executeSimple(_ cmd: SimpleCommand, session: inout ShellSession, stdin: String) async throws -> ExecResult {
        if let aliasName = cmd.words.first?.simpleLiteralText,
           let aliasValue = session.aliases[aliasName] {
            guard session.aliasExpansionDepth < 16 else {
                throw ShellRuntimeError.aliasExpansionTooDeep
            }
            session.aliasExpansionDepth += 1
            defer { session.aliasExpansionDepth -= 1 }

            var expandedCommand = cmd
            expandedCommand.words = try parseAliasWords(aliasValue) + Array(cmd.words.dropFirst())
            return try await executeSimple(expandedCommand, session: &session, stdin: stdin)
        }

        var environment = session.environment
        // Merge local scopes for expansion
        for scope in session.localScopes {
            for (k, v) in scope {
                if let v { environment[k] = v }
            }
        }

        // Apply assignments
        for assignment in cmd.assignments {
            let value = try await expandWord(assignment.value, session: &session, stdin: stdin)
            if cmd.words.isEmpty {
                // Bare assignments persist in session
                if assignment.append {
                    let existing = session.getVariable(assignment.name) ?? ""
                    session.setVariable(assignment.name, existing + value)
                } else {
                    session.setVariable(assignment.name, value)
                }
                environment[assignment.name] = session.getVariable(assignment.name)
            } else {
                // Command-scoped assignments
                environment[assignment.name] = value
            }
        }

        if cmd.words.isEmpty && cmd.assignments.isEmpty && cmd.redirections.isEmpty {
            return ExecResult.success()
        }

        if cmd.words.isEmpty {
            // Only assignments and/or redirections
            let assignmentTrace = cmd.assignments.map { assignment -> String in
                let value = session.getVariable(assignment.name) ?? ""
                return assignment.append ? "\(assignment.name)+=\(value)" : "\(assignment.name)=\(value)"
            }
            if !cmd.redirections.isEmpty {
                let result = try await applyRedirections(ExecResult.success(), redirects: cmd.redirections, session: &session, stdin: stdin)
                return addXtraceIfNeeded(result, traceComponents: assignmentTrace, session: session)
            }
            return addXtraceIfNeeded(ExecResult.success(), traceComponents: assignmentTrace, session: session)
        }

        // Expand words
        let expandedWords = try await expandWords(cmd.words, session: &session, stdin: stdin)
        guard let commandName = expandedWords.first else { return ExecResult.success() }
        let arguments = Array(expandedWords.dropFirst())
        let traceComponents = cmd.assignments.map { assignment -> String in
            let value = environment[assignment.name] ?? session.getVariable(assignment.name) ?? ""
            return assignment.append ? "\(assignment.name)+=\(value)" : "\(assignment.name)=\(value)"
        } + expandedWords

        // Handle stdin redirection
        var effectiveStdin = stdin
        for redir in cmd.redirections {
            if redir.effectiveFD == 0 {
                switch redir.op {
                case .input:
                    let path = try await expandWord(redir.target, session: &session, stdin: stdin)
                    do { effectiveStdin = try fileSystem.readFile(path, relativeTo: session.cwd) }
                    catch { return ExecResult.failure("\(commandName): \(error.localizedDescription)") }
                case .herestring:
                    effectiveStdin = try await expandWord(redir.target, session: &session, stdin: stdin) + "\n"
                case .heredoc, .heredocStripTabs:
                    let body = redir.target.rawText
                    if redir.heredocSuppressExpansion {
                        effectiveStdin = body
                    } else {
                        effectiveStdin = try await expandHeredoc(body, session: &session)
                    }
                default: break
                }
            }
        }

        // Execute
        let result: ExecResult
        if let builtin = shellBuiltin(commandName) {
            result = try await builtin(arguments, &session, environment, effectiveStdin)
        } else if let funcBody = session.functions[commandName] {
            result = try await executeFunction(funcBody, arguments: arguments, session: &session, stdin: effectiveStdin)
        } else if let command = registry.command(named: commandName) {
            let capturedSession = session
            let subshellExec: SubshellExecutor = { [self] script in
                var subSession = capturedSession
                return await self.execute(script: (try? ShellParser(limits: self.limits).parse(script)) ?? Script(), session: &subSession, stdin: "")
            }
            let context = CommandContext(fileSystem: fileSystem, cwd: session.cwd, environment: environment, stdin: effectiveStdin, executeSubshell: subshellExec)
            result = await command.execute(arguments, context)
        } else {
            result = ExecResult.failure("\(commandName): command not found", exitCode: 127)
        }

        session.lastExitCode = result.exitCode

        // Apply output redirections
        let redirected = try await applyOutputRedirections(result, redirects: cmd.redirections, commandName: commandName, session: &session, stdin: stdin)
        return addXtraceIfNeeded(redirected, traceComponents: traceComponents, session: session)
    }

    // MARK: - Compound commands

    private func executeCompound(_ compound: CompoundCommand, session: inout ShellSession, stdin: String) async throws -> ExecResult {
        switch compound {
        case .ifClause(let clause):
            return try await executeIf(clause, session: &session, stdin: stdin)
        case .forClause(let clause):
            return try await executeFor(clause, session: &session, stdin: stdin)
        case .forArithClause(let clause):
            return try await executeForArith(clause, session: &session, stdin: stdin)
        case .whileClause(let clause):
            return try await executeWhile(clause, isUntil: false, session: &session, stdin: stdin)
        case .untilClause(let clause):
            return try await executeWhile(clause, isUntil: true, session: &session, stdin: stdin)
        case .caseClause(let clause):
            return try await executeCase(clause, session: &session, stdin: stdin)
        case .selectClause:
            return ExecResult.success() // select requires interactive input
        case .braceGroup(let script):
            return try await executeScript(script, session: &session, stdin: stdin)
        case .subshell(let script):
            var subSession = session
            let result = try await executeScript(script, session: &subSession, stdin: stdin)
            session.lastExitCode = result.exitCode
            return result
        case .condCommand(let expr):
            let result = try await evaluateCondExpr(expr, session: &session, stdin: stdin)
            return ExecResult(stdout: "", stderr: "", exitCode: result ? 0 : 1)
        case .arithCommand(let expr):
            let value = evaluateArithmetic(expr, session: &session)
            return ExecResult(stdout: "", stderr: "", exitCode: value != 0 ? 0 : 1)
        }
    }

    private func executeIf(_ clause: IfClause, session: inout ShellSession, stdin: String) async throws -> ExecResult {
        for (condition, body) in clause.conditions {
            let condResult = try await executeScript(condition, session: &session, stdin: stdin)
            if condResult.exitCode == 0 {
                return try await executeScript(body, session: &session, stdin: stdin)
            }
        }
        if let elseBody = clause.elseBody {
            return try await executeScript(elseBody, session: &session, stdin: stdin)
        }
        return ExecResult.success()
    }

    private func executeFor(_ clause: ForClause, session: inout ShellSession, stdin: String) async throws -> ExecResult {
        let items: [String]
        if let words = clause.words {
            items = try await expandWords(words, session: &session, stdin: stdin)
        } else {
            items = session.positionalParams
        }

        var combined = ExecResult()
        var iterations = 0
        for item in items {
            iterations += 1
            if iterations > limits.maxLoopIterations {
                return ExecResult.failure("for: maximum loop iterations exceeded", exitCode: 1)
            }
            session.setVariable(clause.variable, item)
            do {
                let result = try await executeScript(clause.body, session: &session, stdin: stdin)
                combined.stdout += result.stdout
                combined.stderr += result.stderr
                combined.exitCode = result.exitCode
            } catch ControlFlow.break(let n) {
                if n > 1 { throw ControlFlow.break(n - 1) }
                break
            } catch ControlFlow.continue(let n) {
                if n > 1 { throw ControlFlow.continue(n - 1) }
                continue
            }
        }
        return combined
    }

    private func executeForArith(_ clause: ForArithClause, session: inout ShellSession, stdin: String) async throws -> ExecResult {
        _ = evaluateArithmetic(clause.initialize, session: &session)
        var combined = ExecResult()
        var iterations = 0
        while true {
            if !clause.condition.isEmpty {
                let condVal = evaluateArithmetic(clause.condition, session: &session)
                if condVal == 0 { break }
            }
            iterations += 1
            if iterations > limits.maxLoopIterations {
                return ExecResult.failure("for: maximum loop iterations exceeded", exitCode: 1)
            }
            do {
                let result = try await executeScript(clause.body, session: &session, stdin: stdin)
                combined.stdout += result.stdout
                combined.stderr += result.stderr
                combined.exitCode = result.exitCode
            } catch ControlFlow.break(let n) {
                if n > 1 { throw ControlFlow.break(n - 1) }
                break
            } catch ControlFlow.continue(let n) {
                if n > 1 { throw ControlFlow.continue(n - 1) }
            }
            _ = evaluateArithmetic(clause.update, session: &session)
        }
        return combined
    }

    private func executeWhile(_ clause: LoopClause, isUntil: Bool, session: inout ShellSession, stdin: String) async throws -> ExecResult {
        var combined = ExecResult()
        var iterations = 0
        while true {
            iterations += 1
            if iterations > limits.maxLoopIterations {
                return ExecResult.failure("while: maximum loop iterations exceeded", exitCode: 1)
            }
            let condResult = try await executeScript(clause.condition, session: &session, stdin: stdin)
            let shouldContinue = isUntil ? (condResult.exitCode != 0) : (condResult.exitCode == 0)
            if !shouldContinue { break }

            do {
                let result = try await executeScript(clause.body, session: &session, stdin: stdin)
                combined.stdout += result.stdout
                combined.stderr += result.stderr
                combined.exitCode = result.exitCode
            } catch ControlFlow.break(let n) {
                if n > 1 { throw ControlFlow.break(n - 1) }
                break
            } catch ControlFlow.continue(let n) {
                if n > 1 { throw ControlFlow.continue(n - 1) }
                continue
            }
        }
        return combined
    }

    private func executeCase(_ clause: CaseClause, session: inout ShellSession, stdin: String) async throws -> ExecResult {
        let word = try await expandWord(clause.word, session: &session, stdin: stdin)
        var combined = ExecResult()
        var matched = false

        for item in clause.items {
            if !matched {
                for pattern in item.patterns {
                    let patternStr = try await expandWord(pattern, session: &session, stdin: stdin)
                    if VirtualFileSystem.globMatch(name: word, pattern: patternStr) || patternStr == "*" {
                        matched = true
                        break
                    }
                }
            }
            if matched {
                if let body = item.body {
                    let result = try await executeScript(body, session: &session, stdin: stdin)
                    combined.stdout += result.stdout
                    combined.stderr += result.stderr
                    combined.exitCode = result.exitCode
                }
                switch item.terminator {
                case .break_: return combined
                case .fallthrough_: continue // execute next case body unconditionally
                case .testNext: matched = false; continue // test next pattern
                }
            }
        }
        return combined
    }

    // MARK: - Functions

    private func executeFunction(_ body: Command, arguments: [String], session: inout ShellSession, stdin: String) async throws -> ExecResult {
        guard session.callDepth < limits.maxCallDepth else {
            return ExecResult.failure("maximum call depth exceeded", exitCode: 1)
        }
        let savedParams = session.positionalParams
        let savedDepth = session.callDepth
        session.positionalParams = arguments
        session.callDepth += 1
        session.pushScope()

        defer {
            session.popScope()
            session.positionalParams = savedParams
            session.callDepth = savedDepth
        }

        do {
            return try await executeCommand(body, session: &session, stdin: stdin)
        } catch ControlFlow.return(let code) {
            return ExecResult(stdout: "", stderr: "", exitCode: code)
        }
    }

    // MARK: - Conditional expressions [[ ]]

    private func evaluateCondExpr(_ expr: CondExpr, session: inout ShellSession, stdin: String) async throws -> Bool {
        switch expr {
        case .unary(let op, let word):
            let val = try await expandWord(word, session: &session, stdin: stdin)
            return evaluateUnaryTest(op, val, session: session)

        case .binary(let left, let op, let right):
            let l = try await expandWord(left, session: &session, stdin: stdin)
            let r = try await expandWord(right, session: &session, stdin: stdin)
            return evaluateBinaryTest(l, op, r)

        case .and(let a, let b):
            let aResult = try await evaluateCondExpr(a, session: &session, stdin: stdin)
            if !aResult { return false }
            return try await evaluateCondExpr(b, session: &session, stdin: stdin)

        case .or(let a, let b):
            let aResult = try await evaluateCondExpr(a, session: &session, stdin: stdin)
            if aResult { return true }
            return try await evaluateCondExpr(b, session: &session, stdin: stdin)

        case .not(let inner):
            return try await !evaluateCondExpr(inner, session: &session, stdin: stdin)

        case .paren(let inner):
            return try await evaluateCondExpr(inner, session: &session, stdin: stdin)

        case .word(let w):
            let val = try await expandWord(w, session: &session, stdin: stdin)
            return !val.isEmpty
        }
    }

    private func evaluateUnaryTest(_ op: String, _ val: String, session: ShellSession) -> Bool {
        let path = VirtualPath.normalize(val, relativeTo: session.cwd)
        switch op {
        case "-z": return val.isEmpty
        case "-n": return !val.isEmpty
        case "-e": return fileSystem.exists(path)
        case "-f": return fileSystem.exists(path) && !fileSystem.isDirectory(path)
        case "-d": return fileSystem.isDirectory(path)
        case "-s":
            guard let info = try? fileSystem.fileInfo(path) else { return false }
            return info.size > 0
        case "-r", "-w", "-x": return fileSystem.exists(path)
        case "-L", "-h":
            return (try? fileSystem.readlink(path)) != nil
        case "-v":
            return session.getVariable(val) != nil
        default: return false
        }
    }

    private func evaluateBinaryTest(_ left: String, _ op: String, _ right: String) -> Bool {
        switch op {
        case "==", "=":
            return VirtualFileSystem.globMatch(name: left, pattern: right)
        case "!=":
            return !VirtualFileSystem.globMatch(name: left, pattern: right)
        case "<": return left < right
        case ">": return left > right
        case "-eq": return (Int(left) ?? 0) == (Int(right) ?? 0)
        case "-ne": return (Int(left) ?? 0) != (Int(right) ?? 0)
        case "-lt": return (Int(left) ?? 0) < (Int(right) ?? 0)
        case "-le": return (Int(left) ?? 0) <= (Int(right) ?? 0)
        case "-gt": return (Int(left) ?? 0) > (Int(right) ?? 0)
        case "-ge": return (Int(left) ?? 0) >= (Int(right) ?? 0)
        case "=~":
            guard let regex = try? NSRegularExpression(pattern: right) else { return false }
            return regex.firstMatch(in: left, range: NSRange(left.startIndex..., in: left)) != nil
        default: return false
        }
    }

    // MARK: - Arithmetic

    func evaluateArithmetic(_ expr: String, session: inout ShellSession) -> Int {
        let expanded = expandArithVariables(expr, session: session)
        return parseArithExpr(expanded, session: &session)
    }

    private func expandArithVariables(_ expr: String, session: ShellSession) -> String {
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
            } else if chars[i].isLetter || chars[i] == "_" {
                var name = ""
                while i < chars.count && (chars[i].isLetter || chars[i].isNumber || chars[i] == "_") {
                    name.append(chars[i]); i += 1
                }
                // Check if this is an operator keyword or a variable name in arithmetic context
                if ["le", "ge", "lt", "gt", "eq", "ne"].contains(name) {
                    result += name
                } else {
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
        enum Kind { case number(Int), op(String) }
        var kind: Kind
    }

    private func tokenizeArith(_ expr: String) -> [ArithToken] {
        var tokens: [ArithToken] = []
        let chars = Array(expr.trimmingCharacters(in: .whitespaces))
        var i = 0
        while i < chars.count {
            if chars[i].isWhitespace { i += 1; continue }
            if chars[i].isNumber || (chars[i] == "-" && (tokens.isEmpty || { if case .op = tokens.last?.kind { return true }; return false }())) {
                var numStr = ""
                if chars[i] == "-" { numStr.append("-"); i += 1 }
                // Hex
                if i < chars.count && chars[i] == "0" && i + 1 < chars.count && (chars[i + 1] == "x" || chars[i + 1] == "X") {
                    i += 2
                    while i < chars.count && chars[i].isHexDigit { numStr.append(chars[i]); i += 1 }
                    tokens.append(ArithToken(kind: .number(Int(numStr, radix: 16) ?? 0)))
                } else {
                    while i < chars.count && chars[i].isNumber { numStr.append(chars[i]); i += 1 }
                    tokens.append(ArithToken(kind: .number(Int(numStr) ?? 0)))
                }
            } else {
                // Two-char operators
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
                if op == "(" {
                    tokens.removeFirst()
                    let val = parseArithTernary(&tokens, session: &session)
                    if tokens.first.map({ if case .op(")") = $0.kind { return true }; return false }) == true {
                        tokens.removeFirst()
                    }
                    return val
                }
            }
            if case .number(let n) = tok.kind { tokens.removeFirst(); return n }
        }
        return 0
    }

    // MARK: - Word Expansion

    func expandWord(_ word: ShellWord, session: inout ShellSession, stdin: String) async throws -> String {
        var result = ""
        for part in word.parts {
            result += try await expandPart(part, session: &session, stdin: stdin)
        }
        return result
    }

    func expandWords(_ words: [ShellWord], session: inout ShellSession, stdin: String) async throws -> [String] {
        var result: [String] = []
        for word in words {
            let expanded = try await expandWord(word, session: &session, stdin: stdin)
            let fields: [String]
            if word.suppressesFieldSplitting {
                fields = [expanded]
            } else {
                let ifs = session.getVariable("IFS") ?? " \t\n"
                fields = splitByIFS(expanded, ifs: ifs)
            }

            for field in fields {
                if word.mayContainGlob && !session.options.noglob {
                    let matches = fileSystem.glob(field, relativeTo: session.cwd)
                    if matches.isEmpty {
                        result.append(field)
                    } else {
                        result.append(contentsOf: matches)
                    }
                } else {
                    result.append(field)
                }
            }
        }
        return result
    }

    private func expandPart(_ part: WordPart, session: inout ShellSession, stdin: String) async throws -> String {
        switch part {
        case .literal(let s):
            return s
        case .singleQuoted(let s):
            return s
        case .doubleQuoted(let parts):
            var result = ""
            for p in parts {
                result += try await expandPart(p, session: &session, stdin: stdin)
            }
            return result
        case .escapedChar(let c):
            return String(c)
        case .dollarSingleQuoted(let s):
            return s
        case .variable(let varRef):
            return try expandVariable(varRef, session: &session)
        case .commandSub(let script):
            return try await executeCommandSubstitution(script, session: &session, stdin: stdin)
        case .backtickSub(let script):
            return try await executeCommandSubstitution(script, session: &session, stdin: stdin)
        case .arithmeticSub(let expr):
            let value = evaluateArithmetic(expr, session: &session)
            return String(value)
        case .tilde(let user):
            if user.isEmpty {
                return session.getVariable("HOME") ?? "/home/user"
            }
            return "/home/\(user)"
        }
    }

    private func expandVariable(_ ref: VarRef, session: inout ShellSession) throws -> String {
        switch ref {
        case .named(let name):
            if let value = session.getVariable(name) {
                return value
            }
            if session.options.nounset {
                throw ShellRuntimeError.unboundVariable(name)
            }
            return ""
        case .special(let ch):
            return expandSpecialVar(ch, session: session)
        case .positional(let n):
            if n > 0 && n <= session.positionalParams.count {
                return session.positionalParams[n - 1]
            }
            if session.options.nounset {
                throw ShellRuntimeError.unboundVariable(String(n))
            }
            return ""
        case .length(let name):
            guard let val = session.getVariable(name) else {
                if session.options.nounset {
                    throw ShellRuntimeError.unboundVariable(name)
                }
                return "0"
            }
            return String(val.count)
        case .withOp(let name, let op):
            return try expandVarOp(name: name, op: op, session: &session)
        case .arrayElement(let name, _):
            // Simplified: treat as regular variable
            if let value = session.getVariable(name) {
                return value
            }
            if session.options.nounset {
                throw ShellRuntimeError.unboundVariable(name)
            }
            return ""
        case .arrayAll(let name, _):
            if let value = session.getVariable(name) {
                return value
            }
            if session.options.nounset {
                throw ShellRuntimeError.unboundVariable(name)
            }
            return ""
        }
    }

    private func expandSpecialVar(_ ch: Character, session: ShellSession) -> String {
        switch ch {
        case "?": return String(session.lastExitCode)
        case "#": return String(session.positionalParams.count)
        case "@", "*": return session.positionalParams.joined(separator: " ")
        case "$": return "1" // Virtual PID
        case "!": return "0"
        case "0": return session.shellName
        case "-": return session.options.flagString
        case "_": return ""
        default: return ""
        }
    }

    private func expandVarOp(name: String, op: VarOp, session: inout ShellSession) throws -> String {
        let value = session.getVariable(name)

        switch op {
        case .defaultValue(let word, let colonForm):
            let isEmpty = colonForm ? (value?.isEmpty ?? true) : (value == nil)
            if isEmpty {
                return expandWordParts(word, session: session)
            }
            return value ?? ""

        case .assignDefault(let word, let colonForm):
            let isEmpty = colonForm ? (value?.isEmpty ?? true) : (value == nil)
            if isEmpty {
                let def = expandWordParts(word, session: session)
                session.setVariable(name, def)
                return def
            }
            return value ?? ""

        case .errorIfUnset(let word, let colonForm):
            let isEmpty = colonForm ? (value?.isEmpty ?? true) : (value == nil)
            if isEmpty {
                _ = word.isEmpty ? "\(name): parameter null or not set" : expandWordParts(word, session: session)
                throw ControlFlow.exit(1)
            }
            return value ?? ""

        case .useAlternative(let word, let colonForm):
            let isEmpty = colonForm ? (value?.isEmpty ?? true) : (value == nil)
            if !isEmpty {
                return expandWordParts(word, session: session)
            }
            return ""

        case .removeSmallestPrefix(let pattern):
            guard let val = value else { return "" }
            return removePrefix(val, pattern: pattern, greedy: false)

        case .removeLargestPrefix(let pattern):
            guard let val = value else { return "" }
            return removePrefix(val, pattern: pattern, greedy: true)

        case .removeSmallestSuffix(let pattern):
            guard let val = value else { return "" }
            return removeSuffix(val, pattern: pattern, greedy: false)

        case .removeLargestSuffix(let pattern):
            guard let val = value else { return "" }
            return removeSuffix(val, pattern: pattern, greedy: true)

        case .replace(let pattern, let replacement, let all):
            guard let val = value else { return "" }
            return replacePattern(val, pattern: pattern, replacement: replacement, all: all)

        case .replacePrefix(let pattern, let replacement):
            guard let val = value else { return "" }
            for i in (0...val.count).reversed() {
                let prefix = String(val.prefix(i))
                if VirtualFileSystem.globMatch(name: prefix, pattern: pattern) {
                    return replacement + String(val.dropFirst(i))
                }
            }
            return val

        case .replaceSuffix(let pattern, let replacement):
            guard let val = value else { return "" }
            for i in 0...val.count {
                let suffix = String(val.suffix(i))
                if VirtualFileSystem.globMatch(name: suffix, pattern: pattern) {
                    return String(val.dropLast(i)) + replacement
                }
            }
            return val

        case .substring(let offsetStr, let lengthStr):
            guard let val = value else { return "" }
            let offset = Int(offsetStr.trimmingCharacters(in: .whitespaces)) ?? 0
            let startIdx = offset < 0 ? max(0, val.count + offset) : min(offset, val.count)
            if let lenStr = lengthStr {
                let length = Int(lenStr.trimmingCharacters(in: .whitespaces)) ?? val.count
                let endIdx = min(startIdx + max(0, length), val.count)
                let start = val.index(val.startIndex, offsetBy: startIdx)
                let end = val.index(val.startIndex, offsetBy: endIdx)
                return String(val[start..<end])
            }
            let start = val.index(val.startIndex, offsetBy: startIdx)
            return String(val[start...])

        case .uppercase(let all):
            guard let val = value else { return "" }
            if all { return val.uppercased() }
            if val.isEmpty { return val }
            return val.prefix(1).uppercased() + val.dropFirst()

        case .lowercase(let all):
            guard let val = value else { return "" }
            if all { return val.lowercased() }
            if val.isEmpty { return val }
            return val.prefix(1).lowercased() + val.dropFirst()
        }
    }

    private func expandWordParts(_ parts: [WordPart], session: ShellSession) -> String {
        var result = ""
        for part in parts {
            switch part {
            case .literal(let s): result += s
            case .singleQuoted(let s): result += s
            case .doubleQuoted(let inner): result += expandWordParts(inner, session: session)
            case .variable(let ref):
                switch ref {
                case .named(let n): result += session.getVariable(n) ?? ""
                case .special(let c): result += expandSpecialVar(c, session: session)
                case .positional(let n):
                    if n > 0 && n <= session.positionalParams.count { result += session.positionalParams[n - 1] }
                default: break
                }
            case .escapedChar(let c): result.append(c)
            default: break
            }
        }
        return result
    }

    // MARK: - Pattern matching helpers

    private func removePrefix(_ value: String, pattern: String, greedy: Bool) -> String {
        if greedy {
            for i in (0...value.count).reversed() {
                let prefix = String(value.prefix(i))
                if VirtualFileSystem.globMatch(name: prefix, pattern: pattern) {
                    return String(value.dropFirst(i))
                }
            }
        } else {
            for i in 0...value.count {
                let prefix = String(value.prefix(i))
                if VirtualFileSystem.globMatch(name: prefix, pattern: pattern) {
                    return String(value.dropFirst(i))
                }
            }
        }
        return value
    }

    private func removeSuffix(_ value: String, pattern: String, greedy: Bool) -> String {
        if greedy {
            for i in (0...value.count).reversed() {
                let suffix = String(value.suffix(value.count - i))
                if VirtualFileSystem.globMatch(name: suffix, pattern: pattern) {
                    return String(value.prefix(i))
                }
            }
        } else {
            for i in (0...value.count).reversed() {
                let suffix = String(value.suffix(value.count - i))
                if VirtualFileSystem.globMatch(name: suffix, pattern: pattern) {
                    return String(value.prefix(i))
                }
            }
        }
        return value
    }

    private func replacePattern(_ value: String, pattern: String, replacement: String, all: Bool) -> String {
        // Simple implementation: try to match pattern at each position
        var result = ""
        let chars = Array(value)
        var i = 0
        while i < chars.count {
            var matched = false
            // Try match from position i with increasing lengths
            for len in (1...(chars.count - i)).reversed() {
                let sub = String(chars[i..<(i + len)])
                if VirtualFileSystem.globMatch(name: sub, pattern: pattern) {
                    result += replacement
                    i += len
                    matched = true
                    if !all { result += String(chars[i...]); return result }
                    break
                }
            }
            if !matched {
                result.append(chars[i])
                i += 1
            }
        }
        return result
    }

    // MARK: - Command substitution

    private func executeCommandSubstitution(_ script: String, session: inout ShellSession, stdin: String) async throws -> String {
        guard session.callDepth < limits.maxSubstitutionDepth else {
            return ""
        }
        let parsed = try ShellParser(limits: limits).parse(script)
        var subSession = session
        subSession.callDepth += 1
        let result = try await executeScript(parsed, session: &subSession, stdin: stdin)
        session.lastExitCode = result.exitCode
        // Trim trailing newlines (bash behavior)
        var output = result.stdout
        while output.hasSuffix("\n") { output = String(output.dropLast()) }
        return output
    }

    // MARK: - Heredoc expansion

    private func expandHeredoc(_ body: String, session: inout ShellSession) async throws -> String {
        // Expand variables in heredoc body
        var result = ""
        let chars = Array(body)
        var i = 0
        while i < chars.count {
            if chars[i] == "$" {
                i += 1
                if i >= chars.count { result.append("$"); continue }
                if chars[i] == "{" {
                    i += 1
                    var name = ""
                    while i < chars.count && chars[i] != "}" { name.append(chars[i]); i += 1 }
                    if i < chars.count { i += 1 }
                    result += session.getVariable(name) ?? ""
                } else if chars[i].isLetter || chars[i] == "_" {
                    var name = ""
                    while i < chars.count && (chars[i].isLetter || chars[i].isNumber || chars[i] == "_") {
                        name.append(chars[i]); i += 1
                    }
                    result += session.getVariable(name) ?? ""
                } else if "?#@*$!0-".contains(chars[i]) {
                    result += expandSpecialVar(chars[i], session: session)
                    i += 1
                } else {
                    result.append("$")
                }
            } else if chars[i] == "\\" {
                i += 1
                if i < chars.count {
                    if "$`\"\\".contains(chars[i]) {
                        result.append(chars[i]); i += 1
                    } else {
                        result.append("\\"); result.append(chars[i]); i += 1
                    }
                } else {
                    result.append("\\")
                }
            } else {
                result.append(chars[i]); i += 1
            }
        }
        return result
    }

    // MARK: - Redirections

    private func applyRedirections(_ result: ExecResult, redirects: [Redirection], session: inout ShellSession, stdin: String) async throws -> ExecResult {
        return try await applyOutputRedirections(result, redirects: redirects, commandName: nil, session: &session, stdin: stdin)
    }

    private func applyOutputRedirections(
        _ result: ExecResult,
        redirects: [Redirection],
        commandName: String?,
        session: inout ShellSession,
        stdin: String
    ) async throws -> ExecResult {
        var stdout = result.stdout
        var stderr = result.stderr

        for redir in redirects {
            switch redir.op {
            case .output, .clobber:
                let target = try await expandWord(redir.target, session: &session, stdin: stdin)
                if case .output = redir.op,
                   session.options.noclobber,
                   fileSystem.exists(target, relativeTo: session.cwd) {
                    return ExecResult.failure("cannot overwrite existing file: \(target)")
                }
                if redir.effectiveFD == 1 {
                    try fileSystem.writeFile(stdout, to: target, relativeTo: session.cwd)
                    stdout = ""
                } else if redir.effectiveFD == 2 {
                    try fileSystem.writeFile(stderr, to: target, relativeTo: session.cwd)
                    stderr = ""
                }
            case .append:
                let target = try await expandWord(redir.target, session: &session, stdin: stdin)
                if redir.effectiveFD == 1 {
                    try fileSystem.writeFile(stdout, to: target, relativeTo: session.cwd, append: true)
                    stdout = ""
                } else if redir.effectiveFD == 2 {
                    try fileSystem.writeFile(stderr, to: target, relativeTo: session.cwd, append: true)
                    stderr = ""
                }
            case .duplicateOutput:
                let target = try await expandWord(redir.target, session: &session, stdin: stdin)
                if target == "1" && redir.fd == 2 {
                    stdout += stderr; stderr = ""
                } else if target == "2" && (redir.fd == nil || redir.fd == 1) {
                    stderr += stdout; stdout = ""
                }
            case .duplicateInput:
                break
            case .input, .inputOutput, .heredoc, .heredocStripTabs, .herestring:
                break // handled earlier in executeSimple
            }
        }

        return ExecResult(stdout: stdout, stderr: stderr, exitCode: result.exitCode)
    }

    private func enforceOutputLimit(_ result: ExecResult) -> ExecResult {
        let outputLength = result.stdout.utf8.count + result.stderr.utf8.count
        guard outputLength <= limits.maxOutputLength else {
            return ExecResult.failure("maximum output length exceeded", exitCode: 1)
        }
        return result
    }

    // MARK: - Shell Builtins

    typealias BuiltinFn = ([String], inout ShellSession, [String: String], String) async throws -> ExecResult

    func shellBuiltin(_ name: String) -> BuiltinFn? {
        switch name {
        case "cd": return builtinCd
        case "pwd": return builtinPwd
        case "echo": return builtinEcho
        case "printf": return builtinPrintf
        case "env": return builtinEnv
        case "printenv": return builtinPrintenv
        case "which", "type": return builtinWhich
        case "true": return { _, _, _, _ in ExecResult.success() }
        case "false": return { _, _, _, _ in ExecResult(stdout: "", stderr: "", exitCode: 1) }
        case "export": return builtinExport
        case "unset": return builtinUnset
        case "local": return builtinLocal
        case "declare", "typeset": return builtinDeclare
        case "read": return builtinRead
        case "set": return builtinSet
        case "shift": return builtinShift
        case "return": return builtinReturn
        case "exit": return builtinExit
        case "break": return builtinBreak
        case "continue": return builtinContinue
        case "test", "[": return builtinTest
        case "eval": return builtinEval
        case "source", ".": return builtinSource
        case "trap": return { _, _, _, _ in ExecResult.success() }
        case "alias": return builtinAlias
        case "unalias": return { args, session, _, _ in args.forEach { session.aliases.removeValue(forKey: $0) }; return .success() }
        case ":": return { _, _, _, _ in ExecResult.success() }
        case "command": return builtinCommand
        case "let": return builtinLet
        case "getopts": return builtinGetopts
        default: return nil
        }
    }

    // MARK: Builtin implementations

    private func builtinCd(_ args: [String], _ session: inout ShellSession, _ env: [String: String], _ stdin: String) async throws -> ExecResult {
        let dest: String
        if args.isEmpty || args[0] == "~" {
            dest = env["HOME"] ?? session.getVariable("HOME") ?? "/home/user"
        } else if args[0] == "-" {
            dest = session.getVariable("OLDPWD") ?? session.cwd
        } else {
            dest = args[0]
        }
        let target = VirtualPath.normalize(dest, relativeTo: session.cwd)
        guard fileSystem.isDirectory(target) else {
            return ExecResult.failure("cd: no such directory: \(dest)")
        }
        let old = session.cwd
        session.cwd = target
        session.setVariable("OLDPWD", old)
        session.setVariable("PWD", target)
        return ExecResult.success()
    }

    private func builtinPwd(_ args: [String], _ session: inout ShellSession, _ env: [String: String], _ stdin: String) async throws -> ExecResult {
        ExecResult.success(session.cwd + "\n")
    }

    private func builtinEcho(_ args: [String], _ session: inout ShellSession, _ env: [String: String], _ stdin: String) async throws -> ExecResult {
        var items = args
        var newline = true
        var interpretEscapes = false
        while let first = items.first {
            if first == "-n" { newline = false; items.removeFirst() }
            else if first == "-e" { interpretEscapes = true; items.removeFirst() }
            else if first == "-E" { interpretEscapes = false; items.removeFirst() }
            else if first == "-en" || first == "-ne" { newline = false; interpretEscapes = true; items.removeFirst() }
            else { break }
        }
        var output = items.joined(separator: " ")
        if interpretEscapes {
            output = interpretEscapeSequences(output)
        }
        if newline { output += "\n" }
        return ExecResult.success(output)
    }

    private func interpretEscapeSequences(_ s: String) -> String {
        var result = ""
        var chars = s.makeIterator()
        while let ch = chars.next() {
            if ch == "\\" {
                guard let next = chars.next() else { result.append("\\"); break }
                switch next {
                case "n": result.append("\n")
                case "t": result.append("\t")
                case "r": result.append("\r")
                case "\\": result.append("\\")
                case "a": result.append("\u{07}")
                case "b": result.append("\u{08}")
                case "e", "E": result.append("\u{1B}")
                case "0":
                    var oct = ""
                    for _ in 0..<3 { if let c = chars.next(), "01234567".contains(c) { oct.append(c) } }
                    if let val = UInt32(oct.isEmpty ? "0" : oct, radix: 8), let s = Unicode.Scalar(val) { result.append(Character(s)) }
                default: result.append("\\"); result.append(next)
                }
            } else {
                result.append(ch)
            }
        }
        return result
    }

    private func builtinPrintf(_ args: [String], _ session: inout ShellSession, _ env: [String: String], _ stdin: String) async throws -> ExecResult {
        guard let format = args.first else { return ExecResult.success() }
        var remaining = Array(args.dropFirst())
        var output = ""

        // Repeat format string while arguments remain
        repeat {
            var iter = format.makeIterator()
            var usedArg = false
            while let ch = iter.next() {
                if ch == "%" {
                    guard let spec = iter.next() else { output.append("%"); break }
                    switch spec {
                    case "%": output.append("%")
                    case "s": output += remaining.isEmpty ? "" : remaining.removeFirst(); usedArg = true
                    case "d", "i":
                        let arg = remaining.isEmpty ? "0" : remaining.removeFirst(); usedArg = true
                        output += String(Int(arg) ?? 0)
                    case "f":
                        let arg = remaining.isEmpty ? "0" : remaining.removeFirst(); usedArg = true
                        output += String(format: "%.6f", Double(arg) ?? 0.0)
                    case "x":
                        let arg = remaining.isEmpty ? "0" : remaining.removeFirst(); usedArg = true
                        output += String(Int(arg) ?? 0, radix: 16)
                    case "o":
                        let arg = remaining.isEmpty ? "0" : remaining.removeFirst(); usedArg = true
                        output += String(Int(arg) ?? 0, radix: 8)
                    case "c":
                        let arg = remaining.isEmpty ? "" : remaining.removeFirst(); usedArg = true
                        output += String(arg.prefix(1))
                    default:
                        output.append("%"); output.append(spec)
                    }
                } else if ch == "\\" {
                    guard let esc = iter.next() else { output.append("\\"); break }
                    switch esc {
                    case "n": output.append("\n")
                    case "t": output.append("\t")
                    case "r": output.append("\r")
                    case "\\": output.append("\\")
                    default: output.append("\\"); output.append(esc)
                    }
                } else {
                    output.append(ch)
                }
            }
            if !usedArg { break }
        } while !remaining.isEmpty

        return ExecResult.success(output)
    }

    private func builtinEnv(_ args: [String], _ session: inout ShellSession, _ env: [String: String], _ stdin: String) async throws -> ExecResult {
        let rendered = env.keys.sorted().map { "\($0)=\(env[$0] ?? "")" }.joined(separator: "\n")
        return ExecResult.success(rendered + (rendered.isEmpty ? "" : "\n"))
    }

    private func builtinPrintenv(_ args: [String], _ session: inout ShellSession, _ env: [String: String], _ stdin: String) async throws -> ExecResult {
        if args.isEmpty {
            return try await builtinEnv(args, &session, env, stdin)
        }
        let values = args.compactMap { env[$0] }
        if values.isEmpty { return ExecResult(stdout: "", stderr: "", exitCode: 1) }
        return ExecResult.success(values.joined(separator: "\n") + "\n")
    }

    private func builtinWhich(_ args: [String], _ session: inout ShellSession, _ env: [String: String], _ stdin: String) async throws -> ExecResult {
        var lines: [String] = []
        for arg in args {
            if shellBuiltin(arg) != nil || registry.contains(arg) || session.functions[arg] != nil {
                lines.append("/bin/\(arg)")
            }
        }
        return ExecResult(stdout: lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n"), stderr: "", exitCode: lines.count == args.count ? 0 : 1)
    }

    private func builtinExport(_ args: [String], _ session: inout ShellSession, _ env: [String: String], _ stdin: String) async throws -> ExecResult {
        if args.isEmpty {
            // Print all exported variables
            let lines = session.environment.keys.sorted().map { "declare -x \($0)=\"\(session.environment[$0] ?? "")\"" }
            return ExecResult.success(lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n"))
        }
        for arg in args {
            if arg == "-n" { continue }
            if let eq = arg.firstIndex(of: "=") {
                let name = String(arg[..<eq])
                let value = String(arg[arg.index(after: eq)...])
                session.setVariable(name, value)
                session.environment[name] = value
            } else if let val = session.getVariable(arg) {
                session.environment[arg] = val
            } else {
                session.environment[arg] = ""
            }
        }
        return ExecResult.success()
    }

    private func builtinUnset(_ args: [String], _ session: inout ShellSession, _ env: [String: String], _ stdin: String) async throws -> ExecResult {
        var names = args
        if names.first == "-v" || names.first == "-f" {
            let flag = names.removeFirst()
            if flag == "-f" {
                for name in names { session.functions.removeValue(forKey: name) }
                return ExecResult.success()
            }
        }
        for name in names { session.unsetVariable(name) }
        return ExecResult.success()
    }

    private func builtinLocal(_ args: [String], _ session: inout ShellSession, _ env: [String: String], _ stdin: String) async throws -> ExecResult {
        for arg in args {
            if let eq = arg.firstIndex(of: "=") {
                let name = String(arg[..<eq])
                let value = String(arg[arg.index(after: eq)...])
                session.declareLocal(name, value: value)
            } else {
                session.declareLocal(arg)
            }
        }
        return ExecResult.success()
    }

    private func builtinDeclare(_ args: [String], _ session: inout ShellSession, _ env: [String: String], _ stdin: String) async throws -> ExecResult {
        // Simplified declare - just handle variable assignment
        var isLocal = false
        var isExport = false
        var filtered: [String] = []
        for arg in args {
            if arg.hasPrefix("-") {
                if arg.contains("x") { isExport = true }
                // -g means global (opposite of local)
                if !arg.contains("g") { isLocal = true }
            } else {
                filtered.append(arg)
            }
        }
        for arg in filtered {
            if let eq = arg.firstIndex(of: "=") {
                let name = String(arg[..<eq])
                let value = String(arg[arg.index(after: eq)...])
                if isLocal {
                    session.declareLocal(name, value: value)
                } else {
                    session.setVariable(name, value)
                }
                if isExport { session.environment[name] = value }
            } else {
                if isLocal { session.declareLocal(arg) }
            }
        }
        return ExecResult.success()
    }

    private func builtinRead(_ args: [String], _ session: inout ShellSession, _ env: [String: String], _ stdin: String) async throws -> ExecResult {
        var delimiter = "\n"
        var varNames: [String] = []
        var i = 0
        while i < args.count {
            switch args[i] {
            case "-r": i += 1 // raw mode (no backslash processing)
            case "-p":
                i += 2 // skip prompt string (no interactive terminal)
            case "-d":
                i += 1; if i < args.count { delimiter = args[i]; i += 1 }
            case "-n", "-N", "-t", "-u":
                i += 2 // skip option and its argument
            default:
                varNames.append(args[i]); i += 1
            }
        }
        if varNames.isEmpty { varNames = ["REPLY"] }

        let input: String
        if let delimChar = delimiter.first {
            if let idx = stdin.firstIndex(of: delimChar) {
                input = String(stdin[..<idx])
            } else {
                input = stdin.trimmingCharacters(in: .newlines)
            }
        } else {
            input = stdin.trimmingCharacters(in: .newlines)
        }

        let ifs = session.getVariable("IFS") ?? " \t\n"
        let fields = splitByIFS(input, ifs: ifs)

        for (idx, name) in varNames.enumerated() {
            if idx == varNames.count - 1 {
                // Last variable gets remaining fields
                let remaining = fields.dropFirst(idx)
                session.setVariable(name, remaining.joined(separator: " "))
            } else if idx < fields.count {
                session.setVariable(name, fields[idx])
            } else {
                session.setVariable(name, "")
            }
        }

        return stdin.isEmpty ? ExecResult(stdout: "", stderr: "", exitCode: 1) : ExecResult.success()
    }

    private func splitByIFS(_ input: String, ifs: String) -> [String] {
        if ifs.isEmpty { return [input] }
        var fields: [String] = []
        var current = ""
        var inField = false
        for ch in input {
            if ifs.contains(ch) {
                if inField {
                    fields.append(current)
                    current = ""
                    inField = false
                }
            } else {
                current.append(ch)
                inField = true
            }
        }
        if inField { fields.append(current) }
        return fields
    }

    private func addXtraceIfNeeded(_ result: ExecResult, traceComponents: [String], session: ShellSession) -> ExecResult {
        guard session.options.xtrace, !traceComponents.isEmpty else { return result }
        let traceLine = "+ " + traceComponents.joined(separator: " ") + "\n"
        return ExecResult(stdout: result.stdout, stderr: traceLine + result.stderr, exitCode: result.exitCode)
    }

    private func parseAliasWords(_ aliasValue: String) throws -> [ShellWord] {
        let parsed = try ShellParser(limits: limits).parse(aliasValue)
        guard parsed.entries.count == 1,
              parsed.entries[0].andOr.rest.isEmpty else {
            return [ShellWord(literal: aliasValue)]
        }
        let pipeline = parsed.entries[0].andOr.first
        guard pipeline.commands.count == 1,
              case .simple(let simple) = pipeline.commands[0],
              simple.assignments.isEmpty,
              simple.redirections.isEmpty,
              !simple.words.isEmpty else {
            return [ShellWord(literal: aliasValue)]
        }
        return simple.words
    }

    private func builtinSet(_ args: [String], _ session: inout ShellSession, _ env: [String: String], _ stdin: String) async throws -> ExecResult {
        if args.isEmpty {
            // Print all variables
            let lines = session.environment.keys.sorted().map { "\($0)='\(session.environment[$0] ?? "")'" }
            return ExecResult.success(lines.joined(separator: "\n") + "\n")
        }
        if args[0] == "--" {
            session.positionalParams = Array(args.dropFirst())
            return ExecResult.success()
        }
        for arg in args {
            if arg.hasPrefix("-") {
                for ch in arg.dropFirst() {
                    switch ch {
                    case "e": session.options.errexit = true
                    case "u": session.options.nounset = true
                    case "x": session.options.xtrace = true
                    case "f": session.options.noglob = true
                    case "C": session.options.noclobber = true
                    case "o":
                        // Handled below
                        break
                    default: break
                    }
                }
            } else if arg.hasPrefix("+") {
                for ch in arg.dropFirst() {
                    switch ch {
                    case "e": session.options.errexit = false
                    case "u": session.options.nounset = false
                    case "x": session.options.xtrace = false
                    case "f": session.options.noglob = false
                    case "C": session.options.noclobber = false
                    default: break
                    }
                }
            }
        }
        // Handle set -o pipefail etc.
        var i = 0
        while i < args.count {
            if args[i] == "-o" && i + 1 < args.count {
                switch args[i + 1] {
                case "pipefail": session.options.pipefail = true
                case "errexit": session.options.errexit = true
                case "nounset": session.options.nounset = true
                case "xtrace": session.options.xtrace = true
                case "noglob": session.options.noglob = true
                case "noclobber": session.options.noclobber = true
                default: break
                }
                i += 2
            } else if args[i] == "+o" && i + 1 < args.count {
                switch args[i + 1] {
                case "pipefail": session.options.pipefail = false
                default: break
                }
                i += 2
            } else {
                i += 1
            }
        }
        return ExecResult.success()
    }

    private func builtinShift(_ args: [String], _ session: inout ShellSession, _ env: [String: String], _ stdin: String) async throws -> ExecResult {
        let n = args.first.flatMap(Int.init) ?? 1
        if n > session.positionalParams.count {
            return ExecResult.failure("shift: shift count out of range")
        }
        session.positionalParams = Array(session.positionalParams.dropFirst(n))
        return ExecResult.success()
    }

    private func builtinReturn(_ args: [String], _ session: inout ShellSession, _ env: [String: String], _ stdin: String) async throws -> ExecResult {
        let code = args.first.flatMap(Int.init) ?? session.lastExitCode
        throw ControlFlow.return(code)
    }

    private func builtinExit(_ args: [String], _ session: inout ShellSession, _ env: [String: String], _ stdin: String) async throws -> ExecResult {
        let code = args.first.flatMap(Int.init) ?? session.lastExitCode
        throw ControlFlow.exit(code)
    }

    private func builtinBreak(_ args: [String], _ session: inout ShellSession, _ env: [String: String], _ stdin: String) async throws -> ExecResult {
        let n = args.first.flatMap(Int.init) ?? 1
        throw ControlFlow.break(max(1, n))
    }

    private func builtinContinue(_ args: [String], _ session: inout ShellSession, _ env: [String: String], _ stdin: String) async throws -> ExecResult {
        let n = args.first.flatMap(Int.init) ?? 1
        throw ControlFlow.continue(max(1, n))
    }

    private func builtinTest(_ args: [String], _ session: inout ShellSession, _ env: [String: String], _ stdin: String) async throws -> ExecResult {
        var testArgs = args
        // Remove trailing ] if present (for [ command)
        if testArgs.last == "]" { testArgs.removeLast() }
        let result = evaluateTestExpr(&testArgs, session: session)
        return ExecResult(stdout: "", stderr: "", exitCode: result ? 0 : 1)
    }

    private func evaluateTestExpr(_ args: inout [String], session: ShellSession) -> Bool {
        if args.isEmpty { return false }
        if args.count == 1 { return !args[0].isEmpty }

        // Unary operators
        if args.count >= 2 && args[0].hasPrefix("-") {
            let op = args[0]
            let val = args[1]
            args = Array(args.dropFirst(2))
            let path = VirtualPath.normalize(val, relativeTo: session.cwd)
            switch op {
            case "-z": return val.isEmpty
            case "-n": return !val.isEmpty
            case "-e": return fileSystem.exists(path)
            case "-f": return fileSystem.exists(path) && !fileSystem.isDirectory(path)
            case "-d": return fileSystem.isDirectory(path)
            case "-s":
                guard let info = try? fileSystem.fileInfo(path) else { return false }
                return info.size > 0
            case "-r", "-w", "-x": return fileSystem.exists(path)
            case "-L", "-h": return (try? fileSystem.readlink(path)) != nil
            default: return false
            }
        }

        // Binary operators
        if args.count >= 3 {
            let left = args[0], op = args[1], right = args[2]
            args = Array(args.dropFirst(3))
            return evaluateBinaryTest(left, op, right)
        }

        return !args.removeFirst().isEmpty
    }

    private func builtinEval(_ args: [String], _ session: inout ShellSession, _ env: [String: String], _ stdin: String) async throws -> ExecResult {
        let script = args.joined(separator: " ")
        if script.isEmpty { return ExecResult.success() }
        do {
            let parsed = try ShellParser(limits: limits).parse(script)
            return try await executeScript(parsed, session: &session, stdin: stdin)
        } catch {
            return ExecResult(stdout: "", stderr: "eval: \(error.localizedDescription)\n", exitCode: 1)
        }
    }

    private func builtinSource(_ args: [String], _ session: inout ShellSession, _ env: [String: String], _ stdin: String) async throws -> ExecResult {
        guard let path = args.first else {
            return ExecResult.failure("source: filename argument required")
        }
        do {
            let content = try fileSystem.readFile(path, relativeTo: session.cwd)
            let parsed = try ShellParser(limits: limits).parse(content)
            return try await executeScript(parsed, session: &session, stdin: stdin)
        } catch {
            return ExecResult(stdout: "", stderr: "source: \(error.localizedDescription)\n", exitCode: 1)
        }
    }

    private func builtinAlias(_ args: [String], _ session: inout ShellSession, _ env: [String: String], _ stdin: String) async throws -> ExecResult {
        if args.isEmpty {
            let lines = session.aliases.keys.sorted().map { "alias \($0)='\(session.aliases[$0]!)'" }
            return ExecResult.success(lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n"))
        }
        for arg in args {
            if let eq = arg.firstIndex(of: "=") {
                let name = String(arg[..<eq])
                let rawValue = String(arg[arg.index(after: eq)...])
                let value = stripMatchingQuotes(rawValue)
                session.aliases[name] = value
            } else {
                if let val = session.aliases[arg] {
                    return ExecResult.success("alias \(arg)='\(val)'\n")
                }
                return ExecResult.failure("alias: \(arg): not found")
            }
        }
        return ExecResult.success()
    }

    private func stripMatchingQuotes(_ text: String) -> String {
        var result = text
        if result.count >= 2,
           ((result.hasPrefix("'") && result.hasSuffix("'")) || (result.hasPrefix("\"") && result.hasSuffix("\""))) {
            return String(result.dropFirst().dropLast())
        }
        if let first = result.first, first == "'" || first == "\"" {
            result.removeFirst()
        }
        if let last = result.last, last == "'" || last == "\"" {
            result.removeLast()
        }
        return result
    }

    private func builtinCommand(_ args: [String], _ session: inout ShellSession, _ env: [String: String], _ stdin: String) async throws -> ExecResult {
        var filteredArgs = args
        // Skip -v flag
        if filteredArgs.first == "-v" {
            filteredArgs.removeFirst()
            return try await builtinWhich(filteredArgs, &session, env, stdin)
        }
        guard let name = filteredArgs.first else { return ExecResult.success() }
        let cmdArgs = Array(filteredArgs.dropFirst())
        // Execute command, bypassing functions
        if let cmd = registry.command(named: name) {
            let ctx = CommandContext(fileSystem: fileSystem, cwd: session.cwd, environment: env, stdin: stdin)
            return await cmd.execute(cmdArgs, ctx)
        }
        if let builtin = shellBuiltin(name) {
            return try await builtin(cmdArgs, &session, env, stdin)
        }
        return ExecResult.failure("\(name): command not found", exitCode: 127)
    }

    private func builtinLet(_ args: [String], _ session: inout ShellSession, _ env: [String: String], _ stdin: String) async throws -> ExecResult {
        var lastVal = 0
        for arg in args {
            lastVal = evaluateArithmetic(arg, session: &session)
        }
        return ExecResult(stdout: "", stderr: "", exitCode: lastVal != 0 ? 0 : 1)
    }

    private func builtinGetopts(_ args: [String], _ session: inout ShellSession, _ env: [String: String], _ stdin: String) async throws -> ExecResult {
        guard args.count >= 2 else { return ExecResult(stdout: "", stderr: "", exitCode: 1) }
        let optstring = args[0]
        let varName = args[1]
        let optArgs = args.count > 2 ? Array(args.dropFirst(2)) : session.positionalParams
        let optind = Int(session.getVariable("OPTIND") ?? "1") ?? 1

        if optind > optArgs.count {
            session.setVariable(varName, "?")
            return ExecResult(stdout: "", stderr: "", exitCode: 1)
        }

        let arg = optArgs[optind - 1]
        guard arg.hasPrefix("-") && arg != "-" && arg != "--" else {
            session.setVariable(varName, "?")
            return ExecResult(stdout: "", stderr: "", exitCode: 1)
        }

        let opt = arg.dropFirst().first!
        session.setVariable(varName, String(opt))

        if let idx = optstring.firstIndex(of: opt) {
            let nextIdx = optstring.index(after: idx)
            if nextIdx < optstring.endIndex && optstring[nextIdx] == ":" {
                // Requires argument
                if arg.count > 2 {
                    session.setVariable("OPTARG", String(arg.dropFirst(2)))
                    session.setVariable("OPTIND", String(optind + 1))
                } else if optind < optArgs.count {
                    session.setVariable("OPTARG", optArgs[optind])
                    session.setVariable("OPTIND", String(optind + 2))
                } else {
                    session.setVariable(varName, ":")
                    session.setVariable("OPTIND", String(optind + 1))
                }
            } else {
                session.setVariable("OPTIND", String(optind + 1))
            }
        } else {
            session.setVariable(varName, "?")
            session.setVariable("OPTIND", String(optind + 1))
        }

        return ExecResult.success()
    }
}
