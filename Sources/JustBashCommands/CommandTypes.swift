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
    public let fileSystem: BashFilesystem
    public let cwd: String
    public let environment: [String: String]
    public let stdin: String
    public let executeSubshell: SubshellExecutor?
    /// URL prefixes that curl/network commands are allowed to access.
    /// An empty array means no network access is permitted (default).
    /// Use `["https://"]` to allow all HTTPS, or specific prefixes like
    /// `["https://api.example.com/"]` for fine-grained control.
    public let allowedURLPrefixes: [String]

    public init(
        fileSystem: BashFilesystem,
        cwd: String,
        environment: [String: String],
        stdin: String,
        executeSubshell: SubshellExecutor? = nil,
        allowedURLPrefixes: [String] = []
    ) {
        self.fileSystem = fileSystem
        self.cwd = cwd
        self.environment = environment
        self.stdin = stdin
        self.executeSubshell = executeSubshell
        self.allowedURLPrefixes = allowedURLPrefixes
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

/// A package of commands that extend the bash environment with an embedded
/// language runtime (e.g. JavaScript via `JustBashJavaScript`, Python via
/// `JustBashPython`). Hosts register runtimes through `BashOptions.embeddedRuntimes`;
/// `Bash.init` then adds each runtime's commands to the registry and seeds
/// matching FS stubs so scripts can invoke them by name or absolute path.
public protocol EmbeddedRuntime: Sendable {
    func commands() -> [AnyBashCommand]
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
            // Binary data
            hexdump(), xxd(), iconv(), uuencode(),
            // System info
            which(), whereis(), df(), free(), uptime(), ps(), kill(), killall(),
            // Archive formats
            zip(), unzip(), bzip2(), bunzip2(), bzcat(),
            // Text processing extras
            fmt(), pr(), look(), tsort(),
            // Checksum
            cksum(), sum(),
            // System
            tty(), pathchk(), jot(),
            // Data manipulation
            shuf(), ts(), sponge(), vidir(), vipe(), pee(), combine(), ifdata(), chronic(), errno(),
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
