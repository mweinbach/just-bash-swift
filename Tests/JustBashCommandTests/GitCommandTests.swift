import XCTest
@testable import JustBash

final class GitCommandTests: XCTestCase {
    private func makeGitBash(env: [String: String] = [:], cwd: String = "/workspace") -> Bash {
        Bash(options: .init(
            env: [
                "GIT_AUTHOR_NAME": "Just Bash",
                "GIT_AUTHOR_EMAIL": "just-bash@example.com",
                "GIT_COMMITTER_NAME": "Just Bash",
                "GIT_COMMITTER_EMAIL": "just-bash@example.com",
            ].merging(env, uniquingKeysWith: { _, new in new }),
            cwd: cwd
        ))
    }

    func testGitRunsOnDefaultVirtualFilesystem() async {
        let bash = makeGitBash()

        let setup = await bash.exec("""
        mkdir -p /workspace
        cd /workspace
        git init
        echo 'hello git' > hello.txt
        git add hello.txt
        git commit -m 'initial import'
        """)
        XCTAssertEqual(setup.exitCode, 0, setup.stderr)
        XCTAssertTrue(setup.stdout.contains("Initialized empty Git repository"), setup.stdout)
        XCTAssertTrue(setup.stdout.contains("initial import"), setup.stdout)

        let log = await bash.exec("git log --oneline -1")
        XCTAssertEqual(log.exitCode, 0, log.stderr)
        XCTAssertTrue(log.stdout.contains("initial import"), log.stdout)

        let cleanStatus = await bash.exec("git status --short")
        XCTAssertEqual(cleanStatus.exitCode, 0, cleanStatus.stderr)
        XCTAssertEqual(cleanStatus.stdout, "")

        let topLevel = await bash.exec("git rev-parse --show-toplevel")
        XCTAssertEqual(topLevel.exitCode, 0, topLevel.stderr)
        XCTAssertEqual(topLevel.stdout, "/workspace\n")
    }

    func testGitStatusShowsUntrackedAndModifiedFiles() async {
        let bash = makeGitBash()
        _ = await bash.exec("""
        mkdir -p /workspace
        cd /workspace
        git init
        echo one > tracked.txt
        git add tracked.txt
        git commit -m one
        echo two > tracked.txt
        echo new > new.txt
        """)

        let status = await bash.exec("git status --short")
        XCTAssertEqual(status.exitCode, 0, status.stderr)
        XCTAssertTrue(status.stdout.contains(" M tracked.txt"), status.stdout)
        XCTAssertTrue(status.stdout.contains("?? new.txt"), status.stdout)
    }

    func testGitCanCloneAndPushToBareRemoteInsideVirtualFilesystem() async {
        let bash = makeGitBash(cwd: "/")

        let initRemote = await bash.exec("git init --bare /remote.git")
        XCTAssertEqual(initRemote.exitCode, 0, initRemote.stderr)

        let publish = await bash.exec("""
        git clone /remote.git /worktree
        cd /worktree
        echo 'from clone' > note.txt
        git add note.txt
        git commit -m 'publish'
        git push /remote.git HEAD:refs/heads/master
        """)
        XCTAssertEqual(publish.exitCode, 0, publish.stderr)

        let remoteHead = await bash.exec("git --git-dir=/remote.git rev-parse refs/heads/master")
        XCTAssertEqual(remoteHead.exitCode, 0, remoteHead.stderr)
        XCTAssertEqual(remoteHead.stdout.trimmingCharacters(in: .whitespacesAndNewlines).count, 40)
    }

    func testGitCredentialHelperUsesVirtualHomeDirectory() async {
        let bash = makeGitBash(env: [
            "HOME": "/home/tester",
            "GIT_TERMINAL_PROMPT": "0",
        ])

        _ = await bash.exec("""
        mkdir -p /home/tester /workspace
        printf '[credential]\\n\\thelper = store\\n' > /home/tester/.gitconfig
        printf 'https://octocat:ghp_example@github.com\\n' > /home/tester/.git-credentials
        """)

        let filled = await bash.exec("printf 'protocol=https\\nhost=github.com\\n\\n' | git credential fill")
        XCTAssertEqual(filled.exitCode, 0, filled.stderr)
        XCTAssertTrue(filled.stdout.contains("username=octocat"), filled.stdout)
        XCTAssertTrue(filled.stdout.contains("password=ghp_example"), filled.stdout)
    }
}
