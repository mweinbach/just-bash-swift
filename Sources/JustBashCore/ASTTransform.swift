import Foundation

// MARK: - AST Transform Protocol

/// A plugin that transforms a bash AST.
///
/// Implement this protocol to create custom AST transformations. Transforms
/// can inspect, modify, or collect information from parsed bash scripts.
///
/// ## Built-in Transforms
///
/// - ``CommandCollector``: Collects all command names that a script would execute.
/// - ``ASTSerializer``: Serializes an AST back to bash source code.
///
/// ## Example
///
/// ```swift
/// struct LoggingTransform: ASTTransformPlugin {
///     var name: String { "logging" }
///
///     func transform(_ script: Script) -> Script {
///         // Wrap each command with a logging prefix
///         return script
///     }
/// }
/// ```
public protocol ASTTransformPlugin: Sendable {
    /// A unique name for this transform plugin.
    var name: String { get }

    /// Transforms a parsed script AST.
    ///
    /// - Parameter script: The input AST.
    /// - Returns: The transformed AST. Return the input unchanged for read-only transforms.
    func transform(_ script: Script) -> Script
}

// MARK: - AST Transform Pipeline

/// A pipeline that applies a sequence of AST transforms to a parsed script.
///
/// ```swift
/// let parser = ShellParser()
/// let script = try parser.parse("echo hello | grep h")
///
/// let pipeline = ASTTransformPipeline()
/// pipeline.add(CommandCollector())
/// let result = pipeline.run(script)
/// ```
public final class ASTTransformPipeline: @unchecked Sendable {
    private var plugins: [any ASTTransformPlugin] = []

    public init() {}

    /// Adds a transform plugin to the pipeline.
    public func add(_ plugin: any ASTTransformPlugin) {
        plugins.append(plugin)
    }

    /// Removes all plugins with the given name.
    public func remove(named name: String) {
        plugins.removeAll { $0.name == name }
    }

    /// Runs all plugins in order against the script.
    ///
    /// - Parameter script: The input AST.
    /// - Returns: The AST after all transforms have been applied.
    public func run(_ script: Script) -> Script {
        var current = script
        for plugin in plugins {
            current = plugin.transform(current)
        }
        return current
    }

    /// The names of all registered plugins, in order.
    public var pluginNames: [String] {
        plugins.map(\.name)
    }
}

// MARK: - Command Collector

/// A read-only transform that collects all command names a script would execute.
///
/// This is useful for AI agent sandboxing — you can parse a script and inspect
/// which commands it plans to run before executing it.
///
/// ```swift
/// let parser = ShellParser()
/// let script = try parser.parse("echo hello && ls -la | grep foo; curl http://example.com")
///
/// let collector = CommandCollector()
/// _ = collector.transform(script)
/// print(collector.commands) // ["echo", "ls", "grep", "curl"]
/// ```
public final class CommandCollector: ASTTransformPlugin, @unchecked Sendable {
    /// The collected command names, in order of appearance.
    public private(set) var commands: [String] = []

    /// Unique command names (deduplicated, preserving first-seen order).
    public var uniqueCommands: [String] {
        var seen = Set<String>()
        return commands.filter { seen.insert($0).inserted }
    }

    public let name = "command-collector"

    public init() {}

    /// Resets the collected commands.
    public func reset() {
        commands = []
    }

    public func transform(_ script: Script) -> Script {
        for entry in script.entries {
            collectFromAndOr(entry.andOr)
        }
        return script // read-only — returns unchanged
    }

    private func collectFromAndOr(_ andOr: AndOrList) {
        collectFromPipeline(andOr.first)
        for (_, pipeline) in andOr.rest {
            collectFromPipeline(pipeline)
        }
    }

    private func collectFromPipeline(_ pipeline: PipelineDef) {
        for command in pipeline.commands {
            collectFromCommand(command)
        }
    }

    private func collectFromCommand(_ command: Command) {
        switch command {
        case .simple(let simple):
            if let firstWord = simple.words.first, let name = firstWord.simpleLiteralText {
                commands.append(name)
            }
        case .compound(let compound, _):
            collectFromCompound(compound)
        case .functionDef(let funcDef):
            collectFromCommand(funcDef.body)
        }
    }

    private func collectFromCompound(_ compound: CompoundCommand) {
        switch compound {
        case .braceGroup(let script), .subshell(let script):
            for entry in script.entries {
                collectFromAndOr(entry.andOr)
            }
        case .ifClause(let ifClause):
            for (condition, body) in ifClause.conditions {
                for entry in condition.entries { collectFromAndOr(entry.andOr) }
                for entry in body.entries { collectFromAndOr(entry.andOr) }
            }
            if let elseBody = ifClause.elseBody {
                for entry in elseBody.entries { collectFromAndOr(entry.andOr) }
            }
        case .forClause(let forClause):
            for entry in forClause.body.entries { collectFromAndOr(entry.andOr) }
        case .forArithClause(let forArith):
            for entry in forArith.body.entries { collectFromAndOr(entry.andOr) }
        case .whileClause(let loop), .untilClause(let loop):
            for entry in loop.condition.entries { collectFromAndOr(entry.andOr) }
            for entry in loop.body.entries { collectFromAndOr(entry.andOr) }
        case .caseClause(let caseClause):
            for item in caseClause.items {
                if let body = item.body {
                    for entry in body.entries { collectFromAndOr(entry.andOr) }
                }
            }
        case .selectClause(let select):
            for entry in select.body.entries { collectFromAndOr(entry.andOr) }
        case .condCommand, .arithCommand:
            break // no sub-commands
        }
    }
}

// MARK: - AST Serializer

/// Serializes an AST back to bash source code.
///
/// This enables round-tripping: parse a script, transform it, then serialize
/// back to a string that can be executed.
///
/// ```swift
/// let parser = ShellParser()
/// let script = try parser.parse("echo hello | grep h")
/// let source = ASTSerializer.serialize(script)
/// // source == "echo hello | grep h"
/// ```
public struct ASTSerializer {

    /// Serializes a `Script` AST back to bash source code.
    public static func serialize(_ script: Script) -> String {
        script.entries.map { serializeEntry($0) }.joined(separator: "\n")
    }

    private static func serializeEntry(_ entry: ListEntry) -> String {
        var result = serializeAndOr(entry.andOr)
        if entry.isBackground { result += " &" }
        return result
    }

    private static func serializeAndOr(_ andOr: AndOrList) -> String {
        var result = serializePipeline(andOr.first)
        for (op, pipeline) in andOr.rest {
            switch op {
            case .and: result += " && "
            case .or: result += " || "
            }
            result += serializePipeline(pipeline)
        }
        return result
    }

    private static func serializePipeline(_ pipeline: PipelineDef) -> String {
        var result = ""
        if pipeline.negated { result += "! " }
        result += pipeline.commands.enumerated().map { index, cmd in
            let serialized = serializeCommand(cmd)
            if index > 0 {
                let pipeOp = (index - 1 < pipeline.pipeStandardError.count && pipeline.pipeStandardError[index - 1]) ? " |& " : " | "
                return pipeOp + serialized
            }
            return serialized
        }.joined()
        return result
    }

    private static func serializeCommand(_ command: Command) -> String {
        switch command {
        case .simple(let simple):
            return serializeSimple(simple)
        case .compound(let compound, let redirections):
            var result = serializeCompound(compound)
            for redir in redirections {
                result += " " + serializeRedirection(redir)
            }
            return result
        case .functionDef(let funcDef):
            return "\(funcDef.name)() " + serializeCommand(funcDef.body)
        }
    }

    private static func serializeSimple(_ simple: SimpleCommand) -> String {
        var parts: [String] = []
        for assignment in simple.assignments {
            var s = assignment.name
            s += assignment.append ? "+=" : "="
            if let arrayValues = assignment.arrayValues {
                s += "(" + arrayValues.map { $0.rawText }.joined(separator: " ") + ")"
            } else {
                s += assignment.value.rawText
            }
            parts.append(s)
        }
        for word in simple.words {
            parts.append(word.rawText)
        }
        for redir in simple.redirections {
            parts.append(serializeRedirection(redir))
        }
        return parts.joined(separator: " ")
    }

    private static func serializeCompound(_ compound: CompoundCommand) -> String {
        switch compound {
        case .braceGroup(let script):
            return "{ " + serialize(script) + "; }"
        case .subshell(let script):
            return "( " + serialize(script) + " )"
        case .ifClause(let ifClause):
            var result = ""
            for (index, (condition, body)) in ifClause.conditions.enumerated() {
                if index == 0 {
                    result += "if " + serialize(condition) + "; then " + serialize(body)
                } else {
                    result += "; elif " + serialize(condition) + "; then " + serialize(body)
                }
            }
            if let elseBody = ifClause.elseBody {
                result += "; else " + serialize(elseBody)
            }
            result += "; fi"
            return result
        case .forClause(let forClause):
            var result = "for \(forClause.variable)"
            if let words = forClause.words {
                result += " in " + words.map { $0.rawText }.joined(separator: " ")
            }
            result += "; do " + serialize(forClause.body) + "; done"
            return result
        case .forArithClause(let forArith):
            return "for (( \(forArith.initialize); \(forArith.condition); \(forArith.update) )); do " +
                serialize(forArith.body) + "; done"
        case .whileClause(let loop):
            return "while " + serialize(loop.condition) + "; do " + serialize(loop.body) + "; done"
        case .untilClause(let loop):
            return "until " + serialize(loop.condition) + "; do " + serialize(loop.body) + "; done"
        case .caseClause(let caseClause):
            var result = "case " + caseClause.word.rawText + " in"
            for item in caseClause.items {
                let patterns = item.patterns.map { $0.rawText }.joined(separator: " | ")
                result += " " + patterns + ")"
                if let body = item.body {
                    result += " " + serialize(body)
                }
                switch item.terminator {
                case .break_: result += ";;"
                case .fallthrough_: result += ";&"
                case .testNext: result += ";;&"
                }
            }
            result += " esac"
            return result
        case .selectClause(let select):
            var result = "select \(select.variable)"
            if let words = select.words {
                result += " in " + words.map { $0.rawText }.joined(separator: " ")
            }
            result += "; do " + serialize(select.body) + "; done"
            return result
        case .condCommand(let expr):
            return "[[ " + serializeCondExpr(expr) + " ]]"
        case .arithCommand(let expr):
            return "(( \(expr) ))"
        }
    }

    private static func serializeCondExpr(_ expr: CondExpr) -> String {
        switch expr {
        case .unary(let op, let word):
            return "\(op) \(word.rawText)"
        case .binary(let left, let op, let right):
            return "\(left.rawText) \(op) \(right.rawText)"
        case .and(let lhs, let rhs):
            return serializeCondExpr(lhs) + " && " + serializeCondExpr(rhs)
        case .or(let lhs, let rhs):
            return serializeCondExpr(lhs) + " || " + serializeCondExpr(rhs)
        case .not(let inner):
            return "! " + serializeCondExpr(inner)
        case .paren(let inner):
            return "( " + serializeCondExpr(inner) + " )"
        case .word(let word):
            return word.rawText
        }
    }

    private static func serializeRedirection(_ redir: Redirection) -> String {
        var result = ""
        if let fd = redir.fd { result += "\(fd)" }
        switch redir.op {
        case .output: result += ">"
        case .append: result += ">>"
        case .input: result += "<"
        case .inputOutput: result += "<>"
        case .duplicateOutput: result += ">&"
        case .duplicateInput: result += "<&"
        case .clobber: result += ">|"
        case .heredoc: result += "<<"
        case .heredocStripTabs: result += "<<-"
        case .herestring: result += "<<<"
        }
        result += redir.target.rawText
        return result
    }
}

// MARK: - AST Walker (Visitor)

/// A protocol for walking an AST without modifying it.
///
/// Implement the methods you care about; default implementations visit all children.
public protocol ASTVisitor {
    mutating func visitScript(_ script: Script)
    mutating func visitEntry(_ entry: ListEntry)
    mutating func visitAndOr(_ andOr: AndOrList)
    mutating func visitPipeline(_ pipeline: PipelineDef)
    mutating func visitCommand(_ command: Command)
    mutating func visitSimpleCommand(_ simple: SimpleCommand)
    mutating func visitCompound(_ compound: CompoundCommand)
    mutating func visitFunctionDef(_ funcDef: FunctionDef)
}

extension ASTVisitor {
    public mutating func visitScript(_ script: Script) {
        for entry in script.entries { visitEntry(entry) }
    }

    public mutating func visitEntry(_ entry: ListEntry) {
        visitAndOr(entry.andOr)
    }

    public mutating func visitAndOr(_ andOr: AndOrList) {
        visitPipeline(andOr.first)
        for (_, pipeline) in andOr.rest { visitPipeline(pipeline) }
    }

    public mutating func visitPipeline(_ pipeline: PipelineDef) {
        for command in pipeline.commands { visitCommand(command) }
    }

    public mutating func visitCommand(_ command: Command) {
        switch command {
        case .simple(let simple): visitSimpleCommand(simple)
        case .compound(let compound, _): visitCompound(compound)
        case .functionDef(let funcDef): visitFunctionDef(funcDef)
        }
    }

    public mutating func visitSimpleCommand(_ simple: SimpleCommand) {}

    public mutating func visitCompound(_ compound: CompoundCommand) {
        switch compound {
        case .braceGroup(let script), .subshell(let script):
            visitScript(script)
        case .ifClause(let ifClause):
            for (cond, body) in ifClause.conditions {
                visitScript(cond)
                visitScript(body)
            }
            if let elseBody = ifClause.elseBody { visitScript(elseBody) }
        case .forClause(let f):
            visitScript(f.body)
        case .forArithClause(let f):
            visitScript(f.body)
        case .whileClause(let loop), .untilClause(let loop):
            visitScript(loop.condition)
            visitScript(loop.body)
        case .caseClause(let c):
            for item in c.items {
                if let body = item.body { visitScript(body) }
            }
        case .selectClause(let s):
            visitScript(s.body)
        case .condCommand, .arithCommand:
            break
        }
    }

    public mutating func visitFunctionDef(_ funcDef: FunctionDef) {
        visitCommand(funcDef.body)
    }
}
