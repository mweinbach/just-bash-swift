import Foundation
import XCTest
@testable import JustBash
@testable import JustBashFS

final class GitCommandTests: XCTestCase {
#if os(macOS) || targetEnvironment(macCatalyst)
    private func makeTempDirectory(prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeText(_ text: String, to url: URL) throws {
        try text.data(using: .utf8)?.write(to: url)
    }

    private func makeGitBash(rootURL: URL, cwd: String, env: [String: String] = [:]) -> Bash {
        let baseEnv = [
            "GIT_AUTHOR_NAME": "Just Bash",
            "GIT_AUTHOR_EMAIL": "just-bash@example.com",
            "GIT_COMMITTER_NAME": "Just Bash",
            "GIT_COMMITTER_EMAIL": "just-bash@example.com",
            "GIT_CONFIG_NOSYSTEM": "1",
        ].merging(env, uniquingKeysWith: { _, new in new })

        return Bash(options: .init(
            env: baseEnv,
            cwd: cwd,
            filesystem: ReadWriteFileSystem(base: rootURL.path)
        ))
    }

    func testGitRejectsPureVirtualFilesystem() async {
        let bash = Bash()
        let result = await bash.exec("git status")
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertTrue(result.stderr.contains("host-backed writable filesystem"))
    }

    func testGitCanInitCommitAndInspectRepository() async throws {
        let rootURL = try makeTempDirectory(prefix: "GitCommandRepo")
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let repoURL = rootURL.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)

        let bash = makeGitBash(rootURL: rootURL, cwd: "/repo")

        let setup = await bash.exec("""
        git init
        echo 'hello git' > hello.txt
        git add hello.txt
        git commit -m 'initial import'
        git status --short
        """)
        XCTAssertEqual(setup.exitCode, 0, setup.stderr)
        XCTAssertTrue(setup.stdout.contains("Initialized empty Git repository"), setup.stdout)
        XCTAssertTrue(setup.stdout.contains("initial import"), setup.stdout)

        let log = await bash.exec("git log --oneline -1")
        XCTAssertEqual(log.exitCode, 0, log.stderr)
        XCTAssertTrue(log.stdout.contains("initial import"), log.stdout)

        let cleanStatus = await bash.exec("git status --short")
        XCTAssertEqual(cleanStatus.exitCode, 0, cleanStatus.stderr)
        XCTAssertTrue(cleanStatus.stdout.isEmpty, cleanStatus.stdout)

        let topLevel = await bash.exec("git rev-parse --show-toplevel")
        XCTAssertEqual(topLevel.exitCode, 0, topLevel.stderr)
        let resolvedTopLevel = URL(fileURLWithPath: topLevel.stdout.trimmingCharacters(in: .whitespacesAndNewlines)).standardizedFileURL.path
        XCTAssertEqual(resolvedTopLevel, repoURL.standardizedFileURL.path)
    }

    func testGitCanPushToBareRemoteUsingVirtualAbsolutePaths() async throws {
        let rootURL = try makeTempDirectory(prefix: "GitCommandRemote")
        defer { try? FileManager.default.removeItem(at: rootURL) }

        try FileManager.default.createDirectory(at: rootURL.appendingPathComponent("workspace", isDirectory: true), withIntermediateDirectories: true)
        let bash = makeGitBash(rootURL: rootURL, cwd: "/workspace")

        let initRemote = await bash.exec("git init --bare /remote.git")
        XCTAssertEqual(initRemote.exitCode, 0, initRemote.stderr)

        let publish = await bash.exec("""
        git clone /remote.git /worktree
        cd /worktree
        echo 'from clone' > note.txt
        git add note.txt
        git commit -m 'publish'
        git push origin HEAD:refs/heads/main
        """)
        XCTAssertEqual(publish.exitCode, 0, publish.stderr)

        let remoteHead = await bash.exec("git --git-dir=/remote.git rev-parse refs/heads/main")
        XCTAssertEqual(remoteHead.exitCode, 0, remoteHead.stderr)
        XCTAssertEqual(remoteHead.stdout.trimmingCharacters(in: .whitespacesAndNewlines).count, 40)
    }

    func testGitCredentialHelperUsesMappedHomeDirectory() async throws {
        let rootURL = try makeTempDirectory(prefix: "GitCommandCreds")
        defer { try? FileManager.default.removeItem(at: rootURL) }

        try FileManager.default.createDirectory(at: rootURL.appendingPathComponent("workspace", isDirectory: true), withIntermediateDirectories: true)
        let hostHome = rootURL.appendingPathComponent("home/tester", isDirectory: true)
        try FileManager.default.createDirectory(at: hostHome, withIntermediateDirectories: true)
        try writeText("[credential]\n\thelper = store\n", to: hostHome.appendingPathComponent(".gitconfig"))
        try writeText("https://octocat:ghp_example@github.com\n", to: hostHome.appendingPathComponent(".git-credentials"))

        let bash = makeGitBash(
            rootURL: rootURL,
            cwd: "/workspace",
            env: [
                "HOME": "/home/tester",
                "GIT_TERMINAL_PROMPT": "0",
            ]
        )

        let filled = await bash.exec("printf 'protocol=https\\nhost=github.com\\n\\n' | git credential fill")
        XCTAssertEqual(filled.exitCode, 0, filled.stderr)
        XCTAssertTrue(filled.stdout.contains("username=octocat"), filled.stdout)
        XCTAssertTrue(filled.stdout.contains("password=ghp_example"), filled.stdout)
    }
#endif
}
