import XCTest
@testable import JustBash

final class XanCommandTests: XCTestCase {
    
    // MARK: - CSV Parser Tests
    
    func testCSVParserBasic() async {
        let bash = Bash(options: .init(files: [
            "/tmp/test.csv": "name,age\nAlice,30\nBob,25"
        ]))
        
        let result = await bash.exec("xan view /tmp/test.csv")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("name"))
        XCTAssertTrue(result.stdout.contains("Alice"))
        XCTAssertTrue(result.stdout.contains("30"))
    }
    
    func testCSVParserQuotes() async {
        let bash = Bash(options: .init(files: [
            "/tmp/quotes.csv": "name,desc\n\"Alice Smith\",\"Hello, world!\""
        ]))
        
        let result = await bash.exec("xan view /tmp/quotes.csv")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("Alice Smith"))
    }
    
    func testCSVCount() async {
        let bash = Bash(options: .init(files: [
            "/tmp/count.csv": "a,b\n1,2\n3,4\n5,6"
        ]))
        
        let result = await bash.exec("xan count /tmp/count.csv")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "3\n")
    }
    
    func testCSVHeaders() async {
        let bash = Bash(options: .init(files: [
            "/tmp/headers.csv": "name,age,city\nAlice,30,NYC"
        ]))
        
        let result = await bash.exec("xan headers /tmp/headers.csv")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("1:\tname"))
        XCTAssertTrue(result.stdout.contains("2:\tage"))
        XCTAssertTrue(result.stdout.contains("3:\tcity"))
    }
    
    func testCSVSelectByIndex() async {
        let bash = Bash(options: .init(files: [
            "/tmp/select.csv": "a,b,c\n1,2,3\n4,5,6"
        ]))
        
        let result = await bash.exec("xan select 1,3 /tmp/select.csv")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "a,c\n1,3\n4,6\n")
    }
    
    func testCSVSelectByName() async {
        let bash = Bash(options: .init(files: [
            "/tmp/select_name.csv": "name,age,city\nAlice,30,NYC\nBob,25,LA"
        ]))
        
        let result = await bash.exec("xan select name,city /tmp/select_name.csv")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "name,city\nAlice,NYC\nBob,LA\n")
    }
    
    func testCSVHead() async {
        var csv = "n\n"
        for i in 1...20 {
            csv += "\(i)\n"
        }
        let bash = Bash(options: .init(files: ["/tmp/head.csv": csv]))
        
        let result = await bash.exec("xan head 5 /tmp/head.csv")
        XCTAssertEqual(result.exitCode, 0)
        let lines = result.stdout.split(separator: "\n")
        XCTAssertEqual(lines.count, 6) // header + 5 rows
    }
    
    func testCSVTail() async {
        var csv = "n\n"
        for i in 1...20 {
            csv += "\(i)\n"
        }
        let bash = Bash(options: .init(files: ["/tmp/tail.csv": csv]))
        
        let result = await bash.exec("xan tail 3 /tmp/tail.csv")
        XCTAssertEqual(result.exitCode, 0)
        let lines = result.stdout.split(separator: "\n")
        XCTAssertEqual(lines.count, 4) // header + 3 rows
    }
    
    func testCSVFilter() async {
        let bash = Bash(options: .init(files: [
            "/tmp/filter.csv": "name,age\nAlice,30\nBob,25\nCharlie,35"
        ]))
        
        let result = await bash.exec("xan filter 'age > 28' /tmp/filter.csv")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("Alice"))
        XCTAssertTrue(result.stdout.contains("Charlie"))
        XCTAssertFalse(result.stdout.contains("Bob"))
    }
    
    func testCSVSortNumeric() async {
        let bash = Bash(options: .init(files: [
            "/tmp/sort.csv": "n\n5\n1\n3\n2\n4"
        ]))
        
        let result = await bash.exec("xan sort 1 /tmp/sort.csv")
        XCTAssertEqual(result.exitCode, 0)
        let lines = result.stdout.split(separator: "\n")
        // Should be sorted: n, 1, 2, 3, 4, 5
        XCTAssertEqual(lines[1], "1")
        XCTAssertEqual(lines[5], "5")
    }
    
    func testCSVTsvOption() async {
        let bash = Bash(options: .init(files: [
            "/tmp/data.tsv": "name\tage\nAlice\t30\nBob\t25"
        ]))
        
        let result = await bash.exec("xan -t count /tmp/data.tsv")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "2\n")
    }
    
    func testCSVFrequency() async {
        let bash = Bash(options: .init(files: [
            "/tmp/freq.csv": "city\nNYC\nLA\nNYC\nChicago\nNYC"
        ]))
        
        let result = await bash.exec("xan freq 1 /tmp/freq.csv")
        XCTAssertEqual(result.exitCode, 0)
        // NYC should appear 3 times
        XCTAssertTrue(result.stdout.contains("NYC"))
        XCTAssertTrue(result.stdout.contains("3"))
    }
    
    func testCSVStats() async {
        let bash = Bash(options: .init(files: [
            "/tmp/stats.csv": "value\n10\n20\n30\n40\n50"
        ]))
        
        let result = await bash.exec("xan stats 1 /tmp/stats.csv")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("count:"))
        XCTAssertTrue(result.stdout.contains("mean:"))
    }
    
    func testCSVNoHeader() async {
        let bash = Bash(options: .init(files: [
            "/tmp/noheader.csv": "Alice,30\nBob,25"
        ]))
        
        let result = await bash.exec("xan --no-header count /tmp/noheader.csv")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "2\n")
    }
    
    func testXanHelp() async {
        let bash = Bash()
        let result = await bash.exec("xan help")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("xan - CSV processing tool"))
        XCTAssertTrue(result.stdout.contains("view"))
        XCTAssertTrue(result.stdout.contains("count"))
    }
    
    func testCSVFromStdin() async {
        let bash = Bash()
        let csv = "a,b\n1,2\n3,4"
        
        let result = await bash.exec("xan count", options: .init(stdin: csv))
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "2\n")
    }
}
