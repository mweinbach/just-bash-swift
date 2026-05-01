import Foundation
import XCTest
@testable import JustBash
@testable import JustBashJavaScript

final class PrimaryRuntimeSpreadsheetCompatTests: XCTestCase {
    func testSpreadsheetSkillCoreAuthoringRunsAgainstStagedIOSCompatPackageInJavaScriptCore() async throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let spreadsheetSkill = URL(
            fileURLWithPath: "/Users/mweinbach/.codex/plugins/cache/openai-primary-runtime/spreadsheets/26.430.10722/skills/spreadsheets/SKILL.md"
        )

        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: spreadsheetSkill.path),
            "Primary-runtime spreadsheet skill cache is not available on this machine"
        )

        var files = try stagedArtifactToolFiles(repoRoot: repoRoot)
        files["/workspace/spreadsheet-smoke.mjs"] = """
        import fs from "node:fs/promises";
        import { DocumentFile, DocumentModel, FileBlob, SpreadsheetFile, Workbook, SUM, Chart } from "@oai/artifact-tool";
        import { execSync } from "node:child_process";

        await fs.mkdir("/workspace/output", { recursive: true });
        const workbook = Workbook.create();
        const dashboard = workbook.worksheets.add("Dashboard");
        await workbook.fromCSV(`Region,Revenue,Cost
        North,120,70
        South,80,45`, { sheetName: "Source" });
        if (workbook.worksheets.getItem("Source").getRange("A2").values[0][0] !== "North") {
          throw new Error("CSV import failed");
        }

        dashboard.showGridLines = false;
        dashboard.getRange("A1:D1").values = [["iOS spreadsheet skill smoke", "", "", ""]];
        dashboard.getRange("A1:D1").merge();
        dashboard.getRange("A1:D1").format.fill.color = "rgb(239,246,255)";
        dashboard.getRange("A1:D1").format.font.bold = true;
        dashboard.getRange("A3:D5").values = [
          ["Region", "Revenue", "Cost", "Profit"],
          ["North", 120, 70, null],
          ["South", 80, 45, null]
        ];
        dashboard.getRange("D4:D5").formulas = [["=B4-C4"], ["=B5-C5"]];
        dashboard.getRange("D6").formulas = [["=SUM(D4:D5)"]];
        dashboard.getRange("A3:D5").getRow(0).format.font.bold = true;
        dashboard.getRange("B4:D6").setNumberFormat("$#,##0");
        dashboard.freezePanes.freezeRows(3);
        dashboard.getRange("A4:A5").dataValidation = {
          rule: { type: "list", source: ["North", "South"] }
        };

        const table = dashboard.tables.add("A3:D5", true, "DashboardTable");
        if (table.name !== "DashboardTable") throw new Error("table creation failed");
        const chart = dashboard.charts.add("column", dashboard.getRange("A3:D5"));
        chart.title = "Profit by Region";
        chart.setPosition("F2", "L14");
        if (dashboard.charts.count !== 1) throw new Error("chart creation failed");

        workbook.comments.setSelf({ displayName: "Just Bash iOS" });
        const thread = workbook.comments.addThread(
          { cell: dashboard.getRange("A1") },
          "Source: generated in JavaScriptCore"
        );
        if (thread.comments[0].text.indexOf("JavaScriptCore") === -1) {
          throw new Error("comment compatibility failed");
        }

        if (dashboard.getRange("D6").values[0][0] !== 85) throw new Error("formula total failed");
        const errors = await workbook.inspect({ kind: "formula", summary: "iOS spreadsheet skill smoke" });
        if (errors.errors.length) throw new Error("formula inspection found errors");
        const trace = JSON.parse(workbook.trace("Dashboard!D6").ndjson);
        if (!trace.dependencies || trace.dependencies.length < 2) {
          throw new Error("trace did not include total dependencies");
        }

        const preview = await workbook.render({ sheetName: "Dashboard", range: "A1:L14", scale: 1 });
        if (preview.mime !== "image/png" || (await preview.arrayBuffer()).length < 100) {
          throw new Error("worksheet render failed");
        }
        await preview.save("/workspace/output/dashboard.png");

        const xlsx = await SpreadsheetFile.exportXlsx(workbook);
        await xlsx.save("/workspace/output/dashboard.xlsx");
        const xlsxBytes = await xlsx.arrayBuffer();
        function includesAscii(bytes, text) {
          const needle = Array.from(text).map((ch) => ch.charCodeAt(0));
          for (let i = 0; i <= bytes.length - needle.length; i += 1) {
            let matched = true;
            for (let j = 0; j < needle.length; j += 1) {
              if (bytes[i + j] !== needle[j]) {
                matched = false;
                break;
              }
            }
            if (matched) return true;
          }
          return false;
        }
        if (!includesAscii(xlsxBytes, "xl/charts/chart1.xml") || !includesAscii(xlsxBytes, "xl/drawings/drawing1.xml")) {
          throw new Error("chart export parts missing");
        }
        if (!includesAscii(xlsxBytes, "Dashboard") || !includesAscii(xlsxBytes, "Source")) {
          throw new Error("sheet names missing from export");
        }

        const imported = await SpreadsheetFile.importXlsx(xlsx);
        const importedDashboard = imported.worksheets.getItem("Dashboard");
        if (importedDashboard.getRange("A1").values[0][0] !== "iOS spreadsheet skill smoke") {
          throw new Error("round-trip values failed");
        }
        if (importedDashboard.getRange("D6").values[0][0] !== 85) {
          throw new Error("round-trip formula failed");
        }
        if (SUM(1, [2, 3]) !== 6 || typeof Chart.create !== "function") {
          throw new Error("expanded artifact-tool exports unavailable");
        }

        await fs.mkdir("/workspace/external-xlsx/_rels", { recursive: true });
        await fs.mkdir("/workspace/external-xlsx/xl/_rels", { recursive: true });
        await fs.mkdir("/workspace/external-xlsx/xl/worksheets", { recursive: true });
        await fs.writeFile("/workspace/external-xlsx/[Content_Types].xml", `<?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>`);
        await fs.writeFile("/workspace/external-xlsx/_rels/.rels", `<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>`);
        await fs.writeFile("/workspace/external-xlsx/xl/workbook.xml", `<?xml version="1.0" encoding="UTF-8"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Compressed" sheetId="1" r:id="rId1"/></sheets></workbook>`);
        await fs.writeFile("/workspace/external-xlsx/xl/_rels/workbook.xml.rels", `<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>`);
        await fs.writeFile("/workspace/external-xlsx/xl/worksheets/sheet1.xml", `<?xml version="1.0" encoding="UTF-8"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>compressed import</t></is></c></row></sheetData></worksheet>`);
        execSync("cd /workspace/external-xlsx && zip -q -r /workspace/external-compressed.xlsx '[Content_Types].xml' _rels xl");
        const compressedWorkbook = await SpreadsheetFile.importXlsx(await FileBlob.load("/workspace/external-compressed.xlsx"));
        if (compressedWorkbook.worksheets.getItem("Compressed").getRange("A1").values[0][0] !== "compressed import") {
          throw new Error("compressed xlsx import fallback failed");
        }

        const document = DocumentModel.create();
        document.addParagraph("hello docx");
        const docx = await DocumentFile.exportDocx(document);
        const importedDoc = await DocumentFile.importDocx(docx);
        if (importedDoc.text !== "hello docx") throw new Error("docx import/export failed");

        console.log("ok");
        """

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

    private func stagedArtifactToolFiles(repoRoot: URL) throws -> [String: String] {
        let sandboxService = repoRoot.appendingPathComponent("Apps/JustBashPhone/JustBashPhone/SandboxService.swift")
        let source = try String(contentsOf: sandboxService, encoding: .utf8)
        let strings = try Dictionary(
            uniqueKeysWithValues: [
                "artifactToolPackageJSON",
                "artifactToolCompatModule",
                "presentationJSXCompatModule",
                "presentationJSXRuntimeCompatModule",
            ].map { name in
                (name, try extractSwiftRawString(named: name, from: source))
            }
        )

        let artifactRoots = [
            "/workspace/node_modules/@oai/artifact-tool",
            "/home/user/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/@oai/artifact-tool",
        ]
        return artifactRoots.reduce(into: [:]) { files, artifactRoot in
            files["\(artifactRoot)/package.json"] = strings["artifactToolPackageJSON"]!
            files["\(artifactRoot)/dist/artifact_tool.mjs"] = strings["artifactToolCompatModule"]!
            files["\(artifactRoot)/dist/presentation-jsx/index.mjs"] = strings["presentationJSXCompatModule"]!
            files["\(artifactRoot)/dist/presentation-jsx/jsx-runtime.mjs"] = strings["presentationJSXRuntimeCompatModule"]!
            files["\(artifactRoot)/dist/presentation-jsx/jsx-dev-runtime.mjs"] = strings["presentationJSXRuntimeCompatModule"]!
        }
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
                domain: "PrimaryRuntimeSpreadsheetCompatTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not extract \(name) from SandboxService.swift"]
            )
        }
        return String(source[valueRange])
    }
}
