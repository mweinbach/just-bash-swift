import Foundation
import XCTest

final class PrimaryRuntimeSkillsIOSCheckerTests: XCTestCase {
    func testCheckerReportsConcreteIOSBlockersForCachedPrimaryRuntimeSkills() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let checker = repoRoot.appendingPathComponent("scripts/check_primary_runtime_skills_ios.py")
        let documentsSkill = URL(fileURLWithPath: "/Users/mweinbach/.codex/plugins/cache/openai-primary-runtime/documents/26.430.10722/skills/documents/SKILL.md")

        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: checker.path)
                && FileManager.default.fileExists(atPath: documentsSkill.path),
            "Primary-runtime skill cache is not available on this machine"
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", checker.path, "--json"]
        process.currentDirectoryURL = repoRoot

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = String(
            data: stderr.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, errorOutput)

        let payload = try JSONSerialization.jsonObject(with: output) as? [String: Any]
        XCTAssertEqual(payload?["overall"] as? String, "blocked")

        let reports = try XCTUnwrap(payload?["reports"] as? [[String: Any]])
        let documents = try XCTUnwrap(report(named: "documents", in: reports))
        let presentations = try XCTUnwrap(report(named: "presentations", in: reports))
        let spreadsheets = try XCTUnwrap(report(named: "spreadsheets", in: reports))

        XCTAssertEqual(documents["status"] as? String, "blocked")
        XCTAssertContainsFinding(
            in: documents,
            containing: "real lxml/python-docx OOXML behavior"
        )
        XCTAssertContainsFinding(
            in: documents,
            containing: "soffice/LibreOffice"
        )

        XCTAssertEqual(presentations["status"] as? String, "blocked")
        XCTAssertContainsFinding(in: presentations, containing: "skia-canvas")
        XCTAssertContainsFinding(in: presentations, containing: "Walnut")

        XCTAssertEqual(spreadsheets["status"] as? String, "blocked")
        XCTAssertContainsFinding(in: spreadsheets, containing: "skia-canvas")
        XCTAssertContainsFinding(
            in: spreadsheets,
            containing: "optional spreadsheet extraction packages"
        )
    }

    private func report(named name: String, in reports: [[String: Any]]) -> [String: Any]? {
        reports.first { $0["name"] as? String == name }
    }

    private func XCTAssertContainsFinding(
        in report: [String: Any],
        containing needle: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let findings = report["findings"] as? [[String: Any]] ?? []
        let messages = findings.compactMap { $0["message"] as? String }
        XCTAssertTrue(
            messages.contains { $0.contains(needle) },
            "Expected finding containing '\(needle)' in messages: \(messages)",
            file: file,
            line: line
        )
    }
}
