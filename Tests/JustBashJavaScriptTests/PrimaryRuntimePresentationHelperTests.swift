import Foundation
import XCTest
@testable import JustBash
@testable import JustBashJavaScript

final class PrimaryRuntimePresentationHelperTests: XCTestCase {
    func testPresentationAuthoringAndRoundTripInJavaScriptCore() async throws {
        var files = OAIPrimaryRuntimeSupport.packageFiles(configuration: .init(
            artifactToolRoots: ["/workspace/node_modules/@oai/artifact-tool"],
            lucideRoots: [], sharpRoots: []
        ))
        files["/workspace/presentation-smoke.mjs"] = try String(
            contentsOf: Bundle.module.url(forResource: "presentation-smoke", withExtension: "mjs", subdirectory: "Fixtures")!,
            encoding: .utf8
        )
        let bash = Bash(options: .init(files: files, cwd: "/workspace", embeddedRuntimes: [JavaScriptRuntime()]))
        let result = await bash.exec("js-exec -m presentation-smoke.mjs")
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(result.stdout, "ok\n")
        let layout = try await bash.readFile("/workspace/output/slide.layout.json")
        XCTAssertTrue(layout.contains("iOS presentation round trip"))
        let artifacts = await bash.exec("test -s output/slide.png && test -s output/deck.pptx && echo ok")
        XCTAssertEqual(artifacts.stdout, "ok\n", artifacts.stderr)
        XCTAssertEqual(artifacts.exitCode, 0)
    }
}
