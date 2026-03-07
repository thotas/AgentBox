import Foundation
import XCTest
@testable import AgentBox

final class AgentBoxTests: XCTestCase {
    func testDefaultSettingsUseExpectedFolderStructure() {
        let settings = AgentBoxSettings.defaultValue()

        XCTAssertTrue(settings.inboxPath.hasSuffix("/AgentBox/01_Inbox"))
        XCTAssertTrue(settings.processingPath.hasSuffix("/AgentBox/02_Processing"))
        XCTAssertTrue(settings.completedPath.hasSuffix("/AgentBox/03_Completed"))
        XCTAssertEqual(settings.pollingIntervalSeconds, 900)
    }

    func testMissionStateRoundTrip() throws {
        var state = MissionState()
        state.missions.append(
            MissionRecord(
                fileName: "example.txt",
                originalInstructionPath: "/tmp/example.txt",
                processingPath: "/tmp/p/example.txt",
                status: .awaitingApproval,
                managerPlan: "test-plan"
            )
        )

        let encoded = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(MissionState.self, from: encoded)

        XCTAssertEqual(decoded.missions.count, 1)
        XCTAssertEqual(decoded.missions[0].fileName, "example.txt")
        XCTAssertEqual(decoded.missions[0].managerPlan, "test-plan")
    }

    func testSavingAPIKeysDoesNotThrowWhenKeychainIsUnavailable() {
        let service = KeychainService()
        let keys = APIKeys(claude: "a", gemini: "g", minimax: "m", codex: "c")
        XCTAssertNoThrow(try service.saveKeys(keys))
    }

    func testAPIKeysExposeCodexKey() {
        XCTAssertEqual(APIKeys.empty.codex, "")
    }

    func testAPIKeysFallbackWhenKeychainFails() throws {
        setenv("AGENTBOX_FORCE_KEYCHAIN_FAILURE", "1", 1)
        defer { unsetenv("AGENTBOX_FORCE_KEYCHAIN_FAILURE") }

        let service = KeychainService()
        let keys = APIKeys(claude: "aa", gemini: "gg", minimax: "mm", codex: "cc")
        let destination = try service.saveKeys(keys)
        let loaded = service.loadKeys()

        guard case let .fallbackFile(path) = destination else {
            XCTFail("Expected fallback storage when keychain is forced to fail")
            return
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
        XCTAssertEqual(loaded.codex, "cc")
    }

    func testFileBridgeCreatesDirectoriesAndMovesFiles() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentBoxTests_\(UUID().uuidString)", isDirectory: true)

        let settings = AgentBoxSettings(
            managerModel: "m",
            workerModel: "w1",
            pollingIntervalSeconds: 900,
            inboxPath: root.appendingPathComponent("01_Inbox", isDirectory: true).path,
            processingPath: root.appendingPathComponent("02_Processing", isDirectory: true).path,
            completedPath: root.appendingPathComponent("03_Completed", isDirectory: true).path,
            pythonExecutable: "/usr/bin/python3"
        )

        let bridge = FileBridgeService()
        try await bridge.ensureDirectories(for: settings)

        let inboxFile = settings.inboxURL.appendingPathComponent("task.txt")
        try Data("hello".utf8).write(to: inboxFile)

        let listed = try await bridge.listInboxTextFiles(in: settings)
        XCTAssertEqual(listed.count, 1)

        let processingFile = try await bridge.moveToProcessing(inboxFile, in: settings)
        XCTAssertTrue(FileManager.default.fileExists(atPath: processingFile.path))

        let artifact = try await bridge.writeResultArtifact(for: "task.txt", result: "# ok", in: settings)
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.path))

        let completedFile = try await bridge.moveToCompleted(processingFile, in: settings)
        XCTAssertTrue(FileManager.default.fileExists(atPath: completedFile.path))
    }

    func testPythonRunnerPlanAndExecution() async throws {
        setenv("AGENTBOX_FAKE_LLM", "1", 1)
        defer { unsetenv("AGENTBOX_FAKE_LLM") }

        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentBoxBridge_\(UUID().uuidString).txt")
        try Data("Summarize this task.".utf8).write(to: tempFile)

        let settings = AgentBoxSettings(
            managerModel: "anthropic sonnet",
            workerModel: "google gemini",
            pollingIntervalSeconds: 900,
            inboxPath: "/tmp",
            processingPath: "/tmp",
            completedPath: "/tmp",
            pythonExecutable: "/usr/bin/python3"
        )
        let keys = APIKeys(claude: "", gemini: "", minimax: "", codex: "")

        let runner = PythonRunner()
        let plan = try await runner.generatePlan(inputFile: tempFile, settings: settings, keys: keys)
        let result = try await runner.executeMission(inputFile: tempFile, settings: settings, keys: keys)

        XCTAssertTrue(plan.contains("Bridge mode: live"))
        XCTAssertTrue(plan.contains("Manager model"))
        XCTAssertTrue(plan.contains("Worker model"))
        XCTAssertTrue(result.contains("# AgentBox Mission Result"))
        XCTAssertTrue(result.contains("Bridge mode: live"))
        XCTAssertTrue(result.contains("## Final Deliverable"))
    }

    func testPythonRunnerSurfacesBridgeErrorMessage() async throws {
        unsetenv("AGENTBOX_FAKE_LLM")
        unsetenv("AGENTBOX_ENABLE_FALLBACK")
        setenv("OPENAI_API_KEY", "", 1)
        setenv("CODEX_API_KEY", "", 1)

        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentBoxBridgeError_\(UUID().uuidString).txt")
        try Data("Need a lunch plan.".utf8).write(to: tempFile)

        let settings = AgentBoxSettings(
            managerModel: "anthropic sonnet",
            workerModel: "codex",
            pollingIntervalSeconds: 900,
            inboxPath: "/tmp",
            processingPath: "/tmp",
            completedPath: "/tmp",
            pythonExecutable: "/usr/bin/python3"
        )
        let keys = APIKeys(claude: "", gemini: "", minimax: "", codex: "")

        let runner = PythonRunner()

        do {
            _ = try await runner.executeMission(inputFile: tempFile, settings: settings, keys: keys)
            XCTFail("Expected executeMission to fail without API keys")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Missing API key"))
        }
    }
}
