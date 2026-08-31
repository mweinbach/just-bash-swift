#!/usr/bin/env python3
"""Verify the pinned skill snapshot and declare the bounded mobile API contract.

This is a static contract check, not an execution or desktop-helper readiness
claim. Run the JavaScriptCore tests for runtime verification. Python is optional.
"""
from __future__ import annotations
import argparse
import json
from pathlib import Path
from verify_primary_runtime_snapshot import DEFAULT_CACHE_ROOT, DEFAULT_MANIFEST, REPO_ROOT, verify_snapshot

CAPABILITIES = {
    "documents": {"supported": ["styled paragraphs", "rectangular tables", "literal text replacement", "preserved imported OOXML package parts"], "unsupported": ["pagination", "rendering", "desktop Python helpers"]},
    "presentations": {"supported": ["positioned rect/ellipse shapes", "uniform text styles", "PNG/JPEG/SVG embedding", "PPTX import/export", "native PNG/JPEG previews", "layout JSON"], "unsupported": ["tables", "custom masters", "animation", "mixed text-run styling", "SVG raster preview"]},
    "spreadsheets": {"supported": ["values and bounded Excel formulas", "persistent styles", "merges", "tables", "freeze panes", "literal list validation", "comments", "line/bar/column chart export", "native cell preview", "XLSX import/export"], "unsupported": ["full Excel calculation", "pivot tables", "macros", "conditional formatting", "sparklines", "native chart preview"]},
}

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cache-root", type=Path, default=DEFAULT_CACHE_ROOT)
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    for family in CAPABILITIES:
        parser.add_argument(f"--{family}-root", type=Path)
    parser.add_argument("--artifact-tool-root", type=Path, help="Optional desktop package location; not required by the mobile shim")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--strict", action="store_true")
    args = parser.parse_args()
    roots = {family: getattr(args, family + "_root") for family in CAPABILITIES if getattr(args, family + "_root") is not None}
    report = verify_snapshot(args.cache_root, args.manifest, roots)
    report.update(platform="ios", assessment="static-compatibility-scan", runtimeVerified=False, pythonRequired=False)
    runtime = REPO_ROOT / "Sources/JustBash/Resources/artifact-tool.mjs"
    if not runtime.is_file():
        report["overall"] = "blocked"
        report["runtimeError"] = "Bundled mobile artifact runtime is missing"
    for family in report["reports"]:
        family["capabilities"] = CAPABILITIES[family["name"]]
        family["findings"] = [{"status": "blocked", "message": error} for error in family["errors"]]
    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print(f"Pinned mobile skill contract: {report['overall']} ({report['snapshotVersion']}); execution not verified")
        for item in report["reports"]:
            print(f"- {item['name']}: {item['status']}" + ("; " + "; ".join(item["errors"]) if item["errors"] else ""))
    return 1 if args.strict and report["overall"] != "ready" else 0

if __name__ == "__main__":
    raise SystemExit(main())
