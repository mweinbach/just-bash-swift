import XCTest
@testable import JustBashCore

final class ASTTransformTests: XCTestCase {

    // MARK: - CommandCollector

    func testCommandCollectorSimple() throws {
        let parser = ShellParser()
        let script = try parser.parse("echo hello")
        let collector = CommandCollector()
        _ = collector.transform(script)
        XCTAssertEqual(collector.commands, ["echo"])
    }

    func testCommandCollectorPipeline() throws {
        let parser = ShellParser()
        let script = try parser.parse("echo hello | grep h | wc -l")
        let collector = CommandCollector()
        _ = collector.transform(script)
        XCTAssertEqual(collector.commands, ["echo", "grep", "wc"])
    }

    func testCommandCollectorAndOr() throws {
        let parser = ShellParser()
        let script = try parser.parse("ls && echo ok || echo fail")
        let collector = CommandCollector()
        _ = collector.transform(script)
        XCTAssertEqual(collector.commands, ["ls", "echo", "echo"])
    }

    func testCommandCollectorUniqueCommands() throws {
        let parser = ShellParser()
        let script = try parser.parse("echo a; echo b; ls; echo c")
        let collector = CommandCollector()
        _ = collector.transform(script)
        XCTAssertEqual(collector.uniqueCommands, ["echo", "ls"])
    }

    func testCommandCollectorIfClause() throws {
        let parser = ShellParser()
        let script = try parser.parse("if test -f foo; then cat foo; else touch foo; fi")
        let collector = CommandCollector()
        _ = collector.transform(script)
        XCTAssertTrue(collector.commands.contains("test"))
        XCTAssertTrue(collector.commands.contains("cat"))
        XCTAssertTrue(collector.commands.contains("touch"))
    }

    func testCommandCollectorForLoop() throws {
        let parser = ShellParser()
        let script = try parser.parse("for x in a b; do echo $x; done")
        let collector = CommandCollector()
        _ = collector.transform(script)
        XCTAssertEqual(collector.commands, ["echo"])
    }

    func testCommandCollectorWhileLoop() throws {
        let parser = ShellParser()
        let script = try parser.parse("while read line; do echo $line; done")
        let collector = CommandCollector()
        _ = collector.transform(script)
        XCTAssertTrue(collector.commands.contains("read"))
        XCTAssertTrue(collector.commands.contains("echo"))
    }

    func testCommandCollectorCaseClause() throws {
        let parser = ShellParser()
        let script = try parser.parse("case $x in a) echo a;; b) echo b;; esac")
        let collector = CommandCollector()
        _ = collector.transform(script)
        XCTAssertEqual(collector.commands, ["echo", "echo"])
    }

    func testCommandCollectorFunctionDef() throws {
        let parser = ShellParser()
        let script = try parser.parse("greet() { echo hello; }")
        let collector = CommandCollector()
        _ = collector.transform(script)
        XCTAssertEqual(collector.commands, ["echo"])
    }

    func testCommandCollectorReset() throws {
        let parser = ShellParser()
        let collector = CommandCollector()

        let s1 = try parser.parse("echo a")
        _ = collector.transform(s1)
        XCTAssertEqual(collector.commands.count, 1)

        collector.reset()
        let s2 = try parser.parse("ls")
        _ = collector.transform(s2)
        XCTAssertEqual(collector.commands, ["ls"])
    }

    // MARK: - ASTSerializer

    func testSerializeSimpleCommand() throws {
        let parser = ShellParser()
        let script = try parser.parse("echo hello world")
        let serialized = ASTSerializer.serialize(script)
        XCTAssertEqual(serialized, "echo hello world")
    }

    func testSerializePipeline() throws {
        let parser = ShellParser()
        let script = try parser.parse("echo hello | grep h")
        let serialized = ASTSerializer.serialize(script)
        XCTAssertEqual(serialized, "echo hello | grep h")
    }

    func testSerializeAndOr() throws {
        let parser = ShellParser()
        let script = try parser.parse("ls && echo ok")
        let serialized = ASTSerializer.serialize(script)
        XCTAssertEqual(serialized, "ls && echo ok")
    }

    func testSerializeIfClause() throws {
        let parser = ShellParser()
        let script = try parser.parse("if true; then echo yes; else echo no; fi")
        let serialized = ASTSerializer.serialize(script)
        XCTAssertTrue(serialized.contains("if"))
        XCTAssertTrue(serialized.contains("then"))
        XCTAssertTrue(serialized.contains("else"))
        XCTAssertTrue(serialized.contains("fi"))
    }

    func testSerializeForLoop() throws {
        let parser = ShellParser()
        let script = try parser.parse("for x in a b c; do echo $x; done")
        let serialized = ASTSerializer.serialize(script)
        XCTAssertTrue(serialized.contains("for x in"))
        XCTAssertTrue(serialized.contains("do"))
        XCTAssertTrue(serialized.contains("done"))
    }

    func testSerializeArithForLoop() throws {
        let parser = ShellParser()
        let script = try parser.parse("for (( i=0; i<3; i++ )); do echo $i; done")
        let serialized = ASTSerializer.serialize(script)
        XCTAssertTrue(serialized.contains("for (("))
        XCTAssertTrue(serialized.contains("done"))
    }

    func testSerializeCaseClause() throws {
        let parser = ShellParser()
        let script = try parser.parse("case $x in a) echo a;; b) echo b;; esac")
        let serialized = ASTSerializer.serialize(script)
        XCTAssertTrue(serialized.contains("case"))
        XCTAssertTrue(serialized.contains("esac"))
    }

    func testSerializeAssignment() throws {
        let parser = ShellParser()
        let script = try parser.parse("x=hello")
        let serialized = ASTSerializer.serialize(script)
        XCTAssertEqual(serialized, "x=hello")
    }

    func testSerializeRedirection() throws {
        let parser = ShellParser()
        let script = try parser.parse("echo hello > out.txt")
        let serialized = ASTSerializer.serialize(script)
        XCTAssertTrue(serialized.contains(">"))
        XCTAssertTrue(serialized.contains("out.txt"))
    }

    // MARK: - Transform Pipeline

    func testPipelineRunsInOrder() throws {
        let parser = ShellParser()
        let script = try parser.parse("echo a; ls; grep x")

        let c1 = CommandCollector()
        let c2 = CommandCollector()
        let pipeline = ASTTransformPipeline()
        pipeline.add(c1)
        pipeline.add(c2)

        _ = pipeline.run(script)

        // Both collectors should have collected the same commands
        XCTAssertEqual(c1.commands, ["echo", "ls", "grep"])
        XCTAssertEqual(c2.commands, ["echo", "ls", "grep"])
    }

    func testPipelinePluginNames() {
        let pipeline = ASTTransformPipeline()
        let c = CommandCollector()
        pipeline.add(c)
        XCTAssertEqual(pipeline.pluginNames, ["command-collector"])
    }

    func testPipelineRemove() {
        let pipeline = ASTTransformPipeline()
        pipeline.add(CommandCollector())
        XCTAssertEqual(pipeline.pluginNames.count, 1)
        pipeline.remove(named: "command-collector")
        XCTAssertEqual(pipeline.pluginNames.count, 0)
    }

    // MARK: - ASTVisitor

    func testASTVisitorCountsCommands() throws {
        struct Counter: ASTVisitor {
            var count = 0
            mutating func visitSimpleCommand(_ simple: SimpleCommand) {
                count += 1
            }
        }

        let parser = ShellParser()
        let script = try parser.parse("echo a | grep b; ls")
        var counter = Counter()
        counter.visitScript(script)
        XCTAssertEqual(counter.count, 3)
    }
}
