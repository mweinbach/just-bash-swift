import XCTest
@testable import JustBashFS

final class VirtualFileSystemTests: XCTestCase {
    func testSeedsDefaultLayout() throws {
        let fs = VirtualFileSystem()
        XCTAssertTrue(fs.isDirectory("/bin"))
        XCTAssertTrue(fs.isDirectory("/usr/bin"))
        XCTAssertTrue(try fs.readFile("/proc/version").contains("Swift Virtual Kernel"))
    }

    func testReadWriteAndRemove() throws {
        let fs = VirtualFileSystem()
        try fs.writeFile("hello", to: "/tmp/hello.txt")
        XCTAssertEqual(try fs.readFile("/tmp/hello.txt"), "hello")
        try fs.removeItem("/tmp/hello.txt")
        XCTAssertFalse(fs.exists("/tmp/hello.txt"))
    }
}
