import Foundation
import JustBashFS

// MARK: - Execution Limits

public struct ExecutionLimits: Sendable, Equatable {
    public var maxInputLength: Int
    public var maxTokenCount: Int
    public var maxCommandCount: Int
    public var maxOutputLength: Int
    public var maxPipelineLength: Int
    public var maxCallDepth: Int
    public var maxLoopIterations: Int
    public var maxSubstitutionDepth: Int

    public init(
        maxInputLength: Int = 256_000,
        maxTokenCount: Int = 16_000,
        maxCommandCount: Int = 10_000,
        maxOutputLength: Int = 1_048_576,
        maxPipelineLength: Int = 32,
        maxCallDepth: Int = 100,
        maxLoopIterations: Int = 10_000,
        maxSubstitutionDepth: Int = 50
    ) {
        self.maxInputLength = maxInputLength
        self.maxTokenCount = maxTokenCount
        self.maxCommandCount = maxCommandCount
        self.maxOutputLength = maxOutputLength
        self.maxPipelineLength = maxPipelineLength
        self.maxCallDepth = maxCallDepth
        self.maxLoopIterations = maxLoopIterations
        self.maxSubstitutionDepth = maxSubstitutionDepth
    }
}

// MARK: - Shell Word

/// A word composed of parts that are expanded at runtime
public struct ShellWord: Sendable {
    public var parts: [WordPart]

    public init(_ parts: [WordPart]) { self.parts = parts }
    public init(literal text: String) { self.parts = [.literal(text)] }
    public static let empty = ShellWord([])

    public var isEmpty: Bool { parts.isEmpty }

    /// Raw text without expansion (for display/debugging)
    public var rawText: String {
        parts.map { $0.rawText }.joined()
    }

    /// Whether any part is an unquoted glob character
    public var mayContainGlob: Bool {
        parts.contains { part in
            if case .literal(let s) = part {
                return s.contains("*") || s.contains("?") || s.contains("[")
            }
            return false
        }
    }

    public var suppressesFieldSplitting: Bool {
        parts.contains { part in
            switch part {
            case .singleQuoted, .doubleQuoted, .escapedChar, .dollarSingleQuoted:
                return true
            default:
                return false
            }
        }
    }

    public var simpleLiteralText: String? {
        guard parts.count == 1, case .literal(let text) = parts[0] else { return nil }
        return text
    }
}

/// Individual components of a shell word
public indirect enum WordPart: Sendable {
    case literal(String)
    case singleQuoted(String)
    case doubleQuoted([WordPart])
    case escapedChar(Character)
    case dollarSingleQuoted(String)
    case variable(VarRef)
    case commandSub(String)
    case backtickSub(String)
    case arithmeticSub(String)
    case tilde(String)

    var rawText: String {
        switch self {
        case .literal(let s): return s
        case .singleQuoted(let s): return "'\(s)'"
        case .doubleQuoted(let parts): return "\"" + parts.map(\.rawText).joined() + "\""
        case .escapedChar(let c): return "\\\(c)"
        case .dollarSingleQuoted(let s): return "$'\(s)'"
        case .variable(let v): return v.rawText
        case .commandSub(let s): return "$(\(s))"
        case .backtickSub(let s): return "`\(s)`"
        case .arithmeticSub(let s): return "$((\(s)))"
        case .tilde(let s): return "~\(s)"
        }
    }
}

/// Variable/parameter reference types
public indirect enum VarRef: Sendable {
    case named(String)                            // $foo or ${foo}
    case special(Character)                       // $? $# $@ $* $$ $! $0 $-
    case positional(Int)                          // $1 ... $9 or ${10}+
    case length(String)                           // ${#foo}
    case withOp(String, VarOp)                    // ${foo<op>...}
    case arrayElement(String, ShellWord)          // ${arr[idx]}
    case arrayAll(String, Bool)                   // ${arr[@]} or ${arr[*]}

    var rawText: String {
        switch self {
        case .named(let n): return "$\(n)"
        case .special(let c): return "$\(c)"
        case .positional(let i): return "$\(i)"
        case .length(let n): return "${#\(n)}"
        case .withOp(_, _): return "${...}" // simplified
        case .arrayElement(let n, _): return "${\(n)[...]}"
        case .arrayAll(let n, _): return "${\(n)[@]}"
        }
    }
}

/// Operations applied inside ${var...} expansions
public indirect enum VarOp: Sendable {
    case defaultValue([WordPart], colonForm: Bool)      // ${v:-w} / ${v-w}
    case assignDefault([WordPart], colonForm: Bool)     // ${v:=w} / ${v=w}
    case errorIfUnset([WordPart], colonForm: Bool)      // ${v:?w} / ${v?w}
    case useAlternative([WordPart], colonForm: Bool)    // ${v:+w} / ${v+w}
    case removeSmallestPrefix(String)                   // ${v#p}
    case removeLargestPrefix(String)                    // ${v##p}
    case removeSmallestSuffix(String)                   // ${v%p}
    case removeLargestSuffix(String)                    // ${v%%p}
    case replace(String, String, all: Bool)             // ${v/p/r} / ${v//p/r}
    case replacePrefix(String, String)                  // ${v/#p/r}
    case replaceSuffix(String, String)                  // ${v/%p/r}
    case substring(String, String?)                     // ${v:off} / ${v:off:len}
    case uppercase(all: Bool)                           // ${v^} / ${v^^}
    case lowercase(all: Bool)                           // ${v,} / ${v,,}
}

// MARK: - Redirections

public struct Redirection: Sendable {
    public var fd: Int?
    public var op: RedirectionOp
    public var target: ShellWord
    public var heredocSuppressExpansion: Bool

    public init(fd: Int? = nil, op: RedirectionOp, target: ShellWord, heredocSuppressExpansion: Bool = false) {
        self.fd = fd
        self.op = op
        self.target = target
        self.heredocSuppressExpansion = heredocSuppressExpansion
    }

    public var effectiveFD: Int {
        if let fd { return fd }
        switch op {
        case .input, .inputOutput, .heredoc, .heredocStripTabs, .herestring, .duplicateInput:
            return 0
        default:
            return 1
        }
    }
}

public enum RedirectionOp: Sendable {
    case output            // >
    case append            // >>
    case input             // <
    case inputOutput       // <>
    case duplicateOutput   // >&
    case duplicateInput    // <&
    case clobber           // >|
    case heredoc           // <<
    case heredocStripTabs  // <<-
    case herestring        // <<<
}

// MARK: - AST Node Types

/// Top-level script: a list of command entries
public struct Script: Sendable {
    public var entries: [ListEntry]
    public init(_ entries: [ListEntry] = []) { self.entries = entries }
    public var isEmpty: Bool { entries.isEmpty }
}

/// A command list entry: an and-or list, optionally backgrounded
public struct ListEntry: Sendable {
    public var andOr: AndOrList
    public var isBackground: Bool

    public init(_ andOr: AndOrList, background: Bool = false) {
        self.andOr = andOr
        self.isBackground = background
    }
}

/// Chain of pipelines connected by && or ||
public struct AndOrList: Sendable {
    public var first: PipelineDef
    public var rest: [(AndOrOp, PipelineDef)]

    public init(_ first: PipelineDef, rest: [(AndOrOp, PipelineDef)] = []) {
        self.first = first
        self.rest = rest
    }
}

public enum AndOrOp: Sendable {
    case and  // &&
    case or   // ||
}

/// A pipeline: [!] command1 [| command2 ...]
public struct PipelineDef: Sendable {
    public var negated: Bool
    public var commands: [Command]
    public var pipeStandardError: [Bool]

    public init(negated: Bool = false, _ commands: [Command], pipeStandardError: [Bool] = []) {
        self.negated = negated
        self.commands = commands
        self.pipeStandardError = pipeStandardError
    }
}

/// A single command in a pipeline
public indirect enum Command: Sendable {
    case simple(SimpleCommand)
    case compound(CompoundCommand, [Redirection])
    case functionDef(FunctionDef)
}

/// Simple command: [assignments] [words] [redirections]
public struct SimpleCommand: Sendable {
    public var assignments: [Assignment]
    public var words: [ShellWord]
    public var redirections: [Redirection]

    public init(assignments: [Assignment] = [], words: [ShellWord] = [], redirections: [Redirection] = []) {
        self.assignments = assignments
        self.words = words
        self.redirections = redirections
    }
}

public struct Assignment: Sendable {
    public var name: String
    public var value: ShellWord
    public var append: Bool
    public var arrayValues: [ShellWord]?

    public init(name: String, value: ShellWord = .empty, append: Bool = false, arrayValues: [ShellWord]? = nil) {
        self.name = name
        self.value = value
        self.append = append
        self.arrayValues = arrayValues
    }
}

/// Function definition
public struct FunctionDef: Sendable {
    public var name: String
    public var body: Command
}

/// Compound commands (control flow and grouping)
public indirect enum CompoundCommand: Sendable {
    case braceGroup(Script)
    case subshell(Script)
    case ifClause(IfClause)
    case forClause(ForClause)
    case forArithClause(ForArithClause)
    case whileClause(LoopClause)
    case untilClause(LoopClause)
    case caseClause(CaseClause)
    case selectClause(SelectClause)
    case condCommand(CondExpr)          // [[ expr ]]
    case arithCommand(String)           // (( expr ))
}

public struct IfClause: Sendable {
    public var conditions: [(condition: Script, body: Script)]
    public var elseBody: Script?
}

public struct ForClause: Sendable {
    public var variable: String
    public var words: [ShellWord]?    // nil means iterate over "$@"
    public var body: Script
}

public struct ForArithClause: Sendable {
    public var initialize: String
    public var condition: String
    public var update: String
    public var body: Script
}

public struct LoopClause: Sendable {
    public var condition: Script
    public var body: Script
}

public struct CaseClause: Sendable {
    public var word: ShellWord
    public var items: [CaseItem]
}

public struct CaseItem: Sendable {
    public var patterns: [ShellWord]
    public var body: Script?
    public var terminator: CaseTerminator
}

public enum CaseTerminator: Sendable {
    case break_       // ;;
    case fallthrough_ // ;&
    case testNext     // ;;&
}

public struct SelectClause: Sendable {
    public var variable: String
    public var words: [ShellWord]?
    public var body: Script
}

/// Conditional expressions for [[ ... ]]
public indirect enum CondExpr: Sendable {
    case unary(String, ShellWord)
    case binary(ShellWord, String, ShellWord)
    case and(CondExpr, CondExpr)
    case or(CondExpr, CondExpr)
    case not(CondExpr)
    case paren(CondExpr)
    case word(ShellWord)
}

// MARK: - Shell Session

/// Mutable shell state during execution
public struct ShellSession: Sendable {
    public var cwd: String
    public var environment: [String: String]
    public var arrayEnvironment: [String: [String]] = [:]
    public var readonlyVariables: Set<String> = []
    public var directoryStack: [String] = []
    public var commandCount: Int = 0
    public var lastExitCode: Int = 0
    public var positionalParams: [String] = []
    public var functions: [String: Command] = [:]
    public var localScopes: [[String: String?]] = []
    public var localArrayScopes: [[String: [String]?]] = []
    public var shellName: String = "bash"
    public var callDepth: Int = 0
    public var aliasExpansionDepth: Int = 0
    public var options: ShellOptions = .init()
    public var aliases: [String: String] = [:]

    public init(cwd: String, environment: [String: String]) {
        self.cwd = VirtualPath.normalize(cwd)
        self.environment = environment
        self.environment["PWD"] = VirtualPath.normalize(cwd)
    }

    /// Set a variable, respecting local scope
    public mutating func setVariable(_ name: String, _ value: String) {
        if let scopeIndex = localScopes.lastIndex(where: { $0.keys.contains(name) }) {
            localScopes[scopeIndex][name] = value
        } else {
            environment[name] = value
        }
        arrayEnvironment.removeValue(forKey: name)
    }

    /// Get a variable value, checking local scopes first
    public func getVariable(_ name: String) -> String? {
        for scope in localScopes.reversed() {
            if let entry = scope[name] {
                return entry // nil entry means explicitly local but unset
            }
        }
        for scope in localArrayScopes.reversed() {
            if let entry = scope[name] {
                return entry?.first
            }
        }
        if let values = arrayEnvironment[name] {
            return values.first
        }
        return environment[name]
    }

    public mutating func setArray(_ name: String, _ values: [String]) {
        if let scopeIndex = localArrayScopes.lastIndex(where: { $0.keys.contains(name) }) {
            localArrayScopes[scopeIndex][name] = values
        } else {
            arrayEnvironment[name] = values
        }
        environment.removeValue(forKey: name)
    }

    public mutating func declareLocalArray(_ name: String, values: [String]? = nil) {
        guard !localArrayScopes.isEmpty else {
            arrayEnvironment[name] = values ?? []
            environment.removeValue(forKey: name)
            return
        }
        localArrayScopes[localArrayScopes.count - 1][name] = values ?? []
        localScopes[localScopes.count - 1].removeValue(forKey: name)
    }

    public func getArray(_ name: String) -> [String]? {
        for scope in localArrayScopes.reversed() {
            if let entry = scope[name] {
                return entry
            }
        }
        return arrayEnvironment[name]
    }

    public mutating func setArrayElement(_ name: String, index: Int, value: String) {
        guard index >= 0 else { return }
        var values = getArray(name) ?? []
        if index >= values.count {
            values.append(contentsOf: Array(repeating: "", count: index - values.count + 1))
        }
        values[index] = value
        setArray(name, values)
    }

    public func getArrayElement(_ name: String, index: Int) -> String? {
        guard index >= 0, let values = getArray(name), index < values.count else { return nil }
        return values[index]
    }

    public mutating func unsetArrayElement(_ name: String, index: Int) {
        guard index >= 0, var values = getArray(name), index < values.count else { return }
        values.remove(at: index)
        setArray(name, values)
    }

    /// Declare a local variable in the current scope
    public mutating func declareLocal(_ name: String, value: String? = nil) {
        guard !localScopes.isEmpty else {
            environment[name] = value ?? ""
            return
        }
        localScopes[localScopes.count - 1][name] = value
    }

    /// Unset a variable
    public mutating func unsetVariable(_ name: String) {
        for i in localScopes.indices.reversed() {
            if localScopes[i].keys.contains(name) {
                localScopes[i].removeValue(forKey: name)
                return
            }
        }
        for i in localArrayScopes.indices.reversed() {
            if localArrayScopes[i].keys.contains(name) {
                localArrayScopes[i].removeValue(forKey: name)
                return
            }
        }
        environment.removeValue(forKey: name)
        arrayEnvironment.removeValue(forKey: name)
    }

    /// Push a new local scope (for function calls)
    public mutating func pushScope() {
        localScopes.append([:])
        localArrayScopes.append([:])
    }

    /// Pop the current local scope
    @discardableResult
    public mutating func popScope() -> [String: String?] {
        _ = localArrayScopes.isEmpty ? [:] : localArrayScopes.removeLast()
        return localScopes.isEmpty ? [:] : localScopes.removeLast()
    }
}

public struct ShellOptions: Sendable {
    public var errexit = false    // set -e
    public var nounset = false    // set -u
    public var xtrace = false     // set -x
    public var pipefail = false   // set -o pipefail
    public var noglob = false     // set -f
    public var noclobber = false  // set -C
    public var expandAliases = true

    public init() {}

    public var flagString: String {
        var flags = ""
        if errexit { flags += "e" }
        if nounset { flags += "u" }
        if xtrace { flags += "x" }
        if pipefail { flags += "p" }
        if noglob { flags += "f" }
        if noclobber { flags += "C" }
        return flags
    }
}

// MARK: - Control Flow Signals

/// Internal signals for break/continue/return/exit in the interpreter
public enum ControlFlow: Error {
    case `break`(Int)
    case `continue`(Int)
    case `return`(Int)
    case exit(Int)
}

public enum ShellRuntimeError: Error, LocalizedError {
    case unboundVariable(String)
    case aliasExpansionTooDeep

    public var errorDescription: String? {
        switch self {
        case .unboundVariable(let name):
            return "\(name): unbound variable"
        case .aliasExpansionTooDeep:
            return "alias expansion too deep"
        }
    }
}
