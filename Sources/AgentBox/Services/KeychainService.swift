import Foundation
import Security

enum APIKeyStorageDestination {
    case keychain
    case fallbackFile(URL)
}

struct KeychainService {
    private static let service = "com.agentbox.credentials"
    private static let forceKeychainFailureEnv = "AGENTBOX_FORCE_KEYCHAIN_FAILURE"

    private let fileManager = FileManager.default
    private let fallbackURL: URL

    private enum Key: String, CaseIterable {
        case claude
        case gemini
        case minimax
        case codex
        case openai
    }

    init(rootDirectoryName: String = "AgentBox") {
        let root = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(rootDirectoryName, isDirectory: true)
        self.fallbackURL = root.appendingPathComponent("Secrets.json", isDirectory: false)
    }

    func loadKeys() -> APIKeys {
        let keychainKeys = APIKeys(
            claude: read(.claude) ?? "",
            gemini: read(.gemini) ?? "",
            minimax: read(.minimax) ?? "",
            codex: read(.codex) ?? "",
            openai: read(.openai) ?? ""
        )

        if !keychainKeys.isEmpty {
            return keychainKeys
        }

        return (try? loadFallbackKeys()) ?? .empty
    }

    @discardableResult
    func saveKeys(_ keys: APIKeys) throws -> APIKeyStorageDestination {
        do {
            try storeInKeychain(keys)
            try removeFallbackFileIfPresent()
            return .keychain
        } catch {
            try storeInFallbackFile(keys)
            return .fallbackFile(fallbackURL)
        }
    }

    private func storeInKeychain(_ keys: APIKeys) throws {
        if ProcessInfo.processInfo.environment[Self.forceKeychainFailureEnv] == "1" {
            throw NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(errSecAuthFailed),
                userInfo: [NSLocalizedDescriptionKey: "Forced keychain failure for testing"]
            )
        }

        try store(keys.claude, for: .claude)
        try store(keys.gemini, for: .gemini)
        try store(keys.minimax, for: .minimax)
        try store(keys.codex, for: .codex)
        try store(keys.openai, for: .openai)
    }

    private func storeInFallbackFile(_ keys: APIKeys) throws {
        let parent = fallbackURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parent.path) {
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(keys)
        try data.write(to: fallbackURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fallbackURL.path)
    }

    private func loadFallbackKeys() throws -> APIKeys {
        guard fileManager.fileExists(atPath: fallbackURL.path) else {
            return .empty
        }

        let data = try Data(contentsOf: fallbackURL)
        return try JSONDecoder().decode(APIKeys.self, from: data)
    }

    private func removeFallbackFileIfPresent() throws {
        guard fileManager.fileExists(atPath: fallbackURL.path) else {
            return
        }
        try fileManager.removeItem(at: fallbackURL)
    }

    private func store(_ value: String, for key: Key) throws {
        if value.isEmpty {
            delete(key)
            return
        }

        let account = key.rawValue
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }

        var insertQuery = query
        insertQuery[kSecValueData as String] = data

        let addStatus = SecItemAdd(insertQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(addStatus),
                userInfo: [NSLocalizedDescriptionKey: "Failed to store keychain value for \(account)"]
            )
        }
    }

    private func read(_ key: Key) -> String? {
        if ProcessInfo.processInfo.environment[Self.forceKeychainFailureEnv] == "1" {
            return nil
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        return value
    }

    private func delete(_ key: Key) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: key.rawValue
        ]
        SecItemDelete(query as CFDictionary)
    }
}
