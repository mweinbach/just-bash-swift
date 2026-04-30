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
