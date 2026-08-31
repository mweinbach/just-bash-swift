import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import JustBash

final class GitCommandTests: XCTestCase {
    private func makeGitBash(env: [String: String] = [:], cwd: String = "/workspace", allowedURLPrefixes: [String] = []) -> Bash {
        Bash(options: .init(
            env: [
                "GIT_AUTHOR_NAME": "Just Bash",
                "GIT_AUTHOR_EMAIL": "just-bash@example.com",
                "GIT_COMMITTER_NAME": "Just Bash",
                "GIT_COMMITTER_EMAIL": "just-bash@example.com",
            ].merging(env, uniquingKeysWith: { _, new in new }),
            cwd: cwd,
            allowedURLPrefixes: allowedURLPrefixes
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

    func testGitPushToGitHubUsesPortableRestFlow() async {
        MockGitHubURLProtocol.reset()
        _ = URLProtocol.registerClass(MockGitHubURLProtocol.self)
        defer {
            URLProtocol.unregisterClass(MockGitHubURLProtocol.self)
            MockGitHubURLProtocol.reset()
        }

        MockGitHubURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            let requestBody = MockGitHubURLProtocol.bodyData(for: request)
            MockGitHubURLProtocol.seen.append((request.httpMethod ?? "GET", path, requestBody))

            switch (request.httpMethod ?? "GET", path) {
            case ("GET", "/repos/octocat/Hello-World/git/ref/heads/master"):
                return MockGitHubURLProtocol.response(status: 200, json: #"{"ref":"refs/heads/master","object":{"sha":"1111111111111111111111111111111111111111"}}"#)
            case ("GET", "/repos/octocat/Hello-World/git/commits/1111111111111111111111111111111111111111"):
                return MockGitHubURLProtocol.response(status: 200, json: #"{"sha":"1111111111111111111111111111111111111111","tree":{"sha":"2222222222222222222222222222222222222222"}}"#)
            case ("POST", "/repos/octocat/Hello-World/git/trees"):
                let body = String(data: requestBody, encoding: .utf8) ?? ""
                XCTAssertTrue(body.contains(#""base_tree":"2222222222222222222222222222222222222222""#), body)
                XCTAssertTrue(body.contains(#""path":"note.txt""#), body)
                XCTAssertTrue(body.contains(#""content":"hello from phone\n""#), body)
                return MockGitHubURLProtocol.response(status: 201, json: #"{"sha":"3333333333333333333333333333333333333333"}"#)
            case ("POST", "/repos/octocat/Hello-World/git/commits"):
                let body = String(data: requestBody, encoding: .utf8) ?? ""
                XCTAssertTrue(body.contains(#""message":"publish from phone""#), body)
                XCTAssertTrue(body.contains(#""tree":"3333333333333333333333333333333333333333""#), body)
                XCTAssertTrue(body.contains(#""parents":["1111111111111111111111111111111111111111"]"#), body)
                return MockGitHubURLProtocol.response(status: 201, json: #"{"sha":"4444444444444444444444444444444444444444"}"#)
            case ("PATCH", "/repos/octocat/Hello-World/git/refs/heads/master"):
                let body = String(data: requestBody, encoding: .utf8) ?? ""
                XCTAssertTrue(body.contains(#""sha":"4444444444444444444444444444444444444444""#), body)
                XCTAssertTrue(body.contains(#""force":false"#), body)
                return MockGitHubURLProtocol.response(status: 200, json: #"{"ref":"refs/heads/master","object":{"sha":"4444444444444444444444444444444444444444"}}"#)
            default:
                return MockGitHubURLProtocol.response(status: 404, json: #"{"message":"unexpected request"}"#)
            }
        }

        let bash = makeGitBash(env: [
            "HOME": "/home/tester",
            "GIT_TERMINAL_PROMPT": "0",
        ], allowedURLPrefixes: ["https://api.github.com/"])
        let push = await bash.exec("""
        mkdir -p /home/tester /workspace
        printf 'https://octocat:ghp_example@github.com\\n' > /home/tester/.git-credentials
        cd /workspace
        git init
        printf 'hello from phone\\n' > note.txt
        git add note.txt
        git commit -m 'publish from phone'
        git push https://github.com/octocat/Hello-World.git HEAD:refs/heads/master
        """)

        XCTAssertEqual(push.exitCode, 0, push.stderr)
        XCTAssertTrue(push.stdout.contains("To https://github.com/octocat/Hello-World.git"), push.stdout)
        XCTAssertEqual(MockGitHubURLProtocol.seen.map(\.0), ["GET", "GET", "POST", "POST", "PATCH"])
        XCTAssertTrue(MockGitHubURLProtocol.seen.allSatisfy { $0.1.hasPrefix("/repos/octocat/Hello-World") })
    }

    func testGitRemoteOperationsHonorDefaultAndPerExecutionNetworkDenial() async {
        MockGitHubURLProtocol.reset()
        _ = URLProtocol.registerClass(MockGitHubURLProtocol.self)
        defer {
            URLProtocol.unregisterClass(MockGitHubURLProtocol.self)
            MockGitHubURLProtocol.reset()
        }
        MockGitHubURLProtocol.handler = { request in
            MockGitHubURLProtocol.seen.append((request.httpMethod ?? "GET", request.url?.path ?? "", nil))
            return MockGitHubURLProtocol.response(status: 403, json: #"{"message":"should not reach transport"}"#)
        }
        for prefixes in [[], ["https://"], ["https://unrelated.invalid/"]] {
            let bash = makeGitBash(allowedURLPrefixes: prefixes)
            let setup = await bash.exec("mkdir -p /workspace; git init; echo content > note.txt; git add note.txt; git commit -m initial")
            XCTAssertEqual(setup.exitCode, 0, setup.stderr)
            let options = ExecOptions(allowNetwork: prefixes == ["https://"] ? false : nil)
            for command in ["git ls-remote https://github.com/octocat/Hello-World.git", "git clone https://github.com/octocat/Hello-World.git cloned", "git push https://github.com/octocat/Hello-World.git HEAD:refs/heads/master"] {
                let result = await bash.exec(command, options: options)
                XCTAssertNotEqual(result.exitCode, 0)
                XCTAssertTrue(result.stderr.contains("not in allow-list"), result.stderr)
            }
        }
        XCTAssertTrue(MockGitHubURLProtocol.seen.isEmpty)
    }
}

private final class MockGitHubURLProtocol: URLProtocol {
    typealias Response = (HTTPURLResponse, Data)

    nonisolated(unsafe) static var handler: ((URLRequest) throws -> Response)?
    nonisolated(unsafe) static var seen: [(String, String, Data?)] = []

    static func reset() {
        handler = nil
        seen = []
    }

    static func response(status: Int, json: String) -> Response {
        let url = URL(string: "https://api.github.com")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(json.utf8))
    }

    static func bodyData(for request: URLRequest) -> Data {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return Data()
        }

        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "api.github.com"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
