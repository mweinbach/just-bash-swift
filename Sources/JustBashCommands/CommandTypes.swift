import Foundation
import JustBashFS

public struct ExecResult: Sendable, Equatable {
    public var stdout: String
    public var stderr: String
    public var exitCode: Int

    public init(stdout: String = "", stderr: String = "", exitCode: Int = 0) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }

    public static func success(_ stdout: String = "") -> ExecResult {
        ExecResult(stdout: stdout, stderr: "", exitCode: 0)
    }

    public static func failure(_ stderr: String, exitCode: Int = 1) -> ExecResult {
        ExecResult(stdout: "", stderr: stderr.hasSuffix("\n") ? stderr : stderr + "\n", exitCode: exitCode)
    }
}

public typealias SubshellExecutor = @Sendable (String) async -> ExecResult
public typealias CommandHandler = @Sendable ([String], CommandContext) async -> ExecResult

public struct CommandContext: @unchecked Sendable {
    public let fileSystem: VirtualFileSystem
    public let cwd: String
    public let environment: [String: String]
    public let stdin: String
    public let executeSubshell: SubshellExecutor?

    public init(
        fileSystem: VirtualFileSystem,
        cwd: String,
        environment: [String: String],
        stdin: String,
        executeSubshell: SubshellExecutor? = nil
    ) {
        self.fileSystem = fileSystem
        self.cwd = cwd
        self.environment = environment
        self.stdin = stdin
        self.executeSubshell = executeSubshell
    }
}

public struct AnyBashCommand: @unchecked Sendable {
    public let name: String
    public let execute: CommandHandler

    public init(name: String, execute: @escaping CommandHandler) {
        self.name = name
        self.execute = execute
    }
}

public final class CommandRegistry: @unchecked Sendable {
    private var commands: [String: AnyBashCommand] = [:]

    public init(commands: [AnyBashCommand] = []) {
        for command in commands {
            register(command)
        }
    }

    public func register(_ command: AnyBashCommand) {
        commands[command.name] = command
    }

    public func command(named name: String) -> AnyBashCommand? {
        commands[name]
    }

    public func contains(_ name: String) -> Bool {
        commands[name] != nil
    }

    public var names: [String] {
        commands.keys.sorted()
    }

    public static func builtins() -> CommandRegistry {
        CommandRegistry(commands: builtinCommands())
    }

    public static func builtinCommands() -> [AnyBashCommand] {
        [
            // Core I/O
            cat(), tee(),
            // File operations
            ls(), mkdir(), touch(), rm(), rmdir(), cp(), mv(), ln(), chmod(), stat(), tree(), split(), mktemp(),
            // File info
            find(), du(), realpath(), readlink(), basename(), dirname(), file(), strings(),
            // Text processing
            grep(), egrep(), fgrep(), rg(), sed(), awk(), sort(), uniq(), tr(), cut(), paste(), join(),
            wc(), head(), tail(), tac(), rev(), nl(), fold(), expand(), unexpand(), column(), od(),
            // Data
            seq(), yes(), base64(), expr(), md5sum(), sha1sum(), sha256sum(), gzip(), gunzip(), zcat(), tar(), sqlite3(), jq(), yq(), bc(), xan(),
            // Misc
            xargs(), diff(), comm(), date(), sleep_(), uname(), hostname(), whoami(), clear(), help(), history(), bash(), sh(), time(), timeout(), curl(), htmlToMarkdown(),
            tput(), getconf(), nproc(), env(),
        ]
    }
}

struct OrderedJSONObject {
    let entries: [(String, Any)]
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        if size >= count { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
