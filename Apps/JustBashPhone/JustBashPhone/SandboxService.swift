import Foundation
import JustBash
import JustBashFS
import JustBashJavaScript

actor SandboxService {
    static let shared = SandboxService()

    static let seedFiles: [String: String] = [
        "/data/input.txt": """
        Codex can run locally inside a virtual shell on iPhone.
        This file lives in the in-memory sandbox.
        """,
        "/data/log.txt": """
        INFO Boot complete
        ERROR Missing token cache
        INFO Retrying request
        ERROR Request failed
        """,
        "/workspace/README.txt": """
        This directory is mounted to the app's sandboxed Documents folder.
        Files written here persist across launches of Just Bash on iPhone/iPad.
        """,
    ]

    private var bash = SandboxService.makeBash()

    func run(_ script: String) async -> ExecResult {
        await bash.exec(script)
    }

    func reset() {
        bash = SandboxService.makeBash()
    }

    func readFile(_ path: String) async throws -> String {
        try await bash.readFile(path)
    }

    func pythonAvailabilitySummary() -> String {
        PythonSupport.availabilitySummary()
    }

    func isPythonAvailable() -> Bool {
        PythonSupport.isAvailable
    }

    func runPython(_ code: String) async -> PythonExecResult {
        PythonSupport.run(code: code, workspacePath: Self.workspaceDirectoryPath())
    }

    func runPythonSmokeIfRequested() async {
        guard ProcessInfo.processInfo.environment["JUSTBASH_SMOKE_PYTHON"] == "1" else {
            return
        }

        let smokePath = Self.workspaceDirectoryPath() + "/python-smoke.txt"
        let startedPath = Self.workspaceDirectoryPath() + "/python-smoke.started"
        let beforeRunPath = Self.workspaceDirectoryPath() + "/python-smoke.before-run"
        let afterRunPath = Self.workspaceDirectoryPath() + "/python-smoke.after-run"
        try? FileManager.default.createDirectory(
            atPath: Self.workspaceDirectoryPath(),
            withIntermediateDirectories: true
        )
        try? "started\n".write(toFile: startedPath, atomically: true, encoding: .utf8)

        let escapedPath = smokePath.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        let code = """
        import importlib.metadata
        import sys
        from pathlib import Path

        import bs4
        import fastjsonschema
        import httpx
        import jedi
        import rich
        import tomlkit

        lines = [
            'python smoke ok',
            sys.version,
            'default packages import ok',
            f'beautifulsoup4={importlib.metadata.version("beautifulsoup4")}',
            f'fastjsonschema={importlib.metadata.version("fastjsonschema")}',
            f'httpx={importlib.metadata.version("httpx")}',
            f'jedi={importlib.metadata.version("jedi")}',
            f'rich={importlib.metadata.version("rich")}',
            f'tomlkit={importlib.metadata.version("tomlkit")}',
        ]

        try:
            lines.append(f'numpy dist={importlib.metadata.version("numpy")}')
        except Exception as exc:
            lines.append(f'numpy dist unavailable: {type(exc).__name__}: {exc}')

        Path('\(escapedPath)').write_text('\\n'.join(lines) + '\\n')
        """

        try? "before run\n".write(toFile: beforeRunPath, atomically: true, encoding: .utf8)
        let result = PythonSupport.run(code: code, workspacePath: Self.workspaceDirectoryPath())
        try? "after run\n".write(toFile: afterRunPath, atomically: true, encoding: .utf8)
        if result.exitCode != 0 {
            try? FileManager.default.createDirectory(
                atPath: Self.workspaceDirectoryPath(),
                withIntermediateDirectories: true
            )
            let message = "python smoke failed: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))\n"
            try? message.write(toFile: smokePath, atomically: true, encoding: .utf8)
            return
        }

        let shellSmoke = await run("""
        py-exec - <<'PY'
        from pathlib import Path
        import httpx

        lines = ["py-exec smoke ok", f"httpx={httpx.__version__}"]
        try:
            import numpy
            lines.append(f"numpy={numpy.__version__}")
        except Exception as exc:
            lines.append(f"numpy unavailable: {type(exc).__name__}: {exc}")

        Path("python-shell-smoke.txt").write_text("\\n".join(lines) + "\\n")
        PY
        cat /workspace/python-shell-smoke.txt
        py-exec - <<'PY'
        try:
            import numpy
            print(f"numpy repeat={numpy.__version__}")
        except Exception as exc:
            print(f"numpy repeat unavailable: {type(exc).__name__}: {exc}")
        PY
        """)
        let shellSmokePath = Self.workspaceDirectoryPath() + "/python-shell-smoke-result.txt"
        let shellSmokeOutput = """
        exitCode=\(shellSmoke.exitCode)
        stdout=\(shellSmoke.stdout)
        stderr=\(shellSmoke.stderr)
        """
        try? shellSmokeOutput.write(toFile: shellSmokePath, atomically: true, encoding: .utf8)
    }

    func writeFile(_ path: String, contents: String) async throws {
        let fs = await bash.fs
        let normalized = fs.normalizePath(path, relativeTo: "/workspace")
        let parent = String(normalized.split(separator: "/").dropLast().joined(separator: "/"))
        let parentPath = parent.isEmpty ? "/" : "/" + parent
        if parentPath != "/" {
            try fs.createDirectory(path: parentPath, relativeTo: "/", recursive: true)
        }
        try fs.writeFile(contents, to: normalized, relativeTo: "/")
    }

    func listDirectory(_ path: String) async throws -> [VirtualDirectoryEntry] {
        try await bash.listDirectory(path)
    }

    private static func makeBash() -> Bash {
        let workspaceBase = workspaceDirectoryPath()
        try? FileManager.default.createDirectory(
            atPath: workspaceBase,
            withIntermediateDirectories: true
        )

        let root = VirtualFileSystem()
        let mountable = MountableFileSystem(root: root)
        mountable.mount(ReadWriteFileSystem(base: workspaceBase), at: "/workspace")

        return Bash(options: .init(
            files: seedFiles,
            customCommands: Self.pythonCommands(),
            filesystem: mountable,
            embeddedRuntimes: [
                JavaScriptRuntime(options: .init(
                    bootstrap: "globalThis.APP_NAME = 'JustBashPhone';"
                ))
            ]
        ))
    }

    private static func pythonCommands() -> [AnyBashCommand] {
        let handler: CommandHandler = { args, ctx in
            var inlineCode: String?
            var scriptPath: String?
            var scriptArgs: [String] = []
            var readFromStdin = false
            var index = 0

            while index < args.count {
                let arg = args[index]
                switch arg {
                case "--help":
                    return ExecResult.success("""
                    py-exec - run embedded Python inside the Just Bash host

                      py-exec -c 'code'         execute inline Python
                      py-exec script.py         execute a virtual filesystem script file
                      py-exec - < script.py     read Python code from stdin
                      python -c 'code'          alias for py-exec
                      python script.py          alias for py-exec

                    Python starts with its current directory set to the persistent
                    workspace. Files written by Python to the current directory are
                    visible to bash under /workspace.

                    """)
                case "-V", "--version":
                    let result = PythonSupport.run(
                        code: "import sys; print(sys.version)",
                        workspacePath: Self.workspaceDirectoryPath(),
                        scriptName: "<justbash-python-version>"
                    )
                    if result.exitCode == 0 {
                        return ExecResult(stdout: result.stdout, stderr: result.stderr, exitCode: result.exitCode)
                    }
                    return ExecResult.failure(result.stderr, exitCode: result.exitCode)
                case "-c":
                    index += 1
                    if index < args.count {
                        inlineCode = args[index]
                    } else {
                        return ExecResult.failure("py-exec: -c requires an argument", exitCode: 2)
                    }
                case "-":
                    readFromStdin = true
                default:
                    if arg.hasPrefix("-") {
                        return ExecResult.failure("py-exec: unknown option \(arg)", exitCode: 2)
                    }
                    if inlineCode == nil && scriptPath == nil && !readFromStdin {
                        scriptPath = arg
                    } else {
                        scriptArgs.append(arg)
                    }
                }
                index += 1
            }

            let source: String
            let displayName: String
            if let inlineCode {
                source = inlineCode
                displayName = "<justbash-python>"
            } else if let scriptPath {
                do {
                    let data = try ctx.fileSystem.readFile(path: scriptPath, relativeTo: ctx.cwd)
                    source = String(decoding: data, as: UTF8.self)
                    displayName = scriptPath
                } catch {
                    return ExecResult.failure("py-exec: cannot read \(scriptPath): \(error.localizedDescription)", exitCode: 2)
                }
            } else if readFromStdin || !ctx.stdin.isEmpty {
                source = ctx.stdin
                displayName = "<stdin>"
            } else {
                return ExecResult.failure("py-exec: no script source provided (use -c, a file path, or stdin)", exitCode: 2)
            }

            let result = PythonSupport.run(
                code: source,
                workspacePath: Self.workspaceDirectoryPath(),
                arguments: scriptArgs,
                scriptName: displayName,
                scriptPath: scriptPath
            )
            return ExecResult(stdout: result.stdout, stderr: result.stderr, exitCode: result.exitCode)
        }

        return [
            AnyBashCommand(name: "py-exec", execute: handler),
            AnyBashCommand(name: "python", execute: handler),
            AnyBashCommand(name: "python3", execute: handler),
        ]
    }

    private static func workspaceDirectoryPath() -> String {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("JustBashWorkspace", isDirectory: true).path
    }
}
