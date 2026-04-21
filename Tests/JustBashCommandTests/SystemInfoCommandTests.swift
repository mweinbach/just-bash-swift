import XCTest
@testable import JustBash

final class SystemInfoCommandTests: XCTestCase {
    
    func testWhichBasic() async {
        let bash = Bash()
        let result = await bash.exec("which cat")
        XCTAssertEqual(result.exitCode, 0)
        // should find cat in /bin/cat or similar
        XCTAssertTrue(result.stdout.contains("/cat"))
    }
    
    func testWhichHelp() async {
        let bash = Bash()
        let result = await bash.exec("which --help")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("which"))
    }
    
    func testUptime() async {
        let bash = Bash()
        let result = await bash.exec("uptime")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("up"))
        XCTAssertTrue(result.stdout.contains("load average"))
    }
    
    func testFree() async {
        let bash = Bash()
        let result = await bash.exec("free")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("Mem:"))
        XCTAssertTrue(result.stdout.contains("Swap:"))
    }
    
    func testDF() async {
        let bash = Bash()
        let result = await bash.exec("df")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("Filesystem"))
    }
    
    func testPS() async {
        let bash = Bash()
        let result = await bash.exec("ps")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("PID"))
    }
    
    func testKillList() async {
        let bash = Bash()
        let result = await bash.exec("kill -l")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("SIGTERM"))
    }
}
