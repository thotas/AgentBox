import Foundation

// MARK: - CLI Runner Error

enum CLIRunnerError: Error, LocalizedError {
    case cliNotFound(String)
    case launchFailed(String)
    case processFailed(String)
    case invalidResponse(String)
    case timeout
    case modelNotAvailable(String)

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
        }
    }
}

// MARK: - CLI Runner

actor CLIRunner {
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private let timeout: TimeInterval = 120

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

    // MARK: - Orchestration API

    /// Phase 1: Call the manager CLI to generate a JSON execution plan (mirrors orchestrate.sh plan_task).
    func generateOrchestrationPlan(instruction: String, settings: AgentBoxSettings) async throws -> OrchestratorPlan {
        let ollamaModel = settings.ollamaModelName.isEmpty ? "llama3" : settings.ollamaModelName
        let prompt = """
        IMPORTANT: Respond ONLY with valid JSON, no markdown fences, no explanation.

        You are an expert AI orchestrator. Break down the following task into parallel sub-tasks and assign each to the most appropriate agent.

        Available agents:
        - claude: Best for complex reasoning, architecture, code review, file editing, implementation
        - codex: Best for code generation, refactoring, implementation
        - gemini: Best for research, documentation, broad knowledge tasks
        - ollama (local/\(ollamaModel)): Best for simple text tasks, summarization, formatting
        - minimax: Best for creative tasks, multilingual content, alternative perspective

        Task: \(instruction)

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

        let output = try await runCustomCLI(command: settings.claudeCLICommand, prompt: prompt, modelId: "claude-cli", mode: "plan", settings: settings)
        let raw = output.plan ?? output.result ?? ""

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

    /// Phase 2: Execute a single subtask with the assigned agent (mirrors orchestrate.sh run_*_agent).
    /// Injects context from dependency results if provided.
    func executeSubtask(_ subtask: OrchestratorSubtask, previousResults: [String: String], settings: AgentBoxSettings) async throws -> String {
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

        return try await dispatchToAgent(subtask.agent, description: description, settings: settings)
    }

    /// Phase 3: Consolidate all subtask results into a final report (mirrors orchestrate.sh consolidate).
    func consolidateResults(originalTask: String, plan: OrchestratorPlan, taskResults: [String: String], settings: AgentBoxSettings) async throws -> String {
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

        let output = try await runCustomCLI(command: settings.claudeCLICommand, prompt: prompt, modelId: "claude-cli", mode: "execute", settings: settings)
        return output.result ?? output.plan ?? ""
    }

    /// Dispatch a prompt to the named agent type, falling back to claude on unknown agents.
    private func dispatchToAgent(_ agent: String, description: String, settings: AgentBoxSettings) async throws -> String {
        switch agent.lowercased() {
        case "codex":
            let out = try await runCustomCLI(command: settings.codexCLICommand, prompt: description, modelId: "codex-cli", mode: "execute", settings: settings)
            return out.result ?? ""
        case "gemini":
            let out = try await runCustomCLI(command: settings.geminiCLICommand, prompt: description, modelId: "gemini-cli", mode: "execute", settings: settings)
            return out.result ?? ""
        case "ollama":
            let out = try await runOllama(modelId: settings.ollamaModelName, mode: "execute", instruction: description, settings: settings)
            return out.result ?? ""
        case "minimax":
            let out = try await runCustomCLI(command: settings.minimaxCLICommand, prompt: description, modelId: "minimax-cli", mode: "execute", settings: settings)
            return out.result ?? ""
        default: // "claude" and any unknown agent — fall back to claude
            let out = try await runCustomCLI(command: settings.claudeCLICommand, prompt: description, modelId: "claude-cli", mode: "execute", settings: settings)
            return out.result ?? ""
        }
    }

    // MARK: - Private Execution

    private func executeWithModel(modelId: String, workerModelId: String? = nil, mode: String, instruction: String, settings: AgentBoxSettings) async throws -> AgentBridgeOutput {
        // Parse model identifier
        let (provider, actualModelId) = parseModelIdentifier(modelId)

        switch provider {
        case .claudeCLI:
            return try await runCustomCLI(command: settings.claudeCLICommand, prompt: instruction, modelId: modelId, mode: mode, settings: settings)
        case .codexCLI:
            return try await runCustomCLI(command: settings.codexCLICommand, prompt: instruction, modelId: modelId, mode: mode, settings: settings)
        case .geminiCLI:
            return try await runCustomCLI(command: settings.geminiCLICommand, prompt: instruction, modelId: modelId, mode: mode, settings: settings)
        case .minimaxCLI:
            return try await runCustomCLI(command: settings.minimaxCLICommand, prompt: instruction, modelId: modelId, mode: mode, settings: settings)
        case .ollama:
            return try await runOllama(modelId: actualModelId, mode: mode, instruction: instruction, settings: settings)
        case .anthropic, .google, .openai, .minimax:
            // These use the Python bridge for API calls
            throw CLIRunnerError.invalidResponse("API-based models require Python bridge. Use CLI models instead.")
        }
    }

    // MARK: - CLI Implementations

    private func runCustomCLI(command: String, prompt: String, modelId: String, mode: String, settings: AgentBoxSettings) async throws -> AgentBridgeOutput {
        let startTime = Date()

        // Replace {PROMPT} placeholder with the actual prompt
        // Quote the prompt to handle spaces and special characters
        let quotedPrompt = prompt.replacingOccurrences(of: "\"", with: "\\\"")
        let processedCommand = command.replacingOccurrences(of: "{PROMPT}", with: "\"\(quotedPrompt)\"")

        // Always use shell to execute - it's more reliable for complex CLI commands
        let output = try await runShellCommand(processedCommand, timeout: 180)
        let executionTime = Date().timeIntervalSince(startTime)

        let cleanOutput = stripANSI(output).trimmingCharacters(in: .whitespacesAndNewlines)

        // Return plan or result depending on mode
        if mode == "plan" {
            return AgentBridgeOutput(
                plan: cleanOutput,
                result: nil,
                error: cleanOutput.isEmpty ? "Empty response from CLI" : nil,
                modelUsed: modelId,
                executionTime: executionTime
            )
        } else {
            return AgentBridgeOutput(
                plan: nil,
                result: cleanOutput,
                error: cleanOutput.isEmpty ? "Empty response from CLI" : nil,
                modelUsed: modelId,
                executionTime: executionTime
            )
        }
    }

    private func runProcessWithStdin(executable: String, arguments: [String], input: String, timeout: TimeInterval) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        // Clean environment to avoid conflicts (e.g., CLAUDECODE)
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

        // Write input to stdin
        stdinPipe.fileHandleForWriting.write(input.data(using: .utf8)!)
        stdinPipe.fileHandleForWriting.closeFile()

        // Wait with timeout
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

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        let stdoutText = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderrText = String(data: stderrData, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            if !stderrText.isEmpty {
                throw CLIRunnerError.processFailed(stderrText)
            }
            throw CLIRunnerError.processFailed("Exit code: \(process.terminationStatus)")
        }

        return stdoutText
    }

    private func runOllama(modelId: String, mode: String, instruction: String, settings: AgentBoxSettings) async throws -> AgentBridgeOutput {
        let ollamaCommand = settings.ollamaCLICommand
        let actualModel = settings.ollamaModelName.isEmpty ? "llama3" : settings.ollamaModelName

        // First check if model is available
        let listOutput = try await runShellCommand("\(ollamaCommand) list", timeout: 30)
        if !listOutput.contains(actualModel) && !listOutput.contains("\(actualModel):") {
            // Try to pull the model
            _ = try await runShellCommand("\(ollamaCommand) pull \(actualModel)", timeout: 300)
        }

        let prompt: String
        if mode == "plan" {
            prompt = """
            You are the AgentBox manager model. Create an execution plan.

            Return markdown with:
            1) Mission Understanding
            2) Work Breakdown
            3) Validation Plan
            4) Risks and Mitigations
            5) Output Contract

            Instruction: \(instruction)
            """
        } else {
            prompt = instruction
        }

        let startTime = Date()
        // Use printf instead of echo for better portability and handling of special characters
        // Use sed to strip ANSI codes reliably in the shell
        let sedCommand = #"sed -E 's/\x1B//g; s/\[(\?|[0-9])[0-9;]*[A-Za-z]?//g; s/\[K//g'"#
        // Use printf %s for safe handling of prompt content
        let fullCommand = "printf '%s' \"\(prompt.replacingOccurrences(of: "\"", with: "\\\""))\" | \(ollamaCommand) run \(actualModel) 2>&1 | \(sedCommand)"
        let output = try await runShellCommand(fullCommand, timeout: 180)
        let executionTime = Date().timeIntervalSince(startTime)

        // Debug: Log output length if empty
        if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            print("[CLIRunner] Warning: Empty output from ollama for mode: \(mode)")
        }

        if mode == "plan" {
            let cleanedOutput = stripANSI(output).trimmingCharacters(in: .whitespacesAndNewlines)
            return AgentBridgeOutput(
                plan: cleanedOutput.isEmpty ? nil : cleanedOutput,
                result: nil,
                error: cleanedOutput.isEmpty ? "Empty response from model" : nil,
                modelUsed: "ollama/\(actualModel)",
                executionTime: executionTime
            )
        } else {
            let cleanedOutput = stripANSI(output).trimmingCharacters(in: .whitespacesAndNewlines)
            return AgentBridgeOutput(
                plan: nil,
                result: cleanedOutput.isEmpty ? nil : cleanedOutput,
                error: cleanedOutput.isEmpty ? "Empty response from model" : nil,
                modelUsed: "ollama/\(actualModel)",
                executionTime: executionTime
            )
        }
    }

    // MARK: - Helper Methods

    private func runShellCommand(_ command: String, timeout: TimeInterval) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]

        // Clean environment to avoid conflicts (e.g., CLAUDECODE)
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "CLAUDECODE")
        process.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()

        // Wait with timeout
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

    private func runProcess(executable: String, arguments: [String], timeout: TimeInterval) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        // Clean environment to avoid conflicts (e.g., CLAUDECODE)
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "CLAUDECODE")
        process.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()

        // Wait with timeout
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

        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()

        let stdoutText = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderrText = String(data: stderrData, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            if !stderrText.isEmpty {
                throw CLIRunnerError.processFailed(stderrText)
            }
            throw CLIRunnerError.processFailed("Exit code: \(process.terminationStatus)")
        }

        return stdoutText
    }

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

        // Default to ollama if no match
        return (.ollama, modelId)
    }

    private func findExecutable(_ name: String) -> String? {
        let possiblePaths = [
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
            "/opt/homebrew/bin/\(name)",
            "/Users/\(NSUserName())/.local/bin/\(name)"
        ]

        for path in possiblePaths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        // Try which
        let whichProcess = Process()
        whichProcess.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        whichProcess.arguments = [name]

        let pipe = Pipe()
        whichProcess.standardOutput = pipe

        do {
            try whichProcess.run()
            whichProcess.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty {
                return path
            }
        } catch {
            // Ignore
        }

        return nil
    }

    // MARK: - ANSI Stripping

    private func stripANSI(_ text: String) -> String {
        var result = text

        // Remove all escape sequences starting with ESC [ ... (CSI sequences)
        // This is more aggressive to catch all variants like [?25h, [?2026h, [1S, etc.
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

    // Handle output from cat -v which converts escape sequences to readable form
    // e.g., ESC[ becomes ^[, M- becomes ^M, etc.
    private func stripCatV(_ text: String) -> String {
        var result = text

        // cat -v converts ESC to ^[, so we need to handle both
        // Remove ^[[ patterns (cat -v representation of ESC[)
        if let regex = try? NSRegularExpression(pattern: "\\^\\[[0-9;]*[A-Za-z]*", options: []) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
        }

        // Remove ^[ patterns (ESC character)
        result = result.replacingOccurrences(of: "^[[", with: "")
        result = result.replacingOccurrences(of: "^[", with: "")

        // Remove cursor movement codes that appear in cat -v output
        result = result.replacingOccurrences(of: "[?25l", with: "")
        result = result.replacingOccurrences(of: "[?25h", with: "")

        // Remove any remaining control character representations from cat -v
        // cat -v uses ^X for control characters and M-c for meta characters
        if let regex = try? NSRegularExpression(pattern: "\\^[A-Z\\[\\]\\\\@]", options: []) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
        }

        return result
    }
}
