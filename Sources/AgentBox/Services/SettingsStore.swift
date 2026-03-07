import Foundation

actor SettingsStore {
    private let fileManager = FileManager.default
    private let settingsURL: URL

    init(rootDirectoryName: String = "AgentBox") {
        let root = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(rootDirectoryName, isDirectory: true)
        self.settingsURL = root.appendingPathComponent("Settings.json", isDirectory: false)
    }

    func loadOrCreate() throws -> AgentBoxSettings {
        try ensureParentDirectory()

        if fileManager.fileExists(atPath: settingsURL.path) {
            let data = try Data(contentsOf: settingsURL)
            return try JSONDecoder().decode(AgentBoxSettings.self, from: data)
        }

        let defaults = AgentBoxSettings.defaultValue()
        try save(defaults)
        return defaults
    }

    func save(_ settings: AgentBoxSettings) throws {
        try ensureParentDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings)
        try data.write(to: settingsURL, options: .atomic)
    }

    func fileURL() -> URL {
        settingsURL
    }

    private func ensureParentDirectory() throws {
        let parent = settingsURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parent.path) {
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        }
    }
}
