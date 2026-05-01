import Foundation
import XCTest
@testable import JustBash
@testable import JustBashJavaScript

final class PrimaryRuntimePresentationHelperTests: XCTestCase {
    func testCachedPresentationHelpersRunAgainstStagedIOSCompatPackageInJavaScriptCore() async throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let presentationScripts = URL(
            fileURLWithPath: "/Users/mweinbach/.codex/plugins/cache/openai-primary-runtime/presentations/26.430.10722/skills/presentations/scripts"
        )

        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: presentationScripts.appendingPathComponent("render_artifact_slide.mjs").path),
            "Primary-runtime presentation skill cache is not available on this machine"
        )

        var files = try stagedPrimaryRuntimePackageFiles(repoRoot: repoRoot)
        for script in [
            "artifact_tool_utils.mjs",
            "build_artifact_deck.mjs",
            "check_layout_quality.mjs",
            "render_artifact_slide.mjs",
        ] {
            files["/workspace/scripts/\(script)"] = try String(
                contentsOf: presentationScripts.appendingPathComponent(script),
                encoding: .utf8
            )
        }
        files["/workspace/slides/slide-01.mjs"] = """
        export async function slide01(presentation, ctx) {
          const slide = presentation.slides.add();
          slide.background.fill = "rgb(255,255,255)";
          ctx.addText(slide, {
            name: "title",
            text: "iOS staged helper smoke",
            left: 56,
            top: 48,
            width: 760,
            height: 88,
            fontSize: 30,
            color: "rgb(17,24,39)",
            fill: "rgb(239,246,255)",
            line: ctx.line("rgb(37,99,235)", 2)
          });
          await ctx.addLucideIcon(slide, {
            icon: "Smartphone",
            left: 56,
            top: 168,
            width: 96,
            height: 96,
            color: "#2563eb",
            name: "phone-icon"
          });
          return slide;
        }
        """

        let bash = Bash(options: .init(
            files: files,
            cwd: "/workspace",
            embeddedRuntimes: [JavaScriptRuntime()]
        ))

        let render = await bash.exec(
            """
            js-exec scripts/render_artifact_slide.mjs \
              --slide-module slides/slide-01.mjs \
              --output output/rendered-slide.png \
              --layout output/rendered-slide.layout.json \
              --pptx output/rendered-slide.pptx \
              --scale 0.5
            """
        )
        XCTAssertEqual(render.exitCode, 0, "stdout: \(render.stdout)\nstderr: \(render.stderr)")

        let build = await bash.exec(
            """
            js-exec scripts/build_artifact_deck.mjs \
              --slides-dir slides \
              --out output/deck.pptx \
              --preview-dir output/previews \
              --layout-dir output/layouts \
              --manifest output/manifest.json \
              --slide-count 1 \
              --scale 0.5
            """
        )
        XCTAssertEqual(build.exitCode, 0, "stdout: \(build.stdout)\nstderr: \(build.stderr)")

        let quality = await bash.exec(
            "js-exec scripts/check_layout_quality.mjs --layout output/layouts --warn-only"
        )
        XCTAssertEqual(quality.exitCode, 0, "stdout: \(quality.stdout)\nstderr: \(quality.stderr)")

        let artifacts = await bash.exec(
            """
            test -s output/rendered-slide.png && \
            test -s output/rendered-slide.layout.json && \
            test -s output/rendered-slide.pptx && \
            test -s output/previews/slide-01.png && \
            test -s output/layouts/slide-01.layout.json && \
            test -s output/deck.pptx && \
            test -s output/manifest.json && \
            echo ok
            """
        )
        XCTAssertEqual(artifacts.exitCode, 0, "stdout: \(artifacts.stdout)\nstderr: \(artifacts.stderr)")
        XCTAssertEqual(artifacts.stdout, "ok\n")

        let layout = try await bash.readFile("/workspace/output/rendered-slide.layout.json")
        XCTAssertTrue(layout.contains(#""name":"title""#) || layout.contains(#""name": "title""#))
        XCTAssertTrue(layout.contains("Smartphone icon"))
    }

    private func stagedPrimaryRuntimePackageFiles(repoRoot: URL) throws -> [String: String] {
        let sandboxService = repoRoot.appendingPathComponent("Apps/JustBashPhone/JustBashPhone/SandboxService.swift")
        let source = try String(contentsOf: sandboxService, encoding: .utf8)
        let strings = try Dictionary(
            uniqueKeysWithValues: [
                "artifactToolPackageJSON",
                "artifactToolCompatModule",
                "presentationJSXCompatModule",
                "presentationJSXRuntimeCompatModule",
                "lucidePackageJSON",
                "lucideCompatModule",
            ].map { name in
                (name, try extractSwiftRawString(named: name, from: source))
            }
        )

        let nodeModules = "/home/user/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules"
        let artifactRoot = "\(nodeModules)/@oai/artifact-tool"
        let lucideRoot = "\(nodeModules)/lucide"
        return [
            "\(artifactRoot)/package.json": strings["artifactToolPackageJSON"]!,
            "\(artifactRoot)/dist/artifact_tool.mjs": strings["artifactToolCompatModule"]!,
            "\(artifactRoot)/dist/presentation-jsx/index.mjs": strings["presentationJSXCompatModule"]!,
            "\(artifactRoot)/dist/presentation-jsx/jsx-runtime.mjs": strings["presentationJSXRuntimeCompatModule"]!,
            "\(artifactRoot)/dist/presentation-jsx/jsx-dev-runtime.mjs": strings["presentationJSXRuntimeCompatModule"]!,
            "\(lucideRoot)/package.json": strings["lucidePackageJSON"]!,
            "\(lucideRoot)/dist/index.mjs": strings["lucideCompatModule"]!,
        ]
    }

    private func extractSwiftRawString(named name: String, from source: String) throws -> String {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        let pattern = "private static let \(escapedName) = #\"\"\"\\n([\\s\\S]*?)\\n    \"\"\"#"
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        guard let match = regex.firstMatch(in: source, range: range),
              match.numberOfRanges == 2,
              let valueRange = Range(match.range(at: 1), in: source) else {
            throw NSError(
                domain: "PrimaryRuntimePresentationHelperTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not extract \(name) from SandboxService.swift"]
            )
        }
        return String(source[valueRange])
    }
}
