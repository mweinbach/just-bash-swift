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

    func testJQBasicAccessAndIteration() async {
        let bash = Bash()

        let identity = await bash.exec(#"echo '{"a":1}' | jq '.'"#)
        XCTAssertTrue(identity.stdout.contains("\"a\""))
        XCTAssertTrue(identity.stdout.contains("1"))

        let field = await bash.exec(#"echo '{"name":"test"}' | jq '.name'"#)
        XCTAssertEqual(field.stdout, "\"test\"\n")

        let nested = await bash.exec(#"echo '{"a":{"b":"nested"}}' | jq '.a.b'"#)
        XCTAssertEqual(nested.stdout, "\"nested\"\n")

        let arrayIndex = await bash.exec(#"echo '["a","b","c"]' | jq '.[-1]'"#)
        XCTAssertEqual(arrayIndex.stdout, "\"c\"\n")

        let iter = await bash.exec(#"echo '[1,2,3]' | jq '.[]'"#)
        XCTAssertEqual(iter.stdout, "1\n2\n3\n")
    }

    func testJQPipesCommaAndCompactRawModes() async {
        let bash = Bash()

        let piped = await bash.exec(#"echo '{"data":{"value":42}}' | jq '.data | .value'"#)
        XCTAssertEqual(piped.stdout, "42\n")

        let comma = await bash.exec(#"echo '{"a":1,"b":2}' | jq '.a, .b'"#)
        XCTAssertEqual(comma.stdout, "1\n2\n")

        let compact = await bash.exec(#"echo '{"a":1}' | jq -c '.'"#)
        XCTAssertEqual(compact.stdout, "{\"a\":1}\n")

        let raw = await bash.exec(#"echo '{"name":"raw"}' | jq -r '.name'"#)
        XCTAssertEqual(raw.stdout, "raw\n")
    }

    func testJQSlicesSelectMapAndHas() async {
        let bash = Bash()

        let slice = await bash.exec(#"echo '[0,1,2,3,4]' | jq '.[1:4]'"#)
        XCTAssertTrue(slice.stdout.contains("1"))
        XCTAssertTrue(slice.stdout.contains("3"))

        let stringSlice = await bash.exec(#"echo '{"text":"hello"}' | jq '.text[1:4]'"#)
        XCTAssertEqual(stringSlice.stdout, "\"ell\"\n")

        let selected = await bash.exec(#"echo '[1,2,3,4,5]' | jq '[.[] | select(. > 3)]'"#)
        XCTAssertTrue(selected.stdout.contains("4"))
        XCTAssertTrue(selected.stdout.contains("5"))

        let mapped = await bash.exec(#"echo '[1,2,3]' | jq 'map(. * 2)'"#)
        XCTAssertTrue(mapped.stdout.contains("2"))
        XCTAssertTrue(mapped.stdout.contains("6"))

        let hasObject = await bash.exec(#"echo '{"foo":42}' | jq 'has("foo")'"#)
        XCTAssertEqual(hasObject.stdout, "true\n")

        let hasArray = await bash.exec(#"echo '[1,2,3]' | jq 'has(1)'"#)
        XCTAssertEqual(hasArray.stdout, "true\n")
    }

    func testJQContainsAnyAndAll() async {
        let bash = Bash()

        let containsArray = await bash.exec(#"echo '[1,2,3]' | jq 'contains([2])'"#)
        XCTAssertEqual(containsArray.stdout, "true\n")

        let containsObject = await bash.exec(#"echo '{"a":1,"b":2}' | jq 'contains({"a":1})'"#)
        XCTAssertEqual(containsObject.stdout, "true\n")

        let any = await bash.exec(#"echo '[1,2,3,4,5]' | jq 'any(. > 3)'"#)
        XCTAssertEqual(any.stdout, "true\n")

        let all = await bash.exec(#"echo '[1,2,3]' | jq 'all(. > 0)'"#)
        XCTAssertEqual(all.stdout, "true\n")
    }

    func testJQConditionals() async {
        let bash = Bash()

        let conditional = await bash.exec(#"echo '5' | jq 'if . > 10 then "big" elif . > 3 then "medium" else "small" end'"#)
        XCTAssertEqual(conditional.stdout, "\"medium\"\n")
    }

    func testJQOptionalAccess() async {
        let bash = Bash()

        let missing = await bash.exec(#"echo 'null' | jq '.foo?'"#)
        XCTAssertEqual(missing.stdout, "null\n")

        let present = await bash.exec(#"echo '{"foo":42}' | jq '.foo?'"#)
        XCTAssertEqual(present.stdout, "42\n")
    }

    func testJQVariablesAndObjectConstruction() async {
        let bash = Bash()

        let bound = await bash.exec(#"echo '5' | jq '. as $x | $x * $x'"#)
        XCTAssertEqual(bound.stdout, "25\n")

        let object = await bash.exec(#"echo '3' | jq -c '. as $n | {value: $n, doubled: ($n * 2)}'"#)
        XCTAssertEqual(object.stdout, #"{"value":3,"doubled":6}"# + "\n")
    }

    func testJQFunctionsLengthKeysAndAdd() async {
        let bash = Bash()

        let arrayLength = await bash.exec(#"echo '[1,2,3,4,5]' | jq 'length'"#)
        XCTAssertEqual(arrayLength.stdout, "5\n")

        let stringLength = await bash.exec(#"echo '"hello"' | jq 'length'"#)
        XCTAssertEqual(stringLength.stdout, "5\n")

        let objectLength = await bash.exec(#"echo '{"a":1,"b":2}' | jq 'length'"#)
        XCTAssertEqual(objectLength.stdout, "2\n")

        let keys = await bash.exec(#"echo '{"b":1,"a":2}' | jq 'keys'"#)
        XCTAssertTrue(keys.stdout.contains("\"a\""))
        XCTAssertTrue(keys.stdout.contains("\"b\""))

        let addNumbers = await bash.exec(#"echo '[1,2,3,4]' | jq 'add'"#)
        XCTAssertEqual(addNumbers.stdout, "10\n")

        let addStrings = await bash.exec(#"echo '["a","b","c"]' | jq 'add'"#)
        XCTAssertEqual(addStrings.stdout, "\"abc\"\n")
    }

    func testJQFunctionsTypeFirstLastReverseSortUniqueMinMax() async {
        let bash = Bash()

        let typeObject = await bash.exec(#"echo '{"a":1}' | jq 'type'"#)
        XCTAssertEqual(typeObject.stdout, "\"object\"\n")

        let typeArray = await bash.exec(#"echo '[1,2]' | jq 'type'"#)
        XCTAssertEqual(typeArray.stdout, "\"array\"\n")

        let first = await bash.exec(#"echo '[5,10,15]' | jq 'first'"#)
        XCTAssertEqual(first.stdout, "5\n")

        let last = await bash.exec(#"echo '[5,10,15]' | jq 'last'"#)
        XCTAssertEqual(last.stdout, "15\n")

        let reverse = await bash.exec(#"echo '[1,2,3]' | jq 'reverse'"#)
        XCTAssertTrue(reverse.stdout.contains("3"))
        XCTAssertTrue(reverse.stdout.contains("1"))

        let sort = await bash.exec(#"echo '[3,1,2]' | jq 'sort'"#)
        XCTAssertTrue(sort.stdout.contains("1"))
        XCTAssertTrue(sort.stdout.contains("3"))

        let unique = await bash.exec(#"echo '[1,2,1,3,2]' | jq 'unique'"#)
        XCTAssertTrue(unique.stdout.contains("1"))
        XCTAssertTrue(unique.stdout.contains("2"))
        XCTAssertTrue(unique.stdout.contains("3"))

        let min = await bash.exec(#"echo '[5,2,8,1]' | jq 'min'"#)
        XCTAssertEqual(min.stdout, "1\n")

        let max = await bash.exec(#"echo '[5,2,8,1]' | jq 'max'"#)
        XCTAssertEqual(max.stdout, "8\n")
    }

    func testJQFunctionsByKeyAndEntries() async {
        let bash = Bash()

        let minBy = await bash.exec(#"echo '[{"n":3},{"n":1},{"n":2}]' | jq -c 'min_by(.n)'"#)
        XCTAssertEqual(minBy.stdout, #"{"n":1}"# + "\n")

        let maxBy = await bash.exec(#"echo '[{"n":3},{"n":1},{"n":2}]' | jq -c 'max_by(.n)'"#)
        XCTAssertEqual(maxBy.stdout, #"{"n":3}"# + "\n")

        let sortBy = await bash.exec(#"echo '[{"n":3},{"n":1},{"n":2}]' | jq -c 'sort_by(.n)'"#)
        XCTAssertEqual(sortBy.stdout, #"[{"n":1},{"n":2},{"n":3}]"# + "\n")

        let groupBy = await bash.exec(#"echo '[{"g":1,"v":"a"},{"g":2,"v":"b"},{"g":1,"v":"c"}]' | jq -c 'group_by(.g)'"#)
        XCTAssertEqual(groupBy.stdout, #"[[{"g":1,"v":"a"},{"g":1,"v":"c"}],[{"g":2,"v":"b"}]]"# + "\n")

        let uniqueBy = await bash.exec(#"echo '[{"n":1},{"n":2},{"n":1}]' | jq -c 'unique_by(.n)'"#)
        XCTAssertEqual(uniqueBy.stdout, #"[{"n":1},{"n":2}]"# + "\n")

        let toEntries = await bash.exec(#"echo '{"a":1,"b":2}' | jq -c 'to_entries'"#)
        XCTAssertEqual(toEntries.stdout, #"[{"key":"a","value":1},{"key":"b","value":2}]"# + "\n")

        let fromEntries = await bash.exec(#"echo '[{"key":"a","value":1}]' | jq -c 'from_entries'"#)
        XCTAssertEqual(fromEntries.stdout, #"{"a":1}"# + "\n")

        let withEntries = await bash.exec(#"echo '{"a":1,"b":2}' | jq -c 'with_entries({key: .key, value: (.value + 10)})'"#)
        XCTAssertEqual(withEntries.stdout, #"{"a":11,"b":12}"# + "\n")
    }

    func testJQGeneratorsPathFunctionsAndMath() async {
        let bash = Bash()

        let flatten = await bash.exec(#"echo '[[1,2],[3,4]]' | jq 'flatten'"#)
        XCTAssertEqual(
            try JSONSerialization.jsonObject(with: Data(flatten.stdout.utf8)) as? [Int],
            [1, 2, 3, 4]
        )

        let flattenDepth = await bash.exec(#"echo '[[[1]],[[2]]]' | jq -c 'flatten(1)'"#)
        XCTAssertEqual(flattenDepth.stdout, #"[[1],[2]]"# + "\n")

        let transpose = await bash.exec(#"echo '[[1,2],[3,4]]' | jq -c 'transpose'"#)
        XCTAssertEqual(transpose.stdout, #"[[1,3],[2,4]]"# + "\n")

        let range = await bash.exec(#"jq -n '[range(5)]'"#)
        XCTAssertEqual(
            try JSONSerialization.jsonObject(with: Data(range.stdout.utf8)) as? [Int],
            [0, 1, 2, 3, 4]
        )

        let boundedRange = await bash.exec(#"jq -n '[limit(3; range(10))]'"#)
        XCTAssertEqual(
            try JSONSerialization.jsonObject(with: Data(boundedRange.stdout.utf8)) as? [Int],
            [0, 1, 2]
        )

        let getPath = await bash.exec(#"echo '{"a":{"b":42}}' | jq 'getpath(["a","b"])'"#)
        XCTAssertEqual(getPath.stdout, "42\n")

        let setPath = await bash.exec(#"echo '{"a":1}' | jq -c 'setpath(["b"]; 2)'"#)
        XCTAssertEqual(setPath.stdout, #"{"a":1,"b":2}"# + "\n")

        let recursiveNumbers = await bash.exec(#"echo '{"a":{"b":1}}' | jq '[.. | numbers]'"#)
        XCTAssertEqual(
            try JSONSerialization.jsonObject(with: Data(recursiveNumbers.stdout.utf8)) as? [Int],
            [1]
        )

        let pow = await bash.exec(#"jq -n 'pow(2; 3)'"#)
        XCTAssertEqual(pow.stdout, "8\n")

        let atan2 = await bash.exec(#"jq -n 'atan2(3; 4)'"#)
        XCTAssertEqual(atan2.stdout, "0.6435011087932844\n")
    }

    func testJQStringFunctions() async {
        let bash = Bash()

        let split = await bash.exec(#"echo '"a,b,c"' | jq 'split(",")'"#)
        XCTAssertEqual(
            try JSONSerialization.jsonObject(with: Data(split.stdout.utf8)) as? [String],
            ["a", "b", "c"]
        )

        let join = await bash.exec(#"echo '["a","b","c"]' | jq 'join("-")'"#)
        XCTAssertEqual(join.stdout, #""a-b-c""# + "\n")

        let testRegex = await bash.exec(#"echo '"foobar"' | jq 'test("bar")'"#)
        XCTAssertEqual(testRegex.stdout, "true\n")

        let startsWith = await bash.exec(#"echo '"hello world"' | jq 'startswith("hello")'"#)
        XCTAssertEqual(startsWith.stdout, "true\n")

        let endsWith = await bash.exec(#"echo '"hello world"' | jq 'endswith("world")'"#)
        XCTAssertEqual(endsWith.stdout, "true\n")

        let leftTrim = await bash.exec(#"echo '"hello world"' | jq 'ltrimstr("hello ")'"#)
        XCTAssertEqual(leftTrim.stdout, #""world""# + "\n")

        let rightTrim = await bash.exec(#"echo '"hello world"' | jq 'rtrimstr(" world")'"#)
        XCTAssertEqual(rightTrim.stdout, #""hello""# + "\n")

        let downcase = await bash.exec(#"echo '"HELLO"' | jq 'ascii_downcase'"#)
        XCTAssertEqual(downcase.stdout, #""hello""# + "\n")

        let upcase = await bash.exec(#"echo '"hello"' | jq 'ascii_upcase'"#)
        XCTAssertEqual(upcase.stdout, #""HELLO""# + "\n")

        let sub = await bash.exec(#"echo '"foobar"' | jq 'sub("o"; "0")'"#)
        XCTAssertEqual(sub.stdout, #""f0obar""# + "\n")

        let gsub = await bash.exec(#"echo '"foobar"' | jq 'gsub("o"; "0")'"#)
        XCTAssertEqual(gsub.stdout, #""f00bar""# + "\n")

        let index = await bash.exec(#"echo '"foobar"' | jq 'index("bar")'"#)
        XCTAssertEqual(index.stdout, "3\n")

        let indices = await bash.exec(#"echo '"abcabc"' | jq 'indices("bc")'"#)
        XCTAssertEqual(
            try JSONSerialization.jsonObject(with: Data(indices.stdout.utf8)) as? [Int],
            [1, 4]
        )
    }

    func testJQOperatorsAndTypeConversion() async {
        let bash = Bash()

        let addNumbers = await bash.exec(#"echo '5' | jq '. + 3'"#)
        XCTAssertEqual(addNumbers.stdout, "8\n")

        let subtract = await bash.exec(#"echo '10' | jq '. - 4'"#)
        XCTAssertEqual(subtract.stdout, "6\n")

        let multiply = await bash.exec(#"echo '6' | jq '. * 7'"#)
        XCTAssertEqual(multiply.stdout, "42\n")

        let divide = await bash.exec(#"echo '20' | jq '. / 4'"#)
        XCTAssertEqual(divide.stdout, "5\n")

        let modulo = await bash.exec(#"echo '17' | jq '. % 5'"#)
        XCTAssertEqual(modulo.stdout, "2\n")

        let stringConcat = await bash.exec(#"echo '{"a":"foo","b":"bar"}' | jq '.a + .b'"#)
        XCTAssertEqual(stringConcat.stdout, #""foobar""# + "\n")

        let arrayConcat = await bash.exec(#"echo '[[1,2],[3,4]]' | jq -c '.[0] + .[1]'"#)
        XCTAssertEqual(arrayConcat.stdout, "[1,2,3,4]\n")

        let objectMerge = await bash.exec(#"echo '[{"a":1},{"b":2}]' | jq -c '.[0] + .[1]'"#)
        XCTAssertEqual(objectMerge.stdout, #"{"a":1,"b":2}"# + "\n")

        let andValue = await bash.exec(#"echo 'true' | jq '. and true'"#)
        XCTAssertEqual(andValue.stdout, "true\n")

        let orValue = await bash.exec(#"echo 'false' | jq '. or true'"#)
        XCTAssertEqual(orValue.stdout, "true\n")

        let notValue = await bash.exec(#"echo 'true' | jq 'not'"#)
        XCTAssertEqual(notValue.stdout, "false\n")

        let fallback = await bash.exec(#"echo '{"a":null}' | jq '.a // "default"'"#)
        XCTAssertEqual(fallback.stdout, #""default""# + "\n")

        let keepValue = await bash.exec(#"echo '{"a":42}' | jq '.a // "default"'"#)
        XCTAssertEqual(keepValue.stdout, "42\n")

        let floorValue = await bash.exec(#"echo '3.7' | jq 'floor'"#)
        XCTAssertEqual(floorValue.stdout, "3\n")

        let ceilValue = await bash.exec(#"echo '3.2' | jq 'ceil'"#)
        XCTAssertEqual(ceilValue.stdout, "4\n")

        let roundValue = await bash.exec(#"echo '3.5' | jq 'round'"#)
        XCTAssertEqual(roundValue.stdout, "4\n")

        let sqrtValue = await bash.exec(#"echo '16' | jq 'sqrt'"#)
        XCTAssertEqual(sqrtValue.stdout, "4\n")

        let absValue = await bash.exec(#"echo '-5' | jq 'abs'"#)
        XCTAssertEqual(absValue.stdout, "5\n")

        let toString = await bash.exec(#"echo '42' | jq 'tostring'"#)
        XCTAssertEqual(toString.stdout, #""42""# + "\n")

        let toNumber = await bash.exec(#"echo '"42"' | jq 'tonumber'"#)
        XCTAssertEqual(toNumber.stdout, "42\n")
    }

    func testJQQuotedFieldAccessAndObjectShorthand() async {
        let bash = Bash()

        let keywordField = await bash.exec(#"echo '{"and":true}' | jq '.and'"#)
        XCTAssertEqual(keywordField.stdout, "true\n")

        let bracketString = await bash.exec(#"echo '{"foo":"bar"}' | jq '.["foo"]'"#)
        XCTAssertEqual(bracketString.stdout, #""bar""# + "\n")

        let dottedQuoted = await bash.exec(#"echo '{"data":{"foo":"bar"}}' | jq '.data. "foo"'"#)
        XCTAssertEqual(dottedQuoted.stdout, #""bar""# + "\n")

        let shorthand = await bash.exec(#"echo '{"label":"hello"}' | jq -c '{label}'"#)
        XCTAssertEqual(shorthand.stdout, #"{"label":"hello"}"# + "\n")

        let keywordShorthand = await bash.exec(#"echo '{"and":1}' | jq -c '{and}'"#)
        XCTAssertEqual(keywordShorthand.stdout, #"{"and":1}"# + "\n")
    }

    func testYQYamlAccessAndIteration() async {
        let bash = Bash(options: .init(files: [
            "/tmp/data.yaml": """
            config:
              database:
                host: localhost
            items:
              - name: foo
                active: true
              - name: bar
                active: false
            fruits:
              - apple
              - banana
            """
        ]))

        let host = await bash.exec("yq '.config.database.host' /tmp/data.yaml")
        XCTAssertEqual(host.stdout, "localhost\n")

        let first = await bash.exec("yq '.items[0].name' /tmp/data.yaml")
        XCTAssertEqual(first.stdout, "foo\n")

        let fruits = await bash.exec("yq '.fruits[]' /tmp/data.yaml")
        XCTAssertEqual(fruits.stdout, "apple\nbanana\n")

        let active = await bash.exec("yq '.items[] | select(.active) | .name' /tmp/data.yaml")
        XCTAssertEqual(active.stdout, "foo\n")
    }

    func testYQJsonModesAndJsonInput() async {
        let bash = Bash(options: .init(files: [
            "/tmp/data.yaml": "name: test\nvalue: 42\nmessage: hello world\n",
            "/tmp/data.json": #"{"name":"test","value":42}"#
        ]))

        let pretty = await bash.exec("yq -o json '.' /tmp/data.yaml")
        XCTAssertTrue(pretty.stdout.contains("\"name\""))
        XCTAssertTrue(pretty.stdout.contains("\"value\""))

        let compact = await bash.exec("yq -c -o json '.' /tmp/data.yaml")
        XCTAssertEqual(
            try JSONSerialization.jsonObject(with: Data(compact.stdout.utf8)) as? [String: AnyHashable],
            ["name": "test", "value": 42, "message": "hello world"]
        )

        let raw = await bash.exec("yq -r -o json '.message' /tmp/data.yaml")
        XCTAssertEqual(raw.stdout, "hello world\n")

        let jsonInput = await bash.exec("yq -p json '.name' /tmp/data.json")
        XCTAssertEqual(jsonInput.stdout, "test\n")
    }

    func testYQStdinAndNullInput() async {
        let bash = Bash()

        let stdin = await bash.exec("echo 'name: test' | yq '.name'")
        XCTAssertEqual(stdin.stdout, "test\n")

        let nullInput = await bash.exec("yq -n '{name: \"created\"}' -o json")
        XCTAssertEqual(
            try JSONSerialization.jsonObject(with: Data(nullInput.stdout.utf8)) as? [String: AnyHashable],
            ["name": "created"]
        )
    }

    func testYQInheritsSharedJQFunctions() async {
        let bash = Bash(options: .init(files: [
            "/tmp/data.json": #"{"matrix":[[1,2],[3,4]],"items":[{"type":"a","name":"b"},{"type":"b","name":"c"},{"type":"a","name":"a"}],"message":"hello world","a":null,"and":1}"#
        ]))

        let transpose = await bash.exec("yq -p json '.matrix | transpose' /tmp/data.json -o json -c")
        XCTAssertEqual(transpose.stdout, "[[1,3],[2,4]]\n")

        let groupBy = await bash.exec("yq -p json '.items | group_by(.type) | length' /tmp/data.json")
        XCTAssertEqual(groupBy.stdout, "2\n")

        let startsWith = await bash.exec("yq -p json '.message | startswith(\"hello\")' /tmp/data.json")
        XCTAssertEqual(startsWith.stdout, "true\n")

        let fallback = await bash.exec("yq -p json '.a // \"default\"' /tmp/data.json")
        XCTAssertEqual(fallback.stdout, "default\n")

        let keywordShorthand = await bash.exec("yq -p json -o json -c '{and}' /tmp/data.json")
        XCTAssertEqual(keywordShorthand.stdout, "{\"and\":1}\n")
    }

    func testYQFormatStrings() async {
        let bash = Bash()

        let base64 = await bash.exec(#"echo '"hello"' | yq -p json -o json '@base64'"#)
        XCTAssertEqual(base64.stdout, #""aGVsbG8=""# + "\n")

        let base64d = await bash.exec(#"echo '"aGVsbG8="' | yq -p json -o json '@base64d'"#)
        XCTAssertEqual(base64d.stdout, #""hello""# + "\n")

        let uri = await bash.exec(#"echo '"hello world"' | yq -p json -o json '@uri'"#)
        XCTAssertEqual(uri.stdout, #""hello%20world""# + "\n")

        let csv = await bash.exec(#"echo '["a","b,c","d"]' | yq -p json -o json '@csv'"#)
        XCTAssertEqual(csv.stdout, #""a,\"b,c\",d""# + "\n")

        let tsv = await bash.exec(#"echo '["a","b","c"]' | yq -p json -o json '@tsv'"#)
        XCTAssertEqual(tsv.stdout, #""a\tb\tc""# + "\n")

        let json = await bash.exec(#"echo '{"a":1}' | yq -p json -o json '@json'"#)
        XCTAssertEqual(json.stdout, #""{\"a\":1}""# + "\n")

        let html = await bash.exec(#"echo '"<script>a & b</script>"' | yq -p json -o json '@html'"#)
        XCTAssertEqual(html.stdout, #""&lt;script&gt;a &amp; b&lt;/script&gt;""# + "\n")

        let shell = await bash.exec(#"echo '"it'\''s"' | yq -p json -o json '@sh'"#)
        XCTAssertEqual(shell.stdout, #""'it'\\''s'""# + "\n")

        let text = await bash.exec(#"echo '42' | yq -p json -o json '@text'"#)
        XCTAssertEqual(text.stdout, #""42""# + "\n")

        let nonString = await bash.exec(#"echo '123' | yq -p json -o json '@base64'"#)
        XCTAssertEqual(nonString.stdout, "null\n")
    }

    func testYQSlurpAndModeFlags() async {
        let bash = Bash(options: .init(files: [
            "/tmp/multi.yaml": """
            ---
            name: first
            ---
            name: second
            """,
            "/tmp/items.yaml": """
            items:
              - a
              - b
              - c
            value: true
            """,
            "/tmp/numbers.yaml": """
            items:
              - 1
              - 2
            """,
            "/tmp/missing.yaml": "value: 42\n",
            "/tmp/array.yaml": """
            items:
              - a
              - b
            """
        ]))

        let slurp = await bash.exec("yq -s '.[0].name' /tmp/multi.yaml")
        XCTAssertEqual(slurp.stdout, "first\n")

        let join = await bash.exec("yq -j '.items[]' /tmp/items.yaml")
        XCTAssertEqual(join.stdout, "abc")

        let truthy = await bash.exec("yq -e '.value' /tmp/items.yaml")
        XCTAssertEqual(truthy.exitCode, 0)

        let falsey = await bash.exec("yq -e '.missing' /tmp/missing.yaml")
        XCTAssertEqual(falsey.exitCode, 1)

        let indent = await bash.exec("yq -o json -I 4 '.' /tmp/array.yaml")
        XCTAssertTrue(indent.stdout.contains("    \"a\""))

        let combined = await bash.exec("yq -cej -o json '.items[]' /tmp/numbers.yaml")
        XCTAssertEqual(combined.exitCode, 0)
        XCTAssertEqual(combined.stdout, "12")
    }

    func testYQNavigationOperators() async throws {
        let bash = Bash(options: .init(files: [
            "/tmp/nav.yaml": """
            a:
              b:
                c: value
            items:
              - name: foo
                val: 1
              - name: bar
                val: 2
            """
        ]))

        let parent = await bash.exec("yq -o json '.a.b.c | parent' /tmp/nav.yaml")
        XCTAssertEqual(
            try JSONSerialization.jsonObject(with: Data(parent.stdout.utf8)) as? [String: String],
            ["c": "value"]
        )

        let grandparent = await bash.exec("yq -o json '.a.b.c | parent(2)' /tmp/nav.yaml")
        let grandparentObject = try JSONSerialization.jsonObject(with: Data(grandparent.stdout.utf8)) as? [String: Any]
        XCTAssertNotNil(grandparentObject?["b"])

        let root = await bash.exec("yq -o json '.a.b.c | root' /tmp/nav.yaml")
        let rootObject = try JSONSerialization.jsonObject(with: Data(root.stdout.utf8)) as? [String: Any]
        XCTAssertNotNil(rootObject?["a"])
        XCTAssertNotNil(rootObject?["items"])

        let parents = await bash.exec("yq -o json '.a.b.c | parents | length' /tmp/nav.yaml")
        XCTAssertEqual(parents.stdout, "3\n")

        let parentZero = await bash.exec("yq -o json '.a.b | parent(0)' /tmp/nav.yaml")
        let parentZeroObject = try JSONSerialization.jsonObject(with: Data(parentZero.stdout.utf8)) as? [String: String]
        XCTAssertEqual(parentZeroObject, ["c": "value"])

        let negativeParent = await bash.exec("yq -o json '.a.b.c | parent(-2)' /tmp/nav.yaml")
        let negativeParentObject = try JSONSerialization.jsonObject(with: Data(negativeParent.stdout.utf8)) as? [String: Any]
        XCTAssertNotNil(negativeParentObject?["b"])

        let arrayParent = await bash.exec("yq -o json '.items[0].name | parent' /tmp/nav.yaml")
        let arrayParentObject = try JSONSerialization.jsonObject(with: Data(arrayParent.stdout.utf8)) as? [String: AnyHashable]
        XCTAssertEqual(arrayParentObject?["name"] as? String, "foo")
        XCTAssertEqual(arrayParentObject?["val"] as? Int, 1)

        let rootStandalone = await bash.exec("yq -o json 'root' /tmp/nav.yaml")
        let rootStandaloneObject = try JSONSerialization.jsonObject(with: Data(rootStandalone.stdout.utf8)) as? [String: Any]
        XCTAssertNotNil(rootStandaloneObject?["a"])
    }

    func testYQCSVInputAndOutput() async throws {
        let bash = Bash(options: .init(files: [
            "/tmp/data.csv": "name,age,city\nalice,30,NYC\nbob,25,LA\ncharlie,35,NYC\n",
            "/tmp/data.tsv": "name\tage\nalice\t30\nbob\t25\n",
            "/tmp/people.yaml": """
            - name: alice
              age: 30
            - name: bob
              age: 25
            """,
            "/tmp/data.json": #"[{"name":"alice","score":95},{"name":"bob","score":87}]"#
        ]))

        let firstName = await bash.exec("yq -p csv '.[0].name' /tmp/data.csv")
        XCTAssertEqual(firstName.stdout, "alice\n")

        let allNames = await bash.exec("yq -p csv '.[].name' /tmp/data.csv")
        XCTAssertEqual(allNames.stdout, "alice\nbob\ncharlie\n")

        let filtered = await bash.exec(#"yq -p csv '[.[] | select(.city == "NYC") | .name]' /tmp/data.csv -o json"#)
        XCTAssertEqual(
            try JSONSerialization.jsonObject(with: Data(filtered.stdout.utf8)) as? [String],
            ["alice", "charlie"]
        )

        let yamlToCSV = await bash.exec("yq -o csv '.' /tmp/people.yaml")
        XCTAssertTrue(yamlToCSV.stdout.contains("age,name"))
        XCTAssertTrue(yamlToCSV.stdout.contains("30,alice"))
        XCTAssertTrue(yamlToCSV.stdout.contains("25,bob"))

        let jsonToCSV = await bash.exec("yq -p json -o csv '.' /tmp/data.json")
        XCTAssertTrue(jsonToCSV.stdout.contains("name,score"))
        XCTAssertTrue(jsonToCSV.stdout.contains("alice,95"))
        XCTAssertTrue(jsonToCSV.stdout.contains("bob,87"))

        let tsv = await bash.exec(#"yq -p csv --csv-delimiter='\t' '.[0].name' /tmp/data.tsv"#)
        XCTAssertEqual(tsv.stdout, "alice\n")
    }

}
