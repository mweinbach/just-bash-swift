import SwiftUI

struct ContentView: View {
    @State private var model = ShellRunnerModel()

    var body: some View {
        NavigationStack {
            List {
                Section("Sample") {
                    Picker("Sample Script", selection: $model.selectedSampleID) {
                        ForEach(ShellRunnerModel.samples) { sample in
                            Text(sample.title).tag(sample.id)
                        }
                    }
                    .pickerStyle(.navigationLink)

                    if let sample = ShellRunnerModel.samples.first(where: { $0.id == model.selectedSampleID }) {
                        Text(sample.description)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Button("Load Sample") {
                        model.applySelectedSample()
                    }
                }

                Section("Script") {
                    TextEditor(text: $model.script)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 220)

                    HStack {
                        Button {
                            model.runScript()
                        } label: {
                            Label(model.isRunning ? "Running…" : "Run Script", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isRunning)

                        Button("Reset Sandbox") {
                            model.resetSandbox()
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.isRunning)
                    }

                    if let exitCode = model.exitCode {
                        Text("Exit code: \(exitCode)")
                            .font(.footnote.monospaced())
                            .foregroundStyle(exitCode == 0 ? .green : .red)
                    }
                }

                Section("Output") {
                    if model.stdout.isEmpty && model.stderr.isEmpty {
                        Text("Run a script to see stdout and stderr.")
                            .foregroundStyle(.secondary)
                    } else {
                        if !model.stdout.isEmpty {
                            outputBlock(title: "stdout", text: model.stdout)
                        }
                        if !model.stderr.isEmpty {
                            outputBlock(title: "stderr", text: model.stderr, tint: .red)
                        }
                    }
                }

                Section("Python") {
                    Text(model.pythonStatus)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if model.pythonAvailable {
                        Picker("Python Sample", selection: $model.selectedPythonSampleID) {
                            ForEach(ShellRunnerModel.pythonSamples) { sample in
                                Text(sample.title).tag(sample.id)
                            }
                        }
                        .pickerStyle(.navigationLink)

                        if let sample = ShellRunnerModel.pythonSamples.first(where: { $0.id == model.selectedPythonSampleID }) {
                            Text(sample.description)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }

                        TextEditor(text: $model.pythonCode)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 180)

                        HStack {
                            Button("Load Python Sample") {
                                model.applySelectedPythonSample()
                            }
                            .buttonStyle(.bordered)

                            Button {
                                model.runPython()
                            } label: {
                                Label(model.isRunningPython ? "Running…" : "Run Python", systemImage: "play.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.isRunningPython)
                        }

                        if let exitCode = model.pythonExitCode {
                            Text("Python exit code: \(exitCode)")
                                .font(.footnote.monospaced())
                                .foregroundStyle(exitCode == 0 ? .green : .red)
                        }

                        if model.pythonStdout.isEmpty && model.pythonStderr.isEmpty {
                            Text("Run Python to see stdout and stderr.")
                                .foregroundStyle(.secondary)
                        } else {
                            if !model.pythonStdout.isEmpty {
                                outputBlock(title: "python stdout", text: model.pythonStdout)
                            }
                            if !model.pythonStderr.isEmpty {
                                outputBlock(title: "python stderr", text: model.pythonStderr, tint: .red)
                            }
                        }
                    }
                }

                ForEach(model.fileSections) { section in
                    Section(section.title) {
                        ForEach(section.entries, id: \.path) { entry in
                            Button {
                                model.open(entry)
                            } label: {
                                HStack {
                                    Image(systemName: entry.isDirectory ? "folder.fill" : "doc.text")
                                        .foregroundStyle(entry.isDirectory ? .blue : .secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entry.name)
                                        Text(entry.path)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(entry.isDirectory)
                        }
                    }
                }
            }
            .navigationTitle("Just Bash")
            .task {
                await model.loadInitialState()
            }
            .sheet(item: $model.filePreview) { preview in
                NavigationStack {
                    ScrollView {
                        Text(preview.contents)
                            .font(.system(.body, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                    .navigationTitle(preview.path)
                    .navigationBarTitleDisplayMode(.inline)
                }
            }
        }
    }

    private func outputBlock(title: String, text: String, tint: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(text)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}
