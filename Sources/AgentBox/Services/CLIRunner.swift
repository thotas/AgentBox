import Foundation

// MARK: - CLI Runner Error

enum CLIRunnerError: Error, LocalizedError {
    case cliNotFound(String)
    case launchFailed(String)
    case processFailed(String)
    case invalidResponse(String)
    case timeout
    case modelNotAvailable(String)
    case agentNotAvailable(String)

    var errorDescription: String? {
        switch self {
        case .cliNotFound(let path):
            return "CLI not found at: \(path)"
        case .launchFailed(let message):
            return "Failed to launch CLI: \(message)"
        case .processFailed(let message):
            return "CLI execution failed: \(message)"
        case .invalidResponse(let message):
            return "Invalid CLI response: \(message)"
        case .timeout:
            return "CLI execution timed out"
        case .modelNotAvailable(let model):
            return "Model not available: \(model)"
        case .agentNotAvailable(let agent):
            return "Agent not available: \(agent)"
        }
    }
}

// MARK: - Agent Availability

struct AgentAvailability {
    var claude: Bool = false
    var codex: Bool = false
    var gemini: Bool = false
    var ollama: Bool = false
    var minimax: Bool = false

    var availableAgents: [String] {
        var agents: [String] = []
        if claude { agents.append("claude") }
        if codex { agents.append("codex") }
        if gemini { agents.append("gemini") }
        if ollama { agents.append("ollama") }
        if minimax { agents.append("minimax") }
        return agents
    }

    func isAvailable(_ agent: String) -> Bool {
        switch agent.lowercased() {
        case "claude": return claude
        case "codex": return codex
        case "gemini": return gemini
        case "ollama": return ollama
        case "minimax": return minimax
        default: return claude // fallback to claude
        }
    }
}

// MARK: - CLI Runner

actor CLIRunner {
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private let timeout: TimeInterval = 180
    private var cachedAvailability: AgentAvailability?

    // MARK: - Orchestration Script Support

    /// Check if orchestration script is configured and available
    func isOrchestrationScriptAvailable(settings: AgentBoxSettings) -> Bool {
        guard settings.useOrchestrateScript,
              !settings.orchestrateScriptPath.isEmpty else {
            return false
        }
        return FileManager.default.fileExists(atPath: settings.orchestrateScriptPath)
    }

    /// Run orchestration script and return output
    private func runOrchestrationScript(arguments: [String], settings: AgentBoxSettings) async throws -> String {
        let scriptPath = settings.orchestrateScriptPath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptPath] + arguments

        // Set environment variables from settings
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "CLAUDECODE")
        env["CLAUDE_CLI"] = settings.claudeCLICommand.split(separator: " ").first.map(String.init) ?? "/opt/homebrew/bin/claude"
        env["CODEX_CLI"] = settings.codexCLICommand.split(separator: " ").first.map(String.init) ?? "/opt/homebrew/bin/codex"
        env["GEMINI_CLI"] = settings.geminiCLICommand.split(separator: " ").first.map(String.init) ?? "/opt/homebrew/bin/gemini"
        env["OLLAMA_CLI"] = settings.ollamaCLICommand.split(separator: " ").first.map(String.init) ?? "/usr/local/bin/ollama"
        env["OLLAMA_MODEL"] = settings.ollamaModelName
        env["MINIMAX_BASE_URL"] = settings.minimaxBaseURL
        env["MINIMAX_AUTH_TOKEN"] = settings.minimaxAuthToken
        env["MINIMAX_MODEL"] = settings.minimaxModelName
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        try await waitForProcess(process, timeout: timeout)

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        let stdoutText = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderrText = String(data: stderrData, encoding: .utf8) ?? ""

        if process.terminationStatus != 0 && stdoutText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let errorMsg = stderrText.isEmpty ? "Exit code: \(process.terminationStatus)" : stderrText
            throw CLIRunnerError.processFailed(errorMsg)
        }

        return stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Run orchestration script with stdin input
    private func runOrchestrationScriptWithStdin(arguments: [String], stdinInput: String, settings: AgentBoxSettings) async throws -> String {
        let scriptPath = settings.orchestrateScriptPath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptPath] + arguments

        // Set environment variables from settings
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "CLAUDECODE")
        env["CLAUDE_CLI"] = settings.claudeCLICommand.split(separator: " ").first.map(String.init) ?? "/opt/homebrew/bin/claude"
        env["CODEX_CLI"] = settings.codexCLICommand.split(separator: " ").first.map(String.init) ?? "/opt/homebrew/bin/codex"
        env["GEMINI_CLI"] = settings.geminiCLICommand.split(separator: " ").first.map(String.init) ?? "/opt/homebrew/bin/gemini"
        env["OLLAMA_CLI"] = settings.ollamaCLICommand.split(separator: " ").first.map(String.init) ?? "/usr/local/bin/ollama"
        env["OLLAMA_MODEL"] = settings.ollamaModelName
        env["MINIMAX_BASE_URL"] = settings.minimaxBaseURL
        env["MINIMAX_AUTH_TOKEN"] = settings.minimaxAuthToken
        env["MINIMAX_MODEL"] = settings.minimaxModelName
        process.environment = env

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        // Write stdin input
        stdinPipe.fileHandleForWriting.write(stdinInput.data(using: .utf8)!)
        stdinPipe.fileHandleForWriting.closeFile()

        try await waitForProcess(process, timeout: timeout)

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        let stdoutText = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderrText = String(data: stderrData, encoding: .utf8) ?? ""

        if process.terminationStatus != 0 && stdoutText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let errorMsg = stderrText.isEmpty ? "Exit code: \(process.terminationStatus)" : stderrText
            throw CLIRunnerError.processFailed(errorMsg)
        }

        return stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Public API

    func generatePlan(inputFile: URL, managerModel: String, instruction: String, settings: AgentBoxSettings) async throws -> String {
        let result = try await executeWithModel(
            modelId: managerModel,
            mode: "plan",
            instruction: instruction,
            settings: settings
        )

        if let error = result.error {
            throw CLIRunnerError.processFailed(error)
        }

        guard let plan = result.plan, !plan.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let errorMsg = result.error ?? "Empty plan response from CLI"
            throw CLIRunnerError.invalidResponse(errorMsg)
        }

        return plan
    }

    func executeMission(inputFile: URL, managerModel: String, workerModel: String, instruction: String, settings: AgentBoxSettings) async throws -> String {
        let result = try await executeWithModel(
            modelId: managerModel,
            workerModelId: workerModel,
            mode: "execute",
            instruction: instruction,
            settings: settings
        )

        if let error = result.error {
            throw CLIRunnerError.processFailed(error)
        }

        guard let resultText = result.result, !resultText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let errorMsg = result.error ?? "Empty result response from CLI"
            throw CLIRunnerError.invalidResponse(errorMsg)
        }

        return resultText
    }

    // MARK: - Agent Validation

    /// Check which agents are available (mirrors orchestrate.sh check_prereqs)
    func checkAgentAvailability(settings: AgentBoxSettings) async -> AgentAvailability {
        // Return cached if recent
        if let cached = cachedAvailability {
            return cached
        }

        // Check if we should use the orchestration script for availability check
        if isOrchestrationScriptAvailable(settings: settings) {
            return await checkAgentAvailabilityViaScript(settings: settings)
        }

        var availability = AgentAvailability()

        // Check Claude CLI
        let claudePath = settings.claudeCLICommand.split(separator: " ").first.map(String.init) ?? "/opt/homebrew/bin/claude"
        if FileManager.default.fileExists(atPath: claudePath) {
            availability.claude = true
        }

        // Check Codex CLI
        let codexPath = settings.codexCLICommand.split(separator: " ").first.map(String.init) ?? "/opt/homebrew/bin/codex"
        if FileManager.default.fileExists(atPath: codexPath) {
            availability.codex = true
        }

        // Check Gemini CLI
        let geminiPath = settings.geminiCLICommand.split(separator: " ").first.map(String.init) ?? "/opt/homebrew/bin/gemini"
        if FileManager.default.fileExists(atPath: geminiPath) {
            availability.gemini = true
        }

        // Check Ollama
        let ollamaPath = settings.ollamaCLICommand.split(separator: " ").first.map(String.init) ?? "/usr/local/bin/ollama"
        if FileManager.default.fileExists(atPath: ollamaPath) {
            // Check if model is available
            do {
                let listOutput = try await runShellCommand("\(ollamaPath) list", timeout: 30)
                let modelName = settings.ollamaModelName.isEmpty ? "llama3" : settings.ollamaModelName
                if listOutput.contains(modelName) || listOutput.contains("\(modelName):") {
                    availability.ollama = true
                }
            } catch {
                // Ollama not available
            }
        }

        // Check MiniMax (requires claude CLI + auth token)
        if availability.claude && !settings.minimaxAuthToken.isEmpty {
            availability.minimax = true
        }

        cachedAvailability = availability
        return availability
    }

    /// Check agent availability via orchestrate.sh script
    private func checkAgentAvailabilityViaScript(settings: AgentBoxSettings) async -> AgentAvailability {
        do {
            let output = try await runOrchestrationScript(
                arguments: ["check_prereqs"],
                settings: settings
            )

            // Parse JSON output
            guard let data = output.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return AgentAvailability()
            }

            var availability = AgentAvailability()
            availability.claude = json["claude"] as? Bool ?? false
            availability.codex = json["codex"] as? Bool ?? false
            availability.gemini = json["gemini"] as? Bool ?? false
            availability.ollama = json["ollama"] as? Bool ?? false
            availability.minimax = json["minimax"] as? Bool ?? false

            cachedAvailability = availability
            return availability
        } catch {
            return AgentAvailability()
        }
    }

    /// Get fallback agent if requested agent is not available
    func getFallbackAgent(for agent: String, availability: AgentAvailability) -> String {
        if availability.isAvailable(agent) {
            return agent
        }

        // Try fallback hierarchy
        if availability.claude {
            return "claude"
        }
        if availability.ollama {
            return "ollama"
        }

        return "claude" // ultimate fallback
    }

    // MARK: - Orchestration API

    /// Phase 1: Call the manager CLI to generate a JSON execution plan (mirrors orchestrate.sh plan_task).
    func generateOrchestrationPlan(instruction: String, settings: AgentBoxSettings) async throws -> OrchestratorPlan {
        // Check if we should use the orchestration script
        if isOrchestrationScriptAvailable(settings: settings) {
            return try await generateOrchestrationPlanViaScript(instruction: instruction, settings: settings)
        }

        // Use native Swift implementation
        let ollamaModel = settings.ollamaModelName.isEmpty ? "llama3" : settings.ollamaModelName

        // Get project context if set
        var projectContext = ""
        if !settings.projectDirectory.isEmpty && FileManager.default.fileExists(atPath: settings.projectDirectory) {
            projectContext = """

            Project directory: \(settings.projectDirectory)
            NOTE: Agents that need to read/write files MUST set "needs_files": true in their subtask JSON.
                  Claude and minimax agents with needs_files=true will run in agentic mode (can read/write files).
                  Ollama cannot access files — only assign text/analysis tasks to it.
            """
        }

        let prompt = """
        IMPORTANT: Respond ONLY with valid JSON, no markdown fences, no explanation.

        You are an expert AI orchestrator. Break down the following task into parallel sub-tasks and assign each to the most appropriate agent.

        Available agents:
        - claude: Best for complex reasoning, architecture, code review, file editing, implementation
        - codex: Best for code generation, refactoring, implementation
        - gemini: Best for research, documentation, broad knowledge tasks
        - ollama (local/\(ollamaModel)): Best for simple text tasks, summarization, formatting (NO file access)
        - minimax (kimi-k2.5): Best for creative tasks, multilingual content, alternative perspective, file editing

        Task: \(instruction)
        \(projectContext)

        Respond ONLY with valid JSON in this exact structure (no markdown, no backticks):
        {
          "task_summary": "one-line summary",
          "subtasks": [
            {
              "id": "task_1",
              "title": "Short title",
              "description": "Detailed description of what this agent should do",
              "agent": "claude|codex|gemini|ollama|minimax",
              "needs_files": false,
              "depends_on": [],
              "priority": 1
            }
          ],
          "consolidation_notes": "Instructions for how to consolidate results"
        }
        """

        // Use stdin for planning (mirrors orchestrate.sh)
        let output = try await runCLIClaudeWithStdin(prompt: prompt, settings: settings, mode: "plan")
        let raw = output

        // Strip markdown fences if present
        let cleaned = raw
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Extract JSON object boundaries
        guard let startIdx = cleaned.firstIndex(of: "{"),
              let endIdx = cleaned.lastIndex(of: "}") else {
            throw CLIRunnerError.invalidResponse("No JSON object found in plan response")
        }

        let jsonString = String(cleaned[startIdx...endIdx])
        guard let data = jsonString.data(using: .utf8) else {
            throw CLIRunnerError.invalidResponse("Could not encode plan JSON as UTF-8")
        }

        do {
            return try JSONDecoder().decode(OrchestratorPlan.self, from: data)
        } catch {
            throw CLIRunnerError.invalidResponse("Could not decode orchestration plan: \(error.localizedDescription)")
        }
    }

    /// Generate orchestration plan via orchestrate.sh script
    private func generateOrchestrationPlanViaScript(instruction: String, settings: AgentBoxSettings) async throws -> OrchestratorPlan {
        // Write instruction to temp file
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent("orchestrate_plan_\(UUID().uuidString).txt")
        try instruction.write(to: tempFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let output = try await runOrchestrationScript(
            arguments: ["plan_task", tempFile.path],
            settings: settings
        )

        // Clean output - remove markdown fences
        let cleaned = output
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Extract JSON object boundaries
        guard let startIdx = cleaned.firstIndex(of: "{"),
              let endIdx = cleaned.lastIndex(of: "}") else {
            throw CLIRunnerError.invalidResponse("No JSON object found in plan response")
        }

        let jsonString = String(cleaned[startIdx...endIdx])
        guard let data = jsonString.data(using: .utf8) else {
            throw CLIRunnerError.invalidResponse("Could not encode plan JSON as UTF-8")
        }

        do {
            return try JSONDecoder().decode(OrchestratorPlan.self, from: data)
        } catch {
            throw CLIRunnerError.invalidResponse("Could not decode orchestration plan: \(error.localizedDescription)")
        }
    }

    /// Phase 2: Execute a single subtask with the assigned agent (mirrors orchestrate.sh run_*_agent).
    /// Injects context from dependency results if provided.
    /// Returns (result, error) - error is non-nil if subtask failed but orchestration should continue
    func executeSubtask(_ subtask: OrchestratorSubtask, previousResults: [String: String], settings: AgentBoxSettings) async -> (result: String?, error: Error?) {
        // Check if we should use the orchestration script
        if isOrchestrationScriptAvailable(settings: settings) {
            return await executeSubtaskViaScript(subtask, previousResults: previousResults, settings: settings)
        }

        // Use native Swift implementation
        let description: String
        if !subtask.dependsOn.isEmpty {
            let depContext = subtask.dependsOn
                .compactMap { depId -> String? in
                    guard let result = previousResults[depId] else { return nil }
                    return "--- Output from \(depId) ---\n\(result)"
                }
                .joined(separator: "\n\n")
            description = depContext.isEmpty
                ? subtask.description
                : subtask.description + "\n\nContext from previous tasks:\n\n" + depContext
        } else {
            description = subtask.description
        }

        // Check agent availability and get fallback if needed
        let availability = await checkAgentAvailability(settings: settings)
        let agent = getFallbackAgent(for: subtask.agent, availability: availability)

        do {
            let result = try await dispatchToAgent(agent, description: description, needsFiles: subtask.needsFiles, settings: settings)
            return (result, nil)
        } catch {
            // Return error but don't throw - allows orchestration to continue
            return (nil, error)
        }
    }

    /// Execute subtask via orchestrate.sh script
    private func executeSubtaskViaScript(_ subtask: OrchestratorSubtask, previousResults: [String: String], settings: AgentBoxSettings) async -> (result: String?, error: Error?) {
        // Build subtask JSON
        var subtaskJson: [String: Any] = [
            "id": subtask.id,
            "agent": subtask.agent,
            "description": subtask.description,
            "needs_files": subtask.needsFiles,
            "project_directory": settings.projectDirectory
        ]

        // Add depends_on as array
        if !subtask.dependsOn.isEmpty {
            subtaskJson["depends_on"] = subtask.dependsOn
        }

        guard let subtaskData = try? JSONSerialization.data(withJSONObject: subtaskJson),
              let subtaskString = String(data: subtaskData, encoding: .utf8) else {
            return (nil, CLIRunnerError.invalidResponse("Could not serialize subtask JSON"))
        }

        // Serialize previous results
        var prevResultsJson: [String: String] = [:]
        if !previousResults.isEmpty {
            prevResultsJson = previousResults
        }

        let prevResultsData = try? JSONSerialization.data(withJSONObject: prevResultsJson)
        let prevResultsString = prevResultsData.flatMap { String(data: $0, encoding: .utf8) } ?? "null"

        do {
            let output = try await runOrchestrationScriptWithStdin(
                arguments: ["run_agent", subtaskString, prevResultsString],
                stdinInput: "",
                settings: settings
            )
            return (output, nil)
        } catch {
            return (nil, error)
        }
    }

    /// Phase 3: Consolidate all subtask results into a final report (mirrors orchestrate.sh consolidate).
    func consolidateResults(originalTask: String, plan: OrchestratorPlan, taskResults: [String: String], settings: AgentBoxSettings) async throws -> String {
        // Check if we should use the orchestration script
        if isOrchestrationScriptAvailable(settings: settings) {
            return try await consolidateResultsViaScript(originalTask: originalTask, plan: plan, taskResults: taskResults, settings: settings)
        }

        // Use native Swift implementation
        let allResults = plan.subtasks
            .compactMap { subtask -> String? in
                guard let result = taskResults[subtask.id] else { return nil }
                return "## Result: \(subtask.id)\n\n\(result)"
            }
            .joined(separator: "\n\n---\n\n")

        let prompt = """
        You are consolidating results from multiple AI agents.

        Original task: \(originalTask)

        Consolidation instructions: \(plan.consolidationNotes)

        Sub-task results:
        \(allResults)

        Please:
        1. Review all agent outputs for quality and correctness
        2. Identify any conflicts, gaps, or errors
        3. Synthesize a coherent final result
        4. Produce a final consolidated output that fully satisfies the original task
        5. End with a brief ## Quality Assessment section noting any concerns

        Format your response as clean Markdown.
        """

        // Use stdin for consolidation (mirrors orchestrate.sh)
        return try await runCLIClaudeWithStdin(prompt: prompt, settings: settings, mode: "execute")
    }

    /// Consolidate results via orchestrate.sh script
    private func consolidateResultsViaScript(originalTask: String, plan: OrchestratorPlan, taskResults: [String: String], settings: AgentBoxSettings) async throws -> String {
        // Serialize plan and results
        let planData = try JSONEncoder().encode(plan)
        let planString = String(data: planData, encoding: .utf8) ?? "{}"

        let resultsData = try JSONSerialization.data(withJSONObject: taskResults)
        let resultsString = String(data: resultsData, encoding: .utf8) ?? "{}"

        let output = try await runOrchestrationScriptWithStdin(
            arguments: ["consolidate", originalTask, planString, resultsString],
            stdinInput: "",
            settings: settings
        )

        return output
    }

    /// Dispatch a prompt to the named agent type with needsFiles handling (mirrors orchestrate.sh).
    /// When needsFiles=true and projectDirectory is set, runs in agentic mode with file access.
    private func dispatchToAgent(_ agent: String, description: String, needsFiles: Bool, settings: AgentBoxSettings) async throws -> String {
        switch agent.lowercased() {
        case "codex":
            return try await runCodexAgent(description: description, needsFiles: needsFiles, settings: settings)
        case "gemini":
            return try await runGeminiAgent(description: description, needsFiles: needsFiles, settings: settings)
        case "ollama":
            return try await runOllamaAgent(description: description, settings: settings)
        case "minimax":
            return try await runMinimaxAgent(description: description, needsFiles: needsFiles, settings: settings)
        default: // "claude" and any unknown agent
            return try await runClaudeAgent(description: description, needsFiles: needsFiles, settings: settings)
        }
    }

    // MARK: - Agent Implementations (matching orchestrate.sh patterns)

    /// Run Claude agent - supports both print mode (stdin) and agentic mode (file access)
    private func runClaudeAgent(description: String, needsFiles: Bool, settings: AgentBoxSettings) async throws -> String {
        let projectDir = settings.projectDirectory
        let hasProjectDir = !projectDir.isEmpty && FileManager.default.fileExists(atPath: projectDir)

        if needsFiles && hasProjectDir {
            // Agentic mode: run WITHOUT --print for tool access (mirrors orchestrate.sh)
            let cliPath = settings.claudeCLICommand.split(separator: " ").first.map(String.init) ?? "/opt/homebrew/bin/claude"
            let result = try await runProcessWithAgenticMode(
                executable: cliPath,
                arguments: ["--dangerously-skip-permissions", "--no-session-persistence", description],
                workingDirectory: projectDir,
                timeout: timeout
            )
            return result
        } else {
            // Print mode: text only via stdin (mirrors orchestrate.sh)
            return try await runCLIClaudeWithStdin(prompt: description, settings: settings, mode: "execute")
        }
    }

    /// Run MiniMax agent - uses Claude CLI with env overrides (mirrors orchestrate.sh)
    private func runMinimaxAgent(description: String, needsFiles: Bool, settings: AgentBoxSettings) async throws -> String {
        let cliPath = settings.claudeCLICommand.split(separator: " ").first.map(String.init) ?? "/opt/homebrew/bin/claude"
        let projectDir = settings.projectDirectory
        let hasProjectDir = !projectDir.isEmpty && FileManager.default.fileExists(atPath: projectDir)

        if needsFiles && hasProjectDir {
            // Agentic mode with env overrides
            return try await runProcessWithAgenticModeAndEnv(
                executable: cliPath,
                arguments: [
                    "--dangerously-skip-permissions",
                    "--no-session-persistence",
                    "--model", settings.minimaxModelName,
                    description
                ],
                workingDirectory: projectDir,
                timeout: timeout,
                envOverrides: [
                    "ANTHROPIC_BASE_URL": settings.minimaxBaseURL,
                    "ANTHROPIC_AUTH_TOKEN": settings.minimaxAuthToken
                ]
            )
        } else {
            // Print mode with env overrides (mirrors orchestrate.sh)
            return try await runCLIWithStdinAndEnv(
                executable: cliPath,
                arguments: ["--print", "--model", settings.minimaxModelName],
                prompt: description,
                timeout: timeout,
                envOverrides: [
                    "ANTHROPIC_BASE_URL": settings.minimaxBaseURL,
                    "ANTHROPIC_AUTH_TOKEN": settings.minimaxAuthToken
                ]
            )
        }
    }

    /// Run Codex agent
    private func runCodexAgent(description: String, needsFiles: Bool, settings: AgentBoxSettings) async throws -> String {
        let cliPath = settings.codexCLICommand.split(separator: " ").first.map(String.init) ?? "/opt/homebrew/bin/codex"
        let projectDir = settings.projectDirectory
        let hasProjectDir = !projectDir.isEmpty && FileManager.default.fileExists(atPath: projectDir)

        if needsFiles && hasProjectDir {
            // Run in project directory
            return try await runCLIWithStdin(
                executable: cliPath,
                arguments: ["--quiet"],
                prompt: description,
                timeout: timeout,
                workingDirectory: projectDir
            )
        } else {
            // Print mode via stdin
            return try await runCLIWithStdin(
                executable: cliPath,
                arguments: ["--quiet"],
                prompt: description,
                timeout: timeout
            )
        }
    }

    /// Run Gemini agent
    private func runGeminiAgent(description: String, needsFiles: Bool, settings: AgentBoxSettings) async throws -> String {
        let cliPath = settings.geminiCLICommand.split(separator: " ").first.map(String.init) ?? "/opt/homebrew/bin/gemini"
        let projectDir = settings.projectDirectory
        let hasProjectDir = !projectDir.isEmpty && FileManager.default.fileExists(atPath: projectDir)

        if needsFiles && hasProjectDir {
            // Run in project directory
            return try await runCLIWithStdin(
                executable: cliPath,
                arguments: [],
                prompt: description,
                timeout: timeout,
                workingDirectory: projectDir
            )
        } else {
            // Print mode via stdin
            return try await runCLIWithStdin(
                executable: cliPath,
                arguments: [],
                prompt: description,
                timeout: timeout
            )
        }
    }

    /// Run Ollama agent (no file access - text only)
    private func runOllamaAgent(description: String, settings: AgentBoxSettings) async throws -> String {
        let cliPath = settings.ollamaCLICommand.split(separator: " ").first.map(String.init) ?? "/usr/local/bin/ollama"
        let modelName = settings.ollamaModelName.isEmpty ? "llama3" : settings.ollamaModelName

        // Check if model is available
        let listOutput = try await runShellCommand("\(cliPath) list", timeout: 30)
        if !listOutput.contains(modelName) && !listOutput.contains("\(modelName):") {
            // Try to pull the model
            _ = try await runShellCommand("\(cliPath) pull \(modelName)", timeout: 300)
        }

        // Use stdin (mirrors orchestrate.sh)
        return try await runCLIWithStdin(
            executable: cliPath,
            arguments: ["run", modelName],
            prompt: description,
            timeout: timeout
        )
    }

    // MARK: - Private Execution Helpers

    /// Run Claude CLI with stdin (mirrors orchestrate.sh pattern)
    private func runCLIClaudeWithStdin(prompt: String, settings: AgentBoxSettings, mode: String) async throws -> String {
        let cliPath = settings.claudeCLICommand.split(separator: " ").first.map(String.init) ?? "/opt/homebrew/bin/claude"
        return try await runCLIWithStdin(
            executable: cliPath,
            arguments: ["--print"],
            prompt: prompt,
            timeout: timeout
        )
    }

    /// Run CLI with stdin input (matches orchestrate.sh < prompt_file pattern)
    private func runCLIWithStdin(executable: String, arguments: [String], prompt: String, timeout: TimeInterval, workingDirectory: String? = nil) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        // Set working directory if specified
        if let workDir = workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workDir)
        }

        // Clean environment
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "CLAUDECODE")
        process.environment = env

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        // Write prompt to stdin
        stdinPipe.fileHandleForWriting.write(prompt.data(using: .utf8)!)
        stdinPipe.fileHandleForWriting.closeFile()

        // Wait with timeout
        try await waitForProcess(process, timeout: timeout)

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        let stdoutText = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderrText = String(data: stderrData, encoding: .utf8) ?? ""

        // Check for errors - but allow non-zero exit if we got output
        if process.terminationStatus != 0 && stdoutText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let errorMsg = stderrText.isEmpty ? "Exit code: \(process.terminationStatus)" : stderrText
            throw CLIRunnerError.processFailed(errorMsg)
        }

        return stripANSI(stdoutText).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Run CLI with stdin and environment overrides
    private func runCLIWithStdinAndEnv(executable: String, arguments: [String], prompt: String, timeout: TimeInterval, envOverrides: [String: String]) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        // Apply env overrides
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "CLAUDECODE")
        for (key, value) in envOverrides {
            env[key] = value
        }
        process.environment = env

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        // Write prompt to stdin
        stdinPipe.fileHandleForWriting.write(prompt.data(using: .utf8)!)
        stdinPipe.fileHandleForWriting.closeFile()

        // Wait with timeout
        try await waitForProcess(process, timeout: timeout)

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        let stdoutText = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderrText = String(data: stderrData, encoding: .utf8) ?? ""

        if process.terminationStatus != 0 && stdoutText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let errorMsg = stderrText.isEmpty ? "Exit code: \(process.terminationStatus)" : stderrText
            throw CLIRunnerError.processFailed(errorMsg)
        }

        return stripANSI(stdoutText).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Run process in agentic mode (no --print, with tool access)
    private func runProcessWithAgenticMode(executable: String, arguments: [String], workingDirectory: String, timeout: TimeInterval) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)

        // Clean environment
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "CLAUDECODE")
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        // Wait with timeout
        try await waitForProcess(process, timeout: timeout)

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        let stdoutText = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderrText = String(data: stderrData, encoding: .utf8) ?? ""

        if process.terminationStatus != 0 && stdoutText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let errorMsg = stderrText.isEmpty ? "Exit code: \(process.terminationStatus)" : stderrText
            throw CLIRunnerError.processFailed(errorMsg)
        }

        return stripANSI(stdoutText).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Run process in agentic mode with env overrides
    private func runProcessWithAgenticModeAndEnv(executable: String, arguments: [String], workingDirectory: String, timeout: TimeInterval, envOverrides: [String: String]) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)

        // Apply env overrides
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "CLAUDECODE")
        for (key, value) in envOverrides {
            env[key] = value
        }
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        // Wait with timeout
        try await waitForProcess(process, timeout: timeout)

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        let stdoutText = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderrText = String(data: stderrData, encoding: .utf8) ?? ""

        if process.terminationStatus != 0 && stdoutText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let errorMsg = stderrText.isEmpty ? "Exit code: \(process.terminationStatus)" : stderrText
            throw CLIRunnerError.processFailed(errorMsg)
        }

        return stripANSI(stdoutText).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Wait for process with timeout
    private func waitForProcess(_ process: Process, timeout: TimeInterval) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                process.waitUntilExit()
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                process.terminate()
                throw CLIRunnerError.timeout
            }

            try await group.next()
            group.cancelAll()
        }
    }

    // MARK: - Legacy Support (for non-orchestration use)

    private func executeWithModel(modelId: String, workerModelId: String? = nil, mode: String, instruction: String, settings: AgentBoxSettings) async throws -> AgentBridgeOutput {
        // Parse model identifier
        let (provider, actualModelId) = parseModelIdentifier(modelId)

        switch provider {
        case .claudeCLI:
            let result = try await runCLIClaudeWithStdin(prompt: instruction, settings: settings, mode: mode)
            return AgentBridgeOutput(plan: mode == "plan" ? result : nil, result: mode != "plan" ? result : nil, error: nil, modelUsed: modelId, executionTime: 0)
        case .codexCLI:
            let result = try await runCodexAgent(description: instruction, needsFiles: false, settings: settings)
            return AgentBridgeOutput(plan: nil, result: result, error: nil, modelUsed: modelId, executionTime: 0)
        case .geminiCLI:
            let result = try await runGeminiAgent(description: instruction, needsFiles: false, settings: settings)
            return AgentBridgeOutput(plan: nil, result: result, error: nil, modelUsed: modelId, executionTime: 0)
        case .minimaxCLI:
            let result = try await runMinimaxAgent(description: instruction, needsFiles: false, settings: settings)
            return AgentBridgeOutput(plan: nil, result: result, error: nil, modelUsed: modelId, executionTime: 0)
        case .ollama:
            let result = try await runOllamaAgent(description: instruction, settings: settings)
            return AgentBridgeOutput(plan: nil, result: result, error: nil, modelUsed: "ollama/\(actualModelId)", executionTime: 0)
        case .anthropic, .google, .openai, .minimax:
            throw CLIRunnerError.invalidResponse("API-based models require Python bridge. Use CLI models instead.")
        }
    }

    // MARK: - Shell Command (for simple commands)

    private func runShellCommand(_ command: String, timeout: TimeInterval) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]

        // Clean environment
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "CLAUDECODE")
        process.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()

        // Wait with timeout
        try await waitForProcess(process, timeout: timeout)

        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()

        let stdoutText = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderrText = String(data: stderrData, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            let errorMsg = stderrText.isEmpty ? stdoutText : stderrText
            throw CLIRunnerError.processFailed(errorMsg.isEmpty ? "Exit code: \(process.terminationStatus)" : errorMsg)
        }

        return stdoutText
    }

    // MARK: - Helper Methods

    private func parseModelIdentifier(_ modelId: String) -> (provider: ModelProvider, modelId: String) {
        let lowercased = modelId.lowercased()

        if lowercased.hasPrefix("claude-cli") {
            return (.claudeCLI, "default")
        }
        if lowercased.hasPrefix("codex-cli") {
            return (.codexCLI, "default")
        }
        if lowercased.hasPrefix("gemini-cli") {
            return (.geminiCLI, "default")
        }
        if lowercased.hasPrefix("minimax-cli") {
            return (.minimaxCLI, "default")
        }
        if lowercased.hasPrefix("ollama ") {
            let actualModel = String(modelId.dropFirst(7))
            return (.ollama, actualModel.isEmpty ? "llama3.3" : actualModel)
        }
        if lowercased.contains("anthropic") || lowercased.contains("claude") {
            return (.anthropic, modelId)
        }
        if lowercased.contains("gemini") || lowercased.contains("google") {
            return (.google, modelId)
        }
        if lowercased.contains("codex") || lowercased.contains("openai") {
            return (.openai, modelId)
        }
        if lowercased.contains("minimax") {
            return (.minimax, modelId)
        }

        return (.ollama, modelId)
    }

    // MARK: - ANSI Stripping

    private func stripANSI(_ text: String) -> String {
        var result = text

        // Remove all escape sequences starting with ESC [ ... (CSI sequences)
        if let regex = try? NSRegularExpression(pattern: "\u{1B}\\[(\\?\\d+|[0-9;])*[A-Za-z]", options: []) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
        }

        // Remove any remaining ESC [ without letters at the end
        if let regex = try? NSRegularExpression(pattern: "\u{1B}\\[\\d*[A-Za-z]*", options: []) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
        }

        // Remove OSC sequences: ESC ] ... BEL
        if let regex = try? NSRegularExpression(pattern: "\u{1B}\\].+?\u{7}", options: [.dotMatchesLineSeparators]) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
        }

        // Remove any standalone ESC characters
        result = result.replacingOccurrences(of: "\u{1B}", with: "")

        // Clean up any orphaned brackets that might remain
        result = result.replacingOccurrences(of: "[?25l", with: "")
        result = result.replacingOccurrences(of: "[?25h", with: "")

        // Remove remaining bracket sequences that might have been missed
        if let regex = try? NSRegularExpression(pattern: "\\[(\\?|[0-9])[0-9;]*[A-Za-z]?", options: []) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
        }

        return result
    }
}
