#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_DIR="${ROOT_DIR}/Vendor/BeeWare"

PYTHON_SERIES="${1:-3.14}"
BUILD_TAG="${2:-b9}"
ARCHIVE_NAME="Python-${PYTHON_SERIES}-iOS-support.${BUILD_TAG}.tar.gz"
RELEASE_TAG="${PYTHON_SERIES}-${BUILD_TAG}"
DOWNLOAD_URL="https://github.com/beeware/Python-Apple-support/releases/download/${RELEASE_TAG}/${ARCHIVE_NAME}"

mkdir -p "${VENDOR_DIR}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

echo "Downloading ${DOWNLOAD_URL}"
curl -L --fail --output "${TMP_DIR}/${ARCHIVE_NAME}" "${DOWNLOAD_URL}"

rm -rf "${VENDOR_DIR}/Python.xcframework"
tar -xzf "${TMP_DIR}/${ARCHIVE_NAME}" -C "${VENDOR_DIR}"

if [[ ! -d "${VENDOR_DIR}/Python.xcframework" ]]; then
  echo "Expected ${VENDOR_DIR}/Python.xcframework after extraction." >&2
  exit 1
fi

echo "Installed BeeWare Python support package:"
echo "  ${VENDOR_DIR}/Python.xcframework"
echo
echo "Next useful checks:"
echo "  1. Verify Swift can import the C module:"
echo "     xcrun swiftc -target arm64-apple-ios26.0-simulator \\"
echo "       -sdk /Applications/Xcode-beta.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator26.5.sdk \\"
echo "       -I ${VENDOR_DIR}/Python.xcframework/ios-arm64_x86_64-simulator/include/python${PYTHON_SERIES} \\"
echo "       /tmp/import_python.swift -c -o /tmp/import_python.o"
echo "  2. Wire a JustBashPython target around the installed support package."
