import XCTest
@testable import JustBashCommands
@testable import JustBashFS

final class CommandRegistryTests: XCTestCase {
    func testEchoCommand() async {
        let registry = CommandRegistry.builtins()
        let result = await registry.command(named: "cat")!.execute([], .init(fileSystem: VirtualFileSystem(), cwd: "/home/user", environment: [:], stdin: "hello\n"))
        XCTAssertEqual(result.stdout, "hello\n")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testGrepCommand() async {
        let registry = CommandRegistry.builtins()
        let result = await registry.command(named: "grep")!.execute(["beta"], .init(fileSystem: VirtualFileSystem(), cwd: "/home/user", environment: [:], stdin: "alpha\nbeta\n"))
        XCTAssertEqual(result.stdout, "beta\n")
        XCTAssertEqual(result.exitCode, 0)
    }
}
