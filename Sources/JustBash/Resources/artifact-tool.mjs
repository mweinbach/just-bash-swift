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
  return String(value??'').replace(/&(#x[0-9a-f]+|#[0-9]+|quot|apos|lt|gt|amp);/gi,(_,entity)=>{
    if(entity.startsWith('#x'))return String.fromCodePoint(parseInt(entity.slice(2),16));
    if(entity.startsWith('#'))return String.fromCodePoint(Number(entity.slice(1)));
    return {quot:'"',apos:"'",lt:'<',gt:'>',amp:'&'}[entity.toLowerCase()];
  });
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
  const values = flattenFormulaArgs(args).filter((value) => typeof value === "number");
  if (!values.length) throw new FormulaError("#DIV/0!");
  return values.reduce((sum, value) => sum + value, 0) / values.length;
}

export function MIN(...args) {
  return Math.min(...flattenFormulaArgs(args).map(asNumber));
}

export function MAX(...args) {
  return Math.max(...flattenFormulaArgs(args).map(asNumber));
}

export function COUNT(...args) {
  return flattenFormulaArgs(args).filter((value) => value !== null && value !== "" && typeof value === "number" && Number.isFinite(value)).length;
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
export function TODAY() { const now = new Date(); return Date.UTC(now.getFullYear(), now.getMonth(), now.getDate()) / 86400000 + 25569; }
export function NOW() { return Date.now() / 86400000 + 25569; }
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

class FormulaError extends Error {
  constructor(code, detail = code) { super(detail); this.code = code; }
}
function formulaNumber(value) {
  if (typeof value === 'string' && value.startsWith('#')) throw new FormulaError(value);
  if (value == null || value === '') return 0;
  const n = Number(value);
  if (!Number.isFinite(n)) throw new FormulaError('#VALUE!');
  return n;
}
function finiteFormula(value) {
  if (typeof value === 'number' && !Number.isFinite(value)) throw new FormulaError('#NUM!');
  return value;
}
// A small Excel expression parser. No JavaScript eval: comparisons and lazy IF /
// IFERROR retain spreadsheet semantics, including errors in the unselected arm.
function evaluateFormula(sheet, formula, row, col, seen) {
  const source = String(formula || '').replace(/^=/, '');
  const tokens = [];
  const tokenRE = /\s*(?:("(?:[^"]|"")*")|((?:'(?:[^']|'')+'|[A-Za-z_][\w.]*)!\$?[A-Za-z]+\$?\d+|\$?[A-Za-z]+\$?\d+)|((?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?)|(#[A-Z0-9/]+[!?]?)|([A-Za-z_][\w.]*)|(<=|>=|<>|[+\-*/^&%=<>()!,;:]))/gy;
  let cursor = 0;
  while (cursor < source.length) {
    if (!source.slice(cursor).trim()) break;
    tokenRE.lastIndex = cursor;
    const match = tokenRE.exec(source);
    if (!match) throw new FormulaError('#VALUE!', 'Unsupported formula syntax: '+source.slice(cursor));
    tokens.push(match[1] ? {kind:'string',value:match[1].slice(1,-1).replace(/""/g,'"')} : match[2] ? {kind:'ref',value:match[2]} : match[3] ? {kind:'number',value:Number(match[3])} : match[4] ? {kind:'error',value:match[4]} : match[5] ? {kind:'name',value:match[5].toUpperCase()} : {kind:match[6],value:match[6]});
    cursor = tokenRE.lastIndex;
    if (tokens.length > 10000) throw new FormulaError('#VALUE!', 'Formula exceeds token budget');
  }
  let at = 0;
  const peek = () => (tokens[at] || {}).kind;
  const take = kind => { const token=tokens[at++]; if(!token || (kind && token.kind!==kind)) throw new FormulaError('#VALUE!', 'Invalid formula'); return token; };
  const precedence = {'=':1,'<>':1,'<':1,'>':1,'<=':1,'>=':1,'&':2,'+':3,'-':3,'*':4,'/':4,'^':5};
  function parse(min = 0) {
    let node;
    if (peek()==='+' || peek()==='-') { const op=take().kind; node={kind:'unary',op,value:parse(5)}; }
    else if (peek()==='(') { take(); node=parse(); take(')'); }
    else {
      const token=take(); node=token;
      if(token.kind==='name' && peek()==='(') {
        take(); const args=[];
        if(peek()!==')') { do { args.push(parse()); if(peek()!==',' && peek()!==';') break; take(); } while(true); }
        take(')'); node={kind:'call',name:token.value,args};
      } else if(token.kind==='ref' && peek()===':') { take(); node={kind:'range',start:token.value,end:take('ref').value}; }
    }
    while(peek()==='%') { take(); node={kind:'percent',value:node}; }
    while(precedence[peek()] !== undefined && precedence[peek()] >= min) {
      const op=take().kind, priority=precedence[op];
      node={kind:'binary',op,left:node,right:parse(priority+(op==='^'?0:1))};
    }
    return node;
  }
  function reference(ref, fallbackSheet=sheet) {
    const split=ref.lastIndexOf('!');
    const name=split<0?'':ref.slice(0,split).replace(/^'|'$/g,'').replace(/''/g,"'");
    const target=name ? sheet.workbook.worksheets.getItem(name) : fallbackSheet;
    if(!target) throw new FormulaError('#REF!', 'Unknown worksheet '+name);
    return {sheet:target,...parseCell((split<0?ref:ref.slice(split+1)).replace(/\$/g,''))};
  }
  function run(node) {
    if(node.kind==='number'||node.kind==='string') return node.value;
    if(node.kind==='error') throw new FormulaError(node.value);
    if(node.kind==='name') { if(node.value==='TRUE') return true; if(node.value==='FALSE') return false; throw new FormulaError('#NAME?',node.value); }
    if(node.kind==='ref') { const ref=reference(node.value); return cellFormulaValue(ref.sheet,ref.row,ref.col,new Set(seen||[])); }
    if(node.kind==='range') {
      const start=reference(node.start),end=reference(node.end,start.sheet);
      if(start.sheet!==end.sheet) throw new FormulaError('#REF!');
      const bounds={row:Math.min(start.row,end.row),col:Math.min(start.col,end.col),rows:Math.abs(end.row-start.row)+1,cols:Math.abs(end.col-start.col)+1};
      if(bounds.rows*bounds.cols>100000) throw new FormulaError('#VALUE!','Range exceeds calculation budget');
      return rangeFormulaValues(start.sheet,bounds,new Set(seen||[]));
    }
    if(node.kind==='unary') return (node.op==='-'?-1:1)*formulaNumber(run(node.value));
    if(node.kind==='percent') return formulaNumber(run(node.value))/100;
    if(node.kind==='call') {
      if(node.name==='IF') { if(node.args.length<2||node.args.length>3) throw new FormulaError('#VALUE!'); return run(node.args[0])?run(node.args[1]):node.args[2]?run(node.args[2]):false; }
      if(node.name==='IFERROR') { if(node.args.length!==2) throw new FormulaError('#VALUE!'); try { return run(node.args[0]); } catch(error) { if(!(error instanceof FormulaError)) throw error; return run(node.args[1]); } }
      const fn=FORMULA_FUNCTIONS[node.name];
      if(!fn) throw new FormulaError('#NAME?','Unsupported function '+node.name);
      return finiteFormula(fn(...node.args.map(run)));
    }
    if(node.kind==='binary') {
      let left=run(node.left),right=run(node.right);
      if(node.op==='&') return String(left??'')+String(right??'');
      if(['=','<>','<','>','<=','>='].includes(node.op)) {
        if(typeof left==='string') left=left.toLowerCase(); if(typeof right==='string') right=right.toLowerCase();
        if(left==null) left=typeof right==='string'?'':0; if(right==null) right=typeof left==='string'?'':0;
        if(node.op==='=') return left===right;
        if(node.op==='<>') return left!==right;
        if(node.op==='<') return left<right; if(node.op==='>') return left>right;
        if(node.op==='<=') return left<=right; return left>=right;
      }
      left=formulaNumber(left); right=formulaNumber(right);
      if(node.op==='/') { if(right===0) throw new FormulaError('#DIV/0!'); return left/right; }
      if(node.op==='+') return left+right; if(node.op==='-') return left-right;
      if(node.op==='*') return finiteFormula(left*right); if(node.op==='^') return finiteFormula(left**right);
    }
    throw new FormulaError('#VALUE!','Unsupported formula expression');
  }
  const tree=parse(); if(at!==tokens.length) throw new FormulaError('#VALUE!','Unexpected formula token');
  return finiteFormula(run(tree));
}

function cellFormulaValue(sheet, row, col, seen) {
  const key = `${sheet.name}:${row},${col}`;
  const activeSeen = new Set(seen || []);
  if (activeSeen.has(key)) throw new FormulaError("#REF!", `Circular formula reference at ${formulaAddress(sheet, row, col)}`);
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

function cloneData(value) { return value == null ? value : JSON.parse(JSON.stringify(value)); }
function rangeRef(bounds) { return `${a1(bounds.row,bounds.col)}:${a1(bounds.row+bounds.rows-1,bounds.col+bounds.cols-1)}`; }
function eachRangeCell(sheet,bounds,fn) {
  if(bounds.rows*bounds.cols>100000) throw new Error('Range exceeds 100000-cell mutation budget');
  for(let r=0;r<bounds.rows;r++) for(let c=0;c<bounds.cols;c++) {
    const key=`${bounds.row+r},${bounds.col+c}`;
    sheet.cells[key] ||= {}; fn(sheet.cells[key],bounds.row+r,bounds.col+c);
  }
}
function unsupportedCollection(name) { return new LooseCollection(()=>unsupportedArtifactToolFeature(name)); }
function rangeFormat(sheet, bounds) {
  const groups={fill:['color'],font:['bold','italic','size','fontSize','name','color','underline'],alignment:['horizontal','vertical','wrapText'],borders:['top','bottom','left','right','all']};
  const scalars=['numberFormat','wrapText','columnWidth','rowHeight','columnWidthPx','rowHeightPx'];
  const first=()=>((sheet.cells[`${bounds.row},${bounds.col}`]||{}).format||{});
  function write(key,value,subkey) {
    eachRangeCell(sheet,bounds,(cell,row,col)=>{
      cell.format ||= {};
      if(subkey) { cell.format[key] ||= {}; cell.format[key][subkey]=cloneData(value); }
      else cell.format[key]=cloneData(value);
      if(key==='columnWidth'||key==='columnWidthPx') sheet.columnWidths[col]=key==='columnWidthPx'?Number(value)/7:Number(value);
      if(key==='rowHeight'||key==='rowHeightPx') sheet.rowHeights[row]=key==='rowHeightPx'?Number(value)*0.75:Number(value);
    });
  }
  const methods={
    autofitColumns(){ for(let c=bounds.col;c<bounds.col+bounds.cols;c++) { let width=8; for(let r=bounds.row;r<bounds.row+bounds.rows;r++) width=Math.max(width,String((sheet.cells[`${r},${c}`]||{}).value??'').length+2); sheet.columnWidths[c]=Math.min(width,80); } },
    autofitRows(){ for(let r=bounds.row;r<bounds.row+bounds.rows;r++) sheet.rowHeights[r]=Math.max(18,...Array.from({length:bounds.cols},(_,i)=>String((sheet.cells[`${r},${bounds.col+i}`]||{}).value??'').split('\n').length*16)); }
  };
  return new Proxy({}, {
    get(_,key) {
      if(key==='toJSON') return ()=>cloneData(first());
      if(methods[key]) return methods[key];
      if(groups[key]) return new Proxy({}, {get(_,sub){ if(sub==='toJSON')return()=>cloneData(first()[key]||{});return (first()[key]||{})[sub]; },set(_,sub,value){if(!groups[key].includes(sub))unsupportedArtifactToolFeature(`Range.format.${key}.${String(sub)}`);write(key,value,sub);return true;}});
      return first()[key];
    },
    set(_,key,value){ if(groups[key]) { for(const sub of Object.keys(value||{})) {if(!groups[key].includes(sub))unsupportedArtifactToolFeature(`Range.format.${key}.${sub}`);write(key,value[sub],sub);} }
      else {if(!scalars.includes(key))unsupportedArtifactToolFeature(`Range.format.${String(key)}`);write(key,value);} return true; }
  });
}
function rgbHex(value,fallback='000000') { const color=colorBytes(value,null); return color?color.slice(0,3).map(n=>n.toString(16).padStart(2,'0')).join('').toUpperCase():fallback; }
function xmlAttributes(text) { const out={}; String(text).replace(/([\w:]+)\s*=\s*"([^"]*)"/g,(_,key,value)=>{out[key]=xmlDecode(value);return '';});return out; }
function xmlElements(text,tag) { return String(text).match(new RegExp(`<${tag}\\b[^>]*(?:\\/>|>[\\s\\S]*?<\\/${tag}>)`,'g'))||[]; }
function xlsxStyles(workbook) {
  const formats=[{}],map=new Map([['{}',0]]);
  workbook.worksheets.items.forEach(sheet=>Object.values(sheet.cells).forEach(cell=>{
    const key=JSON.stringify(cell.format||{}); if(!map.has(key)){map.set(key,formats.length);formats.push(cell.format||{});} cell.styleIndex=map.get(key);
  }));
  const fonts=formats.map(f=>{const v=f.font||{};return `<font><sz val="${Number(v.size||v.fontSize||11)}"/><name val="${xml(v.name||'Aptos')}"/><color rgb="FF${rgbHex(v.color)}"/>${v.bold?'<b/>':''}${v.italic?'<i/>':''}${v.underline?'<u/>':''}</font>`;});
  const fills=['<fill><patternFill patternType="none"/></fill>','<fill><patternFill patternType="gray125"/></fill>',...formats.map(f=>f.fill&&f.fill.color?`<fill><patternFill patternType="solid"><fgColor rgb="FF${rgbHex(f.fill.color)}"/><bgColor indexed="64"/></patternFill></fill>`:'<fill><patternFill patternType="none"/></fill>')];
  const borders=formats.map(f=>'<border>'+['left','right','top','bottom'].map(edge=>{const v=(f.borders||{})[edge]||(f.borders||{}).all;return v?`<${edge} style="${xml(typeof v==='string'?v:v.style||'thin')}"><color rgb="FF${rgbHex(v.color)}"/></${edge}>`:`<${edge}/>`;}).join('')+'<diagonal/></border>');
  const nums=formats.map((f,i)=>f.numberFormat?`<numFmt numFmtId="${164+i}" formatCode="${xml(f.numberFormat)}"/>`:'').join('');
  const xfs=formats.map((f,i)=>{const a=f.alignment||{};return `<xf numFmtId="${f.numberFormat?164+i:0}" fontId="${i}" fillId="${i+2}" borderId="${i}" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyNumberFormat="1" applyAlignment="1"><alignment horizontal="${xml(a.horizontal||'general')}" vertical="${xml(a.vertical||'bottom')}" wrapText="${f.wrapText||a.wrapText?1:0}"/></xf>`;}).join('');
  return `<?xml version="1.0" encoding="UTF-8"?><styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><numFmts count="${formats.filter(f=>f.numberFormat).length}">${nums}</numFmts><fonts count="${fonts.length}">${fonts.join('')}</fonts><fills count="${fills.length}">${fills.join('')}</fills><borders count="${borders.length}">${borders.join('')}</borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="${formats.length}">${xfs}</cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>`;
}
function importXlsxStyles(text) {
  const section=name=>(String(text).match(new RegExp(`<${name}\\b[^>]*>([\\s\\S]*?)<\\/${name}>`))||[])[1]||'';
  const fonts=xmlElements(section('fonts'),'font'),fills=xmlElements(section('fills'),'fill'),borders=xmlElements(section('borders'),'border');
  const num={0:'General',1:'0',2:'0.00',3:'#,##0',4:'#,##0.00',9:'0%',10:'0.00%',14:'m/d/yy'};
  xmlElements(section('numFmts'),'numFmt').forEach(e=>{const a=xmlAttributes(e);num[a.numFmtId]=a.formatCode;});
  const attr=(e,tag)=>xmlAttributes((xmlElements(e,tag)||[])[0]||'');
  return xmlElements(section('cellXfs'),'xf').map(e=>{
    const a=xmlAttributes(e.split('>')[0]),f=fonts[Number(a.fontId)]||'',fill=fills[Number(a.fillId)]||'',border=borders[Number(a.borderId)]||'',al=attr(e,'alignment');
    const result={font:{size:Number(attr(f,'sz').val||11),name:attr(f,'name').val||'Aptos',bold:/<b(?:\s|\/|>)/.test(f),italic:/<i(?:\s|\/|>)/.test(f)},fill:{},borders:{},numberFormat:num[a.numFmtId]||'General',alignment:{horizontal:al.horizontal||'general',vertical:al.vertical||'bottom'},wrapText:al.wrapText==='1'};
    if(attr(f,'color').rgb) result.font.color='#'+attr(f,'color').rgb.slice(-6);
    if(attr(fill,'fgColor').rgb) result.fill.color='#'+attr(fill,'fgColor').rgb.slice(-6);
    for(const edge of ['left','right','top','bottom']) {const el=xmlElements(border,edge)[0]||'',at=xmlAttributes(el.split('>')[0]);if(at.style) result.borders[edge]={style:at.style,color:'#'+(attr(el,'color').rgb||'FF000000').slice(-6)};}
    return result;
  });
}

function unsupportedArtifactToolFeature(name) {
  throw new Error(`${name} is not implemented by the Just Bash iOS artifact-tool compatibility package`);
}

function docParagraphXml(text, options={}) {
  const allowed=['bold','italic','fontSize','color','style'];
  for(const key of Object.keys(options))if(!allowed.includes(key))unsupportedArtifactToolFeature('DOCX paragraph option '+key);
  const props=`${options.bold?'<w:b/>':''}${options.italic?'<w:i/>':''}${options.fontSize?`<w:sz w:val="${Number(options.fontSize)*2}"/>`:''}${options.color?`<w:color w:val="${rgbHex(options.color)}"/>`:''}`;
  return `<w:p>${options.style?`<w:pPr><w:pStyle w:val="${xml(options.style)}"/></w:pPr>`:''}<w:r>${props?`<w:rPr>${props}</w:rPr>`:''}${String(text).split('\n').map(line=>`<w:t xml:space="preserve">${xml(line)}</w:t>`).join('<w:br/>')}</w:r></w:p>`;
}
function parseWordParagraphs(documentXml) {
  return xmlElements(documentXml,'w:p').map(p=>xmlElements(p,'w:t').map(t=>xmlDecode(t.replace(/<[^>]+>/g,''))).join(''));
}
function replaceWordText(documentXml,search,replacement) {
  if(!search)throw new Error('replaceText requires nonempty literal search text');
  return String(documentXml).replace(/<w:p\b[\s\S]*?<\/w:p>/g,paragraph=>{
    const runs=xmlElements(paragraph,'w:t').map(t=>xmlDecode(t.replace(/<[^>]+>/g,''))),joined=runs.join('');
    const matches=[];let position=joined.indexOf(search);
    while(position>=0){matches.push(position);position=joined.indexOf(search,position+search.length);}
    if(!matches.length)return paragraph;
    const offsets=[];let total=0;runs.forEach(text=>{offsets.push(total);total+=text.length;});
    for(const match of matches.reverse()) {
      for(let i=0;i<runs.length;i++) {
        const start=offsets[i],end=start+(i+1<offsets.length?offsets[i+1]-start:joined.length-start);
        if(end<=match||start>=match+search.length)continue;
        const localStart=Math.max(0,match-start),localEnd=Math.min(end-start,match+search.length-start);
        runs[i]=runs[i].slice(0,localStart)+(match>=start?replacement:'')+runs[i].slice(localEnd);
      }
    }
    let i=0;return paragraph.replace(/<w:t\b([^>]*)>[\s\S]*?<\/w:t>/g,(_,attrs)=>`<w:t${attrs.includes('xml:space')?attrs:attrs+' xml:space="preserve"'}>${xml(runs[i++])}</w:t>`);
  });
}
export class DocumentModel {
  constructor(options={}) {
    this.metadata=options.metadata||{};this._blocks=[];this._sourceFiles=null;this._documentXml=null;
    (options.paragraphs||[]).forEach(text=>this.addParagraph(text));
  }
  static create(options) { return new DocumentModel(options||{}); }
  get paragraphs() { return Object.freeze(parseWordParagraphs(this._bodyXML())); }
  set paragraphs(value) { if(this._sourceFiles)unsupportedArtifactToolFeature('replacing all imported DOCX paragraphs; use replaceText');this._blocks=[];(value||[]).forEach(text=>this.addParagraph(text)); }
  get text() { return this.paragraphs.join('\n'); }
  set text(value) { this.paragraphs=String(value??'').split(/\r?\n/); }
  addParagraph(text='',options={}) {
    const block={kind:'paragraph',text:String(text),options:cloneData(options)};this._blocks.push(block);return block;
  }
  addTable(rows) {
    if(!Array.isArray(rows)||!rows.length||!rows.every(row=>Array.isArray(row)&&row.length===rows[0].length))throw new Error('DOCX tables require rectangular rows');
    const block={kind:'table',rows:rows.map(row=>row.map(String))};this._blocks.push(block);return block;
  }
  replaceText(search,replacement) {
    if(search instanceof RegExp)unsupportedArtifactToolFeature('DOCX regex replacement; use literal text');
    search=String(search);replacement=String(replacement);if(!search)throw new Error('replaceText requires nonempty search text');
    if(this._documentXml)this._documentXml=replaceWordText(this._documentXml,search,replacement);
    for(const block of this._blocks) {if(block.kind==='paragraph')block.text=block.text.split(search).join(replacement);else block.rows=block.rows.map(row=>row.map(text=>text.split(search).join(replacement)));}
    return this;
  }
  _bodyXML() {
    const added=this._blocks.map(block=>block.kind==='paragraph'?docParagraphXml(block.text,block.options):`<w:tbl><w:tblPr><w:tblW w:w="0" w:type="auto"/><w:tblBorders>${['top','left','bottom','right','insideH','insideV'].map(edge=>`<w:${edge} w:val="single" w:sz="4" w:color="B0B0B0"/>`).join('')}</w:tblBorders></w:tblPr><w:tblGrid>${block.rows[0].map(()=>'<w:gridCol w:w="2400"/>').join('')}</w:tblGrid>${block.rows.map(row=>`<w:tr>${row.map(text=>`<w:tc><w:tcPr><w:tcW w:w="2400" w:type="dxa"/></w:tcPr>${docParagraphXml(text)}</w:tc>`).join('')}</w:tr>`).join('')}</w:tbl>`).join('');
    if(!this._documentXml)return added;
    return this._documentXml.replace(/(<w:sectPr\b[^>]*(?:\/>|>[\s\S]*?<\/w:sectPr>)\s*)?<\/w:body>/,(_,section)=>(added+(section||'')+'</w:body>'));
  }
  inspect(options={}) { return {ndjson:[JSON.stringify({kind:'document',paragraphs:this.paragraphs.length,options}),...this.paragraphs.map((text,index)=>JSON.stringify({kind:'paragraph',index,text}))].join('\n')+'\n',paragraphs:this.paragraphs}; }
  render() { unsupportedArtifactToolFeature('DOCX pagination/rendering; export and preview with a native Office viewer'); }
  help(query) { return {ndjson:JSON.stringify({query,note:'Supports styled paragraphs, rectangular tables, literal replaceText and preservation of imported DOCX package parts. No pagination or renderer.'})+'\n'}; }
  toJSON() { return {paragraphs:this.paragraphs,metadata:this.metadata}; }
}
export class DocumentFile {
  static async importDocx(blob) {
    const files=await unzipOfficeZip(blob instanceof FileBlob?blob.data:blob),text=zipText(files,'word/document.xml');
    if(!text)throw new Error('DocumentFile.importDocx requires word/document.xml');
    const document=DocumentModel.create();document._sourceFiles=files;document._documentXml=text;return document;
  }
  static async exportDocx(document) {
    const model=document instanceof DocumentModel?document:new DocumentModel(document||{});
    const files=model._sourceFiles?{...model._sourceFiles}:{
      '[Content_Types].xml':'<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>',
      '_rels/.rels':officeRelationships([{id:'rId1',kind:'officeDocument',target:'word/document.xml'}])
    };
    if(!model._sourceFiles) {
      files['word/styles.xml']=`<?xml version="1.0"?><w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:rPr><w:rFonts w:ascii="Arial" w:hAnsi="Arial"/><w:sz w:val="22"/></w:rPr></w:style>${[1,2].map(level=>`<w:style w:type="paragraph" w:styleId="Heading${level}"><w:name w:val="heading ${level}"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:outlineLvl w:val="${level-1}"/></w:pPr><w:rPr><w:b/><w:sz w:val="${level===1?36:28}"/></w:rPr></w:style>`).join('')}</w:styles>`;
      files['word/_rels/document.xml.rels']=officeRelationships([{id:'rIdStyles',kind:'styles',target:'styles.xml'}]);
      files['[Content_Types].xml']=files['[Content_Types].xml'].replace('</Types>','<Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/></Types>');
    }
    const stylesXML=zipText(files,'word/styles.xml');
    for(const block of model._blocks) if(block.kind==='paragraph'&&block.options.style&&!stylesXML.includes('w:styleId="'+xml(block.options.style)+'"'))throw new Error('Unknown DOCX paragraph style '+block.options.style);
    files['word/document.xml']=model._sourceFiles?model._bodyXML():`<?xml version="1.0" encoding="UTF-8"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>${model._bodyXML()}<w:sectPr><w:pgSz w:w="12240" w:h="15840"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440"/></w:sectPr></w:body></w:document>`;
    return new FileBlob(zip(files),MIME.docx);
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
    unsupportedArtifactToolFeature("Presentation.record");
  }
  template(name) {
    unsupportedArtifactToolFeature("Presentation.template");
  }
  apply(template) {
    unsupportedArtifactToolFeature("Presentation.apply");
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
  setLayout(layout) { unsupportedArtifactToolFeature("Slide.setLayout"); }
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
  bringToFront() { unsupportedArtifactToolFeature("Shape.bringToFront; order the shapes collection"); }
  sendToBack() { unsupportedArtifactToolFeature("Shape.sendToBack; order the shapes collection"); }
  delete() {
    this.deleted = true;
  }
  clone() {
    const copy = new Shape({ ...this.options, id: undefined, name: this.name, position: { ...this.position }, fill: this.fill, line: this.line, geometry: this.geometry });
    copy.text = new TextFrame(this.text.plain);
    Object.assign(copy.text, cloneData(this.text));
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
    unsupportedArtifactToolFeature("Image.regenerate");
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

async function renderPresentationPng(presentation, options) {
  if (typeof globalThis.__jb_render_artifact === 'function') {
    const slide=exportedSlide(presentation,options.slide),scale=Math.max(0.1,Math.min(2,Number(options.scale||1))),elements=[];
    const scaleFrame=position=>{const f=frameOf(position,{});return {left:f.left*scale,top:f.top*scale,width:f.width*scale,height:f.height*scale};};
    for(const shape of slide.shapes.items.filter(shape=>!shape.deleted)) {
      if(!['rect','ellipse'].includes(shape.geometry))unsupportedArtifactToolFeature('preview geometry '+shape.geometry);
      const t=shape.text;
      elements.push({frame:scaleFrame(shape.position),geometry:shape.geometry,fill:colorBytes(shape.fill,null),lineColor:colorBytes((shape.line||{}).fill||(shape.line||{}).color,null),lineWidth:Number((shape.line||{}).width||0)*scale,text:t.plain,fontSize:Number(t.fontSize||24)*scale/0.75,typeface:t.typeface,color:colorBytes(t.color,[17,24,39,255]),bold:t.bold,italic:t.italic,alignment:t.alignment,inset:Number((t.insets||{}).left||0)*scale});
    }
    for(const image of slide.images.items.filter(image=>!image.deleted)) {const payload=await imagePayload(image);elements.push({frame:scaleFrame(image.position),imageBase64:Buffer.from(payload.data).toString('base64')});}
    const png=globalThis.__jb_render_artifact(JSON.stringify({width:Math.round(presentation.slideSize.width*scale),height:Math.round(presentation.slideSize.height*scale),background:colorBytes(slide.background.fill,[255,255,255,255]),elements}));
    return new FileBlob(Buffer.from(png,'base64'),MIME.png);
  }
  if(options.previewMode!=='schematic')unsupportedArtifactToolFeature('native presentation preview outside JustBashJavaScript; explicitly request previewMode: "schematic" for a diagnostic only');
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

const EMU_PER_PIXEL=9525;
function drawingColor(value) { return value==null||value==='transparent'?'<a:noFill/>':`<a:solidFill><a:srgbClr val="${rgbHex(value)}"/></a:solidFill>`; }
function drawingTransform(position) { const f=frameOf(position,{});return `<a:xfrm><a:off x="${Math.round(f.left*EMU_PER_PIXEL)}" y="${Math.round(f.top*EMU_PER_PIXEL)}"/><a:ext cx="${Math.round(f.width*EMU_PER_PIXEL)}" cy="${Math.round(f.height*EMU_PER_PIXEL)}"/></a:xfrm>`; }
function shapeXml(shape,index) {
  if(!['rect','ellipse'].includes(shape.geometry))unsupportedArtifactToolFeature('PPTX shape geometry '+shape.geometry);
  const t=shape.text,alignment={left:'l',center:'ctr',right:'r',justify:'just'}[t.alignment]||'l';
  const runProperties=`<a:rPr lang="en-US" sz="${Math.round(Number(t.fontSize||24)*100)}" b="${t.bold?1:0}" i="${t.italic?1:0}">${drawingColor(t.color)}<a:latin typeface="${xml(t.typeface||'Aptos')}"/></a:rPr>`;
  const paragraphs=String(t.plain).split('\n').map(line=>`<a:p><a:pPr algn="${alignment}"/><a:r>${runProperties}<a:t xml:space="preserve">${xml(line)}</a:t></a:r><a:endParaRPr lang="en-US"/></a:p>`).join('');
  const insets=t.insets||{};
  return `<p:sp><p:nvSpPr><p:cNvPr id="${index}" name="${xml(shape.name||shape.id)}"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr><p:spPr>${drawingTransform(shape.position)}<a:prstGeom prst="${shape.geometry}"><a:avLst/></a:prstGeom>${drawingColor(shape.fill)}<a:ln w="${Math.round(Number((shape.line||{}).width||0)*EMU_PER_PIXEL)}">${drawingColor((shape.line||{}).fill||(shape.line||{}).color)}</a:ln></p:spPr><p:txBody><a:bodyPr anchor="${{top:'t',middle:'ctr',bottom:'b'}[t.verticalAlignment]||'t'}" lIns="${Math.round((insets.left||0)*EMU_PER_PIXEL)}" tIns="${Math.round((insets.top||0)*EMU_PER_PIXEL)}" rIns="${Math.round((insets.right||0)*EMU_PER_PIXEL)}" bIns="${Math.round((insets.bottom||0)*EMU_PER_PIXEL)}"/><a:lstStyle/>${paragraphs}</p:txBody></p:sp>`;
}
async function imagePayload(image) {
  const source=image.options.dataUrl||image.options.uri;
  if(source&&source.startsWith('data:')) {
    const match=source.match(/^data:(image\/(?:png|jpeg|svg\+xml));base64,([\s\S]+)$/);
    if(!match)unsupportedArtifactToolFeature('image source; use PNG/JPEG/SVG base64 data URL');
    return {data:Buffer.from(match[2],'base64'),mime:match[1],ext:match[1]==='image/jpeg'?'jpg':match[1]==='image/svg+xml'?'svg':'png'};
  }
  const path=image.options.path||source;
  if(!path||/^https?:/.test(path))unsupportedArtifactToolFeature('image source; load into the workspace first');
  const ext=String(path).split('.').pop().toLowerCase();if(!['png','jpg','jpeg','svg'].includes(ext))unsupportedArtifactToolFeature('image type '+ext);
  return {data:await fs.readFile(path),mime:ext==='svg'?'image/svg+xml':ext==='png'?'image/png':'image/jpeg',ext};
}
function pictureXml(image,index,relID) { return `<p:pic><p:nvPicPr><p:cNvPr id="${index}" name="${xml(image.name||image.id)}" descr="${xml(image.alt||image.options.alt||'')}"/><p:cNvPicPr><a:picLocks noChangeAspect="1"/></p:cNvPicPr><p:nvPr/></p:nvPicPr><p:blipFill><a:blip r:embed="${relID}"/><a:stretch><a:fillRect/></a:stretch></p:blipFill><p:spPr>${drawingTransform(image.position)}<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr></p:pic>`; }
function parseDrawingFrame(text) { const off=xmlAttributes(xmlElements(text,'a:off')[0]||''),ext=xmlAttributes(xmlElements(text,'a:ext')[0]||'');return {left:Number(off.x||0)/EMU_PER_PIXEL,top:Number(off.y||0)/EMU_PER_PIXEL,width:Number(ext.cx||0)/EMU_PER_PIXEL,height:Number(ext.cy||0)/EMU_PER_PIXEL}; }
function parseDrawingColor(text) { const val=xmlAttributes(xmlElements(text,'a:srgbClr')[0]||'').val;return val?'#'+val:undefined; }
export class PresentationFile {
  static async importPptx(blob) {
    const files=await unzipOfficeZip(blob instanceof FileBlob?blob.data:blob),text=zipText(files,'ppt/presentation.xml');
    if(!text)throw new Error('PresentationFile.importPptx requires ppt/presentation.xml');
    const size=xmlAttributes(xmlElements(text,'p:sldSz')[0]||'');
    const deck=Presentation.create({slideSize:{width:Number(size.cx||12192000)/EMU_PER_PIXEL,height:Number(size.cy||6858000)/EMU_PER_PIXEL}});
    const rels=xmlElements(zipText(files,'ppt/_rels/presentation.xml.rels'),'Relationship').map(xmlAttributes);
    for(const entry of xmlElements(text,'p:sldId')) {
      const id=xmlAttributes(entry)['r:id'],rel=rels.find(rel=>rel.Id===id);if(!rel)throw new Error('Missing slide relationship '+id);
      const target=packagePath('ppt',rel.Target),slideText=zipText(files,target),slide=deck.slides.add();
      if(/<p:graphicFrame\b|<p:grpSp\b|<p:oleObj\b|<p:timing\b|<p:ph\b/.test(slideText))unsupportedArtifactToolFeature('PPTX table, group, embedded object, inherited placeholder or animation import');
      slide.background.fill=parseDrawingColor(xmlElements(slideText,'p:bg')[0]||'');
      for(const element of xmlElements(slideText,'p:sp')) {
        const props=xmlElements(element,'p:spPr')[0]||'',nonvisual=xmlAttributes(xmlElements(element,'p:cNvPr')[0]||'');
        const geometry=xmlAttributes(xmlElements(props,'a:prstGeom')[0]||'').prst||'rect';
        const shape=slide.shapes.add({name:nonvisual.name,position:parseDrawingFrame(props),geometry,fill:parseDrawingColor(props.split('<a:ln')[0]),line:{fill:parseDrawingColor(xmlElements(props,'a:ln')[0]||''),width:Number(xmlAttributes(xmlElements(props,'a:ln')[0]||'').w||0)/EMU_PER_PIXEL}});
        const runs=xmlElements(element,'a:rPr');
        if(new Set(runs).size>1)unsupportedArtifactToolFeature('PPTX mixed text-run styles');
        shape.text=xmlElements(element,'a:p').map(p=>xmlElements(p,'a:t').map(t=>xmlDecode(t.replace(/<[^>]+>/g,''))).join('')).join('\n');
        const run=runs[0]||'',a=xmlAttributes(run.split('>')[0]);shape.text.fontSize=Number(a.sz||2400)/100;shape.text.bold=a.b==='1';shape.text.italic=a.i==='1';shape.text.color=parseDrawingColor(run)||'#111827';shape.text.typeface=xmlAttributes(xmlElements(run,'a:latin')[0]||'').typeface||'Aptos';
        const body=xmlAttributes(xmlElements(element,'a:bodyPr')[0]||'');shape.text.verticalAlignment={t:'top',ctr:'middle',b:'bottom'}[body.anchor]||'top';shape.text.insets={left:Number(body.lIns||0)/EMU_PER_PIXEL,top:Number(body.tIns||0)/EMU_PER_PIXEL,right:Number(body.rIns||0)/EMU_PER_PIXEL,bottom:Number(body.bIns||0)/EMU_PER_PIXEL};
        shape.text.alignment={l:'left',ctr:'center',r:'right',just:'justify'}[xmlAttributes(xmlElements(element,'a:pPr')[0]||'').algn]||'left';
      }
      const dir=target.slice(0,target.lastIndexOf('/')),name=target.slice(target.lastIndexOf('/')+1),slideRels=xmlElements(zipText(files,dir+'/_rels/'+name+'.rels'),'Relationship').map(xmlAttributes);
      if(slideRels.some(rel=>rel.Type.endsWith('/notesSlide')))unsupportedArtifactToolFeature('PPTX speaker notes import');
      for(const pic of xmlElements(slideText,'p:pic')) {
        if(/<a:srcRect\b/.test(pic))unsupportedArtifactToolFeature('PPTX cropped image import');
        const relID=xmlAttributes(xmlElements(pic,'a:blip')[0]||'')['r:embed'],imageRel=slideRels.find(rel=>rel.Id===relID);if(!imageRel)throw new Error('Missing image '+relID);
        const path=packagePath(dir,imageRel.Target),data=files[path];if(!data)throw new Error('Missing image data '+path);
        const ext=path.split('.').pop().toLowerCase(),mime=ext==='svg'?'image/svg+xml':ext==='png'?'image/png':'image/jpeg',nv=xmlAttributes(xmlElements(pic,'p:cNvPr')[0]||'');
        slide.images.add({name:nv.name,alt:nv.descr,position:parseDrawingFrame(xmlElements(pic,'p:spPr')[0]||''),dataUrl:`data:${mime};base64,${Buffer.from(data).toString('base64')}`});
      }
    }
    return deck;
  }
  static async exportPptx(presentation) {
    if(presentation.layouts.count||presentation.masters.count||presentation.comments.threads.length)unsupportedArtifactToolFeature('custom presentation layouts, masters or comments');
    const files={},overrides=[],imageTypes={};let imageIndex=1;
    for(let i=0;i<presentation.slides.count;i++) {
      const slide=presentation.slides.items[i];if(slide.tables.count||slide.speakerNotes.text)unsupportedArtifactToolFeature('presentation tables or speaker notes');
      let shapeID=2;const content=slide.shapes.items.filter(shape=>!shape.deleted).map(shape=>shapeXml(shape,shapeID++));
      const rels=[{id:'rIdLayout',kind:'slideLayout',target:'../slideLayouts/slideLayout1.xml'}];
      for(const image of slide.images.items.filter(image=>!image.deleted)) {
        if(Object.keys(image.crop||{}).length)unsupportedArtifactToolFeature('PPTX image crop');
        const payload=await imagePayload(image),name=`image${imageIndex++}.${payload.ext}`,relID='rIdImage'+imageIndex;
        files['ppt/media/'+name]=payload.data;imageTypes[payload.ext]=payload.mime;rels.push({id:relID,kind:'image',target:'../media/'+name});content.push(pictureXml(image,shapeID++,relID));
      }
      files[`ppt/slides/slide${i+1}.xml`]=`<?xml version="1.0"?><p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:cSld><p:bg><p:bgPr>${drawingColor(slide.background.fill||'#ffffff')}<a:effectLst/></p:bgPr></p:bg><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>${content.join('')}</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>`;
      files[`ppt/slides/_rels/slide${i+1}.xml.rels`]=officeRelationships(rels);overrides.push([`/ppt/slides/slide${i+1}.xml`,'application/vnd.openxmlformats-officedocument.presentationml.slide+xml']);
    }
    const tree='<p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/></p:spTree>',ns='xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"';
    files['ppt/slideLayouts/slideLayout1.xml']=`<?xml version="1.0"?><p:sldLayout ${ns} type="blank" preserve="1"><p:cSld name="Blank">${tree}</p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>`;
    files['ppt/slideLayouts/_rels/slideLayout1.xml.rels']=officeRelationships([{id:'rId1',kind:'slideMaster',target:'../slideMasters/slideMaster1.xml'}]);
    files['ppt/slideMasters/slideMaster1.xml']=`<?xml version="1.0"?><p:sldMaster ${ns}><p:cSld>${tree}</p:cSld><p:clrMap accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" bg1="lt1" bg2="lt2" folHlink="folHlink" hlink="hlink" tx1="dk1" tx2="dk2"/><p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst><p:txStyles><p:titleStyle/><p:bodyStyle/><p:otherStyle/></p:txStyles></p:sldMaster>`;
    files['ppt/slideMasters/_rels/slideMaster1.xml.rels']=officeRelationships([{id:'rId1',kind:'slideLayout',target:'../slideLayouts/slideLayout1.xml'}]);
    files['ppt/presentation.xml']=`<?xml version="1.0"?><p:presentation ${ns}><p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rIdMaster"/></p:sldMasterIdLst><p:sldIdLst>${presentation.slides.items.map((_,i)=>`<p:sldId id="${256+i}" r:id="rId${i+1}"/>`).join('')}</p:sldIdLst><p:sldSz cx="${Math.round(presentation.slideSize.width*EMU_PER_PIXEL)}" cy="${Math.round(presentation.slideSize.height*EMU_PER_PIXEL)}"/><p:notesSz cx="6858000" cy="9144000"/></p:presentation>`;
    files['ppt/_rels/presentation.xml.rels']=officeRelationships([...presentation.slides.items.map((_,i)=>({id:'rId'+(i+1),kind:'slide',target:`slides/slide${i+1}.xml`})),{id:'rIdMaster',kind:'slideMaster',target:'slideMasters/slideMaster1.xml'}]);
    files['_rels/.rels']=officeRelationships([{id:'rId1',kind:'officeDocument',target:'ppt/presentation.xml'}]);
    overrides.push(['/ppt/presentation.xml','application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml'],['/ppt/slideLayouts/slideLayout1.xml','application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml'],['/ppt/slideMasters/slideMaster1.xml','application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml']);
    files['[Content_Types].xml']=`<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/>${Object.entries(imageTypes).map(([ext,type])=>`<Default Extension="${ext}" ContentType="${type}"/>`).join('')}${overrides.map(([part,type])=>`<Override PartName="${part}" ContentType="${type}"/>`).join('')}</Types>`;
    return new FileBlob(zip(files),MIME.pptx);
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

function previewCellText(value,format) {
  if(typeof value!=='number')return String(value??'');
  const code=format.numberFormat||'General';
  if(code==='General'||code==='@'||!code)return String(value);
  if(!/^[#$0,.%\-+ ()]+$/.test(code))unsupportedArtifactToolFeature('native preview number format '+code);
  const decimals=(code.split('.')[1]||'').replace(/[^0#].*$/,'').length;
  let text=(value*(code.includes('%')?100:1)).toFixed(Math.min(10,decimals));
  if(code.includes(',')){const parts=text.split('.');parts[0]=parts[0].replace(/\B(?=(\d{3})+(?!\d))/g,',');text=parts.join('.');}
  return (code.includes('$')?'$':'')+text+(code.includes('%')?'%':'');
}
function renderNativeWorkbook(workbook,options) {
  if(options.format&&options.format!=='png')unsupportedArtifactToolFeature('workbook preview '+options.format);
  const sheet=options.sheetName?workbook.worksheets.getItem(options.sheetName):workbook.getActiveWorksheet();if(!sheet)throw new Error('Unknown preview worksheet');
  const bounds=options.range?parseRange(options.range):sheet.getUsedRange().bounds,scale=Number(options.scale||1),elements=[];
  const widths=Array.from({length:bounds.cols},(_,i)=>(sheet.columnWidths[bounds.col+i]!==undefined?sheet.columnWidths[bounds.col+i]*7:112)*scale);
  const heights=Array.from({length:bounds.rows},(_,i)=>(sheet.rowHeights[bounds.row+i]!==undefined?sheet.rowHeights[bounds.row+i]/0.75:28)*scale);
  const x=[0],y=[0];widths.forEach(w=>x.push(x[x.length-1]+w));heights.forEach(h=>y.push(y[y.length-1]+h));
  if(x[x.length-1]>1800||y[y.length-1]>1800)throw new Error('Preview exceeds 1800 pixels; select a smaller range or scale');
  const merges=sheet.mergedRanges.map(ref=>typeof ref==='string'?parseRange(ref):ref);
  for(let r=0;r<bounds.rows;r++)for(let c=0;c<bounds.cols;c++) {
    const row=bounds.row+r,col=bounds.col+c,merge=merges.find(m=>row>=m.row&&row<m.row+m.rows&&col>=m.col&&col<m.col+m.cols);
    if(merge&&(row!==merge.row||col!==merge.col))continue;
    const cell=sheet.cells[`${row},${col}`]||{},f=cell.format||{},font=f.font||{};let value;try{value=cellFormulaValue(sheet,row,col,new Set());}catch(error){value=error.code||'#VALUE!';}
    const width=merge?x[Math.min(bounds.cols,c+merge.cols)]-x[c]:widths[c],height=merge?y[Math.min(bounds.rows,r+merge.rows)]-y[r]:heights[r];
    elements.push({frame:{left:x[c],top:y[r],width,height},fill:colorBytes((f.fill||{}).color,[255,255,255,255]),lineWidth:sheet.showGridLines?1:0,lineColor:[209,213,219,255],text:previewCellText(value,f),fontSize:Number(font.size||font.fontSize||11)*scale/0.75,typeface:font.name||'Aptos',bold:font.bold,italic:font.italic,color:colorBytes(font.color,[17,24,39,255]),alignment:(f.alignment||{}).horizontal,inset:4*scale});
  }
  // Chart previews are explicitly schematic until the native chart layout lane is implemented.
  if(sheet.charts.count) {
    if(options.chartPreview!=='omit')unsupportedArtifactToolFeature('native chart preview; use chartPreview: "omit" for cells only and validate charts in the exported workbook');
  }
  const png=globalThis.__jb_render_artifact(JSON.stringify({width:Math.max(1,Math.ceil(x[x.length-1])),height:Math.max(1,Math.ceil(y[y.length-1])),elements}));return new FileBlob(Buffer.from(png,'base64'),MIME.png);
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
    if(typeof globalThis.__jb_render_artifact==='function') return renderNativeWorkbook(this,opts);
    if(opts.previewMode!=='schematic')unsupportedArtifactToolFeature('native workbook preview outside JustBashJavaScript; explicitly request previewMode: "schematic" for a diagnostic only');
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
          value = error.code || "#VALUE!";
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
    this.columnWidths = {};
    this.rowHeights = {};
    this.frozenRows = 0;
    this.frozenColumns = 0;
    this.charts = new ChartCollection(this);
    this.shapes = new LooseCollection((options) => ({ options: options || {}, text: "", position: (options || {}).position || {} }));
    this.images = new LooseCollection((options) => ({ options: options || {}, position: (options || {}).position || {} }));
    this.tables = new LooseCollection((rangeOrOptions, hasHeaders, name) => ({
      range: typeof rangeOrOptions === "string" ? rangeOrOptions : (rangeOrOptions || {}).range,
      hasHeaders: Boolean(hasHeaders),
      name: name || (rangeOrOptions || {}).name || `Table${this.tables.count + 1}`,
      options: typeof rangeOrOptions === "object" ? (rangeOrOptions || {}) : {}
    }));
    this.sparklineGroups = unsupportedCollection("sparklines");
    this.sparklines = this.sparklineGroups;
    this.dataTables = unsupportedCollection("what-if data tables");
    this.conditionalFormattings = unsupportedCollection("conditional formatting");
    this.dataValidations = new LooseCollection((options) => ({ options: options || {} }));
    this.showGridLines = true;
    this.mergedRanges = [];
    this.freezePanes = { freezeRows: (count) => { this.frozenRows = Math.max(0, Number(count)); }, freezeColumns: (count) => { this.frozenColumns = Math.max(0, Number(count)); }, unfreeze: () => { this.frozenRows = 0; this.frozenColumns = 0; } };
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
    this._format = rangeFormat(sheet, bounds);
    this._dataValidation = {};
    this.conditionalFormats = unsupportedCollection("conditional formatting");
    this.sparklines = unsupportedCollection("sparklines");
  }
  get format() { return this._format; }
  set format(value) { for(const key of Object.keys(value||{}))this._format[key]=value[key]; }
  get dataValidation() { return this._dataValidation; }
  set dataValidation(value) {
    const rule=(value||{}).rule||value||{};
    if (rule.type !== 'list' || !Array.isArray(rule.source)) unsupportedArtifactToolFeature('data validation other than a literal list');
    this._dataValidation=cloneData(value);
    this.sheet.dataValidations.items=this.sheet.dataValidations.items.filter(item=>item.ref!==rangeRef(this.bounds));
    this.sheet.dataValidations.items.push({ref:rangeRef(this.bounds),source:rule.source});
  }
  get values() {
    const out = [];
    for (let r = 0; r < this.bounds.rows; r += 1) {
      const row = [];
      for (let c = 0; c < this.bounds.cols; c += 1) {
        try {
          row.push(cellFormulaValue(this.sheet, this.bounds.row + r, this.bounds.col + c, new Set()));
        } catch (error) {
          row.push(error.code || "#VALUE!");
        }
      }
      out.push(row);
    }
    return out;
  }
  set values(matrix) {
    (matrix || []).forEach((row, r) => (row || []).forEach((value, c) => {
      const key=`${this.bounds.row+r},${this.bounds.col+c}`;
      this.sheet.cells[key] = { ...(this.sheet.cells[key] || {}), value };
      delete this.sheet.cells[key].formula;
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
    unsupportedArtifactToolFeature("R1C1 formulas");
  }
  set formulasR1C1(matrix) {
    unsupportedArtifactToolFeature("R1C1 formulas");
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
        if (applyTo === "contents") { const cell=this.sheet.cells[key]; if(cell){delete cell.value;delete cell.formula;} }
        else delete this.sheet.cells[key];
      }
    }
    if (applyTo === "formats" || applyTo === "all") {
      eachRangeCell(this.sheet,this.bounds,cell=>{delete cell.format;});
    }
  }
  copyFrom(sourceRange, kind) {
    if (!sourceRange) return this;
    const mode = kind || "all";
    if (mode === "values" || mode === "all") this.values = sourceRange.values;
    if (mode === "formulas" || mode === "all") this.formulas = sourceRange.formulas;
    if (mode === "formats" || mode === "all") eachRangeCell(this.sheet,this.bounds,(cell,row,col)=>{ const original=sourceRange.sheet.cells[`${sourceRange.bounds.row+row-this.bounds.row},${sourceRange.bounds.col+col-this.bounds.col}`];cell.format=cloneData((original||{}).format||{}); });
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
    const ref=rangeRef(this.bounds); if(!this.sheet.mergedRanges.includes(ref)) this.sheet.mergedRanges.push(ref);
  }
  unmerge() { const ref=rangeRef(this.bounds); this.sheet.mergedRanges=this.sheet.mergedRanges.filter(value=>value!==ref); }
  setNumberFormat(value) {
    this.format.numberFormat = value;
  }
  autofit() { this.format.autofitColumns(); this.format.autofitRows(); }
  fillDown() { unsupportedArtifactToolFeature("Range.fillDown; use explicit formulas"); }
  fillRight() { unsupportedArtifactToolFeature("Range.fillRight; use explicit formulas"); }
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

function sheetXml(sheet, relationships) {
  const rows={};
  Object.keys(sheet.cells).forEach(key=>{
    const [r,c]=key.split(',').map(Number),cell=sheet.cells[key],ref=a1(r,c); rows[r] ||= [];
    const style=` s="${cell.styleIndex||0}"`;
    if(cell.formula) {
      let value,type=''; try { value=cellFormulaValue(sheet,r,c,new Set()); } catch(error) {value=error.code||'#VALUE!';type=' t="e"';}
      if(typeof value==='boolean'){type=' t="b"';value=value?1:0;} else if(typeof value==='string'&&!type)type=' t="str"';
      rows[r].push(`<c r="${ref}"${style}${type}><f>${xml(String(cell.formula).replace(/^=/,''))}</f><v>${xml(value??'')}</v></c>`);
    } else if(typeof cell.value==='number')rows[r].push(`<c r="${ref}"${style}><v>${cell.value}</v></c>`);
    else if(typeof cell.value==='boolean')rows[r].push(`<c r="${ref}"${style} t="b"><v>${cell.value?1:0}</v></c>`);
    else rows[r].push(`<c r="${ref}"${style} t="inlineStr"><is><t xml:space="preserve">${xml(cell.value??'')}</t></is></c>`);
  });
  const body=Object.keys(rows).sort((a,b)=>Number(a)-Number(b)).map(r=>`<row r="${Number(r)+1}"${sheet.rowHeights[r]?` ht="${sheet.rowHeights[r]}" customHeight="1"`:''}>${rows[r].join('')}</row>`).join('');
  const pane=sheet.frozenRows||sheet.frozenColumns?`<pane xSplit="${sheet.frozenColumns}" ySplit="${sheet.frozenRows}" topLeftCell="${a1(sheet.frozenRows,sheet.frozenColumns)}" activePane="${sheet.frozenRows&&sheet.frozenColumns?'bottomRight':sheet.frozenRows?'bottomLeft':'topRight'}" state="frozen"/>`:'';
  const cols=Object.keys(sheet.columnWidths).map(col=>`<col min="${Number(col)+1}" max="${Number(col)+1}" width="${sheet.columnWidths[col]}" customWidth="1"/>`).join('');
  const merges=sheet.mergedRanges.map(ref=>`<mergeCell ref="${xml(typeof ref==='string'?ref:rangeRef(ref))}"/>`).join('');
  const validations=sheet.dataValidations.items.map(item=>`<dataValidation type="list" allowBlank="1" sqref="${xml(item.ref)}"><formula1>${xml('"'+item.source.join(',')+'"')}</formula1></dataValidation>`).join('');
  const tableParts=relationships.filter(rel=>rel.kind==='table').map(rel=>`<tablePart r:id="${rel.id}"/>`).join('');
  const drawing=relationships.find(rel=>rel.kind==='drawing');
  return `<?xml version="1.0" encoding="UTF-8"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheetViews><sheetView workbookViewId="0" showGridLines="${sheet.showGridLines?1:0}">${pane}</sheetView></sheetViews>${cols?`<cols>${cols}</cols>`:''}<sheetData>${body}</sheetData>${merges?`<mergeCells count="${sheet.mergedRanges.length}">${merges}</mergeCells>`:''}${validations?`<dataValidations count="${sheet.dataValidations.count}">${validations}</dataValidations>`:''}${drawing?`<drawing r:id="${drawing.id}"/>`:''}${tableParts?`<tableParts count="${sheet.tables.count}">${tableParts}</tableParts>`:''}</worksheet>`;
}
function officeRelationships(items) { return `<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">${items.map(item=>`<Relationship Id="${item.id}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/${item.kind}" Target="${xml(item.target)}"/>`).join('')}</Relationships>`; }
function packagePath(base,target) {if(target.startsWith('/'))base='';const parts=[]; for(const part of (base+'/'+target).split('/')) {if(part==='..')parts.pop();else if(part&&part!=='.')parts.push(part);}return parts.join('/');}
export class SpreadsheetFile {
  static async importXlsx(blob) {
    const files=await unzipOfficeZip(blob instanceof FileBlob?blob.data:blob);
    const workbookXml=zipText(files,'xl/workbook.xml');
    if(!workbookXml) throw new Error('SpreadsheetFile.importXlsx requires xl/workbook.xml');
    if(Object.keys(files).some(path=>/xl\/(pivot|slicer|vbaProject|externalLinks)/.test(path))) unsupportedArtifactToolFeature('XLSX pivot, slicer, macro or external-link import');
    const workbook=Workbook.create(),styles=importXlsxStyles(zipText(files,'xl/styles.xml'));
    const strings=parseSharedStrings(zipText(files,'xl/sharedStrings.xml'));
    const entries=parseWorkbookSheets(workbookXml,zipText(files,'xl/_rels/workbook.xml.rels'));
    for(const entry of entries) {
      const sheet=workbook.worksheets.add(entry.name),text=zipText(files,entry.target);
      if(/<conditionalFormatting\b|<extLst\b|<f\b[^>]*t="(?:shared|array)"/.test(text))unsupportedArtifactToolFeature('XLSX conditional-format, extension or shared/array formula import');
      parseWorksheetCells(sheet,text,strings);
      xmlElements(text,'c').forEach(cellXml=>{const a=xmlAttributes(cellXml.split('>')[0]);if(a.r){const p=parseCell(a.r);sheet.cells[`${p.row},${p.col}`].format=cloneData(styles[Number(a.s||0)]||{});}});
      sheet.showGridLines=!/<sheetView\b[^>]*showGridLines="0"/.test(text);
      sheet.mergedRanges=xmlElements(text,'mergeCell').map(el=>xmlAttributes(el).ref);
      const pane=xmlAttributes(xmlElements(text,'pane')[0]||'');
      if(pane.state==='frozen'||pane.state==='frozenSplit'){sheet.frozenRows=Number(pane.ySplit||0);sheet.frozenColumns=Number(pane.xSplit||0);}
      xmlElements(text,'col').forEach(el=>{const a=xmlAttributes(el);for(let c=Number(a.min)-1;c<Number(a.max);c++)sheet.columnWidths[c]=Number(a.width);});
      xmlElements(text,'row').forEach(el=>{const a=xmlAttributes(el.split('>')[0]);if(a.ht)sheet.rowHeights[Number(a.r)-1]=Number(a.ht);});
      xmlElements(text,'dataValidation').forEach(el=>{const a=xmlAttributes(el.split('>')[0]),f=xmlDecode((el.match(/<formula1>([\s\S]*?)<\/formula1>/)||[])[1]||'');if(a.type!=='list'||!f.startsWith('"'))unsupportedArtifactToolFeature('XLSX data validation other than literal list');sheet.dataValidations.items.push({ref:a.sqref,source:f.slice(1,-1).split(',')});});
      const dir=entry.target.slice(0,entry.target.lastIndexOf('/')),name=entry.target.slice(entry.target.lastIndexOf('/')+1);
      const rels=xmlElements(zipText(files,dir+'/_rels/'+name+'.rels'),'Relationship').map(xmlAttributes);
      for(const rel of rels) {
        const target=packagePath(dir,rel.Target);
        if(rel.Type.endsWith('/table')) {
          const a=xmlAttributes((zipText(files,target).match(/<table\b[^>]*>/)||[])[0]||'');
          sheet.tables.add(a.ref,a.headerRowCount!=='0',a.displayName||a.name);
        } else if(rel.Type.endsWith('/comments')) {
          const commentXml=zipText(files,target),authors=xmlElements(commentXml,'author').map(el=>xmlDecode(el.replace(/<[^>]+>/g,'')));
          xmlElements(commentXml,'comment').forEach(el=>{const a=xmlAttributes(el.split('>')[0]);workbook.comments.setSelf({displayName:authors[Number(a.authorId)]||'Author'});workbook.comments.addThread({cell:sheet.getRange(a.ref)},xmlDecode(xmlElements(el,'t').map(t=>t.replace(/<[^>]+>/g,'')).join('')));});
        } else if(rel.Type.endsWith('/drawing')) {
          const drawingText=zipText(files,target),drawDir=target.slice(0,target.lastIndexOf('/')),drawName=target.slice(target.lastIndexOf('/')+1);
          if(/<xdr:pic\b|<xdr:sp\b/.test(drawingText))unsupportedArtifactToolFeature('XLSX image or shape import');
          const chartRels=xmlElements(zipText(files,drawDir+'/_rels/'+drawName+'.rels'),'Relationship').map(xmlAttributes);
          xmlElements(drawingText,'xdr:twoCellAnchor').forEach(anchor=>{
            const relID=(anchor.match(/<c:chart\b[^>]*r:id="([^"]+)"/)||[])[1],chartRel=chartRels.find(r=>r.Id===relID);if(!chartRel)return;
            const chartText=zipText(files,packagePath(drawDir,chartRel.Target));
            if(!/<c:(lineChart|barChart)\b/.test(chartText))unsupportedArtifactToolFeature('XLSX chart type import');
            const refs=xmlElements(chartText,'c:f').map(el=>xmlDecode(el.replace(/<[^>]+>/g,''))).map(ref=>{const split=ref.lastIndexOf('!');return ref.slice(split+1).replace(/\$/g,'');}).flatMap(ref=>ref.split(':').map(parseCell));
            if(!refs.length)return;
            const minRow=Math.min(...refs.map(p=>p.row)),maxRow=Math.max(...refs.map(p=>p.row)),minCol=Math.min(...refs.map(p=>p.col)),maxCol=Math.max(...refs.map(p=>p.col));
            const chart=sheet.charts.add(/<c:lineChart/.test(chartText)?'line':/<c:barDir val="bar"/.test(chartText)?'bar':'column',sheet.getRangeByIndexes(minRow,minCol,maxRow-minRow+1,maxCol-minCol+1));
            chart.title=xmlDecode((chartText.match(/<a:t>([\s\S]*?)<\/a:t>/)||[])[1]||'Chart');
            const point=tag=>{const e=xmlElements(anchor,'xdr:'+tag)[0]||'';return a1(Number((e.match(/<xdr:row>(\d+)/)||[])[1]||0),Number((e.match(/<xdr:col>(\d+)/)||[])[1]||0));};chart.setPosition(point('from'),point('to'));
          });
        } else if(!rel.Type.endsWith('/vmlDrawing')) unsupportedArtifactToolFeature('XLSX relationship '+rel.Type);
      }
    }
    return workbook;
  }
  static async exportXlsx(workbook) {
    const sheets=workbook.worksheets.items.length?workbook.worksheets.items:[workbook.worksheets.add('Sheet1')];
    const files={'xl/styles.xml':xlsxStyles(workbook)},overrides=[['/xl/workbook.xml','application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml'],['/xl/styles.xml','application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml']];
    let chartIndex=1,tableIndex=1;
    sheets.forEach((sheet,index)=>{
      if(sheet.images.count||sheet.shapes.count)unsupportedArtifactToolFeature('XLSX shapes or images export');
      const rels=[];
      const relation=(kind,target)=>{const rel={id:'rId'+(rels.length+1),kind,target};rels.push(rel);return rel;};
      if(sheet.charts.count) {
        const charts=sheet.charts.items.map(chart=>({sheet,chart,chartIndex:chartIndex++}));
        charts.forEach(({chart,chartIndex})=>{if(!['line','column','bar'].includes(String(chart.type).toLowerCase()))unsupportedArtifactToolFeature('XLSX chart type '+chart.type);files[`xl/charts/chart${chartIndex}.xml`]=chartXml(chart,chartIndex);overrides.push([`/xl/charts/chart${chartIndex}.xml`,'application/vnd.openxmlformats-officedocument.drawingml.chart+xml']);});
        relation('drawing',`../drawings/drawing${index+1}.xml`);files[`xl/drawings/drawing${index+1}.xml`]=drawingXml(charts);files[`xl/drawings/_rels/drawing${index+1}.xml.rels`]=drawingRelsXml(charts);overrides.push([`/xl/drawings/drawing${index+1}.xml`,'application/vnd.openxmlformats-officedocument.drawing+xml']);
      }
      sheet.tables.items.forEach(table=>{
        const number=tableIndex++,ref=typeof table.range==='string'?table.range:rangeRef(table.range.bounds||table.range),bounds=parseRange(ref),headers=sheet.getRange(ref).values[0]||[];
        const columns=Array.from({length:bounds.cols},(_,i)=>`<tableColumn id="${i+1}" name="${xml(String(headers[i]??'Column'+(i+1)))}"/>`).join('');
        files[`xl/tables/table${number}.xml`]=`<?xml version="1.0"?><table xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" id="${number}" name="${xml(table.name)}" displayName="${xml(table.name)}" ref="${xml(ref)}" headerRowCount="${table.hasHeaders?1:0}" totalsRowShown="0">${table.hasHeaders?`<autoFilter ref="${xml(ref)}"/>`:''}<tableColumns count="${bounds.cols}">${columns}</tableColumns><tableStyleInfo name="TableStyleMedium2" showFirstColumn="0" showLastColumn="0" showRowStripes="1" showColumnStripes="0"/></table>`;
        relation('table',`../tables/table${number}.xml`);overrides.push([`/xl/tables/table${number}.xml`,'application/vnd.openxmlformats-officedocument.spreadsheetml.table+xml']);
      });
      const comments=workbook.comments.threads.filter(thread=>thread.target.cell&&thread.target.cell.sheet===sheet);
      if(comments.length) {
        const authors=comments.map(thread=>String(thread.comments[0].author?.displayName||'Author'));
        files[`xl/comments${index+1}.xml`]=`<?xml version="1.0"?><comments xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><authors>${authors.map(a=>`<author>${xml(a)}</author>`).join('')}</authors><commentList>${comments.map((thread,i)=>`<comment ref="${a1(thread.target.cell.bounds.row,thread.target.cell.bounds.col)}" authorId="${i}"><text><t xml:space="preserve">${xml(thread.comments.map(c=>c.text).join('\n'))}</t></text></comment>`).join('')}</commentList></comments>`;
        relation('comments',`../comments${index+1}.xml`);overrides.push([`/xl/comments${index+1}.xml`,'application/vnd.openxmlformats-officedocument.spreadsheetml.comments+xml']);
      }
      files[`xl/worksheets/sheet${index+1}.xml`]=sheetXml(sheet,rels);if(rels.length)files[`xl/worksheets/_rels/sheet${index+1}.xml.rels`]=officeRelationships(rels);
      overrides.push([`/xl/worksheets/sheet${index+1}.xml`,'application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml']);
    });
    files['[Content_Types].xml']=`<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/>${overrides.map(([part,type])=>`<Override PartName="${part}" ContentType="${type}"/>`).join('')}</Types>`;
    files['_rels/.rels']=officeRelationships([{id:'rId1',kind:'officeDocument',target:'xl/workbook.xml'}]);
    files['xl/workbook.xml']=`<?xml version="1.0"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>${sheets.map((sheet,i)=>`<sheet name="${xml(sheet.name)}" sheetId="${i+1}" r:id="rId${i+1}"/>`).join('')}</sheets><calcPr fullCalcOnLoad="1"/></workbook>`;
    files['xl/_rels/workbook.xml.rels']=officeRelationships([...sheets.map((_,i)=>({id:'rId'+(i+1),kind:'worksheet',target:`worksheets/sheet${i+1}.xml`})),{id:'rIdStyles',kind:'styles',target:'styles.xml'}]);
    return new FileBlob(zip(files),MIME.xlsx);
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
