import Foundation

enum PythonRunnerError: Error, LocalizedError {
    case missingScript
    case launchFailed(String)
    case processFailed(String)
    case invalidResponse(String)
    case fallbackResponse(String)

    var errorDescription: String? {
        switch self {
        case .missingScript:
            return "Could not locate crew_bridge.py in app resources."
        case .launchFailed(let message):
            return "Failed to launch Python bridge: \(message)"
        case .processFailed(let message):
            return "Python bridge failed: \(message)"
        case .invalidResponse(let message):
            return "Unexpected Python bridge response: \(message)"
        case .fallbackResponse(let message):
            return "Using fallback response: \(message)"
        }
    }
}

actor PythonRunner {
    private let decoder = JSONDecoder()

    // MARK: - Public API

    func generatePlan(inputFile: URL, settings: AgentBoxSettings, keys: APIKeys) async throws -> String {
        // Check if we should use CLI mode
        if settings.useCLIMode {
            let instruction = try String(contentsOf: inputFile, encoding: .utf8)
            let cliRunner = CLIRunner()
            return try await cliRunner.generatePlan(
                inputFile: inputFile,
                managerModel: settings.managerModelId,
                instruction: instruction,
                settings: settings
            )
        }

        // Fallback to Python bridge
        let output = try await runBridge(mode: "plan", inputFile: inputFile, settings: settings, keys: keys)
        if let error = output.error {
            throw PythonRunnerError.processFailed(error)
        }
        guard let plan = output.plan, !plan.isEmpty else {
            throw PythonRunnerError.invalidResponse("Missing plan in response")
        }
        return plan
    }

    func executeMission(inputFile: URL, settings: AgentBoxSettings, keys: APIKeys) async throws -> String {
        // Check if we should use CLI mode
        if settings.useCLIMode {
            let instruction = try String(contentsOf: inputFile, encoding: .utf8)
            let cliRunner = CLIRunner()
            return try await cliRunner.executeMission(
                inputFile: inputFile,
                managerModel: settings.managerModelId,
                workerModel: settings.workerModelId,
                instruction: instruction,
                settings: settings
            )
        }

        // Fallback to Python bridge
        let output = try await runBridge(mode: "execute", inputFile: inputFile, settings: settings, keys: keys)
        if let error = output.error {
            throw PythonRunnerError.processFailed(error)
        }
        guard let result = output.result, !result.isEmpty else {
            throw PythonRunnerError.invalidResponse("Missing result in response")
        }
        return result
    }

    // MARK: - Bridge Execution

    private func runBridge(mode: String, inputFile: URL, settings: AgentBoxSettings, keys: APIKeys) async throws -> AgentBridgeOutput {
        guard let scriptURL = Bundle.module.url(forResource: "crew_bridge", withExtension: "py", subdirectory: "Scripts") else {
            throw PythonRunnerError.missingScript
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: settings.pythonExecutable)
        process.arguments = [
            scriptURL.path,
            "--mode", mode,
            "--input", inputFile.path,
            "--manager", settings.managerModelId,
            "--worker", settings.workerModelId
        ]

        var env = ProcessInfo.processInfo.environment
        if !keys.claude.isEmpty {
            env["ANTHROPIC_API_KEY"] = keys.claude
        }
        if !keys.gemini.isEmpty {
            env["GEMINI_API_KEY"] = keys.gemini
        }
        if !keys.minimax.isEmpty {
            env["MINIMAX_API_KEY"] = keys.minimax
        }
        if !keys.codex.isEmpty {
            env["OPENAI_API_KEY"] = keys.codex
            env["CODEX_API_KEY"] = keys.codex
        }
        if !keys.openai.isEmpty {
            env["OPENAI_API_KEY"] = keys.openai
        }
        process.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            throw PythonRunnerError.launchFailed(error.localizedDescription)
        }

        process.waitUntilExit()

        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        let stdoutText = String(data: stdoutData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderrText = String(data: stderrData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard process.terminationStatus == 0 else {
            // Try to parse error from stdout JSON
            if let bridgeOutput = try? decoder.decode(AgentBridgeOutput.self, from: stdoutData),
               let bridgeError = bridgeOutput.error,
               !bridgeError.isEmpty {
                throw PythonRunnerError.processFailed(bridgeError)
            }

            if !stderrText.isEmpty {
                throw PythonRunnerError.processFailed(stderrText)
            }

            if !stdoutText.isEmpty {
                throw PythonRunnerError.processFailed(stdoutText)
            }

            throw PythonRunnerError.processFailed("exit code \(process.terminationStatus)")
        }

        do {
            return try decoder.decode(AgentBridgeOutput.self, from: stdoutData)
        } catch {
            // If JSON parsing fails but we have text output, create a fallback response
            if !stdoutText.isEmpty {
                return AgentBridgeOutput(
                    plan: mode == "plan" ? stdoutText : nil,
                    result: mode == "execute" ? stdoutText : nil,
                    error: nil,
                    modelUsed: settings.managerModelId,
                    executionTime: nil
                )
            }

            let body = stdoutText.isEmpty ? "<no stdout>" : stdoutText
            throw PythonRunnerError.invalidResponse("\(error.localizedDescription). Raw: \(body)")
        }
    }
}

// MARK: - Legacy Bridge Output (for compatibility)

struct PythonBridgeOutput: Codable {
    var plan: String?
    var result: String?
    var error: String?
}
