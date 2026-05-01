import Foundation
import JustBashCommands
import JustBashCore
import JustBashFS

public struct CodingAgentWorkspace: Sendable {
    public var filesystem: UserWorkspaceFileSystem
    public var homePath: String
    public var cwd: String
    public var env: [String: String]

    public init(
        rootURL: URL,
        username: String = "coder",
        cwd: String? = nil,
        env: [String: String] = [:]
    ) throws {
        let layout = UserWorkspaceFileSystem.Layout(username: username)
        let filesystem = try UserWorkspaceFileSystem(rootURL: rootURL, layout: layout)
        let homePath = layout.homePath
        let workingDirectory = cwd ?? "\(homePath)/Documents"
        self.filesystem = filesystem
        self.homePath = homePath
        self.cwd = workingDirectory
        self.env = [
            "HOME": homePath,
            "USER": username,
            "LOGNAME": username,
            "PWD": workingDirectory,
            "OLDPWD": workingDirectory,
            "TMPDIR": "/tmp",
            "PATH": "/usr/bin:/bin",
        ].merging(env, uniquingKeysWith: { _, new in new })
    }

    public func options(
        files: [String: String] = [:],
        executionLimits: ExecutionLimits = .init(),
        customCommands: [AnyBashCommand] = [],
        allowedURLPrefixes: [String] = [],
        embeddedRuntimes: [any EmbeddedRuntime] = []
    ) -> BashOptions {
        BashOptions(
            files: files,
            env: env,
            cwd: cwd,
            executionLimits: executionLimits,
            customCommands: customCommands,
            filesystem: filesystem,
            allowedURLPrefixes: allowedURLPrefixes,
            embeddedRuntimes: embeddedRuntimes
        )
    }
}

extension BashOptions {
    /// Creates options for an app-hosted coding agent with a persistent,
    /// mac-like user filesystem.
    ///
    /// Use this in iOS/macOS apps that need an embedded shell or coding agent
    /// to work in familiar paths such as `~/Documents` and `~/Downloads`.
    public static func codingAgentWorkspace(
        rootURL: URL,
        username: String = "coder",
        cwd: String? = nil,
        files: [String: String] = [:],
        env: [String: String] = [:],
        executionLimits: ExecutionLimits = .init(),
        customCommands: [AnyBashCommand] = [],
        allowedURLPrefixes: [String] = [],
        embeddedRuntimes: [any EmbeddedRuntime] = []
    ) throws -> BashOptions {
        let workspace = try CodingAgentWorkspace(
            rootURL: rootURL,
            username: username,
            cwd: cwd,
            env: env
        )
        return workspace.options(
            files: files,
            executionLimits: executionLimits,
            customCommands: customCommands,
            allowedURLPrefixes: allowedURLPrefixes,
            embeddedRuntimes: embeddedRuntimes
        )
    }
}
