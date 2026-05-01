import Foundation
import XCTest

final class PrimaryRuntimeSkillsIOSCheckerTests: XCTestCase {
    func testCheckerReportsConcreteIOSBlockersForCachedPrimaryRuntimeSkills() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let checker = repoRoot.appendingPathComponent("scripts/check_primary_runtime_skills_ios.py")

        let payload = try runChecker(checker, repoRoot: repoRoot)
        assertBlockedSkillReports(in: payload)
    }

    func testCheckerAcceptsExplicitSkillFamilyRoots() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let checker = repoRoot.appendingPathComponent("scripts/check_primary_runtime_skills_ios.py")
        let cacheRoot = "/Users/mweinbach/.codex/plugins/cache/openai-primary-runtime"
        let artifactToolRoot = "/Users/mweinbach/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/@oai/artifact-tool"

        let payload = try runChecker(
            checker,
            repoRoot: repoRoot,
            extraArguments: [
                "--documents-root", "\(cacheRoot)/documents",
                "--presentations-root", "\(cacheRoot)/presentations",
                "--spreadsheets-root", "\(cacheRoot)/spreadsheets",
                "--artifact-tool-root", artifactToolRoot,
            ]
        )
        assertBlockedSkillReports(in: payload)
    }

    func testStagedCompatibilityCanRunRepresentativeCachedHelpers() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let smokeScript = repoRoot.appendingPathComponent("scripts/smoke_primary_runtime_skill_helpers.py")
        let presentationsSkillFamily = URL(
            fileURLWithPath: "/Users/mweinbach/.codex/plugins/cache/openai-primary-runtime/presentations"
        )

        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: smokeScript.path)
                && FileManager.default.fileExists(atPath: presentationsSkillFamily.path),
            "Primary-runtime presentation/spreadsheet skill cache is not available on this machine"
        )
        try XCTSkipUnless(commandSucceeds("node", "--version"), "Node is required for cached helper smoke")

        let payload = try runJSONCommand(
            ["python3", smokeScript.path, "--json"],
            repoRoot: repoRoot
        )

        XCTAssertEqual(payload["overall"] as? String, "ok")
        guard let checks = payload["checks"] as? [[String: Any]] else {
            XCTFail("Missing smoke checks in payload: \(payload)")
            return
        }
        XCTAssertContainsCheck(named: "presentations.build_artifact_deck", in: checks)
        XCTAssertContainsCheck(named: "presentations.render_lucide_icon", in: checks)
        XCTAssertContainsCheck(named: "spreadsheets.artifact_tool_api", in: checks)
    }

    private func runChecker(
        _ checker: URL,
        repoRoot: URL,
        extraArguments: [String] = []
    ) throws -> [String: Any] {
        let documentsSkillFamily = URL(fileURLWithPath: "/Users/mweinbach/.codex/plugins/cache/openai-primary-runtime/documents")

        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: checker.path)
                && FileManager.default.fileExists(atPath: documentsSkillFamily.path),
            "Primary-runtime skill cache is not available on this machine"
        )

        return try runJSONCommand(["python3", checker.path, "--json"] + extraArguments, repoRoot: repoRoot)
    }

    private func runJSONCommand(_ arguments: [String], repoRoot: URL) throws -> [String: Any] {
        let output = try runCommand(arguments, repoRoot: repoRoot)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: output.stdout) as? [String: Any])
    }

    private func runCommand(_ arguments: [String], repoRoot: URL) throws -> (stdout: Data, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
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
        return (output, errorOutput)
    }

    private func commandSucceeds(_ arguments: String...) throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = Array(arguments)
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private func assertBlockedSkillReports(in payload: [String: Any]) {
        XCTAssertEqual(payload["overall"] as? String, "blocked")

        guard let reports = payload["reports"] as? [[String: Any]],
              let documents = report(named: "documents", in: reports),
              let presentations = report(named: "presentations", in: reports),
              let spreadsheets = report(named: "spreadsheets", in: reports) else {
            XCTFail("Missing one or more skill reports in payload: \(payload)")
            return
        }

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
        XCTAssertContainsFinding(in: presentations, containing: "no browser/iOS export condition")
        XCTAssertContainsFinding(in: presentations, containing: "render basic presentation slides to PNG")
        XCTAssertContainsFinding(in: presentations, containing: "cached helper CLI/runtime conventions")
        XCTAssertContainsFinding(in: presentations, containing: "lucide compatibility package")
        XCTAssertContainsFinding(in: presentations, containing: "child_process.spawnSync")
        XCTAssertContainsFinding(in: presentations, containing: "Python presentation fan-out")
        XCTAssertContainsFinding(in: presentations, containing: "arbitrary process spawning remains unavailable")
        XCTAssertContainsFinding(in: presentations, containing: "sharp compatibility package")
        XCTAssertContainsFinding(in: presentations, containing: "native sharp/skia-canvas rendering remains unavailable")
        XCTAssertContainsFinding(in: presentations, containing: "skia-canvas")
        XCTAssertContainsFinding(in: presentations, containing: "Walnut")

        XCTAssertEqual(spreadsheets["status"] as? String, "blocked")
        XCTAssertContainsFinding(in: spreadsheets, containing: "common spreadsheet structural APIs")
        XCTAssertContainsFinding(in: spreadsheets, containing: "import uncompressed XLSX")
        XCTAssertContainsFinding(in: spreadsheets, containing: "render basic worksheet ranges to PNG")
        XCTAssertContainsFinding(in: spreadsheets, containing: "no browser/iOS export condition")
        XCTAssertContainsFinding(in: spreadsheets, containing: "computes common arithmetic/range formulas")
        XCTAssertContainsFinding(in: spreadsheets, containing: "Swift JavaScriptCore test covers spreadsheet skill core authoring")
        XCTAssertContainsFinding(in: spreadsheets, containing: "not the full Excel calculation engine")
        XCTAssertContainsFinding(in: spreadsheets, containing: "exports native XLSX chart parts")
        XCTAssertContainsFinding(in: spreadsheets, containing: "not the full Excel chart engine")
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

    private func XCTAssertContainsCheck(
        named name: String,
        in checks: [[String: Any]],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let check = checks.first(where: { $0["name"] as? String == name }) else {
            XCTFail("Missing smoke check named \(name): \(checks)", file: file, line: line)
            return
        }
        XCTAssertEqual(check["status"] as? String, "ok", file: file, line: line)
    }
}
