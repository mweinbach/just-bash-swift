import CryptoKit
import Foundation
import XCTest

/// Synthetic bundles keep the contract independent of a personal Codex cache.
final class PrimaryRuntimeSkillsIOSCheckerTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    func testPinnedSnapshotIgnoresNewerUnverifiedBundle() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let newer = fixture.root.appendingPathComponent("presentations/99.0/skills/presentations")
        try FileManager.default.createDirectory(at: newer, withIntermediateDirectories: true)
        try Data("unverified".utf8).write(to: newer.appendingPathComponent("SKILL.md"))
        let (status, report) = try runChecker(fixture)
        XCTAssertEqual(status, 0)
        XCTAssertEqual(report["overall"] as? String, "ready")
        XCTAssertEqual(report["snapshotVersion"] as? String, "1.2.3")
        XCTAssertEqual(report["runtimeVerified"] as? Bool, false)
        XCTAssertEqual(report["pythonRequired"] as? Bool, false)
        let reports = try XCTUnwrap(report["reports"] as? [[String: Any]])
        XCTAssertTrue(reports.allSatisfy { ($0["root"] as? String)?.hasSuffix("/1.2.3") == true })
    }
    func testModifiedSkillFailsClosed() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try Data("changed".utf8).write(to: fixture.root.appendingPathComponent("documents/1.2.3/skills/documents/SKILL.md"))
        let (status, report) = try runChecker(fixture)
        XCTAssertEqual(status, 1)
        XCTAssertEqual(report["overall"] as? String, "blocked")
    }
    func testMissingPinnedBundleFailsClosed() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("spreadsheets/1.2.3"))
        let (status, report) = try runChecker(fixture)
        XCTAssertEqual(status, 1)
        XCTAssertEqual(report["overall"] as? String, "blocked")
    }
    private struct Fixture { let root: URL; let manifest: URL }
    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("justbash-snapshot-\(UUID().uuidString)")
        var families: [String: [String: String]] = [:]
        for family in ["documents", "presentations", "spreadsheets"] {
            let directory = root.appendingPathComponent("\(family)/1.2.3/skills/\(family)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = Data("# \(family)\nSynthetic test skill.\n".utf8)
            try data.write(to: directory.appendingPathComponent("SKILL.md"))
            families[family] = ["skillSHA256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()]
        }
        let manifest = root.appendingPathComponent("manifest.json")
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "snapshotVersion": "1.2.3", "supportLevel": "bounded-ios-compatibility", "families": families]).write(to: manifest)
        return Fixture(root: root, manifest: manifest)
    }
    private func runChecker(_ fixture: Fixture) throws -> (Int32, [String: Any]) {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", repoRoot.appendingPathComponent("scripts/check_primary_runtime_skills_ios.py").path,
                             "--cache-root", fixture.root.path, "--manifest", fixture.manifest.path, "--strict", "--json"]
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]))
    }
}
