import XCTest
@testable import JustBash
@testable import JustBashJavaScript

final class JsExecBootstrapTests: XCTestCase {
    func testBootstrapGlobalVisibleToUserCode() async {
        let bash = Bash(options: .init(embeddedRuntimes: [
            JavaScriptRuntime(options: BashJavaScriptOptions(bootstrap: "globalThis.APP_NAME = 'demo';"))
        ]))
        let result = await bash.exec("js-exec -c 'console.log(globalThis.APP_NAME)'")
        XCTAssertEqual(result.exitCode, 0, "stderr: \(result.stderr)")
        XCTAssertEqual(result.stdout, "demo\n")
    }

    func testAddonModuleResolvableViaRequire() async {
        struct Addon: JavaScriptModule {
            var name: String { "greeter" }
            var source: String { "module.exports = { greet: function(n) { return 'hi ' + n; } };" }
        }
        let bash = Bash(options: .init(embeddedRuntimes: [
            JavaScriptRuntime(options: BashJavaScriptOptions(addonModules: [Addon()]))
        ]))
        let result = await bash.exec(#"js-exec -c 'console.log(require("greeter").greet("world"))'"#)
        XCTAssertEqual(result.exitCode, 0, "stderr: \(result.stderr)")
        XCTAssertEqual(result.stdout, "hi world\n")
    }

    func testMissingModuleThrowsModuleNotFound() async {
        let bash = Bash(options: .init(embeddedRuntimes: [JavaScriptRuntime()]))
        let result = await bash.exec(#"js-exec -c 'try { require("does-not-exist") } catch (e) { console.log(e.code) }'"#)
        XCTAssertEqual(result.exitCode, 0, "stderr: \(result.stderr)")
        XCTAssertEqual(result.stdout, "MODULE_NOT_FOUND\n")
    }
}
