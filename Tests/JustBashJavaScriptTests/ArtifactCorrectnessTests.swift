import Foundation
import ImageIO
import XCTest
@testable import JustBash
@testable import JustBashJavaScript

final class ArtifactCorrectnessTests: XCTestCase {
    func testOfficeSemanticsAndNativePreviews() async throws {
        var files = OAIPrimaryRuntimeSupport.packageFiles(configuration: .init(
            artifactToolRoots: ["/workspace/node_modules/@oai/artifact-tool"], lucideRoots: [], sharpRoots: []
        ))
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "artifact-correctness", withExtension: "mjs", subdirectory: "Fixtures"))
        files["/workspace/correctness.mjs"] = try String(contentsOf: fixture, encoding: .utf8)
        let bash = Bash(options: .init(files: files, cwd: "/workspace", embeddedRuntimes: [JavaScriptRuntime()]))
        let result = await bash.exec("js-exec -m correctness.mjs")
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(result.stdout, "ok\n", result.stderr)
        let fs = await bash.fs
        for (name, width, height) in [("native-slide.png", 800, 600), ("native-sheet.png", 392, 256)] {
            let data = try fs.readFile(path: "/workspace/output/\(name)", relativeTo: "/")
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(image.width, width)
            XCTAssertEqual(image.height, height)
        }
        if let directory = ProcessInfo.processInfo.environment["JUSTBASH_ARTIFACT_OUTPUT_DIR"] {
            let output = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            for name in ["native-slide.png", "native-sheet.png", "correctness.pptx", "correctness.xlsx", "correctness.docx"] {
                let data = try fs.readFile(path: "/workspace/output/\(name)", relativeTo: "/")
                try data.write(to: output.appendingPathComponent(name))
            }
        }
    }
    func testJavaScriptArtifactReadinessDoesNotRequirePython() async throws {
        var options = BashOptions(cwd: "/workspace", embeddedRuntimes: [JavaScriptRuntime()])
        options.enableOAIPrimaryRuntime()
        let bash = Bash(options: options)
        let result = await bash.exec("primary-runtime-skills-check")
        XCTAssertEqual(result.exitCode, 0, result.stderr + result.stdout)
        let text = try await bash.readFile("/workspace/primary-runtime-skills-ios-report.json")
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(report["overall"] as? String, "ready")
        XCTAssertEqual(report["pythonRequired"] as? Bool, false)
    }
}
