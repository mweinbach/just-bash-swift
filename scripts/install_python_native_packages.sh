#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${ROOT_DIR}/Apps/JustBashPhone/PythonApp"
REQUIREMENTS="${1:-${APP_DIR}/requirements-native-ios.txt}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
BEEWARE_INDEX="${BEEWARE_IOS_WHEEL_INDEX:-https://pypi.anaconda.org/beeware/simple}"

if [[ ! -f "${REQUIREMENTS}" ]]; then
  echo "Native Python package requirements not found: ${REQUIREMENTS}" >&2
  exit 1
fi

install_for_slice() {
  local slice="$1"
  local platform_tag="$2"
  local target="${APP_DIR}/native/${slice}/site-packages"
  local marker="${target}/.justbash-native-requirements.sha256"
  local req_hash

  req_hash="$(printf '%s  %s\n%s\n' "${platform_tag}" "${REQUIREMENTS}" "$(shasum -a 256 "${REQUIREMENTS}" | awk '{print $1}')" | shasum -a 256 | awk '{print $1}')"

  mkdir -p "${target}"
  if [[ "${JUSTBASH_PYTHON_NATIVE_REFRESH:-0}" != "1" && -f "${marker}" ]]; then
    if [[ "$(cat "${marker}")" == "${req_hash}" ]]; then
      echo "Native Python packages already installed for ${slice}:"
      echo "  ${target}"
      return
    fi
  fi

  rm -rf "${target}"
  mkdir -p "${target}"

  "${PYTHON_BIN}" -m pip install \
    --upgrade \
    --ignore-installed \
    --target "${target}" \
    --requirement "${REQUIREMENTS}" \
    --only-binary=:all: \
    --platform "${platform_tag}" \
    --implementation cp \
    --python-version 314 \
    --abi cp314 \
    --extra-index-url "${BEEWARE_INDEX}" \
    --no-compile

  find "${target}" -name __pycache__ -type d -prune -exec rm -rf {} +
  echo "${req_hash}" > "${marker}"
}

install_for_slice "ios-arm64" "ios_15_4_arm64_iphoneos"
install_for_slice "ios-arm64-simulator" "ios_15_4_arm64_iphonesimulator"
install_for_slice "ios-x86_64-simulator" "ios_13_0_x86_64_iphonesimulator"

echo
echo "Installed optional native Python packages under:"
echo "  ${APP_DIR}/native"
