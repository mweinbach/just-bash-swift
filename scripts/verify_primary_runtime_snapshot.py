#!/usr/bin/env python3
"""Resolve and verify one pinned, portable primary-runtime skill snapshot."""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_MANIFEST = REPO_ROOT / "Compatibility/primary-runtime.json"
DEFAULT_CACHE_ROOT = Path.home() / ".codex/plugins/cache/openai-primary-runtime"
FAMILIES = ("documents", "presentations", "spreadsheets")

def verify_snapshot(cache_root: Path, manifest_path: Path = DEFAULT_MANIFEST, roots: dict[str, Path] | None = None) -> dict:
    manifest = json.loads(manifest_path.read_text())
    if manifest.get("schemaVersion") != 1:
        raise ValueError("Unsupported compatibility manifest schema")
    version = manifest["snapshotVersion"]
    reports = []
    for family in FAMILIES:
        supplied = (roots or {}).get(family)
        if supplied is None:
            root = cache_root / family / version
        elif (supplied / "skills" / family / "SKILL.md").exists():
            root = supplied
        elif supplied.name == family:
            root = supplied / version
        else:
            root = supplied / family / version
        skill = root / "skills" / family / "SKILL.md"
        expected = manifest["families"][family]["skillSHA256"]
        actual = hashlib.sha256(skill.read_bytes()).hexdigest() if skill.is_file() else None
        errors = []
        if root.name != version:
            errors.append(f"Expected snapshot {version}, received {root.name}")
        if actual != expected:
            errors.append("SKILL.md SHA256 mismatch" if actual else "Pinned SKILL.md is missing")
        reports.append({"name": family, "root": str(root), "skillPath": str(skill), "status": "blocked" if errors else "ready", "expectedSHA256": expected, "actualSHA256": actual, "errors": errors})
    return {"snapshotVersion": version, "supportLevel": manifest["supportLevel"], "overall": "blocked" if any(r["errors"] for r in reports) else "ready", "reports": reports}

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cache-root", type=Path, default=DEFAULT_CACHE_ROOT)
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    args = parser.parse_args()
    report = verify_snapshot(args.cache_root, args.manifest)
    print(json.dumps(report, indent=2))
    return 0 if report["overall"] == "ready" else 1

if __name__ == "__main__":
    raise SystemExit(main())
