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
    }
}
