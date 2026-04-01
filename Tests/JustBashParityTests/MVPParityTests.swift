import XCTest
@testable import JustBash

private struct Fixture: Decodable {
    let name: String
    let script: String
    let files: [String: String]
    let stdout: String
    let stderr: String
    let exitCode: Int
}

final class MVPParityTests: XCTestCase {
    func testFixtures() async throws {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Fixtures/upstream/comparison/mvp.json")
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url))
        for fixture in fixtures {
            let bash = Bash(options: .init(files: fixture.files))
            let result = await bash.exec(fixture.script)
            XCTAssertEqual(result.stdout, fixture.stdout, fixture.name)
            XCTAssertEqual(result.stderr, fixture.stderr, fixture.name)
            XCTAssertEqual(result.exitCode, fixture.exitCode, fixture.name)
        }
    }
}
