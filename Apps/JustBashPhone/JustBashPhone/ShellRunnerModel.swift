import Foundation
import Observation
import JustBashFS

@MainActor
@Observable
final class ShellRunnerModel {
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
