#!/usr/bin/env python3
"""Check whether cached primary-runtime artifact skills are iOS-runnable here.

This script intentionally does not install or register the skills. It inspects
the cached skill bundles plus the current repo's iOS runtime surface and reports
whether the Documents, Presentations, and Spreadsheets skills can run unchanged
inside the iOS host.
"""

from __future__ import annotations

import argparse
import ast
import json
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable


REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CACHE_ROOT = Path("/Users/mweinbach/.codex/plugins/cache/openai-primary-runtime")
DEFAULT_ARTIFACT_TOOL = (
    Path("/Users/mweinbach/.cache/codex-runtimes/codex-primary-runtime")
    / "dependencies/node/node_modules/@oai/artifact-tool"
)


@dataclass
class Finding:
    status: str
    message: str
    evidence: list[str] = field(default_factory=list)


@dataclass
class SkillReport:
    name: str
    root: Path
    findings: list[Finding] = field(default_factory=list)

    @property
    def blocked(self) -> bool:
        return any(f.status == "blocked" for f in self.findings)

    def add(self, status: str, message: str, evidence: Iterable[str] = ()) -> None:
        self.findings.append(Finding(status=status, message=message, evidence=list(evidence)))


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def line_for(path: Path, needle: str) -> str:
    try:
        for index, line in enumerate(read_text(path).splitlines(), start=1):
            if needle in line:
                return f"{path}:{index}"
    except FileNotFoundError:
        pass
    return str(path)


def line_for_any(path: Path, needles: Iterable[str]) -> str:
    for needle in needles:
        location = line_for(path, needle)
        if location != str(path):
            return location
    return str(path)


def load_requirements(path: Path) -> set[str]:
    packages: set[str] = set()
    if not path.exists():
        return packages
    for raw in read_text(path).splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        name = re.split(r"[<>=!~;\\[]", line, maxsplit=1)[0].strip().lower()
        if name:
            packages.add(name)
    return packages


def python_import_roots(root: Path) -> set[str]:
    imports: set[str] = set()
    for path in sorted(root.rglob("*.py")):
        try:
            tree = ast.parse(read_text(path), filename=str(path))
        except SyntaxError:
            continue
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                for alias in node.names:
                    imports.add(alias.name.split(".", 1)[0])
            elif isinstance(node, ast.ImportFrom) and node.module:
                imports.add(node.module.split(".", 1)[0])
    return imports


def js_import_specs(root: Path) -> set[str]:
    specs: set[str] = set()
    pattern = re.compile(
        r"import\s+(?:[^\"']+?\s+from\s+)?[\"']([^\"']+)[\"']|"
        r"require\([\"']([^\"']+)[\"']\)"
    )
    for path in sorted(root.rglob("*.mjs")):
        text = read_text(path)
        for esm, cjs in pattern.findall(text):
            specs.add(esm or cjs)
    return specs


def version_key(path: Path) -> tuple[int, ...]:
    parts = [int(part) for part in re.findall(r"\d+", path.name)]
    return tuple(parts) if parts else (0,)


def resolve_cached_plugin_root(cache_root: Path, family: str, plugin_name: str) -> Path:
    """Find the cached version directory for a skill family.

    Accepts either the primary-runtime cache root, a family directory such as
    `.../documents`, or a concrete version directory.
    """

    candidates: list[Path] = []
    direct_skill = cache_root / "skills" / plugin_name / "SKILL.md"
    if (cache_root / ".codex-plugin" / "plugin.json").exists() and direct_skill.exists():
        candidates.append(cache_root)

    family_root = cache_root if cache_root.name == family else cache_root / family
    if family_root.exists():
        for child in family_root.iterdir():
            skill_md = child / "skills" / plugin_name / "SKILL.md"
            plugin_json = child / ".codex-plugin" / "plugin.json"
            if child.is_dir() and skill_md.exists() and plugin_json.exists():
                candidates.append(child)

    if not candidates:
        return family_root / "missing"
    return sorted(candidates, key=version_key)[-1]


def documents_ooxml_evidence(skill_dir: Path) -> list[str]:
    """Return representative uses that need real lxml/python-docx behavior."""

    candidates = [
        (skill_dir / "scripts" / "docx_ooxml_patch.py", ["etree.XMLParser", ".addnext(", "OxmlElement"]),
        (skill_dir / "scripts" / "content_controls.py", ['xpath("string(', ".xpath(", "etree.XMLParser"]),
        (skill_dir / "scripts" / "table_geometry.py", ["OxmlElement"]),
        (skill_dir / "scripts" / "xlsx_to_docx_table.py", ["Document()", "OxmlElement"]),
    ]
    evidence: list[str] = []
    for path, needles in candidates:
        if path.exists():
            evidence.append(line_for_any(path, needles))
    return evidence


def artifact_tool_evidence(artifact_tool_root: Path) -> list[str]:
    evidence = [str(artifact_tool_root / "package.json")]
    if (artifact_tool_root / "dist" / "artifact_tool.mjs").exists():
        evidence.append(str(artifact_tool_root / "dist" / "artifact_tool.mjs"))
    skia = artifact_tool_root / "node_modules" / "skia-canvas"
    if skia.exists():
        evidence.append(str(skia / "package.json"))
        if (skia / "lib" / "skia.node").exists():
            evidence.append(str(skia / "lib" / "skia.node"))
    walnut_wasm = artifact_tool_root / "node_modules" / "@oai" / "walnut" / "wasm"
    if walnut_wasm.exists():
        evidence.append(str(walnut_wasm))
        if (walnut_wasm / "dotnet.js").exists():
            evidence.append(str(walnut_wasm / "dotnet.js"))
        if (walnut_wasm / "blazor.boot.json").exists():
            evidence.append(str(walnut_wasm / "blazor.boot.json"))
    return evidence


def artifact_tool_compat_evidence() -> list[str]:
    sandbox_service = REPO_ROOT / "Apps/JustBashPhone/JustBashPhone/SandboxService.swift"
    evidence = [
        line_for(sandbox_service, "primaryRuntimeArtifactToolFiles"),
        line_for(sandbox_service, '"/node_modules/@oai/artifact-tool"'),
        line_for(sandbox_service, "artifactToolCompatModule"),
    ]
    return evidence


def artifact_tool_package_shape(artifact_tool_root: Path) -> tuple[dict | None, list[str]]:
    package_json = artifact_tool_root / "package.json"
    evidence = [str(package_json)]
    try:
        package = json.loads(read_text(package_json))
    except Exception:
        return None, evidence
    exports = package.get("exports")
    if exports is not None:
        evidence.append(f"{package_json}:exports")
    return package, evidence


def check_artifact_tool_runtime(
    report: SkillReport,
    skill_md: Path,
    message: str,
    artifact_tool_root: Path,
) -> None:
    if "@oai/artifact-tool" not in read_text(skill_md):
        return

    require_resolver = REPO_ROOT / "Sources/JustBashJavaScript/Bridges/RequireResolver.swift"
    resolver_text = read_text(require_resolver)
    if "transformTopLevelModuleSyntax" in resolver_text and "pickPackageExport" in resolver_text:
        report.add(
            "ok",
            "js-exec handles artifact-tool's bundled/minified ESM shape and nested package export conditions",
            [str(require_resolver), str(artifact_tool_root / "dist" / "artifact_tool.mjs")],
        )

    sandbox_service = REPO_ROOT / "Apps/JustBashPhone/JustBashPhone/SandboxService.swift"
    sandbox_text = read_text(sandbox_service)
    if (
        "primaryRuntimeArtifactToolFiles" in sandbox_text
        and "artifactToolCompatModule" in sandbox_text
        and "/node_modules/@oai/artifact-tool" in sandbox_text
    ):
        report.add(
            "ok",
            "iOS host stages a limited pure-JS @oai/artifact-tool compatibility package for direct imports, presentation-jsx, and basic xlsx/pptx export smoke checks",
            artifact_tool_compat_evidence(),
        )

    spreadsheet_structural_methods = ("getOrAdd", "getUsedRange", "copyFrom", "copyTo", "trace(address)")
    if all(method in sandbox_text for method in spreadsheet_structural_methods):
        report.add(
            "ok",
            "iOS artifact-tool compatibility covers common spreadsheet structural APIs such as worksheet getOrAdd/getUsedRange, range copy/write helpers, and workbook trace stubs",
            artifact_tool_compat_evidence(),
        )

    if "unsupportedArtifactToolFeature" in sandbox_text:
        report.add(
            "blocked",
            "iOS artifact-tool compatibility explicitly rejects full render/import APIs required by these skills instead of returning fake visual verification",
            [
                line_for(sandbox_service, "unsupportedArtifactToolFeature"),
                line_for(sandbox_service, "Presentation.export"),
                line_for(sandbox_service, "Workbook.render"),
                line_for(sandbox_service, "SpreadsheetFile.importXlsx"),
            ],
        )

    package, package_evidence = artifact_tool_package_shape(artifact_tool_root)
    if package is not None:
        export_text = json.dumps(package.get("exports", {}), sort_keys=True)
        supported_conditions = ("browser", "ios", "react-native")
        if not any(condition in export_text for condition in supported_conditions):
            version = package.get("version", "unknown")
            report.add(
                "blocked",
                f"artifact-tool {version} exposes no browser/iOS export condition; the iOS host must use the limited compatibility package or a native-backed port",
                package_evidence,
            )

    report.add(
        "blocked",
        message,
        [line_for(skill_md, "@oai/artifact-tool"), *artifact_tool_evidence(artifact_tool_root)],
    )

    skia_node = artifact_tool_root / "node_modules" / "skia-canvas" / "lib" / "skia.node"
    if skia_node.exists():
        report.add(
            "blocked",
            "artifact-tool bundles skia-canvas with a native Node addon; iOS needs a signed in-process renderer or Swift/CoreGraphics adapter",
            [str(skia_node), str(artifact_tool_root / "node_modules" / "skia-canvas" / "package.json")],
        )

    walnut_wasm = artifact_tool_root / "node_modules" / "@oai" / "walnut" / "wasm"
    if walnut_wasm.exists():
        report.add(
            "blocked",
            "artifact-tool's Walnut document import/export path uses a .NET WASM payload and dotnet.js resource loader that are not packaged or bridged for JavaScriptCore on iOS",
            [str(walnut_wasm / "dotnet.js"), str(walnut_wasm / "blazor.boot.json")],
        )


def validate_plugin(report: SkillReport, plugin_name: str) -> Path | None:
    plugin_json = report.root / ".codex-plugin" / "plugin.json"
    skill_dir = report.root / "skills" / plugin_name
    skill_md = skill_dir / "SKILL.md"
    try:
        plugin = json.loads(read_text(plugin_json))
    except Exception as exc:  # noqa: BLE001 - diagnostic script.
        report.add("blocked", f"plugin.json is not readable JSON: {exc}", [str(plugin_json)])
        return None
    if plugin.get("skills") != "./skills/":
        report.add("warning", "plugin skills path is not the expected ./skills/ value", [str(plugin_json)])
    if not skill_md.exists():
        report.add("blocked", "skill entrypoint is missing", [str(skill_md)])
        return None
    report.add("ok", "cached plugin and skill entrypoint are present", [str(plugin_json), str(skill_md)])
    return skill_dir


def check_documents(cache_root: Path, root: Path | None = None) -> SkillReport:
    root = root or resolve_cached_plugin_root(cache_root, "documents", "documents")
    report = SkillReport("documents", root)
    skill_dir = validate_plugin(report, "documents")
    if skill_dir is None:
        return report

    skill_md = skill_dir / "SKILL.md"
    render_py = skill_dir / "render_docx.py"
    imports = python_import_roots(skill_dir)
    py_pkg_map = {
        "docx": "python-docx",
        "lxml": "lxml",
        "PIL": "Pillow",
        "pdf2image": "pdf2image",
        "openpyxl": "openpyxl",
    }
    required = {py_pkg_map[name] for name in py_pkg_map if name in imports}
    default_reqs = load_requirements(REPO_ROOT / "Apps/JustBashPhone/PythonApp/requirements-default.txt")
    native_reqs = load_requirements(REPO_ROOT / "Apps/JustBashPhone/PythonApp/requirements-native-ios.txt")
    missing = sorted(pkg for pkg in required if pkg.lower() not in default_reqs and pkg.lower() not in native_reqs)
    if missing:
        report.add(
            "blocked",
            "iOS Python bundle does not stage required Documents packages: " + ", ".join(missing),
            [
                str(REPO_ROOT / "Apps/JustBashPhone/PythonApp/requirements-default.txt"),
                str(REPO_ROOT / "Apps/JustBashPhone/PythonApp/requirements-native-ios.txt"),
            ],
        )
        if "lxml" in {pkg.lower() for pkg in missing} or "python-docx" in {pkg.lower() for pkg in missing}:
            report.add(
                "blocked",
                "Documents helpers require real lxml/python-docx OOXML behavior; a shallow import shim is not sufficient",
                documents_ooxml_evidence(skill_dir),
            )
    else:
        report.add("ok", "all detected Python packages are declared for iOS staging")

    render_text = read_text(render_py)
    if "soffice" in render_text:
        report.add(
            "blocked",
            "DOCX render QA shells out to soffice/LibreOffice, which is not available in the iOS runtime",
            [line_for(render_py, '"soffice"')],
        )
    if "subprocess.run" in render_text:
        report.add(
            "blocked",
            "Documents render path uses subprocess execution; iOS host needs in-process render/adapters",
            [line_for(render_py, "subprocess.run")],
        )
    report.add(
        "info",
        "skill contract requires Codex workspace dependencies rather than system Python",
        [line_for(skill_md, "Use Codex workspace dependencies")],
    )
    return report


def check_presentations(
    cache_root: Path,
    artifact_tool_root: Path,
    root: Path | None = None,
) -> SkillReport:
    root = root or resolve_cached_plugin_root(cache_root, "presentations", "presentations")
    report = SkillReport("presentations", root)
    skill_dir = validate_plugin(report, "presentations")
    if skill_dir is None:
        return report

    specs = js_import_specs(skill_dir)
    node_specs = sorted(s for s in specs if s.startswith("node:"))
    if node_specs:
        require_resolver = REPO_ROOT / "Sources/JustBashJavaScript/Bridges/RequireResolver.swift"
        resolver_text = read_text(require_resolver)
        if "normalizeBuiltinName" in resolver_text and "fs/promises" in resolver_text:
            report.add(
                "ok",
                "JavaScriptCore require() resolves Node builtin specifier aliases used by scripts: "
                + ", ".join(node_specs),
                [str(require_resolver)],
            )
        else:
            report.add(
                "blocked",
                "presentation scripts import Node builtin specifiers that require() does not resolve: "
                + ", ".join(node_specs),
                [str(skill_dir / "scripts" / "build_artifact_deck.mjs")],
            )
    if list(skill_dir.rglob("*.mjs")):
        require_resolver = REPO_ROOT / "Sources/JustBashJavaScript/Bridges/RequireResolver.swift"
        resolver_text = read_text(require_resolver)
        engine_text = read_text(REPO_ROOT / "Sources/JustBashJavaScript/JSCEngine.swift")
        if "__jb_transpile_esm" in resolver_text and "__jb_dynamic_import" in resolver_text and "transpile.call" in engine_text:
            report.add(
                "ok",
                "js-exec has ESM compatibility for .mjs entrypoints, relative imports, and dynamic import()",
                [
                    str(require_resolver),
                    str(REPO_ROOT / "Sources/JustBashJavaScript/JSCEngine.swift"),
                ],
            )
        else:
            report.add(
                "blocked",
                "presentation helpers are ESM .mjs files with static import/export; js-exec does not provide an ESM loader",
                [
                    str(skill_dir / "scripts" / "build_artifact_deck.mjs"),
                    str(REPO_ROOT / "Sources/JustBashJavaScript/JSCEngine.swift"),
                ],
            )
        if "resolvePackage" in resolver_text and "nodeModuleBases" in resolver_text:
            report.add(
                "ok",
                "JavaScriptCore require/import can resolve sandboxed node_modules packages with package.json exports",
                [str(require_resolver)],
            )
        else:
            report.add(
                "blocked",
                "presentation helpers need package.json/node_modules package resolution for artifact-tool subpaths",
                [str(require_resolver), str(skill_dir / "scripts" / "build_artifact_deck.mjs")],
            )
    skill_md = skill_dir / "SKILL.md"
    check_artifact_tool_runtime(
        report,
        skill_md,
        "@oai/artifact-tool is required; the iOS host has a limited compatibility package, but the full native rendering/import stack is not ported",
        artifact_tool_root,
    )
    if any("child_process" in spec for spec in specs) or "node:child_process" in specs:
        report.add(
            "ok",
            "repo has a virtual child_process bridge; spawned programs are limited to sandbox commands provided by the host",
            [str(REPO_ROOT / "Sources/JustBashJavaScript/Bridges/ChildProcessBridge.swift")],
        )
    return report


def check_spreadsheets(
    cache_root: Path,
    artifact_tool_root: Path,
    root: Path | None = None,
) -> SkillReport:
    root = root or resolve_cached_plugin_root(cache_root, "spreadsheets", "spreadsheets")
    report = SkillReport("spreadsheets", root)
    skill_dir = validate_plugin(report, "spreadsheets")
    if skill_dir is None:
        return report

    skill_md = skill_dir / "SKILL.md"
    text = read_text(skill_md)
    require_resolver = REPO_ROOT / "Sources/JustBashJavaScript/Bridges/RequireResolver.swift"
    resolver_text = read_text(require_resolver)
    if "resolvePackage" in resolver_text and "nodeModuleBases" in resolver_text:
        report.add(
            "ok",
            "JavaScriptCore require/import can resolve sandboxed node_modules packages with package.json exports",
            [str(require_resolver)],
        )
    else:
        report.add(
            "blocked",
            "spreadsheet authoring needs package.json/node_modules package resolution for artifact-tool subpaths",
            [str(require_resolver), str(skill_md)],
        )
    check_artifact_tool_runtime(
        report,
        skill_md,
        "@oai/artifact-tool is required for workbook authoring/export; the iOS host has a limited compatibility package, but full inspection/render/import behavior is not ported",
        artifact_tool_root,
    )
    optional_py = {"pandas", "numpy", "pypdf", "python-docx", "reportlab"}
    default_reqs = load_requirements(REPO_ROOT / "Apps/JustBashPhone/PythonApp/requirements-default.txt")
    native_reqs = load_requirements(REPO_ROOT / "Apps/JustBashPhone/PythonApp/requirements-native-ios.txt")
    staged = default_reqs | native_reqs
    missing = sorted(pkg for pkg in optional_py if pkg.lower() not in staged)
    if missing:
        report.add(
            "warning",
            "optional spreadsheet extraction packages are not fully staged for iOS: " + ", ".join(missing),
            [line_for(skill_md, "Bundled Python libraries available")],
        )
    return report


def check_repo_runtime(reports: list[SkillReport]) -> None:
    package = read_text(REPO_ROOT / "Package.swift")
    js_runtime = REPO_ROOT / "Sources/JustBashJavaScript/JavaScriptRuntime.swift"
    if "JustBashJavaScript" in package and js_runtime.exists():
        for report in reports:
            report.add("ok", "repo has the JavaScriptCore-backed JustBashJavaScript runtime", [str(js_runtime)])

    py_support = REPO_ROOT / "Apps/JustBashPhone/JustBashPhone/PythonSupport.swift"
    if py_support.exists():
        for report in reports:
            report.add("info", "repo has host-only BeeWare Python support for the iPhone app", [str(py_support)])


def to_json(reports: list[SkillReport]) -> str:
    payload = {
        "platform": "ios",
        "overall": "blocked" if any(r.blocked for r in reports) else "ready",
        "reports": [
            {
                "name": report.name,
                "root": str(report.root),
                "status": "blocked" if report.blocked else "ready",
                "findings": [
                    {
                        "status": finding.status,
                        "message": finding.message,
                        "evidence": finding.evidence,
                    }
                    for finding in report.findings
                ],
            }
            for report in reports
        ],
    }
    return json.dumps(payload, indent=2, sort_keys=True)


def print_text(reports: list[SkillReport]) -> None:
    overall = "blocked" if any(r.blocked for r in reports) else "ready"
    print(f"Primary runtime skill iOS readiness: {overall}")
    for report in reports:
        status = "blocked" if report.blocked else "ready"
        print(f"\n[{report.name}] {status}")
        for finding in report.findings:
            print(f"- {finding.status}: {finding.message}")
            for evidence in finding.evidence:
                print(f"  evidence: {evidence}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cache-root", type=Path, default=DEFAULT_CACHE_ROOT)
    parser.add_argument("--documents-root", type=Path, help="documents family or version directory")
    parser.add_argument("--presentations-root", type=Path, help="presentations family or version directory")
    parser.add_argument("--spreadsheets-root", type=Path, help="spreadsheets family or version directory")
    parser.add_argument(
        "--artifact-tool-root",
        type=Path,
        default=DEFAULT_ARTIFACT_TOOL,
        help="cached @oai/artifact-tool package directory",
    )
    parser.add_argument("--json", action="store_true", help="emit machine-readable JSON")
    parser.add_argument("--strict", action="store_true", help="exit non-zero when any iOS blocker is found")
    args = parser.parse_args()

    documents_root = (
        resolve_cached_plugin_root(args.documents_root, "documents", "documents")
        if args.documents_root
        else None
    )
    presentations_root = (
        resolve_cached_plugin_root(args.presentations_root, "presentations", "presentations")
        if args.presentations_root
        else None
    )
    spreadsheets_root = (
        resolve_cached_plugin_root(args.spreadsheets_root, "spreadsheets", "spreadsheets")
        if args.spreadsheets_root
        else None
    )

    reports = [
        check_documents(args.cache_root, documents_root),
        check_presentations(args.cache_root, args.artifact_tool_root, presentations_root),
        check_spreadsheets(args.cache_root, args.artifact_tool_root, spreadsheets_root),
    ]
    check_repo_runtime(reports)

    if args.json:
        print(to_json(reports))
    else:
        print_text(reports)

    if args.strict and any(report.blocked for report in reports):
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
