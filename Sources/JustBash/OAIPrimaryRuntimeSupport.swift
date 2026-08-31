import Foundation
import JustBashCommands

public enum OAIPrimaryRuntimeSkill: String, Codable, Sendable, Equatable, CaseIterable {
    case documents
    case presentations
    case spreadsheets

    public var invocationName: String { rawValue }
}

public struct OAIPrimaryRuntimeCommandResult: Codable, Sendable, Equatable {
    public var stdout: String
    public var stderr: String
    public var exitCode: Int

    public init(stdout: String = "", stderr: String = "", exitCode: Int = 0) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}

public typealias OAIPrimaryRuntimePythonProbe = @Sendable () async -> OAIPrimaryRuntimeCommandResult

public struct OAIPrimaryRuntimeConfiguration: Sendable, Equatable {
    public var artifactToolRoots: [String]
    public var lucideRoots: [String]
    public var sharpRoots: [String]
    public var reportPath: String

    public init(
        artifactToolRoots: [String] = OAIPrimaryRuntimeSupport.defaultArtifactToolRoots,
        lucideRoots: [String] = OAIPrimaryRuntimeSupport.defaultLucideRoots,
        sharpRoots: [String] = OAIPrimaryRuntimeSupport.defaultSharpRoots,
        reportPath: String = "/workspace/primary-runtime-skills-ios-report.json"
    ) {
        self.artifactToolRoots = artifactToolRoots
        self.lucideRoots = lucideRoots
        self.sharpRoots = sharpRoots
        self.reportPath = reportPath
    }
}

public enum OAIPrimaryRuntimeSupport {
    public static let defaultArtifactToolRoots = [
        "/node_modules/@oai/artifact-tool",
        "/Users/coder/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/@oai/artifact-tool",
        "/home/user/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/@oai/artifact-tool",
    ]

    public static let defaultLucideRoots = [
        "/node_modules/lucide",
        "/Users/coder/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/lucide",
        "/home/user/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/lucide",
    ]

    public static let defaultSharpRoots = [
        "/node_modules/sharp",
        "/Users/coder/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/sharp",
        "/home/user/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/sharp",
    ]

    public static func packageFiles(configuration: OAIPrimaryRuntimeConfiguration = .init()) -> [String: String] {
        var files = configuration.artifactToolRoots.reduce(into: [String: String]()) { files, packageRoot in
            files["\(packageRoot)/package.json"] = artifactToolPackageJSON
            files["\(packageRoot)/dist/artifact_tool.mjs"] = artifactToolCompatModule
            files["\(packageRoot)/dist/presentation-jsx/index.mjs"] = presentationJSXCompatModule
            files["\(packageRoot)/dist/presentation-jsx/jsx-runtime.mjs"] = presentationJSXRuntimeCompatModule
            files["\(packageRoot)/dist/presentation-jsx/jsx-dev-runtime.mjs"] = presentationJSXRuntimeCompatModule
        }
        for packageRoot in configuration.lucideRoots {
            files["\(packageRoot)/package.json"] = lucidePackageJSON
            files["\(packageRoot)/dist/index.mjs"] = lucideCompatModule
        }
        for packageRoot in configuration.sharpRoots {
            files["\(packageRoot)/package.json"] = sharpPackageJSON
            files["\(packageRoot)/index.js"] = sharpCompatModule
        }
        return files
    }

    private static let artifactToolPackageJSON = #"""
    {
      "name": "@oai/artifact-tool",
      "version": "2.7.4",
      "type": "module",
      "exports": {
        ".": "./dist/artifact_tool.mjs",
        "./presentation-jsx": "./dist/presentation-jsx/index.mjs",
        "./presentation-jsx/jsx-runtime": "./dist/presentation-jsx/jsx-runtime.mjs",
        "./presentation-jsx/jsx-dev-runtime": "./dist/presentation-jsx/jsx-dev-runtime.mjs"
      }
    }
    """#

    private static let presentationJSXCompatModule = #"""
    export const Fragment = Symbol.for("@oai/artifact-tool/presentation-jsx.fragment");
    export function createRef() {
      return { current: null };
    }
    export function jsx(type, props, key) {
      return { type, props: props || {}, key: key == null ? null : String(key) };
    }
    export const jsxs = jsx;
    export const jsxDEV = jsx;
    export function paint(value) {
      return value;
    }
    export function stroke(value) {
      if (typeof value === "string") return { fill: value, width: 1, style: "solid" };
      return value || { fill: "#000000", width: 1, style: "solid" };
    }
    export function textStyle(value) {
      return value || {};
    }
    export default jsx;
    """#

    private static let presentationJSXRuntimeCompatModule = #"""
    import { Fragment, jsx, jsxs, jsxDEV } from "./index.mjs";
    export { Fragment, jsx, jsxs, jsxDEV };
    """#

    private static let lucidePackageJSON = #"""
    {
      "name": "lucide",
      "version": "0.0.0-justbash-ios",
      "type": "module",
      "exports": {
        ".": "./dist/index.mjs"
      }
    }
    """#

    private static let lucideCompatModule = #"""
    function iconNode(name) {
      return [
        ["path", { d: "M4 4h16v16H4z" }, []],
        ["path", { d: "M8 8h8v8H8z" }, []],
        ["path", { d: "M9 13l2 2 4-5" }, []]
      ];
    }

    export const icons = new Proxy({}, {
      get(_target, prop) {
        if (typeof prop !== "string") return undefined;
        return iconNode(prop);
      },
      has() {
        return true;
      },
      ownKeys() {
        return ["Smartphone", "Presentation", "FileText", "ChartLine", "Table"];
      },
      getOwnPropertyDescriptor() {
        return { enumerable: true, configurable: true };
      }
    });

    export const Smartphone = iconNode("Smartphone");
    export const Presentation = iconNode("Presentation");
    export const FileText = iconNode("FileText");
    export const ChartLine = iconNode("ChartLine");
    export const Table = iconNode("Table");
    """#

    private static let sharpPackageJSON = #"""
    {
      "name": "sharp",
      "version": "0.0.0-justbash-ios",
      "main": "./index.js"
    }
    """#

    private static let sharpCompatModule = #"""
    const fs = require("node:fs");
    const path = require("node:path");

    function crc32(bytes) {
      let crc = 0xffffffff;
      for (let i = 0; i < bytes.length; i += 1) {
        crc ^= bytes[i];
        for (let j = 0; j < 8; j += 1) crc = (crc >>> 1) ^ (0xedb88320 & -(crc & 1));
      }
      return (crc ^ 0xffffffff) >>> 0;
    }

    function adler32(bytes) {
      let a = 1;
      let b = 0;
      for (let i = 0; i < bytes.length; i += 1) {
        a = (a + bytes[i]) % 65521;
        b = (b + a) % 65521;
      }
      return ((b << 16) | a) >>> 0;
    }

    function u32(value) {
      return [(value >>> 24) & 255, (value >>> 16) & 255, (value >>> 8) & 255, value & 255];
    }

    function chunk(type, payload) {
      const typeBytes = Buffer.from(type, "ascii");
      const body = Buffer.from(payload);
      return Buffer.from([...u32(body.length), ...typeBytes, ...body, ...u32(crc32(Buffer.concat([typeBytes, body])))]);
    }

    function deflateStored(raw) {
      const blocks = [0x78, 0x01];
      for (let offset = 0; offset < raw.length; offset += 65535) {
        const block = raw.slice(offset, offset + 65535);
        const final = offset + 65535 >= raw.length ? 1 : 0;
        blocks.push(final, block.length & 255, (block.length >>> 8) & 255, (~block.length) & 255, ((~block.length) >>> 8) & 255);
        for (let i = 0; i < block.length; i += 1) blocks.push(block[i]);
      }
      blocks.push(...u32(adler32(raw)));
      return Buffer.from(blocks);
    }

    function parseDimension(svg, name, fallback) {
      const match = String(svg).match(new RegExp(name + '="([0-9.]+)'));
      const value = match ? Number(match[1]) : fallback;
      return Number.isFinite(value) && value > 0 ? Math.max(1, Math.min(1024, Math.round(value))) : fallback;
    }

    function setPixel(rgba, width, height, x, y, color) {
      if (x < 0 || y < 0 || x >= width || y >= height) return;
      const index = (y * width + x) * 4;
      rgba[index] = color[0]; rgba[index + 1] = color[1]; rgba[index + 2] = color[2]; rgba[index + 3] = color[3];
    }

    function fillRect(rgba, width, height, x, y, w, h, color) {
      for (let yy = Math.max(0, y); yy < Math.min(height, y + h); yy += 1) {
        for (let xx = Math.max(0, x); xx < Math.min(width, x + w); xx += 1) setPixel(rgba, width, height, xx, yy, color);
      }
    }

    function drawLine(rgba, width, height, x0, y0, x1, y1, color) {
      let dx = Math.abs(x1 - x0);
      let sx = x0 < x1 ? 1 : -1;
      let dy = -Math.abs(y1 - y0);
      let sy = y0 < y1 ? 1 : -1;
      let err = dx + dy;
      while (true) {
        fillRect(rgba, width, height, x0 - 1, y0 - 1, 3, 3, color);
        if (x0 === x1 && y0 === y1) break;
        const e2 = 2 * err;
        if (e2 >= dy) { err += dy; x0 += sx; }
        if (e2 <= dx) { err += dx; y0 += sy; }
      }
    }

    function pngFromSvg(input) {
      const svg = Buffer.isBuffer(input) ? input.toString("utf8") : String(input || "");
      const width = parseDimension(svg, "width", 128);
      const height = parseDimension(svg, "height", width);
      const rgba = Buffer.alloc(width * height * 4, 0);
      const color = [17, 24, 39, 255];
      const pad = Math.max(4, Math.round(Math.min(width, height) * 0.16));
      fillRect(rgba, width, height, pad, pad, width - pad * 2, Math.max(2, Math.round(height * 0.05)), color);
      fillRect(rgba, width, height, pad, height - pad, width - pad * 2, Math.max(2, Math.round(height * 0.05)), color);
      fillRect(rgba, width, height, pad, pad, Math.max(2, Math.round(width * 0.05)), height - pad * 2, color);
      fillRect(rgba, width, height, width - pad, pad, Math.max(2, Math.round(width * 0.05)), height - pad * 2, color);
      drawLine(rgba, width, height, Math.round(width * 0.32), Math.round(height * 0.55), Math.round(width * 0.45), Math.round(height * 0.68), color);
      drawLine(rgba, width, height, Math.round(width * 0.45), Math.round(height * 0.68), Math.round(width * 0.70), Math.round(height * 0.35), color);
      const raw = Buffer.alloc((width * 4 + 1) * height);
      for (let y = 0; y < height; y += 1) {
        const rowStart = y * (width * 4 + 1);
        raw[rowStart] = 0;
        rgba.copy(raw, rowStart + 1, y * width * 4, (y + 1) * width * 4);
      }
      return Buffer.concat([
        Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
        chunk("IHDR", Buffer.from([...u32(width), ...u32(height), 8, 6, 0, 0, 0])),
        chunk("IDAT", deflateStored(raw)),
        chunk("IEND", Buffer.alloc(0))
      ]);
    }

    function sharp(input) {
      return {
        png() {
          return this;
        },
        async toBuffer() {
          return pngFromSvg(input);
        },
        async toFile(output) {
          const buffer = pngFromSvg(input);
          await fs.promises.mkdir(path.dirname(output), { recursive: true });
          await fs.promises.writeFile(output, buffer);
          return { format: "png", size: buffer.length, width: parseDimension(Buffer.isBuffer(input) ? input.toString("utf8") : input, "width", 128), height: parseDimension(Buffer.isBuffer(input) ? input.toString("utf8") : input, "height", 128) };
        }
      };
    }

    module.exports = sharp;
    """#

    private static let artifactToolCompatModule: String = {
        guard let url = Bundle.module.url(forResource: "artifact-tool", withExtension: "mjs"),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            preconditionFailure("Missing bundled artifact-tool compatibility runtime")
        }
        return source
    }()

    public static func commands(
        configuration: OAIPrimaryRuntimeConfiguration = .init(),
        pythonProbe: OAIPrimaryRuntimePythonProbe? = nil
    ) -> [AnyBashCommand] {
        let handler: CommandHandler = { _, ctx in
            let pythonResult: OAIPrimaryRuntimeCommandResult
            if let pythonProbe {
                pythonResult = await pythonProbe()
            } else {
                pythonResult = OAIPrimaryRuntimeCommandResult(
                    stdout: "",
                    stderr: "primary-runtime-skills-check: no Python probe registered\n",
                    exitCode: 127
                )
            }
            
            let artifactToolResult = await ctx.executeSubshell?(
                #"js-exec -m -c 'import { Workbook, SpreadsheetFile, Presentation, PresentationFile, DocumentModel, DocumentFile } from "@oai/artifact-tool"; const doc = DocumentModel.create(); doc.addParagraph("Runtime document", {bold:true}); doc.addTable([["Name","Value"],["One","1"]]); const docx = await DocumentFile.exportDocx(doc); if (!(await DocumentFile.importDocx(docx)).text.includes("Runtime document")) throw new Error("DOCX workflow failed"); await docx.save("/tmp/primary-runtime-smoke.docx"); const wb = Workbook.create(); const ws = wb.worksheets.add("Smoke"); ws.getRange("A1:B2").values = [["runtime", "ios"], [2, 3]]; ws.getRange("E1:E3").formulas = [["=SUM(A2:B2)"], ["=AVERAGE(A2:B2)"], ["=E1*2"]]; if (ws.getRange("E1:E3").values[0][0] !== 5 || ws.getRange("E1:E3").values[2][0] !== 10) throw new Error("formula compatibility failed"); if ((await wb.inspect({ kind: "formula" })).errors.length) throw new Error("formula error scan failed"); if (!JSON.parse(wb.trace("Smoke!E3").ndjson).dependencies.length) throw new Error("trace dependencies unavailable"); await wb.fromCSV("name,value\nalpha,1", { sheetName: "ImportedData" }); const imported = wb.worksheets.getOrAdd("ImportedData"); const copied = imported.getRange("A1:B2").copyTo(ws.getRange("C1:D2"), "values"); ws.getCell(4, 0).writeValues([["trace"]]); ws.getRange("A1:D4").getRow(0).format.autofitColumns(); ws.getRange("A1:D4").getColumn(0).setNumberFormat("@"); ws.mergeCells("A6:B6"); ws.unmergeCells("A6:B6"); const chart = ws.charts.add("line", ws.getRange("A1:B2")); chart.setPosition("G1", "M12"); chart.title = "Runtime Chart"; if (chart.type !== "line" || ws.charts.count !== 1) throw new Error("chart compatibility failed"); const table = ws.tables.add("A1:B2", true, "SmokeTable"); if (table.name !== "SmokeTable") throw new Error("table compatibility failed"); wb.comments.setSelf({ displayName: "ChatGPT" }); const thread = wb.comments.addThread({ cell: ws.getRange("A1") }, "Source: iOS smoke"); if (thread.comments[0].text !== "Source: iOS smoke") throw new Error("comment compatibility failed"); if (!copied.values[0][0]) throw new Error("copyTo failed"); const preview = await wb.render({ sheetName: "Smoke", range: "A1:M12", scale: 0.5, chartPreview: "omit" }); if (preview.mime !== "image/png" || (await preview.arrayBuffer()).length < 100) throw new Error("workbook render compatibility failed"); await preview.save("/tmp/primary-runtime-smoke.png"); const xlsx = await SpreadsheetFile.exportXlsx(wb); const xlsxText = Buffer.from(await xlsx.arrayBuffer()).toString("latin1"); if (!xlsxText.includes("xl/charts/chart1.xml") || !xlsxText.includes("xl/drawings/drawing1.xml")) throw new Error("xlsx chart export compatibility failed"); const roundTrip = await SpreadsheetFile.importXlsx(xlsx); if (roundTrip.worksheets.getItem("Smoke").getRange("A1").values[0][0] !== "runtime") throw new Error("xlsx import compatibility failed"); await xlsx.save("/tmp/primary-runtime-smoke.xlsx"); const deck = Presentation.create({ slideSize: { width: 1280, height: 720 } }); const slide = deck.slides.add(); const shape = slide.shapes.add({ name: "title", position: { left: 40, top: 40, width: 400, height: 80 }, fill: "rgb(239,246,255)", line: { fill: "rgb(37,99,235)", width: 2 } }); shape.text = "iOS artifact-tool smoke"; shape.text.fontSize = 24; shape.text.color = "rgb(17,24,39)"; if (shape.text.fontSize !== 24) throw new Error("text frame not mutable"); const slidePreview = await deck.export({ slide, format: "png", scale: 0.5 }); if (slidePreview.mime !== "image/png" || (await slidePreview.arrayBuffer()).length < 100) throw new Error("presentation render compatibility failed"); await slidePreview.save("/tmp/primary-runtime-slide.png"); const layout = JSON.parse(await (await deck.export({ slide, format: "layout" })).text()); if (!layout.elements || layout.elements[0].name !== "title") throw new Error("presentation layout compatibility failed"); const pptx = await PresentationFile.exportPptx(deck); await pptx.save("/tmp/primary-runtime-smoke.pptx"); console.log("available");'"#
            )
            let nodeModuleResult = await ctx.executeSubshell?(
                #"js-exec -c 'try { require("node:fs"); console.log("available"); } catch (error) { console.log((error && error.code ? error.code : "ERROR") + ": " + error.message); process.exit(1); }'"#
            )
            let esmResult = await ctx.executeSubshell?(
                #"js-exec -m -c 'import fs from "node:fs/promises"; await fs.writeFile("/tmp/primary-runtime-esm.txt", "available"); console.log(await fs.readFile("/tmp/primary-runtime-esm.txt", "utf8"));'"#
            )
            let childProcessPythonResult = await ctx.executeSubshell?(
                #"js-exec -m -c 'import { spawnSync } from "node:child_process"; const result = spawnSync("python3", ["-c", "print(\"child-process-python\")"]); if (result.status !== 0) { console.error(result.stderr); process.exit(result.status || 1); } if (!String(result.stdout).includes("child-process-python")) throw new Error("python3 child_process bridge returned unexpected output: " + result.stdout); console.log("available");'"#
            )
            let packageExportsResult: ExecResult?
            do {
                try Self.stageArtifactToolPackageProbe(in: ctx)
                packageExportsResult = await ctx.executeSubshell?(
                    #"cd /tmp/primary-runtime-package-probe && js-exec -m -c 'import { createRequire } from "node:module"; import { runtimeName, resolveFs } from "@oai/artifact-tool"; import jsx, { Fragment } from "@oai/artifact-tool/presentation-jsx"; import { icons } from "lucide"; const require = createRequire(import.meta.url); const sharp = require("sharp"); const png = await sharp(Buffer.from("<svg width=\"16\" height=\"16\"></svg>", "utf8")).png().toBuffer(); if (png.length < 20) throw new Error("sharp compatibility failed"); const fresh = await import("@oai/artifact-tool"); console.log(runtimeName); console.log(resolveFs()); console.log(jsx("slide").type); console.log(Fragment); console.log(fresh.runtimeName); console.log(icons.Smartphone[0][0]); console.log(png.length);'"#
                )
            } catch {
                packageExportsResult = ExecResult.failure(
                    "primary-runtime-skills-check: cannot stage package probe: \(error.localizedDescription)",
                    exitCode: 1
                )
            }
            let unsupportedFullApiResult = await ctx.executeSubshell?(
                #"js-exec -m -c 'import { Presentation } from "@oai/artifact-tool"; const failures = []; async function expectReject(label, fn) { try { await fn(); failures.push(label + " unexpectedly succeeded"); } catch (error) { console.log(label + ": " + (error && error.message ? error.message : error)); } } await expectReject("Presentation.export(pdf)", () => { const deck = Presentation.create({ slideSize: { width: 1280, height: 720 } }); const slide = deck.slides.add(); return deck.export({ slide, format: "pdf" }); }); if (failures.length) { console.error(failures.join("\n")); process.exit(1); }'"#
            )

            let report = Self.primaryRuntimeSkillReportJSON(
                pythonResult: pythonResult,
                artifactToolResult: artifactToolResult,
                nodeModuleResult: nodeModuleResult,
                esmResult: esmResult,
                childProcessPythonResult: childProcessPythonResult,
                packageExportsResult: packageExportsResult,
                unsupportedFullApiResult: unsupportedFullApiResult,
                reportPath: configuration.reportPath
            )

            do {
                try ctx.fileSystem.createDirectory(
                    (configuration.reportPath as NSString).deletingLastPathComponent,
                    relativeTo: ctx.cwd,
                    recursive: true
                )
                try ctx.fileSystem.writeFile(
                    report,
                    to: configuration.reportPath,
                    relativeTo: ctx.cwd
                )
            } catch {
                return ExecResult.failure(
                    "primary-runtime-skills-check: cannot write report: \(error.localizedDescription)",
                    exitCode: 1
                )
            }

            return ExecResult(stdout: report, stderr: "", exitCode: report.contains(#""overall": "ready""#) ? 0 : 1)
        }

        return [
            AnyBashCommand(name: "primary-runtime-skills-check", execute: handler),
        ]
    }

    private static func primaryRuntimeSkillReportJSON(
        pythonResult: OAIPrimaryRuntimeCommandResult,
        artifactToolResult: ExecResult?,
        nodeModuleResult: ExecResult?,
        esmResult: ExecResult?,
        childProcessPythonResult: ExecResult?,
        packageExportsResult: ExecResult?,
        unsupportedFullApiResult: ExecResult?,
        reportPath: String
    ) -> String {
        let pythonStatus = pythonResult.exitCode == 0 ? "available" : "unavailable"
        let artifactToolStatus = artifactToolResult?.exitCode == 0 ? "available" : "blocked"
        let nodeModuleStatus = nodeModuleResult?.exitCode == 0 ? "available" : "blocked"
        let esmStatus = esmResult?.exitCode == 0 ? "available" : "blocked"
        let childProcessPythonStatus = childProcessPythonResult?.exitCode == 0 ? "available" : "blocked"
        let packageExportsStatus = packageExportsResult?.exitCode == 0 ? "available" : "blocked"
        let unsupportedFullApiStatus = unsupportedFullApiResult?.exitCode == 0 ? "guarded" : "unguarded"
        let commonArtifactStatus = (
            artifactToolStatus == "available"
            && nodeModuleStatus == "available"
            && esmStatus == "available"
            && packageExportsStatus == "available"
            && unsupportedFullApiStatus == "guarded"
        ) ? "ready" : "blocked"
        let documentsStatus = commonArtifactStatus
        let presentationsStatus = commonArtifactStatus
        let spreadsheetsStatus = commonArtifactStatus
        let overallStatus = (
            documentsStatus == "ready"
            && presentationsStatus == "ready"
            && spreadsheetsStatus == "ready"
        ) ? "ready" : "blocked"
        let documentBlockers = [
            "JavaScript DOCX supports styled paragraphs, rectangular tables and literal text replacement while preserving imported package parts",
            "DOCX pagination, native document rendering and desktop Python helpers are unavailable"
        ]
        let spreadsheetBlockers = [
            "XLSX supports values, bounded Excel formulas, styles, merges, tables, freeze panes, literal list validation and comments",
            "line, bar and column charts are exported as native OOXML; native preview requires chartPreview: omit",
            "pivot tables, macros, conditional formatting, sparklines and full Excel calculation are unsupported and rejected"
        ]
        let documentBlockersJSON = jsonStringArray(
            documentBlockers,
            itemIndent: "                ",
            closingIndent: "              "
        )
        let spreadsheetBlockersJSON = jsonStringArray(
            spreadsheetBlockers,
            itemIndent: "                ",
            closingIndent: "              "
        )
        return """
        {
          "platform": "ios",
          "supportLevel": "bounded-ios-compatibility",
          "pythonRequired": false,
          "overall": "\(overallStatus)",
          "runtime": {
            "beeWarePython": {
              "status": "\(pythonStatus)",
              "exitCode": \(pythonResult.exitCode),
              "stdout": "\(jsonEscaped(pythonResult.stdout))",
              "stderr": "\(jsonEscaped(pythonResult.stderr))"
            },
            "javaScriptCore": {
              "status": "available",
              "artifactToolRequire": {
                "status": "\(artifactToolStatus)",
                "exitCode": \(artifactToolResult?.exitCode ?? 127),
                "stdout": "\(jsonEscaped(artifactToolResult?.stdout ?? ""))",
                "stderr": "\(jsonEscaped(artifactToolResult?.stderr ?? ""))"
              },
              "nodeModuleRequire": {
                "status": "\(nodeModuleStatus)",
                "exitCode": \(nodeModuleResult?.exitCode ?? 127),
                "stdout": "\(jsonEscaped(nodeModuleResult?.stdout ?? ""))",
                "stderr": "\(jsonEscaped(nodeModuleResult?.stderr ?? ""))"
              },
              "esmCompatibility": {
                "status": "\(esmStatus)",
                "exitCode": \(esmResult?.exitCode ?? 127),
                "stdout": "\(jsonEscaped(esmResult?.stdout ?? ""))",
                "stderr": "\(jsonEscaped(esmResult?.stderr ?? ""))"
              },
              "childProcessPythonBridge": {
                "status": "\(childProcessPythonStatus)",
                "exitCode": \(childProcessPythonResult?.exitCode ?? 127),
                "stdout": "\(jsonEscaped(childProcessPythonResult?.stdout ?? ""))",
                "stderr": "\(jsonEscaped(childProcessPythonResult?.stderr ?? ""))"
              },
              "packageExportsCompatibility": {
                "status": "\(packageExportsStatus)",
                "exitCode": \(packageExportsResult?.exitCode ?? 127),
                "stdout": "\(jsonEscaped(packageExportsResult?.stdout ?? ""))",
                "stderr": "\(jsonEscaped(packageExportsResult?.stderr ?? ""))"
              },
              "unsupportedFullApiGuards": {
                "status": "\(unsupportedFullApiStatus)",
                "exitCode": \(unsupportedFullApiResult?.exitCode ?? 127),
                "stdout": "\(jsonEscaped(unsupportedFullApiResult?.stdout ?? ""))",
                "stderr": "\(jsonEscaped(unsupportedFullApiResult?.stderr ?? ""))"
              }
            }
          },
          "skills": {
            "documents": {
              "status": "\(documentsStatus)",
              "limitations": \(documentBlockersJSON)
            },
            "presentations": {
              "status": "\(presentationsStatus)",
              "limitations": [
                "PPTX supports positioned rectangle/ellipse shapes, uniform text styles and embedded PNG/JPEG/SVG images",
                "CoreGraphics/CoreText/ImageIO provide native shape, text and PNG/JPEG previews in JavaScriptCore",
                "SVG raster preview, custom masters, mixed text-run styling, tables and animations are unsupported and rejected"
              ]
            },
            "spreadsheets": {
              "status": "\(spreadsheetsStatus)",
              "limitations": \(spreadsheetBlockersJSON)
            }
          },
          "reportPath": "\(jsonEscaped(reportPath))"
        }

        """
    }

    private static func pythonSkillStatus(
        from pythonResult: OAIPrimaryRuntimeCommandResult,
        skill: String,
        fallback: String
    ) -> String {
        guard pythonResult.exitCode == 0,
              let data = pythonResult.stdout.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let skills = payload["skills"] as? [String: Any],
              let skillPayload = skills[skill] as? [String: Any],
              let status = skillPayload["status"] as? String else {
            return fallback
        }
        return status
    }

    private static func pythonSkillBlockers(
        from pythonResult: OAIPrimaryRuntimeCommandResult,
        skill: String,
        fallback: [String]
    ) -> [String] {
        guard pythonResult.exitCode == 0,
              let data = pythonResult.stdout.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let skills = payload["skills"] as? [String: Any],
              let skillPayload = skills[skill] as? [String: Any],
              let blockers = skillPayload["blockers"] as? [String] else {
            return fallback
        }
        return blockers
    }

    private static func jsonStringArray(
        _ values: [String],
        itemIndent: String,
        closingIndent: String
    ) -> String {
        guard !values.isEmpty else { return "[]" }
        let items = values
            .map { "\(itemIndent)\"\(jsonEscaped($0))\"" }
            .joined(separator: ",\n")
        return "[\n\(items)\n\(closingIndent)]"
    }

    private static func stageArtifactToolPackageProbe(in ctx: CommandContext) throws {
        let packageRoot = "/tmp/primary-runtime-package-probe/node_modules/@oai/artifact-tool"
        try ctx.fileSystem.createDirectory(path: "\(packageRoot)/dist/presentation-jsx", relativeTo: ctx.cwd, recursive: true)
        let lucideRoot = "/tmp/primary-runtime-package-probe/node_modules/lucide"
        try ctx.fileSystem.createDirectory(path: "\(lucideRoot)/dist", relativeTo: ctx.cwd, recursive: true)
        let sharpRoot = "/tmp/primary-runtime-package-probe/node_modules/sharp"
        try ctx.fileSystem.createDirectory(path: sharpRoot, relativeTo: ctx.cwd, recursive: true)
        try ctx.fileSystem.writeFile(
            """
            {
              "name": "@oai/artifact-tool",
              "type": "module",
              "exports": {
                ".": "./dist/artifact_tool.mjs",
                "./presentation-jsx": "./dist/presentation-jsx/index.mjs"
              }
            }
            """,
            to: "\(packageRoot)/package.json",
            relativeTo: ctx.cwd
        )
        try ctx.fileSystem.writeFile(
            """
            import { createRequire as __createRequire } from "node:module"; const require = __createRequire(import.meta.url);
            export const runtimeName = "artifact-tool";
            export function resolveFs() {
                return require.resolve("node:fs");
            }
            """,
            to: "\(packageRoot)/dist/artifact_tool.mjs",
            relativeTo: ctx.cwd
        )
        try ctx.fileSystem.writeFile(
            """
            export default function jsx(type) {
                return { type };
            }
            export const Fragment = "Fragment";
            """,
            to: "\(packageRoot)/dist/presentation-jsx/index.mjs",
            relativeTo: ctx.cwd
        )
        try ctx.fileSystem.writeFile(lucidePackageJSON, to: "\(lucideRoot)/package.json", relativeTo: ctx.cwd)
        try ctx.fileSystem.writeFile(lucideCompatModule, to: "\(lucideRoot)/dist/index.mjs", relativeTo: ctx.cwd)
        try ctx.fileSystem.writeFile(sharpPackageJSON, to: "\(sharpRoot)/package.json", relativeTo: ctx.cwd)
        try ctx.fileSystem.writeFile(sharpCompatModule, to: "\(sharpRoot)/index.js", relativeTo: ctx.cwd)
    }

    private static func jsonEscaped(_ value: String) -> String {
        var escaped = ""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\":
                escaped += "\\\\"
            case "\"":
                escaped += "\\\""
            case "\n":
                escaped += "\\n"
            case "\r":
                escaped += "\\r"
            case "\t":
                escaped += "\\t"
            default:
                if scalar.value < 0x20 {
                    escaped += String(format: "\\u%04X", scalar.value)
                } else {
                    escaped.unicodeScalars.append(scalar)
                }
            }
        }
        return escaped
    }

}

public extension BashOptions {
    mutating func enableOAIPrimaryRuntime(
        configuration: OAIPrimaryRuntimeConfiguration = .init(),
        pythonProbe: OAIPrimaryRuntimePythonProbe? = nil
    ) {
        files.merge(
            OAIPrimaryRuntimeSupport.packageFiles(configuration: configuration),
            uniquingKeysWith: { _, new in new }
        )
        customCommands.append(
            contentsOf: OAIPrimaryRuntimeSupport.commands(configuration: configuration, pythonProbe: pythonProbe)
        )
    }

    func withOAIPrimaryRuntime(
        configuration: OAIPrimaryRuntimeConfiguration = .init(),
        pythonProbe: OAIPrimaryRuntimePythonProbe? = nil
    ) -> BashOptions {
        var copy = self
        copy.enableOAIPrimaryRuntime(configuration: configuration, pythonProbe: pythonProbe)
        return copy
    }
}
