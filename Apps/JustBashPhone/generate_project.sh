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
  if [[ "${JUSTBASH_PHONE_SKIP_PYTHON_PACKAGES:-0}" != "1" ]]; then
    "${ROOT_DIR}/scripts/install_python_app_packages.sh"
  fi
  SPEC_FILE="project.python.yml"
fi

TEMP_SPEC=""
cleanup() {
  if [[ -n "${TEMP_SPEC}" && -f "${TEMP_SPEC}" ]]; then
    rm -f "${TEMP_SPEC}"
  fi
}
trap cleanup EXIT

if [[ -n "${JUSTBASH_PHONE_DEVELOPMENT_TEAM:-}" || -n "${JUSTBASH_PHONE_BUNDLE_ID:-}" ]]; then
  TEMP_SPEC="${SCRIPT_DIR}/.project.override.yml"
  cp "${SPEC_FILE}" "${TEMP_SPEC}"

  if [[ -n "${JUSTBASH_PHONE_BUNDLE_ID:-}" ]]; then
    perl -0pi -e 's/PRODUCT_BUNDLE_IDENTIFIER: .*/PRODUCT_BUNDLE_IDENTIFIER: '"${JUSTBASH_PHONE_BUNDLE_ID}"'/' "${TEMP_SPEC}"
  fi

  if [[ -n "${JUSTBASH_PHONE_DEVELOPMENT_TEAM:-}" ]]; then
    perl -0pi -e 's/CODE_SIGN_STYLE: Automatic\n/CODE_SIGN_STYLE: Automatic\n        DEVELOPMENT_TEAM: '"${JUSTBASH_PHONE_DEVELOPMENT_TEAM}"'\n/' "${TEMP_SPEC}"
  fi

  SPEC_FILE="${TEMP_SPEC}"
fi

xcodegen generate -s "${SPEC_FILE}"
