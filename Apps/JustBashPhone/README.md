# JustBashPhone

Minimal iPhone/iPad host app for `just-bash-swift`.

Deployment target: iOS 26+.

## What It Does

- links the local `JustBash` and `JustBashJavaScript` package products
- runs bash scripts entirely in-process on iOS
- seeds a virtual filesystem with sample files under `/data`
- mounts `/workspace` to the app's sandboxed Documents directory for persistent files
- shows stdout, stderr, exit code, and a small sandbox file browser
- shows whether BeeWare Python support is linked into the current build
- runs Python code on-device with captured stdout/stderr when the BeeWare-linked build is used
- adds `py-exec`, `python`, and `python3` commands to the virtual bash when the iPhone host is running
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

Not included by default:

- third-party packages such as `requests`, `numpy`, `rich`, or `pydantic`
- a supported runtime `pip install` workflow on iPhone
- access from CPython to the full JustBash virtual filesystem

The interpreter starts with its current directory set to the app's persistent
workspace. Files that Python writes relative to `Path.cwd()` are visible to bash
under `/workspace`.

Run inline Python from the virtual bash:

```bash
py-exec -c 'import sys; print(sys.version)'
python -c 'from pathlib import Path; Path("from-python.txt").write_text("hello\n")'
cat /workspace/from-python.txt
```

Run a script stored in the virtual filesystem:

```bash
cat > /workspace/hello.py <<'PY'
from pathlib import Path
Path("python-output.txt").write_text("created by embedded Python\n")
print("wrote python-output.txt")
PY

python /workspace/hello.py
cat /workspace/python-output.txt
```

Important filesystem detail: `py-exec` can read a script file from the virtual
filesystem, including `/workspace/script.py`, but CPython itself is not chrooted
into the virtual filesystem. Use relative paths, `Path.cwd()`, or the
`JUSTBASH_WORKSPACE` environment variable for persistent files. Do not expect
`open("/data/input.txt")` inside Python to read JustBash's in-memory `/data`.

### Adding Python Modules

For pure-Python dependencies, vendor them into `PythonApp` before generating or
building the Python-linked project:

```bash
cd /Users/mweinbach/Projects/just-bash-swift
python3 -m pip install --target Apps/JustBashPhone/PythonApp requests
cd Apps/JustBashPhone
./generate_project.sh --with-python
```

Anything in `Apps/JustBashPhone/PythonApp` is copied into the app bundle's
`app` resource directory and added to `sys.path` before user code runs.

Packages with native extensions are a build-time integration task. They need
iOS-compatible extension binaries for the target slice, must be included in the
signed app bundle, and may require extra Xcode build-script work. Installing
native wheels on-device at runtime is not a supported iPhone path.

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
