import XCTest
@testable import JustBash

final class MoreCommandTests: XCTestCase {
    
    func testShuf() async {
        let bash = Bash()
        let result = await bash.exec("echo -e 'a\\nb\\nc\\nd' | shuf")
        XCTAssertEqual(result.exitCode, 0)
        let lines = result.stdout.components(separatedBy: .newlines).filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 4)
        XCTAssertTrue(lines.contains("a"))
        XCTAssertTrue(lines.contains("b"))
    }
    
    func testShufRange() async {
        let bash = Bash()
        let result = await bash.exec("shuf -i 1-5")
        XCTAssertEqual(result.exitCode, 0)
        let lines = result.stdout.components(separatedBy: .newlines).filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 5)
    }
    
    func testTS() async {
        let bash = Bash()
        let result = await bash.exec("echo 'test' | ts")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("test"))
    }
    
    func testSponge() async {
        let bash = Bash()
        _ = await bash.exec("echo 'sponge test' | sponge /tmp/sponge_out.txt")
        let result = await bash.exec("cat /tmp/sponge_out.txt")
        XCTAssertEqual(result.stdout, "sponge test\n")
    }
    
    func testErrno() async {
        let bash = Bash()
        let result = await bash.exec("errno 2")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("ENOENT"))
    }
    
    func testErrnoName() async {
        let bash = Bash()
        let result = await bash.exec("errno ENOENT")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("No such file"))
    }
    
    func testChronic() async {
        let bash = Bash()
        // Successful command should produce no output
        let result = await bash.exec("chronic echo 'hidden'")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "")
    }
    
    func testChronicVerbose() async {
        let bash = Bash()
        let result = await bash.exec("chronic -v echo 'visible'")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "visible\n")
    }
    
    func testCombine() async {
        let bash = Bash()
        _ = await bash.exec("echo -e 'a\\nb' > /tmp/c1.txt && echo -e 'b\\nc' > /tmp/c2.txt")
        let result = await bash.exec("combine and /tmp/c1.txt /tmp/c2.txt")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("b"))
    }
}
