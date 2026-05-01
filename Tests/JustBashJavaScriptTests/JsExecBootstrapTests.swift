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

    func testModuleModeResolvesNodeModulesPackageExports() async {
        let bash = Bash(options: .init(
            files: [
                "/workspace/node_modules/@oai/artifact-tool/package.json": """
                {
                  "name": "@oai/artifact-tool",
                  "type": "module",
                  "exports": {
                    ".": "./dist/artifact_tool.mjs",
                    "./presentation-jsx": "./dist/presentation-jsx/index.mjs"
                  }
                }
                """,
                "/workspace/node_modules/@oai/artifact-tool/dist/artifact_tool.mjs": """
                import { createRequire as __createRequire } from "node:module"; const require = __createRequire(import.meta.url);
                export const runtimeName = "artifact-tool";
                export function resolveFs() {
                    return require.resolve("node:fs");
                }
                """,
                "/workspace/node_modules/@oai/artifact-tool/dist/presentation-jsx/index.mjs": """
                export default function jsx(type) {
                    return { type };
                }
                export const Fragment = "Fragment";
                """,
                "/workspace/scripts/main.mjs": """
                import { runtimeName, resolveFs } from "@oai/artifact-tool";
                import jsx, { Fragment } from "@oai/artifact-tool/presentation-jsx";
                const fresh = await import("@oai/artifact-tool");
                console.log(runtimeName);
                console.log(resolveFs());
                console.log(jsx("slide").type);
                console.log(Fragment);
                console.log(fresh.runtimeName);
                """
            ],
            embeddedRuntimes: [JavaScriptRuntime()]
        ))

        let result = await bash.exec("cd /workspace && js-exec scripts/main.mjs")

        XCTAssertEqual(result.exitCode, 0, "stderr: \(result.stderr)")
        XCTAssertEqual(result.stdout, "artifact-tool\nnode:fs\nslide\nFragment\nartifact-tool\n")
    }

    func testModuleModeHandlesMinifiedImportsAndExportLists() async {
        let bash = Bash(options: .init(
            files: [
                "/data/input.txt": "from fs",
                "/workspace/node_modules/minified/package.json": """
                {
                  "name": "minified",
                  "type": "module",
                  "exports": {
                    ".": "./dist/index.mjs"
                  }
                }
                """,
                "/workspace/node_modules/minified/dist/dep.mjs": """
                export default "defaulted";
                export const value = "named";
                """,
                "/workspace/node_modules/minified/dist/index.mjs": """
                const text = "literal import nope from 'x'; export{nope as nope};";import{join as pJoin}from"node:path";import fsPromises from"node:fs/promises";import defaultThing,{value as namedValue}from"./dep.mjs";async function readLoaded(){ return await fsPromises.readFile("/data/input.txt", "utf8"); }export{pJoin as joinPath,namedValue as renamed,defaultThing,readLoaded,text};
                """,
                "/workspace/scripts/main.mjs": """
                import { defaultThing, joinPath, readLoaded, renamed, text } from "minified";
                console.log(defaultThing);
                console.log(renamed);
                console.log(joinPath("/a", "b"));
                console.log(await readLoaded());
                console.log(text.includes("literal import nope"));
                """
            ],
            embeddedRuntimes: [JavaScriptRuntime()]
        ))

        let result = await bash.exec("cd /workspace && js-exec scripts/main.mjs")

        XCTAssertEqual(result.exitCode, 0, "stderr: \(result.stderr)")
        XCTAssertEqual(result.stdout, "defaulted\nnamed\n/a/b\nfrom fs\ntrue\n")
    }

    func testModuleModeResolvesNestedPackageExportConditions() async {
        let bash = Bash(options: .init(
            files: [
                "/workspace/node_modules/conditional/package.json": """
                {
                  "name": "conditional",
                  "type": "module",
                  "exports": {
                    ".": {
                      "node": {
                        "import": "./node-entry.mjs",
                        "require": "./node-entry.cjs"
                      },
                      "browser": "./browser-entry.mjs"
                    }
                  }
                }
                """,
                "/workspace/node_modules/conditional/node-entry.mjs": #"export const target = "node-import";"#,
                "/workspace/node_modules/conditional/browser-entry.mjs": #"export const target = "browser";"#,
                "/workspace/scripts/main.mjs": """
                import { target } from "conditional";
                console.log(target);
                """
            ],
            embeddedRuntimes: [JavaScriptRuntime()]
        ))

        let result = await bash.exec("cd /workspace && js-exec scripts/main.mjs")

        XCTAssertEqual(result.exitCode, 0, "stderr: \(result.stderr)")
        XCTAssertEqual(result.stdout, "node-import\n")
    }
}
