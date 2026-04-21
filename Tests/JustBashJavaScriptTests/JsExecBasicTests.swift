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
