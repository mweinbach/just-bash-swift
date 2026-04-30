import AppIntents
import JustBash

struct RunShellScriptIntent: AppIntent {
    static var title: LocalizedStringResource { "Run Shell Script" }
    static var description: IntentDescription {
        IntentDescription("Run a shell script inside Just Bash's on-device sandbox.")
    }
    static let supportedModes: IntentModes = [.background]

    @Parameter(
        title: "Script",
        requestValueDialog: IntentDialog("What shell script should I run?")
    )
    var script: String

    static var parameterSummary: some ParameterSummary {
        Summary("Run shell script")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let result = await SandboxService.shared.run(script)
        let summary = summarize(result)
        let dialog = result.exitCode == 0
            ? IntentDialog("Finished running the shell script.")
            : IntentDialog("The shell script failed with exit code \(result.exitCode).")
        return .result(value: summary, dialog: dialog)
    }

    private func summarize(_ result: ExecResult) -> String {
        var parts: [String] = ["exitCode=\(result.exitCode)"]
        if !result.stdout.isEmpty {
            parts.append("stdout:\n\(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        if !result.stderr.isEmpty {
            parts.append("stderr:\n\(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return parts.joined(separator: "\n\n")
    }
}

struct ResetSandboxIntent: AppIntent {
    static var title: LocalizedStringResource { "Reset Sandbox" }
    static var description: IntentDescription {
        IntentDescription("Reset the Just Bash virtual filesystem back to its seeded state.")
    }
    static let supportedModes: IntentModes = [.background]

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await SandboxService.shared.reset()
        return .result(dialog: "Reset the virtual sandbox.")
    }
}

struct RunPythonCodeIntent: AppIntent {
    static var title: LocalizedStringResource { "Run Python Code" }
    static var description: IntentDescription {
        IntentDescription("Run Python code inside the BeeWare-backed on-device runtime.")
    }
    static let supportedModes: IntentModes = [.background]

    @Parameter(
        title: "Code",
        requestValueDialog: IntentDialog("What Python code should I run?")
    )
    var code: String

    static var parameterSummary: some ParameterSummary {
        Summary("Run Python code")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let result = await SandboxService.shared.runPython(code)
        let summary = summarize(result)
        let dialog = result.exitCode == 0
            ? IntentDialog("Finished running the Python code.")
            : IntentDialog("The Python code failed with exit code \(result.exitCode).")
        return .result(value: summary, dialog: dialog)
    }

    private func summarize(_ result: PythonExecResult) -> String {
        var parts: [String] = ["exitCode=\(result.exitCode)"]
        if !result.stdout.isEmpty {
            parts.append("stdout:\n\(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        if !result.stderr.isEmpty {
            parts.append("stderr:\n\(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return parts.joined(separator: "\n\n")
    }
}

struct ReadWorkspaceFileIntent: AppIntent {
    static var title: LocalizedStringResource { "Read Workspace File" }
    static var description: IntentDescription {
        IntentDescription("Read a text file from the persistent Just Bash workspace.")
    }
    static let supportedModes: IntentModes = [.background]

    @Parameter(
        title: "Path",
        requestValueDialog: IntentDialog("Which workspace file should I read?")
    )
    var path: String

    static var parameterSummary: some ParameterSummary {
        Summary("Read workspace file")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let normalizedPath = normalizeWorkspacePath(path)
        do {
            let contents = try await SandboxService.shared.readFile(normalizedPath)
            return .result(
                value: contents,
                dialog: IntentDialog("Read \(normalizedPath).")
            )
        } catch {
            return .result(
                value: "",
                dialog: IntentDialog("Couldn't read \(normalizedPath).")
            )
        }
    }
}

struct WriteWorkspaceFileIntent: AppIntent {
    static var title: LocalizedStringResource { "Write Workspace File" }
    static var description: IntentDescription {
        IntentDescription("Create or replace a text file in the persistent Just Bash workspace.")
    }
    static let supportedModes: IntentModes = [.background]

    @Parameter(
        title: "Path",
        requestValueDialog: IntentDialog("Where should I write the workspace file?")
    )
    var path: String

    @Parameter(
        title: "Contents",
        requestValueDialog: IntentDialog("What should the file contain?")
    )
    var contents: String

    static var parameterSummary: some ParameterSummary {
        Summary("Write workspace file")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let normalizedPath = normalizeWorkspacePath(path)
        try await SandboxService.shared.writeFile(normalizedPath, contents: contents)
        return .result(dialog: "Wrote \(normalizedPath).")
    }
}

struct JustBashShortcuts: AppShortcutsProvider {
    static let shortcutTileColor: ShortcutTileColor = .blue

    @AppShortcutsBuilder
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RunShellScriptIntent(),
            phrases: [
                "Run a shell script in \(.applicationName)",
                "Execute a sandbox script with \(.applicationName)"
            ],
            shortTitle: "Run Script",
            systemImageName: "terminal"
        )
        AppShortcut(
            intent: ResetSandboxIntent(),
            phrases: [
                "Reset the Just Bash sandbox in \(.applicationName)",
                "Clear the shell sandbox with \(.applicationName)"
            ],
            shortTitle: "Reset Sandbox",
            systemImageName: "arrow.counterclockwise"
        )
        AppShortcut(
            intent: RunPythonCodeIntent(),
            phrases: [
                "Run Python code in \(.applicationName)",
                "Execute Python with \(.applicationName)"
            ],
            shortTitle: "Run Python",
            systemImageName: "curlybraces.square"
        )
        AppShortcut(
            intent: ReadWorkspaceFileIntent(),
            phrases: [
                "Read a Just Bash workspace file in \(.applicationName)",
                "Show a workspace file from \(.applicationName)"
            ],
            shortTitle: "Read File",
            systemImageName: "doc.text.magnifyingglass"
        )
        AppShortcut(
            intent: WriteWorkspaceFileIntent(),
            phrases: [
                "Write a Just Bash workspace file in \(.applicationName)",
                "Save text into the shell workspace with \(.applicationName)"
            ],
            shortTitle: "Write File",
            systemImageName: "square.and.pencil"
        )
    }
}

private func normalizeWorkspacePath(_ rawPath: String) -> String {
    if rawPath.hasPrefix("/workspace/") || rawPath == "/workspace" {
        return rawPath
    }
    let trimmed = rawPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    return trimmed.isEmpty ? "/workspace" : "/workspace/\(trimmed)"
}
