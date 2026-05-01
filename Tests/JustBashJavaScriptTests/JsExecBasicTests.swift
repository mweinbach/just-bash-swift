import XCTest
@testable import JustBash
@testable import JustBashJavaScript

final class JsExecBasicTests: XCTestCase {
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
