import Foundation
import JustBashCommands
import JustBashFS

public final class ShellInterpreter: @unchecked Sendable {
    let fileSystem: VirtualFileSystem
    let registry: CommandRegistry
    let limits: ExecutionLimits
    let allowedURLPrefixes: [String]

    public init(fileSystem: VirtualFileSystem, registry: CommandRegistry, limits: ExecutionLimits, allowedURLPrefixes: [String] = []) {
        self.fileSystem = fileSystem
        self.registry = registry
        self.limits = limits
        self.allowedURLPrefixes = allowedURLPrefixes
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

    func executeScript(_ script: Script, session: inout ShellSession, stdin: String) async throws -> ExecResult {
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
        // set -v (verbose): echo each command to stderr before execution
        if session.options.verbose {
            let source = ASTSerializer.serialize(Script([entry]))
            var result = try await executeAndOr(entry.andOr, session: &session, stdin: stdin)
            result.stderr = source + "\n" + result.stderr
            return result
        }
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

        session.setArray("PIPESTATUS", pipelineExitCodes.map(String.init))

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
        if session.options.expandAliases,
           let aliasName = cmd.words.first?.simpleLiteralText,
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
            if let arrayValues = assignment.arrayValues {
                let expandedValues = try await expandWords(arrayValues, session: &session, stdin: stdin)
                if cmd.words.isEmpty {
                    if session.readonlyVariables.contains(assignment.name) {
                        return ExecResult.failure("bash: \(assignment.name): readonly variable")
                    }
                    session.setArray(assignment.name, expandedValues)
                    environment[assignment.name] = expandedValues.first
                } else {
                    environment[assignment.name] = expandedValues.first
                }
                continue
            }

            let value = try await expandWord(assignment.value, session: &session, stdin: stdin)
            if let (arrayName, key) = parseArrayElementAssignmentTarget(assignment.name) {
                if cmd.words.isEmpty {
                    if session.readonlyVariables.contains(arrayName) {
                        return ExecResult.failure("bash: \(arrayName): readonly variable")
                    }
                    if let index = Int(key) {
                        session.setArrayElement(arrayName, index: index, value: value)
                        environment[arrayName] = session.getArray(arrayName)?.first
                    } else {
                        session.setAssociativeElement(arrayName, key: key, value: value)
                        environment[arrayName] = session.getAssociativeArray(arrayName)?.values.sorted().first
                    }
                } else {
                    environment[arrayName] = value
                }
            } else if cmd.words.isEmpty {
                // Bare assignments persist in session
                if session.readonlyVariables.contains(assignment.name) {
                    return ExecResult.failure("bash: \(assignment.name): readonly variable")
                }
                if assignment.append {
                    let existing = session.getVariable(assignment.name) ?? ""
                    session.setVariable(assignment.name, existing + value)
                } else {
                    var finalValue = value
                    if session.integerVariables.contains(assignment.name) {
                        finalValue = String(evaluateArithmetic(value, session: &session))
                    }
                    session.setVariable(assignment.name, finalValue)
                }
                environment[assignment.name] = session.getVariable(assignment.name)
                // set -a (allexport): ensure variable is also in the global environment
                if session.options.allexport {
                    session.environment[assignment.name] = session.getVariable(assignment.name) ?? ""
                }
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
        if let funcBody = session.functions[commandName] {
            result = try await executeFunction(funcBody, name: commandName, arguments: arguments, session: &session, stdin: effectiveStdin)
        } else if let builtin = shellBuiltin(commandName) {
            result = try await builtin(arguments, &session, environment, effectiveStdin)
        } else if let command = registry.command(named: commandName) {
            let capturedSession = session
            let subshellExec: SubshellExecutor = { [self] script in
                var subSession = capturedSession
                return await self.execute(script: (try? ShellParser(limits: self.limits).parse(script)) ?? Script(), session: &subSession, stdin: "")
            }
            let context = CommandContext(fileSystem: fileSystem, cwd: session.cwd, environment: environment, stdin: effectiveStdin, executeSubshell: subshellExec, allowedURLPrefixes: allowedURLPrefixes)
            result = await command.execute(arguments, context)
        } else {
            result = ExecResult.failure("\(commandName): command not found", exitCode: 127)
        }

        session.lastExitCode = result.exitCode

        // Store last argument as $_
        if let lastArg = expandedWords.last {
            session.setVariable("_", lastArg)
        }

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
        case .selectClause(let clause):
            return try await executeSelect(clause, session: &session, stdin: stdin)
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

    private func executeSelect(_ clause: SelectClause, session: inout ShellSession, stdin: String) async throws -> ExecResult {
        let items: [String]
        if let words = clause.words {
            items = try await expandWords(words, session: &session, stdin: stdin)
        } else {
            items = session.positionalParams
        }
        guard !items.isEmpty else { return ExecResult.success() }

        // Build the numbered menu output
        var menu = ""
        for (i, item) in items.enumerated() {
            menu += "\(i + 1)) \(item)\n"
        }

        // In a sandboxed shell without interactive input, select the first option and execute once
        session.setVariable(clause.variable, items[0])
        session.setVariable("REPLY", "1")
        var combined = ExecResult()
        combined.stderr += menu
        do {
            let result = try await executeScript(clause.body, session: &session, stdin: stdin)
            combined.stdout += result.stdout
            combined.stderr += result.stderr
            combined.exitCode = result.exitCode
        } catch ControlFlow.break(let n) {
            if n > 1 { throw ControlFlow.break(n - 1) }
        } catch ControlFlow.continue(let n) {
            if n > 1 { throw ControlFlow.continue(n - 1) }
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
                    if VirtualFileSystem.globMatch(name: word, pattern: patternStr, extglob: session.options.extglob) || patternStr == "*" {
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

    private func executeFunction(_ body: Command, name functionName: String = "", arguments: [String], session: inout ShellSession, stdin: String) async throws -> ExecResult {
        guard session.callDepth < limits.maxCallDepth else {
            return ExecResult.failure("maximum call depth exceeded", exitCode: 1)
        }
        let savedParams = session.positionalParams
        let savedDepth = session.callDepth
        session.positionalParams = arguments
        session.callDepth += 1
        session.pushScope()
        session.functionCallStack.append(functionName)

        defer {
            session.functionCallStack.removeLast()
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
            return evaluateBinaryTest(l, op, r, session: session)

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

    func evaluateBinaryTest(_ left: String, _ op: String, _ right: String, session: ShellSession? = nil) -> Bool {
        let extglob = session?.options.extglob ?? false
        switch op {
        case "==", "=":
            return VirtualFileSystem.globMatch(name: left, pattern: right, extglob: extglob)
        case "!=":
            return !VirtualFileSystem.globMatch(name: left, pattern: right, extglob: extglob)
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
        case "-nt":
            // Newer than: in VFS, no timestamps. If both exist, same age (false).
            // If left exists and right doesn't, true.
            let cwd = session?.cwd ?? "/"
            let leftPath = VirtualPath.normalize(left, relativeTo: cwd)
            let rightPath = VirtualPath.normalize(right, relativeTo: cwd)
            let leftExists = fileSystem.exists(leftPath)
            let rightExists = fileSystem.exists(rightPath)
            if leftExists && !rightExists { return true }
            return false
        case "-ot":
            // Older than: opposite of -nt.
            let cwd = session?.cwd ?? "/"
            let leftPath = VirtualPath.normalize(left, relativeTo: cwd)
            let rightPath = VirtualPath.normalize(right, relativeTo: cwd)
            let leftExists = fileSystem.exists(leftPath)
            let rightExists = fileSystem.exists(rightPath)
            if !leftExists && rightExists { return true }
            return false
        case "-ef":
            // Same file: compare normalized paths.
            let cwd = session?.cwd ?? "/"
            let leftPath = VirtualPath.normalize(left, relativeTo: cwd)
            let rightPath = VirtualPath.normalize(right, relativeTo: cwd)
            return leftPath == rightPath
        default: return false
        }
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
        wordLoop: for word in words.flatMap(braceExpand) {
            // Handle quoted "${arr[@]}" — each element becomes a separate word
            for part in word.parts {
                if case .doubleQuoted(let innerParts) = part {
                    if innerParts.count == 1, case .variable(let ref) = innerParts[0] {
                        if case .arrayAll(let name, let allElements) = ref, allElements {
                            let arr = session.getArray(name) ?? []
                            result.append(contentsOf: arr)
                            continue wordLoop
                        }
                    }
                }
            }
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
                    let matches = fileSystem.glob(field, relativeTo: session.cwd, dotglob: session.options.dotglob, extglob: session.options.extglob)
                    if matches.isEmpty {
                        if !session.options.nullglob {
                            result.append(field)
                        }
                        // nullglob: drop the pattern entirely when no matches
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

    private func braceExpand(_ word: ShellWord) -> [ShellWord] {
        let expandedParts = word.parts.reduce([[WordPart]]([[]])) { partials, part in
            let partExpansions: [WordPart]
            if case .literal(let text) = part {
                partExpansions = braceExpandLiteral(text).map(WordPart.literal)
            } else {
                partExpansions = [part]
            }
            return partials.flatMap { partial in
                partExpansions.map { partial + [$0] }
            }
        }
        return expandedParts.map(ShellWord.init)
    }

    private func braceExpandLiteral(_ text: String) -> [String] {
        let chars = Array(text)
        var index = 0
        while index < chars.count {
            guard chars[index] == "{" else {
                index += 1
                continue
            }
            guard let end = matchingBrace(in: chars, from: index) else {
                index += 1
                continue
            }
            let prefix = String(chars[..<index])
            let body = String(chars[(index + 1)..<end])
            let suffix = String(chars[(end + 1)...])
            let replacements = parseBraceAlternatives(body)
            if replacements.isEmpty {
                index += 1
                continue
            }
            return replacements.flatMap { replacement in
                braceExpandLiteral(prefix + replacement + suffix)
            }
        }
        return [text]
    }

    private func matchingBrace(in chars: [Character], from start: Int) -> Int? {
        var depth = 0
        var index = start
        while index < chars.count {
            if chars[index] == "{" {
                depth += 1
            } else if chars[index] == "}" {
                depth -= 1
                if depth == 0 {
                    return index
                }
            }
            index += 1
        }
        return nil
    }

    private func parseBraceAlternatives(_ body: String) -> [String] {
        if let alternatives = splitTopLevelComma(body), !alternatives.isEmpty {
            return alternatives
        }
        if let sequence = parseBraceSequence(body) {
            return sequence
        }
        return []
    }

    private func splitTopLevelComma(_ body: String) -> [String]? {
        var depth = 0
        var current = ""
        var parts: [String] = []
        var sawComma = false

        for ch in body {
            switch ch {
            case "{":
                depth += 1
                current.append(ch)
            case "}":
                depth -= 1
                current.append(ch)
            case "," where depth == 0:
                parts.append(current)
                current = ""
                sawComma = true
            default:
                current.append(ch)
            }
        }

        guard sawComma else { return nil }
        parts.append(current)
        return parts
    }

    private func parseBraceSequence(_ body: String) -> [String]? {
        let parts = body.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 5 || parts.count == 3 else { return nil }
        guard parts[1].isEmpty else { return nil }
        if parts.count == 5, !parts[3].isEmpty { return nil }

        let start = parts[0]
        let end = parts[2]
        let stepText = parts.count == 5 ? parts[4] : nil

        let maxBraceExpansion = 10_000

        if let startInt = Int(start), let endInt = Int(end) {
            let step = Int(stepText ?? "") ?? (startInt <= endInt ? 1 : -1)
            guard step != 0 else { return nil }
            let count = step > 0 ? (endInt >= startInt ? (endInt - startInt) / step + 1 : 0)
                                 : (startInt >= endInt ? (startInt - endInt) / (-step) + 1 : 0)
            guard count <= maxBraceExpansion else { return nil }
            var values: [String] = []
            var current = startInt
            if step > 0 {
                while current <= endInt {
                    values.append(String(current))
                    current += step
                }
            } else {
                while current >= endInt {
                    values.append(String(current))
                    current += step
                }
            }
            return values
        }

        guard start.count == 1, end.count == 1,
              let startScalar = start.unicodeScalars.first,
              let endScalar = end.unicodeScalars.first else {
            return nil
        }

        let step = Int(stepText ?? "") ?? (startScalar.value <= endScalar.value ? 1 : -1)
        guard step != 0 else { return nil }
        let startVal = Int(startScalar.value)
        let targetVal = Int(endScalar.value)
        let alphaCount = step > 0 ? (targetVal >= startVal ? (targetVal - startVal) / step + 1 : 0)
                                  : (startVal >= targetVal ? (startVal - targetVal) / (-step) + 1 : 0)
        guard alphaCount <= maxBraceExpansion else { return nil }
        var values: [String] = []
        var current = startVal
        if step > 0 {
            while current <= targetVal {
                values.append(String(UnicodeScalar(current)!))
                current += step
            }
        } else {
            while current >= targetVal {
                values.append(String(UnicodeScalar(current)!))
                current += step
            }
        }
        return values
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
            return try await expandVariable(varRef, session: &session, stdin: stdin)
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
        case .processSubstitution(let script, let isInput):
            let tempPath = "/tmp/.proc_sub_\(UUID().uuidString.prefix(8))"
            if isInput {
                let parsed = try ShellParser(limits: limits).parse(script)
                var subSession = session
                subSession.callDepth += 1
                let execResult = try await executeScript(parsed, session: &subSession, stdin: stdin)
                try? fileSystem.writeFile(execResult.stdout, to: tempPath)
            } else {
                try? fileSystem.writeFile("", to: tempPath)
            }
            return tempPath
        }
    }

    private func expandVariable(_ ref: VarRef, session: inout ShellSession, stdin: String) async throws -> String {
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
            if let values = session.getArray(name) {
                return String(values.count)
            }
            if let values = session.getAssociativeArray(name) {
                return String(values.count)
            }
            guard let val = session.getVariable(name) else {
                if session.options.nounset {
                    throw ShellRuntimeError.unboundVariable(name)
                }
                return "0"
            }
            return String(val.count)
        case .withOp(let name, let op):
            return try expandVarOp(name: name, op: op, session: &session)
        case .arrayElement(let name, let indexWord):
            let key = try await expandWord(indexWord, session: &session, stdin: stdin).trimmingCharacters(in: .whitespacesAndNewlines)
            if let index = Int(key), let value = session.getArrayElement(name, index: index) {
                return value
            }
            if let value = session.getAssociativeElement(name, key: key) {
                return value
            }
            if session.options.nounset {
                throw ShellRuntimeError.unboundVariable("\(name)[\(key)]")
            }
            return ""
        case .arrayAll(let name, let allTypeAt):
            if let values = session.getArray(name) {
                let separator = allTypeAt ? " " : (session.getVariable("IFS") ?? " \t\n")
                return values.joined(separator: separator)
            }
            if let values = session.getAssociativeArray(name) {
                let separator = allTypeAt ? " " : (session.getVariable("IFS") ?? " \t\n")
                return values.keys.sorted().compactMap { values[$0] }.joined(separator: separator)
            }
            if session.options.nounset {
                throw ShellRuntimeError.unboundVariable(name)
            }
            return ""
        case .indirect(let name):
            let intermediateValue = session.getVariable(name) ?? ""
            return session.getVariable(intermediateValue) ?? ""
        case .namesByPrefix(let prefix, _):
            let names = session.environment.keys.filter { $0.hasPrefix(prefix) }.sorted()
            return names.joined(separator: " ")
        case .arrayKeys(let name, _):
            if let arr = session.getArray(name) {
                return (0..<arr.count).map(String.init).joined(separator: " ")
            }
            if let assoc = session.getAssociativeArray(name) {
                return assoc.keys.sorted().joined(separator: " ")
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
            return removePrefix(val, pattern: pattern, greedy: false, extglob: session.options.extglob)

        case .removeLargestPrefix(let pattern):
            guard let val = value else { return "" }
            return removePrefix(val, pattern: pattern, greedy: true, extglob: session.options.extglob)

        case .removeSmallestSuffix(let pattern):
            guard let val = value else { return "" }
            return removeSuffix(val, pattern: pattern, greedy: false, extglob: session.options.extglob)

        case .removeLargestSuffix(let pattern):
            guard let val = value else { return "" }
            return removeSuffix(val, pattern: pattern, greedy: true, extglob: session.options.extglob)

        case .replace(let pattern, let replacement, let all):
            guard let val = value else { return "" }
            return replacePattern(val, pattern: pattern, replacement: replacement, all: all, extglob: session.options.extglob)

        case .replacePrefix(let pattern, let replacement):
            guard let val = value else { return "" }
            let ext = session.options.extglob
            for i in (0...val.count).reversed() {
                let prefix = String(val.prefix(i))
                if VirtualFileSystem.globMatch(name: prefix, pattern: pattern, extglob: ext) {
                    return replacement + String(val.dropFirst(i))
                }
            }
            return val

        case .replaceSuffix(let pattern, let replacement):
            guard let val = value else { return "" }
            let ext = session.options.extglob
            for i in 0...val.count {
                let suffix = String(val.suffix(i))
                if VirtualFileSystem.globMatch(name: suffix, pattern: pattern, extglob: ext) {
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

        case .transform(let op):
            guard let val = value else { return "" }
            switch op {
            case .quote:
                return "'\(val.replacingOccurrences(of: "'", with: "'\\''"))'"
            case .escape:
                return val.map { ch in
                    "\\\"'$ \t\n".contains(ch) ? "\\\(ch)" : String(ch)
                }.joined()
            case .assign:
                return "declare -- \(name)=\"\(val)\""
            case .attributes:
                return ""  // simplified — no attribute tracking
            case .prompt:
                return val  // simplified — no prompt expansion
            }
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

    private func removePrefix(_ value: String, pattern: String, greedy: Bool, extglob: Bool = false) -> String {
        if greedy {
            for i in (0...value.count).reversed() {
                let prefix = String(value.prefix(i))
                if VirtualFileSystem.globMatch(name: prefix, pattern: pattern, extglob: extglob) {
                    return String(value.dropFirst(i))
                }
            }
        } else {
            for i in 0...value.count {
                let prefix = String(value.prefix(i))
                if VirtualFileSystem.globMatch(name: prefix, pattern: pattern, extglob: extglob) {
                    return String(value.dropFirst(i))
                }
            }
        }
        return value
    }

    private func removeSuffix(_ value: String, pattern: String, greedy: Bool, extglob: Bool = false) -> String {
        if greedy {
            for i in 0...value.count {
                let suffix = String(value.suffix(value.count - i))
                if VirtualFileSystem.globMatch(name: suffix, pattern: pattern, extglob: extglob) {
                    return String(value.prefix(i))
                }
            }
        } else {
            for i in (0...value.count).reversed() {
                let suffix = String(value.suffix(value.count - i))
                if VirtualFileSystem.globMatch(name: suffix, pattern: pattern, extglob: extglob) {
                    return String(value.prefix(i))
                }
            }
        }
        return value
    }

    private func replacePattern(_ value: String, pattern: String, replacement: String, all: Bool, extglob: Bool = false) -> String {
        // Simple implementation: try to match pattern at each position
        var result = ""
        let chars = Array(value)
        var i = 0
        while i < chars.count {
            var matched = false
            // Try match from position i with increasing lengths
            for len in (1...(chars.count - i)).reversed() {
                let sub = String(chars[i..<(i + len)])
                if VirtualFileSystem.globMatch(name: sub, pattern: pattern, extglob: extglob) {
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

        // Handle $(< file) shorthand — equivalent to $(cat file)
        let trimmed = script.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("<") {
            let rest = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty && !rest.contains(" ") && !rest.contains("|") && !rest.contains(";") {
                let path = VirtualPath.normalize(rest, relativeTo: session.cwd)
                if let content = try? fileSystem.readFile(path) {
                    var output = content
                    while output.hasSuffix("\n") { output = String(output.dropLast()) }
                    return output
                }
            }
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
                } else {
                    // Stub: for fd > 2 (e.g. exec 3>file), just create the file
                    try fileSystem.writeFile("", to: target, relativeTo: session.cwd)
                }
            case .append:
                let target = try await expandWord(redir.target, session: &session, stdin: stdin)
                if redir.effectiveFD == 1 {
                    try fileSystem.writeFile(stdout, to: target, relativeTo: session.cwd, append: true)
                    stdout = ""
                } else if redir.effectiveFD == 2 {
                    try fileSystem.writeFile(stderr, to: target, relativeTo: session.cwd, append: true)
                    stderr = ""
                } else {
                    // Stub: for fd > 2, just create/touch the file
                    try fileSystem.writeFile("", to: target, relativeTo: session.cwd, append: true)
                }
            case .duplicateOutput:
                let target = try await expandWord(redir.target, session: &session, stdin: stdin)
                if target == "1" && redir.fd == 2 {
                    stdout += stderr; stderr = ""
                } else if target == "2" && (redir.fd == nil || redir.fd == 1) {
                    stderr += stdout; stdout = ""
                }
                // fd > 2 duplicate targets are silently accepted
            case .duplicateInput:
                break // silently accept all fd duplicate inputs
            case .input:
                // For fd > 2 (e.g. exec 3<file), silently accept if not fd 0
                // fd 0 input is handled earlier in executeSimple
                break
            case .inputOutput:
                if redir.effectiveFD > 2 {
                    // Stub: for fd > 2 (e.g. exec 3<>file), just create the file if it doesn't exist
                    let target = try await expandWord(redir.target, session: &session, stdin: stdin)
                    if !fileSystem.exists(target, relativeTo: session.cwd) {
                        try fileSystem.writeFile("", to: target, relativeTo: session.cwd)
                    }
                }
            case .heredoc, .heredocStripTabs, .herestring:
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

    // MARK: - Shared Helpers

    func splitByIFS(_ input: String, ifs: String) -> [String] {
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

    func addXtraceIfNeeded(_ result: ExecResult, traceComponents: [String], session: ShellSession) -> ExecResult {
        guard session.options.xtrace, !traceComponents.isEmpty else { return result }
        let traceLine = "+ " + traceComponents.joined(separator: " ") + "\n"
        return ExecResult(stdout: result.stdout, stderr: traceLine + result.stderr, exitCode: result.exitCode)
    }

    func parseArrayElementAssignmentTarget(_ name: String) -> (String, String)? {
        guard let bracket = name.firstIndex(of: "["),
              name.hasSuffix("]") else {
            return nil
        }
        let base = String(name[..<bracket])
        let start = name.index(after: bracket)
        let end = name.index(before: name.endIndex)
        let indexText = String(name[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty, !indexText.isEmpty else {
            return nil
        }
        return (base, indexText)
    }
}
