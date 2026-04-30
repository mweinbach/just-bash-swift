import Foundation
import JustBash
import JustBashFS
import JustBashJavaScript

actor SandboxService {
    static let shared = SandboxService()

    static let seedFiles: [String: String] = [
        "/data/input.txt": """
        Codex can run locally inside a virtual shell on iPhone.
        This file lives in the in-memory sandbox.
        """,
        "/data/log.txt": """
        INFO Boot complete
        ERROR Missing token cache
        INFO Retrying request
        ERROR Request failed
        """,
        "/workspace/README.txt": """
        This directory is mounted to the app's sandboxed Documents folder.
        Files written here persist across launches of Just Bash on iPhone/iPad.
        """,
    ]

    private var bash = SandboxService.makeBash()

    func run(_ script: String) async -> ExecResult {
        await bash.exec(script)
    }

    func reset() {
        bash = SandboxService.makeBash()
    }

    func readFile(_ path: String) async throws -> String {
        try await bash.readFile(path)
    }

    func pythonAvailabilitySummary() -> String {
        PythonSupport.availabilitySummary()
    }

    func runPython(_ code: String) async -> Result<String, Error> {
        PythonSupport.run(code: code, workspacePath: Self.workspaceDirectoryPath())
    }

    func writeFile(_ path: String, contents: String) async throws {
        let fs = await bash.fs
        let normalized = fs.normalizePath(path, relativeTo: "/workspace")
        let parent = String(normalized.split(separator: "/").dropLast().joined(separator: "/"))
        let parentPath = parent.isEmpty ? "/" : "/" + parent
        if parentPath != "/" {
            try fs.createDirectory(path: parentPath, relativeTo: "/", recursive: true)
        }
        try fs.writeFile(contents, to: normalized, relativeTo: "/")
    }

    func listDirectory(_ path: String) async throws -> [VirtualDirectoryEntry] {
        try await bash.listDirectory(path)
    }

    private static func makeBash() -> Bash {
        let workspaceBase = workspaceDirectoryPath()
        try? FileManager.default.createDirectory(
            atPath: workspaceBase,
            withIntermediateDirectories: true
        )

        let root = VirtualFileSystem()
        let mountable = MountableFileSystem(root: root)
        mountable.mount(ReadWriteFileSystem(base: workspaceBase), at: "/workspace")

        return Bash(options: .init(
            files: seedFiles,
            filesystem: mountable,
            embeddedRuntimes: [
                JavaScriptRuntime(options: .init(
                    bootstrap: "globalThis.APP_NAME = 'JustBashPhone';"
                ))
            ]
        ))
    }

    private static func workspaceDirectoryPath() -> String {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("JustBashWorkspace", isDirectory: true).path
    }
}
