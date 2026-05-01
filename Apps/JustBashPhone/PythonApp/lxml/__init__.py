"""Small pure-Python lxml compatibility surface for the iOS Python bundle.

This package intentionally implements the subset of ``lxml.etree`` used by the
cached primary-runtime document helpers. It is not a drop-in replacement for the
native lxml package.
"""

from . import etree

__all__ = ["etree"]
