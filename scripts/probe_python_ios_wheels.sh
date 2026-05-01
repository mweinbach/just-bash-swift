#!/usr/bin/env bash
set -u

PYTHON_BIN="${PYTHON_BIN:-python3}"
BEEWARE_INDEX="${BEEWARE_IOS_WHEEL_INDEX:-https://pypi.anaconda.org/beeware/simple}"

if [[ "$#" -eq 0 ]]; then
  set -- numpy pandas scipy pillow lxml cryptography orjson pydantic-core duckdb pyarrow
fi

PLATFORMS=(
  "ios_15_4_arm64_iphoneos"
  "ios_15_4_arm64_iphonesimulator"
  "ios_13_0_x86_64_iphonesimulator"
)

overall=0
for package in "$@"; do
  echo "== ${package} =="
  for platform in "${PLATFORMS[@]}"; do
    tmp_dir="$(mktemp -d)"
    if "${PYTHON_BIN}" -m pip download \
      --dest "${tmp_dir}" \
      --only-binary=:all: \
      --platform "${platform}" \
      --implementation cp \
      --python-version 314 \
      --abi cp314 \
      --extra-index-url "${BEEWARE_INDEX}" \
      "${package}" >/tmp/justbash-ios-wheel-probe.log 2>&1; then
      wheel_count="$(find "${tmp_dir}" -name '*.whl' | wc -l | tr -d ' ')"
      echo "  ${platform}: yes (${wheel_count} wheel files)"
      find "${tmp_dir}" -maxdepth 1 -name '*.whl' | sed 's#.*/#    #'
    else
      overall=1
      echo "  ${platform}: no"
      tail -5 /tmp/justbash-ios-wheel-probe.log | sed 's/^/    /'
    fi
    rm -rf "${tmp_dir}"
  done
  echo
done

exit "${overall}"
