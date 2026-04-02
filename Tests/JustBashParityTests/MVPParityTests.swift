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

private func loadFixtures(_ filename: String) throws -> [Fixture] {
    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Fixtures/upstream/comparison/\(filename)")
    return try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url))
}

private func runFixtures(_ fixtures: [Fixture], file: StaticString = #filePath, line: UInt = #line) async {
    for fixture in fixtures {
        let bash = Bash(options: .init(files: fixture.files))
        let result = await bash.exec(fixture.script)
        XCTAssertEqual(result.stdout, fixture.stdout, "\(fixture.name) — stdout", file: file, line: line)
        XCTAssertEqual(result.stderr, fixture.stderr, "\(fixture.name) — stderr", file: file, line: line)
        XCTAssertEqual(result.exitCode, fixture.exitCode, "\(fixture.name) — exitCode", file: file, line: line)
    }
}

final class MVPParityTests: XCTestCase {
    func testMVPFixtures() async throws {
        let fixtures = try loadFixtures("mvp.json")
        await runFixtures(fixtures)
    }

    func testRedirectionFixtures() async throws {
        let fixtures = try loadFixtures("redirections.json")
        await runFixtures(fixtures)
    }

    func testSubstitutionFixtures() async throws {
        let fixtures = try loadFixtures("substitution.json")
        await runFixtures(fixtures)
    }

    func testGlobbingFixtures() async throws {
        let fixtures = try loadFixtures("globbing.json")
        await runFixtures(fixtures)
    }

    func testAliasFixtures() async throws {
        let fixtures = try loadFixtures("alias.json")
        await runFixtures(fixtures)
    }

    func testParseErrorFixtures() async throws {
        let fixtures = try loadFixtures("parse_errors.json")
        await runFixtures(fixtures)
    }

    func testShellBuiltinsFixtures() async throws {
        let fixtures = try loadFixtures("shell_builtins.json")
        await runFixtures(fixtures)
    }

    func testAdvancedFeaturesFixtures() async throws {
        let fixtures = try loadFixtures("advanced_features.json")
        await runFixtures(fixtures)
    }
}
