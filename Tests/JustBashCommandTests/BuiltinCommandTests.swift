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

    func testBase64AndExpr() async {
        let bash = Bash()
        let encoded = await bash.exec("echo hello | base64")
        XCTAssertEqual(encoded.stdout, "aGVsbG8K\n")

        let decoded = await bash.exec("echo aGVsbG8= | base64 -d")
        XCTAssertEqual(decoded.stdout, "hello")

        let expr = await bash.exec("expr 7 + 5")
        XCTAssertEqual(expr.stdout, "12\n")
    }

    func testChecksumsAndWhoami() async {
        let bash = Bash(options: .init(files: ["/tmp/data.txt": "abc"], env: ["USER": "agent"]))
        let md5 = await bash.exec("md5sum /tmp/data.txt")
        XCTAssertTrue(md5.stdout.hasPrefix("900150983cd24fb0d6963f7d28e17f72  /tmp/data.txt"))

        let sha256 = await bash.exec("sha256sum /tmp/data.txt")
        XCTAssertTrue(sha256.stdout.hasPrefix("ba7816bf8f01cfea414140de5dae2223"))

        let whoami = await bash.exec("whoami")
        XCTAssertEqual(whoami.stdout, "agent\n")
    }

    func testRmdirTreeAndFile() async {
        let bash = Bash(options: .init(files: ["/tmp/demo.txt": "hello"]))
        _ = await bash.exec("mkdir -p /tmp/dir/sub")
        let tree = await bash.exec("tree /tmp")
        XCTAssertTrue(tree.stdout.contains("demo.txt"))
        XCTAssertTrue(tree.stdout.contains("dir"))

        let file = await bash.exec("file /tmp/demo.txt /tmp/dir")
        XCTAssertTrue(file.stdout.contains("/tmp/demo.txt: ASCII text"))
        XCTAssertTrue(file.stdout.contains("/tmp/dir: directory"))

        let rmdir = await bash.exec("rmdir /tmp/dir/sub")
        XCTAssertEqual(rmdir.exitCode, 0)
    }

    func testStringsTacAndOd() async {
        let bash = Bash(options: .init(files: ["/tmp/mixed.txt": "abc\u{0001}printable\u{0002}xyz\none\ntwo\n"]))
        let strings = await bash.exec("strings /tmp/mixed.txt")
        XCTAssertTrue(strings.stdout.contains("printable"))

        let tac = await bash.exec("printf 'one\\ntwo\\n' | tac")
        XCTAssertEqual(tac.stdout, "two\none\n")

        let od = await bash.exec("printf 'AB' | od")
        XCTAssertTrue(od.stdout.contains("41 42"))
    }

    func testSplitAndJoin() async {
        let bash = Bash(options: .init(files: [
            "/tmp/left.txt": "a 1\nb 2\n",
            "/tmp/right.txt": "a x\nb y\n"
        ]))
        let split = await bash.exec("printf 'l1\\nl2\\nl3\\n' | split -l 2 - /tmp/chunk")
        XCTAssertEqual(split.exitCode, 0)
        let first = await bash.exec("cat /tmp/chunkaa")
        let second = await bash.exec("cat /tmp/chunkab")
        XCTAssertEqual(first.stdout, "l1\nl2\n")
        XCTAssertEqual(second.stdout, "l3\n")

        let join = await bash.exec("join /tmp/left.txt /tmp/right.txt")
        XCTAssertEqual(join.stdout, "a 1 x\nb 2 y\n")
    }

    func testSearchAliasesAndClearHelpHistory() async {
        let bash = Bash(options: .init(files: [
            "/tmp/a.txt": "alpha\nbeta\n",
            "/tmp/b.txt": "beta\n"
        ]))
        let fgrep = await bash.exec("printf 'alpha\\nbeta\\n' | fgrep beta")
        XCTAssertEqual(fgrep.stdout, "beta\n")

        let egrep = await bash.exec("printf 'abc\\n123\\n' | egrep '[0-9]+'")
        XCTAssertEqual(egrep.stdout, "123\n")

        let rg = await bash.exec("rg beta /tmp")
        XCTAssertTrue(rg.stdout.contains("/tmp/a.txt:beta"))

        let clear = await bash.exec("clear")
        XCTAssertEqual(clear.exitCode, 0)

        let help = await bash.exec("help")
        XCTAssertTrue(help.stdout.contains("Supported utility commands"))

        let history = await bash.exec("history")
        XCTAssertEqual(history.exitCode, 0)
    }

    func testShellRunnerAndTimeoutTime() async {
        let bash = Bash()
        let sh = await bash.exec("sh echo hi")
        XCTAssertEqual(sh.stdout, "hi\n")

        let timeout = await bash.exec("timeout 5 echo later")
        XCTAssertEqual(timeout.stdout, "later\n")

        let timed = await bash.exec("time echo now")
        XCTAssertEqual(timed.stdout, "now\n")
        XCTAssertTrue(timed.stderr.contains("real 0.000"))
    }

    func testGzipGunzipAndZcat() async {
        let bash = Bash(options: .init(files: ["/tmp/data.txt": "Hello, World!"]))

        let gzip = await bash.exec("gzip /tmp/data.txt")
        XCTAssertEqual(gzip.exitCode, 0)
        let ls = await bash.exec("ls /tmp")
        XCTAssertFalse(ls.stdout.contains("data.txt\n"))
        XCTAssertTrue(ls.stdout.contains("data.txt.gz\n"))

        let zcat = await bash.exec("zcat /tmp/data.txt.gz")
        XCTAssertEqual(zcat.stdout, "Hello, World!")

        let gunzip = await bash.exec("gunzip /tmp/data.txt.gz")
        XCTAssertEqual(gunzip.exitCode, 0)
        let restored = await bash.exec("cat /tmp/data.txt")
        XCTAssertEqual(restored.stdout, "Hello, World!")
    }

    func testGzipStdoutAndKeepModes() async {
        let bash = Bash(options: .init(files: ["/tmp/data.txt": "swift gzip"]))

        let stdoutGzip = await bash.exec("gzip -c /tmp/data.txt | gunzip -c")
        XCTAssertEqual(stdoutGzip.stdout, "swift gzip")

        let keep = await bash.exec("gzip -k /tmp/data.txt")
        XCTAssertEqual(keep.exitCode, 0)
        let ls = await bash.exec("ls /tmp")
        XCTAssertTrue(ls.stdout.contains("data.txt\n"))
        XCTAssertTrue(ls.stdout.contains("data.txt.gz\n"))
    }
}
