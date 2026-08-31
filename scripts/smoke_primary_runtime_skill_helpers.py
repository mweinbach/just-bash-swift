#!/usr/bin/env python3
"""Exercise the bounded iOS artifact API with self-contained fixtures.

Default checks need Node and Python stdlib, not a personal Codex installation.
Desktop Python helpers are outside this runtime contract.
JavaScriptCore/on-device coverage lives in the Swift test target.
"""
from __future__ import annotations
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
RUNTIME_SUPPORT = REPO_ROOT / "Sources/JustBash/OAIPrimaryRuntimeSupport.swift"
IOS_PYTHON_APP = REPO_ROOT / "Apps/JustBashPhone/PythonApp"
FIXTURES = REPO_ROOT / "Tests/JustBashJavaScriptTests/Fixtures"

SWIFT_STRING_NAMES = [
    "artifactToolPackageJSON",
    "artifactToolCompatModule",
    "presentationJSXCompatModule",
    "presentationJSXRuntimeCompatModule",
    "lucidePackageJSON",
    "lucideCompatModule",
    "sharpPackageJSON",
    "sharpCompatModule",
]


def extract_swift_raw_strings(source: str) -> dict[str, str]:
    values: dict[str, str] = {}
    for name in SWIFT_STRING_NAMES:
        if name == "artifactToolCompatModule":
            values[name] = (REPO_ROOT / "Sources/JustBash/Resources/artifact-tool.mjs").read_text()
            continue
        pattern = rf"private static let {re.escape(name)} = #\"\"\"\n(.*?)\n    \"\"\"#"
        match = re.search(pattern, source, flags=re.S)
        if not match:
            raise RuntimeError(f"Could not extract {name} from {RUNTIME_SUPPORT}")
        values[name] = match.group(1)
    return values


def write_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def stage_runtime(home: Path, strings: dict[str, str]) -> Path:
    node_modules = (
        home
        / ".cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules"
    )

    artifact_root = node_modules / "@oai/artifact-tool"
    write_text(artifact_root / "package.json", strings["artifactToolPackageJSON"])
    write_text(artifact_root / "dist/artifact_tool.mjs", strings["artifactToolCompatModule"])
    write_text(artifact_root / "dist/presentation-jsx/index.mjs", strings["presentationJSXCompatModule"])
    write_text(
        artifact_root / "dist/presentation-jsx/jsx-runtime.mjs",
        strings["presentationJSXRuntimeCompatModule"],
    )
    write_text(
        artifact_root / "dist/presentation-jsx/jsx-dev-runtime.mjs",
        strings["presentationJSXRuntimeCompatModule"],
    )

    lucide_root = node_modules / "lucide"
    write_text(lucide_root / "package.json", strings["lucidePackageJSON"])
    write_text(lucide_root / "dist/index.mjs", strings["lucideCompatModule"])

    sharp_root = node_modules / "sharp"
    write_text(sharp_root / "package.json", strings["sharpPackageJSON"])
    write_text(sharp_root / "index.js", strings["sharpCompatModule"])

    return node_modules


def run_command(
    command: list[str],
    *,
    cwd: Path,
    env: dict[str, str],
    label: str,
) -> dict[str, object]:
    proc = subprocess.run(
        command,
        cwd=cwd,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    return {
        "label": label,
        "command": command,
        "cwd": str(cwd),
        "exitCode": proc.returncode,
        "stdout": proc.stdout,
        "stderr": proc.stderr,
    }


def require_success(result: dict[str, object]) -> None:
    if result["exitCode"] != 0:
        raise RuntimeError(
            "\n".join(
                [
                    f"{result['label']} failed with exit {result['exitCode']}",
                    "command: " + " ".join(str(part) for part in result["command"]),
                    "stdout:",
                    str(result["stdout"]),
                    "stderr:",
                    str(result["stderr"]),
                ]
            )
        )


def build_report(workdir: Path) -> dict[str, object]:
    strings = extract_swift_raw_strings(RUNTIME_SUPPORT.read_text(encoding="utf-8"))
    modules = stage_runtime(workdir / "runtime", strings)
    (workdir / "node_modules").symlink_to(modules, target_is_directory=True)
    checks = []
    for name in ["presentation", "spreadsheet", "artifact-correctness"]:
        script = workdir / (f"{name}-smoke.mjs" if name != "artifact-correctness" else "artifact-correctness.mjs")
        shutil.copyfile(FIXTURES / script.name, script)
        result = run_command(["node", str(script)], cwd=workdir, env=os.environ.copy(), label=name)
        checks.append({"name": name, "status": "ok" if result["exitCode"] == 0 else "failed", **result})
    # The spreadsheet fixture also verifies real DOCX import/export, and compressed XLSX.
    for name, member in [("deck.pptx", "ppt/slides/slide1.xml"), ("dashboard.xlsx", "xl/worksheets/sheet1.xml")]:
        try:
            with zipfile.ZipFile(workdir / "output" / name) as archive:
                data = archive.read(member)
                if not data: raise ValueError("Empty Office XML")
            checks.append({"name": name + ".ooxml", "status": "ok"})
        except Exception as error:
            checks.append({"name": name + ".ooxml", "status": "failed", "error": str(error)})
    return {"overall": "ok" if all(c["status"] == "ok" for c in checks) else "failed", "supportLevel": "bounded-ios-compatibility", "checks": checks}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--keep-workdir", action="store_true")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="justbash-artifacts-") as temporary:
        workdir = Path(temporary)
        report = build_report(workdir)
        if args.keep_workdir:
            kept = Path(tempfile.mkdtemp(prefix="justbash-artifacts-kept-"))
            shutil.copytree(workdir, kept, dirs_exist_ok=True)
            report["keptWorkdir"] = str(kept)
    print(json.dumps(report, indent=2) if args.json else "Artifact API smoke: " + report["overall"])
    return 0 if report["overall"] == "ok" else 1

if __name__ == "__main__":
    raise SystemExit(main())
