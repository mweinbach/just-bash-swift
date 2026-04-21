import XCTest
@testable import JustBash

final class ExtraCommandTests: XCTestCase {
    
    func testTTY() async {
        let bash = Bash()
        let result = await bash.exec("tty")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("/dev/tty"))
    }
    
    func testPathchk() async {
        let bash = Bash()
        let result = await bash.exec("pathchk /valid/path")
        XCTAssertEqual(result.exitCode, 0)
    }
    
    func testPathchkInvalid() async {
        let bash = Bash()
        let result = await bash.exec("pathchk -P 'invalid:path'")
        XCTAssertEqual(result.exitCode, 1)
    }
    
    func testJot() async {
        let bash = Bash()
        let result = await bash.exec("jot 5")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("1"))
    }
    
    func testTSort() async {
        let bash = Bash()
        let result = await bash.exec("echo 'a b b c' | tsort")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("a"))
    }
    
    func testCksum() async {
        let bash = Bash()
        let result = await bash.exec("echo 'test' | cksum")
        XCTAssertEqual(result.exitCode, 0)
        // Should have two numbers (CRC and size)
        let parts = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        XCTAssertEqual(parts.count, 2)
    }
    
    func testSum() async {
        let bash = Bash()
        let result = await bash.exec("echo 'test' | sum")
        XCTAssertEqual(result.exitCode, 0)
        let parts = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        XCTAssertTrue(parts.count >= 2)
    }
    
    func testFmt() async {
        let bash = Bash()
        let longLine = String(repeating: "word ", count: 20)
        let result = await bash.exec("echo '\(longLine)' | fmt -w 40")
        XCTAssertEqual(result.exitCode, 0)
        // Output should be wrapped to multiple lines
        let lines = result.stdout.components(separatedBy: .newlines)
        XCTAssertTrue(lines.count > 1)
    }
}
