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
    soffice_path = shutil.which("soffice") or shutil.which("libreoffice")

    return {
        "platform": "ios",
        "workspace": str(workspace_path),
        "python": python,
        "skills": {
            "documents": {
                "status": "blocked",
                "python_modules": [_module_status(name) for name in documents_modules],
                "external_binaries": {
                    "soffice_or_libreoffice": soffice_path,
                },
                "blockers": [
                    "render_docx.py requires soffice/LibreOffice through subprocess",
                    "pdf2image typically requires Poppler binaries",
                    "required Python packages are not part of the default iOS bundle",
                ],
            },
            "presentations": {
                "status": "blocked",
                "blockers": [
                    "cached scripts require static ESM import/export loading",
                    "cached scripts require @oai/artifact-tool/presentation-jsx",
                    "cached scripts depend on native/npm packages that are not bundled for iOS",
                ],
            },
            "spreadsheets": {
                "status": "blocked",
                "python_modules": [_module_status(name) for name in spreadsheet_modules],
                "blockers": [
                    "cached skill requires @oai/artifact-tool workbook APIs",
                    "Node-style workspace dependency resolution is not available on iOS",
                ],
            },
        },
    }


def main() -> None:
    report = build_report()
    print(json.dumps(report, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
