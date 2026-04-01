import XCTest
@testable import JustBash

final class BashStateTests: XCTestCase {
    func testFilesystemPersistsAcrossExecsButEnvDoesNot() async {
        let bash = Bash()
        _ = await bash.exec("echo hi > /tmp/hello.txt")
        let first = await bash.exec("cat /tmp/hello.txt")
        XCTAssertEqual(first.stdout, "hi\n")

        _ = await bash.exec("export FOO=bar; echo ok")
        let second = await bash.exec("printenv FOO")
        XCTAssertEqual(second.exitCode, 1)
    }

    func testCdOnlyAffectsCurrentExec() async {
        let bash = Bash()
        let first = await bash.exec("mkdir -p /tmp/work; cd /tmp/work; pwd")
        XCTAssertEqual(first.stdout, "/tmp/work\n")
        let second = await bash.exec("pwd")
        XCTAssertEqual(second.stdout, "/home/user\n")
    }
}
