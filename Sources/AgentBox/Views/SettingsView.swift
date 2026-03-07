import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: MissionControlViewModel

    @State private var settingsFilePath = ""
    @State private var stateFilePath = ""

    // Model options - CLI only
    private let cliModels = ["claude-cli", "codex-cli", "gemini-cli", "minimax-cli"]
    private let ollamaModels = ["ollama llama3", "ollama qwen3.5"]

    private var allModels: [String] {
        cliModels + ollamaModels
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            Form {
                Section("Manager Model (Planner)") {
                    modelPicker(selection: $viewModel.settings.managerModelId, models: allModels)
                }

                Section("Worker Model (Executor)") {
                    modelPicker(selection: $viewModel.settings.workerModelId, models: allModels)

                    if viewModel.settings.workerModelId.hasPrefix("ollama ") {
                        HStack {
                            Image(systemName: "info.circle")
                                .foregroundStyle(.blue)
                            Text("Ollama runs locally - no API key needed!")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Dispatcher") {
                    HStack {
                        Text("Poll interval")
                        Slider(
                            value: Binding(
                                get: { viewModel.settings.pollingIntervalMinutes },
                                set: { viewModel.settings.pollingIntervalMinutes = $0 }
                            ),
                            in: 1...120,
                            step: 1
                        )
                        Text("\(Int(viewModel.settings.pollingIntervalMinutes)) min")
                            .foregroundStyle(.secondary)
                            .frame(width: 80, alignment: .trailing)
                    }
                }

                Section("Directories") {
                    directoryRow(label: "Inbox", path: $viewModel.settings.inboxPath)
                    directoryRow(label: "Processing", path: $viewModel.settings.processingPath)
                    directoryRow(label: "Completed", path: $viewModel.settings.completedPath)
                }

                Section("CLI Configuration") {
                    Text("Configure CLI commands. Use {PROMPT} placeholder for the instruction.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    cliCommandRow(name: "Claude CLI", command: $viewModel.settings.claudeCLICommand)
                    cliCommandRow(name: "Codex CLI", command: $viewModel.settings.codexCLICommand)
                    cliCommandRow(name: "Gemini CLI", command: $viewModel.settings.geminiCLICommand)
                    cliCommandRow(name: "MiniMax CLI", command: $viewModel.settings.minimaxCLICommand)
                    cliCommandRow(name: "Ollama CLI", command: $viewModel.settings.ollamaCLICommand)

                    HStack {
                        Text("Ollama Model")
                            .frame(width: 100, alignment: .leading)
                        TextField("llama3", text: $viewModel.settings.ollamaModelName)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                Section("Files") {
                    LabeledContent("Settings.json") {
                        Text(settingsFilePath)
                            .textSelection(.enabled)
                            .font(.footnote.monospaced())
                    }

                    LabeledContent("State.json") {
                        Text(stateFilePath)
                            .textSelection(.enabled)
                            .font(.footnote.monospaced())
                    }
                }

                HStack {
                    Button("Save Settings") {
                        Task { await viewModel.saveSettings() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)

                    Button("Run Poll Now") {
                        Task { await viewModel.pollNow() }
                    }
                    .buttonStyle(.bordered)

                    Spacer()
                }
            }
            .scrollContentBackground(.hidden)
            .padding(20)
        }
        .task {
            settingsFilePath = await viewModel.settingsPath
            stateFilePath = await viewModel.statePath
        }
    }

    @ViewBuilder
    private func modelPicker(selection: Binding<String>, models: [String]) -> some View {
        Picker("Model", selection: selection) {
            ForEach(models, id: \.self) { model in
                Text(model).tag(model)
            }
        }
    }

    @ViewBuilder
    private func cliCommandRow(name: String, command: Binding<String>) -> some View {
        HStack {
            Text(name)
                .font(.subheadline)
                .frame(width: 100, alignment: .leading)
            TextField("command", text: command)
                .textFieldStyle(.roundedBorder)
                .font(.caption.monospaced())
        }
    }

    @ViewBuilder
    private func directoryRow(label: String, path: Binding<String>) -> some View {
        HStack {
            TextField(label, text: path)
                .font(.body.monospaced())

            Button("Choose") {
                chooseDirectory(for: path)
            }
            .buttonStyle(.bordered)
        }
    }

    private func chooseDirectory(for path: Binding<String>) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.resolvesAliases = true
        panel.treatsFilePackagesAsDirectories = true
        panel.prompt = "Select"
        panel.directoryURL = bestStartingDirectory(from: path.wrappedValue)

        if panel.runModal() == .OK, let url = panel.url {
            path.wrappedValue = url.standardizedFileURL.path
        }
    }

    private func bestStartingDirectory(from rawPath: String) -> URL {
        let fileManager = FileManager.default
        let expandedPath = NSString(string: rawPath).expandingTildeInPath

        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: expandedPath, isDirectory: &isDirectory), isDirectory.boolValue {
            return URL(fileURLWithPath: expandedPath, isDirectory: true)
        }

        let parent = URL(fileURLWithPath: expandedPath, isDirectory: false).deletingLastPathComponent()
        var parentIsDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: parent.path, isDirectory: &parentIsDirectory), parentIsDirectory.boolValue {
            return parent
        }

        return fileManager.homeDirectoryForCurrentUser
    }
}
