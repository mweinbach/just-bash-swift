import XCTest
@testable import JustBash
@testable import JustBashCommands

final class DefineCommandTests: XCTestCase {

    func testDefineCommandRunsInScript() async {
        let bash = Bash()
        await bash.defineCommand("greet") { args, _ in
            // args does NOT include the command name — args[0] is the first argument
            let name = args.first ?? "world"
            return ExecResult.success("Hello, \(name)!\n")
        }
        let result = await bash.exec("greet Swift")
        XCTAssertEqual(result.stdout, "Hello, Swift!\n")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testDefineCommandAppearsInNames() async {
        let bash = Bash()
        await bash.defineCommand("mycmd") { _, _ in .success("ok\n") }
        let names = await bash.commandNames
        XCTAssertTrue(names.contains("mycmd"))
    }

    func testDefineMultipleCommands() async {
        let bash = Bash()
        await bash.defineCommands([
            AnyBashCommand(name: "cmd1") { _, _ in .success("one\n") },
            AnyBashCommand(name: "cmd2") { _, _ in .success("two\n") },
        ])
        let r1 = await bash.exec("cmd1")
        let r2 = await bash.exec("cmd2")
        XCTAssertEqual(r1.stdout, "one\n")
        XCTAssertEqual(r2.stdout, "two\n")
    }

    func testDefineCommandReceivesContext() async {
        let bash = Bash(options: BashOptions(env: ["MY_VAR": "test-value"]))
        await bash.defineCommand("readvar") { _, ctx in
            let val = ctx.environment["MY_VAR"] ?? "missing"
            return .success("\(val)\n")
        }
        let result = await bash.exec("readvar")
        XCTAssertEqual(result.stdout, "test-value\n")
    }

    func testDefineCommandReceivesStdin() async {
        let bash = Bash()
        await bash.defineCommand("upper") { _, ctx in
            return .success(ctx.stdin.uppercased())
        }
        let result = await bash.exec("echo hello | upper")
        XCTAssertEqual(result.stdout, "HELLO\n")
    }

    func testDefineCommandCanFail() async {
        let bash = Bash()
        await bash.defineCommand("fail") { _, _ in
            return .failure("something went wrong")
        }
        let result = await bash.exec("fail")
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("something went wrong"))
    }

    func testCustomCommandViaOptions() async {
        let bash = Bash(options: BashOptions(
            customCommands: [
                AnyBashCommand(name: "ping") { _, _ in .success("pong\n") }
            ]
        ))
        let result = await bash.exec("ping")
        XCTAssertEqual(result.stdout, "pong\n")
    }

    func testFsAccessor() async {
        let bash = Bash(options: BashOptions(files: ["/tmp/test.txt": "content"]))
        let fs = await bash.fs
        XCTAssertTrue(fs.exists("/tmp/test.txt"))
        let text = try? fs.readFile("/tmp/test.txt")
        XCTAssertEqual(text, "content")
    }
}
