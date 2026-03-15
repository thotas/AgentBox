import Foundation

@MainActor
final class MissionControlViewModel: ObservableObject {
    @Published var settings: AgentBoxSettings = .defaultValue()
    @Published var apiKeys: APIKeys = .empty
    @Published private(set) var missionState: MissionState = .init()
    @Published private(set) var pendingFileNames: [String] = []
    @Published var selectedMissionForPlan: MissionRecord?
    @Published var errorMessage: String?
    @Published var infoMessage: String?
    @Published private(set) var isPolling = false
    @Published private(set) var nextScheduledPollAt: Date?

    private let settingsStore = SettingsStore()
    private let stateStore = StateStore()
    private lazy var keychainService: KeychainService = KeychainService()
    private let fileBridge = FolderWatcher()
    private let pythonRunner = PythonRunner()

    private var timer: Timer?
    private var missionTasks: [UUID: Task<Void, Never>] = [:]
    private var didBootstrap = false

    var awaitingApprovalMissions: [MissionRecord] {
        missionState.missions
            .filter { $0.status == .awaitingApproval }
            .sorted(by: { $0.createdAt > $1.createdAt })
    }

    var activeMissions: [MissionRecord] {
        missionState.missions
            .filter { $0.status == .active }
            .sorted(by: { $0.updatedAt > $1.updatedAt })
    }

    var completedMissions: [MissionRecord] {
        missionState.missions
            .filter { [.completed, .failed, .rejected].contains($0.status) }
            .sorted(by: { $0.updatedAt > $1.updatedAt })
    }

    var settingsPath: String {
        get async {
            await settingsStore.fileURL().path
        }
    }

    var statePath: String {
        get async {
            await stateStore.fileURL().path
        }
    }

    func bootstrapIfNeeded() async {
        guard !didBootstrap else { return }
        didBootstrap = true

        do {
            settings = try await settingsStore.loadOrCreate()
            // Only load API keys if not in CLI-only mode
            if !settings.useCLIMode {
                apiKeys = keychainService.loadKeys()
            }
            missionState = try await stateStore.loadOrCreate()

            try await fileBridge.ensureDirectories(for: settings)
            refreshTimer()
            try await refreshPendingSnapshot()
            await pollNow()
        } catch {
            errorMessage = "Bootstrap failed: \(error.localizedDescription)"
        }
    }

    func pollNow() async {
        guard !isPolling else { return }
        isPolling = true
        defer { isPolling = false }

        do {
            try await fileBridge.ensureDirectories(for: settings)
            let inboxFiles = try await fileBridge.listInboxTextFiles(in: settings)

            for file in inboxFiles {
                let processingURL = try await fileBridge.moveToProcessing(file, in: settings)
                let plan = await planText(for: processingURL)

                let mission = MissionRecord(
                    fileName: processingURL.lastPathComponent,
                    originalInstructionPath: file.path,
                    processingPath: processingURL.path,
                    status: .awaitingApproval,
                    managerPlan: plan
                )

                missionState.missions.insert(mission, at: 0)
            }

            missionState.lastPollAt = .now
            try await persistState()
            try await refreshPendingSnapshot()
            scheduleNextPollDate()
        } catch {
            errorMessage = "Polling failed: \(error.localizedDescription)"
        }
    }

    func approveMission(_ mission: MissionRecord) {
        guard mission.status == .awaitingApproval else { return }
        guard missionTasks[mission.id] == nil else { return }

        updateMission(id: mission.id) {
            $0.status = .active
            $0.updatedAt = .now
            $0.errorMessage = nil
        }

        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.executeMission(id: mission.id)
        }
        missionTasks[mission.id] = task
    }

    func rejectMission(_ mission: MissionRecord) {
        guard mission.status == .awaitingApproval else { return }

        Task {
            do {
                let processingURL = URL(fileURLWithPath: mission.processingPath)
                let completedInstruction = try await fileBridge.moveToCompleted(processingURL, in: settings)
                let note = "# Mission Rejected\n\nThe user rejected this manager plan before worker execution.\n"
                let artifactURL = try await fileBridge.writeResultArtifact(
                    for: mission.fileName,
                    result: note,
                    in: settings
                )

                updateMission(id: mission.id) {
                    $0.status = .rejected
                    $0.completedInstructionPath = completedInstruction.path
                    $0.completedArtifactPath = artifactURL.path
                    $0.updatedAt = .now
                    $0.resultSummary = "Mission was rejected before execution."
                }

                try await persistState()
            } catch {
                errorMessage = "Failed to reject mission: \(error.localizedDescription)"
            }
        }
    }

    func saveSettings() async {
        do {
            try await settingsStore.save(settings)
            try await fileBridge.ensureDirectories(for: settings)
            refreshTimer()
            try await refreshPendingSnapshot()
            infoMessage = "Settings saved to Settings.json"
        } catch {
            errorMessage = "Failed to save settings: \(error.localizedDescription)"
        }
    }

    func saveAPIKeys() {
        do {
            let destination = try keychainService.saveKeys(apiKeys)
            switch destination {
            case .keychain:
                infoMessage = "API keys saved to macOS Keychain"
            case .fallbackFile(let url):
                infoMessage = "API keys saved to fallback file at \(url.path)"
            }
        } catch {
            errorMessage = "Failed to save API keys: \(error.localizedDescription)"
        }
    }

    func clearBannerMessages() {
        errorMessage = nil
        infoMessage = nil
    }

    private func executeMission(id: UUID) async {
        defer { missionTasks[id] = nil }

        guard let mission = missionState.missions.first(where: { $0.id == id }) else {
            return
        }

        do {
            let processingURL = URL(fileURLWithPath: mission.processingPath)
            let result: String

            if settings.useCLIMode {
                result = try await executeOrchestratedCLI(mission: mission, processingURL: processingURL)
            } else {
                result = try await pythonRunner.executeMission(
                    inputFile: processingURL,
                    settings: settings,
                    keys: apiKeys
                )
            }

            let artifactURL = try await fileBridge.writeResultArtifact(
                for: mission.fileName,
                result: result,
                in: settings
            )
            let completedInstructionURL = try await fileBridge.moveToCompleted(processingURL, in: settings)

            updateMission(id: id) {
                $0.status = .completed
                $0.completedArtifactPath = artifactURL.path
                $0.completedInstructionPath = completedInstructionURL.path
                $0.updatedAt = .now
                $0.resultSummary = summarize(result)
                $0.errorMessage = nil
            }

            try await persistState()
        } catch {
            var completedInstructionPath: String?
            var completedArtifactPath: String?

            do {
                let processingURL = URL(fileURLWithPath: mission.processingPath)
                let failureBody = """
                # Mission Failed

                \(error.localizedDescription)
                """
                let artifactURL = try await fileBridge.writeResultArtifact(
                    for: mission.fileName,
                    result: failureBody,
                    in: settings
                )
                completedArtifactPath = artifactURL.path

                if FileManager.default.fileExists(atPath: processingURL.path) {
                    let completedInstructionURL = try await fileBridge.moveToCompleted(processingURL, in: settings)
                    completedInstructionPath = completedInstructionURL.path
                }
            } catch {
                completedArtifactPath = nil
            }

            updateMission(id: id) {
                $0.status = .failed
                $0.updatedAt = .now
                $0.errorMessage = error.localizedDescription
                $0.resultSummary = "Execution failed. See error details in Mission Control."
                $0.completedInstructionPath = completedInstructionPath
                $0.completedArtifactPath = completedArtifactPath
            }
            try? await persistState()
        }
    }

    /// CLI-mode execution: parses the stored JSON plan and runs the 4-phase orchestration flow.
    /// Falls back to single-worker execution if the plan is not valid JSON.
    private func executeOrchestratedCLI(mission: MissionRecord, processingURL: URL) async throws -> String {
        let cliRunner = CLIRunner()

        // Try to parse the plan stored during Phase 1 as an OrchestratorPlan
        if let planData = mission.managerPlan.data(using: .utf8),
           let plan = try? JSONDecoder().decode(OrchestratorPlan.self, from: planData),
           !plan.subtasks.isEmpty {
            return try await runMultiAgentOrchestration(cliRunner: cliRunner, mission: mission, plan: plan, processingURL: processingURL)
        }

        // Fallback: single-worker execution via the existing CLIRunner path
        let instruction = try String(contentsOf: processingURL, encoding: .utf8)
        return try await cliRunner.executeMission(
            inputFile: processingURL,
            managerModel: settings.managerModelId,
            workerModel: settings.workerModelId,
            instruction: instruction,
            settings: settings
        )
    }

    /// Runs Phase 2 (parallel wave 1 + parallel wave 2) and Phase 3 (consolidation).
    /// Uses error isolation - individual subtask failures don't abort the orchestration (mirrors orchestrate.sh).
    private func runMultiAgentOrchestration(cliRunner: CLIRunner, mission: MissionRecord, plan: OrchestratorPlan, processingURL: URL) async throws -> String {
        let instruction = (try? String(contentsOf: processingURL, encoding: .utf8)) ?? mission.fileName
        let capturedSettings = settings

        var taskResults: [String: String] = [:]
        var failedTasks: [String: String] = [:] // Track failed tasks for reporting

        // Phase 2, Wave 1: independent tasks run in parallel (with error isolation)
        let wave1 = plan.subtasks.filter { $0.dependsOn.isEmpty }
        if !wave1.isEmpty {
            await withTaskGroup(of: (String, String?, Error?).self) { group in
                for subtask in wave1 {
                    group.addTask {
                        let (result, error) = await cliRunner.executeSubtask(subtask, previousResults: [:], settings: capturedSettings)
                        if let error = error {
                            return (subtask.id, nil, error)
                        }
                        return (subtask.id, result, nil)
                    }
                }

                for await (taskId, result, error) in group {
                    if let result = result {
                        taskResults[taskId] = result
                    } else if let error = error {
                        failedTasks[taskId] = error.localizedDescription
                        print("[MissionControl] Wave 1 task \(taskId) failed: \(error.localizedDescription)")
                    }
                }
            }
        }

        // Phase 2, Wave 2: dependent tasks run in parallel, each injecting available wave 1 context
        let wave2 = plan.subtasks.filter { !$0.dependsOn.isEmpty }
        if !wave2.isEmpty {
            let capturedTaskResults = taskResults
            await withTaskGroup(of: (String, String?, Error?).self) { group in
                for subtask in wave2 {
                    let depResults = subtask.dependsOn.reduce(into: [String: String]()) { dict, depId in
                        dict[depId] = capturedTaskResults[depId]
                    }
                    group.addTask {
                        let (result, error) = await cliRunner.executeSubtask(subtask, previousResults: depResults, settings: capturedSettings)
                        if let error = error {
                            return (subtask.id, nil, error)
                        }
                        return (subtask.id, result, nil)
                    }
                }

                for await (taskId, result, error) in group {
                    if let result = result {
                        taskResults[taskId] = result
                    } else if let error = error {
                        failedTasks[taskId] = error.localizedDescription
                        print("[MissionControl] Wave 2 task \(taskId) failed: \(error.localizedDescription)")
                    }
                }
            }
        }

        // Log failed tasks if any
        if !failedTasks.isEmpty {
            let failedList = failedTasks.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
            print("[MissionControl] Completed with \(failedTasks.count) failed task(s): \(failedList)")
        }

        // Phase 3: Consolidate all results into a final report
        // Even if some tasks failed, we still try to consolidate
        return try await cliRunner.consolidateResults(
            originalTask: instruction,
            plan: plan,
            taskResults: taskResults,
            settings: capturedSettings
        )
    }

    private func persistState() async throws {
        try await stateStore.save(missionState)
    }

    private func refreshPendingSnapshot() async throws {
        let pending = try await fileBridge.listInboxTextFiles(in: settings)
        pendingFileNames = pending.map { $0.lastPathComponent }
    }

    private func planText(for processingFile: URL) async -> String {
        do {
            if settings.useCLIMode {
                // Phase 1: generate a JSON orchestration plan (mirrors orchestrate.sh plan_task)
                let instruction = try String(contentsOf: processingFile, encoding: .utf8)
                let cliRunner = CLIRunner()
                let plan = try await cliRunner.generateOrchestrationPlan(instruction: instruction, settings: settings)
                let data = try JSONEncoder().encode(plan)
                return String(data: data, encoding: .utf8) ?? plan.taskSummary
            }
            return try await pythonRunner.generatePlan(
                inputFile: processingFile,
                settings: settings,
                keys: apiKeys
            )
        } catch {
            return "Fallback plan generated locally because CLI execution failed.\n\n1. Read instruction file\n2. Produce manager task decomposition\n3. Dispatch work to the selected worker model\n4. Synthesize final output\n\nError detail: \(error.localizedDescription)"
        }
    }

    private func summarize(_ result: String) -> String {
        let lines = result
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        if let first = lines.first {
            return String(first.prefix(180))
        }

        return "Execution completed with an empty result body."
    }

    private func updateMission(id: UUID, mutate: (inout MissionRecord) -> Void) {
        guard let index = missionState.missions.firstIndex(where: { $0.id == id }) else {
            return
        }

        mutate(&missionState.missions[index])
    }

    private func refreshTimer() {
        timer?.invalidate()
        let interval = max(60, settings.pollingIntervalSeconds)

        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { [weak self] in
                await self?.pollNow()
            }
        }

        scheduleNextPollDate()
    }

    private func scheduleNextPollDate() {
        nextScheduledPollAt = Date().addingTimeInterval(max(60, settings.pollingIntervalSeconds))
    }
}
