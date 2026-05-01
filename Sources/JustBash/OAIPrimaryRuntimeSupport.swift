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

    private static let artifactToolCompatModule = #"""
    import fs from "node:fs/promises";
    import { spawnSync } from "node:child_process";
    import { createRequire as __createRequire } from "node:module";

    const require = __createRequire(import.meta.url);
    export const runtimeName = "artifact-tool";
    export function resolveFs() {
      return require.resolve("node:fs");
    }

    const MIME = {
      png: "image/png",
      pptx: "application/vnd.openxmlformats-officedocument.presentationml.presentation",
      xlsx: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
      docx: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
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

    function u32be(value) {
      return Uint8Array.from([(value >>> 24) & 255, (value >>> 16) & 255, (value >>> 8) & 255, value & 255]);
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

    function u16At(data, offset) {
      return data[offset] | (data[offset + 1] << 8);
    }

    function u32At(data, offset) {
      return (data[offset] | (data[offset + 1] << 8) | (data[offset + 2] << 16) | (data[offset + 3] << 24)) >>> 0;
    }

    function adler32(data) {
      let a = 1;
      let b = 0;
      for (let i = 0; i < data.length; i += 1) {
        a = (a + data[i]) % 65521;
        b = (b + a) % 65521;
      }
      return ((b << 16) | a) >>> 0;
    }

    function zlibStored(data) {
      const chunks = [Uint8Array.from([0x78, 0x01])];
      let offset = 0;
      while (offset < data.length) {
        const size = Math.min(65535, data.length - offset);
        const final = offset + size >= data.length ? 1 : 0;
        chunks.push(Uint8Array.from([final, size & 255, (size >>> 8) & 255, (~size) & 255, ((~size) >>> 8) & 255]));
        chunks.push(data.slice(offset, offset + size));
        offset += size;
      }
      chunks.push(u32be(adler32(data)));
      return concat(chunks);
    }

    function pngChunk(type, data) {
      const typeBytes = strBytes(type);
      const payload = bytes(data);
      const crc = crc32(concat([typeBytes, payload]));
      return concat([u32be(payload.length), typeBytes, payload, u32be(crc)]);
    }

    function pngImage(width, height, rgba) {
      const stride = width * 4;
      const rows = new Uint8Array((stride + 1) * height);
      for (let y = 0; y < height; y += 1) {
        rows[y * (stride + 1)] = 0;
        rows.set(rgba.slice(y * stride, y * stride + stride), y * (stride + 1) + 1);
      }
      const header = concat([
        u32be(width),
        u32be(height),
        Uint8Array.from([8, 6, 0, 0, 0])
      ]);
      return concat([
        Uint8Array.from([137, 80, 78, 71, 13, 10, 26, 10]),
        pngChunk("IHDR", header),
        pngChunk("IDAT", zlibStored(rows)),
        pngChunk("IEND", new Uint8Array())
      ]);
    }

    function unzipLocalZip(filesBlob) {
      const data = bytes(filesBlob);
      const files = {};
      let offset = 0;
      while (offset + 30 <= data.length) {
        const signature = u32At(data, offset);
        if (signature === 0x02014b50 || signature === 0x06054b50) break;
        if (signature !== 0x04034b50) {
          offset += 1;
          continue;
        }

        const flags = u16At(data, offset + 6);
        const method = u16At(data, offset + 8);
        const compressedSize = u32At(data, offset + 18);
        const nameLength = u16At(data, offset + 26);
        const extraLength = u16At(data, offset + 28);
        if (flags & 8) {
          throw new Error("ZIP entries with data descriptors require sandbox unzip fallback on iOS");
        }
        if (method !== 0 && method !== 8) {
          throw new Error(`ZIP compression method ${method} is not supported on iOS`);
        }
        if (method === 8) {
          throw new Error("Deflated ZIP entries require sandbox unzip fallback on iOS");
        }
        const nameStart = offset + 30;
        const dataStart = nameStart + nameLength + extraLength;
        const name = Buffer.from(data.slice(nameStart, nameStart + nameLength)).toString("utf8");
        files[name] = data.slice(dataStart, dataStart + compressedSize);
        offset = dataStart + compressedSize;
      }
      return files;
    }

    let unzipSequence = 0;

    async function rmForce(path) {
      try {
        await fs.rm(path, { recursive: true, force: true });
      } catch (_) {}
    }

    async function unzipViaSandbox(filesBlob, reason) {
      const data = bytes(filesBlob);
      const token = `${Date.now()}-${unzipSequence++}`;
      const baseDir = `${process.cwd()}/.justbash-artifacts`;
      const archivePath = `${baseDir}/artifact-${token}.zip`;
      const outputDir = `${baseDir}/artifact-${token}`;
      await fs.mkdir(baseDir, { recursive: true });
      await fs.writeFile(archivePath, data);
      await rmForce(outputDir);
      await fs.mkdir(outputDir, { recursive: true });
      const result = spawnSync("unzip", ["-q", "-o", archivePath, "-d", outputDir], { timeout: 30000 });
      if (result.status !== 0) {
        const stderr = result.stderr || result.stdout || "unknown unzip failure";
        throw new Error(`artifact-tool iOS unzip fallback failed after ${reason.message}: ${stderr}`);
      }
      const files = {};
      async function walk(relativePath) {
        const directory = relativePath ? `${outputDir}/${relativePath}` : outputDir;
        const names = await fs.readdir(directory);
        for (const name of names) {
          const childRelative = relativePath ? `${relativePath}/${name}` : name;
          const childPath = `${outputDir}/${childRelative}`;
          const stat = await fs.stat(childPath);
          if (stat.isDirectory()) await walk(childRelative);
          else files[childRelative] = await fs.readFile(childPath);
        }
      }
      await walk("");
      await rmForce(outputDir);
      await rmForce(archivePath);
      return files;
    }

    async function unzipOfficeZip(filesBlob) {
      try {
        return unzipLocalZip(filesBlob);
      } catch (error) {
        return await unzipViaSandbox(filesBlob, error);
      }
    }

    const FONT_3X5 = {
      "0": ["111", "101", "101", "101", "111"], "1": ["010", "110", "010", "010", "111"],
      "2": ["111", "001", "111", "100", "111"], "3": ["111", "001", "111", "001", "111"],
      "4": ["101", "101", "111", "001", "001"], "5": ["111", "100", "111", "001", "111"],
      "6": ["111", "100", "111", "101", "111"], "7": ["111", "001", "010", "010", "010"],
      "8": ["111", "101", "111", "101", "111"], "9": ["111", "101", "111", "001", "111"],
      "A": ["010", "101", "111", "101", "101"], "B": ["110", "101", "110", "101", "110"],
      "C": ["111", "100", "100", "100", "111"], "D": ["110", "101", "101", "101", "110"],
      "E": ["111", "100", "110", "100", "111"], "F": ["111", "100", "110", "100", "100"],
      "G": ["111", "100", "101", "101", "111"], "H": ["101", "101", "111", "101", "101"],
      "I": ["111", "010", "010", "010", "111"], "J": ["001", "001", "001", "101", "111"],
      "K": ["101", "101", "110", "101", "101"], "L": ["100", "100", "100", "100", "111"],
      "M": ["101", "111", "111", "101", "101"], "N": ["101", "111", "111", "111", "101"],
      "O": ["111", "101", "101", "101", "111"], "P": ["111", "101", "111", "100", "100"],
      "Q": ["111", "101", "101", "111", "001"], "R": ["111", "101", "111", "110", "101"],
      "S": ["111", "100", "111", "001", "111"], "T": ["111", "010", "010", "010", "010"],
      "U": ["101", "101", "101", "101", "111"], "V": ["101", "101", "101", "101", "010"],
      "W": ["101", "101", "111", "111", "101"], "X": ["101", "101", "010", "101", "101"],
      "Y": ["101", "101", "010", "010", "010"], "Z": ["111", "001", "010", "100", "111"],
      ".": ["000", "000", "000", "000", "010"], "-": ["000", "000", "111", "000", "000"],
      "_": ["000", "000", "000", "000", "111"], "/": ["001", "001", "010", "100", "100"],
      ":": ["000", "010", "000", "010", "000"], "=": ["000", "111", "000", "111", "000"],
      "#": ["101", "111", "101", "111", "101"], "%": ["101", "001", "010", "100", "101"],
      "$": ["111", "110", "111", "011", "111"], " ": ["000", "000", "000", "000", "000"]
    };

    function makeCanvas(width, height, color) {
      const rgba = new Uint8Array(width * height * 4);
      for (let i = 0; i < rgba.length; i += 4) {
        rgba[i] = color[0]; rgba[i + 1] = color[1]; rgba[i + 2] = color[2]; rgba[i + 3] = color[3];
      }
      return { width, height, rgba };
    }

    function setPixel(canvas, x, y, color) {
      if (x < 0 || y < 0 || x >= canvas.width || y >= canvas.height) return;
      const index = (y * canvas.width + x) * 4;
      canvas.rgba[index] = color[0];
      canvas.rgba[index + 1] = color[1];
      canvas.rgba[index + 2] = color[2];
      canvas.rgba[index + 3] = color[3];
    }

    function fillRect(canvas, x, y, width, height, color) {
      if (!color || color[3] === 0) return;
      for (let yy = Math.max(0, y); yy < Math.min(canvas.height, y + height); yy += 1) {
        for (let xx = Math.max(0, x); xx < Math.min(canvas.width, x + width); xx += 1) setPixel(canvas, xx, yy, color);
      }
    }

    function strokeRect(canvas, x, y, width, height, color) {
      fillRect(canvas, x, y, width, 1, color);
      fillRect(canvas, x, y + height - 1, width, 1, color);
      fillRect(canvas, x, y, 1, height, color);
      fillRect(canvas, x + width - 1, y, 1, height, color);
    }

    function drawLine(canvas, x0, y0, x1, y1, color) {
      let dx = Math.abs(x1 - x0);
      let sx = x0 < x1 ? 1 : -1;
      let dy = -Math.abs(y1 - y0);
      let sy = y0 < y1 ? 1 : -1;
      let err = dx + dy;
      while (true) {
        fillRect(canvas, x0 - 1, y0 - 1, 3, 3, color);
        if (x0 === x1 && y0 === y1) break;
        const e2 = 2 * err;
        if (e2 >= dy) { err += dy; x0 += sx; }
        if (e2 <= dx) { err += dx; y0 += sy; }
      }
    }

    function drawText(canvas, text, x, y, maxWidth, color) {
      const scale = 2;
      let cursor = x;
      const value = String(text == null ? "" : text).toUpperCase();
      for (let i = 0; i < value.length && cursor + 3 * scale <= x + maxWidth; i += 1) {
        const glyph = FONT_3X5[value[i]] || FONT_3X5["#"];
        glyph.forEach((row, gy) => {
          for (let gx = 0; gx < row.length; gx += 1) {
            if (row[gx] === "1") fillRect(canvas, cursor + gx * scale, y + gy * scale, scale, scale, color);
          }
        });
        cursor += 4 * scale;
      }
    }

    function clampByte(value, fallback) {
      const number = Number(value);
      if (!Number.isFinite(number)) return fallback;
      return Math.max(0, Math.min(255, Math.round(number)));
    }

    function colorBytes(value, fallback) {
      if (value == null || value === "" || value === "transparent") return fallback;
      if (Array.isArray(value)) {
        return [
          clampByte(value[0], 0),
          clampByte(value[1], 0),
          clampByte(value[2], 0),
          value.length > 3 ? clampByte(value[3], 255) : 255
        ];
      }
      const text = String(value).trim();
      const hex = text.match(/^#([0-9a-f]{6}|[0-9a-f]{8})$/i);
      if (hex) {
        const raw = hex[1];
        return [
          parseInt(raw.slice(0, 2), 16),
          parseInt(raw.slice(2, 4), 16),
          parseInt(raw.slice(4, 6), 16),
          raw.length === 8 ? parseInt(raw.slice(6, 8), 16) : 255
        ];
      }
      const rgb = text.match(/^rgba?\(([^)]+)\)$/i);
      if (rgb) {
        const parts = rgb[1].split(",").map((part) => part.trim());
        const alpha = parts.length > 3 ? Math.round(Number(parts[3]) * 255) : 255;
        return [clampByte(parts[0], 0), clampByte(parts[1], 0), clampByte(parts[2], 0), clampByte(alpha, 255)];
      }
      return fallback;
    }

    function frameOf(position, fallback) {
      const source = position || {};
      return {
        left: Number(source.left ?? source.x ?? fallback.left ?? 0) || 0,
        top: Number(source.top ?? source.y ?? fallback.top ?? 0) || 0,
        width: Math.max(1, Number(source.width ?? source.w ?? fallback.width ?? 1) || 1),
        height: Math.max(1, Number(source.height ?? source.h ?? fallback.height ?? 1) || 1)
      };
    }

    function scaledFrame(frame, scale) {
      return {
        left: Math.round(frame.left * scale),
        top: Math.round(frame.top * scale),
        width: Math.max(1, Math.round(frame.width * scale)),
        height: Math.max(1, Math.round(frame.height * scale))
      };
    }

    function xml(value) {
      return String(value == null ? "" : value)
        .replace(/&/g, "&amp;")
        .replace(/</g, "&lt;")
        .replace(/>/g, "&gt;")
        .replace(/"/g, "&quot;");
    }

    function xmlDecode(value) {
      return String(value == null ? "" : value)
        .replace(/&quot;/g, '"')
        .replace(/&apos;/g, "'")
        .replace(/&lt;/g, "<")
        .replace(/&gt;/g, ">")
        .replace(/&amp;/g, "&");
    }

    function zipText(files, name) {
      const data = files[name];
      return data ? Buffer.from(data).toString("utf8") : "";
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

    function a1(row, col) {
      return `${colName(col)}${row + 1}`;
    }

    function formulaAddress(sheet, row, col) {
      return `${sheet.name}!${a1(row, col)}`;
    }

    function resolveFormulaSheet(workbook, name, fallback) {
      if (!name) return fallback;
      return workbook.worksheets.getItem(String(name).replace(/^'|'$/g, "")) || fallback;
    }

    function asNumber(value) {
      if (value == null || value === "") return 0;
      if (typeof value === "number") return value;
      if (typeof value === "boolean") return value ? 1 : 0;
      const numeric = Number(value);
      return Number.isFinite(numeric) ? numeric : 0;
    }

    function flattenFormulaArgs(values) {
      const out = [];
      values.forEach((value) => {
        if (Array.isArray(value)) out.push(...flattenFormulaArgs(value));
        else out.push(value);
      });
      return out;
    }

    export function SUM(...args) {
      return flattenFormulaArgs(args).reduce((sum, value) => sum + asNumber(value), 0);
    }

    export function AVERAGE(...args) {
      const values = flattenFormulaArgs(args).filter((value) => value !== null && value !== "");
      return values.length ? values.reduce((sum, value) => sum + asNumber(value), 0) / values.length : 0;
    }

    export function MIN(...args) {
      return Math.min(...flattenFormulaArgs(args).map(asNumber));
    }

    export function MAX(...args) {
      return Math.max(...flattenFormulaArgs(args).map(asNumber));
    }

    export function COUNT(...args) {
      return flattenFormulaArgs(args).filter((value) => value !== null && value !== "" && Number.isFinite(Number(value))).length;
    }

    export function COUNTA(...args) {
      return flattenFormulaArgs(args).filter((value) => value !== null && value !== "").length;
    }

    export function ROUND(value, digits = 0) {
      return Number(asNumber(value).toFixed(asNumber(digits)));
    }

    export function ROUNDDOWN(value, digits = 0) {
      const factor = 10 ** asNumber(digits);
      return Math.trunc(asNumber(value) * factor) / factor;
    }

    export function ROUNDUP(value, digits = 0) {
      const factor = 10 ** asNumber(digits);
      const number = asNumber(value) * factor;
      return (number < 0 ? Math.floor(number) : Math.ceil(number)) / factor;
    }

    export function ABS(value) { return Math.abs(asNumber(value)); }
    export function POWER(value, exponent) { return asNumber(value) ** asNumber(exponent); }
    export function SQRT(value) { return Math.sqrt(asNumber(value)); }
    export function IF(condition, yesValue, noValue = false) { return condition ? yesValue : noValue; }
    export function IFERROR(value, fallback) { return (value == null || String(value).startsWith("#")) ? fallback : value; }
    export function AND(...args) { return flattenFormulaArgs(args).every(Boolean); }
    export function OR(...args) { return flattenFormulaArgs(args).some(Boolean); }
    export function NOT(value) { return !value; }
    export function CONCAT(...args) { return flattenFormulaArgs(args).map((value) => value == null ? "" : String(value)).join(""); }
    export const CONCATENATE = CONCAT;
    export function LEN(value) { return String(value == null ? "" : value).length; }
    export function LEFT(value, count = 1) { return String(value == null ? "" : value).slice(0, asNumber(count)); }
    export function RIGHT(value, count = 1) { const text = String(value == null ? "" : value); return text.slice(Math.max(0, text.length - asNumber(count))); }
    export function MID(value, start, count) { return String(value == null ? "" : value).slice(Math.max(0, asNumber(start) - 1), Math.max(0, asNumber(start) - 1) + asNumber(count)); }
    export function LOWER(value) { return String(value == null ? "" : value).toLowerCase(); }
    export function UPPER(value) { return String(value == null ? "" : value).toUpperCase(); }
    export function TRIM(value) { return String(value == null ? "" : value).trim().replace(/\s+/g, " "); }
    export function TODAY() { const now = new Date(); return new Date(now.getFullYear(), now.getMonth(), now.getDate()); }
    export function NOW() { return new Date(); }
    export const TRUE = true;
    export const FALSE = false;

    const FORMULA_FUNCTIONS = {
      SUM, AVERAGE, MIN, MAX, COUNT, COUNTA, ROUND, ROUNDDOWN, ROUNDUP, ABS, POWER, SQRT,
      IF, IFERROR, AND, OR, NOT, CONCAT, CONCATENATE, LEN, LEFT, RIGHT, MID, LOWER, UPPER, TRIM,
      TODAY, NOW
    };

    function rangeFormulaValues(sheet, bounds, seen) {
      const out = [];
      for (let r = 0; r < bounds.rows; r += 1) {
        const row = [];
        for (let c = 0; c < bounds.cols; c += 1) row.push(cellFormulaValue(sheet, bounds.row + r, bounds.col + c, seen));
        out.push(row);
      }
      return out;
    }

    function formulaDependencies(sheet, formula) {
      const deps = [];
      const text = String(formula || "").replace(/^=/, "");
      const pushRange = (targetSheet, start, end) => {
        const rangeSheet = resolveFormulaSheet(sheet.workbook, targetSheet, sheet);
        const first = parseCell(start.replace(/\$/g, ""));
        const last = parseCell(end.replace(/\$/g, ""));
        const rowStart = Math.min(first.row, last.row);
        const rowEnd = Math.max(first.row, last.row);
        const colStart = Math.min(first.col, last.col);
        const colEnd = Math.max(first.col, last.col);
        for (let row = rowStart; row <= rowEnd; row += 1) {
          for (let col = colStart; col <= colEnd; col += 1) deps.push({ sheet: rangeSheet, row, col });
        }
      };
      text.replace(/(?:(?:'([^']+)'|([A-Za-z_][A-Za-z0-9_ .]*))!)?(\$?[A-Za-z]+\$?\d+):(\$?[A-Za-z]+\$?\d+)/g, (_, quotedSheet, bareSheet, start, end) => {
        pushRange(quotedSheet || bareSheet || "", start, end);
        return "";
      });
      text.replace(/(?:(?:'([^']+)'|([A-Za-z_][A-Za-z0-9_ .]*))!)?(\$?[A-Za-z]+\$?\d+)/g, (_, quotedSheet, bareSheet, ref) => {
        const targetSheet = resolveFormulaSheet(sheet.workbook, quotedSheet || bareSheet || "", sheet);
        const cell = parseCell(ref.replace(/\$/g, ""));
        deps.push({ sheet: targetSheet, row: cell.row, col: cell.col });
        return "";
      });
      return deps;
    }

    function evaluateFormula(sheet, formula, row, col, seen) {
      let expr = String(formula || "").trim().replace(/^=/, "").replace(/\$/g, "");
      const activeSeen = new Set(seen || []);
      const callRange = (sheetName, start, end) => {
        const targetSheet = resolveFormulaSheet(sheet.workbook, sheetName, sheet);
        const first = parseCell(start);
        const last = parseCell(end);
        return rangeFormulaValues(targetSheet, {
          row: Math.min(first.row, last.row),
          col: Math.min(first.col, last.col),
          rows: Math.abs(last.row - first.row) + 1,
          cols: Math.abs(last.col - first.col) + 1
        }, activeSeen);
      };
      const callCell = (sheetName, ref) => {
        const targetSheet = resolveFormulaSheet(sheet.workbook, sheetName, sheet);
        const cell = parseCell(ref);
        return cellFormulaValue(targetSheet, cell.row, cell.col, activeSeen);
      };
      const placeholders = [];
      expr = expr.replace(/(?:(?:'([^']+)'|([A-Za-z_][A-Za-z0-9_ .]*))!)?([A-Za-z]+\d+):([A-Za-z]+\d+)/g, (_, quotedSheet, bareSheet, start, end) => {
        const token = `__JB_FORMULA_${placeholders.length}__`;
        placeholders.push(`RANGE(${JSON.stringify(quotedSheet || bareSheet || "")},${JSON.stringify(start)},${JSON.stringify(end)})`);
        return token;
      });
      expr = expr.replace(/(?:(?:'([^']+)'|([A-Za-z_][A-Za-z0-9_ .]*))!)?([A-Za-z]+\d+)/g, (_, quotedSheet, bareSheet, ref) => {
        const token = `__JB_FORMULA_${placeholders.length}__`;
        placeholders.push(`CELL(${JSON.stringify(quotedSheet || bareSheet || "")},${JSON.stringify(ref)})`);
        return token;
      });
      placeholders.forEach((replacement, index) => {
        expr = expr.replace(`__JB_FORMULA_${index}__`, replacement);
      });
      expr = expr.replace(/\^/g, "**").replace(/<>/g, "!=");
      const funcs = FORMULA_FUNCTIONS;
      try {
        return Function("CELL", "RANGE", ...Object.keys(funcs), `"use strict"; return (${expr});`)(
          callCell,
          callRange,
          ...Object.values(funcs)
        );
      } catch (error) {
        throw new Error(`Unsupported formula at ${formulaAddress(sheet, row, col)}: ${formula} (${error.message})`);
      }
    }

    function cellFormulaValue(sheet, row, col, seen) {
      const key = `${sheet.name}:${row},${col}`;
      const activeSeen = new Set(seen || []);
      if (activeSeen.has(key)) throw new Error(`Circular formula reference at ${formulaAddress(sheet, row, col)}`);
      const record = sheet.cells[`${row},${col}`] || {};
      if (!record.formula) return record.value ?? null;
      activeSeen.add(key);
      return evaluateFormula(sheet, record.formula, row, col, activeSeen);
    }

    function inspectFormulaErrors(workbook, options) {
      const errors = [];
      workbook.worksheets.items.forEach((sheet) => {
        Object.keys(sheet.cells).forEach((key) => {
          const record = sheet.cells[key];
          if (!record.formula) return;
          const [row, col] = key.split(",").map((n) => Number(n));
          try {
            cellFormulaValue(sheet, row, col, new Set());
          } catch (error) {
            errors.push({ address: formulaAddress(sheet, row, col), formula: record.formula, error: error.message });
          }
        });
      });
      return {
        ndjson: [
          JSON.stringify({ kind: "workbook", sheets: workbook.worksheets.items.map((sheet) => sheet.name), options: options || {} }),
          ...errors.map((error) => JSON.stringify({ kind: "formulaError", ...error }))
        ].join("\n") + "\n",
        errors
      };
    }

    function traceCell(sheet, row, col, seen) {
      const key = `${sheet.name}:${row},${col}`;
      const activeSeen = new Set(seen || []);
      const record = sheet.cells[`${row},${col}`] || {};
      if (activeSeen.has(key)) return { address: formulaAddress(sheet, row, col), error: "circular" };
      activeSeen.add(key);
      const node = {
        address: formulaAddress(sheet, row, col),
        formula: record.formula || null,
        value: null,
        dependencies: []
      };
      try {
        node.value = cellFormulaValue(sheet, row, col, new Set(seen || []));
      } catch (error) {
        node.error = error.message;
      }
      if (record.formula) {
        node.dependencies = formulaDependencies(sheet, record.formula)
          .slice(0, 200)
          .map((dep) => traceCell(dep.sheet, dep.row, dep.col, activeSeen));
      }
      return node;
    }

    function chartBounds(chart) {
      const start = typeof chart.position === "string" ? parseCell(chart.position) : null;
      const end = typeof chart.endPosition === "string" ? parseCell(chart.endPosition) : null;
      if (start && end) {
        return {
          row: Math.min(start.row, end.row),
          col: Math.min(start.col, end.col),
          rows: Math.max(6, Math.abs(end.row - start.row) + 1),
          cols: Math.max(4, Math.abs(end.col - start.col) + 1)
        };
      }
      if (start) return { row: start.row, col: start.col, rows: 12, cols: 6 };
      return { row: 0, col: 6, rows: 12, cols: 6 };
    }

    function chartSourceValues(chart) {
      const range = chart.sourceRange || chart.options.sourceRange;
      if (!range || !range.values) return { headers: [], categories: [], series: [] };
      const values = range.values;
      const headers = (values[0] || []).map((value) => String(value == null ? "" : value));
      const categories = values.slice(1).map((row) => String((row || [])[0] == null ? "" : (row || [])[0]));
      const series = [];
      for (let c = 1; c < Math.max(2, headers.length); c += 1) {
        series.push({
          name: headers[c] || `Series ${c}`,
          values: values.slice(1).map((row) => asNumber((row || [])[c]))
        });
      }
      return { headers, categories, series };
    }

    function renderChart(canvas, chart, frame) {
      const border = [75, 85, 99, 255];
      const grid = [229, 231, 235, 255];
      const text = [17, 24, 39, 255];
      const colors = [[37, 99, 235, 255], [5, 150, 105, 255], [220, 38, 38, 255], [124, 58, 237, 255]];
      fillRect(canvas, frame.left, frame.top, frame.width, frame.height, [255, 255, 255, 255]);
      strokeRect(canvas, frame.left, frame.top, frame.width, frame.height, border);
      const title = typeof chart.title === "string" ? chart.title : (chart.name || "Chart");
      drawText(canvas, title, frame.left + 8, frame.top + 8, Math.max(24, frame.width - 16), text);
      const data = chartSourceValues(chart);
      if (!data.series.length || !data.categories.length) {
        drawText(canvas, "NO DATA", frame.left + 8, frame.top + 28, frame.width - 16, text);
        return;
      }
      const plot = {
        left: frame.left + 32,
        top: frame.top + 30,
        width: Math.max(20, frame.width - 44),
        height: Math.max(20, frame.height - 58)
      };
      strokeRect(canvas, plot.left, plot.top, plot.width, plot.height, grid);
      const values = data.series.flatMap((series) => series.values);
      const maxValue = Math.max(1, ...values.map(asNumber));
      const minValue = Math.min(0, ...values.map(asNumber));
      const span = Math.max(1, maxValue - minValue);
      const xFor = (index) => plot.left + Math.round((plot.width - 10) * (data.categories.length === 1 ? 0.5 : index / (data.categories.length - 1))) + 5;
      const yFor = (value) => plot.top + plot.height - 4 - Math.round(((asNumber(value) - minValue) / span) * (plot.height - 8));
      const kind = String(chart.type || "").toLowerCase();
      if (kind.includes("bar") || kind.includes("column")) {
        const groupWidth = Math.max(4, Math.floor((plot.width - 10) / Math.max(1, data.categories.length)));
        const barWidth = Math.max(2, Math.floor(groupWidth / Math.max(1, data.series.length + 1)));
        data.series.forEach((series, seriesIndex) => {
          series.values.forEach((value, index) => {
            const x = plot.left + 5 + index * groupWidth + seriesIndex * barWidth;
            const y = yFor(value);
            fillRect(canvas, x, y, barWidth - 1, plot.top + plot.height - 4 - y, colors[seriesIndex % colors.length]);
          });
        });
      } else {
        data.series.forEach((series, seriesIndex) => {
          let previous = null;
          series.values.forEach((value, index) => {
            const point = { x: xFor(index), y: yFor(value) };
            if (previous) drawLine(canvas, previous.x, previous.y, point.x, point.y, colors[seriesIndex % colors.length]);
            fillRect(canvas, point.x - 2, point.y - 2, 5, 5, colors[seriesIndex % colors.length]);
            previous = point;
          });
        });
      }
      drawText(canvas, data.categories[0] || "", plot.left, plot.top + plot.height + 8, Math.floor(plot.width / 2), text);
      drawText(canvas, data.categories[data.categories.length - 1] || "", plot.left + Math.floor(plot.width / 2), plot.top + plot.height + 8, Math.floor(plot.width / 2), text);
    }

    function parseSharedStrings(xmlText) {
      const strings = [];
      const matches = String(xmlText).match(/<si\b[\s\S]*?<\/si>/g) || [];
      matches.forEach((entry) => {
        const textParts = [];
        const textMatches = entry.match(/<t\b[^>]*>[\s\S]*?<\/t>/g) || [];
        textMatches.forEach((part) => {
          textParts.push(xmlDecode(part.replace(/^<t\b[^>]*>/, "").replace(/<\/t>$/, "")));
        });
        strings.push(textParts.join(""));
      });
      return strings;
    }

    function parseRelationships(relsXml, basePrefix) {
      const relTargets = {};
      (String(relsXml).match(/<Relationship\b[^>]*\/>/g) || []).forEach((rel) => {
        const id = (rel.match(/\bId="([^"]+)"/) || [])[1];
        const target = (rel.match(/\bTarget="([^"]+)"/) || [])[1];
        if (id && target) relTargets[id] = target.startsWith("/") ? target.slice(1) : `${basePrefix || ""}${target}`;
      });
      return relTargets;
    }

    function parseWorkbookSheets(workbookXml, relsXml) {
      const relTargets = parseRelationships(relsXml, "xl/");

      const sheets = [];
      (String(workbookXml).match(/<sheet\b[^>]*\/>/g) || []).forEach((sheet) => {
        const name = xmlDecode((sheet.match(/\bname="([^"]+)"/) || [])[1] || `Sheet${sheets.length + 1}`);
        const relId = (sheet.match(/\br:id="([^"]+)"/) || [])[1];
        const target = relTargets[relId] || `xl/worksheets/sheet${sheets.length + 1}.xml`;
        sheets.push({ name, target });
      });
      return sheets.length ? sheets : [{ name: "Sheet1", target: "xl/worksheets/sheet1.xml" }];
    }

    function parseWorksheetCells(sheet, xmlText, sharedStrings) {
      const cellMatches = String(xmlText).match(/<c\b[\s\S]*?<\/c>/g) || [];
      cellMatches.forEach((cellXml) => {
        const ref = (cellXml.match(/\br="([^"]+)"/) || [])[1];
        if (!ref) return;
        const cell = parseCell(ref);
        const type = (cellXml.match(/\bt="([^"]+)"/) || [])[1] || "";
        const formulaMatch = cellXml.match(/<f\b[^>]*>([\s\S]*?)<\/f>/);
        const valueMatch = cellXml.match(/<v\b[^>]*>([\s\S]*?)<\/v>/);
        const inlineMatch = cellXml.match(/<is\b[\s\S]*?<t\b[^>]*>([\s\S]*?)<\/t>[\s\S]*?<\/is>/);
        const record = {};
        if (formulaMatch) record.formula = "=" + xmlDecode(formulaMatch[1]);
        if (type === "s" && valueMatch) {
          record.value = sharedStrings[Number(valueMatch[1])] ?? "";
        } else if (type === "b" && valueMatch) {
          record.value = valueMatch[1] === "1";
        } else if (inlineMatch) {
          record.value = xmlDecode(inlineMatch[1]);
        } else if (valueMatch) {
          const raw = xmlDecode(valueMatch[1]);
          const numeric = Number(raw);
          record.value = Number.isNaN(numeric) ? raw : numeric;
        }
        sheet.cells[`${cell.row},${cell.col}`] = record;
      });
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
      add(...args) {
        const item = this.factory(...args);
        this.items.push(item);
        return item;
      }
      getItem(indexOrName) {
        if (typeof indexOrName === "number") return this.items[indexOrName];
        if (indexOrName && typeof indexOrName === "object" && indexOrName.id) return this.items.find((item) => item && item.id === indexOrName.id);
        return this.items.find((item) => item && (item.name === indexOrName || item.id === indexOrName));
      }
      getItemOrNullObject(indexOrName) {
        return this.getItem(indexOrName) || { isNullObject: true, name: indexOrName, delete() {} };
      }
      deleteAll() {
        this.items = [];
      }
      get count() {
        return this.items.length;
      }
    }

    function rangeFormat() {
      return {
        fill: {},
        font: {},
        borders: {},
        alignment: {},
        numberFormat: "",
        wrapText: false,
        columnWidth: undefined,
        rowHeight: undefined,
        columnWidthPx: undefined,
        rowHeightPx: undefined,
        autofitColumns() {},
        autofitRows() {}
      };
    }

    function unsupportedArtifactToolFeature(name) {
      throw new Error(`${name} is not implemented by the Just Bash iOS artifact-tool compatibility package`);
    }

    function docParagraphXml(text) {
      return `<w:p><w:r><w:t>${xml(text)}</w:t></w:r></w:p>`;
    }

    function parseWordParagraphs(documentXml) {
      const paragraphs = [];
      const matches = String(documentXml).match(/<w:p\b[\s\S]*?<\/w:p>/g) || [];
      matches.forEach((paragraphXml) => {
        const parts = [];
        const textMatches = paragraphXml.match(/<w:t\b[^>]*>[\s\S]*?<\/w:t>/g) || [];
        textMatches.forEach((part) => {
          parts.push(xmlDecode(part.replace(/^<w:t\b[^>]*>/, "").replace(/<\/w:t>$/, "")));
        });
        paragraphs.push(parts.join(""));
      });
      return paragraphs;
    }

    export class DocumentModel {
      constructor(options) {
        const source = options || {};
        this.paragraphs = Array.isArray(source.paragraphs) ? [...source.paragraphs] : [];
        this.metadata = source.metadata || {};
      }
      static create(options) {
        return new DocumentModel(options || {});
      }
      get text() {
        return this.paragraphs.join("\n");
      }
      set text(value) {
        this.paragraphs = String(value == null ? "" : value).split(/\r?\n/);
      }
      addParagraph(text = "") {
        this.paragraphs.push(String(text));
        return { text: String(text), index: this.paragraphs.length - 1 };
      }
      inspect(options = {}) {
        const rows = [
          JSON.stringify({ kind: "document", paragraphs: this.paragraphs.length, options }),
          ...this.paragraphs.map((text, index) => JSON.stringify({ kind: "paragraph", index, text }))
        ];
        return { ndjson: rows.join("\n") + "\n", paragraphs: [...this.paragraphs] };
      }
      help(query) {
        return { ndjson: JSON.stringify({ query, note: "Just Bash iOS DocumentModel supports text paragraphs plus DOCX import/export" }) + "\n" };
      }
      toJSON() {
        return { paragraphs: [...this.paragraphs], metadata: this.metadata };
      }
    }

    export class DocumentFile {
      static async importDocx(blob) {
        const files = await unzipOfficeZip(blob instanceof FileBlob ? blob.data : blob);
        const documentXml = zipText(files, "word/document.xml");
        if (!documentXml) throw new Error("DocumentFile.importDocx could not find word/document.xml");
        return new DocumentModel({ paragraphs: parseWordParagraphs(documentXml) });
      }
      static async exportDocx(document) {
        const model = document instanceof DocumentModel ? document : new DocumentModel(document || {});
        const body = (model.paragraphs.length ? model.paragraphs : [""]).map(docParagraphXml).join("");
        const files = {
          "[Content_Types].xml": `<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>`,
          "_rels/.rels": `<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>`,
          "word/document.xml": `<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>${body}<w:sectPr/></w:body></w:document>`
        };
        return new FileBlob(zip(files), MIME.docx);
      }
    }

    export class Presentation {
      constructor(options) {
        this.slideSize = (options && options.slideSize) || { width: 1280, height: 720 };
        this.slides = new SlideCollection(this);
        this.comments = new CommentCollection();
        this.layouts = new LooseCollection((name, options) => ({ name, id: `layout-${this.layouts.count + 1}`, options: options || {}, shapes: new LooseCollection((shapeOptions) => new Shape(shapeOptions)), setParentLayoutId(value) { this.parentLayoutId = value; }, setColorMap(value) { this.colorMap = value; } }));
        this.masters = new LooseCollection((name) => ({ name, id: `master-${this.masters.count + 1}` }));
      }
      static create(options) {
        return new Presentation(options || {});
      }
      getActiveSlide() {
        return this.slides.getItem(0) || this.slides.add();
      }
      async export(options) {
        const format = (options && options.format) || "png";
        if (format === "layout") {
          return new FileBlob(JSON.stringify(presentationLayout(this, options && options.slide), null, 2), "application/json");
        }
        if (format === "png") {
          return renderPresentationPng(this, options || {});
        }
        unsupportedArtifactToolFeature(`Presentation.export(${format})`);
      }
      async inspect(options = {}) {
        return { ndjson: this.slides.items.map((slide, index) => JSON.stringify({ kind: "slide", index, id: slide.id, elements: slide.shapes.count + slide.images.count })).join("\n") + "\n" };
      }
      help(query) {
        return { ndjson: JSON.stringify({ query, note: "Just Bash iOS Presentation supports slides, shapes, images, comments, layout preview, PNG and PPTX export" }) + "\n" };
      }
      resolve(id) {
        const value = String(id || "");
        const slideMatch = value.match(/^sl\/(.+)$/);
        if (slideMatch) return this.slides.items.find((slide) => slide.id === slideMatch[1]);
        const shapeMatch = value.match(/^sh\/([^./]+)\.(.+)$/);
        if (shapeMatch) {
          const slide = this.slides.items.find((candidate) => candidate.id === shapeMatch[1]);
          return slide && slide.shapes.items.find((shape) => shape.id === shapeMatch[2]);
        }
        return null;
      }
      record(fn) {
        const value = fn();
        return { value, patch: [] };
      }
      template(name) {
        return { name, patch: [] };
      }
      apply(template) {
        if (template && Array.isArray(template.patch)) return template.patch;
        return [];
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
        super((options) => new Slide(presentation, options || {}));
        this.presentation = presentation;
      }
      getItem(indexOrId) {
        if (typeof indexOrId === "number") return this.items[indexOrId];
        if (indexOrId && typeof indexOrId === "object" && indexOrId.id) return this.items.find((slide) => slide.id === indexOrId.id);
        return this.items.find((slide) => slide.id === indexOrId);
      }
    }

    export class Slide {
      constructor(presentation, options) {
        this.presentation = presentation;
        this.id = (options && options.id) || `slide-${presentation.slides.count + 1}`;
        this.shapes = new LooseCollection((options) => new Shape(options));
        this.images = new LooseCollection((options) => new Image(options));
        this.tables = new LooseCollection((options) => ({ options: options || {}, position: (options || {}).position || {} }));
        this.background = {};
        this.speakerNotes = {
          text: "",
          append: (value) => { this.speakerNotes.text += String(value == null ? "" : value); },
          clear: () => { this.speakerNotes.text = ""; }
        };
      }
      get index() {
        return this.presentation.slides.items.indexOf(this);
      }
      setLayout(layout) {
        this.layout = layout;
        return this;
      }
      setViewportSize(width, height) {
        this.presentation.slideSize = { width: Number(width) || this.presentation.slideSize.width, height: Number(height) || this.presentation.slideSize.height };
        return this;
      }
      duplicate() {
        const copy = new Slide(this.presentation, { id: `slide-${this.presentation.slides.count + 1}` });
        copy.background = { ...this.background };
        this.shapes.items.forEach((shape) => copy.shapes.items.push(shape.clone()));
        this.images.items.forEach((image) => copy.images.items.push(image.clone()));
        this.presentation.slides.items.splice(this.index + 1, 0, copy);
        return copy;
      }
      moveTo(index) {
        const slides = this.presentation.slides.items;
        const current = slides.indexOf(this);
        if (current < 0) return this;
        slides.splice(current, 1);
        slides.splice(Math.max(0, Math.min(slides.length, Number(index) || 0)), 0, this);
        return this;
      }
      delete() {
        this.presentation.slides.items = this.presentation.slides.items.filter((slide) => slide !== this);
      }
      async export(options = {}) {
        return await this.presentation.export({ ...options, slide: this });
      }
      toJSON() {
        return {
          id: this.id,
          shapes: this.shapes.items.map((shape) => shape.toJSON()),
          images: this.images.items.map((image) => image.toJSON())
        };
      }
    }

    export class Shape {
      constructor(options) {
        this.options = options || {};
        this.id = this.options.id || `shape-${Math.random().toString(36).slice(2, 10)}`;
        this.name = this.options.name;
        this.position = this.options.position || {};
        this.fill = this.options.fill;
        this.line = this.options.line;
        this.geometry = this.options.geometry || "rect";
        this._text = new TextFrame("");
      }
      get text() {
        return this._text;
      }
      set text(value) {
        this._text = value instanceof TextFrame ? value : new TextFrame(value);
      }
      get frame() {
        return this.position;
      }
      set frame(value) {
        this.position = value || {};
      }
      bringToFront() {}
      sendToBack() {}
      delete() {
        this.deleted = true;
      }
      clone() {
        const copy = new Shape({ ...this.options, id: undefined, name: this.name, position: { ...this.position }, fill: this.fill, line: this.line, geometry: this.geometry });
        copy.text = new TextFrame(this.text.plain);
        copy.text.fontSize = this.text.fontSize;
        copy.text.color = this.text.color;
        return copy;
      }
      toJSON() {
        return { id: this.id, name: this.name, position: this.position, geometry: this.geometry, text: this.text.plain };
      }
    }

    export class TextFrame {
      constructor(value) {
        this.plain = String(value == null ? "" : value);
        this.fontSize = 24;
        this.color = "#111827";
        this.bold = false;
        this.typeface = "Aptos";
        this.alignment = "left";
        this.verticalAlignment = "top";
        this.insets = { left: 0, right: 0, top: 0, bottom: 0 };
      }
      toString() {
        return this.plain;
      }
      add(value) {
        this.plain += String(value == null ? "" : value);
        return this;
      }
      replace(search, replacement) {
        this.plain = this.plain.replace(search instanceof RegExp ? search : String(search), String(replacement == null ? "" : replacement));
        return this;
      }
      get(search) {
        const text = this;
        return {
          bold: text.bold,
          italic: text.italic || false,
          fontSize: text.fontSize,
          color: text.color,
          text: String(search == null ? "" : search)
        };
      }
      getRange(start, length) {
        return { start, length, text: this.plain.slice(start, start + length), bold: this.bold, fontSize: this.fontSize, color: this.color };
      }
    }

    export class Image {
      constructor(options) {
        this.options = options || {};
        this.id = this.options.id || `image-${Math.random().toString(36).slice(2, 10)}`;
        this.name = this.options.name;
        this.position = this.options.position || {};
        this.alt = this.options.alt || "";
        this.prompt = this.options.prompt;
        this.fit = this.options.fit || "contain";
        this.crop = this.options.crop || {};
        this.geometry = this.options.geometry;
      }
      get frame() {
        return this.position;
      }
      set frame(value) {
        this.position = value || {};
      }
      get isPlaceholder() {
        return !!this.prompt && !this.options.path && !this.options.dataUrl && !this.options.uri;
      }
      replace(source) {
        this.options = { ...this.options, ...(source || {}) };
        return this;
      }
      regenerate(options) {
        this.regeneration = options || {};
        return this;
      }
      delete() {
        this.deleted = true;
      }
      clone() {
        return new Image({ ...this.options, id: undefined, name: this.name, position: { ...this.position } });
      }
      toJSON() {
        return { id: this.id, name: this.name, position: this.position, alt: this.options.alt || "" };
      }
    }

    function exportedSlide(presentation, requestedSlide) {
      return requestedSlide || presentation.slides.getItem(0) || presentation.slides.add();
    }

    function presentationLayout(presentation, requestedSlide) {
      const slide = exportedSlide(presentation, requestedSlide);
      const slideSize = presentation.slideSize || { width: 1280, height: 720 };
      const elements = [];
      slide.shapes.items.forEach((shape, index) => {
        const frame = frameOf(shape.position, {});
        const text = shape.text && typeof shape.text.plain === "string" ? shape.text.plain : "";
        elements.push({
          kind: "shape",
          name: shape.name || `shape-${index + 1}`,
          bbox: [frame.left, frame.top, frame.width, frame.height],
          geometry: shape.geometry,
          textPreview: text,
          text,
          resolvedFontSize: shape.text && shape.text.fontSize ? shape.text.fontSize : 24,
          resolvedTextStyle: { fontSize: shape.text && shape.text.fontSize ? shape.text.fontSize : 24 },
          textLayout: { lineCount: Math.max(1, String(text).split(/\r?\n/).length) }
        });
      });
      slide.images.items.forEach((image, index) => {
        const frame = frameOf(image.position, {});
        elements.push({
          kind: "image",
          name: image.name || image.options.name || `image-${index + 1}`,
          bbox: [frame.left, frame.top, frame.width, frame.height],
          alt: image.options.alt || ""
        });
      });
      return {
        slide: { frame: { left: 0, top: 0, width: slideSize.width, height: slideSize.height } },
        elements
      };
    }

    function renderPresentationPng(presentation, options) {
      const slide = exportedSlide(presentation, options.slide);
      const slideSize = presentation.slideSize || { width: 1280, height: 720 };
      const scale = Math.max(0.1, Math.min(2, Number(options.scale || 1) || 1));
      const width = Math.max(1, Math.min(1800, Math.round(slideSize.width * scale)));
      const height = Math.max(1, Math.min(1800, Math.round(slideSize.height * scale)));
      const actualScale = Math.min(width / slideSize.width, height / slideSize.height);
      const background = colorBytes(slide.background.fill || slide.background.color || slide.background, [255, 255, 255, 255]);
      const canvas = makeCanvas(width, height, background);
      slide.shapes.items.forEach((shape) => {
        const frame = scaledFrame(frameOf(shape.position, {}), actualScale);
        const fill = colorBytes(shape.fill, null);
        if (fill) fillRect(canvas, frame.left, frame.top, frame.width, frame.height, fill);
        const line = shape.line || {};
        const stroke = colorBytes(line.fill || line.color, [0, 0, 0, 0]);
        const lineWidth = Math.max(1, Math.round(Number(line.width || 1) * actualScale));
        for (let i = 0; i < lineWidth; i += 1) {
          strokeRect(canvas, frame.left + i, frame.top + i, Math.max(1, frame.width - i * 2), Math.max(1, frame.height - i * 2), stroke);
        }
        const text = shape.text && typeof shape.text.plain === "string" ? shape.text.plain : "";
        if (text) {
          const insets = (shape.text && shape.text.insets) || {};
          const x = frame.left + Math.round(Number(insets.left || 8) * actualScale);
          const y = frame.top + Math.round(Number(insets.top || 8) * actualScale);
          drawText(canvas, text, x, y, Math.max(1, frame.width - 12), colorBytes(shape.text.color, [17, 24, 39, 255]));
        }
      });
      slide.images.items.forEach((image) => {
        const frame = scaledFrame(frameOf(image.position, {}), actualScale);
        fillRect(canvas, frame.left, frame.top, frame.width, frame.height, [229, 231, 235, 255]);
        strokeRect(canvas, frame.left, frame.top, frame.width, frame.height, [107, 114, 128, 255]);
        drawText(canvas, image.options.alt || image.name || "IMAGE", frame.left + 8, frame.top + 8, Math.max(1, frame.width - 16), [55, 65, 81, 255]);
      });
      return new FileBlob(pngImage(width, height, canvas.rgba), MIME.png);
    }

    function slideXml(slide) {
      const shapes = slide.shapes.items.map((shape, index) => {
        const text = shape.text && typeof shape.text.plain === "string" ? shape.text.plain : String(shape.text || "");
        return `<p:sp><p:nvSpPr><p:cNvPr id="${index + 2}" name="Text ${index + 1}"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="4000000" cy="700000"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:noFill/><a:ln><a:noFill/></a:ln></p:spPr><p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:rPr lang="en-US" sz="2400"/><a:t>${xml(text)}</a:t></a:r></a:p></p:txBody></p:sp>`;
      }).join("");
      return `<?xml version="1.0" encoding="UTF-8" standalone="yes"?><p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>${shapes}</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>`;
    }

    export class PresentationFile {
      static async importPptx(blob) {
        const files = await unzipOfficeZip(blob instanceof FileBlob ? blob.data : blob);
        const presentationXml = zipText(files, "ppt/presentation.xml");
        if (!presentationXml) throw new Error("PresentationFile.importPptx could not find ppt/presentation.xml");
        const relTargets = parseRelationships(zipText(files, "ppt/_rels/presentation.xml.rels"), "ppt/");
        const presentation = Presentation.create();
        presentation.slides.deleteAll();
        const slideIds = [];
        presentationXml.replace(/<p:sldId\b[^>]*\br:id="([^"]+)"[^>]*\/>/g, (_, relId) => {
          slideIds.push(relId);
          return "";
        });
        const targets = slideIds.length ? slideIds.map((relId) => relTargets[relId]).filter(Boolean) : Object.keys(files).filter((name) => /^ppt\/slides\/slide\d+\.xml$/.test(name)).sort();
        targets.forEach((target, index) => {
          const slideXmlText = zipText(files, target);
          const slide = presentation.slides.add({ id: `slide-${index + 1}` });
          const textRuns = [];
          (slideXmlText.match(/<a:t\b[^>]*>[\s\S]*?<\/a:t>/g) || []).forEach((part) => {
            textRuns.push(xmlDecode(part.replace(/^<a:t\b[^>]*>/, "").replace(/<\/a:t>$/, "")));
          });
          if (textRuns.length) {
            const shape = slide.shapes.add({
              name: `imported-text-${index + 1}`,
              position: { left: 48, top: 48, width: presentation.slideSize.width - 96, height: 120 },
              fill: "transparent",
              line: { fill: "transparent", width: 0 }
            });
            shape.text = textRuns.join("\n");
          }
        });
        return presentation;
      }
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

    class CommentCollection {
      constructor() {
        this.self = null;
        this.threads = [];
      }
      setSelf(author) {
        this.self = author || {};
        return this.self;
      }
      addThread(target, text) {
        const thread = {
          target,
          comments: [{ author: this.self, text: String(text == null ? "" : text) }],
          addComment: (value) => {
            thread.comments.push({ author: this.self, text: String(value == null ? "" : value) });
            return thread.comments[thread.comments.length - 1];
          }
        };
        this.threads.push(thread);
        return thread;
      }
    }

    export class Workbook {
      constructor() {
        this.worksheets = new WorksheetCollection(this);
        this.comments = new CommentCollection();
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
      async fromCSV(csvText, options) {
        const sheet = this.worksheets.getOrAdd((options && options.sheetName) || "ImportedData");
        const rows = csvRows(csvText);
        if (rows.length) sheet.getRangeByIndexes(0, 0, rows.length, Math.max(...rows.map((row) => row.length))).values = rows;
        return sheet;
      }
      getActiveWorksheet() {
        return this.worksheets.items[0] || this.worksheets.add("Sheet1");
      }
      async render(options) {
        const opts = options || {};
        const format = opts.format || "png";
        if (format !== "png") unsupportedArtifactToolFeature(`Workbook.render(${format})`);
        const sheet = (opts.sheetName && this.worksheets.getItem(opts.sheetName)) || this.getActiveWorksheet();
        const range = opts.range ? sheet.getRange(opts.range) : sheet.getUsedRange();
        const cellWidth = Math.max(48, Math.min(220, Math.round((opts.cellWidth || 112) * (opts.scale || 1))));
        const cellHeight = Math.max(22, Math.min(72, Math.round((opts.cellHeight || 28) * (opts.scale || 1))));
        const rows = Math.min(range.bounds.rows, Math.max(1, Math.floor(1800 / cellHeight)));
        const cols = Math.min(range.bounds.cols, Math.max(1, Math.floor(1800 / cellWidth)));
        const width = cols * cellWidth + 1;
        const height = rows * cellHeight + 1;
        const canvas = makeCanvas(width, height, [255, 255, 255, 255]);
        const grid = [209, 213, 219, 255];
        const text = [17, 24, 39, 255];
        for (let r = 0; r < rows; r += 1) {
          for (let c = 0; c < cols; c += 1) {
            const x = c * cellWidth;
            const y = r * cellHeight;
            let value = null;
            try {
              value = cellFormulaValue(sheet, range.bounds.row + r, range.bounds.col + c, new Set());
            } catch (error) {
              value = "#ERROR!";
            }
            strokeRect(canvas, x, y, cellWidth + 1, cellHeight + 1, grid);
            drawText(canvas, value == null ? "" : value, x + 6, y + 8, cellWidth - 12, text);
          }
        }
        sheet.charts.items.forEach((chart) => {
          const bounds = chartBounds(chart);
          const frame = {
            left: (bounds.col - range.bounds.col) * cellWidth,
            top: (bounds.row - range.bounds.row) * cellHeight,
            width: bounds.cols * cellWidth,
            height: bounds.rows * cellHeight
          };
          if (frame.left + frame.width > 0 && frame.top + frame.height > 0 && frame.left < width && frame.top < height) {
            renderChart(canvas, chart, frame);
          }
        });
        return new FileBlob(pngImage(width, height, canvas.rgba), MIME.png);
      }
      calculate() {
        const scan = inspectFormulaErrors(this, { summary: "calculate" });
        if (scan.errors.length) throw new Error(`Formula calculation failed with ${scan.errors.length} error(s)`);
        return scan;
      }
      inspect(options) {
        return inspectFormulaErrors(this, options || {});
      }
      help(query) {
        return { ndjson: JSON.stringify({ query, note: "Just Bash iOS artifact-tool compatibility surface" }) + "\n" };
      }
      trace(address) {
        const parts = String(address).split("!");
        const sheet = parts.length > 1 ? this.worksheets.getItem(parts[0].replace(/^'|'$/g, "")) : this.getActiveWorksheet();
        const cell = parseCell(parts.length > 1 ? parts[1] : parts[0]);
        const tree = traceCell(sheet || this.getActiveWorksheet(), cell.row, cell.col, new Set());
        return {
          ndjson: JSON.stringify(tree) + "\n",
          tree
        };
      }
    }

    export class ChartCollection {
      constructor(sheet) {
        this.sheet = sheet;
        this.items = [];
      }
      add(typeOrOptions, sourceRange) {
        const options = typeof typeOrOptions === "string"
          ? { type: typeOrOptions, sourceRange }
          : (typeOrOptions || {});
        const collection = this;
        const chart = {
          name: options.name || `Chart ${this.items.length + 1}`,
          type: options.type || options.chartType || "column",
          sourceRange: options.sourceRange || sourceRange || null,
          options,
          title: {},
          legend: {},
          axes: {},
          series: new LooseCollection((seriesOptions) => ({ options: seriesOptions || {} })),
          setPosition(anchor, endAnchor) {
            this.position = anchor;
            this.endPosition = endAnchor;
            return this;
          },
          delete() {
            collection.items = collection.items.filter((item) => item !== chart);
          }
        };
        this.items.push(chart);
        return chart;
      }
      getItem(indexOrName) {
        if (typeof indexOrName === "number") return this.items[indexOrName];
        return this.items.find((chart) => chart.name === indexOrName);
      }
      getItemOrNullObject(name) {
        return this.getItem(name) || { isNullObject: true, name, delete() {} };
      }
      deleteAll() {
        this.items = [];
      }
      get count() {
        return this.items.length;
      }
    }

    class WorksheetCollection extends LooseCollection {
      constructor(workbook) {
        super((name) => new Worksheet(workbook, typeof name === "string" ? name : "Sheet" + (workbook.worksheets.count + 1)));
        this.workbook = workbook;
      }
      getItem(nameOrIndex) {
        if (typeof nameOrIndex === "number") return this.items[nameOrIndex];
        return this.items.find((sheet) => sheet.name === nameOrIndex);
      }
      getOrAdd(name, options) {
        let sheet = this.getItem(name);
        if (!sheet && options && options.renameFirstIfOnlyNewSpreadsheet && this.items.length === 1) {
          sheet = this.items[0];
          sheet.name = name;
        }
        return sheet || this.add(name);
      }
      getItemAt(index) {
        return this.items[index];
      }
      getActiveWorksheet() {
        return this.workbook.getActiveWorksheet();
      }
    }

    export class Worksheet {
      constructor(workbook, name) {
        this.workbook = workbook;
        this.name = name;
        this.cells = {};
        this.charts = new ChartCollection(this);
        this.shapes = new LooseCollection((options) => ({ options: options || {}, text: "", position: (options || {}).position || {} }));
        this.images = new LooseCollection((options) => ({ options: options || {}, position: (options || {}).position || {} }));
        this.tables = new LooseCollection((rangeOrOptions, hasHeaders, name) => ({
          range: typeof rangeOrOptions === "string" ? rangeOrOptions : (rangeOrOptions || {}).range,
          hasHeaders: Boolean(hasHeaders),
          name: name || (rangeOrOptions || {}).name || `Table ${this.tables.count + 1}`,
          options: typeof rangeOrOptions === "object" ? (rangeOrOptions || {}) : {}
        }));
        this.sparklineGroups = new LooseCollection((options) => ({ options: options || {} }));
        this.sparklines = this.sparklineGroups;
        this.dataTables = new LooseCollection((options) => ({ options: options || {} }));
        this.conditionalFormattings = new LooseCollection((options) => ({ options: options || {} }));
        this.dataValidations = new LooseCollection((options) => ({ options: options || {} }));
        this.showGridLines = true;
        this.mergedRanges = [];
        this.freezePanes = { freezeRows() {}, freezeColumns() {}, unfreeze() {} };
      }
      getRange(address) {
        return new Range(this, parseRange(address));
      }
      getRangeByIndexes(row, col, rows, cols) {
        return new Range(this, { row, col, rows, cols });
      }
      getCell(row, col) {
        return this.getRangeByIndexes(row, col, 1, 1);
      }
      getUsedRange() {
        const keys = Object.keys(this.cells);
        if (!keys.length) return this.getRangeByIndexes(0, 0, 1, 1);
        const points = keys.map((key) => key.split(",").map((n) => Number(n)));
        const rows = points.map((point) => point[0]);
        const cols = points.map((point) => point[1]);
        const minRow = Math.min(...rows);
        const minCol = Math.min(...cols);
        return this.getRangeByIndexes(minRow, minCol, Math.max(...rows) - minRow + 1, Math.max(...cols) - minCol + 1);
      }
      mergeCells(address) {
        this.mergedRanges.push(address);
      }
      unmergeCells(address) {
        this.mergedRanges = this.mergedRanges.filter((range) => range !== address);
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
        this.format = rangeFormat();
        this.dataValidation = {};
        this.conditionalFormats = new LooseCollection();
        this.sparklines = new LooseCollection((type, sourceRange, config) => ({
          type,
          sourceRange,
          targetRange: this,
          config: config || {}
        }));
      }
      get values() {
        const out = [];
        for (let r = 0; r < this.bounds.rows; r += 1) {
          const row = [];
          for (let c = 0; c < this.bounds.cols; c += 1) {
            try {
              row.push(cellFormulaValue(this.sheet, this.bounds.row + r, this.bounds.col + c, new Set()));
            } catch (error) {
              row.push("#ERROR!");
            }
          }
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
          for (let c = 0; c < this.bounds.cols; c += 1) row.push((this.sheet.cells[`${this.bounds.row + r},${this.bounds.col + c}`] || {}).formula ?? null);
          out.push(row);
        }
        return out;
      }
      set formulas(matrix) {
        (matrix || []).forEach((row, r) => (row || []).forEach((formula, c) => {
          this.sheet.cells[`${this.bounds.row + r},${this.bounds.col + c}`] = { ...(this.sheet.cells[`${this.bounds.row + r},${this.bounds.col + c}`] || {}), formula };
        }));
      }
      get formulasR1C1() {
        return this.formulas;
      }
      set formulasR1C1(matrix) {
        this.formulas = matrix;
      }
      get displayFormulas() {
        return this.formulas;
      }
      get displayValues() {
        return this.values;
      }
      get formulaInfos() {
        return this.formulas.map((row, r) => row.map((formula, c) => {
          if (!formula) return null;
          try {
            return { formula, value: cellFormulaValue(this.sheet, this.bounds.row + r, this.bounds.col + c, new Set()) };
          } catch (error) {
            return { formula, error: error.message };
          }
        }));
      }
      write(payload) {
        if (Array.isArray(payload)) {
          this.values = payload;
        } else if (payload && Array.isArray(payload.values)) {
          this.values = payload.values;
        } else {
          this.values = [[payload]];
        }
        return this;
      }
      writeValues(matrix) {
        this.values = matrix;
        return this;
      }
      clear(options) {
        const applyTo = (options && options.applyTo) || "all";
        for (let r = 0; r < this.bounds.rows; r += 1) {
          for (let c = 0; c < this.bounds.cols; c += 1) {
            const key = `${this.bounds.row + r},${this.bounds.col + c}`;
            if (applyTo === "formats") continue;
            delete this.sheet.cells[key];
          }
        }
        if (applyTo === "formats" || applyTo === "all") {
          this.format = rangeFormat();
        }
      }
      copyFrom(sourceRange, kind) {
        if (!sourceRange) return this;
        const mode = kind || "all";
        if (mode === "values" || mode === "all") this.values = sourceRange.values;
        if (mode === "formulas" || mode === "all") this.formulas = sourceRange.formulas;
        return this;
      }
      copyTo(destinationRange, kind) {
        destinationRange.copyFrom(this, kind);
        return destinationRange;
      }
      offset(rows, cols) {
        return new Range(this.sheet, {
          row: this.bounds.row + (rows || 0),
          col: this.bounds.col + (cols || 0),
          rows: this.bounds.rows,
          cols: this.bounds.cols
        });
      }
      resize(rows, cols) {
        return new Range(this.sheet, {
          row: this.bounds.row,
          col: this.bounds.col,
          rows: rows || this.bounds.rows,
          cols: cols || this.bounds.cols
        });
      }
      getCurrentRegion() {
        return this.sheet.getUsedRange();
      }
      getRow(index) {
        return new Range(this.sheet, {
          row: this.bounds.row + index,
          col: this.bounds.col,
          rows: 1,
          cols: this.bounds.cols
        });
      }
      getColumn(index) {
        return new Range(this.sheet, {
          row: this.bounds.row,
          col: this.bounds.col + index,
          rows: this.bounds.rows,
          cols: 1
        });
      }
      getRangeByIndexes(row, col, rows, cols) {
        return new Range(this.sheet, {
          row: this.bounds.row + row,
          col: this.bounds.col + col,
          rows,
          cols
        });
      }
      getCell(row, col) {
        return this.getRangeByIndexes(row, col, 1, 1);
      }
      merge() {
        this.sheet.mergedRanges.push(this.bounds);
      }
      unmerge() {}
      setNumberFormat(value) {
        this.format.numberFormat = value;
      }
      autofit() {}
      fillDown() {}
      fillRight() {}
    }

    function xlsxRangeRef(sheet, bounds) {
      const sheetName = "'" + String(sheet.name).replace(/'/g, "''") + "'";
      const start = `$${colName(bounds.col)}$${bounds.row + 1}`;
      const end = `$${colName(bounds.col + bounds.cols - 1)}$${bounds.row + bounds.rows}`;
      return `${sheetName}!${start}:${end}`;
    }

    function xlsxCellRef(sheet, row, col) {
      const sheetName = "'" + String(sheet.name).replace(/'/g, "''") + "'";
      return `${sheetName}!$${colName(col)}$${row + 1}`;
    }

    function chartSeriesXml(chart) {
      const range = chart.sourceRange || chart.options.sourceRange;
      if (!range || range.bounds.rows < 2 || range.bounds.cols < 2) return "";
      const sheet = range.sheet;
      const categoryRef = xlsxRangeRef(sheet, {
        row: range.bounds.row + 1,
        col: range.bounds.col,
        rows: range.bounds.rows - 1,
        cols: 1
      });
      const series = [];
      for (let colOffset = 1; colOffset < range.bounds.cols; colOffset += 1) {
        const index = colOffset - 1;
        const valueRef = xlsxRangeRef(sheet, {
          row: range.bounds.row + 1,
          col: range.bounds.col + colOffset,
          rows: range.bounds.rows - 1,
          cols: 1
        });
        const titleRef = xlsxCellRef(sheet, range.bounds.row, range.bounds.col + colOffset);
        series.push(`<c:ser><c:idx val="${index}"/><c:order val="${index}"/><c:tx><c:strRef><c:f>${xml(titleRef)}</c:f></c:strRef></c:tx><c:cat><c:strRef><c:f>${xml(categoryRef)}</c:f></c:strRef></c:cat><c:val><c:numRef><c:f>${xml(valueRef)}</c:f></c:numRef></c:val></c:ser>`);
      }
      return series.join("");
    }

    function chartXml(chart, index) {
      const kind = String(chart.type || "column").toLowerCase();
      const title = typeof chart.title === "string" ? chart.title : chart.name || `Chart ${index}`;
      const series = chartSeriesXml(chart);
      const chartBody = (kind.includes("bar") || kind.includes("column"))
        ? `<c:barChart><c:barDir val="${kind.includes("bar") ? "bar" : "col"}"/><c:grouping val="clustered"/>${series}<c:axId val="10"/><c:axId val="20"/></c:barChart>`
        : `<c:lineChart><c:grouping val="standard"/>${series}<c:axId val="10"/><c:axId val="20"/></c:lineChart>`;
      return `<?xml version="1.0" encoding="UTF-8" standalone="yes"?><c:chartSpace xmlns:c="http://schemas.openxmlformats.org/drawingml/2006/chart" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><c:chart><c:title><c:tx><c:rich><a:bodyPr/><a:lstStyle/><a:p><a:r><a:t>${xml(title)}</a:t></a:r></a:p></c:rich></c:tx></c:title><c:plotArea><c:layout/>${chartBody}<c:catAx><c:axId val="10"/><c:scaling><c:orientation val="minMax"/></c:scaling><c:axPos val="b"/><c:tickLblPos val="nextTo"/><c:crossAx val="20"/><c:crosses val="autoZero"/></c:catAx><c:valAx><c:axId val="20"/><c:scaling><c:orientation val="minMax"/></c:scaling><c:axPos val="l"/><c:majorGridlines/><c:numFmt formatCode="General" sourceLinked="1"/><c:tickLblPos val="nextTo"/><c:crossAx val="10"/><c:crosses val="autoZero"/></c:valAx></c:plotArea><c:legend><c:legendPos val="r"/><c:layout/></c:legend><c:plotVisOnly val="1"/></c:chart></c:chartSpace>`;
    }

    function drawingXml(charts) {
      const anchors = charts.map(({ chart, chartIndex }, index) => {
        const bounds = chartBounds(chart);
        return `<xdr:twoCellAnchor><xdr:from><xdr:col>${bounds.col}</xdr:col><xdr:colOff>0</xdr:colOff><xdr:row>${bounds.row}</xdr:row><xdr:rowOff>0</xdr:rowOff></xdr:from><xdr:to><xdr:col>${bounds.col + bounds.cols}</xdr:col><xdr:colOff>0</xdr:colOff><xdr:row>${bounds.row + bounds.rows}</xdr:row><xdr:rowOff>0</xdr:rowOff></xdr:to><xdr:graphicFrame macro=""><xdr:nvGraphicFramePr><xdr:cNvPr id="${index + 2}" name="${xml(chart.name || `Chart ${chartIndex}`)}"/><xdr:cNvGraphicFramePr/></xdr:nvGraphicFramePr><xdr:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/></xdr:xfrm><a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/chart"><c:chart xmlns:c="http://schemas.openxmlformats.org/drawingml/2006/chart" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" r:id="rId${index + 1}"/></a:graphicData></a:graphic></xdr:graphicFrame><xdr:clientData/></xdr:twoCellAnchor>`;
      }).join("");
      return `<?xml version="1.0" encoding="UTF-8" standalone="yes"?><xdr:wsDr xmlns:xdr="http://schemas.openxmlformats.org/drawingml/2006/spreadsheetDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">${anchors}</xdr:wsDr>`;
    }

    function drawingRelsXml(charts) {
      return `<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">${charts.map(({ chartIndex }, index) => `<Relationship Id="rId${index + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/chart" Target="../charts/chart${chartIndex}.xml"/>`).join("")}</Relationships>`;
    }

    function sheetRelsXml(drawingIndex) {
      return `<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/drawing" Target="../drawings/drawing${drawingIndex}.xml"/></Relationships>`;
    }

    function sheetXml(sheet, drawingIndex) {
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
      const drawing = drawingIndex ? `<drawing r:id="rId1"/>` : "";
      return `<?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheetData>${body}</sheetData>${drawing}</worksheet>`;
    }

    export class SpreadsheetFile {
      static async importXlsx(blob) {
        const files = await unzipOfficeZip(blob instanceof FileBlob ? blob.data : blob);
        const workbookXml = zipText(files, "xl/workbook.xml");
        if (!workbookXml) throw new Error("SpreadsheetFile.importXlsx could not find xl/workbook.xml");
        const workbook = Workbook.create();
        workbook.worksheets.deleteAll();
        const sharedStrings = parseSharedStrings(zipText(files, "xl/sharedStrings.xml"));
        const sheets = parseWorkbookSheets(workbookXml, zipText(files, "xl/_rels/workbook.xml.rels"));
        sheets.forEach((entry) => {
          const sheet = workbook.worksheets.add(entry.name);
          parseWorksheetCells(sheet, zipText(files, entry.target), sharedStrings);
        });
        return workbook;
      }
      static async exportXlsx(workbook) {
        const sheets = workbook.worksheets.items.length ? workbook.worksheets.items : [workbook.worksheets.add("Sheet1")];
        const chartSheets = [];
        let chartIndex = 1;
        sheets.forEach((sheet, sheetIndex) => {
          const charts = sheet.charts.items.map((chart) => ({ sheet, sheetIndex, chart, chartIndex: chartIndex++ }));
          if (charts.length) chartSheets.push({ sheet, sheetIndex, drawingIndex: chartSheets.length + 1, charts });
        });
        const contentChartOverrides = chartSheets.flatMap((entry) => [
          `<Override PartName="/xl/drawings/drawing${entry.drawingIndex}.xml" ContentType="application/vnd.openxmlformats-officedocument.drawing+xml"/>`,
          ...entry.charts.map(({ chartIndex }) => `<Override PartName="/xl/charts/chart${chartIndex}.xml" ContentType="application/vnd.openxmlformats-officedocument.drawingml.chart+xml"/>`)
        ]).join("");
        const files = {
          "[Content_Types].xml": `<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>${sheets.map((_, i) => `<Override PartName="/xl/worksheets/sheet${i + 1}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>`).join("")}${contentChartOverrides}</Types>`,
          "_rels/.rels": `<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>`,
          "xl/workbook.xml": `<?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>${sheets.map((sheet, i) => `<sheet name="${xml(sheet.name)}" sheetId="${i + 1}" r:id="rId${i + 1}"/>`).join("")}</sheets></workbook>`,
          "xl/_rels/workbook.xml.rels": `<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">${sheets.map((_, i) => `<Relationship Id="rId${i + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet${i + 1}.xml"/>`).join("")}</Relationships>`
        };
        sheets.forEach((sheet, i) => {
          const chartSheet = chartSheets.find((entry) => entry.sheet === sheet);
          files[`xl/worksheets/sheet${i + 1}.xml`] = sheetXml(sheet, chartSheet && chartSheet.drawingIndex);
        });
        chartSheets.forEach((entry) => {
          files[`xl/worksheets/_rels/sheet${entry.sheetIndex + 1}.xml.rels`] = sheetRelsXml(entry.drawingIndex);
          files[`xl/drawings/drawing${entry.drawingIndex}.xml`] = drawingXml(entry.charts);
          files[`xl/drawings/_rels/drawing${entry.drawingIndex}.xml.rels`] = drawingRelsXml(entry.charts);
          entry.charts.forEach(({ chart, chartIndex }) => {
            files[`xl/charts/chart${chartIndex}.xml`] = chartXml(chart, chartIndex);
          });
        });
        return new FileBlob(zip(files), MIME.xlsx);
      }
    }

    class IOSCompatModel {
      constructor(config = {}) {
        Object.assign(this, config || {});
        if (!this.id) this.id = `${this.constructor.name}-${Math.random().toString(36).slice(2, 10)}`;
      }
      static create(config) {
        return new this(config || {});
      }
      toConfig() {
        return { ...this };
      }
      toJSON() {
        return this.toConfig();
      }
      toProto() {
        return this.toConfig();
      }
    }

    export class AutoLayout extends IOSCompatModel {}
    export class BorderLineModel extends IOSCompatModel {}
    export class BorderModel extends IOSCompatModel {}
    export class BoundingBox extends IOSCompatModel {}
    export class Cell extends IOSCompatModel {}
    export class CellStore extends IOSCompatModel {}
    export class Chart extends IOSCompatModel {}
    export class ChartAreaOptions extends IOSCompatModel {}
    export class ChartAxis extends IOSCompatModel {}
    export class ChartAxisTitle extends IOSCompatModel {}
    export class ChartBarOptions extends IOSCompatModel {}
    export class ChartBoxWhiskerOptions extends IOSCompatModel {}
    export class ChartDataLabels extends IOSCompatModel {}
    export class ChartDataTable extends IOSCompatModel {}
    export class ChartDoughnutOptions extends IOSCompatModel {}
    export class ChartElement extends IOSCompatModel {}
    export class ChartElementCollection extends LooseCollection {}
    export class ChartErrorBars extends IOSCompatModel {}
    export class ChartFunnelOptions extends IOSCompatModel {}
    export class ChartLegend extends IOSCompatModel {}
    export class ChartLineOptions extends IOSCompatModel {}
    export class ChartMapOptions extends IOSCompatModel {}
    export class ChartPieOptions extends IOSCompatModel {}
    export class ChartScatterOptions extends IOSCompatModel {}
    export class ChartSeries extends IOSCompatModel {}
    export class ChartSeriesCollection extends LooseCollection {}
    export class ChartSeriesDataLabelOverride extends IOSCompatModel {}
    export class ChartSeriesDataLabelOverrideCollection extends LooseCollection {}
    export class ChartSeriesMarker extends IOSCompatModel {}
    export class ChartSeriesPoint extends IOSCompatModel {}
    export class ChartSeriesPointCollection extends LooseCollection {}
    export class ChartStyleOptions extends IOSCompatModel {}
    export class ChartTreemapOptions extends IOSCompatModel {}
    export class ChartTrendline extends IOSCompatModel {}
    export class ChartTrendlineCollection extends LooseCollection {}
    export class ChartTrendlineLabel extends IOSCompatModel {}
    export class ChartView3d extends IOSCompatModel {}
    export class Citation extends IOSCompatModel {}
    export class CitationsCollection extends LooseCollection {}
    export class Color extends IOSCompatModel {}
    export class Comment extends IOSCompatModel {}
    export class Comments extends CommentCollection {}
    export class ConditionalFormat extends IOSCompatModel {}
    export class DefinedNames extends IOSCompatModel {}
    export class Element extends IOSCompatModel {}
    export class ElementsCollection extends LooseCollection {}
    export class Fill extends IOSCompatModel {}
    export class FontMetricsProvider extends IOSCompatModel {}
    export class GoogleSheetsAdapter extends IOSCompatModel {}
    export class GoogleSlidesAdapter extends IOSCompatModel {}
    export class FetchGoogleSheetsClient extends IOSCompatModel {}
    export class FetchGoogleSlidesClient extends IOSCompatModel {}
    export class GapiGoogleSheetsClient extends IOSCompatModel {}
    export class GapiGoogleSlidesClient extends IOSCompatModel {}
    export class GeometryHitTester extends IOSCompatModel {}
    export class HiddenTextareaBridge extends IOSCompatModel {}
    export class ImageCollection extends LooseCollection {}
    export class ImageElement extends Image {}
    export class ImageElementCollection extends LooseCollection {}
    export class InMemoryEngineEventBus extends IOSCompatModel {}
    export class InputController extends IOSCompatModel {}
    export class LabelFilterCondition extends IOSCompatModel {}
    export class Layout extends IOSCompatModel {}
    export class LayoutCollection extends LooseCollection {}
    export class Line extends IOSCompatModel {}
    export class Note extends IOSCompatModel {}
    export class NotesCollection extends LooseCollection {}
    export class NullTable extends IOSCompatModel {}
    export class NullWorksheet extends IOSCompatModel {}
    export class Paragraph extends IOSCompatModel {}
    export class ParagraphCollection extends LooseCollection {}
    export class Pattern extends IOSCompatModel {}
    export class PeopleCollection extends LooseCollection {}
    export class Person extends IOSCompatModel {}
    export class PivotCacheDefinition extends IOSCompatModel {}
    export class PivotCacheIndex extends IOSCompatModel {}
    export class PivotDataHierarchy extends IOSCompatModel {}
    export class PivotDataHierarchyCollection extends LooseCollection {}
    export class PivotField extends IOSCompatModel {}
    export class PivotFieldCollection extends LooseCollection {}
    export class PivotHierarchy extends IOSCompatModel {}
    export class PivotHierarchyCollection extends LooseCollection {}
    export class PivotItem extends IOSCompatModel {}
    export class PivotItemCollection extends LooseCollection {}
    export class PivotLayout extends IOSCompatModel {}
    export class PivotSourceTable extends IOSCompatModel {}
    export class PivotTable extends IOSCompatModel {}
    export class PivotTableCollection extends LooseCollection {}
    export class PlaceholderCollection extends LooseCollection {}
    export class Position extends IOSCompatModel {}
    export class PresentationAwarenessState extends IOSCompatModel {}
    export class PresentationCell extends IOSCompatModel {}
    export class PresentationTable extends IOSCompatModel {}
    export class PresentationTheme extends IOSCompatModel {}
    export class RangeConditionalFormats extends LooseCollection {}
    export class RangeDataValidation extends IOSCompatModel {}
    export class RangeFormat extends IOSCompatModel {}
    export class Row extends IOSCompatModel {}
    export class Scripts extends IOSCompatModel {}
    export class SelectionTool extends IOSCompatModel {}
    export class ShapeCollection extends LooseCollection {}
    export class ShapeGeometry extends IOSCompatModel {}
    export class ShapePlaceholder extends IOSCompatModel {}
    export class ShapePositionUnit extends IOSCompatModel {}
    export class Slicer extends IOSCompatModel {}
    export class SlicerCollection extends LooseCollection {}
    export class SlideBackground extends IOSCompatModel {}
    export class SlideCollectionFacade extends LooseCollection {}
    export class SlideComposeThemeFacade extends IOSCompatModel {}
    export class SparklineAxis extends IOSCompatModel {}
    export class SparklineGroup extends IOSCompatModel {}
    export class SparklineGroupCollection extends LooseCollection {}
    export class SparklineMarkers extends IOSCompatModel {}
    export class SparklinePreview extends IOSCompatModel {}
    export class SpeakerNotes extends IOSCompatModel {}
    export class SpillManager extends IOSCompatModel {}
    export class SpreadsheetKeyboardEventBus extends IOSCompatModel {}
    export class Style extends IOSCompatModel {}
    export class StyleRegistry extends IOSCompatModel {}
    export class StylesCollection extends LooseCollection {}
    export class Table extends IOSCompatModel {}
    export class TableBorders extends IOSCompatModel {}
    export class TableCellRange extends IOSCompatModel {}
    export class TableCollection extends LooseCollection {}
    export class TableColumn extends IOSCompatModel {}
    export class TableColumns extends LooseCollection {}
    export class TableRowCollection extends LooseCollection {}
    export class Tables extends LooseCollection {}
    export class Text extends TextFrame {}
    export class TextAutoFit extends IOSCompatModel {}
    export class TextDirection extends IOSCompatModel {}
    export class TextEditController extends IOSCompatModel {}
    export class TextLayoutIndex extends IOSCompatModel {}
    export class TextOverlayPainter extends IOSCompatModel {}
    export class TextRange extends IOSCompatModel {}
    export class TextRun extends IOSCompatModel {}
    export class TextRunCollection extends LooseCollection {}
    export class TextSelectionModel extends IOSCompatModel {}
    export class TextStyle extends IOSCompatModel {}
    export class TextStyleModel extends IOSCompatModel {}
    export class TextWrap extends IOSCompatModel {}
    export class Theme extends IOSCompatModel {}
    export class Thread extends IOSCompatModel {}
    export class ThreadsCollection extends LooseCollection {}
    export class ValueFilterCondition extends IOSCompatModel {}
    export class WorkbookAwarenessState extends IOSCompatModel {}
    export class WorkbookRecorder extends IOSCompatModel {}
    export class WorksheetCells extends IOSCompatModel {}
    export class WorksheetChart extends IOSCompatModel {}
    export class WorksheetChartCollection extends LooseCollection {}
    export class WorksheetChartOfficeCompat extends IOSCompatModel {}
    export class WorksheetCollectionFacade extends LooseCollection {}
    export class WorksheetConditionalFormattingCollection extends LooseCollection {}
    export class WorksheetDataTableCollection extends LooseCollection {}
    export class WorksheetDataValidationCollection extends LooseCollection {}
    export class WorksheetDrawingCollection extends LooseCollection {}
    export class WorksheetFreezePanes extends IOSCompatModel {}
    export class WorksheetImage extends Image {}
    export class WorksheetImageCollection extends LooseCollection {}
    export class WorksheetShape extends Shape {}
    export class WorksheetShapeCollection extends LooseCollection {}

    export const AggregationFunction = {};
    export const AnnotationTarget = {};
    export const AutoLayoutAlign = { start: "start", center: "center", end: "end" };
    export const AutoLayoutDirection = { horizontal: "horizontal", vertical: "vertical" };
    export const DataConsolidateFunction = {};
    export const DateFilterCondition = {};
    export const FilterDatetimeSpecificity = {};
    export const HorizontalAlignment = { left: "left", center: "center", right: "right" };
    export const LayoutType = {};
    export const ShowAs = {};
    export const ShowAsCalculation = {};

    export function executeTool() {
      unsupportedArtifactToolFeature("executeTool");
    }
    export function executeToolCall() {
      unsupportedArtifactToolFeature("executeToolCall");
    }
    export function setupSpreadsheetAgent(workbook = Workbook.create()) {
      return { workbook, tools: granolaSpreadsheetAgentTools_17 };
    }
    export const granolaSpreadsheetAgentTools_3 = [];
    export const granolaSpreadsheetAgentTools_17 = [];
    """#

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
                #"js-exec -m -c 'import { Workbook, SpreadsheetFile, Presentation, PresentationFile } from "@oai/artifact-tool"; const wb = Workbook.create(); const ws = wb.worksheets.add("Smoke"); ws.getRange("A1:B2").values = [["runtime", "ios"], [2, 3]]; ws.getRange("E1:E3").formulas = [["=SUM(A2:B2)"], ["=AVERAGE(A2:B2)"], ["=E1*2"]]; if (ws.getRange("E1:E3").values[0][0] !== 5 || ws.getRange("E1:E3").values[2][0] !== 10) throw new Error("formula compatibility failed"); if ((await wb.inspect({ kind: "formula" })).errors.length) throw new Error("formula error scan failed"); if (!JSON.parse(wb.trace("Smoke!E3").ndjson).dependencies.length) throw new Error("trace dependencies unavailable"); await wb.fromCSV("name,value\nalpha,1", { sheetName: "ImportedData" }); const imported = wb.worksheets.getOrAdd("ImportedData"); const copied = imported.getRange("A1:B2").copyTo(ws.getRange("C1:D2"), "values"); ws.getCell(4, 0).writeValues([["trace"]]); ws.getRange("A1:D4").getRow(0).format.autofitColumns(); ws.getRange("A1:D4").getColumn(0).setNumberFormat("@"); ws.mergeCells("A6:B6"); ws.unmergeCells("A6:B6"); const chart = ws.charts.add("line", ws.getRange("A1:B2")); chart.setPosition("G1", "M12"); chart.title = "Runtime Chart"; if (chart.type !== "line" || ws.charts.count !== 1) throw new Error("chart compatibility failed"); const table = ws.tables.add("A1:B2", true, "SmokeTable"); if (table.name !== "SmokeTable") throw new Error("table compatibility failed"); const spark = ws.getRange("E1:E2").sparklines.add("line", ws.getRange("B1:B2"), { color: "rgb(37,99,235)" }); if (spark.type !== "line") throw new Error("sparkline compatibility failed"); wb.comments.setSelf({ displayName: "ChatGPT" }); const thread = wb.comments.addThread({ cell: ws.getRange("A1") }, "Source: iOS smoke"); if (thread.comments[0].text !== "Source: iOS smoke") throw new Error("comment compatibility failed"); if (!copied.values[0][0]) throw new Error("copyTo failed"); const preview = await wb.render({ sheetName: "Smoke", range: "A1:M12", scale: 1 }); if (preview.mime !== "image/png" || (await preview.arrayBuffer()).length < 100) throw new Error("workbook render compatibility failed"); await preview.save("/tmp/primary-runtime-smoke.png"); const xlsx = await SpreadsheetFile.exportXlsx(wb); const xlsxText = Buffer.from(await xlsx.arrayBuffer()).toString("latin1"); if (!xlsxText.includes("xl/charts/chart1.xml") || !xlsxText.includes("xl/drawings/drawing1.xml")) throw new Error("xlsx chart export compatibility failed"); const roundTrip = await SpreadsheetFile.importXlsx(xlsx); if (roundTrip.worksheets.getItem("Smoke").getRange("A1").values[0][0] !== "runtime") throw new Error("xlsx import compatibility failed"); await xlsx.save("/tmp/primary-runtime-smoke.xlsx"); const deck = Presentation.create({ slideSize: { width: 1280, height: 720 } }); const slide = deck.slides.add(); const shape = slide.shapes.add({ name: "title", position: { left: 40, top: 40, width: 400, height: 80 }, fill: "rgb(239,246,255)", line: { fill: "rgb(37,99,235)", width: 2 } }); shape.text = "iOS artifact-tool smoke"; shape.text.fontSize = 24; shape.text.color = "rgb(17,24,39)"; if (shape.text.fontSize !== 24) throw new Error("text frame not mutable"); const slidePreview = await deck.export({ slide, format: "png", scale: 0.5 }); if (slidePreview.mime !== "image/png" || (await slidePreview.arrayBuffer()).length < 100) throw new Error("presentation render compatibility failed"); await slidePreview.save("/tmp/primary-runtime-slide.png"); const layout = JSON.parse(await (await deck.export({ slide, format: "layout" })).text()); if (!layout.elements || layout.elements[0].name !== "title") throw new Error("presentation layout compatibility failed"); const pptx = await PresentationFile.exportPptx(deck); await pptx.save("/tmp/primary-runtime-smoke.pptx"); console.log("available");'"#
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

            return ExecResult(stdout: report, stderr: pythonResult.stderr, exitCode: report.contains(#""overall": "ready""#) ? 0 : 1)
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
        let documentsStatus = pythonSkillStatus(
            from: pythonResult,
            skill: "documents",
            fallback: "blocked"
        )
        let commonArtifactStatus = (
            artifactToolStatus == "available"
            && nodeModuleStatus == "available"
            && esmStatus == "available"
            && childProcessPythonStatus == "available"
            && packageExportsStatus == "available"
            && unsupportedFullApiStatus == "guarded"
        ) ? "ready" : "blocked"
        let presentationsStatus = commonArtifactStatus
        let spreadsheetsStatus = commonArtifactStatus
        let overallStatus = (
            pythonStatus == "available"
            && documentsStatus == "ready"
            && presentationsStatus == "ready"
            && spreadsheetsStatus == "ready"
        ) ? "ready" : "blocked"
        let documentBlockers = pythonSkillBlockers(
            from: pythonResult,
            skill: "documents",
            fallback: [
                "requires soffice/LibreOffice render QA",
                "uses subprocess-based document rendering",
                "missing required Python modules: docx, lxml",
                "Documents helpers require real lxml/python-docx OOXML behavior; a shallow import shim is not sufficient",
            ]
        )
        let spreadsheetBlockers = pythonSkillBlockers(
            from: pythonResult,
            skill: "spreadsheets",
            fallback: [
                "broad pure-JS @oai/artifact-tool workbook export plus common structural spreadsheet API compatibility, including table/chart/comment/sparkline stubs, is staged",
                "stored and sandbox-extracted compressed .xlsx import/export plus basic workbook PNG rendering are staged; full artifact-tool inspection/render behavior is not ported to iOS",
                "bounded iOS formula computation, formula-error scans, and workbook.trace dependency trees are staged for common arithmetic/range formulas",
                "full Excel calculation semantics still require the native artifact-tool runtime or a broader iOS formula engine",
                "bounded native XLSX chart parts and basic chart PNG previews are staged for common source-range charts",
                "full Excel chart semantics still require the native artifact-tool runtime or a broader iOS chart engine",
                "missing optional spreadsheet Python modules: pandas, docx",
            ]
        )
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
              "blockers": \(documentBlockersJSON)
            },
            "presentations": {
              "status": "\(presentationsStatus)",
              "blockers": [
                "broad pure-JS @oai/artifact-tool/presentation-jsx compatibility is staged",
                "basic PresentationFile.importPptx and DocumentFile.importDocx facades are staged for common OOXML text extraction paths",
                "basic presentation PNG rendering and layout JSON are staged; full-fidelity rendering still needs a real iOS renderer",
                "full-fidelity rendering still depends on native/npm artifact-tool paths not ported to iOS",
                "JavaScript helper scripts can invoke host-provided python3 through child_process",
                "same-interpreter Python subprocess fan-out is adapted in-process for app-visible helper scripts",
                "ctx.addLucideIcon can use the staged pure-JS lucide SVG package",
                "standalone Lucide PNG icon rendering can use the staged pure-JS sharp SVG-to-PNG compatibility package",
                "native sharp/skia-canvas rendering remains unavailable on iOS"
              ]
            },
            "spreadsheets": {
              "status": "\(spreadsheetsStatus)",
              "blockers": \(spreadsheetBlockersJSON)
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
