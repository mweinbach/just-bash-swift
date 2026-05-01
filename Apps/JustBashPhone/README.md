# JustBashPhone

Minimal iPhone/iPad host app for `just-bash-swift`.

Deployment target: iOS 26+.

## What It Does

- links the local `JustBash` and `JustBashJavaScript` package products
- runs bash scripts entirely in-process on iOS
- uses the package-level `BashOptions.codingAgentWorkspace(...)` setup
- seeds a persistent mac-like filesystem with `/Users/coder`, `~/Documents`,
  `~/Downloads`, `~/Desktop`, `~/Pictures`, `~/Library`, `/Applications`, and `/tmp`
- keeps `/workspace` available for existing agent-script compatibility
- shows stdout, stderr, exit code, and a small sandbox file browser with save,
  move, delete, and share/export actions
- shows whether BeeWare Python support is linked into the current build
- runs Python code on-device with captured stdout/stderr when the BeeWare-linked build is used
- adds `py-exec`, `python`, and `python3` commands to the virtual bash when the iPhone host is running
- stages a broad pure-JS `@oai/artifact-tool` compatibility package for
  direct imports, `presentation-jsx`, common `.docx`/`.pptx`/`.xlsx`
  import/export smoke checks, and model-facing facade exports
- adds `primary-runtime-skills-check` to write an on-device readiness report for
  the cached Documents, Presentations, and Spreadsheets skill bundles
- exposes App Shortcuts for:
  - `Run Shell Script`
  - `Reset Sandbox`
  - `Run Python Code`
  - `Read Workspace File`
  - `Write Workspace File`

## Generate The Project

```bash
cd Apps/JustBashPhone
./generate_project.sh
```

Then open `JustBashPhone.xcodeproj` in Xcode and run the `JustBashPhone` scheme on an iPhone or iOS Simulator.

To preconfigure a team or bundle ID while generating the project:

```bash
cd Apps/JustBashPhone
JUSTBASH_PHONE_DEVELOPMENT_TEAM=YOURTEAMID \
JUSTBASH_PHONE_BUNDLE_ID=com.example.JustBashPhone \
./generate_project.sh --with-python
```

To generate a Python-linked variant after installing BeeWare support:

```bash
cd Apps/JustBashPhone
./generate_project.sh --with-python
```

That variant links `Python.xcframework` and stages a bundle-local
`python/lib/python3.14` tree into the app at build time.

## Embedded Python

The Python-linked build embeds BeeWare CPython in the app bundle. It is a
build-time Python distribution, not a runtime package manager. On iPhone, assume
dependencies need to be bundled before signing the app.

Included by default:

- CPython `3.14` from the BeeWare iOS support package
- the Python standard library under `python/lib/python3.14`
- BeeWare's iOS `lib-dynload` extension modules, including common modules such
  as `_sqlite3`, `_ssl`, `_socket`, `zlib`, `bz2`, `lzma`, `_csv`, `_json`,
  `math`, `unicodedata`, and `zoneinfo`
- app-local modules copied from `Apps/JustBashPhone/PythonApp` into the bundle's
  `app` resource directory
- the pinned pure-Python package set in `PythonApp/requirements-default.txt`
  when `./generate_project.sh --with-python` runs normally

Not included by default:

- native-heavy packages such as `numpy`, `pandas`, `scipy`, `duckdb`, `pyarrow`,
  `pillow`, or `lxml`
- a supported runtime `pip install` workflow on iPhone
- access from CPython to the full JustBash virtual filesystem

The interpreter starts with its current directory set to the app's persistent
Documents directory. Files that Python writes relative to `Path.cwd()` are
visible to bash under `~/Documents`.

Run inline Python from the virtual bash:

```bash
py-exec -c 'import sys; print(sys.version)'
python -c 'from pathlib import Path; Path("from-python.txt").write_text("hello\n")'
cat ~/Documents/from-python.txt
```

Run a script stored in the virtual filesystem:

```bash
cat > ~/Documents/hello.py <<'PY'
from pathlib import Path
Path("python-output.txt").write_text("created by embedded Python\n")
print("wrote python-output.txt")
PY

python ~/Documents/hello.py
cat ~/Documents/python-output.txt
```

Important filesystem detail: `py-exec` can read a script file from the virtual
filesystem, including `~/Documents/script.py`, but CPython itself is not chrooted
into the virtual filesystem. Use relative paths, `Path.cwd()`, or the
`JUSTBASH_WORKSPACE` environment variable for persistent files. Do not expect
arbitrary virtual absolute paths inside Python to map unless the host exposes
the corresponding real directory.

### Adding Python Modules

For pure-Python dependencies, update `PythonApp/requirements-default.txt` and
refresh the generated package directory:

```bash
cd /Users/mweinbach/Projects/just-bash-swift
./scripts/install_python_app_packages.sh
cd Apps/JustBashPhone
./generate_project.sh --with-python
```

Anything in `Apps/JustBashPhone/PythonApp` is copied into the app bundle's
`app` resource directory. `app` and `app/site-packages` are added to `sys.path`
before user code runs.

### Primary Runtime Skill Probe

The Python-linked host includes a small pure-Python probe module for the cached
OpenAI primary-runtime Documents, Presentations, and Spreadsheets skills. It does
not install or register those skills. It verifies the on-device runtime surface
and writes a report:

```bash
primary-runtime-skills-check
cat /workspace/primary-runtime-skills-ios-report.json
```

The expected result is currently `ready` for the staged compatibility surface.
Some unchanged cached skills still reference desktop/container capabilities such
as LibreOffice/`soffice`, native Node graphics packages, and the full
`@oai/artifact-tool` skia-canvas/Walnut runtime. The app stages pure-JS
compatibility for direct imports, common Office import/export smoke checks, and
bounded renderer fallbacks. See
`../../docs/PRIMARY_RUNTIME_SKILLS_IOS.md` for the full compatibility matrix.
The command exits nonzero if the report regresses from ready so agents can use
it as a readiness gate.

The app keeps the embedded CPython interpreter alive across `py-exec` calls.
That still gives each command fresh script globals, but avoids repeatedly
finalizing native extensions like `numpy`.

Packages with native extensions are a build-time integration task. They need
iOS-compatible extension binaries for the target slice, must be included in the
signed app bundle, and may require extra Xcode build-script work. Installing
native wheels on-device at runtime is not a supported iPhone path.

Optional native package lane:

```bash
cd /Users/mweinbach/Projects/just-bash-swift
./scripts/probe_python_ios_wheels.sh numpy pillow pdf2image reportlab lxml pandas scipy
./scripts/install_python_native_packages.sh
cd Apps/JustBashPhone
./generate_project.sh --with-python
```

Today, `numpy==2.3.5.post1`, `Pillow`, `pdf2image`, and `reportlab` resolve for
the current CPython 3.14 iOS staging lane. `lxml`, `pandas`, and `scipy` do not
resolve yet for this target.
set, so they stay documented/probed rather than bundled.

Verified lane after installing BeeWare support:

```bash
xcodebuild -project Apps/JustBashPhone/JustBashPhone.xcodeproj \
  -scheme JustBashPhone \
  -destination 'generic/platform=iOS Simulator' \
  build
```

Embedded Python smoke lane:

```bash
APP=$(ls -d ~/Library/Developer/Xcode/DerivedData/JustBashPhone-*/Build/Products/Debug-iphonesimulator/JustBashPhone.app | tail -1)
xcrun simctl install <booted-simulator-udid> "$APP"
SIMCTL_CHILD_JUSTBASH_SMOKE_PYTHON=1 \
  xcrun simctl launch <booted-simulator-udid> com.mweinbach.JustBashPhone
```

Primary runtime skill readiness smoke lane:

```bash
SIMCTL_CHILD_JUSTBASH_SMOKE_PRIMARY_RUNTIME_SKILLS=1 \
  xcrun simctl launch <booted-simulator-udid> com.mweinbach.JustBashPhone
```

This writes `primary-runtime-skills-ios-report.json` and
`primary-runtime-skills-smoke-result.txt` into the app workspace.

## Physical iPhone Note

The iPhone host is now verified on a real device as well:

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

Verified locally against `Max’s iPhone 17 Pro Max` on iOS `26.5`.
