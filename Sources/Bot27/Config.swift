import Foundation
import Security

struct AppConfig {
    enum Provider: String, CaseIterable {
        case claude, gpt, xai
        var label: String {
            switch self {
            case .claude: return "Claude (local login)"
            case .gpt: return "GPT (ChatGPT login)"
            case .xai: return "xAI API"
            }
        }
    }

    static let claudeModels: [(id: String, name: String)] = [
        ("claude-opus-5-5", "Claude Opus 5.5"),
        ("claude-sonnet-5-5", "Claude Sonnet 5.5"),
        ("claude-haiku-5-5", "Claude Haiku 5.5"),
        ("claude-fable-5-1", "Claude Fable 5.1 (needs usage credits)"),
    ]
    static let defaultClaudeModel = "claude-opus-5-5"

    /// Models the Codex CLI accepts with a ChatGPT login.
    static let gptModels: [(id: String, name: String)] = [
        ("gpt-6-astra", "GPT-6-Astra"),
        ("gpt-5.6-sol", "GPT-5.6-Sol"),
        ("gpt-5.6-terra", "GPT-5.6-Terra"),
        ("gpt-5.6-luna", "GPT-5.6-Luna"),
    ]
    static let defaultGPTModel = "gpt-6-astra"

    /// Earlier builds stored CLI aliases ("opus") or nothing; switch those to full model IDs.
    static func migrate() {
        let d = UserDefaults.standard
        let aliases = ["fable": "claude-fable-5-1", "opus": "claude-opus-5-5",
                       "sonnet": "claude-sonnet-5-5", "haiku": "claude-haiku-5-5"]
        let stored = d.string(forKey: "claudeModel") ?? ""
        if let full = aliases[stored] {
            d.set(full, forKey: "claudeModel")
        } else if !claudeModels.contains(where: { $0.id == stored }) {
            d.set(defaultClaudeModel, forKey: "claudeModel")
        }
    }

    static let defaultModel = "grok-4"
    static let defaultBaseURL = "https://api.x.ai/v1"
    static let defaultSystemPrompt = "You are a bot inside Bot27, a Mac chat app. Be direct and concise, like a sharp friend texting back. Use Markdown when it helps."
    static let optionsHint = "When you want the user to pick what happens next, end with the question on its own line, then 2–4 short options on their own lines formatted exactly as \"A. …\", \"B. …\"."

    static let models: [(id: String, name: String)] = [
        ("grok-4", "Grok 4"),
        ("grok-4-fast", "Grok 4 Fast"),
        ("grok-3-mini", "Grok 3 Mini"),
    ]

    static func displayName(_ id: String) -> String {
        models.first { $0.id == id }?.name ?? id
    }

    var provider: Provider
    var claudeModel: String
    var claudePath: String
    var gptModel: String
    var codexPath: String
    var apiKey: String?
    var baseURL: URL
    var model: String
    var systemPrompt: String

    static var current: AppConfig {
        let d = UserDefaults.standard
        let env = ProcessInfo.processInfo.environment["XAI_API_KEY"]
        let key = Keychain.read() ?? env
        return AppConfig(
            provider: Provider(rawValue: d.string(forKey: "provider") ?? "") ?? .claude,
            claudeModel: d.string(forKey: "claudeModel") ?? defaultClaudeModel,
            claudePath: d.string(forKey: "claudePath") ?? "",
            gptModel: d.string(forKey: "gptModel") ?? defaultGPTModel,
            codexPath: d.string(forKey: "codexPath") ?? "",
            apiKey: (key?.isEmpty ?? true) ? nil : key,
            baseURL: URL(string: d.string(forKey: "baseURL") ?? defaultBaseURL) ?? URL(string: defaultBaseURL)!,
            model: d.string(forKey: "model") ?? defaultModel,
            systemPrompt: d.string(forKey: "systemPrompt") ?? defaultSystemPrompt
        )
    }
}

/// A provider plus one of its model IDs. Each bot keeps its own.
struct ModelChoice: Equatable {
    var provider: AppConfig.Provider
    var id: String

    var name: String { AppConfig.models(for: provider).first { $0.id == id }?.name ?? id }
    var tag: String { "\(provider.rawValue)|\(id)" }

    init(provider: AppConfig.Provider, id: String) {
        self.provider = provider
        self.id = id
    }

    init?(tag: String) {
        let parts = tag.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, let p = AppConfig.Provider(rawValue: parts[0]) else { return nil }
        self.init(provider: p, id: parts[1])
    }

    /// What Settings says new bots should use.
    static var defaultChoice: ModelChoice {
        let c = AppConfig.current
        switch c.provider {
        case .claude: return ModelChoice(provider: .claude, id: c.claudeModel)
        case .gpt: return ModelChoice(provider: .gpt, id: c.gptModel)
        case .xai: return ModelChoice(provider: .xai, id: c.model)
        }
    }
}

extension AppConfig {
    static func models(for provider: Provider) -> [(id: String, name: String)] {
        switch provider {
        case .claude: return claudeModels
        case .gpt: return gptModels
        case .xai: return models
        }
    }

    func with(_ choice: ModelChoice) -> AppConfig {
        var c = self
        c.provider = choice.provider
        switch choice.provider {
        case .claude: c.claudeModel = choice.id
        case .gpt: c.gptModel = choice.id
        case .xai: c.model = choice.id
        }
        return c
    }
}

enum Keychain {
    private static let service = "com.bot27.app"
    private static let account = "xai-api-key"

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func read() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ value: String) {
        SecItemDelete(baseQuery as CFDictionary)
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var query = baseQuery
        query[kSecValueData as String] = Data(trimmed.utf8)
        SecItemAdd(query as CFDictionary, nil)
    }
}
