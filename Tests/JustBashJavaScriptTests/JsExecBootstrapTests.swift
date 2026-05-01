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

    func testNodeBuiltinSpecifierAliasesResolve() async {
        let bash = Bash(options: .init(
            files: ["/data/greeting.txt": "hello node"],
            embeddedRuntimes: [JavaScriptRuntime()]
        ))
        let result = await bash.exec(#"js-exec -m -c 'const fs = require("node:fs"); const fsp = require("node:fs/promises"); const path = require("node:path"); const cp = require("node:child_process"); const module = require("node:module"); const req = module.createRequire("file:///workspace/package.json"); console.log(fs === require("fs")); console.log(await fsp.readFile("/data/greeting.txt", "utf8")); console.log(path.join("/a", "b")); console.log(typeof cp.spawnSync); console.log(req.resolve("node:fs"));'"#)
        XCTAssertEqual(result.exitCode, 0, "stderr: \(result.stderr)")
        XCTAssertEqual(result.stdout, "true\nhello node\n/a/b\nfunction\nnode:fs\n")
    }

    func testModuleModeHandlesStaticImportsAndRelativeExports() async {
        let bash = Bash(options: .init(
            files: [
                "/data/input.txt": "hello esm",
                "/scripts/helpers.mjs": """
                import path from "node:path";
                export const fileName = path.basename("/tmp/report.txt");
                export function shout(value) {
                    return value.toUpperCase();
                }
                """,
                "/scripts/main.mjs": """
                import fs from "node:fs/promises";
                import { fileName, shout } from "./helpers.mjs";
                const text = await fs.readFile("/data/input.txt", "utf8");
                console.log(fileName);
                console.log(shout(text));
                """
            ],
            embeddedRuntimes: [JavaScriptRuntime()]
        ))

        let result = await bash.exec("js-exec /scripts/main.mjs")

        XCTAssertEqual(result.exitCode, 0, "stderr: \(result.stderr)")
        XCTAssertEqual(result.stdout, "report.txt\nHELLO ESM\n")
    }

    func testModuleModeHandlesDynamicImports() async {
        let bash = Bash(options: .init(
            files: [
                "/scripts/dynamic.mjs": #"export const answer = 42;"#,
                "/scripts/main.mjs": """
                const local = await import("./dynamic.mjs");
                const viaURL = await import("file:///scripts/dynamic.mjs");
                console.log(local.answer);
                console.log(viaURL.answer);
                """
            ],
            embeddedRuntimes: [JavaScriptRuntime()]
        ))

        let result = await bash.exec("js-exec /scripts/main.mjs")

        XCTAssertEqual(result.exitCode, 0, "stderr: \(result.stderr)")
        XCTAssertEqual(result.stdout, "42\n42\n")
    }
}
