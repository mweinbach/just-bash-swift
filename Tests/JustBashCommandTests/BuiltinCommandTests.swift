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

    func testSQLite3BasicAndJsonModes() async {
        let bash = Bash()

        let basic = await bash.exec(#"sqlite3 :memory: "CREATE TABLE t(x INT, y TEXT); INSERT INTO t VALUES(1,'a'),(2,'b'); SELECT * FROM t""#)
        XCTAssertEqual(basic.stdout, "1|a\n2|b\n")

        let json = await bash.exec(#"sqlite3 -json :memory: "CREATE TABLE t(x, y); INSERT INTO t VALUES(NULL, 42); SELECT * FROM t""#)
        XCTAssertEqual(json.stdout, #"[{"x":null,"y":42}]"# + "\n")
    }

    func testSQLite3StdinAndFilePersistence() async {
        let bash = Bash()

        let stdinRun = await bash.exec(#"echo "CREATE TABLE t(x); INSERT INTO t VALUES(42); SELECT * FROM t" | sqlite3 :memory:"#)
        XCTAssertEqual(stdinRun.stdout, "42\n")

        _ = await bash.exec(#"sqlite3 /tmp/test.db "CREATE TABLE users(id INT, name TEXT); INSERT INTO users VALUES(1,'alice')""#)
        let persisted = await bash.exec(#"sqlite3 /tmp/test.db "SELECT * FROM users""#)
        XCTAssertEqual(persisted.stdout, "1|alice\n")
    }

    func testSQLite3HelpAndErrors() async {
        let bash = Bash()

        let help = await bash.exec("sqlite3 --help")
        XCTAssertTrue(help.stdout.contains("sqlite3 DATABASE [SQL]"))

        let missing = await bash.exec("sqlite3")
        XCTAssertEqual(missing.exitCode, 1)
        XCTAssertEqual(missing.stderr, "sqlite3: missing database argument\n")

        let unknown = await bash.exec(#"sqlite3 -unknown :memory: "SELECT 1""#)
        XCTAssertEqual(unknown.exitCode, 1)
        XCTAssertEqual(unknown.stderr, "sqlite3: Error: unknown option: -unknown\nUse -help for a list of options.\n")

        let syntax = await bash.exec(#"sqlite3 :memory: "SELEC * FROM nope""#)
        XCTAssertEqual(syntax.exitCode, 0)
        XCTAssertTrue(syntax.stdout.contains("Error:"))
    }

    func testTarCreateListAndExtract() async {
        let bash = Bash(options: .init(files: ["/tmp/hello.txt": "Hello, World!\n"]))

        let create = await bash.exec("tar -cf /tmp/archive.tar /tmp/hello.txt")
        XCTAssertEqual(create.exitCode, 0)

        let list = await bash.exec("tar -tf /tmp/archive.tar")
        XCTAssertEqual(list.stdout, "tmp/hello.txt\n")

        _ = await bash.exec("rm /tmp/hello.txt")
        let extract = await bash.exec("tar -xf /tmp/archive.tar -C /")
        XCTAssertEqual(extract.exitCode, 0)

        let cat = await bash.exec("cat /tmp/hello.txt")
        XCTAssertEqual(cat.stdout, "Hello, World!\n")
    }

    func testTarDirectoryAndStripComponents() async {
        let bash = Bash()

        _ = await bash.exec("mkdir -p /tmp/deep/path && echo 'Deep content' > /tmp/deep/path/file.txt")
        _ = await bash.exec("tar -cf /tmp/archive.tar /tmp/deep/path/file.txt")
        _ = await bash.exec("mkdir /tmp/out")
        let extract = await bash.exec("tar -xf /tmp/archive.tar -C /tmp/out --strip-components=3")
        XCTAssertEqual(extract.exitCode, 0)

        let cat = await bash.exec("cat /tmp/out/file.txt")
        XCTAssertEqual(cat.stdout, "Deep content\n")
    }

    func testTarGzipRoundTrip() async {
        let bash = Bash(options: .init(files: ["/tmp/compress.txt": "Compressed content\n"]))

        let create = await bash.exec("tar -czf /tmp/archive.tar.gz /tmp/compress.txt")
        XCTAssertEqual(create.exitCode, 0)

        let list = await bash.exec("tar -tzf /tmp/archive.tar.gz")
        XCTAssertEqual(list.stdout, "tmp/compress.txt\n")

        _ = await bash.exec("rm /tmp/compress.txt")
        let extract = await bash.exec("tar -xzf /tmp/archive.tar.gz -C /")
        XCTAssertEqual(extract.exitCode, 0)

        let cat = await bash.exec("cat /tmp/compress.txt")
        XCTAssertEqual(cat.stdout, "Compressed content\n")
    }

    func testCurlDataUrlAndOutputFile() async {
        let bash = Bash()

        let direct = await bash.exec("curl data:text/plain,hello%20world")
        XCTAssertEqual(direct.stdout, "hello world\n")

        let headed = await bash.exec("curl -I data:text/plain,hello")
        XCTAssertTrue(headed.stdout.contains("HTTP/1.1 200 OK"))

        let output = await bash.exec("curl -o /tmp/curl.txt data:text/plain,stored")
        XCTAssertEqual(output.exitCode, 0)
        let cat = await bash.exec("cat /tmp/curl.txt")
        XCTAssertEqual(cat.stdout, "stored")
    }

    func testHtmlToMarkdown() async {
        let bash = Bash()
        let result = await bash.exec(#"echo '<h1>Title</h1><p>Hello <strong>world</strong> <a href="https://example.com">link</a></p>' | html-to-markdown"#)
        XCTAssertEqual(result.stdout, "# Title\n\nHello **world** [link](https://example.com)\n")
    }
}
