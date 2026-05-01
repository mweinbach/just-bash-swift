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
- the pinned pure-Python default package set in
  `Apps/JustBashPhone/PythonApp/requirements-default.txt` when the Python
  project is generated normally

Not included by default:

- native-heavy packages such as `numpy`, `pandas`, `scipy`, `duckdb`, `pyarrow`,
  `pillow`, or `lxml`
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

By default, `--with-python` also installs the pure-Python package set into:

```text
Apps/JustBashPhone/PythonApp/site-packages
```

That directory is gitignored and copied into the app bundle at build time.
Set `JUSTBASH_PHONE_SKIP_PYTHON_PACKAGES=1` if you need to regenerate the Xcode
project without refreshing packages.

One important integration detail: the Python include/module-map path must be
SDK-specific. Pointing both the device and simulator include directories at the
same target causes duplicate `module Python` definitions during clang
dependency scanning.

## Run Python From Virtual Bash

The iPhone host registers `py-exec`, `python`, and `python3` commands in its
JustBash instance. They run through the embedded interpreter and share the same
persistent `~/Documents` workspace as bash.

Inline:

```bash
py-exec -c 'import sys; print(sys.version)'
python -c 'from pathlib import Path; Path("from-python.txt").write_text("hello\n")'
cat ~/Documents/from-python.txt
```

Script file:

```bash
cat > ~/Documents/hello.py <<'PY'
from pathlib import Path
Path("python-output.txt").write_text("created by embedded Python\n")
print("wrote python-output.txt")
PY

python ~/Documents/hello.py
cat ~/Documents/python-output.txt
```

Filesystem caveat: `py-exec` can load the Python script source from the
JustBash virtual filesystem, but CPython itself is not chrooted into that VFS.
The interpreter starts with its current directory set to the real host directory
for `~/Documents`. Use relative paths, `Path.cwd()`, or
`os.environ["JUSTBASH_WORKSPACE"]` for persistent files. Do not expect arbitrary
virtual absolute paths inside Python to resolve unless the host exposes the
corresponding real directory.

## Add Python Modules

The default pure-Python package set is pinned in:

```text
Apps/JustBashPhone/PythonApp/requirements-default.txt
```

It currently includes:

- HTTP/client helpers: `httpx`, `httpcore`, `requests`, `urllib3`, `certifi`,
  `idna`, `charset-normalizer`, `anyio`, `h11`
- CLI/config/runtime helpers: `click`, `rich`, `pygments`, `python-dotenv`,
  `platformdirs`, `filelock`, `tenacity`, `packaging`, `typing-extensions`
- data/text helpers: `python-dateutil`, `tomlkit`, `fastjsonschema`,
  `jmespath`, `beautifulsoup4`, `html5lib`, `markdown-it-py`
- Python-code helpers useful for local agents: `pyflakes`, `isort`, `rope`,
  `jedi`, `parso`, `attrs`, `cattrs`

Install or refresh the default set with:

```bash
./scripts/install_python_app_packages.sh
```

For additional pure-Python modules, add them to `requirements-default.txt` or
install into `Apps/JustBashPhone/PythonApp/site-packages`:

```bash
cd /Users/mweinbach/Projects/just-bash-swift
python3 -m pip install --target Apps/JustBashPhone/PythonApp/site-packages some-pure-python-package
Apps/JustBashPhone/generate_project.sh --with-python
```

The Python-linked build copies `Apps/JustBashPhone/PythonApp/.` into the app's
`app` resource directory. `PythonSupport` inserts both the `app` directory and
`app/site-packages` at the front of `sys.path` before user code runs.

The embedded interpreter stays initialized for the lifetime of the app process.
Each `py-exec` call gets fresh script globals and `sys.argv`, but the underlying
CPython runtime is not finalized between commands. That keeps native extensions
such as `numpy` usable across repeated imports.

Packages with native extensions must be built for iOS and included at build
time. On-device runtime installation of native wheels is not the supported path:
the app has no compiler toolchain, native code must be signed with the app, and
downloaded executable code is not the model we want for this host.

For the OpenAI primary-runtime Documents, Presentations, and Spreadsheets skill
bundles, see [Primary Runtime Skills On iOS](PRIMARY_RUNTIME_SKILLS_IOS.md).
Those skills are not iOS-runnable unchanged today because their upstream
contracts depend on desktop/container runtimes such as LibreOffice, native Node
packages, and full `@oai/artifact-tool` renderer/import behavior. The iPhone
host does stage a broad pure-JS artifact-tool compatibility package for direct
imports, common Office import/export smoke checks, and model-facing facade
exports.

## Native Package Status

Use this probe to check whether native packages resolve for CPython 3.14 iOS
device and simulator wheel tags:

```bash
./scripts/probe_python_ios_wheels.sh numpy pillow pdf2image reportlab lxml python-docx pandas scipy
```

Current probe result:

- `numpy==2.3.5.post1` resolves from BeeWare's secondary wheel index for
  `ios_15_4_arm64_iphoneos`, `ios_15_4_arm64_iphonesimulator`, and
  `ios_13_0_x86_64_iphonesimulator`.
- `Pillow`, `pdf2image`, and `reportlab` resolve for the current iOS staging
  lane; `pdf2image` may still need an app-provided Poppler-compatible renderer
  for real document rendering.
- `lxml` does not currently resolve for CPython 3.14 iOS using PyPI plus
  BeeWare's secondary wheel index.
- `python-docx` does not currently resolve for CPython 3.14 iOS because its
  `lxml` dependency cannot be satisfied on this target.
- `pandas` does not currently resolve for CPython 3.14 iOS using PyPI plus
  BeeWare's secondary wheel index.
- `scipy` does not currently resolve for CPython 3.14 iOS using PyPI plus
  BeeWare's secondary wheel index.

To install the optional native set, currently `numpy`, `Pillow`, `pdf2image`,
and `reportlab`, into architecture-specific staging directories:

```bash
./scripts/install_python_native_packages.sh
```

Those packages are staged under `Apps/JustBashPhone/PythonApp/native/` and are
gitignored. The Xcode build copies only the matching device/simulator slice into
`app/site-packages` and removes the other native slices from the app bundle.

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
