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

    struct FileSection: Identifiable {
        let id: String
        let title: String
        let entries: [VirtualDirectoryEntry]
    }

    struct FilePreview: Identifiable {
        let id: String
        let path: String
        let contents: String

        init(path: String, contents: String) {
            self.id = path
            self.path = path
            self.contents = contents
        }
    }

    static let samples: [SampleScript] = [
        .init(
            id: "word-count",
            title: "Word Count",
            description: "Run ordinary shell commands against a seeded file.",
            script: """
            echo "Input preview:"
            cat /data/input.txt
            echo
            echo "Word count:"
            wc -w /data/input.txt
            """
        ),
        .init(
            id: "transform",
            title: "Transform",
            description: "Write output into the virtual filesystem and inspect it.",
            script: """
            cat /data/log.txt | grep ERROR | sed 's/ERROR/[error]/' > /tmp/errors.txt
            echo "Saved:"
            cat /tmp/errors.txt
            """
        ),
        .init(
            id: "workspace",
            title: "Persistent Workspace",
            description: "Write a file into /workspace so it survives app relaunches.",
            script: """
            date > /workspace/last-run.txt
            echo "Workspace files:"
            ls -la /workspace
            echo
            echo "last-run.txt:"
            cat /workspace/last-run.txt
            """
        ),
        .init(
            id: "js-exec",
            title: "JS Runtime",
            description: "Exercise the embedded JavaScript runtime on-device.",
            script: #"""
            js-exec -c 'const fs = require("fs"); const text = fs.readFileSync("/data/input.txt", "utf8"); console.log(text.toUpperCase())'
            """#
        ),
    ]

    var selectedSampleID: SampleScript.ID
    var script: String
    var stdout = ""
    var stderr = ""
    var exitCode: Int?
    var isRunning = false
    var fileSections: [FileSection] = []
    var filePreview: FilePreview?

    init() {
        let sample = Self.samples[0]
        self.selectedSampleID = sample.id
        self.script = sample.script
    }

    func loadInitialState() async {
        await refreshFileSections()
    }

    func applySelectedSample() {
        guard let sample = Self.samples.first(where: { $0.id == selectedSampleID }) else {
            return
        }
        script = sample.script
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
        filePreview = nil
        Task {
            await SandboxService.shared.reset()
            await refreshFileSections()
        }
    }

    func open(_ entry: VirtualDirectoryEntry) {
        guard !entry.isDirectory else { return }

        Task {
            let contents = (try? await SandboxService.shared.readFile(entry.path)) ?? "<binary or unreadable>"
            await MainActor.run {
                filePreview = FilePreview(path: entry.path, contents: contents)
            }
        }
    }

    private func refreshFileSections() async {
        let directories: [(path: String, title: String)] = [
            ("/", "Root"),
            ("/data", "Data"),
            ("/workspace", "Workspace"),
            ("/tmp", "Temp"),
            ("/home/user", "Home"),
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
