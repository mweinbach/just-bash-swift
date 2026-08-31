import Foundation
import XCTest
import JustBash
@testable import JustBashCommands

final class NetworkPolicyTests: XCTestCase {
    func testExecutionNetworkOverrideIsIsolatedAndInheritedBySubshells() async {
        let bash = Bash(options: .init(allowedURLPrefixes: ["https://permitted.invalid/"]))
        await bash.defineCommand("network-policy") { _, context in
            .success(context.allowedURLPrefixes.isEmpty ? "denied\n" : "configured\n")
        }
        async let denied = bash.exec("sleep 0.03; network-policy; bash -c network-policy; echo \"$(network-policy)\"", options: .init(allowNetwork: false))
        async let inherited = bash.exec("network-policy")
        let (deniedResult, inheritedResult) = await (denied, inherited)
        XCTAssertEqual(deniedResult.stdout, "denied\ndenied\ndenied\n", deniedResult.stderr)
        XCTAssertEqual(inheritedResult.stdout, "configured\n")
        let restored = await bash.exec("network-policy", options: .init(allowNetwork: true))
        XCTAssertEqual(restored.stdout, "configured\n")
        let emptyHost = Bash()
        let cannotGrant = await emptyHost.exec("curl https://permitted.invalid/", options: .init(allowNetwork: true))
        XCTAssertNotEqual(cannotGrant.exitCode, 0)
        XCTAssertTrue(cannotGrant.stderr.contains("not in allow-list"), cannotGrant.stderr)
    }

    func testHTTPAllowlistChecksOriginAndRejectsOtherSchemes() {
        let prefixes = ["https://example.com"]
        XCTAssertTrue(CommandNetworkAccess.isAllowed(URL(string: "https://example.com/path")!, prefixes: prefixes))
        for value in ["https://example.com.evil.invalid/", "https://example.com@evil.invalid/", "https://example.com:8443/", "http://example.com/", "file:///etc/hosts"] {
            XCTAssertFalse(CommandNetworkAccess.isAllowed(URL(string: value)!, prefixes: prefixes), value)
        }
        XCTAssertTrue(CommandNetworkAccess.isAllowed(URL(string: "https://other.invalid/path")!, prefixes: ["https://"]))
        XCTAssertFalse(CommandNetworkAccess.isAllowed(URL(string: "https://example.com/")!, prefixes: []))
    }

    func testCurlFileURLsUseVirtualFilesystemEvenWhenPhysicalFileExists() async throws {
        let physical = FileManager.default.temporaryDirectory.appendingPathComponent("justbash-network-\(UUID().uuidString).txt")
        try Data("host-only-secret".utf8).write(to: physical)
        defer { try? FileManager.default.removeItem(at: physical) }
        let bash = Bash(options: .init(files: [physical.path: "virtual-content"]))
        let virtual = await bash.exec("curl '\(physical.absoluteString)'", options: .init(allowNetwork: false))
        XCTAssertEqual(virtual.stdout, "virtual-content\n", virtual.stderr)
        _ = await bash.exec("rm '\(physical.path)'")
        let missing = await bash.exec("curl '\(physical.absoluteString)'")
        XCTAssertNotEqual(missing.exitCode, 0)
        XCTAssertFalse(missing.stdout.contains("host-only-secret"))
        let inline = await bash.exec("curl 'data:text/plain,hello%20world'", options: .init(allowNetwork: false))
        XCTAssertEqual(inline.stdout, "hello world\n", inline.stderr)
    }

    func testCurlAllowsConfiguredHTTPAndBlocksRedirectOutsideAllowlist() async {
        _ = URLProtocol.registerClass(RedirectTestURLProtocol.self)
        defer { URLProtocol.unregisterClass(RedirectTestURLProtocol.self) }
        let bash = Bash(options: .init(allowedURLPrefixes: ["https://redirect.justbash.invalid/"]))
        let allowed = await bash.exec("curl https://redirect.justbash.invalid/allowed", options: .init(allowNetwork: true))
        XCTAssertEqual(allowed.stdout, "allowed-body\n", allowed.stderr)
        let redirect = await bash.exec("curl https://redirect.justbash.invalid/redirect")
        XCTAssertNotEqual(redirect.exitCode, 0)
        XCTAssertTrue(redirect.stderr.contains("redirect URL not in allow-list"), redirect.stderr)
        XCTAssertFalse(redirect.stdout.contains("escaped"))
    }
}

private final class RedirectTestURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        ["redirect.justbash.invalid", "blocked.justbash.invalid"].contains(request.url?.host ?? "")
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        if url.path == "/redirect" {
            let target = URL(string: "https://blocked.justbash.invalid/escaped")!
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: ["Location": target.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        } else {
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [:])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data((url.path == "/allowed" ? "allowed-body" : "escaped").utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}
