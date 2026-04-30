# Embedded Python

The iPhone host can be generated as a Python-linked app backed by BeeWare's
`Python.xcframework`. This embeds CPython in-process on iOS without spawning
`python`, `bash`, `Process`, a VM, or a container.

## What Ships

- BeeWare publishes iOS support packages as release archives such as:
  `Python-3.14-iOS-support.b9.tar.gz`
- Those archives extract to a `Python.xcframework` containing:
  - device and simulator framework slices
  - Python headers
  - a `module.modulemap`
  - the standard-library layout under `lib/pythonX.Y`
- A direct Swift compile spike succeeded when the include path pointed at the
  slice's `include/python3.14` directory, which means Swift can import the
  `Python` C module without a custom module map.
- The Python-linked iPhone build stages a bundle-local Python home under:

```text
JustBashPhone.app/python/lib/python3.14
```

That staged home includes the standard library plus `lib-dynload` extension
modules from the selected BeeWare slice.

Default included examples:

- pure-Python stdlib modules such as `argparse`, `asyncio`, `csv`, `email`,
  `http`, `json`, `logging`, `pathlib`, `sqlite3`'s Python layer, `urllib`, and
  `xml`
- compiled stdlib extensions such as `_sqlite3`, `_ssl`, `_socket`, `zlib`,
  `bz2`, `lzma`, `_csv`, `_json`, `math`, `unicodedata`, and `zoneinfo`
- any app-local modules copied from `Apps/JustBashPhone/PythonApp`

Not included by default:

- third-party packages such as `requests`, `numpy`, `rich`, or `pydantic`
- a supported runtime `pip install` flow on iPhone
- transparent CPython access to JustBash's full in-memory virtual filesystem

## Install The Support Package

```bash
./scripts/install_beeware_python_support.sh
```

Default version:

- Python series: `3.14`
- BeeWare build tag: `b9`

You can override both:

```bash
./scripts/install_beeware_python_support.sh 3.13 b13
```

The package is extracted to:

```text
Vendor/BeeWare/Python.xcframework
```

`Vendor/BeeWare/` is gitignored on purpose.

## Generate The Python-Linked Host

```bash
Apps/JustBashPhone/generate_project.sh --with-python
```

The generated project links `Python.xcframework`, points Swift at the
SDK-specific Python headers, and stages the selected Python home into the app
bundle.

One important integration detail: the Python include/module-map path must be
SDK-specific. Pointing both the device and simulator include directories at the
same target causes duplicate `module Python` definitions during clang
dependency scanning.

## Run Python From Virtual Bash

The iPhone host registers `py-exec`, `python`, and `python3` commands in its
JustBash instance. They run through the embedded interpreter and share the same
persistent workspace as bash.

Inline:

```bash
py-exec -c 'import sys; print(sys.version)'
python -c 'from pathlib import Path; Path("from-python.txt").write_text("hello\n")'
cat /workspace/from-python.txt
```

Script file:

```bash
cat > /workspace/hello.py <<'PY'
from pathlib import Path
Path("python-output.txt").write_text("created by embedded Python\n")
print("wrote python-output.txt")
PY

python /workspace/hello.py
cat /workspace/python-output.txt
```

Filesystem caveat: `py-exec` can load the Python script source from the
JustBash virtual filesystem, but CPython itself is not chrooted into that VFS.
The interpreter starts with its current directory set to the real app workspace,
and that directory is mounted into bash at `/workspace`. Use relative paths,
`Path.cwd()`, or `os.environ["JUSTBASH_WORKSPACE"]` for persistent files.
Do not expect `open("/data/input.txt")` inside Python to read JustBash's
in-memory `/data`.

## Add Python Modules

For pure-Python modules, vendor them into `Apps/JustBashPhone/PythonApp`:

```bash
cd /Users/mweinbach/Projects/just-bash-swift
python3 -m pip install --target Apps/JustBashPhone/PythonApp requests
Apps/JustBashPhone/generate_project.sh --with-python
```

The Python-linked build copies `Apps/JustBashPhone/PythonApp/.` into the app
bundle's `app` resource directory, and `PythonSupport` inserts that directory at
the front of `sys.path` before user code runs.

Packages with native extensions must be built for iOS and included at build
time. On-device runtime installation of native wheels is not the supported path:
the app has no compiler toolchain, native code must be signed with the app, and
downloaded executable code is not the model we want for this host.

## Verified Import Spike

This compile check passed locally against the extracted simulator slice:

```bash
xcrun swiftc \
  -target arm64-apple-ios26.0-simulator \
  -sdk /Applications/Xcode-beta.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator26.5.sdk \
  -I Vendor/BeeWare/Python.xcframework/ios-arm64_x86_64-simulator/include/python3.14 \
  /tmp/import_python.swift \
  -c -o /tmp/import_python.o
```

With test source:

```swift
import Foundation
import Python

func test() {
    Py_Initialize()
    PyRun_SimpleString("print('hello from python')")
    Py_Finalize()
}
```

## Verified Host-App Integration

The optional iPhone host project can now be generated with Python support and
built successfully for iOS Simulator once BeeWare support is installed:

```bash
Apps/JustBashPhone/generate_project.sh --with-python
xcodebuild \
  -project Apps/JustBashPhone/JustBashPhone.xcodeproj \
  -scheme JustBashPhone \
  -destination 'generic/platform=iOS Simulator' \
  build
```

Simulator smoke:

```bash
APP=$(ls -d ~/Library/Developer/Xcode/DerivedData/JustBashPhone-*/Build/Products/Debug-iphonesimulator/JustBashPhone.app | tail -1)
xcrun simctl install <booted-simulator-udid> "$APP"
SIMCTL_CHILD_JUSTBASH_SMOKE_PYTHON=1 \
  xcrun simctl launch <booted-simulator-udid> com.mweinbach.JustBashPhone
```

Physical device build/install/launch has also been verified with automatic
development signing:

```bash
xcodebuild -project Apps/JustBashPhone/JustBashPhone.xcodeproj \
  -scheme JustBashPhone \
  -destination 'generic/platform=iOS' \
  DEVELOPMENT_TEAM=YOURTEAMID \
  build

APP=$(ls -d ~/Library/Developer/Xcode/DerivedData/JustBashPhone-*/Build/Products/Debug-iphoneos/JustBashPhone.app | tail -1)
xcrun devicectl device install app --device <physical-device-udid> "$APP"
xcrun devicectl device process launch --device <physical-device-udid> com.mweinbach.JustBashPhone
```

## Remaining Integration Work

- add a `JustBashPython` package target/product
- decide how to make the support package optional without breaking default builds
- add package-level tests for Python command parsing once Python support is
  factored out of the app target
- decide whether Python should get a VFS adapter layer beyond the current
  shared persistent `/workspace` bridge
