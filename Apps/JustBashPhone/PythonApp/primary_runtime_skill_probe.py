"""On-device capability probe for primary-runtime artifact skills.

This module is intentionally small and pure Python so the BeeWare-backed iOS
host can import it from the app bundle. It does not install or register skills;
it reports the runtime pieces that the cached Documents, Presentations, and
Spreadsheets skills need before they can run on iOS.
"""

from __future__ import annotations

import importlib.util
import json
import shutil
import sys
from pathlib import Path


def _module_status(import_name: str) -> dict[str, object]:
    spec = importlib.util.find_spec(import_name)
    return {
        "name": import_name,
        "available": spec is not None,
        "origin": getattr(spec, "origin", None) if spec is not None else None,
    }


def _missing_modules(statuses: list[dict[str, object]]) -> list[str]:
    return [str(item["name"]) for item in statuses if not item["available"]]


def _documents_blockers(missing_modules: list[str]) -> list[str]:
    blockers = [
        "render_docx.py requires soffice/LibreOffice through subprocess",
        "pdf2image typically requires Poppler binaries",
    ]
    if missing_modules:
        blockers.append("missing required Python modules: " + ", ".join(missing_modules))
    else:
        blockers.append("all detected document Python modules are importable")
    if "docx" in missing_modules or "lxml" in missing_modules:
        blockers.append(
            "Documents helpers require real lxml/python-docx OOXML behavior; a shallow import shim is not sufficient"
        )
    return blockers


def build_report(workspace: str | None = None) -> dict[str, object]:
    workspace_path = Path(workspace or Path.cwd()).resolve()
    python = {
        "available": True,
        "version": sys.version,
        "executable": sys.executable,
        "workspace": str(workspace_path),
    }

    documents_modules = ["docx", "lxml", "openpyxl", "PIL", "pdf2image"]
    spreadsheet_modules = ["pandas", "numpy", "pypdf", "docx", "reportlab"]
    documents_module_statuses = [_module_status(name) for name in documents_modules]
    spreadsheet_module_statuses = [_module_status(name) for name in spreadsheet_modules]
    documents_missing = _missing_modules(documents_module_statuses)
    spreadsheet_missing = _missing_modules(spreadsheet_module_statuses)
    soffice_path = shutil.which("soffice") or shutil.which("libreoffice")
    poppler_path = shutil.which("pdftoppm") or shutil.which("pdftocairo")

    return {
        "platform": "ios",
        "workspace": str(workspace_path),
        "python": python,
        "skills": {
            "documents": {
                "status": "blocked",
                "python_modules": documents_module_statuses,
                "external_binaries": {
                    "soffice_or_libreoffice": soffice_path,
                    "poppler_pdf_renderer": poppler_path,
                },
                "blockers": _documents_blockers(documents_missing),
            },
            "presentations": {
                "status": "blocked",
                "blockers": [
                    "limited pure-JS @oai/artifact-tool compatibility is staged by the iOS host",
                    "basic presentation PNG rendering and layout JSON are staged; full-fidelity rendering still needs a real iOS renderer",
                    "full-fidelity rendering still depends on native/npm artifact-tool paths not ported to iOS",
                    "JavaScript helper scripts can invoke host-provided python3 through child_process; Python subprocess fan-out still needs an in-process iOS adapter",
                    "ctx.addLucideIcon can use the staged pure-JS lucide SVG package; standalone PNG icon rendering still requires sharp or skia-canvas native graphics packages",
                ],
            },
            "spreadsheets": {
                "status": "blocked",
                "python_modules": spreadsheet_module_statuses,
                "blockers": [
                    "limited pure-JS @oai/artifact-tool workbook export plus common structural spreadsheet API compatibility, including table/chart/comment/sparkline stubs, is staged",
                    "limited uncompressed .xlsx import/export and basic workbook PNG rendering are staged; full artifact-tool inspection/render behavior is not ported to iOS",
                    "spreadsheet completion criteria require formula computation, formula-error scans, and real trace output; the iOS compatibility package only stores formulas structurally",
                    "spreadsheet chart and dashboard workflows require native Excel charts plus rendered visual verification; the iOS compatibility package does not export or render real charts",
                    (
                        "missing optional spreadsheet Python modules: " + ", ".join(spreadsheet_missing)
                        if spreadsheet_missing
                        else "all optional spreadsheet Python modules are importable"
                    ),
                ],
            },
        },
    }


def main() -> None:
    report = build_report()
    print(json.dumps(report, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
