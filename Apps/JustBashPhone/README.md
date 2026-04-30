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
- exposes App Shortcuts for:
  - `Run Shell Script`
  - `Reset Sandbox`
  - `Read Workspace File`
  - `Write Workspace File`

## Generate The Project

```bash
cd Apps/JustBashPhone
xcodegen generate
```

Then open `JustBashPhone.xcodeproj` in Xcode and run the `JustBashPhone` scheme on an iPhone or iOS Simulator.

## Physical iPhone Note

The simulator build is verified from the command line. A direct build to the
connected iPhone currently stops at signing if no team is configured yet:

`Signing for "JustBashPhone" requires a development team.`

Set your team once in Xcode under Signing & Capabilities for the
`JustBashPhone` target, then rerun the device build.
