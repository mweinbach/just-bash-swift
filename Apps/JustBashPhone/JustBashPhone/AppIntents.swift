import AppIntents
import CodexCore
import Foundation
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

struct RunCodexPromptIntent: AppIntent {
    static var title: LocalizedStringResource { "Run Codex Prompt" }
    static var description: IntentDescription {
        IntentDescription("Send a prompt to Codex using the on-device Just Bash workspace.")
    }
    static let supportedModes: IntentModes = [.background]

    @Parameter(
        title: "Prompt",
        requestValueDialog: IntentDialog("What should Codex do?")
    )
    var prompt: String

    @Parameter(title: "Model")
    var model: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Run Codex prompt")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let key = CodexPhoneSettings.loadAPIKey().trimmingCharacters(in: .whitespacesAndNewlines)
        let selection: CodexPhoneSettings.ProviderSelection
        do {
            selection = try await CodexPhoneSettings.makeProvider(apiKeyFallback: key)
        } catch {
            return .result(value: "", dialog: "Sign in with ChatGPT or add an OpenAI API key in Just Bash first.")
        }
        let selectedModel = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        let configuration = AgentConfiguration(
            model: selectedModel?.isEmpty == false ? selectedModel! : CodexPhoneSettings.defaultModel,
            instructions: "You are Codex running fully on iOS inside Just Bash. Use JustBash-backed tools for workspace work.",
            approvalPolicy: .never,
            sandboxPolicy: .workspaceWrite
        )
        let runtime = try await SandboxService.shared.makeCodexRuntime(modelProvider: selection.provider, configuration: configuration)
        let thread = try await runtime.createThread(title: "Shortcuts Codex")
        let response = try await runtime.sendMessage(threadID: thread.id, text: prompt)
        return .result(value: response, dialog: "Codex finished.")
    }
}

struct QueueBackgroundCodexPromptIntent: AppIntent {
    static var title: LocalizedStringResource { "Queue Background Codex Prompt" }
    static var description: IntentDescription {
        IntentDescription("Queue a Codex prompt as a durable background response.")
    }
    static let supportedModes: IntentModes = [.background]

    @Parameter(
        title: "Prompt",
        requestValueDialog: IntentDialog("What should Codex process in the background?")
    )
    var prompt: String

    @Parameter(title: "Model")
    var model: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Queue background Codex prompt")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        do {
            let job = try await CodexBackgroundQueue.shared.enqueue(prompt: prompt, model: model)
            return .result(value: job.displayID, dialog: "Queued background job \(job.displayID).")
        } catch {
            return .result(value: "", dialog: "Could not queue the background job.")
        }
    }
}

struct RefreshBackgroundCodexJobsIntent: AppIntent {
    static var title: LocalizedStringResource { "Refresh Background Codex Jobs" }
    static var description: IntentDescription {
        IntentDescription("Refresh queued Codex background responses.")
    }
    static let supportedModes: IntentModes = [.background]

    static var parameterSummary: some ParameterSummary {
        Summary("Refresh background Codex jobs")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let jobs = try await CodexBackgroundQueue.shared.refreshPendingJobs()
        let summary = jobs.isEmpty
            ? "No background Codex jobs."
            : jobs.map { "[\($0.displayID)] \($0.status.rawValue) \($0.responseStatus ?? "")" }.joined(separator: "\n")
        return .result(value: summary, dialog: "Refreshed background Codex jobs.")
    }
}

struct ReadWorkspaceFileIntent: AppIntent {
    static var title: LocalizedStringResource { "Read Workspace File" }
    static var description: IntentDescription {
        IntentDescription("Read a text file from the persistent Just Bash Documents workspace.")
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
        IntentDescription("Create or replace a text file in the persistent Just Bash Documents workspace.")
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
            intent: RunCodexPromptIntent(),
            phrases: [
                "Run Codex in \(.applicationName)",
                "Ask Codex with \(.applicationName)"
            ],
            shortTitle: "Run Codex",
            systemImageName: "sparkles"
        )
        AppShortcut(
            intent: QueueBackgroundCodexPromptIntent(),
            phrases: [
                "Queue Codex in \(.applicationName)",
                "Run Codex in the background with \(.applicationName)"
            ],
            shortTitle: "Queue Codex",
            systemImageName: "clock.badge.checkmark"
        )
        AppShortcut(
            intent: RefreshBackgroundCodexJobsIntent(),
            phrases: [
                "Refresh Codex jobs in \(.applicationName)",
                "Check Codex background jobs with \(.applicationName)"
            ],
            shortTitle: "Refresh Jobs",
            systemImageName: "arrow.clockwise"
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
    if rawPath == "~" {
        return "/Users/coder"
    }
    if rawPath.hasPrefix("~/") {
        return "/Users/coder/" + String(rawPath.dropFirst(2))
    }
    if rawPath.hasPrefix("/") {
        return rawPath
    }
    let trimmed = rawPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    return trimmed.isEmpty ? "/Users/coder/Documents" : "/Users/coder/Documents/\(trimmed)"
}
