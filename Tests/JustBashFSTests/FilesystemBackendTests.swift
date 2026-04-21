import XCTest
@testable import JustBashFS

// MARK: - OverlayFileSystem Tests

final class OverlayFileSystemTests: XCTestCase {

    private var tempDir: String!

    override func setUp() {
        super.setUp()
        tempDir = NSTemporaryDirectory() + "OverlayFSTest-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        // Seed some files on disk
        FileManager.default.createFile(atPath: tempDir + "/hello.txt", contents: Data("disk-hello".utf8))
        try? FileManager.default.createDirectory(atPath: tempDir + "/subdir", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: tempDir + "/subdir/nested.txt", contents: Data("nested".utf8))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tempDir)
        super.tearDown()
    }

    func testReadFromDisk() throws {
        let fs = OverlayFileSystem(base: tempDir)
        let data = try fs.readFile(path: "/hello.txt", relativeTo: "/")
        XCTAssertEqual(String(data: data, encoding: .utf8), "disk-hello")
    }

    func testWriteStaysInMemory() throws {
        let fs = OverlayFileSystem(base: tempDir)
        try fs.writeFile(path: "/hello.txt", content: Data("overlay-hello".utf8), relativeTo: "/")

        // Overlay returns the in-memory version
        let data = try fs.readFile(path: "/hello.txt", relativeTo: "/")
        XCTAssertEqual(String(data: data, encoding: .utf8), "overlay-hello")

        // Disk is untouched
        let diskData = FileManager.default.contents(atPath: tempDir + "/hello.txt")
        XCTAssertEqual(String(data: diskData!, encoding: .utf8), "disk-hello")
    }

    func testWriteNewFile() throws {
        let fs = OverlayFileSystem(base: tempDir)
        try fs.writeFile(path: "/new.txt", content: Data("new".utf8), relativeTo: "/")
        let data = try fs.readFile(path: "/new.txt", relativeTo: "/")
        XCTAssertEqual(String(data: data, encoding: .utf8), "new")
        // Not on disk
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir + "/new.txt"))
    }

    func testDeleteCreatesWhiteout() throws {
        let fs = OverlayFileSystem(base: tempDir)
        XCTAssertTrue(fs.fileExists(path: "/hello.txt", relativeTo: "/"))
        try fs.deleteFile(path: "/hello.txt", relativeTo: "/", recursive: false, force: false)
        XCTAssertFalse(fs.fileExists(path: "/hello.txt", relativeTo: "/"))
        // Disk still has it
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir + "/hello.txt"))
    }

    func testListDirectoryMergesDiskAndOverlay() throws {
        let fs = OverlayFileSystem(base: tempDir)
        try fs.writeFile(path: "/overlay-only.txt", content: Data("x".utf8), relativeTo: "/")
        let entries = try fs.listDirectory(path: "/", relativeTo: "/")
        XCTAssertTrue(entries.contains("hello.txt"))
        XCTAssertTrue(entries.contains("overlay-only.txt"))
        XCTAssertTrue(entries.contains("subdir"))
    }

    func testListDirectoryHidesWhiteouts() throws {
        let fs = OverlayFileSystem(base: tempDir)
        try fs.deleteFile(path: "/hello.txt", relativeTo: "/", recursive: false, force: false)
        let entries = try fs.listDirectory(path: "/", relativeTo: "/")
        XCTAssertFalse(entries.contains("hello.txt"))
    }

    func testFileExists() throws {
        let fs = OverlayFileSystem(base: tempDir)
        XCTAssertTrue(fs.fileExists(path: "/hello.txt", relativeTo: "/"))
        XCTAssertTrue(fs.isDirectory(path: "/subdir", relativeTo: "/"))
        XCTAssertFalse(fs.fileExists(path: "/nope.txt", relativeTo: "/"))
    }

    func testCreateDirectoryInOverlay() throws {
        let fs = OverlayFileSystem(base: tempDir)
        try fs.createDirectory(path: "/newdir", relativeTo: "/", recursive: false)
        XCTAssertTrue(fs.isDirectory(path: "/newdir", relativeTo: "/"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir + "/newdir"))
    }

    func testFileInfoFromDisk() throws {
        let fs = OverlayFileSystem(base: tempDir)
        let info = try fs.fileInfo(path: "/hello.txt", relativeTo: "/")
        XCTAssertEqual(info.kind, .file)
        XCTAssertEqual(info.size, "disk-hello".utf8.count)
    }

    func testWalk() throws {
        let fs = OverlayFileSystem(base: tempDir)
        let paths = try fs.walk(path: "/", relativeTo: "/")
        XCTAssertTrue(paths.contains("/"))
        XCTAssertTrue(paths.contains("/hello.txt"))
        XCTAssertTrue(paths.contains("/subdir"))
        XCTAssertTrue(paths.contains("/subdir/nested.txt"))
    }

    func testNestedRead() throws {
        let fs = OverlayFileSystem(base: tempDir)
        let data = try fs.readFile(path: "/subdir/nested.txt", relativeTo: "/")
        XCTAssertEqual(String(data: data, encoding: .utf8), "nested")
    }

    func testRecursiveDelete() throws {
        let fs = OverlayFileSystem(base: tempDir)
        try fs.deleteFile(path: "/subdir", relativeTo: "/", recursive: true, force: false)
        XCTAssertFalse(fs.fileExists(path: "/subdir", relativeTo: "/"))
        XCTAssertFalse(fs.fileExists(path: "/subdir/nested.txt", relativeTo: "/"))
    }
}

// MARK: - ReadWriteFileSystem Tests

final class ReadWriteFileSystemTests: XCTestCase {

    private var tempDir: String!

    override func setUp() {
        super.setUp()
        tempDir = NSTemporaryDirectory() + "ReadWriteFSTest-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tempDir)
        super.tearDown()
    }

    func testWriteAndRead() throws {
        let fs = ReadWriteFileSystem(base: tempDir)
        try fs.writeFile(path: "/test.txt", content: Data("hello".utf8), relativeTo: "/")
        let data = try fs.readFile(path: "/test.txt", relativeTo: "/")
        XCTAssertEqual(String(data: data, encoding: .utf8), "hello")
        // Actually on disk
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir + "/test.txt"))
    }

    func testDelete() throws {
        let fs = ReadWriteFileSystem(base: tempDir)
        try fs.writeFile(path: "/delete-me.txt", content: Data("x".utf8), relativeTo: "/")
        try fs.deleteFile(path: "/delete-me.txt", relativeTo: "/", recursive: false, force: false)
        XCTAssertFalse(fs.fileExists(path: "/delete-me.txt", relativeTo: "/"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir + "/delete-me.txt"))
    }

    func testCreateAndListDirectory() throws {
        let fs = ReadWriteFileSystem(base: tempDir)
        try fs.createDirectory(path: "/mydir", relativeTo: "/", recursive: false)
        XCTAssertTrue(fs.isDirectory(path: "/mydir", relativeTo: "/"))
        try fs.writeFile(path: "/mydir/a.txt", content: Data("a".utf8), relativeTo: "/")
        let entries = try fs.listDirectory(path: "/mydir", relativeTo: "/")
        XCTAssertEqual(entries, ["a.txt"])
    }

    func testFileInfo() throws {
        let fs = ReadWriteFileSystem(base: tempDir)
        try fs.writeFile(path: "/info.txt", content: Data("1234".utf8), relativeTo: "/")
        let info = try fs.fileInfo(path: "/info.txt", relativeTo: "/")
        XCTAssertEqual(info.kind, .file)
        XCTAssertEqual(info.size, 4)
    }

    func testWalk() throws {
        let fs = ReadWriteFileSystem(base: tempDir)
        try fs.createDirectory(path: "/a", relativeTo: "/", recursive: false)
        try fs.writeFile(path: "/a/b.txt", content: Data("b".utf8), relativeTo: "/")
        let paths = try fs.walk(path: "/", relativeTo: "/")
        XCTAssertTrue(paths.contains("/"))
        XCTAssertTrue(paths.contains("/a"))
        XCTAssertTrue(paths.contains("/a/b.txt"))
    }

    func testNotFoundThrows() {
        let fs = ReadWriteFileSystem(base: tempDir)
        XCTAssertThrowsError(try fs.readFile(path: "/nope", relativeTo: "/"))
    }

    func testDeleteForce() throws {
        let fs = ReadWriteFileSystem(base: tempDir)
        // Should not throw
        try fs.deleteFile(path: "/nope", relativeTo: "/", recursive: false, force: true)
    }
}

// MARK: - MountableFileSystem Tests

final class MountableFileSystemTests: XCTestCase {

    func testRoutesToCorrectBackend() throws {
        let mem1 = VirtualFileSystem()
        let mem2 = VirtualFileSystem()
        try mem1.writeFile("from-root", to: "/root-file.txt")
        try mem2.writeFile("from-app", to: "/config.json")

        let fs = MountableFileSystem(root: mem1)
        fs.mount(mem2, at: "/app")

        // Root filesystem
        let rootData = try fs.readFile(path: "/root-file.txt", relativeTo: "/")
        XCTAssertEqual(String(data: rootData, encoding: .utf8), "from-root")

        // Mounted filesystem
        let appData = try fs.readFile(path: "/app/config.json", relativeTo: "/")
        XCTAssertEqual(String(data: appData, encoding: .utf8), "from-app")
    }

    func testMountPointAppearsAsDirectory() {
        let mem = VirtualFileSystem()
        let fs = MountableFileSystem(root: mem)
        fs.mount(VirtualFileSystem(), at: "/data")

        XCTAssertTrue(fs.fileExists(path: "/data", relativeTo: "/"))
        XCTAssertTrue(fs.isDirectory(path: "/data", relativeTo: "/"))
    }

    func testListDirectoryIncludesMountPoints() throws {
        let root = VirtualFileSystem()
        let fs = MountableFileSystem(root: root)
        fs.mount(VirtualFileSystem(), at: "/mnt")

        let entries = try fs.listDirectory(path: "/", relativeTo: "/")
        XCTAssertTrue(entries.contains("mnt"))
    }

    func testWriteToMount() throws {
        let root = VirtualFileSystem()
        let data = VirtualFileSystem()
        let fs = MountableFileSystem(root: root)
        fs.mount(data, at: "/data")

        try fs.writeFile(path: "/data/out.txt", content: Data("hello".utf8), relativeTo: "/")
        let read = try fs.readFile(path: "/data/out.txt", relativeTo: "/")
        XCTAssertEqual(String(data: read, encoding: .utf8), "hello")

        // Verify it went to the data backend
        XCTAssertTrue(data.exists("/out.txt"))
    }

    func testUnmount() throws {
        let root = VirtualFileSystem()
        let mounted = VirtualFileSystem()
        try mounted.writeFile("secret", to: "/file.txt")
        let fs = MountableFileSystem(root: root)
        fs.mount(mounted, at: "/secret")

        XCTAssertTrue(fs.fileExists(path: "/secret/file.txt", relativeTo: "/"))
        fs.unmount(at: "/secret")
        XCTAssertFalse(fs.fileExists(path: "/secret/file.txt", relativeTo: "/"))
    }

    func testMountPoints() {
        let fs = MountableFileSystem(root: VirtualFileSystem())
        fs.mount(VirtualFileSystem(), at: "/a")
        fs.mount(VirtualFileSystem(), at: "/b")
        let points = fs.mountPoints
        XCTAssertTrue(points.contains("/a"))
        XCTAssertTrue(points.contains("/b"))
    }

    func testLongestPrefixWins() throws {
        let root = VirtualFileSystem()
        let outer = VirtualFileSystem()
        let inner = VirtualFileSystem()
        try outer.writeFile("outer", to: "/file.txt")
        try inner.writeFile("inner", to: "/file.txt")

        let fs = MountableFileSystem(root: root)
        fs.mount(outer, at: "/mnt")
        fs.mount(inner, at: "/mnt/deep")

        let outerData = try fs.readFile(path: "/mnt/file.txt", relativeTo: "/")
        XCTAssertEqual(String(data: outerData, encoding: .utf8), "outer")

        let innerData = try fs.readFile(path: "/mnt/deep/file.txt", relativeTo: "/")
        XCTAssertEqual(String(data: innerData, encoding: .utf8), "inner")
    }

    func testWalkAcrossMounts() throws {
        let root = VirtualFileSystem()
        let mounted = VirtualFileSystem()
        try mounted.writeFile("hi", to: "/a.txt")

        let fs = MountableFileSystem(root: root)
        fs.mount(mounted, at: "/mnt")

        let paths = try fs.walk(path: "/mnt", relativeTo: "/")
        XCTAssertTrue(paths.contains("/mnt"))
        XCTAssertTrue(paths.contains("/mnt/a.txt"))
    }
}
