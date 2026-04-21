import XCTest
@testable import JustBash
@testable import JustBashJavaScript

final class JsExecExecTests: XCTestCase {
    func testExecSyncRoundTripThroughBash() async {
        let bash = Bash(options: .init(embeddedRuntimes: [JavaScriptRuntime()]))
        let result = await bash.exec(#"js-exec -c 'var cp = require("child_process"); var out = cp.execSync("echo hi"); console.log(out.trim ? out.trim() : String(out))'"#)
        XCTAssertEqual(result.exitCode, 0, "stderr: \(result.stderr)")
        XCTAssertTrue(result.stdout.contains("hi"))
    }

    func testExecSyncFailureThrows() async {
        let bash = Bash(options: .init(embeddedRuntimes: [JavaScriptRuntime()]))
        let result = await bash.exec(#"js-exec -c 'try { require("child_process").execSync("false") } catch (e) { console.log("status=" + e.status) }'"#)
        XCTAssertEqual(result.exitCode, 0, "stderr: \(result.stderr)")
        XCTAssertTrue(result.stdout.contains("status="))
    }

    func testSpawnSyncReturnsResultObject() async {
        let bash = Bash(options: .init(embeddedRuntimes: [JavaScriptRuntime()]))
        let result = await bash.exec(#"js-exec -c 'var r = require("child_process").spawnSync("echo", ["hello"]); console.log(r.status, r.stdout.trim ? r.stdout.trim() : String(r.stdout))'"#)
        XCTAssertEqual(result.exitCode, 0, "stderr: \(result.stderr)")
        XCTAssertTrue(result.stdout.contains("0 hello"))
    }
}
