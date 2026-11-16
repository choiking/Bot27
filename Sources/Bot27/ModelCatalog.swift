import Foundation
import Combine

/// Refresh each provider independently. Failed checks preserve its last good catalog.
@MainActor final class ModelCatalog: ObservableObject {
    static let shared = ModelCatalog()
    @Published private(set) var gptModels = CodexModels.cached
    @Published private(set) var claudeModels = ClaudeModels.cached
    @Published private(set) var refreshing: Set<AppConfig.Provider> = []
    @Published private(set) var errors: [AppConfig.Provider: String] = [:]
    private var tasks: [AppConfig.Provider: Task<Void, Never>] = [:]
    private var lastAttempts: [AppConfig.Provider: Date] = [:]
    private var paths: [AppConfig.Provider: String] = [:]
    private var timer: Timer?

    init(automaticallyRefresh: Bool = true) {
        if automaticallyRefresh {
            timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refreshIfNeeded() }
            }
        }
    }

    func models(for provider: AppConfig.Provider) -> [(id: String, name: String)] {
        switch provider {
        case .claude: return claudeModels.map { ($0.value, $0.displayName) }
        case .gpt: return gptModels.map { ($0.model, $0.displayName) }
        }
    }

    /// Check on launch, opening model settings, returning to the app, and hourly.
    /// Failures retry after a minute; a changed CLI path invalidates the cooldown.
    func refreshIfNeeded(force: Bool = false) {
        for provider in AppConfig.Provider.allCases {
            let path = UserDefaults.standard.string(forKey: provider == .gpt ? "codexPath" : "claudePath") ?? ""
            let pathChanged = paths[provider] != path
            guard pathChanged || !refreshing.contains(provider) else { continue }
            let elapsed = Date().timeIntervalSince(lastAttempts[provider] ?? .distantPast)
            guard force || pathChanged || elapsed >= (errors[provider] == nil ? 3600 : 60) else { continue }
            tasks[provider]?.cancel()
            paths[provider] = path
            lastAttempts[provider] = Date()
            refreshing.insert(provider)
            errors[provider] = nil
            tasks[provider] = Task {
                do {
                    switch provider {
                    case .gpt:
                        let models = try await CodexModels.discover(custom: path)
                        try Task.checkCancellation()
                        let data = try JSONEncoder().encode(models)
                        UserDefaults.standard.set(data, forKey: CodexModels.cacheKey)
                        gptModels = models
                    case .claude:
                        let models = try await ClaudeModels.discover(custom: path)
                        try Task.checkCancellation()
                        let data = try JSONEncoder().encode(models)
                        UserDefaults.standard.set(data, forKey: ClaudeModels.cacheKey)
                        claudeModels = models
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    errors[provider] = error.localizedDescription
                }
                refreshing.remove(provider)
                tasks[provider] = nil
            }
        }
    }
}
