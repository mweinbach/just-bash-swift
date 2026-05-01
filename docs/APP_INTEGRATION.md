# App Integration

Use this package when an iOS, iPadOS, macOS, or Mac Catalyst app needs an
embedded shell or coding agent that can work with normal-looking user files.
The package runs in-process: no `Process`, no external `bash`, no VM, and no
container.

## Package Products

Add the package:

```swift
.package(url: "https://github.com/mweinbach/just-bash-swift.git", branch: "main")
```

For a shell-only app:

```swift
.product(name: "JustBash", package: "just-bash-swift")
```

For an app that also wants JavaScript/Node-like helpers:

```swift
.product(name: "JustBash", package: "just-bash-swift")
.product(name: "JustBashJavaScript", package: "just-bash-swift")
```

`JustBashJavaScript` uses JavaScriptCore and adds `js-exec`, `fs`, `path`,
`process`, `Buffer`, `console`, `child_process` shims, and package resolution
for pure-JS modules.

## Basic App Shell

```swift
import JustBash

let bash = Bash(options: .init(
    files: [
        "/data/input.txt": "hello world\n",
    ],
    env: [
        "APP_NAME": "MyApp",
    ]
))

let result = await bash.exec("""
echo "$APP_NAME"
cat /data/input.txt | wc -w
""")

print(result.exitCode)
print(result.stdout)
print(result.stderr)
```

The default filesystem is in-memory. It is useful for short-lived sandboxes,
tests, and isolated command execution.

## Coding-Agent Workspace

For a real app, prefer the package-level coding-agent workspace. It gives the
agent a persistent, mac-like filesystem rooted inside your app sandbox.

```swift
import Foundation
import JustBash
import JustBashJavaScript

let appDocuments = FileManager.default.urls(
    for: .documentDirectory,
    in: .userDomainMask
)[0]

let workspaceRoot = appDocuments.appendingPathComponent(
    "AgentWorkspace",
    isDirectory: true
)

let bash = Bash(options: try .codingAgentWorkspace(
    rootURL: workspaceRoot,
    username: "coder",
    embeddedRuntimes: [
        JavaScriptRuntime(options: .init(
            bootstrap: "globalThis.APP_NAME = 'MyApp';"
        )),
    ]
))
```

This seeds:

```text
/
/Applications
/Library
/System
/Users/coder
/Users/coder/Desktop
/Users/coder/Documents
/Users/coder/Downloads
/Users/coder/Library
/Users/coder/Movies
/Users/coder/Music
/Users/coder/Pictures
/Users/coder/Public
/Users/coder/.Trash
/tmp
/workspace
```

The default current directory is `~/Documents`, and these environment variables
are set for the shell and embedded runtimes:

```text
HOME=/Users/coder
USER=coder
LOGNAME=coder
PWD=/Users/coder/Documents
TMPDIR=/tmp
PATH=/usr/bin:/bin
```

`/workspace` is kept as a compatibility directory for agent scripts that expect
that path, but new app code should usually present `~/Documents` and
`~/Downloads` to users.

## Running Agent Commands

```swift
let result = await bash.exec("""
printf 'Draft from the agent\\n' > ~/Documents/draft.txt
cp ~/Documents/draft.txt ~/Downloads/
ls -la ~/Documents ~/Downloads
""")

if result.exitCode != 0 {
    print(result.stderr)
}
```

Use `ExecOptions` when a user action or agent step needs a temporary cwd,
environment, or stdin:

```swift
let result = await bash.exec(
    "cat > notes/today.txt && wc -w notes/today.txt",
    options: ExecOptions(
        cwd: "/Users/coder/Documents",
        stdin: "Meeting notes from the user.\n"
    )
)
```

Each `exec` call gets fresh shell state. The filesystem persists because the
workspace is disk-backed.

## File Browser UI

You can build a file browser from the same filesystem the agent uses:

```swift
let fs = await bash.fs
let names = try fs.listDirectory(
    path: "/Users/coder/Documents",
    relativeTo: "/"
)

for name in names {
    let path = "/Users/coder/Documents/\(name)"
    let info = try fs.fileInfo(path: path, relativeTo: "/")
    print(info.kind, path, info.size)
}
```

To preview a text file:

```swift
let data = try fs.readFile(
    path: "/Users/coder/Documents/draft.txt",
    relativeTo: "/"
)
let text = String(decoding: data, as: UTF8.self)
```

To save from a SwiftUI text editor:

```swift
try fs.writeFile(
    path: "/Users/coder/Documents/note.txt",
    content: Data(text.utf8),
    relativeTo: "/"
)
```

Normal shell commands such as `cp`, `mv`, `rm`, `mkdir`, `ls`, `find`, `zip`,
and `tar` operate on this same workspace.

## Importing User Files

Keep a reference to the workspace filesystem when you need document picker or
drag/drop import/export:

```swift
import JustBash
import JustBashJavaScript

let workspace = try CodingAgentWorkspace(
    rootURL: workspaceRoot,
    username: "coder"
)

let bash = Bash(options: workspace.options(
    embeddedRuntimes: [JavaScriptRuntime()]
))

let virtualPath = try workspace.filesystem.importItem(
    from: pickedFileURL
)

// Example result: /Users/coder/Downloads/report.csv
let result = await bash.exec("head \(shellQuoted(virtualPath))")
```

Use a small shell-quoting helper for app-provided paths:

```swift
func shellQuoted(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
```

When `destinationPath` is omitted, imported files go to `~/Downloads` and
imported directories go to `~/Documents`.

Use a specific virtual destination when your UI has an explicit target folder:

```swift
try workspace.filesystem.importItem(
    from: pickedFileURL,
    to: "/Users/coder/Documents/Project/input.csv"
)
```

For security-scoped URLs from a document picker, start access before calling
`importItem` and stop it afterward:

```swift
let granted = pickedFileURL.startAccessingSecurityScopedResource()
defer {
    if granted {
        pickedFileURL.stopAccessingSecurityScopedResource()
    }
}

let virtualPath = try workspace.filesystem.importItem(from: pickedFileURL)
```

## Exporting And Sharing Files

To expose a generated file through `ShareLink`, `UIDocumentPickerViewController`,
or `NSSharingServicePicker`, get the host URL:

```swift
let fileURL = try workspace.filesystem.url(forVirtualPath: "/Users/coder/Documents/report.md")
```

SwiftUI share example:

```swift
ShareLink(item: fileURL) {
    Label("Export", systemImage: "square.and.arrow.up")
}
```

To copy a virtual file or directory to a user-selected host folder:

```swift
let exportedURL = try workspace.filesystem.exportItem(
    "/Users/coder/Documents/report.md",
    to: destinationDirectoryURL
)
```

If the destination URL is a directory, the virtual file keeps its basename
inside that directory.

## Custom Commands

Use custom commands to let the agent call app features without escaping the
sandbox. Commands receive arguments, stdin, cwd, environment, and filesystem
access.

```swift
let saveToApp = AnyBashCommand(name: "app-save-note") { args, ctx in
    guard args.count >= 2 else {
        return ExecResult.failure("usage: app-save-note PATH TEXT\n", exitCode: 2)
    }

    do {
        try ctx.fileSystem.writeFile(
            args.dropFirst().joined(separator: " "),
            to: args[0],
            relativeTo: ctx.cwd
        )
        return ExecResult.success()
    } catch {
        return ExecResult.failure("app-save-note: \(error.localizedDescription)\n")
    }
}

let bash = Bash(options: try .codingAgentWorkspace(
    rootURL: workspaceRoot,
    customCommands: [saveToApp]
))
```

This is the preferred bridge for app-specific actions such as querying app
state, writing to a database, requesting user approval, or handing a generated
file to another subsystem.

## JavaScript Runtime

Add `JustBashJavaScript` when the agent needs Node-like helper scripts:

```swift
let bash = Bash(options: try .codingAgentWorkspace(
    rootURL: workspaceRoot,
    embeddedRuntimes: [
        JavaScriptRuntime(options: BashJavaScriptOptions(
            bootstrap: "globalThis.APP_NAME = 'MyApp';"
        ))
    ]
))

let result = await bash.exec(#"""
js-exec -c '
  const fs = require("fs");
  fs.writeFileSync(
    process.env.HOME + "/Documents/from-js.txt",
    "hello from JavaScript\n"
  );
'
cat ~/Documents/from-js.txt
"""#)
```

`fetch` is disabled by default. Pass `allowedURLPrefixes` when your app wants to
allow outbound requests:

```swift
let bash = Bash(options: try .codingAgentWorkspace(
    rootURL: workspaceRoot,
    allowedURLPrefixes: ["https://api.example.com/"],
    embeddedRuntimes: [JavaScriptRuntime()]
))
```

## Artifact Skills On iOS

The example iPhone host stages a pure-JS compatibility package for
`@oai/artifact-tool` so cached Documents, Presentations, and Spreadsheets helper
paths can run on iOS through JavaScriptCore.

That compatibility layer is useful for model-facing API shape and common
Office import/export smoke paths, but it is not a literal port of the native
desktop stack. Native `skia-canvas` and Walnut/.NET-WASM are still replaced by
bounded iOS facades.

If your app wants the same staged artifact-tool behavior, enable the shared
runtime support on the `BashOptions` you create for the host:

```swift
var options = try BashOptions.codingAgentWorkspace(
    rootURL: workspaceURL,
    username: "coder",
    embeddedRuntimes: [JavaScriptRuntime()]
)
options.enableOAIPrimaryRuntime(pythonProbe: {
    // Return an OAIPrimaryRuntimeCommandResult from your embedded Python probe.
})
```

Specifically:

- `OAIPrimaryRuntimeSupport` seeds package files under `/node_modules/...` and
  `~/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/...`
- include `JavaScriptRuntime`
- provide any host commands the helper scripts need, such as `python3`
- run `primary-runtime-skills-check` or an equivalent smoke command on device

## iOS Notes

- Use an app-container directory, usually under `FileManager.default.urls(for:
  .documentDirectory, in: .userDomainMask)`, as the workspace root.
- iOS cannot spawn arbitrary system processes. Keep work inside JustBash,
  JavaScriptCore, embedded Python, or explicit host-provided commands.
- JavaScriptCore runs without JIT on iOS, so compute-heavy JavaScript is slower
  than macOS.
- Files are real files under your workspace root. Users can preview, share,
  move, delete, import, and export them through normal app UI.
- Do not mount broad real-device paths into the agent workspace. Import files
  the user selected, then let the agent work on copies inside the sandbox.

## Minimal View Model Sketch

```swift
import Foundation
import SwiftUI
import JustBash
import JustBashJavaScript

@MainActor
final class AgentShellModel: ObservableObject {
    @Published var output = ""

    private let workspace: CodingAgentWorkspace
    private let bash: Bash

    init() throws {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentWorkspace", isDirectory: true)
        let workspace = try CodingAgentWorkspace(rootURL: root, username: "coder")
        self.workspace = workspace
        self.bash = Bash(options: workspace.options(
            embeddedRuntimes: [JavaScriptRuntime()]
        ))
    }

    func run(_ script: String) {
        Task {
            let result = await bash.exec(script)
            await MainActor.run {
                output = result.stdout + result.stderr
            }
        }
    }

    func importFile(_ url: URL) throws -> String {
        try workspace.filesystem.importItem(from: url)
    }

    func shareURL(for path: String) throws -> URL {
        try workspace.filesystem.url(forVirtualPath: path)
    }
}
```
