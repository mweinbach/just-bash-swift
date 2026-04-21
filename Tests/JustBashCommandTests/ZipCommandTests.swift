import XCTest
@testable import JustBash

final class ZipCommandTests: XCTestCase {
    
    func testZipCreate() async {
        let bash = Bash()
        
        // Create a test file
        _ = await bash.exec("echo 'Hello, World!' > /tmp/test.txt")
        
        // Create zip archive
        let result = await bash.exec("cd /tmp && zip archive.zip test.txt")
        XCTAssertEqual(result.exitCode, 0)
        
        // Verify archive was created
        let exists = await bash.exec("test -f /tmp/archive.zip && echo 'exists'")
        XCTAssertEqual(exists.stdout, "exists\n")
    }
    
    func testUnzipList() async {
        let bash = Bash()
        
        // Create a test file and zip it
        _ = await bash.exec("echo 'Hello' > /tmp/list.txt && cd /tmp && zip list.zip list.txt")
        
        // List contents
        let result = await bash.exec("unzip -l /tmp/list.zip")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("list.txt"))
        XCTAssertTrue(result.stdout.contains("Length"))
    }
    
    func testZipRecursive() async {
        let bash = Bash()
        
        // Create directory structure
        _ = await bash.exec("mkdir -p /tmp/zipdir/subdir && echo 'file1' > /tmp/zipdir/file1.txt && echo 'file2' > /tmp/zipdir/subdir/file2.txt")
        
        // Create recursive zip
        let result = await bash.exec("cd /tmp && zip -r recursive.zip zipdir")
        XCTAssertEqual(result.exitCode, 0)
        
        // List should show both files
        let list = await bash.exec("unzip -l /tmp/recursive.zip")
        XCTAssertTrue(list.stdout.contains("file1.txt"))
        XCTAssertTrue(list.stdout.contains("file2.txt"))
    }
    
    func testZipUnzipRoundTrip() async throws {
        let bash = Bash()
        
        // Create and zip
        _ = await bash.exec("echo 'Round trip content' > /tmp/round.txt && cd /tmp && zip round.zip round.txt && rm round.txt")
        
        // Unzip
        let result = await bash.exec("cd /tmp && unzip round.zip")
        XCTAssertEqual(result.exitCode, 0)
        
        // Verify content
        let cat = await bash.exec("cat /tmp/round.txt")
        XCTAssertEqual(cat.stdout, "Round trip content\n")
    }
    
    func testZipHelp() async {
        let bash = Bash()
        let result = await bash.exec("zip -h")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("zip"))
    }
    
    func testUnzipHelp() async {
        let bash = Bash()
        let result = await bash.exec("unzip --help")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("unzip"))
    }
    
    func testZipNoArgs() async {
        let bash = Bash()
        let result = await bash.exec("zip")
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("error"))
    }
}
