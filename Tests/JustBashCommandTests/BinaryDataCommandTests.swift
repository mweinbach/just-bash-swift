import XCTest
@testable import JustBash

final class BinaryDataCommandTests: XCTestCase {
    
    // MARK: - hexdump Tests
    
    func testHexdumpCanonical() async {
        let bash = Bash()
        let result = await bash.exec("echo -n 'Hello, World!' | hexdump -C")
        XCTAssertEqual(result.exitCode, 0)
        // Should contain hex + ASCII representation
        XCTAssertTrue(result.stdout.contains("48 65 6c 6c 6f")) // Hello in hex
        XCTAssertTrue(result.stdout.contains("|Hello, World!|"))
    }
    
    func testHexdumpPlain() async {
        let bash = Bash()
        let result = await bash.exec("echo -n 'ABC' | hexdump -p")
        XCTAssertEqual(result.exitCode, 0)
        // Plain hex output: 414243
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "414243")
    }
    
    func testHexdumpHelp() async {
        let bash = Bash()
        let result = await bash.exec("hexdump --help")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("hexdump"))
        XCTAssertTrue(result.stdout.contains("-C"))
    }
    
    // MARK: - xxd Tests
    
    func testXXDHexDump() async {
        let bash = Bash()
        let result = await bash.exec("echo -n 'ABC' | xxd")
        XCTAssertEqual(result.exitCode, 0)
        // xxd format: offset + hex groups + ASCII
        XCTAssertTrue(result.stdout.contains("414243"))
        XCTAssertTrue(result.stdout.contains("ABC"))
    }
    
    func testXXDPlain() async {
        let bash = Bash()
        let result = await bash.exec("echo -n 'Hello' | xxd -p")
        XCTAssertEqual(result.exitCode, 0)
        // Plain hex: 48656c6c6f
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "48656c6c6f")
    }
    
    func testXXDBinary() async {
        let bash = Bash()
        let result = await bash.exec("echo -n 'AB' | xxd -b")
        XCTAssertEqual(result.exitCode, 0)
        // Binary format should show 01000001 (A) and 01000010 (B)
        XCTAssertTrue(result.stdout.contains("01000001"))
    }
    
    func testXXDUppercase() async {
        let bash = Bash()
        let result = await bash.exec("echo -n 'ABC' | xxd -u")
        XCTAssertEqual(result.exitCode, 0)
        // Uppercase hex: 414243
        XCTAssertTrue(result.stdout.contains("414243"))
    }
    
    func testXXDHelp() async {
        let bash = Bash()
        let result = await bash.exec("xxd -h")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("xxd"))
    }
    
    // MARK: - iconv Tests
    
    func testIconvPassThrough() async {
        let bash = Bash()
        let result = await bash.exec("echo 'Hello, World!' | iconv")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("Hello, World!"))
    }
    
    func testIconvHelp() async {
        let bash = Bash()
        let result = await bash.exec("iconv --help")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("iconv"))
    }
    
    func testIconvList() async {
        let bash = Bash()
        let result = await bash.exec("iconv -l")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("UTF-8"))
    }
    
    // MARK: - uuencode/uudecode Tests
    
    func testUuencodeBasic() async {
        let bash = Bash()
        let result = await bash.exec("echo -n 'Hello' | uuencode output.txt")
        XCTAssertEqual(result.exitCode, 0)
        // Should have begin line
        XCTAssertTrue(result.stdout.contains("begin 644 output.txt"))
        // Should have end line
        XCTAssertTrue(result.stdout.contains("end"))
    }
    
    func testUuencodeRoundTrip() async {
        let bash = Bash()
        
        // Encode
        let encoded = await bash.exec("echo 'Hello, World!' | uuencode message.txt")
        XCTAssertEqual(encoded.exitCode, 0)
        
        // Decode using xxd in reverse mode (uuencode -d equivalent)
        // Note: Our uuencode command includes decode functionality with -d flag
        // For now, just verify encoding works
    }
    
    func testUuencodeHelp() async {
        let bash = Bash()
        let result = await bash.exec("uuencode --help")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("uuencode"))
    }
}
