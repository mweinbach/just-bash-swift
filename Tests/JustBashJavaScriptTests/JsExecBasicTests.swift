import XCTest
@testable import JustBash
@testable import JustBashJavaScript

final class JsExecBasicTests: XCTestCase {
    func testPerExecutionNetworkDenialReachesFetchAndChildProcess() async {
        let source = #"""
        try { await fetch('https://example.invalid/'); throw new Error('network escaped'); }
        catch (error) { if (!error.message.includes('not in allow-list')) throw error; }
        const cp = require('node:child_process');
        try { cp.execSync('curl https://example.invalid/'); throw new Error('subshell escaped'); }
        catch (error) { if (!String(error.stderr).includes('not in allow-list')) throw error; }
        console.log('denied');
        """#
        let bash = Bash(options: .init(files: ["/network.mjs": source], allowedURLPrefixes: ["https://"], embeddedRuntimes: [JavaScriptRuntime()]))
        let result = await bash.exec("js-exec /network.mjs", options: .init(allowNetwork: false))
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(result.stdout, "denied\n")
    }

    func testFetchLocalURLsUseVirtualFilesystemAndPreserveBinary() async throws {
        let physical = FileManager.default.temporaryDirectory.appendingPathComponent("justbash-fetch-\(UUID().uuidString).txt")
        try Data("host-only-secret".utf8).write(to: physical)
        defer { try? FileManager.default.removeItem(at: physical) }
        let source = """
        const response = await fetch('\(physical.absoluteString)');
        if (await response.text() !== 'virtual-content') throw new Error('wrong filesystem');
        require('node:fs').unlinkSync('\(physical.path)');
        try { await fetch('\(physical.absoluteString)'); throw new Error('host file escaped'); }
        catch (error) { if (error.message.includes('host file escaped')) throw error; }
        const binary = await fetch('data:application/octet-stream;base64,AP9B');
        const bytes = new Uint8Array(await binary.arrayBuffer());
        if (String(bytes) !== '0,255,65') throw new Error('binary corrupted');
        console.log('local');
        """
        let bash = Bash(options: .init(files: [physical.path: "virtual-content", "/local.mjs": source], embeddedRuntimes: [JavaScriptRuntime()]))
        let result = await bash.exec("js-exec /local.mjs", options: .init(allowNetwork: false))
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(result.stdout, "local\n")
    }

    func testBase64PaddingPreservesBinaryArtifacts() async {
        let bash = Bash(options: .init(embeddedRuntimes: [JavaScriptRuntime()]))
        let result = await bash.exec(#"js-exec -c 'for (const text of ["Zg==", "Zm8=", "Zm9v", "AP8="]) { if (Buffer.from(text, "base64").toString("base64") !== text) throw new Error("base64 padding: " + text); } console.log("ok");'"#)
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(result.stdout, "ok\n")
    }

    func testHardDeadlinePolicyRejectsBeforeExecutingUnboundedCode() async {
        let bash = Bash(options: .init(embeddedRuntimes: [JavaScriptRuntime(options: .init(executionPolicy: .requirePreemptible))]))
        let result = await bash.exec("js-exec -c 'while (true) {}'")
        XCTAssertEqual(result.exitCode, 2)
        XCTAssertTrue(result.stderr.contains("preemptible worker"))
        let next = await bash.exec("echo still-responsive")
        XCTAssertEqual(next.stdout, "still-responsive\n")
    }

    func testFiniteSynchronousOverrunReportsDeadline() async {
        let bash = Bash(options: .init(embeddedRuntimes: [JavaScriptRuntime(options: .init(defaultTimeoutMs: 1))]))
        let result = await bash.exec("js-exec -c 'const end = Date.now() + 30; while (Date.now() < end) {}'")
        XCTAssertEqual(result.exitCode, 124, result.stderr)
    }

    func testCancellationStopsPendingJavaScriptAndFollowingShellCommand() async throws {
        let bash = Bash(options: .init(embeddedRuntimes: [JavaScriptRuntime()]))
        let task = Task { await bash.exec("js-exec -m -c 'await new Promise(() => {})'; echo must-not-run") }
        try await Task.sleep(for: .milliseconds(30))
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result.exitCode, 130, result.stderr)
        XCTAssertFalse(result.stdout.contains("must-not-run"))
        let next = await bash.exec("echo ok")
        XCTAssertEqual(next.stdout, "ok\n")
    }

    func testConsoleLogStdout() async {
        let bash = Bash(options: .init(embeddedRuntimes: [JavaScriptRuntime()]))
        let result = await bash.exec("js-exec -c 'console.log(1 + 2)'")
        XCTAssertEqual(result.exitCode, 0, "stderr: \(result.stderr)")
        XCTAssertEqual(result.stdout, "3\n")
    }

    func testConsoleErrorRoutesToStderr() async {
        let bash = Bash(options: .init(embeddedRuntimes: [JavaScriptRuntime()]))
        let result = await bash.exec("js-exec -c 'console.error(\"oops\")'")
        XCTAssertEqual(result.exitCode, 0, "stderr: \(result.stderr)")
        XCTAssertEqual(result.stdout, "")
        XCTAssertTrue(result.stderr.contains("oops"))
    }

    func testJsonRoundTrip() async {
        let bash = Bash(options: .init(embeddedRuntimes: [JavaScriptRuntime()]))
        let result = await bash.exec(#"js-exec -c 'console.log(JSON.stringify({a:1,b:[2,3]}))'"#)
        XCTAssertEqual(result.exitCode, 0, "stderr: \(result.stderr)")
        XCTAssertEqual(result.stdout, "{\"a\":1,\"b\":[2,3]}\n")
    }

    func testBufferSupportsNodeCompatTypedArrayAndLatin1Cases() async {
        let bash = Bash(options: .init(embeddedRuntimes: [JavaScriptRuntime()]))
        let result = await bash.exec(
            #"js-exec -c 'const source = Uint8Array.from([65, 0, 255]).buffer; const buf = Buffer.from(source); if (!Buffer.isBuffer(buf)) throw new Error("not a buffer"); if (buf.toString("latin1").charCodeAt(2) !== 255) throw new Error("latin1 failed"); const target = Buffer.alloc(4); if (buf.copy(target, 1, 0, 3) !== 3 || target[3] !== 255) throw new Error("copy failed"); const joined = Buffer.concat([Buffer.from("AB", "ascii"), Buffer.from([67])]); if (joined.toString("ascii") !== "ABC") throw new Error("concat failed"); console.log(Buffer.from("A" + String.fromCharCode(255), "latin1")[1]);'"#
        )
        XCTAssertEqual(result.exitCode, 0, "stderr: \(result.stderr)")
        XCTAssertEqual(result.stdout, "255\n")
    }

    func testProcessExitCodePropagates() async {
        let bash = Bash(options: .init(embeddedRuntimes: [JavaScriptRuntime()]))
        let result = await bash.exec("js-exec -c 'process.exit(7)'")
        XCTAssertEqual(result.exitCode, 7, "stderr: \(result.stderr)")
    }

    func testProcessArgvIncludesScriptArgs() async {
        let bash = Bash(options: .init(embeddedRuntimes: [JavaScriptRuntime()]))
        let result = await bash.exec("js-exec -c 'console.log(process.argv.slice(1).join(\",\"))' alpha beta")
        XCTAssertEqual(result.exitCode, 0, "stderr: \(result.stderr)")
        XCTAssertEqual(result.stdout, "alpha,beta\n")
    }

    func testScriptArgsMayStartWithDashes() async {
        let bash = Bash(options: .init(
            files: ["/scripts/args.mjs": "console.log(process.argv.slice(2).join('|'));"],
            embeddedRuntimes: [JavaScriptRuntime()]
        ))
        let result = await bash.exec("js-exec /scripts/args.mjs --output report.png --scale 0.5")
        XCTAssertEqual(result.exitCode, 0, "stderr: \(result.stderr)")
        XCTAssertEqual(result.stdout, "--output|report.png|--scale|0.5\n")
    }

    func testScriptFileShebangIsIgnored() async {
        let bash = Bash(options: .init(
            files: ["/scripts/shebang.mjs": "#!/usr/bin/env node\nconsole.log('ok');"],
            embeddedRuntimes: [JavaScriptRuntime()]
        ))
        let result = await bash.exec("js-exec /scripts/shebang.mjs")
        XCTAssertEqual(result.exitCode, 0, "stderr: \(result.stderr)")
        XCTAssertEqual(result.stdout, "ok\n")
    }

    func testStdinAsScriptSource() async {
        let bash = Bash(options: .init(embeddedRuntimes: [JavaScriptRuntime()]))
        let result = await bash.exec("echo 'console.log(\"from stdin\")' | js-exec")
        XCTAssertEqual(result.exitCode, 0, "stderr: \(result.stderr)")
        XCTAssertEqual(result.stdout, "from stdin\n")
    }

    func testUnknownFlagFails() async {
        let bash = Bash(options: .init(embeddedRuntimes: [JavaScriptRuntime()]))
        let result = await bash.exec("js-exec --bogus")
        XCTAssertEqual(result.exitCode, 2)
        XCTAssertTrue(result.stderr.contains("unknown option"))
    }

    func testVersionFlag() async {
        let bash = Bash(options: .init(embeddedRuntimes: [JavaScriptRuntime()]))
        let result = await bash.exec("js-exec -V")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("JavaScriptCore"))
    }

    func testNoRuntimeRegisteredMeansNoCommand() async {
        let bash = Bash()
        let result = await bash.exec("js-exec -c 'console.log(1)'")
        XCTAssertNotEqual(result.exitCode, 0, "expected js-exec to be unavailable without runtime")
    }
}
