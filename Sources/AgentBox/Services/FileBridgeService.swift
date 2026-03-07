import Foundation

actor FileBridgeService {
    private let fileManager = FileManager.default

    func ensureDirectories(for settings: AgentBoxSettings) throws {
        try ensureDirectory(settings.inboxURL)
        try ensureDirectory(settings.processingURL)
        try ensureDirectory(settings.completedURL)
    }

    func listInboxTextFiles(in settings: AgentBoxSettings) throws -> [URL] {
        let contents = try fileManager.contentsOfDirectory(
            at: settings.inboxURL,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        )

        return contents
            .filter { $0.pathExtension.lowercased() == "txt" }
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
    }

    func moveToProcessing(_ file: URL, in settings: AgentBoxSettings) throws -> URL {
        let destination = uniqueDestination(for: file, in: settings.processingURL)
        try fileManager.moveItem(at: file, to: destination)
        return destination
    }

    func moveToCompleted(_ processingFile: URL, in settings: AgentBoxSettings) throws -> URL {
        let destination = uniqueDestination(for: processingFile, in: settings.completedURL)
        try fileManager.moveItem(at: processingFile, to: destination)
        return destination
    }

    func writeResultArtifact(for missionFileName: String, result: String, in settings: AgentBoxSettings) throws -> URL {
        let stem = URL(fileURLWithPath: missionFileName).deletingPathExtension().lastPathComponent
        let artifactName = "\(stem)_result.md"
        let artifactURL = uniqueDestination(forFileName: artifactName, in: settings.completedURL)
        let data = Data(result.utf8)
        try data.write(to: artifactURL, options: .atomic)
        return artifactURL
    }

    private func ensureDirectory(_ url: URL) throws {
        if !fileManager.fileExists(atPath: url.path) {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    private func uniqueDestination(for sourceURL: URL, in directory: URL) -> URL {
        uniqueDestination(forFileName: sourceURL.lastPathComponent, in: directory)
    }

    private func uniqueDestination(forFileName fileName: String, in directory: URL) -> URL {
        let target = directory.appendingPathComponent(fileName, isDirectory: false)
        if !fileManager.fileExists(atPath: target.path) {
            return target
        }

        let ext = target.pathExtension
        let base = target.deletingPathExtension().lastPathComponent
        let stamped = "\(base)_\(Int(Date().timeIntervalSince1970))"
        if ext.isEmpty {
            return directory.appendingPathComponent(stamped, isDirectory: false)
        }
        return directory.appendingPathComponent("\(stamped).\(ext)", isDirectory: false)
    }
}
