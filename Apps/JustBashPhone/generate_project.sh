#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PYTHON_XCFRAMEWORK="${ROOT_DIR}/Vendor/BeeWare/Python.xcframework"

cd "${SCRIPT_DIR}"

SPEC_FILE="project.yml"
if [[ "${1:-}" == "--with-python" ]]; then
  if [[ ! -d "${PYTHON_XCFRAMEWORK}" ]]; then
    echo "BeeWare Python support not found at:" >&2
    echo "  ${PYTHON_XCFRAMEWORK}" >&2
    echo "Install it first with ./scripts/install_beeware_python_support.sh" >&2
    exit 1
  fi
  SPEC_FILE="project.python.yml"
fi

xcodegen generate -s "${SPEC_FILE}"
