import Foundation

// MARK: - Model Types

enum ModelProvider: String, Codable, CaseIterable, Identifiable {
    case anthropic = "anthropic"
    case google = "google"
    case openai = "openai"
    case minimax = "minimax"
    case ollama = "ollama"
    case claudeCLI = "claude-cli"
    case codexCLI = "codex-cli"
    case geminiCLI = "gemini-cli"
    case minimaxCLI = "minimax-cli"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .anthropic: return "Anthropic API"
        case .google: return "Google Gemini API"
        case .openai: return "OpenAI/Codex API"
        case .minimax: return "MiniMax API"
        case .ollama: return "Ollama (Local)"
        case .claudeCLI: return "Claude Code CLI"
        case .codexCLI: return "Codex CLI"
        case .geminiCLI: return "Gemini CLI"
        case .minimaxCLI: return "MiniMax CLI"
        }
    }

    var needsAPIKey: Bool {
        switch self {
        case .ollama, .claudeCLI, .codexCLI, .geminiCLI, .minimaxCLI:
            return false
        case .anthropic, .google, .openai, .minimax:
            return true
        }
    }

    var supportsLocalExecution: Bool {
        switch self {
        case .ollama:
            return true
        default:
            return false
        }
    }
}

// MARK: - Model Configuration

struct ModelConfig: Codable, Identifiable, Hashable {
    var id: String { "\(provider.rawValue)-\(modelId)" }
    var provider: ModelProvider
    var modelId: String
    var cliPath: String?
    var apiURL: String?

    static let defaults: [ModelConfig] = [
        ModelConfig(provider: .anthropic, modelId: "claude-sonnet-4-20250514", apiURL: "https://api.anthropic.com"),
        ModelConfig(provider: .anthropic, modelId: "claude-3-5-sonnet-20241022", apiURL: "https://api.anthropic.com"),
        ModelConfig(provider: .anthropic, modelId: "claude-3-5-haiku-20241022", apiURL: "https://api.anthropic.com"),
        ModelConfig(provider: .google, modelId: "gemini-2.0-flash-exp", apiURL: "https://generativelanguage.googleapis.com/v1beta"),
        ModelConfig(provider: .google, modelId: "gemini-1.5-flash-8b", apiURL: "https://generativelanguage.googleapis.com/v1beta"),
        ModelConfig(provider: .openai, modelId: "gpt-5-codex", apiURL: "https://api.openai.com/v1"),
        ModelConfig(provider: .openai, modelId: "gpt-4o", apiURL: "https://api.openai.com/v1"),
        ModelConfig(provider: .minimax, modelId: "abab6.5-chat", apiURL: "https://api.minimax.chat/v1"),
        ModelConfig(provider: .ollama, modelId: "llama3.3", cliPath: "/usr/local/bin/ollama"),
        ModelConfig(provider: .ollama, modelId: "qwen2.5-coder", cliPath: "/usr/local/bin/ollama"),
        ModelConfig(provider: .ollama, modelId: "mistral", cliPath: "/usr/local/bin/ollama"),
        ModelConfig(provider: .claudeCLI, modelId: "default", cliPath: "/usr/local/bin/claude"),
        ModelConfig(provider: .codexCLI, modelId: "default", cliPath: "/usr/local/bin/codex"),
        ModelConfig(provider: .geminiCLI, modelId: "default", cliPath: "/usr/local/bin/gemini"),
    ]
}

// MARK: - Mission Status

enum MissionStatus: String, Codable, CaseIterable {
    case pending
    case awaitingApproval
    case active
    case completed
    case failed
    case rejected

    var displayName: String {
        switch self {
        case .pending: return "Pending"
        case .awaitingApproval: return "Awaiting Approval"
        case .active: return "Active"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .rejected: return "Rejected"
        }
    }

    var iconName: String {
        switch self {
        case .pending: return "clock"
        case .awaitingApproval: return "checkmark.circle"
        case .active: return "gearshape.2"
        case .completed: return "checkmark.seal"
        case .failed: return "xmark.circle"
        case .rejected: return "minus.circle"
        }
    }
}

// MARK: - Mission Record

struct MissionRecord: Identifiable, Codable, Hashable {
    let id: UUID
    var fileName: String
    var originalInstructionPath: String
    var processingPath: String
    var completedInstructionPath: String?
    var completedArtifactPath: String?
    var status: MissionStatus
    var createdAt: Date
    var updatedAt: Date
    var managerPlan: String
    var managerModel: String
    var workerModel: String
    var resultSummary: String?
    var errorMessage: String?

    init(
        id: UUID = UUID(),
        fileName: String,
        originalInstructionPath: String,
        processingPath: String,
        completedInstructionPath: String? = nil,
        completedArtifactPath: String? = nil,
        status: MissionStatus = .pending,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        managerPlan: String = "",
        managerModel: String = "",
        workerModel: String = "",
        resultSummary: String? = nil,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.fileName = fileName
        self.originalInstructionPath = originalInstructionPath
        self.processingPath = processingPath
        self.completedInstructionPath = completedInstructionPath
        self.completedArtifactPath = completedArtifactPath
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.managerPlan = managerPlan
        self.managerModel = managerModel
        self.workerModel = workerModel
        self.resultSummary = resultSummary
        self.errorMessage = errorMessage
    }
}

// MARK: - Mission State

struct MissionState: Codable {
    var missions: [MissionRecord]
    var lastPollAt: Date?

    init(missions: [MissionRecord] = [], lastPollAt: Date? = nil) {
        self.missions = missions
        self.lastPollAt = lastPollAt
    }
}

// MARK: - AgentBox Settings

struct AgentBoxSettings: Codable, Equatable {
    var managerModelId: String
    var workerModelId: String
    var pollingIntervalSeconds: TimeInterval
    var inboxPath: String
    var processingPath: String
    var completedPath: String
    var pythonExecutable: String
    var useCLIMode: Bool

    // CLI commands (can include arguments like "cmd1 && cmd2")
    var claudeCLICommand: String
    var codexCLICommand: String
    var geminiCLICommand: String
    var minimaxCLICommand: String
    var ollamaCLICommand: String
    var ollamaModelName: String

    static let modelOptions: [String] = [
        "anthropic sonnet",
        "anthropic haiku",
        "google gemini",
        "minimax2.5",
        "codex",
        "ollama llama3.3",
        "ollama qwen2.5-coder",
        "claude-cli",
        "codex-cli",
        "gemini-cli",
        "minimax-cli"
    ]

    static func defaultValue() -> AgentBoxSettings {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("AgentBox", isDirectory: true)

        return AgentBoxSettings(
            managerModelId: "claude-cli",
            workerModelId: "ollama llama3.3",
            pollingIntervalSeconds: 900,
            inboxPath: root.appendingPathComponent("01_Inbox", isDirectory: true).path,
            processingPath: root.appendingPathComponent("02_Processing", isDirectory: true).path,
            completedPath: root.appendingPathComponent("03_Completed", isDirectory: true).path,
            pythonExecutable: "/usr/bin/python3",
            useCLIMode: true,
            claudeCLICommand: "/opt/homebrew/bin/claude -p {PROMPT}",
            codexCLICommand: "/opt/homebrew/bin/codex exec --skip-git-repo-check {PROMPT}",
            geminiCLICommand: "/opt/homebrew/bin/gemini {PROMPT}",
            minimaxCLICommand: "/opt/homebrew/bin/minimax {PROMPT}",
            ollamaCLICommand: "/usr/local/bin/ollama run llama3",
            ollamaModelName: "llama3"
        )
    }

    var pollingIntervalMinutes: Double {
        get { pollingIntervalSeconds / 60.0 }
        set { pollingIntervalSeconds = max(60, newValue * 60.0) }
    }

    var inboxURL: URL { URL(fileURLWithPath: inboxPath, isDirectory: true) }
    var processingURL: URL { URL(fileURLWithPath: processingPath, isDirectory: true) }
    var completedURL: URL { URL(fileURLWithPath: completedPath, isDirectory: true) }
}

// MARK: - API Keys

struct APIKeys: Codable, Equatable {
    var claude: String
    var gemini: String
    var minimax: String
    var codex: String
    var openai: String

    var isEmpty: Bool {
        claude.isEmpty && gemini.isEmpty && minimax.isEmpty && codex.isEmpty && openai.isEmpty
    }

    static let empty = APIKeys(claude: "", gemini: "", minimax: "", codex: "", openai: "")

    private enum CodingKeys: String, CodingKey {
        case claude
        case gemini
        case minimax
        case codex
        case openai
    }

    init(claude: String, gemini: String, minimax: String, codex: String, openai: String) {
        self.claude = claude
        self.gemini = gemini
        self.minimax = minimax
        self.codex = codex
        self.openai = openai
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        claude = try container.decodeIfPresent(String.self, forKey: .claude) ?? ""
        gemini = try container.decodeIfPresent(String.self, forKey: .gemini) ?? ""
        minimax = try container.decodeIfPresent(String.self, forKey: .minimax) ?? ""
        codex = try container.decodeIfPresent(String.self, forKey: .codex) ?? ""
        openai = try container.decodeIfPresent(String.self, forKey: .openai) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(claude, forKey: .claude)
        try container.encode(gemini, forKey: .gemini)
        try container.encode(minimax, forKey: .minimax)
        try container.encode(codex, forKey: .codex)
        try container.encode(openai, forKey: .openai)
    }
}

// MARK: - Bridge Output

struct AgentBridgeOutput: Codable {
    var plan: String?
    var result: String?
    var error: String?
    var modelUsed: String?
    var executionTime: TimeInterval?
}

// MARK: - Orchestration Plan

struct OrchestratorSubtask: Codable, Identifiable, Sendable {
    var id: String
    var title: String
    var description: String
    var agent: String
    var needsFiles: Bool
    var dependsOn: [String]
    var priority: Int

    enum CodingKeys: String, CodingKey {
        case id, title, description, agent, priority
        case needsFiles = "needs_files"
        case dependsOn = "depends_on"
    }
}

struct OrchestratorPlan: Codable, Sendable {
    var taskSummary: String
    var subtasks: [OrchestratorSubtask]
    var consolidationNotes: String

    enum CodingKeys: String, CodingKey {
        case subtasks
        case taskSummary = "task_summary"
        case consolidationNotes = "consolidation_notes"
    }
}
