import Foundation
import Observation
import CodexCore
import JustBashFS
import Security

enum CodexPhoneSettings {
    static let defaultModel = "gpt-5.4"
    private static let keychainService = "com.mweinbach.JustBashPhone.codex"
    private static let keychainAccount = "openai-api-key"
    private static let oauthKeychainService = "com.mweinbach.JustBashPhone.codex.oauth"
    private static let oauthKeychainAccount = "chatgpt"

    struct ProviderSelection {
        let provider: any ModelProvider
        let signature: String
        let status: String
        let usesAPIKey: Bool
    }

    static func makeOAuthStore() -> CodexKeychainAuthStore {
        CodexKeychainAuthStore(service: oauthKeychainService, account: oauthKeychainAccount)
    }

    static func makeOAuthConfig() -> CodexChatGPTAuthConfig {
        CodexChatGPTAuthConfig(codexHome: CodexDefaultLocations.codexHome)
    }

    static func loadChatGPTSession() async throws -> AuthSession? {
        try await makeOAuthStore().loadSession()
    }

    static func clearChatGPTSession() async throws {
        try await makeOAuthStore().clear()
    }

    static func makeProvider(apiKeyFallback: String) async throws -> ProviderSelection {
        let store = makeOAuthStore()
        let config = makeOAuthConfig()
        if let session = try await store.loadSession(), session.mode == .chatGPT {
            let auth = ChatGPTAuthProvider(session: session, codexStore: store, config: config)
            let account = session.accountID ?? session.workspaceID ?? "chatgpt"
            return ProviderSelection(
                provider: OpenAIResponsesClient(auth: auth, options: .chatGPTCodexBackend),
                signature: "chatgpt:\(account)",
                status: "Using ChatGPT sign-in",
                usesAPIKey: false
            )
        }

        let key = apiKeyFallback.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw CodexCoreError.authError("Sign in with ChatGPT or add an OpenAI API key before starting Codex.")
        }
        return ProviderSelection(
            provider: OpenAIResponsesClient(auth: APIKeyAuthProvider(apiKey: key)),
            signature: "api:\(key.hashValue)",
            status: "Using API key",
            usesAPIKey: true
        )
    }

    static func loadAPIKey() -> String {
        var query = keychainBaseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return ""
        }
        return value
    }

    static func saveAPIKey(_ value: String) {
        var query = keychainBaseQuery()
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty, let data = value.data(using: .utf8) else { return }
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(query as CFDictionary, nil)
    }

    private static func keychainBaseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
    }
}

@MainActor
@Observable
final class ShellRunnerModel {
    struct CodexTranscriptItem: Identifiable, Hashable {
        enum Role: String {
            case user = "User"
            case assistant = "Codex"
            case event = "Event"
            case error = "Error"
        }

        let id = UUID()
        let role: Role
        let text: String
    }

    struct SampleScript: Identifiable, Hashable {
        let id: String
        let title: String
        let description: String
        let script: String
    }

    struct SamplePython: Identifiable, Hashable {
        let id: String
        let title: String
        let description: String
        let code: String
    }

    struct FileSection: Identifiable {
        let id: String
        let title: String
        let entries: [VirtualDirectoryEntry]
    }

    struct FilePreview: Identifiable {
        let id: String
        let path: String
        let contents: String
        let fileURL: URL

        init(path: String, contents: String, fileURL: URL) {
            self.id = path
            self.path = path
            self.contents = contents
            self.fileURL = fileURL
        }
    }

    static let samples: [SampleScript] = [
        .init(
            id: "word-count",
            title: "Word Count",
            description: "Run ordinary shell commands against a seeded file.",
            script: """
            echo "Input preview:"
            cat ~/Downloads/input.txt
            echo
            echo "Word count:"
            wc -w ~/Downloads/input.txt
            """
        ),
        .init(
            id: "transform",
            title: "Transform",
            description: "Write output into the virtual filesystem and inspect it.",
            script: """
            cat ~/Documents/log.txt | grep ERROR | sed 's/ERROR/[error]/' > ~/Documents/errors.txt
            echo "Saved:"
            cat ~/Documents/errors.txt
            """
        ),
        .init(
            id: "workspace",
            title: "Persistent Documents",
            description: "Write a file into ~/Documents so it survives app relaunches.",
            script: """
            date > ~/Documents/last-run.txt
            echo "Documents files:"
            ls -la ~/Documents
            echo
            echo "last-run.txt:"
            cat ~/Documents/last-run.txt
            """
        ),
        .init(
            id: "js-exec",
            title: "JS Runtime",
            description: "Exercise the embedded JavaScript runtime on-device.",
            script: #"""
            js-exec -c 'const fs = require("fs"); const text = fs.readFileSync(process.env.HOME + "/Downloads/input.txt", "utf8"); console.log(text.toUpperCase())'
            """#
        ),
        .init(
            id: "primary-runtime-skills-check",
            title: "Skill Runtime Check",
            description: "Write an on-device capability report for the cached Documents, Presentations, and Spreadsheets skills.",
            script: """
            primary-runtime-skills-check
            echo
            echo "Saved report:"
            cat /workspace/primary-runtime-skills-ios-report.json
            """
        ),
    ]

    static let pythonSamples: [SamplePython] = [
        .init(
            id: "hello",
            title: "Hello Python",
            description: "Verify the embedded interpreter and print its version.",
            code: """
            import sys
            print("Hello from Python")
            print(sys.version)
            """
        ),
        .init(
            id: "workspace",
            title: "Write Workspace File",
            description: "Create a persistent workspace file from Python.",
            code: """
            from pathlib import Path
            target = Path.cwd() / "python-note.txt"
            target.write_text("Python wrote this on-device.\\n")
            print(target.read_text(), end="")
            """
        ),
        .init(
            id: "list",
            title: "List Workspace",
            description: "Inspect the persistent workspace directory from Python.",
            code: """
            from pathlib import Path
            for path in sorted(Path.cwd().iterdir()):
                kind = "dir" if path.is_dir() else "file"
                print(f"{kind}: {path.name}")
            """
        ),
    ]

    var selectedSampleID: SampleScript.ID
    var script: String
    var selectedPythonSampleID: SamplePython.ID
    var pythonCode: String
    var stdout = ""
    var stderr = ""
    var exitCode: Int?
    var isRunning = false
    var isRunningPython = false
    var pythonStatus = ""
    var pythonAvailable = false
    var pythonStdout = ""
    var pythonStderr = ""
    var pythonExitCode: Int?
    var fileSections: [FileSection] = []
    var filePreview: FilePreview?
    var newFileName = "note.txt"
    var newFileContents = "Saved from Just Bash on iOS.\n"
    var codexPrompt = "Inspect the workspace and suggest the next useful file change."
    var codexAPIKey = CodexPhoneSettings.loadAPIKey()
    var codexModel = CodexPhoneSettings.defaultModel
    var codexStatus = "Idle"
    var codexAuthStatus = "Checking sign-in"
    var codexOAuthUserCode = ""
    var codexOAuthVerificationURL: URL?
    var codexTranscript: [CodexTranscriptItem] = []
    var codexStreamingText = ""
    var codexThreadID: String?
    var codexTurnID: String?
    var isCodexRunning = false
    var isCodexOAuthRunning = false

    @ObservationIgnored private var codexRuntime: CodexRuntime?
    @ObservationIgnored private var codexRuntimeAuthSignature: String?
    @ObservationIgnored private var codexRuntimeModel: String?

    init() {
        let sample = Self.samples[0]
        let pythonSample = Self.pythonSamples[0]
        self.selectedSampleID = sample.id
        self.script = sample.script
        self.selectedPythonSampleID = pythonSample.id
        self.pythonCode = pythonSample.code
    }

    func loadInitialState() async {
        await SandboxService.shared.runPythonSmokeIfRequested()
        await SandboxService.shared.runPrimaryRuntimeSkillsSmokeIfRequested()
        pythonStatus = await SandboxService.shared.pythonAvailabilitySummary()
        pythonAvailable = await SandboxService.shared.isPythonAvailable()
        await refreshCodexAuthStatus()
        await refreshFileSections()
    }

    func applySelectedSample() {
        guard let sample = Self.samples.first(where: { $0.id == selectedSampleID }) else {
            return
        }
        script = sample.script
    }

    func applySelectedPythonSample() {
        guard let sample = Self.pythonSamples.first(where: { $0.id == selectedPythonSampleID }) else {
            return
        }
        pythonCode = sample.code
    }

    func runScript() {
        guard !isRunning else { return }
        let currentScript = script
        isRunning = true

        Task {
            let result = await SandboxService.shared.run(currentScript)
            await MainActor.run {
                stdout = result.stdout
                stderr = result.stderr
                exitCode = result.exitCode
                isRunning = false
            }
            await refreshFileSections()
        }
    }

    func saveCodexAPIKey() {
        let trimmed = codexAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        codexAPIKey = trimmed
        CodexPhoneSettings.saveAPIKey(trimmed)
        codexRuntime = nil
        codexRuntimeAuthSignature = nil
        codexAuthStatus = trimmed.isEmpty ? "API key cleared" : "API key saved"
        codexStatus = codexAuthStatus
    }

    func signInCodexWithChatGPT() {
        guard !isCodexOAuthRunning else { return }
        isCodexOAuthRunning = true
        codexAuthStatus = "Requesting ChatGPT sign-in"
        codexOAuthUserCode = ""
        codexOAuthVerificationURL = nil

        Task {
            do {
                let store = CodexPhoneSettings.makeOAuthStore()
                let client = CodexChatGPTAuthClient(config: CodexPhoneSettings.makeOAuthConfig(), store: store)
                let deviceCode = try await client.requestDeviceCode()
                await MainActor.run {
                    codexOAuthUserCode = deviceCode.userCode
                    codexOAuthVerificationURL = deviceCode.verificationURL
                    codexAuthStatus = "Enter code \(deviceCode.userCode)"
                }
                let session = try await client.completeDeviceCodeLogin(deviceCode)
                await MainActor.run {
                    codexOAuthUserCode = ""
                    codexOAuthVerificationURL = nil
                    codexRuntime = nil
                    codexRuntimeAuthSignature = nil
                    codexAuthStatus = "Signed in with ChatGPT\(session.accountID.map { " (\($0))" } ?? "")"
                    isCodexOAuthRunning = false
                }
            } catch {
                await MainActor.run {
                    codexTranscript.append(CodexTranscriptItem(role: .error, text: String(describing: error)))
                    codexAuthStatus = "ChatGPT sign-in failed"
                    isCodexOAuthRunning = false
                }
            }
        }
    }

    func signOutCodexChatGPT() {
        Task {
            do {
                try await CodexPhoneSettings.clearChatGPTSession()
                await MainActor.run {
                    codexRuntime = nil
                    codexRuntimeAuthSignature = nil
                    codexOAuthUserCode = ""
                    codexOAuthVerificationURL = nil
                    codexAuthStatus = codexAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Signed out" : "Using API key"
                }
            } catch {
                await MainActor.run {
                    codexTranscript.append(CodexTranscriptItem(role: .error, text: String(describing: error)))
                    codexAuthStatus = "Sign out failed"
                }
            }
        }
    }

    private func refreshCodexAuthStatus() async {
        do {
            if let session = try await CodexPhoneSettings.loadChatGPTSession(), session.mode == .chatGPT {
                codexAuthStatus = "Signed in with ChatGPT\(session.accountID.map { " (\($0))" } ?? "")"
            } else if !codexAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                codexAuthStatus = "Using API key"
            } else {
                codexAuthStatus = "Not signed in"
            }
        } catch {
            codexAuthStatus = "Could not read saved sign-in"
        }
    }

    func sendCodexPrompt() {
        let prompt = codexPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        if isCodexRunning {
            steerCodexTurn(prompt)
            return
        }
        isCodexRunning = true
        codexStatus = "Starting"
        codexStreamingText = ""
        codexTranscript.append(CodexTranscriptItem(role: .user, text: prompt))

        Task {
            do {
                let runtime = try await makeCodexRuntime()
                let threadID: String
                if let existingThreadID = codexThreadID {
                    threadID = existingThreadID
                } else {
                    let thread = try await runtime.createThread(title: "Just Bash iOS")
                    threadID = thread.id
                    await MainActor.run { codexThreadID = thread.id }
                }

                let handle = try await runtime.startTurn(threadID: threadID, input: TurnInput(prompt))
                await MainActor.run {
                    codexTurnID = handle.turnID
                    codexStatus = "Streaming"
                }
                try await consumeCodexEvents(handle.events)
                await refreshFileSections()
            } catch {
                await MainActor.run {
                    codexTranscript.append(CodexTranscriptItem(role: .error, text: String(describing: error)))
                    codexStatus = "Failed"
                    isCodexRunning = false
                    codexTurnID = nil
                    codexStreamingText = ""
                }
            }
        }
    }

    func steerCodexTurn(_ text: String? = nil) {
        let prompt = (text ?? codexPrompt).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, let runtime = codexRuntime, let threadID = codexThreadID, let turnID = codexTurnID else { return }
        codexTranscript.append(CodexTranscriptItem(role: .user, text: prompt))
        codexStatus = "Steering"
        Task {
            do {
                try await runtime.steer(threadID: threadID, expectedTurnID: turnID, text: prompt)
            } catch {
                await MainActor.run {
                    codexTranscript.append(CodexTranscriptItem(role: .error, text: String(describing: error)))
                    codexStatus = "Steer failed"
                }
            }
        }
    }

    func interruptCodexTurn() {
        guard let runtime = codexRuntime, let threadID = codexThreadID else { return }
        Task {
            do {
                try await runtime.interrupt(threadID: threadID, expectedTurnID: codexTurnID)
            } catch {
                await MainActor.run {
                    codexTranscript.append(CodexTranscriptItem(role: .error, text: String(describing: error)))
                }
            }
            await MainActor.run {
                codexStatus = "Interrupted"
                isCodexRunning = false
                codexTurnID = nil
            }
        }
    }

    private func makeCodexRuntime() async throws -> CodexRuntime {
        let key = codexAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let selection = try await CodexPhoneSettings.makeProvider(apiKeyFallback: key)
        if let codexRuntime, codexRuntimeAuthSignature == selection.signature, codexRuntimeModel == codexModel {
            return codexRuntime
        }
        if selection.usesAPIKey {
            CodexPhoneSettings.saveAPIKey(key)
        }
        let configuration = AgentConfiguration(
            model: codexModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? CodexPhoneSettings.defaultModel : codexModel,
            instructions: "You are Codex running fully on iOS inside Just Bash. Use the JustBash-backed shell and file tools for workspace work. Use primary-runtime-skills-check before document, presentation, or spreadsheet artifact work.",
            approvalPolicy: .never,
            sandboxPolicy: .workspaceWrite
        )
        let runtime = try await SandboxService.shared.makeCodexRuntime(modelProvider: selection.provider, configuration: configuration)
        codexRuntime = runtime
        codexRuntimeAuthSignature = selection.signature
        codexRuntimeModel = configuration.model
        codexAuthStatus = selection.status
        return runtime
    }

    private func consumeCodexEvents(_ events: AsyncThrowingStream<AgentEvent, Error>) async throws {
        for try await event in events {
            await MainActor.run {
                apply(event)
            }
        }
        await MainActor.run {
            isCodexRunning = false
            codexTurnID = nil
            if codexStatus == "Streaming" {
                codexStatus = "Complete"
            }
        }
    }

    private func apply(_ event: AgentEvent) {
        switch event {
        case .turnStarted(_, let turnID):
            codexTurnID = turnID
            codexStatus = "Running"
        case .itemDelta(_, let delta):
            codexStreamingText += delta
        case .itemCompleted(let item):
            if item.kind == .assistantMessage, let content = item.payload["content"]?.stringValue, !content.isEmpty {
                codexTranscript.append(CodexTranscriptItem(role: .assistant, text: content))
                codexStreamingText = ""
            }
        case .toolStarted(let call):
            codexTranscript.append(CodexTranscriptItem(role: .event, text: "Started \(call.name)"))
        case .toolCompleted(let call, let result):
            let state = result.isError ? "failed" : "finished"
            codexTranscript.append(CodexTranscriptItem(role: result.isError ? .error : .event, text: "\(call.name) \(state): \(result.summary)"))
        case .approvalRequested(let request):
            codexTranscript.append(CodexTranscriptItem(role: .event, text: "Approval requested for \(request.toolName)"))
        case .turnCompleted(_, _, let status, _):
            codexStatus = status.rawValue.capitalized
            isCodexRunning = false
            codexTurnID = nil
        case .warning(let message):
            codexTranscript.append(CodexTranscriptItem(role: .event, text: message))
        case .error(let message):
            codexTranscript.append(CodexTranscriptItem(role: .error, text: message))
            codexStatus = "Failed"
            isCodexRunning = false
            codexTurnID = nil
        default:
            break
        }
    }

    func resetSandbox() {
        guard !isRunning else { return }
        stdout = ""
        stderr = ""
        exitCode = nil
        pythonStdout = ""
        pythonStderr = ""
        pythonExitCode = nil
        filePreview = nil
        Task {
            await SandboxService.shared.reset()
            await refreshFileSections()
        }
    }

    func runPython() {
        guard !isRunningPython else { return }
        let currentCode = pythonCode
        isRunningPython = true

        Task {
            let result = await SandboxService.shared.runPython(currentCode)
            await MainActor.run {
                pythonStdout = result.stdout
                pythonStderr = result.stderr
                pythonExitCode = result.exitCode
                isRunningPython = false
            }
            await refreshFileSections()
        }
    }

    func open(_ entry: VirtualDirectoryEntry) {
        guard !entry.isDirectory else { return }

        Task {
            let contents = (try? await SandboxService.shared.readFile(entry.path)) ?? "<binary or unreadable>"
            let fileURL = await SandboxService.shared.fileURL(forVirtualPath: entry.path)
            await MainActor.run {
                filePreview = FilePreview(path: entry.path, contents: contents, fileURL: fileURL)
            }
        }
    }

    func saveNewFile() {
        let name = newFileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        Task {
            try? await SandboxService.shared.writeFile(name, contents: newFileContents)
            await refreshFileSections()
        }
    }

    func move(_ entry: VirtualDirectoryEntry, toDirectory destinationDirectory: String) {
        guard !entry.isDirectory else { return }
        Task {
            _ = await SandboxService.shared.moveFile(from: entry.path, toDirectory: destinationDirectory)
            await refreshFileSections()
        }
    }

    func delete(_ entry: VirtualDirectoryEntry) {
        Task {
            _ = await SandboxService.shared.deleteFile(entry.path)
            await refreshFileSections()
        }
    }

    private func refreshFileSections() async {
        let directories: [(path: String, title: String)] = [
            ("/", "Root"),
            ("/Users/coder", "Home"),
            ("/Users/coder/Documents", "Documents"),
            ("/Users/coder/Downloads", "Downloads"),
            ("/Users/coder/Desktop", "Desktop"),
            ("/tmp", "Temp"),
            ("/workspace", "Workspace"),
        ]

        var sections: [FileSection] = []
        for directory in directories {
            if let entries = try? await SandboxService.shared.listDirectory(directory.path), !entries.isEmpty {
                sections.append(FileSection(id: directory.path, title: directory.title, entries: entries))
            }
        }

        await MainActor.run {
            fileSections = sections
        }
    }
}
