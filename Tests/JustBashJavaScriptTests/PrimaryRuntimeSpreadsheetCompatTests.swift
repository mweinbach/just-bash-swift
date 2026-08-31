import Foundation
import XCTest
@testable import JustBash
@testable import JustBashJavaScript

final class PrimaryRuntimeSpreadsheetCompatTests: XCTestCase {
    func testSpreadsheetSkillCoreAuthoringRunsAgainstStagedIOSCompatPackageInJavaScriptCore() async throws {
        var files = OAIPrimaryRuntimeSupport.packageFiles(configuration: .init(
            artifactToolRoots: [
                "/workspace/node_modules/@oai/artifact-tool",
                "/home/user/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/@oai/artifact-tool",
            ],
            lucideRoots: [],
            sharpRoots: []
        ))
        files["/workspace/spreadsheet-smoke.mjs"] = try String(
            contentsOf: Bundle.module.url(forResource: "spreadsheet-smoke", withExtension: "mjs", subdirectory: "Fixtures")!,
            encoding: .utf8
        )

        let bash = Bash(options: .init(
            files: files,
            cwd: "/workspace",
            embeddedRuntimes: [JavaScriptRuntime()]
        ))

        let result = await bash.exec("js-exec -m spreadsheet-smoke.mjs")
        XCTAssertEqual(result.exitCode, 0, "stdout: \(result.stdout)\nstderr: \(result.stderr)")
        XCTAssertEqual(result.stdout, "ok\n")

        let artifacts = await bash.exec(
            """
            test -s output/dashboard.png && \
            test -s output/dashboard.xlsx && \
            echo ok
            """
        )
        XCTAssertEqual(artifacts.exitCode, 0, "stdout: \(artifacts.stdout)\nstderr: \(artifacts.stderr)")
        XCTAssertEqual(artifacts.stdout, "ok\n")
    }
}
