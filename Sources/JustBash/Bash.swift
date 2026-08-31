import Foundation
import JustBashCommands
import JustBashCore
import JustBashFS

public typealias AnyBashCommand = JustBashCommands.AnyBashCommand
public typealias CommandContext = JustBashCommands.CommandContext
public typealias CommandHandler = JustBashCommands.CommandHandler
public typealias ExecResult = JustBashCommands.ExecResult
public typealias ExecutionLimits = JustBashCore.ExecutionLimits
public typealias VirtualProcessInfo = JustBashFS.VirtualProcessInfo

public struct BashOptions: Sendable {
    public var files: [String: String]
    public var env: [String: String]
    public var cwd: String
    public var executionLimits: ExecutionLimits
    public var customCommands: [AnyBashCommand]
    public var processInfo: VirtualProcessInfo
    /// Optional custom filesystem backend. When omitted, `Bash` creates an
    /// in-memory `VirtualFileSystem` seeded from `files` and `processInfo`.
    public var filesystem: (any BashFilesystem)?
    /// URL prefixes that network commands (curl) are allowed to access.
    /// An empty array means no network access (default, matching upstream).
    /// Examples: `["https://"]` for all HTTPS, `["https://api.example.com/"]` for specific hosts.
    public var allowedURLPrefixes: [String]
    /// Optional embedded-language runtimes (e.g. `JavaScriptRuntime`, `PythonRuntime`).
    /// Each runtime contributes a set of commands that are registered alongside the
    /// builtins. Leaving this empty preserves the default shell surface.
    public var embeddedRuntimes: [any EmbeddedRuntime]

    public init(
        files: [String: String] = [:],
        env: [String: String] = [:],
        cwd: String = "/home/user",
        executionLimits: ExecutionLimits = .init(),
        customCommands: [AnyBashCommand] = [],
        processInfo: VirtualProcessInfo = .init(),
        filesystem: (any BashFilesystem)? = nil,
        allowedURLPrefixes: [String] = [],
        embeddedRuntimes: [any EmbeddedRuntime] = []
    ) {
        self.files = files
        self.env = env
        self.cwd = cwd
        self.executionLimits = executionLimits
        self.customCommands = customCommands
        self.processInfo = processInfo
        self.filesystem = filesystem
        self.allowedURLPrefixes = allowedURLPrefixes
        self.embeddedRuntimes = embeddedRuntimes
    }
}

public struct ExecOptions: Sendable {
    public var env: [String: String]
    public var replaceEnv: Bool
    public var cwd: String?
    public var stdin: String
    /// `false` disables network access for this invocation, including nested
    /// shell commands and embedded runtimes. `true` or `nil` retains the host's
    /// `BashOptions.allowedURLPrefixes`; it never grants additional URLs.
    public var allowNetwork: Bool?

    public init(env: [String: String] = [:], replaceEnv: Bool = false, cwd: String? = nil, stdin: String = "", allowNetwork: Bool? = nil) {
        self.env = env
        self.replaceEnv = replaceEnv
        self.cwd = cwd
        self.stdin = stdin
        self.allowNetwork = allowNetwork
    }
}

public actor Bash {
    private let fileSystem: any BashFilesystem
    private let registry: CommandRegistry
    private let baseEnv: [String: String]
    private let baseCwd: String
    private let parser: ShellParser
    private let interpreter: ShellInterpreter
    private let networkDisabledInterpreter: ShellInterpreter

    public init(options: BashOptions = .init()) {
        let fileSystem = options.filesystem ?? VirtualFileSystem(
            initialFiles: options.files,
            processInfo: options.processInfo
        )
        if options.filesystem != nil {
            for (path, content) in options.files {
                let normalized = fileSystem.normalizePath(path, relativeTo: "/")
                let parent = VirtualPath.dirname(normalized)
                if parent != "/" {
                    try? fileSystem.createDirectory(path: parent, relativeTo: "/", recursive: true)
                }
                try? fileSystem.writeFile(content, to: normalized, relativeTo: "/")
            }
        }
        self.fileSystem = fileSystem
        let registry = CommandRegistry.builtins()
        for command in options.customCommands {
            registry.register(command)
        }
        for runtime in options.embeddedRuntimes {
            for command in runtime.commands() {
                registry.register(command)
            }
        }
        for name in ["cd", "pwd", "env", "printenv", "which", "true", "false", "export",
                      "echo", "printf", "test", "[", "read", "set", "unset", "local",
                      "declare", "typeset", "eval", "source", ".", "shift", "return",
                      "exit", "break", "continue", "trap", "alias", "unalias",
                      "command", "type", "let", ":", "getopts", "mapfile", "readarray",
                      "pushd", "popd", "dirs", "builtin", "hash", "exec", "readonly", "shopt",
                      "compgen", "complete", "compopt"] + registry.names {
            fileSystem.seedCommandStub(named: name)
        }
        self.registry = registry
        self.baseCwd = VirtualPath.normalize(options.cwd)
        self.baseEnv = [
            "HOME": "/home/user",
            "PATH": "/usr/bin:/bin",
            "PWD": self.baseCwd,
            "OLDPWD": self.baseCwd,
            "IFS": " \t\n",
            "HOSTNAME": "localhost",
            "SHELL": "/bin/bash",
            "TERM": "xterm-256color",
            "LANG": "en_US.UTF-8",
            "BASH_VERSION": "5.2.0(1)-release",
            "BASH_VERSINFO": "5",
            "SHLVL": "1",
            "RANDOM": String(Int.random(in: 0...32767)),
            "LINENO": "1",
            "SECONDS": "0",
            "OPTIND": "1",
        ].merging(options.env, uniquingKeysWith: { _, new in new })
        self.parser = ShellParser(limits: options.executionLimits)
        self.interpreter = ShellInterpreter(fileSystem: fileSystem, registry: registry, limits: options.executionLimits, allowedURLPrefixes: options.allowedURLPrefixes)
        self.networkDisabledInterpreter = ShellInterpreter(fileSystem: fileSystem, registry: registry, limits: options.executionLimits, allowedURLPrefixes: [])
    }

    public func exec(_ script: String, options: ExecOptions = .init()) async -> ExecResult {
        if script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ExecResult.success()
        }
        do {
            let parsed = try parser.parse(script)
            let cwd = VirtualPath.normalize(options.cwd ?? baseCwd)
            var environment = options.replaceEnv ? [:] : baseEnv
            environment.merge(options.env, uniquingKeysWith: { _, new in new })
            var session = ShellSession(cwd: cwd, environment: environment)
            // Both interpreters are immutable. An overlapping invocation cannot
            // change another invocation's effective network capabilities.
            let scopedInterpreter = options.allowNetwork == false ? networkDisabledInterpreter : interpreter
            return await scopedInterpreter.execute(script: parsed, session: &session, stdin: options.stdin)
        } catch {
            return ExecResult(stdout: "", stderr: "bash: syntax error: \(error.localizedDescription)\n", exitCode: 2)
        }
    }

    public func readFile(_ path: String) throws -> String {
        try fileSystem.readFile(path, relativeTo: baseCwd)
    }

    public func listDirectory(_ path: String = "/") throws -> [VirtualDirectoryEntry] {
        let normalized = fileSystem.normalizePath(path, relativeTo: baseCwd)
        let names = try fileSystem.listDirectory(path, relativeTo: baseCwd, includeHidden: true)
        return names.map { name in
            let childPath = normalized == "/" ? "/\(name)" : "\(normalized)/\(name)"
            let info = try? fileSystem.fileInfo(path: childPath, relativeTo: "/")
            let kind: VirtualNodeKind
            switch info?.kind {
            case .directory:
                kind = .directory
            case .symlink:
                kind = .symlink
            default:
                kind = .file
            }
            return VirtualDirectoryEntry(name: name, path: childPath, kind: kind)
        }
    }

    // MARK: - defineCommand API

    /// Registers a custom command at runtime.
    ///
    /// This is the Swift equivalent of upstream's `defineCommand()`. It lets host
    /// apps extend the shell with domain-specific commands that bash scripts can
    /// call like any other command.
    ///
    /// ```swift
    /// let bash = Bash()
    /// await bash.defineCommand("greet") { args, ctx in
    ///     let name = args.dropFirst().first ?? "world"
    ///     return ExecResult.success("Hello, \(name)!\n")
    /// }
    /// let result = await bash.exec("greet Swift")
    /// // result.stdout == "Hello, Swift!\n"
    /// ```
    ///
    /// - Parameters:
    ///   - name: The command name (what users type in bash).
    ///   - handler: A closure that receives `(args, context)` and returns an `ExecResult`.
    public func defineCommand(_ name: String, handler: @escaping CommandHandler) {
        let command = AnyBashCommand(name: name, execute: handler)
        registry.register(command)
        fileSystem.seedCommandStub(named: name)
    }

    /// Registers multiple custom commands at once.
    ///
    /// - Parameter commands: An array of `AnyBashCommand` values to register.
    public func defineCommands(_ commands: [AnyBashCommand]) {
        for command in commands {
            registry.register(command)
            fileSystem.seedCommandStub(named: command.name)
        }
    }

    /// Returns the names of all registered commands (builtins + custom).
    public var commandNames: [String] {
        registry.names
    }

    // MARK: - Filesystem Access

    /// Direct access to the underlying virtual filesystem.
    ///
    /// Host apps can use this to pre-populate files, read outputs, or inspect
    /// the filesystem state after script execution.
    public var fs: any BashFilesystem {
        fileSystem
    }
}
