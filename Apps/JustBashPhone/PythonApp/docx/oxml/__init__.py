from lxml import etree

from .ns import qn


def OxmlElement(tag: str):
    return etree.Element(qn(tag))


__all__ = ["OxmlElement", "qn"]
