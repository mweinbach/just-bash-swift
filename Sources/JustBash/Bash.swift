import Foundation
import JustBashCommands
import JustBashCore
import JustBashFS

public typealias AnyBashCommand = JustBashCommands.AnyBashCommand
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

    public init(
        files: [String: String] = [:],
        env: [String: String] = [:],
        cwd: String = "/home/user",
        executionLimits: ExecutionLimits = .init(),
        customCommands: [AnyBashCommand] = [],
        processInfo: VirtualProcessInfo = .init()
    ) {
        self.files = files
        self.env = env
        self.cwd = cwd
        self.executionLimits = executionLimits
        self.customCommands = customCommands
        self.processInfo = processInfo
    }
}

public struct ExecOptions: Sendable {
    public var env: [String: String]
    public var replaceEnv: Bool
    public var cwd: String?
    public var stdin: String

    public init(env: [String: String] = [:], replaceEnv: Bool = false, cwd: String? = nil, stdin: String = "") {
        self.env = env
        self.replaceEnv = replaceEnv
        self.cwd = cwd
        self.stdin = stdin
    }
}

public actor Bash {
    private let fileSystem: VirtualFileSystem
    private let baseEnv: [String: String]
    private let baseCwd: String
    private let parser: ShellParser
    private let interpreter: ShellInterpreter

    public init(options: BashOptions = .init()) {
        self.fileSystem = VirtualFileSystem(initialFiles: options.files, processInfo: options.processInfo)
        let registry = CommandRegistry.builtins()
        for command in options.customCommands {
            registry.register(command)
        }
        for name in ["cd", "pwd", "env", "printenv", "which", "true", "false", "export",
                      "echo", "printf", "test", "[", "read", "set", "unset", "local",
                      "declare", "typeset", "eval", "source", ".", "shift", "return",
                      "exit", "break", "continue", "trap", "alias", "unalias",
                      "command", "type", "let", ":", "getopts", "mapfile", "readarray",
                      "pushd", "popd", "dirs", "builtin", "hash", "exec"] + registry.names {
            fileSystem.seedCommandStub(named: name)
        }
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
        self.interpreter = ShellInterpreter(fileSystem: fileSystem, registry: registry, limits: options.executionLimits)
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
            return await interpreter.execute(script: parsed, session: &session, stdin: options.stdin)
        } catch {
            return ExecResult(stdout: "", stderr: "bash: syntax error: \(error.localizedDescription)\n", exitCode: 2)
        }
    }

    public func readFile(_ path: String) throws -> String {
        try fileSystem.readFile(path, relativeTo: baseCwd)
    }

    public func listDirectory(_ path: String = "/") throws -> [VirtualDirectoryEntry] {
        try fileSystem.listDirectory(path, includeHidden: true)
    }
}
