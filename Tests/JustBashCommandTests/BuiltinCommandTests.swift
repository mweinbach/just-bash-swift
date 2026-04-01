import XCTest
@testable import JustBash

final class BuiltinCommandTests: XCTestCase {
    func testPipelineAndGrep() async {
        let bash = Bash()
        let result = await bash.exec("printf 'alpha\\nbeta\\n' | grep beta")
        XCTAssertEqual(result.stdout, "beta\n")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testHeadTailAndWc() async {
        let bash = Bash(options: .init(files: ["/tmp/data.txt": "a\nb\nc\n"]))
        let head = await bash.exec("head -n 2 /tmp/data.txt")
        XCTAssertEqual(head.stdout, "a\nb\n")
        let wc = await bash.exec("wc -l /tmp/data.txt")
        XCTAssertEqual(wc.stdout, "3 /tmp/data.txt\n")
    }

    func testSortAndUniq() async {
        let bash = Bash()
        let result = await bash.exec("printf 'c\\na\\nb\\na\\n' | sort | uniq")
        XCTAssertEqual(result.stdout, "a\nb\nc\n")
    }

    func testTr() async {
        let bash = Bash()
        let result = await bash.exec("echo hello | tr a-z A-Z")
        XCTAssertEqual(result.stdout, "HELLO\n")
    }

    func testCut() async {
        let bash = Bash()
        let result = await bash.exec("echo 'a:b:c' | cut -d: -f2")
        XCTAssertEqual(result.stdout, "b\n")
    }

    func testSeq() async {
        let bash = Bash()
        let result = await bash.exec("seq 3")
        XCTAssertEqual(result.stdout, "1\n2\n3\n")
    }

    func testBasenameAndDirname() async {
        let bash = Bash()
        let bn = await bash.exec("basename /path/to/file.txt")
        XCTAssertEqual(bn.stdout, "file.txt\n")
        let dn = await bash.exec("dirname /path/to/file.txt")
        XCTAssertEqual(dn.stdout, "/path/to\n")
    }

    func testSed() async {
        let bash = Bash()
        let result = await bash.exec("echo 'hello world' | sed 's/world/bash/'")
        XCTAssertEqual(result.stdout, "hello bash\n")
    }

    func testTee() async {
        let bash = Bash()
        let result = await bash.exec("echo hello | tee /tmp/tee_out.txt")
        XCTAssertEqual(result.stdout, "hello\n")
        let check = await bash.exec("cat /tmp/tee_out.txt")
        XCTAssertEqual(check.stdout, "hello\n")
    }

    func testDate() async {
        let bash = Bash()
        let result = await bash.exec("date +%Y")
        XCTAssertFalse(result.stdout.isEmpty)
        XCTAssertEqual(result.exitCode, 0)
    }
}
