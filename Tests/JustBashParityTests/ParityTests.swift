import XCTest
import JustBash

final class ParityTests: XCTestCase {
    func testCuratedMvpCases() async {
        let cases: [(String, String)] = [
            ("echo hello", "hello\n"),
            ("mkdir -p /tmp/demo; echo hi > /tmp/demo/file.txt; cat /tmp/demo/file.txt", "hi\n"),
            ("printf 'a b c\\n' | wc -w", "3\n"),
        ]

        for (script, expected) in cases {
            let bash = Bash()
            let result = await bash.exec(script)
            XCTAssertEqual(result.stdout, expected, "failed script: \(script)")
            XCTAssertEqual(result.exitCode, 0)
        }
    }

    func testControlFlowParity() async {
        let cases: [(String, String)] = [
            // If/else
            ("if true; then echo yes; else echo no; fi", "yes\n"),
            ("if false; then echo yes; else echo no; fi", "no\n"),
            // For loop
            ("for x in 1 2 3; do echo $x; done", "1\n2\n3\n"),
            // While loop
            ("i=0; while [ $i -lt 3 ]; do echo $i; i=$((i+1)); done", "0\n1\n2\n"),
            // Case
            ("x=b; case $x in a) echo A;; b) echo B;; esac", "B\n"),
            // Nested
            ("for i in 1 2; do if [ $i = 1 ]; then echo first; else echo second; fi; done", "first\nsecond\n"),
        ]

        for (script, expected) in cases {
            let bash = Bash()
            let result = await bash.exec(script)
            XCTAssertEqual(result.stdout, expected, "failed script: \(script)")
        }
    }

    func testCommandSubstitutionParity() async {
        let cases: [(String, String)] = [
            ("echo $(echo hello)", "hello\n"),
            ("x=$(echo 42); echo $x", "42\n"),
            ("echo $(echo $(echo deep))", "deep\n"),
        ]

        for (script, expected) in cases {
            let bash = Bash()
            let result = await bash.exec(script)
            XCTAssertEqual(result.stdout, expected, "failed script: \(script)")
        }
    }

    func testVariableExpansionParity() async {
        let cases: [(String, String)] = [
            ("x=hello; echo $x", "hello\n"),
            ("x=hello; echo ${x}", "hello\n"),
            ("echo ${unset:-default}", "default\n"),
            ("x=hello; echo ${#x}", "5\n"),
            ("x=hello; echo ${x^^}", "HELLO\n"),
            ("x=HELLO; echo ${x,,}", "hello\n"),
            ("f=/a/b/c.txt; echo ${f##*/}", "c.txt\n"),
            ("f=/a/b/c.txt; echo ${f%.*}", "/a/b/c\n"),
        ]

        for (script, expected) in cases {
            let bash = Bash()
            let result = await bash.exec(script)
            XCTAssertEqual(result.stdout, expected, "failed script: \(script)")
        }
    }

    func testArithmeticParity() async {
        let cases: [(String, String)] = [
            ("echo $((1 + 2))", "3\n"),
            ("echo $((10 - 3))", "7\n"),
            ("echo $((4 * 5))", "20\n"),
            ("echo $((10 / 3))", "3\n"),
            ("echo $((10 % 3))", "1\n"),
            ("echo $((2 ** 8))", "256\n"),
            ("x=5; echo $((x + 1))", "6\n"),
        ]

        for (script, expected) in cases {
            let bash = Bash()
            let result = await bash.exec(script)
            XCTAssertEqual(result.stdout, expected, "failed script: \(script)")
        }
    }
}
