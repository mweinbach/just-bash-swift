import Foundation
import JustBash
import JustBashFS
import JustBashJavaScript

actor SandboxService {
    static let shared = SandboxService()

    static let seedFiles: [String: String] = [
        "/data/input.txt": """
        Codex can run locally inside a virtual shell on iPhone.
        This file lives in the in-memory sandbox.
        """,
        "/data/log.txt": """
        INFO Boot complete
        ERROR Missing token cache
        INFO Retrying request
        ERROR Request failed
        """,
        "/workspace/README.txt": """
        This directory is mounted to the app's sandboxed Documents folder.
        Files written here persist across launches of Just Bash on iPhone/iPad.
        """,
    ]

    private var bash = SandboxService.makeBash()

    func run(_ script: String) async -> ExecResult {
        await bash.exec(script)
    }

    func reset() {
        bash = SandboxService.makeBash()
    }

    func readFile(_ path: String) async throws -> String {
        try await bash.readFile(path)
    }

    func pythonAvailabilitySummary() -> String {
        PythonSupport.availabilitySummary()
    }

    func isPythonAvailable() -> Bool {
        PythonSupport.isAvailable
    }

    func runPython(_ code: String) async -> PythonExecResult {
        PythonSupport.run(code: code, workspacePath: Self.workspaceDirectoryPath())
    }

    func runPythonSmokeIfRequested() async {
        guard ProcessInfo.processInfo.environment["JUSTBASH_SMOKE_PYTHON"] == "1" else {
            return
        }

        let smokePath = Self.workspaceDirectoryPath() + "/python-smoke.txt"
        let startedPath = Self.workspaceDirectoryPath() + "/python-smoke.started"
        let beforeRunPath = Self.workspaceDirectoryPath() + "/python-smoke.before-run"
        let afterRunPath = Self.workspaceDirectoryPath() + "/python-smoke.after-run"
        try? FileManager.default.createDirectory(
            atPath: Self.workspaceDirectoryPath(),
            withIntermediateDirectories: true
        )
        try? "started\n".write(toFile: startedPath, atomically: true, encoding: .utf8)

        let escapedPath = smokePath.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        let code = """
        import importlib.metadata
        import sys
        from pathlib import Path

        import bs4
        import fastjsonschema
        import httpx
        import jedi
        import rich
        import tomlkit

        lines = [
            'python smoke ok',
            sys.version,
            'default packages import ok',
            f'beautifulsoup4={importlib.metadata.version("beautifulsoup4")}',
            f'fastjsonschema={importlib.metadata.version("fastjsonschema")}',
            f'httpx={importlib.metadata.version("httpx")}',
            f'jedi={importlib.metadata.version("jedi")}',
            f'rich={importlib.metadata.version("rich")}',
            f'tomlkit={importlib.metadata.version("tomlkit")}',
        ]

        try:
            lines.append(f'numpy dist={importlib.metadata.version("numpy")}')
        except Exception as exc:
            lines.append(f'numpy dist unavailable: {type(exc).__name__}: {exc}')

        Path('\(escapedPath)').write_text('\\n'.join(lines) + '\\n')
        """

        try? "before run\n".write(toFile: beforeRunPath, atomically: true, encoding: .utf8)
        let result = PythonSupport.run(code: code, workspacePath: Self.workspaceDirectoryPath())
        try? "after run\n".write(toFile: afterRunPath, atomically: true, encoding: .utf8)
        if result.exitCode != 0 {
            try? FileManager.default.createDirectory(
                atPath: Self.workspaceDirectoryPath(),
                withIntermediateDirectories: true
            )
            let message = "python smoke failed: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))\n"
            try? message.write(toFile: smokePath, atomically: true, encoding: .utf8)
            return
        }

        let shellSmoke = await run("""
        py-exec - <<'PY'
        from pathlib import Path
        import httpx

        lines = ["py-exec smoke ok", f"httpx={httpx.__version__}"]
        try:
            import numpy
            lines.append(f"numpy={numpy.__version__}")
        except Exception as exc:
            lines.append(f"numpy unavailable: {type(exc).__name__}: {exc}")

        Path("python-shell-smoke.txt").write_text("\\n".join(lines) + "\\n")
        PY
        cat /workspace/python-shell-smoke.txt
        py-exec - <<'PY'
        try:
            import numpy
            print(f"numpy repeat={numpy.__version__}")
        except Exception as exc:
            print(f"numpy repeat unavailable: {type(exc).__name__}: {exc}")
        PY
        """)
        let shellSmokePath = Self.workspaceDirectoryPath() + "/python-shell-smoke-result.txt"
        let shellSmokeOutput = """
        exitCode=\(shellSmoke.exitCode)
        stdout=\(shellSmoke.stdout)
        stderr=\(shellSmoke.stderr)
        """
        try? shellSmokeOutput.write(toFile: shellSmokePath, atomically: true, encoding: .utf8)
    }

    func runPrimaryRuntimeSkillsSmokeIfRequested() async {
        guard ProcessInfo.processInfo.environment["JUSTBASH_SMOKE_PRIMARY_RUNTIME_SKILLS"] == "1" else {
            return
        }

        let result = await run("primary-runtime-skills-check")
        let smokePath = Self.workspaceDirectoryPath() + "/primary-runtime-skills-smoke-result.txt"
        let output = """
        exitCode=\(result.exitCode)
        stdout=\(result.stdout)
        stderr=\(result.stderr)
        """
        try? output.write(toFile: smokePath, atomically: true, encoding: .utf8)
    }

    func writeFile(_ path: String, contents: String) async throws {
        let fs = await bash.fs
        let normalized = fs.normalizePath(path, relativeTo: "/workspace")
        let parent = String(normalized.split(separator: "/").dropLast().joined(separator: "/"))
        let parentPath = parent.isEmpty ? "/" : "/" + parent
        if parentPath != "/" {
            try fs.createDirectory(path: parentPath, relativeTo: "/", recursive: true)
        }
        try fs.writeFile(contents, to: normalized, relativeTo: "/")
    }

    func listDirectory(_ path: String) async throws -> [VirtualDirectoryEntry] {
        try await bash.listDirectory(path)
    }

    private static func makeBash() -> Bash {
        let workspaceBase = workspaceDirectoryPath()
        try? FileManager.default.createDirectory(
            atPath: workspaceBase,
            withIntermediateDirectories: true
        )

        let root = VirtualFileSystem()
        let mountable = MountableFileSystem(root: root)
        mountable.mount(ReadWriteFileSystem(base: workspaceBase), at: "/workspace")

        var files = seedFiles
        files.merge(primaryRuntimeArtifactToolFiles(), uniquingKeysWith: { _, new in new })

        return Bash(options: .init(
            files: files,
            customCommands: Self.pythonCommands() + Self.primaryRuntimeSkillCommands(),
            filesystem: mountable,
            embeddedRuntimes: [
                JavaScriptRuntime(options: .init(
                    bootstrap: "globalThis.APP_NAME = 'JustBashPhone';"
                ))
            ]
        ))
    }

    private static func pythonCommands() -> [AnyBashCommand] {
        let handler: CommandHandler = { args, ctx in
            var inlineCode: String?
            var scriptPath: String?
            var scriptArgs: [String] = []
            var readFromStdin = false
            var index = 0

            while index < args.count {
                let arg = args[index]
                switch arg {
                case "--help":
                    return ExecResult.success("""
                    py-exec - run embedded Python inside the Just Bash host

                      py-exec -c 'code'         execute inline Python
                      py-exec script.py         execute a virtual filesystem script file
                      py-exec - < script.py     read Python code from stdin
                      python -c 'code'          alias for py-exec
                      python script.py          alias for py-exec

                    Python starts with its current directory set to the persistent
                    workspace. Files written by Python to the current directory are
                    visible to bash under /workspace.

                    """)
                case "-V", "--version":
                    let result = PythonSupport.run(
                        code: "import sys; print(sys.version)",
                        workspacePath: Self.workspaceDirectoryPath(),
                        scriptName: "<justbash-python-version>"
                    )
                    if result.exitCode == 0 {
                        return ExecResult(stdout: result.stdout, stderr: result.stderr, exitCode: result.exitCode)
                    }
                    return ExecResult.failure(result.stderr, exitCode: result.exitCode)
                case "-c":
                    index += 1
                    if index < args.count {
                        inlineCode = args[index]
                    } else {
                        return ExecResult.failure("py-exec: -c requires an argument", exitCode: 2)
                    }
                case "-":
                    readFromStdin = true
                default:
                    if arg.hasPrefix("-") {
                        return ExecResult.failure("py-exec: unknown option \(arg)", exitCode: 2)
                    }
                    if inlineCode == nil && scriptPath == nil && !readFromStdin {
                        scriptPath = arg
                    } else {
                        scriptArgs.append(arg)
                    }
                }
                index += 1
            }

            let source: String
            let displayName: String
            if let inlineCode {
                source = inlineCode
                displayName = "<justbash-python>"
            } else if let scriptPath {
                do {
                    let data = try ctx.fileSystem.readFile(path: scriptPath, relativeTo: ctx.cwd)
                    source = String(decoding: data, as: UTF8.self)
                    displayName = scriptPath
                } catch {
                    return ExecResult.failure("py-exec: cannot read \(scriptPath): \(error.localizedDescription)", exitCode: 2)
                }
            } else if readFromStdin || !ctx.stdin.isEmpty {
                source = ctx.stdin
                displayName = "<stdin>"
            } else {
                return ExecResult.failure("py-exec: no script source provided (use -c, a file path, or stdin)", exitCode: 2)
            }

            let result = PythonSupport.run(
                code: source,
                workspacePath: Self.workspaceDirectoryPath(),
                arguments: scriptArgs,
                scriptName: displayName,
                scriptPath: scriptPath
            )
            return ExecResult(stdout: result.stdout, stderr: result.stderr, exitCode: result.exitCode)
        }

        return [
            AnyBashCommand(name: "py-exec", execute: handler),
            AnyBashCommand(name: "python", execute: handler),
            AnyBashCommand(name: "python3", execute: handler),
        ]
    }

    private static func primaryRuntimeArtifactToolFiles() -> [String: String] {
        let packageRoots = [
            "/node_modules/@oai/artifact-tool",
            "/home/user/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/@oai/artifact-tool",
        ]
        return packageRoots.reduce(into: [:]) { files, packageRoot in
            files["\(packageRoot)/package.json"] = artifactToolPackageJSON
            files["\(packageRoot)/dist/artifact_tool.mjs"] = artifactToolCompatModule
            files["\(packageRoot)/dist/presentation-jsx/index.mjs"] = presentationJSXCompatModule
            files["\(packageRoot)/dist/presentation-jsx/jsx-runtime.mjs"] = presentationJSXRuntimeCompatModule
            files["\(packageRoot)/dist/presentation-jsx/jsx-dev-runtime.mjs"] = presentationJSXRuntimeCompatModule
        }
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

    private static let artifactToolCompatModule = #"""
    import fs from "node:fs/promises";

    const MIME = {
      png: "image/png",
      pptx: "application/vnd.openxmlformats-officedocument.presentationml.presentation",
      xlsx: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
      csv: "text/csv",
      txt: "text/plain",
      json: "application/json"
    };

    const PNG_1X1 = Buffer.from(
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=",
      "base64"
    );

    function bytes(value) {
      if (value instanceof Uint8Array) return value;
      if (Array.isArray(value)) return Uint8Array.from(value);
      if (value && value.data && Array.isArray(value.data)) return Uint8Array.from(value.data);
      return Buffer.from(String(value == null ? "" : value), "utf8");
    }

    function strBytes(value) {
      return Buffer.from(String(value), "utf8");
    }

    function concat(chunks) {
      let length = 0;
      chunks.forEach((chunk) => { length += chunk.length; });
      const out = new Uint8Array(length);
      let offset = 0;
      chunks.forEach((chunk) => { out.set(chunk, offset); offset += chunk.length; });
      return out;
    }

    function u16(value) {
      return Uint8Array.from([value & 255, (value >>> 8) & 255]);
    }

    function u32(value) {
      return Uint8Array.from([value & 255, (value >>> 8) & 255, (value >>> 16) & 255, (value >>> 24) & 255]);
    }

    const CRC_TABLE = (() => {
      const table = [];
      for (let n = 0; n < 256; n += 1) {
        let c = n;
        for (let k = 0; k < 8; k += 1) c = (c & 1) ? (0xedb88320 ^ (c >>> 1)) : (c >>> 1);
        table[n] = c >>> 0;
      }
      return table;
    })();

    function crc32(data) {
      let c = 0xffffffff;
      for (let i = 0; i < data.length; i += 1) c = CRC_TABLE[(c ^ data[i]) & 255] ^ (c >>> 8);
      return (c ^ 0xffffffff) >>> 0;
    }

    function zip(files) {
      const locals = [];
      const centrals = [];
      let offset = 0;
      Object.keys(files).forEach((name) => {
        const nameBytes = strBytes(name);
        const data = bytes(files[name]);
        const crc = crc32(data);
        const local = concat([
          u32(0x04034b50), u16(20), u16(0), u16(0), u16(0), u16(0),
          u32(crc), u32(data.length), u32(data.length), u16(nameBytes.length), u16(0),
          nameBytes, data
        ]);
        locals.push(local);
        centrals.push(concat([
          u32(0x02014b50), u16(20), u16(20), u16(0), u16(0), u16(0), u16(0),
          u32(crc), u32(data.length), u32(data.length), u16(nameBytes.length), u16(0), u16(0),
          u16(0), u16(0), u32(0), u32(offset), nameBytes
        ]));
        offset += local.length;
      });
      const central = concat(centrals);
      return concat([
        ...locals,
        central,
        u32(0x06054b50), u16(0), u16(0), u16(centrals.length), u16(centrals.length),
        u32(central.length), u32(offset), u16(0)
      ]);
    }

    function xml(value) {
      return String(value == null ? "" : value)
        .replace(/&/g, "&amp;")
        .replace(/</g, "&lt;")
        .replace(/>/g, "&gt;")
        .replace(/"/g, "&quot;");
    }

    function colName(index) {
      let n = index + 1;
      let out = "";
      while (n > 0) {
        const r = (n - 1) % 26;
        out = String.fromCharCode(65 + r) + out;
        n = Math.floor((n - 1) / 26);
      }
      return out;
    }

    function colIndex(label) {
      let out = 0;
      String(label).toUpperCase().split("").forEach((ch) => { out = out * 26 + ch.charCodeAt(0) - 64; });
      return out - 1;
    }

    function parseCell(ref) {
      const match = String(ref).match(/^([A-Za-z]+)(\d+)$/);
      if (!match) throw new Error("Unsupported cell reference: " + ref);
      return { row: Number(match[2]) - 1, col: colIndex(match[1]) };
    }

    function parseRange(ref) {
      const parts = String(ref).split("!");
      const address = parts.length > 1 ? parts[1] : parts[0];
      const ends = address.split(":");
      const start = parseCell(ends[0]);
      const end = parseCell(ends[1] || ends[0]);
      return {
        row: start.row,
        col: start.col,
        rows: Math.max(1, end.row - start.row + 1),
        cols: Math.max(1, end.col - start.col + 1)
      };
    }

    function csvRows(text) {
      return String(text).trimEnd().split(/\r?\n/).map((line) => {
        const row = [];
        let cell = "";
        let quoted = false;
        for (let i = 0; i < line.length; i += 1) {
          const ch = line[i];
          if (quoted && ch === '"' && line[i + 1] === '"') { cell += '"'; i += 1; continue; }
          if (ch === '"') { quoted = !quoted; continue; }
          if (ch === "," && !quoted) { row.push(cell); cell = ""; continue; }
          cell += ch;
        }
        row.push(cell);
        return row;
      });
    }

    export class FileBlob {
      constructor(data, mime) {
        this.data = bytes(data);
        this.mime = mime || "application/octet-stream";
      }
      static async load(path) {
        const data = await fs.readFile(path);
        const ext = String(path).split(".").pop();
        return new FileBlob(data, MIME[ext] || "application/octet-stream");
      }
      async save(path) {
        await fs.writeFile(path, this.data);
      }
      async text() {
        return Buffer.from(this.data).toString("utf8");
      }
      async arrayBuffer() {
        return this.data;
      }
    }

    class LooseCollection {
      constructor(factory) {
        this.items = [];
        this.factory = factory || ((x) => x || {});
      }
      add(options) {
        const item = this.factory(options || {});
        this.items.push(item);
        return item;
      }
      getItem(index) {
        return this.items[index];
      }
      get count() {
        return this.items.length;
      }
    }

    export class Presentation {
      constructor(options) {
        this.slideSize = (options && options.slideSize) || { width: 1280, height: 720 };
        this.slides = new SlideCollection(this);
      }
      static create(options) {
        return new Presentation(options || {});
      }
      async export(options) {
        const format = (options && options.format) || "png";
        if (format === "layout") {
          return new FileBlob(JSON.stringify(this.toJSON(), null, 2), "application/json");
        }
        return new FileBlob(PNG_1X1, "image/png");
      }
      toJSON() {
        return {
          slideSize: this.slideSize,
          slides: this.slides.items.map((slide) => slide.toJSON())
        };
      }
    }

    class SlideCollection extends LooseCollection {
      constructor(presentation) {
        super(() => new Slide(presentation));
      }
    }

    export class Slide {
      constructor(presentation) {
        this.presentation = presentation;
        this.shapes = new LooseCollection((options) => new Shape(options));
        this.images = new LooseCollection((options) => new Image(options));
        this.tables = new LooseCollection((options) => ({ options: options || {}, position: (options || {}).position || {} }));
        this.background = {};
      }
      toJSON() {
        return {
          shapes: this.shapes.items.map((shape) => shape.toJSON()),
          images: this.images.items.map((image) => image.toJSON())
        };
      }
    }

    export class Shape {
      constructor(options) {
        this.options = options || {};
        this.position = this.options.position || {};
        this.fill = this.options.fill;
        this.line = this.options.line;
        this.geometry = this.options.geometry || "rect";
        this.text = "";
      }
      toJSON() {
        return { position: this.position, geometry: this.geometry, text: this.text };
      }
    }

    export class Image {
      constructor(options) {
        this.options = options || {};
        this.position = this.options.position || {};
      }
      toJSON() {
        return { position: this.position, alt: this.options.alt || "" };
      }
    }

    function slideXml(slide) {
      const shapes = slide.shapes.items.map((shape, index) => {
        const text = typeof shape.text === "string" ? shape.text : String(shape.text || "");
        return `<p:sp><p:nvSpPr><p:cNvPr id="${index + 2}" name="Text ${index + 1}"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="4000000" cy="700000"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:noFill/><a:ln><a:noFill/></a:ln></p:spPr><p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:rPr lang="en-US" sz="2400"/><a:t>${xml(text)}</a:t></a:r></a:p></p:txBody></p:sp>`;
      }).join("");
      return `<?xml version="1.0" encoding="UTF-8" standalone="yes"?><p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>${shapes}</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>`;
    }

    export class PresentationFile {
      static async exportPptx(presentation) {
        const files = {
          "[Content_Types].xml": `<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>${presentation.slides.items.map((_, i) => `<Override PartName="/ppt/slides/slide${i + 1}.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>`).join("")}</Types>`,
          "_rels/.rels": `<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/></Relationships>`,
          "ppt/presentation.xml": `<?xml version="1.0" encoding="UTF-8" standalone="yes"?><p:presentation xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:sldIdLst>${presentation.slides.items.map((_, i) => `<p:sldId id="${256 + i}" r:id="rId${i + 1}"/>`).join("")}</p:sldIdLst><p:sldSz cx="12192000" cy="6858000" type="screen16x9"/><p:notesSz cx="6858000" cy="9144000"/></p:presentation>`,
          "ppt/_rels/presentation.xml.rels": `<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">${presentation.slides.items.map((_, i) => `<Relationship Id="rId${i + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide${i + 1}.xml"/>`).join("")}</Relationships>`
        };
        presentation.slides.items.forEach((slide, i) => { files[`ppt/slides/slide${i + 1}.xml`] = slideXml(slide); });
        return new FileBlob(zip(files), MIME.pptx);
      }
    }

    export class Workbook {
      constructor() {
        this.worksheets = new WorksheetCollection(this);
      }
      static create() {
        return new Workbook();
      }
      static async fromCSV(csvText, options) {
        const workbook = new Workbook();
        const sheet = workbook.worksheets.add((options && options.sheetName) || "Sheet1");
        const rows = csvRows(csvText);
        if (rows.length) sheet.getRangeByIndexes(0, 0, rows.length, Math.max(...rows.map((row) => row.length))).values = rows;
        return workbook;
      }
      getActiveWorksheet() {
        return this.worksheets.items[0] || this.worksheets.add("Sheet1");
      }
      async render() {
        return new FileBlob(PNG_1X1, "image/png");
      }
      inspect(options) {
        return { ndjson: JSON.stringify({ kind: "workbook", sheets: this.worksheets.items.map((s) => s.name), options: options || {} }) + "\n" };
      }
      help(query) {
        return { ndjson: JSON.stringify({ query, note: "Just Bash iOS artifact-tool compatibility surface" }) + "\n" };
      }
    }

    class WorksheetCollection extends LooseCollection {
      constructor(workbook) {
        super((name) => new Worksheet(workbook, typeof name === "string" ? name : "Sheet" + (workbook.worksheets.count + 1)));
      }
      getItem(nameOrIndex) {
        if (typeof nameOrIndex === "number") return this.items[nameOrIndex];
        return this.items.find((sheet) => sheet.name === nameOrIndex);
      }
    }

    export class Worksheet {
      constructor(workbook, name) {
        this.workbook = workbook;
        this.name = name;
        this.cells = {};
        this.charts = new LooseCollection((options) => ({ options: options || {}, series: new LooseCollection(), title: {}, legend: {} }));
        this.shapes = new LooseCollection((options) => ({ options: options || {}, text: "", position: (options || {}).position || {} }));
        this.images = new LooseCollection((options) => ({ options: options || {}, position: (options || {}).position || {} }));
        this.tables = new LooseCollection((options) => ({ options: options || {} }));
        this.freezePanes = { freezeRows() {}, freezeColumns() {} };
      }
      getRange(address) {
        return new Range(this, parseRange(address));
      }
      getRangeByIndexes(row, col, rows, cols) {
        return new Range(this, { row, col, rows, cols });
      }
      deleteAllDrawings() {
        this.charts.items = [];
        this.shapes.items = [];
        this.images.items = [];
      }
    }

    export class Range {
      constructor(sheet, bounds) {
        this.sheet = sheet;
        this.bounds = bounds;
        this.format = { fill: {}, font: {}, borders: {}, alignment: {}, numberFormat: "" };
        this.dataValidation = {};
        this.conditionalFormats = new LooseCollection();
      }
      get values() {
        const out = [];
        for (let r = 0; r < this.bounds.rows; r += 1) {
          const row = [];
          for (let c = 0; c < this.bounds.cols; c += 1) row.push((this.sheet.cells[`${this.bounds.row + r},${this.bounds.col + c}`] || {}).value || null);
          out.push(row);
        }
        return out;
      }
      set values(matrix) {
        (matrix || []).forEach((row, r) => (row || []).forEach((value, c) => {
          this.sheet.cells[`${this.bounds.row + r},${this.bounds.col + c}`] = { ...(this.sheet.cells[`${this.bounds.row + r},${this.bounds.col + c}`] || {}), value };
        }));
      }
      get formulas() {
        const out = [];
        for (let r = 0; r < this.bounds.rows; r += 1) {
          const row = [];
          for (let c = 0; c < this.bounds.cols; c += 1) row.push((this.sheet.cells[`${this.bounds.row + r},${this.bounds.col + c}`] || {}).formula || null);
          out.push(row);
        }
        return out;
      }
      set formulas(matrix) {
        (matrix || []).forEach((row, r) => (row || []).forEach((formula, c) => {
          this.sheet.cells[`${this.bounds.row + r},${this.bounds.col + c}`] = { ...(this.sheet.cells[`${this.bounds.row + r},${this.bounds.col + c}`] || {}), formula };
        }));
      }
      clear() {
        for (let r = 0; r < this.bounds.rows; r += 1) {
          for (let c = 0; c < this.bounds.cols; c += 1) delete this.sheet.cells[`${this.bounds.row + r},${this.bounds.col + c}`];
        }
      }
      autofit() {}
      fillDown() {}
      fillRight() {}
    }

    function sheetXml(sheet) {
      const rows = {};
      Object.keys(sheet.cells).forEach((key) => {
        const parts = key.split(",").map((n) => Number(n));
        const r = parts[0];
        const c = parts[1];
        if (!rows[r]) rows[r] = [];
        const cell = sheet.cells[key];
        const ref = `${colName(c)}${r + 1}`;
        if (cell.formula) rows[r].push(`<c r="${ref}"><f>${xml(String(cell.formula).replace(/^=/, ""))}</f></c>`);
        else if (typeof cell.value === "number") rows[r].push(`<c r="${ref}"><v>${cell.value}</v></c>`);
        else if (typeof cell.value === "boolean") rows[r].push(`<c r="${ref}" t="b"><v>${cell.value ? 1 : 0}</v></c>`);
        else rows[r].push(`<c r="${ref}" t="inlineStr"><is><t>${xml(cell.value == null ? "" : cell.value)}</t></is></c>`);
      });
      const body = Object.keys(rows).sort((a, b) => Number(a) - Number(b)).map((r) => `<row r="${Number(r) + 1}">${rows[r].join("")}</row>`).join("");
      return `<?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>${body}</sheetData></worksheet>`;
    }

    export class SpreadsheetFile {
      static async importXlsx(blob) {
        const workbook = Workbook.create();
        workbook.worksheets.add("Sheet1");
        return workbook;
      }
      static async exportXlsx(workbook) {
        const sheets = workbook.worksheets.items.length ? workbook.worksheets.items : [workbook.worksheets.add("Sheet1")];
        const files = {
          "[Content_Types].xml": `<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>${sheets.map((_, i) => `<Override PartName="/xl/worksheets/sheet${i + 1}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>`).join("")}</Types>`,
          "_rels/.rels": `<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>`,
          "xl/workbook.xml": `<?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>${sheets.map((sheet, i) => `<sheet name="${xml(sheet.name)}" sheetId="${i + 1}" r:id="rId${i + 1}"/>`).join("")}</sheets></workbook>`,
          "xl/_rels/workbook.xml.rels": `<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">${sheets.map((_, i) => `<Relationship Id="rId${i + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet${i + 1}.xml"/>`).join("")}</Relationships>`
        };
        sheets.forEach((sheet, i) => { files[`xl/worksheets/sheet${i + 1}.xml`] = sheetXml(sheet); });
        return new FileBlob(zip(files), MIME.xlsx);
      }
    }
    """#

    private static func primaryRuntimeSkillCommands() -> [AnyBashCommand] {
        let handler: CommandHandler = { _, ctx in
            let pythonResult = PythonSupport.run(
                code: """
                import json
                from pathlib import Path
                import primary_runtime_skill_probe

                report = primary_runtime_skill_probe.build_report()
                Path("primary-runtime-skills-python-report.json").write_text(
                    json.dumps(report, indent=2, sort_keys=True) + "\\n"
                )
                print(json.dumps(report, sort_keys=True))
                """,
                workspacePath: Self.workspaceDirectoryPath(),
                scriptName: "<primary-runtime-skills-check>"
            )

            let artifactToolResult = await ctx.executeSubshell?(
                #"js-exec -m -c 'import { Workbook, SpreadsheetFile, Presentation, PresentationFile } from "@oai/artifact-tool"; const wb = Workbook.create(); const ws = wb.worksheets.add("Smoke"); ws.getRange("A1:B2").values = [["runtime", "ios"], ["ok", true]]; const xlsx = await SpreadsheetFile.exportXlsx(wb); await xlsx.save("/tmp/primary-runtime-smoke.xlsx"); const deck = Presentation.create({ slideSize: { width: 1280, height: 720 } }); const slide = deck.slides.add(); const shape = slide.shapes.add({ position: { left: 40, top: 40, width: 400, height: 80 } }); shape.text = "iOS artifact-tool smoke"; const pptx = await PresentationFile.exportPptx(deck); await pptx.save("/tmp/primary-runtime-smoke.pptx"); console.log("available");'"#
            )
            let nodeModuleResult = await ctx.executeSubshell?(
                #"js-exec -c 'try { require("node:fs"); console.log("available"); } catch (error) { console.log((error && error.code ? error.code : "ERROR") + ": " + error.message); process.exit(1); }'"#
            )
            let esmResult = await ctx.executeSubshell?(
                #"js-exec -m -c 'import fs from "node:fs/promises"; await fs.writeFile("/tmp/primary-runtime-esm.txt", "available"); console.log(await fs.readFile("/tmp/primary-runtime-esm.txt", "utf8"));'"#
            )
            let packageExportsResult: ExecResult?
            do {
                try Self.stageArtifactToolPackageProbe(in: ctx)
                packageExportsResult = await ctx.executeSubshell?(
                    #"cd /tmp/primary-runtime-package-probe && js-exec -m -c 'import { runtimeName, resolveFs } from "@oai/artifact-tool"; import jsx, { Fragment } from "@oai/artifact-tool/presentation-jsx"; const fresh = await import("@oai/artifact-tool"); console.log(runtimeName); console.log(resolveFs()); console.log(jsx("slide").type); console.log(Fragment); console.log(fresh.runtimeName);'"#
                )
            } catch {
                packageExportsResult = ExecResult.failure(
                    "primary-runtime-skills-check: cannot stage package probe: \(error.localizedDescription)",
                    exitCode: 1
                )
            }

            let report = Self.primaryRuntimeSkillReportJSON(
                pythonResult: pythonResult,
                artifactToolResult: artifactToolResult,
                nodeModuleResult: nodeModuleResult,
                esmResult: esmResult,
                packageExportsResult: packageExportsResult
            )

            do {
                try ctx.fileSystem.writeFile(
                    report,
                    to: "/workspace/primary-runtime-skills-ios-report.json",
                    relativeTo: ctx.cwd
                )
            } catch {
                return ExecResult.failure(
                    "primary-runtime-skills-check: cannot write report: \(error.localizedDescription)",
                    exitCode: 1
                )
            }

            return ExecResult(stdout: report, stderr: pythonResult.stderr, exitCode: 1)
        }

        return [
            AnyBashCommand(name: "primary-runtime-skills-check", execute: handler),
        ]
    }

    private static func primaryRuntimeSkillReportJSON(
        pythonResult: PythonExecResult,
        artifactToolResult: ExecResult?,
        nodeModuleResult: ExecResult?,
        esmResult: ExecResult?,
        packageExportsResult: ExecResult?
    ) -> String {
        let pythonStatus = pythonResult.exitCode == 0 ? "available" : "unavailable"
        let artifactToolStatus = artifactToolResult?.exitCode == 0 ? "available" : "blocked"
        let nodeModuleStatus = nodeModuleResult?.exitCode == 0 ? "available" : "blocked"
        let esmStatus = esmResult?.exitCode == 0 ? "available" : "blocked"
        let packageExportsStatus = packageExportsResult?.exitCode == 0 ? "available" : "blocked"
        return """
        {
          "platform": "ios",
          "overall": "blocked",
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
              "packageExportsCompatibility": {
                "status": "\(packageExportsStatus)",
                "exitCode": \(packageExportsResult?.exitCode ?? 127),
                "stdout": "\(jsonEscaped(packageExportsResult?.stdout ?? ""))",
                "stderr": "\(jsonEscaped(packageExportsResult?.stderr ?? ""))"
              }
            }
          },
          "skills": {
            "documents": {
              "status": "blocked",
              "blockers": [
                "requires soffice/LibreOffice render QA",
                "uses subprocess-based document rendering",
                "requires Python packages not staged in the default iOS bundle"
              ]
            },
            "presentations": {
              "status": "blocked",
              "blockers": [
                "limited pure-JS @oai/artifact-tool/presentation-jsx compatibility is staged",
                "full-fidelity rendering still depends on native/npm artifact-tool paths not ported to iOS"
              ]
            },
            "spreadsheets": {
              "status": "blocked",
              "blockers": [
                "limited pure-JS @oai/artifact-tool workbook export compatibility is staged",
                "full artifact-tool inspection/render/import behavior is not ported to iOS"
              ]
            }
          },
          "reportPath": "/workspace/primary-runtime-skills-ios-report.json"
        }

        """
    }

    private static func stageArtifactToolPackageProbe(in ctx: CommandContext) throws {
        let packageRoot = "/tmp/primary-runtime-package-probe/node_modules/@oai/artifact-tool"
        try ctx.fileSystem.createDirectory(path: "\(packageRoot)/dist/presentation-jsx", relativeTo: ctx.cwd, recursive: true)
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

    private static func workspaceDirectoryPath() -> String {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("JustBashWorkspace", isDirectory: true).path
    }
}
