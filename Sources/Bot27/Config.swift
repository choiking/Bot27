import Foundation

struct AppConfig {
    enum Provider: String, CaseIterable {
        case claude, gpt
        var label: String {
            switch self {
            case .claude: return "Claude (local login)"
            case .gpt: return "GPT (ChatGPT login)"
            }
        }
        /// Computer and browser use run through the claude and codex CLIs.
        var canUseComputer: Bool { true }
    }

    static var claudeModels: [(id: String, name: String)] {
        ClaudeModels.cached.map { ($0.value, $0.displayName) }
    }
    static var defaultClaudeModel: String { ClaudeModels.cached.first?.value ?? "" }

    /// Catalog returned by the installed Codex CLI, cached for offline use.
    static var gptModels: [(id: String, name: String)] {
        CodexModels.cached.map { ($0.model, $0.displayName) }
    }
    static var defaultGPTModel: String { CodexModels.preferred(in: CodexModels.cached)?.model ?? "" }

    static func resolvedModel(_ id: String?, for provider: Provider) -> String {
        if let id, !id.isEmpty { return id }
        return provider == .claude ? defaultClaudeModel : defaultGPTModel
    }

    /// Preserve saved model IDs; only replace a provider that is no longer supported.
    static func migrate(defaults d: UserDefaults = .standard) {
        if Provider(rawValue: d.string(forKey: "provider") ?? "") == nil {
            d.set(Provider.claude.rawValue, forKey: "provider")
        }
        d.removeObject(forKey: "model")
        d.removeObject(forKey: "baseURL")
    }

    static let defaultSystemPrompt = "You are a bot inside Bot27, a Mac chat app. Be direct and concise, like a sharp friend texting back. Use Markdown when it helps."
    static let optionsHint = "When you want the user to pick what happens next, end with the question on its own line, then 2–4 short options on their own lines formatted exactly as \"A. …\", \"B. …\"."

    var provider: Provider
    var claudeModel: String
    var claudePath: String
    var gptModel: String
    var gptReasoningEffort: String? = nil
    var codexPath: String
    var systemPrompt: String

    static var current: AppConfig {
        let d = UserDefaults.standard
        return AppConfig(
            provider: Provider(rawValue: d.string(forKey: "provider") ?? "") ?? .claude,
            claudeModel: resolvedModel(d.string(forKey: "claudeModel"), for: .claude),
            claudePath: d.string(forKey: "claudePath") ?? "",
            gptModel: resolvedModel(d.string(forKey: "gptModel"), for: .gpt),
            gptReasoningEffort: d.string(forKey: "gptReasoningEffort"),
            codexPath: d.string(forKey: "codexPath") ?? "",
            systemPrompt: d.string(forKey: "systemPrompt") ?? defaultSystemPrompt
        )
    }
}

/// A provider plus one of its model IDs. Each bot keeps its own.
struct ModelChoice: Equatable {
    var provider: AppConfig.Provider
    var id: String

    var name: String {
        if id.isEmpty { return "Models unavailable" }
        return AppConfig.models(for: provider).first { $0.id == id }?.name ?? id
    }
    var tag: String { "\(provider.rawValue)|\(id)" }

    init(provider: AppConfig.Provider, id: String) {
        self.provider = provider
        self.id = AppConfig.resolvedModel(id, for: provider)
    }

    init?(tag: String) {
        let parts = tag.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, let p = AppConfig.Provider(rawValue: parts[0]) else { return nil }
        self.init(provider: p, id: parts[1])
    }

    /// What Settings says new bots should use.
    static var defaultChoice: ModelChoice {
        let c = AppConfig.current
        switch c.provider {
        case .claude: return ModelChoice(provider: .claude, id: c.claudeModel)
        case .gpt: return ModelChoice(provider: .gpt, id: c.gptModel)
        }
    }
}

extension AppConfig {
    static func models(for provider: Provider) -> [(id: String, name: String)] {
        switch provider {
        case .claude: return claudeModels
        case .gpt: return gptModels
        }
    }

    func with(_ choice: ModelChoice) -> AppConfig {
        var c = self
        c.provider = choice.provider
        switch choice.provider {
        case .claude: c.claudeModel = choice.id
        case .gpt: c.gptModel = choice.id
        }
        return c
    }
}
