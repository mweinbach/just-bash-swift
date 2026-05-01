"""Pure-Python subset of :mod:`lxml.etree` for JustBash iOS.

The iPhone build cannot currently ship lxml's native extension wheels. The
primary-runtime Documents helpers mostly need namespace-aware OOXML parsing,
simple XPath selections, parent/sibling mutation, and XML serialization. This
module provides that behavior on top of ``xml.etree.ElementTree`` so those
helpers can run inside the app's bash/Python environment.
"""

from __future__ import annotations

from collections.abc import Iterable, Iterator
from pathlib import Path
from typing import Any
import re
import xml.etree.ElementTree as _ET


_ElementLike = "_Element | _ET.Element"


class XMLParser:
    def __init__(self, *args: Any, remove_blank_text: bool = False, recover: bool = False, **kwargs: Any) -> None:
        self.remove_blank_text = remove_blank_text
        self.recover = recover


class QName:
    def __init__(self, text_or_uri: str, tag: str | None = None) -> None:
        self.text = f"{{{text_or_uri}}}{tag}" if tag is not None else text_or_uri

    def __str__(self) -> str:
        return self.text

    @property
    def namespace(self) -> str | None:
        if self.text.startswith("{") and "}" in self.text:
            return self.text[1 : self.text.index("}")]
        return None

    @property
    def localname(self) -> str:
        if self.text.startswith("{") and "}" in self.text:
            return self.text[self.text.index("}") + 1 :]
        return self.text


class _Element:
    def __init__(self, element: _ET.Element, parent: "_Element | None" = None) -> None:
        object.__setattr__(self, "_element", element)
        object.__setattr__(self, "_parent", parent)
        object.__setattr__(self, "_children", [])
        children = [_Element(child, self) for child in list(element)]
        object.__setattr__(self, "_children", children)

    @property
    def tag(self) -> str:
        return self._element.tag

    @tag.setter
    def tag(self, value: str) -> None:
        self._element.tag = value

    @property
    def text(self) -> str | None:
        return self._element.text

    @text.setter
    def text(self, value: str | None) -> None:
        self._element.text = value

    @property
    def tail(self) -> str | None:
        return self._element.tail

    @tail.setter
    def tail(self, value: str | None) -> None:
        self._element.tail = value

    @property
    def attrib(self) -> dict[str, str]:
        return self._element.attrib

    def get(self, key: str, default: Any = None) -> Any:
        return self._element.get(key, default)

    def set(self, key: str, value: Any) -> None:
        self._element.set(key, str(value))

    def keys(self) -> list[str]:
        return list(self._element.keys())

    def items(self) -> list[tuple[str, str]]:
        return list(self._element.items())

    def getparent(self) -> "_Element | None":
        return self._parent

    def getnext(self) -> "_Element | None":
        if self._parent is None:
            return None
        siblings = self._parent._children
        index = siblings.index(self)
        return siblings[index + 1] if index + 1 < len(siblings) else None

    def getprevious(self) -> "_Element | None":
        if self._parent is None:
            return None
        siblings = self._parent._children
        index = siblings.index(self)
        return siblings[index - 1] if index > 0 else None

    def iterancestors(self) -> Iterator["_Element"]:
        parent = self._parent
        while parent is not None:
            yield parent
            parent = parent._parent

    def append(self, child: _ElementLike) -> None:
        wrapped = _coerce_element(child)
        _detach(wrapped)
        wrapped._parent = self
        self._children.append(wrapped)
        self._element.append(wrapped._element)

    def extend(self, children: Iterable[_ElementLike]) -> None:
        for child in children:
            self.append(child)

    def insert(self, index: int, child: _ElementLike) -> None:
        wrapped = _coerce_element(child)
        _detach(wrapped)
        wrapped._parent = self
        self._children.insert(index, wrapped)
        self._element.insert(index, wrapped._element)

    def remove(self, child: _ElementLike) -> None:
        wrapped = _coerce_element(child)
        self._children.remove(wrapped)
        self._element.remove(wrapped._element)
        wrapped._parent = None

    def addnext(self, child: _ElementLike) -> None:
        if self._parent is None:
            raise ValueError("cannot add sibling to root element")
        self._parent.insert(self._parent._children.index(self) + 1, child)

    def addprevious(self, child: _ElementLike) -> None:
        if self._parent is None:
            raise ValueError("cannot add sibling to root element")
        self._parent.insert(self._parent._children.index(self), child)

    def clear(self) -> None:
        for child in self._children:
            child._parent = None
        self._children = []
        self._element.clear()

    def find(self, path: str, namespaces: dict[str, str] | None = None) -> "_Element | None":
        matches = self.findall(path, namespaces=namespaces)
        return matches[0] if matches else None

    def findall(self, path: str, namespaces: dict[str, str] | None = None) -> list["_Element"]:
        if path.startswith("{") or path.startswith("./{"):
            raw = path[2:] if path.startswith("./") else path
            return [child for child in self._children if child.tag == raw]
        return [item for item in _select_path(self, path, namespaces or {}) if isinstance(item, _Element)]

    def iter(self, tag: str | None = None) -> Iterator["_Element"]:
        if tag is None or tag == "*" or self.tag == tag:
            yield self
        for child in self._children:
            yield from child.iter(tag)

    def xpath(self, expression: str, namespaces: dict[str, str] | None = None, **kwargs: Any) -> Any:
        namespaces = namespaces or {}
        expression = expression.strip()
        if expression.startswith("string(") and expression.endswith(")"):
            values = _select_path(self, expression[len("string(") : -1], namespaces)
            if not values:
                return ""
            first = values[0]
            return _string_value(first)
        if "|" in expression:
            seen: set[int] = set()
            merged: list[Any] = []
            for part in expression.split("|"):
                for value in self.xpath(part.strip(), namespaces=namespaces):
                    marker = id(value)
                    if marker not in seen:
                        seen.add(marker)
                        merged.append(value)
            return merged
        return _select_path(self, expression, namespaces)

    def __len__(self) -> int:
        return len(self._children)

    def __iter__(self) -> Iterator["_Element"]:
        return iter(self._children)

    def __getitem__(self, index: int | slice) -> Any:
        return self._children[index]

    def __setitem__(self, index: int, child: _ElementLike) -> None:
        old = self._children[index]
        wrapped = _coerce_element(child)
        _detach(wrapped)
        old._parent = None
        wrapped._parent = self
        self._children[index] = wrapped
        self._element[index] = wrapped._element

    def __delitem__(self, index: int | slice) -> None:
        victims = self._children[index]
        if isinstance(victims, _Element):
            victims = [victims]
        del self._children[index]
        del self._element[index]
        for victim in victims:
            victim._parent = None

    def __repr__(self) -> str:
        return f"<Element {self.tag!r} at {hex(id(self))}>"


class _ElementTree:
    def __init__(self, element: _ElementLike | _ET.ElementTree) -> None:
        if isinstance(element, _ET.ElementTree):
            self._tree = element
            self._root = _Element(element.getroot())
        else:
            root = _coerce_element(element)
            self._root = root
            self._tree = _ET.ElementTree(root._element)

    def getroot(self) -> _Element:
        return self._root

    def write(
        self,
        file_or_filename: str | Path | Any,
        encoding: str = "us-ascii",
        xml_declaration: bool | None = None,
        standalone: bool | str | None = None,
        **kwargs: Any,
    ) -> None:
        data = tostring(self._root, encoding=encoding, xml_declaration=bool(xml_declaration), standalone=standalone)
        if hasattr(file_or_filename, "write"):
            file_or_filename.write(data)
        else:
            Path(file_or_filename).write_bytes(data)

    def xpath(self, expression: str, namespaces: dict[str, str] | None = None, **kwargs: Any) -> Any:
        return self._root.xpath(expression, namespaces=namespaces, **kwargs)


def Element(tag: str | QName, attrib: dict[str, Any] | None = None, nsmap: dict[str | None, str] | None = None, **extra: Any) -> _Element:
    _register_nsmap(nsmap)
    attrs = _prepare_attrs(attrib, extra)
    return _Element(_ET.Element(str(tag), attrs))


def SubElement(
    parent: _ElementLike,
    tag: str | QName,
    attrib: dict[str, Any] | None = None,
    nsmap: dict[str | None, str] | None = None,
    **extra: Any,
) -> _Element:
    wrapped_parent = _coerce_element(parent)
    child = Element(tag, attrib=attrib, nsmap=nsmap, **extra)
    wrapped_parent.append(child)
    return child


def ElementTree(element: _ElementLike) -> _ElementTree:
    return _ElementTree(element)


def XML(text: str | bytes, parser: XMLParser | None = None) -> _Element:
    return fromstring(text, parser=parser)


def fromstring(text: str | bytes, parser: XMLParser | None = None, **kwargs: Any) -> _Element:
    raw = text.encode("utf-8") if isinstance(text, str) else text
    return _Element(_ET.fromstring(raw))


def parse(source: str | Path | Any, parser: XMLParser | None = None, **kwargs: Any) -> _ElementTree:
    return _ElementTree(_ET.parse(source))


def tostring(
    element_or_tree: _ElementLike | _ElementTree,
    encoding: str | None = "ASCII",
    xml_declaration: bool | None = None,
    standalone: bool | str | None = None,
    pretty_print: bool = False,
    **kwargs: Any,
) -> bytes | str:
    if isinstance(element_or_tree, _ElementTree):
        element = element_or_tree.getroot()
    else:
        element = _coerce_element(element_or_tree)
    enc = encoding or "unicode"
    data = _ET.tostring(element._element, encoding=enc, xml_declaration=bool(xml_declaration))
    if standalone is not None and xml_declaration:
        data = _add_standalone(data, standalone)
    return data


def register_namespace(prefix: str, uri: str) -> None:
    _ET.register_namespace(prefix, uri)


def cleanup_namespaces(tree_or_element: _ElementLike | _ElementTree, **kwargs: Any) -> None:
    return None


def _coerce_element(value: _ElementLike) -> _Element:
    if isinstance(value, _Element):
        return value
    if isinstance(value, _ET.Element):
        return _Element(value)
    raise TypeError(f"expected Element, got {type(value)!r}")


def _detach(element: _Element) -> None:
    parent = element._parent
    if parent is not None:
        parent.remove(element)


def _register_nsmap(nsmap: dict[str | None, str] | None) -> None:
    for prefix, uri in (nsmap or {}).items():
        if prefix is not None:
            _ET.register_namespace(prefix, uri)


def _prepare_attrs(attrib: dict[str, Any] | None, extra: dict[str, Any]) -> dict[str, str]:
    attrs: dict[str, str] = {}
    for key, value in (attrib or {}).items():
        attrs[str(key)] = str(value)
    for key, value in extra.items():
        attrs[str(key)] = str(value)
    return attrs


def _add_standalone(data: bytes | str, standalone: bool | str) -> bytes | str:
    value = "yes" if standalone is True else "no" if standalone is False else str(standalone)
    if isinstance(data, bytes):
        if b"standalone=" in data or not data.startswith(b"<?xml"):
            return data
        return data.replace(b"?>", f' standalone="{value}"?>'.encode("ascii"), 1)
    if "standalone=" in data or not data.startswith("<?xml"):
        return data
    return data.replace("?>", f' standalone="{value}"?>', 1)


def _string_value(value: Any) -> str:
    if isinstance(value, _Element):
        return "".join(value._element.itertext())
    return "" if value is None else str(value)


def _select_path(root: _Element, expression: str, namespaces: dict[str, str]) -> list[Any]:
    expression = expression.strip()
    if not expression:
        return []
    if expression == ".":
        return [root]
    if expression.startswith("(") and expression.endswith(")"):
        expression = expression[1:-1].strip()
    text_mode = expression.endswith("/text()")
    if text_mode:
        expression = expression[: -len("/text()")]
    attr_name: str | None = None
    attr_match = re.match(r"^(.*)/@([A-Za-z_][\w.-]*(?::[A-Za-z_][\w.-]*)?)$", expression)
    if attr_match:
        expression = attr_match.group(1)
        attr_name = _expand_name(attr_match.group(2), namespaces)

    current: list[_Element] = [root]
    remaining = expression
    anywhere = False
    absolute = False
    if remaining.startswith(".//"):
        anywhere = True
        remaining = remaining[3:]
    elif remaining.startswith("//"):
        anywhere = True
        remaining = remaining[2:]
    elif remaining.startswith("./"):
        remaining = remaining[2:]
    elif remaining.startswith("/"):
        absolute = True
        remaining = remaining.lstrip("/")

    segments = [segment for segment in _split_path_segments(remaining) if segment and segment != "."]
    if not segments:
        nodes = current
    else:
        first, rest = segments[0], segments[1:]
        if anywhere:
            nodes = _match_descendants(current, first, namespaces)
        elif absolute:
            nodes = [node for node in current if _segment_matches(node, first, namespaces)]
        else:
            nodes = _match_children(current, first, namespaces)
        for segment in rest:
            nodes = _match_children(nodes, segment, namespaces)

    if attr_name is not None:
        return [node.get(attr_name) for node in nodes if node.get(attr_name) is not None]
    if text_mode:
        return [text for node in nodes for text in node._element.itertext()]
    return nodes


def _match_children(nodes: list[_Element], segment: str, namespaces: dict[str, str]) -> list[_Element]:
    result: list[_Element] = []
    for node in nodes:
        for child in node._children:
            if _segment_matches(child, segment, namespaces):
                result.append(child)
    return result


def _match_descendants(nodes: list[_Element], segment: str, namespaces: dict[str, str]) -> list[_Element]:
    result: list[_Element] = []
    for node in nodes:
        for candidate in node.iter():
            if candidate is node:
                continue
            if _segment_matches(candidate, segment, namespaces):
                result.append(candidate)
    return result


def _segment_matches(node: _Element, raw_segment: str, namespaces: dict[str, str]) -> bool:
    name, predicates = _split_predicates(raw_segment)
    if name and name != "*" and node.tag != _expand_name(name, namespaces):
        return False
    return all(_predicate_matches(node, predicate, namespaces) for predicate in predicates)


def _split_predicates(segment: str) -> tuple[str, list[str]]:
    name = segment.split("[", 1)[0]
    predicates = re.findall(r"\[([^\]]+)\]", segment)
    return name, predicates


def _split_path_segments(path: str) -> list[str]:
    segments: list[str] = []
    start = 0
    depth = 0
    quote: str | None = None
    for index, char in enumerate(path):
        if quote is not None:
            if char == quote:
                quote = None
            continue
        if char in ("'", '"'):
            quote = char
        elif char == "[":
            depth += 1
        elif char == "]" and depth:
            depth -= 1
        elif char == "/" and depth == 0:
            segments.append(path[start:index])
            start = index + 1
    segments.append(path[start:])
    return segments


def _predicate_matches(node: _Element, predicate: str, namespaces: dict[str, str]) -> bool:
    predicate = predicate.strip()
    exists_attr = re.fullmatch(r"@([A-Za-z_][\w.-]*(?::[A-Za-z_][\w.-]*)?)", predicate)
    if exists_attr:
        return node.get(_expand_name(exists_attr.group(1), namespaces)) is not None

    attr_eq = re.fullmatch(r"@([A-Za-z_][\w.-]*(?::[A-Za-z_][\w.-]*)?)\s*=\s*['\"]([^'\"]*)['\"]", predicate)
    if attr_eq:
        return node.get(_expand_name(attr_eq.group(1), namespaces)) == attr_eq.group(2)

    number_ge = re.fullmatch(r"number\(@([A-Za-z_][\w.-]*(?::[A-Za-z_][\w.-]*)?)\)\s*>=\s*([0-9.]+)", predicate)
    if number_ge:
        try:
            return float(node.get(_expand_name(number_ge.group(1), namespaces), "nan")) >= float(number_ge.group(2))
        except ValueError:
            return False

    child_text_eq = re.fullmatch(r"([A-Za-z_][\w.-]*(?::[A-Za-z_][\w.-]*)?)\s*=\s*['\"]([^'\"]*)['\"]", predicate)
    if child_text_eq:
        child_name = _expand_name(child_text_eq.group(1), namespaces)
        return any(child.tag == child_name and _string_value(child) == child_text_eq.group(2) for child in node._children)

    nested_text_eq = re.fullmatch(r"(.+)\s*=\s*['\"]([^'\"]*)['\"]", predicate)
    if nested_text_eq:
        matches = _select_path(node, nested_text_eq.group(1), namespaces)
        return any(_string_value(match) == nested_text_eq.group(2) for match in matches)

    return False


def _expand_name(name: str, namespaces: dict[str, str]) -> str:
    if name.startswith("{") or name == "*":
        return name
    if ":" in name:
        prefix, local = name.split(":", 1)
        uri = namespaces.get(prefix)
        return f"{{{uri}}}{local}" if uri else name
    return name
