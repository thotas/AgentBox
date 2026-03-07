import Foundation

actor StateStore {
    private let fileManager = FileManager.default
    private let stateURL: URL

    init(rootDirectoryName: String = "AgentBox") {
        let root = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(rootDirectoryName, isDirectory: true)
        self.stateURL = root.appendingPathComponent("State.json", isDirectory: false)
    }

    func loadOrCreate() throws -> MissionState {
        try ensureParentDirectory()

        if fileManager.fileExists(atPath: stateURL.path) {
            let data = try Data(contentsOf: stateURL)
            return try JSONDecoder().decode(MissionState.self, from: data)
        }

        let empty = MissionState()
        try save(empty)
        return empty
    }

    func save(_ state: MissionState) throws {
        try ensureParentDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try data.write(to: stateURL, options: .atomic)
    }

    func fileURL() -> URL {
        stateURL
    }

    private func ensureParentDirectory() throws {
        let parent = stateURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parent.path) {
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        }
    }
}
