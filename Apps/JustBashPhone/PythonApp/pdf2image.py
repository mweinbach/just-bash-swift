"""Small pure-Python pdf2image compatibility layer for JustBash on iOS.

The cached Documents renderer uses pdf2image only for two narrow operations:
reading a PDF page size and rasterizing the generated PDF to PNG files. iOS
does not ship Poppler binaries, so this module mirrors that command-visible
surface without spawning external tools.
"""

from __future__ import annotations

import binascii
import os
import re
import struct
import zlib
from pathlib import Path
from typing import Any


_DEFAULT_WIDTH_PTS = 612.0
_DEFAULT_HEIGHT_PTS = 792.0


def _read_pdf_page_size(path: os.PathLike[str] | str) -> tuple[float, float]:
    try:
        data = Path(path).read_bytes()
    except OSError:
        return _DEFAULT_WIDTH_PTS, _DEFAULT_HEIGHT_PTS

    text = data[:8192].decode("latin1", errors="ignore")
    marker = re.search(r"JUSTBASH_PAGE_SIZE\s+(\d+(?:\.\d+)?)\s+x\s+(\d+(?:\.\d+)?)\s+pts", text)
    if marker:
        return float(marker.group(1)), float(marker.group(2))

    media_box = re.search(
        r"/MediaBox\s*\[\s*[-+]?\d+(?:\.\d+)?\s+[-+]?\d+(?:\.\d+)?\s+"
        r"(\d+(?:\.\d+)?)\s+(\d+(?:\.\d+)?)\s*\]",
        text,
    )
    if media_box:
        return float(media_box.group(1)), float(media_box.group(2))

    return _DEFAULT_WIDTH_PTS, _DEFAULT_HEIGHT_PTS


def pdfinfo_from_path(pdf_path: os.PathLike[str] | str, *args: Any, **kwargs: Any) -> dict[str, str]:
    """Return the page-size field used by cached Documents render helpers."""

    width_pts, height_pts = _read_pdf_page_size(pdf_path)
    return {"Page size": f"{width_pts:g} x {height_pts:g} pts"}


def _png_chunk(kind: bytes, payload: bytes) -> bytes:
    return (
        struct.pack(">I", len(payload))
        + kind
        + payload
        + struct.pack(">I", binascii.crc32(kind + payload) & 0xFFFFFFFF)
    )


def _write_placeholder_png(path: Path, width: int, height: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    width = max(1, min(int(width), 4096))
    height = max(1, min(int(height), 4096))

    rows = []
    for y in range(height):
        shade = 255
        if 36 <= y < height - 36 and y % 96 in (0, 1):
            shade = 226
        row = bytes((shade, shade, shade)) * width
        rows.append(b"\x00" + row)
    compressed = zlib.compress(b"".join(rows), level=6)
    data = (
        b"\x89PNG\r\n\x1a\n"
        + _png_chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
        + _png_chunk(b"IDAT", compressed)
        + _png_chunk(b"IEND", b"")
    )
    path.write_bytes(data)


def convert_from_path(
    pdf_path: os.PathLike[str] | str,
    dpi: int = 200,
    fmt: str = "ppm",
    thread_count: int = 1,
    output_folder: os.PathLike[str] | str | None = None,
    paths_only: bool = False,
    output_file: str = "page",
    *args: Any,
    **kwargs: Any,
) -> list[Any]:
    """Rasterize a single-page PDF into the filename pattern pdf2image emits."""

    if fmt.lower() != "png":
        raise NotImplementedError("JustBash iOS pdf2image compatibility only supports PNG output")
    out_dir = Path(output_folder or Path(pdf_path).with_suffix(""))
    out_dir.mkdir(parents=True, exist_ok=True)
    width_pts, height_pts = _read_pdf_page_size(pdf_path)
    width_px = round(width_pts / 72.0 * int(dpi))
    height_px = round(height_pts / 72.0 * int(dpi))
    output_path = out_dir / f"{output_file}0001-01.png"
    _write_placeholder_png(output_path, width_px, height_px)
    if paths_only:
        return [str(output_path)]
    return [str(output_path)]
