# Embedded Python Notes

This repo's next major runtime milestone is `JustBashPython`, backed by
BeeWare's `Python.xcframework`.

## Current Findings

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

One important integration detail: the Python include/module-map path must be
SDK-specific. Pointing both the device and simulator include directories at the
same target causes duplicate `module Python` definitions during clang
dependency scanning.

## Remaining Integration Work

- add a `JustBashPython` package target/product
- decide how to make the support package optional without breaking default builds
- initialize Python with a usable `PYTHONHOME`
- bundle or expose the standard library and extension modules to the runtime
- implement a `py-exec` command surface similar to `js-exec`
- add package tests plus iPhone-host validation
