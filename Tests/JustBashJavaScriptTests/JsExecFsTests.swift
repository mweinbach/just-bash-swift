import XCTest
@testable import JustBash
@testable import JustBashJavaScript

final class JsExecFsTests: XCTestCase {
    func testReadFileSyncUtf8() async {
        let bash = Bash(options: .init(
            files: ["/data/greeting.txt": "hello world"],
            embeddedRuntimes: [JavaScriptRuntime()]
        ))
        let result = await bash.exec(#"js-exec -c 'console.log(require("fs").readFileSync("/data/greeting.txt", "utf8"))'"#)
        XCTAssertEqual(result.exitCode, 0, "stderr: \(result.stderr)")
        XCTAssertEqual(result.stdout, "hello world\n")
    }

    func testWriteFileSyncRoundTrip() async {
        let bash = Bash(options: .init(embeddedRuntimes: [JavaScriptRuntime()]))
        let writeResult = await bash.exec(#"js-exec -c 'require("fs").writeFileSync("/tmp/out.txt", "swiftly")'"#)
        XCTAssertEqual(writeResult.exitCode, 0, "stderr: \(writeResult.stderr)")
        let readBack = await bash.exec("cat /tmp/out.txt")
        XCTAssertEqual(readBack.exitCode, 0)
        XCTAssertEqual(readBack.stdout, "swiftly")
    }

    func testReaddirSync() async {
        let bash = Bash(options: .init(
            files: ["/data/a.txt": "1", "/data/b.txt": "2"],
            embeddedRuntimes: [JavaScriptRuntime()]
        ))
        let result = await bash.exec(#"js-exec -c 'console.log(require("fs").readdirSync("/data").sort().join(","))'"#)
        XCTAssertEqual(result.exitCode, 0, "stderr: \(result.stderr)")
        XCTAssertEqual(result.stdout, "a.txt,b.txt\n")
    }

    func testExistsSyncTrueAndFalse() async {
        let bash = Bash(options: .init(
            files: ["/exists.txt": "x"],
            embeddedRuntimes: [JavaScriptRuntime()]
        ))
        let result = await bash.exec(#"js-exec -c 'var fs = require("fs"); console.log(fs.existsSync("/exists.txt"), fs.existsSync("/missing.txt"))'"#)
        XCTAssertEqual(result.exitCode, 0, "stderr: \(result.stderr)")
        XCTAssertEqual(result.stdout, "true false\n")
    }

    func testStatSyncReportsFileType() async {
        let bash = Bash(options: .init(
            files: ["/data/file.txt": "abc"],
            embeddedRuntimes: [JavaScriptRuntime()]
        ))
        let result = await bash.exec(#"js-exec -c 'var s = require("fs").statSync("/data/file.txt"); console.log(s.isFile(), s.isDirectory(), s.size)'"#)
        XCTAssertEqual(result.exitCode, 0, "stderr: \(result.stderr)")
        XCTAssertEqual(result.stdout, "true false 3\n")
    }

    func testMissingFileMapsToENOENT() async {
        let bash = Bash(options: .init(embeddedRuntimes: [JavaScriptRuntime()]))
        let result = await bash.exec(#"js-exec -c 'try { require("fs").readFileSync("/nope") } catch (e) { console.log(e.code) }'"#)
        XCTAssertEqual(result.exitCode, 0, "stderr: \(result.stderr)")
        XCTAssertEqual(result.stdout, "ENOENT\n")
    }

    func testMkdirSyncRecursive() async {
        let bash = Bash(options: .init(embeddedRuntimes: [JavaScriptRuntime()]))
        let result = await bash.exec(#"js-exec -c 'require("fs").mkdirSync("/a/b/c", {recursive: true}); console.log("ok")'"#)
        XCTAssertEqual(result.exitCode, 0, "stderr: \(result.stderr)")
        XCTAssertEqual(result.stdout, "ok\n")
        let exists = await bash.exec("test -d /a/b/c && echo yes || echo no")
        XCTAssertEqual(exists.stdout, "yes\n")
    }
}
