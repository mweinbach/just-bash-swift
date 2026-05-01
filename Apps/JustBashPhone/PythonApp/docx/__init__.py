"""Small python-docx compatibility package for JustBash iOS.

The cached primary-runtime document helpers use a practical subset of
``python-docx`` for simple DOCX creation, table export, header/footer material,
and low-level OOXML insertion. This module implements that subset without native
dependencies so the same helper scripts can run inside the iOS bash runtime.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any
import zipfile

from lxml import etree

from .shared import Inches


W_NS = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
R_NS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
REL_NS = "http://schemas.openxmlformats.org/package/2006/relationships"
CT_NS = "http://schemas.openxmlformats.org/package/2006/content-types"

NS = {"w": W_NS, "r": R_NS}


def _w(tag: str) -> str:
    return f"{{{W_NS}}}{tag}"


def _r(tag: str) -> str:
    return f"{{{R_NS}}}{tag}"


def _paragraph_text(p_el: etree._Element) -> str:
    return "".join(p_el.xpath(".//w:t/text() | .//w:delText/text()", namespaces=NS))


def _text_run(text: str) -> etree._Element:
    r_el = etree.Element(_w("r"))
    t_el = etree.SubElement(r_el, _w("t"))
    t_el.text = text
    return r_el


def _empty_paragraph(text: str = "") -> etree._Element:
    p_el = etree.Element(_w("p"))
    if text:
        p_el.append(_text_run(text))
    return p_el


def _empty_cell() -> etree._Element:
    tc = etree.Element(_w("tc"))
    etree.SubElement(tc, _w("tcPr"))
    tc.append(_empty_paragraph())
    return tc


def _minimal_document_root() -> etree._Element:
    document = etree.Element(_w("document"), nsmap={"w": W_NS, "r": R_NS})
    body = etree.SubElement(document, _w("body"))
    etree.SubElement(body, _w("sectPr"))
    return document


def _body(root: etree._Element) -> etree._Element:
    body = root.find("w:body", namespaces=NS)
    if body is None:
        body = etree.SubElement(root, _w("body"))
    return body


def _sect_pr(root: etree._Element) -> etree._Element:
    body = _body(root)
    sect = body.find("w:sectPr", namespaces=NS)
    if sect is None:
        sect = etree.SubElement(body, _w("sectPr"))
    return sect


def _insert_body_child(root: etree._Element, child: etree._Element) -> None:
    body = _body(root)
    sect = body.find("w:sectPr", namespaces=NS)
    if sect is not None:
        body.insert(body.index(sect), child)
    else:
        body.append(child)


def _xml_bytes(root: etree._Element) -> bytes:
    return etree.tostring(root, xml_declaration=True, encoding="UTF-8", standalone="yes")


class _Style:
    def __init__(self, name: str | None = None) -> None:
        self.name = name or "Normal"


class _ParagraphFormat:
    def __init__(self) -> None:
        self.alignment = None
        self.first_line_indent = None
        self.left_indent = None
        self.right_indent = None
        self.space_before = None
        self.space_after = None
        self.line_spacing = None
        self.line_spacing_rule = None


class _Color:
    def __init__(self) -> None:
        self.rgb = None


class _Font:
    def __init__(self, run: "Run") -> None:
        self._run = run
        self.name = None
        self.size = None
        self.color = _Color()

    @property
    def bold(self) -> bool | None:
        return self._run.bold

    @bold.setter
    def bold(self, value: bool | None) -> None:
        self._run.bold = value

    @property
    def italic(self) -> bool | None:
        return self._run.italic

    @italic.setter
    def italic(self, value: bool | None) -> None:
        self._run.italic = value

    @property
    def underline(self) -> bool | None:
        return self._run.underline

    @underline.setter
    def underline(self, value: bool | None) -> None:
        self._run.underline = value


class Run:
    def __init__(self, element: etree._Element) -> None:
        self._r = element
        self._element = element
        self.font = _Font(self)

    @property
    def text(self) -> str:
        return "".join(self._r.xpath(".//w:t/text() | .//w:delText/text()", namespaces=NS))

    @text.setter
    def text(self, value: str) -> None:
        for child in list(self._r):
            self._r.remove(child)
        t_el = etree.SubElement(self._r, _w("t"))
        t_el.text = value

    def _get_or_add_rpr(self) -> etree._Element:
        rpr = self._r.find("w:rPr", namespaces=NS)
        if rpr is None:
            rpr = etree.Element(_w("rPr"))
            self._r.insert(0, rpr)
        return rpr

    def _set_toggle(self, tag: str, value: bool | None) -> None:
        rpr = self._get_or_add_rpr()
        existing = rpr.find(f"w:{tag}", namespaces=NS)
        if value is None:
            if existing is not None:
                rpr.remove(existing)
            return
        if existing is None:
            existing = etree.SubElement(rpr, _w(tag))
        if value is False:
            existing.set(_w("val"), "0")

    @property
    def bold(self) -> bool | None:
        return self._toggle_value("b")

    @bold.setter
    def bold(self, value: bool | None) -> None:
        self._set_toggle("b", value)

    @property
    def italic(self) -> bool | None:
        return self._toggle_value("i")

    @italic.setter
    def italic(self, value: bool | None) -> None:
        self._set_toggle("i", value)

    @property
    def underline(self) -> bool | None:
        return self._toggle_value("u")

    @underline.setter
    def underline(self, value: bool | None) -> None:
        self._set_toggle("u", value)

    def _toggle_value(self, tag: str) -> bool | None:
        el = self._r.find(f"w:rPr/w:{tag}", namespaces=NS)
        if el is None:
            return None
        return el.get(_w("val")) != "0"


class _Part:
    def __init__(self, document: "Document | None") -> None:
        self._document = document

    def relate_to(self, target: str, reltype: str, is_external: bool = False) -> str:
        if self._document is None:
            raise AttributeError("paragraph is not attached to a document part")
        return self._document._add_relationship(target, reltype, is_external=is_external)


class Paragraph:
    def __init__(self, element: etree._Element, document: "Document | None" = None) -> None:
        self._p = element
        self._element = element
        self.part = _Part(document)
        self.paragraph_format = _ParagraphFormat()
        self.alignment = None

    @property
    def text(self) -> str:
        return _paragraph_text(self._p)

    @text.setter
    def text(self, value: str) -> None:
        for child in list(self._p):
            self._p.remove(child)
        if value:
            self._p.append(_text_run(value))

    @property
    def runs(self) -> list[Run]:
        return [Run(r) for r in self._p.xpath("./w:r", namespaces=NS)]

    @property
    def style(self) -> _Style:
        pstyle = self._p.find("w:pPr/w:pStyle", namespaces=NS)
        if pstyle is not None:
            return _Style(pstyle.get(_w("val")))
        return _Style()

    @style.setter
    def style(self, value: str | _Style | None) -> None:
        name = value.name if isinstance(value, _Style) else value
        ppr = self._p.find("w:pPr", namespaces=NS)
        if ppr is None:
            ppr = etree.Element(_w("pPr"))
            self._p.insert(0, ppr)
        pstyle = ppr.find("w:pStyle", namespaces=NS)
        if pstyle is None:
            pstyle = etree.SubElement(ppr, _w("pStyle"))
        pstyle.set(_w("val"), name or "Normal")

    def add_run(self, text: str = "") -> Run:
        r_el = _text_run(text)
        self._p.append(r_el)
        return Run(r_el)


class Cell:
    def __init__(self, element: etree._Element) -> None:
        self._tc = element
        self._element = element
        self.width = None

    @property
    def paragraphs(self) -> list[Paragraph]:
        paragraphs = self._tc.xpath("./w:p", namespaces=NS)
        if not paragraphs:
            paragraphs = [etree.SubElement(self._tc, _w("p"))]
        return [Paragraph(p) for p in paragraphs]

    @property
    def text(self) -> str:
        return "\n".join(p.text for p in self.paragraphs)

    @text.setter
    def text(self, value: str) -> None:
        for child in list(self._tc):
            if child.tag != _w("tcPr"):
                self._tc.remove(child)
        self._tc.append(_empty_paragraph(value))


class Row:
    def __init__(self, element: etree._Element) -> None:
        self._tr = element
        self._element = element
        self.height = None

    @property
    def cells(self) -> list[Cell]:
        return [Cell(tc) for tc in self._tr.xpath("./w:tc", namespaces=NS)]


class _Column:
    def __init__(self) -> None:
        self.width = None


class Table:
    def __init__(self, element: etree._Element) -> None:
        self._tbl = element
        self._element = element
        self.style = None
        self.autofit = True
        self.alignment = None

    @property
    def rows(self) -> list[Row]:
        return [Row(tr) for tr in self._tbl.xpath("./w:tr", namespaces=NS)]

    @property
    def columns(self) -> list[_Column]:
        count = max((len(row.cells) for row in self.rows), default=0)
        return [_Column() for _ in range(count)]

    def cell(self, row: int, col: int) -> Cell:
        return self.rows[row].cells[col]


class _HeaderFooter:
    def __init__(self, document: "Document", kind: str) -> None:
        self._document = document
        self._kind = kind
        self.is_linked_to_previous = False

    @property
    def _root(self) -> etree._Element:
        return self._document._ensure_story_root(self._kind)

    @property
    def paragraphs(self) -> list[Paragraph]:
        paragraphs = self._root.xpath("./w:p", namespaces=NS)
        return [Paragraph(p, self._document) for p in paragraphs]

    def add_paragraph(self, text: str = "", style: str | None = None) -> Paragraph:
        p_el = _empty_paragraph(text)
        self._root.append(p_el)
        p = Paragraph(p_el, self._document)
        if style:
            p.style = style
        return p

    def add_table(self, rows: int, cols: int, width: Any | None = None) -> Table:
        table = self._document._make_table(rows, cols)
        self._root.append(table._tbl)
        return table


@dataclass
class Section:
    _document: "Document"
    page_width: int = int(Inches(8.5))
    page_height: int = int(Inches(11))
    left_margin: int = int(Inches(1))
    right_margin: int = int(Inches(1))
    top_margin: int = int(Inches(1))
    bottom_margin: int = int(Inches(1))
    orientation: str = "portrait"

    @property
    def header(self) -> _HeaderFooter:
        return _HeaderFooter(self._document, "header")

    @property
    def footer(self) -> _HeaderFooter:
        return _HeaderFooter(self._document, "footer")


class Document:
    def __init__(self, path: str | Path | None = None) -> None:
        self._source_path = Path(path) if path is not None else None
        self._extra_parts: dict[str, bytes] = {}
        self._header_root: etree._Element | None = None
        self._footer_root: etree._Element | None = None
        if self._source_path is not None:
            self._load(self._source_path)
        else:
            self._root = _minimal_document_root()
        self._sections = [Section(self)]
        self._relationships: list[tuple[str, str, str, bool]] = []

    @property
    def paragraphs(self) -> list[Paragraph]:
        return [Paragraph(p, self) for p in _body(self._root).xpath("./w:p", namespaces=NS)]

    @property
    def tables(self) -> list[Table]:
        return [Table(tbl) for tbl in _body(self._root).xpath("./w:tbl", namespaces=NS)]

    @property
    def sections(self) -> list[Section]:
        return self._sections

    def add_paragraph(self, text: str = "", style: str | None = None) -> Paragraph:
        p_el = _empty_paragraph(text)
        _insert_body_child(self._root, p_el)
        p = Paragraph(p_el, self)
        if style:
            p.style = style
        return p

    def add_heading(self, text: str = "", level: int = 1) -> Paragraph:
        return self.add_paragraph(text, style=f"Heading {level}")

    def add_table(self, rows: int, cols: int) -> Table:
        table = self._make_table(rows, cols)
        _insert_body_child(self._root, table._tbl)
        return table

    def save(self, path: str | Path) -> None:
        out = Path(path)
        out.parent.mkdir(parents=True, exist_ok=True)
        parts = self._default_parts()
        parts.update(self._extra_parts)
        parts["word/document.xml"] = _xml_bytes(self._root)
        if self._header_root is not None:
            parts["word/header1.xml"] = _xml_bytes(self._header_root)
        if self._footer_root is not None:
            parts["word/footer1.xml"] = _xml_bytes(self._footer_root)
        parts["[Content_Types].xml"] = self._content_types(include_header=self._header_root is not None, include_footer=self._footer_root is not None)
        parts["word/_rels/document.xml.rels"] = self._document_rels(include_header=self._header_root is not None, include_footer=self._footer_root is not None)
        with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as zf:
            for name, data in sorted(parts.items()):
                zf.writestr(name, data)

    def _load(self, path: Path) -> None:
        with zipfile.ZipFile(path, "r") as zf:
            names = set(zf.namelist())
            self._root = etree.fromstring(zf.read("word/document.xml")) if "word/document.xml" in names else _minimal_document_root()
            for name in names:
                if name.startswith("word/header") and name.endswith(".xml") and self._header_root is None:
                    self._header_root = etree.fromstring(zf.read(name))
                elif name.startswith("word/footer") and name.endswith(".xml") and self._footer_root is None:
                    self._footer_root = etree.fromstring(zf.read(name))
                elif name not in {"word/document.xml", "[Content_Types].xml", "_rels/.rels", "word/_rels/document.xml.rels"}:
                    self._extra_parts[name] = zf.read(name)

    def _add_relationship(self, target: str, reltype: str, is_external: bool = False) -> str:
        existing_ids = [rel_id for rel_id, *_ in self._relationships]
        next_id = 1
        while f"rIdCompat{next_id}" in existing_ids:
            next_id += 1
        rel_id = f"rIdCompat{next_id}"
        self._relationships.append((rel_id, reltype, target, is_external))
        return rel_id

    def _ensure_story_root(self, kind: str) -> etree._Element:
        attr = "_header_root" if kind == "header" else "_footer_root"
        root = getattr(self, attr)
        if root is None:
            tag = "hdr" if kind == "header" else "ftr"
            root = etree.Element(_w(tag), nsmap={"w": W_NS, "r": R_NS})
            root.append(_empty_paragraph())
            setattr(self, attr, root)
        return root

    def _make_table(self, rows: int, cols: int) -> Table:
        tbl = etree.Element(_w("tbl"))
        tbl_pr = etree.SubElement(tbl, _w("tblPr"))
        tbl_w = etree.SubElement(tbl_pr, _w("tblW"))
        tbl_w.set(_w("type"), "auto")
        tbl_w.set(_w("w"), "0")
        grid = etree.SubElement(tbl, _w("tblGrid"))
        for _ in range(cols):
            col = etree.SubElement(grid, _w("gridCol"))
            col.set(_w("w"), "1440")
        for _ in range(rows):
            tr = etree.SubElement(tbl, _w("tr"))
            for _ in range(cols):
                tr.append(_empty_cell())
        return Table(tbl)

    def _default_parts(self) -> dict[str, bytes]:
        return {
            "_rels/.rels": (
                f'<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
                f'<Relationships xmlns="{REL_NS}">'
                f'<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>'
                f"</Relationships>"
            ).encode("utf-8"),
            "docProps/core.xml": b'<?xml version="1.0" encoding="UTF-8" standalone="yes"?><cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties"/>',
            "docProps/app.xml": b'<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"/>',
        }

    def _content_types(self, *, include_header: bool, include_footer: bool) -> bytes:
        overrides = [
            '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>',
            '<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>',
            '<Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>',
        ]
        if include_header:
            overrides.append('<Override PartName="/word/header1.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.header+xml"/>')
        if include_footer:
            overrides.append('<Override PartName="/word/footer1.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml"/>')
        text = (
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            f'<Types xmlns="{CT_NS}">'
            '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
            '<Default Extension="xml" ContentType="application/xml"/>'
            + "".join(overrides)
            + "</Types>"
        )
        return text.encode("utf-8")

    def _document_rels(self, *, include_header: bool, include_footer: bool) -> bytes:
        rels = []
        if include_header:
            rels.append('<Relationship Id="rIdHeader1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/header" Target="header1.xml"/>')
            sect = _sect_pr(self._root)
            ref = sect.find("w:headerReference", namespaces=NS)
            if ref is None:
                ref = etree.SubElement(sect, _w("headerReference"))
            ref.set(_w("type"), "default")
            ref.set(_r("id"), "rIdHeader1")
        if include_footer:
            rels.append('<Relationship Id="rIdFooter1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer" Target="footer1.xml"/>')
            sect = _sect_pr(self._root)
            ref = sect.find("w:footerReference", namespaces=NS)
            if ref is None:
                ref = etree.SubElement(sect, _w("footerReference"))
            ref.set(_w("type"), "default")
            ref.set(_r("id"), "rIdFooter1")
        for rel_id, reltype, target, is_external in self._relationships:
            mode = ' TargetMode="External"' if is_external else ""
            rels.append(f'<Relationship Id="{rel_id}" Type="{reltype}" Target="{target}"{mode}/>')
        text = (
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            f'<Relationships xmlns="{REL_NS}">'
            + "".join(rels)
            + "</Relationships>"
        )
        return text.encode("utf-8")


__all__ = ["Document"]
