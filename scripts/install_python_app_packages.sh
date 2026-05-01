#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${ROOT_DIR}/Apps/JustBashPhone/PythonApp"
REQUIREMENTS="${1:-${APP_DIR}/requirements-default.txt}"
TARGET="${APP_DIR}/site-packages"
PYTHON_BIN="${PYTHON_BIN:-python3}"

if [[ ! -f "${REQUIREMENTS}" ]]; then
  echo "Python package requirements not found: ${REQUIREMENTS}" >&2
  exit 1
fi

mkdir -p "${TARGET}"
REQ_HASH="$(shasum -a 256 "${REQUIREMENTS}" | awk '{print $1}')"
MARKER="${TARGET}/.justbash-requirements.sha256"

if [[ "${JUSTBASH_PYTHON_PACKAGE_REFRESH:-0}" != "1" && -f "${MARKER}" ]]; then
  if [[ "$(cat "${MARKER}")" == "${REQ_HASH}" ]]; then
    echo "Default Python packages already installed in:"
    echo "  ${TARGET}"
    exit 0
  fi
fi

rm -rf "${TARGET}"
mkdir -p "${TARGET}"

"${PYTHON_BIN}" -m pip install \
  --upgrade \
  --ignore-installed \
  --target "${TARGET}" \
  --requirement "${REQUIREMENTS}" \
  --only-binary=:all: \
  --platform any \
  --implementation py \
  --python-version 314 \
  --abi none \
  --no-compile

find "${TARGET}" -name __pycache__ -type d -prune -exec rm -rf {} +
echo "${REQ_HASH}" > "${MARKER}"

echo
echo "Installed default Python packages:"
echo "  requirements: ${REQUIREMENTS}"
echo "  target:       ${TARGET}"
