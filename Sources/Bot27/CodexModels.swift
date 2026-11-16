import Foundation
import Darwin

struct CodexModel: Codable, Equatable, Identifiable {
    struct Effort: Codable, Equatable, Identifiable {
        var reasoningEffort: String
        var description: String
        var id: String { reasoningEffort }
        var label: String { reasoningEffort == "xhigh" ? "Extra High" : reasoningEffort.capitalized }
    }

    var id: String
    var model: String
    var displayName: String
    var hidden: Bool?
    var isDefault: Bool
    var defaultReasoningEffort: String
    var supportedReasoningEfforts: [Effort]
}

/// Metadata only. Authentication and upstream catalog caching remain owned by Codex.
enum CodexModels {
    static let cacheKey = "codexModelCatalog"

    static var cached: [CodexModel] {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let models = try? JSONDecoder().decode([CodexModel].self, from: data) else { return [] }
        return models
    }

    static func preferred(in models: [CodexModel]) -> CodexModel? {
        models.first(where: \.isDefault) ?? models.first
    }

    static func selected(_ id: String, in models: [CodexModel]) -> CodexModel? {
        id.isEmpty ? preferred(in: models) : models.first { $0.model == id }
    }

    static func arguments(model: String, effort: String?, models: [CodexModel] = cached) -> [String] {
        let metadata = selected(model, in: models)
        let modelID = model.isEmpty ? (metadata?.model ?? "") : model
        var args = modelID.isEmpty ? [] : ["-m", modelID]
        // Leave effort unset for Codex's current default. Preserve offline saved choices,
        // but never send an effort the known selected model doesn't support.
        if let effort, !effort.isEmpty {
            if metadata?.supportedReasoningEfforts.contains(where: { $0.id == effort }) != false {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.withoutEscapingSlashes]
                let value = String(decoding: try! encoder.encode(effort), as: UTF8.self)
                args += ["-c", "model_reasoning_effort=\(value)"]
            }
        }
        return args
    }

    enum DiscoveryError: LocalizedError {
        case missingCLI, unavailable, invalidCatalog
        var errorDescription: String? {
            switch self {
            case .missingCLI: return "Install Codex or set its CLI path in Settings."
            case .unavailable: return "Couldn't update GPT models. Check your Codex login and network; Bot27 will retry automatically."
            case .invalidCatalog: return "Codex returned an unreadable model list. Update Codex; Bot27 will retry automatically."
            }
        }
    }

    private struct Page: Decodable { var data: [CodexModel]; var nextCursor: String? }

    static func discover(custom: String, timeout: TimeInterval = 25) async throws -> [CodexModel] {
        guard let path = CodexCLI.locate(custom: custom) else { throw DiscoveryError.missingCLI }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.arguments = ["app-server", "-c", "features.plugins=false", "-c", "features.apps=false"]
        process.environment = CLIEnvironment.make()
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        func send(_ id: Int?, _ method: String, _ params: [String: Any] = [:]) throws {
            var request: [String: Any] = ["method": method, "params": params]
            if let id { request["id"] = id }
            var data = try JSONSerialization.data(withJSONObject: request)
            data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        // This short-lived process never runs a model turn or tools. Force termination
        // on timeout/cancellation so an unresponsive CLI cannot leave Refresh spinning.
        @Sendable func stop() {
            guard process.isRunning else { return }
            let pid = process.processIdentifier
            _ = kill(getpgid(pid) == pid ? -pid : pid, SIGKILL)
        }

        return try await withTaskCancellationHandler {
            guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
                throw DiscoveryError.unavailable
            }
            try Task.checkCancellation()
            try process.run()
            let watchdog = Task.detached {
                try? await Task.sleep(for: .seconds(timeout))
                if !Task.isCancelled { stop() }
            }
            defer {
                watchdog.cancel()
                try? input.fileHandleForWriting.close()
                stop()
            }
            try Task.checkCancellation()
            try send(1, "initialize", ["clientInfo": ["name": "bot27", "version": "1.0"]])
            var expectedID = 1
            var models: [CodexModel] = []
            var seenModels = Set<String>(), seenCursors = Set<String>()
            for try await line in output.fileHandleForReading.bytes.lines {
                try Task.checkCancellation()
                guard let response = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      response["id"] as? Int == expectedID else { continue }
                guard response["error"] == nil, let result = response["result"] else {
                    throw DiscoveryError.unavailable
                }
                if expectedID == 1 {
                    try send(nil, "initialized")
                    expectedID += 1
                    try send(expectedID, "model/list", ["limit": 100, "includeHidden": false])
                    continue
                }
                guard let data = try? JSONSerialization.data(withJSONObject: result),
                      let page = try? JSONDecoder().decode(Page.self, from: data) else {
                    throw DiscoveryError.invalidCatalog
                }
                for model in page.data where model.hidden != true {
                    guard !model.model.isEmpty, !model.displayName.isEmpty else { throw DiscoveryError.invalidCatalog }
                    if seenModels.insert(model.model).inserted { models.append(model) }
                }
                guard let cursor = page.nextCursor else { return models }
                guard seenCursors.insert(cursor).inserted, seenCursors.count < 50 else {
                    throw DiscoveryError.invalidCatalog
                }
                expectedID += 1
                try send(expectedID, "model/list", ["limit": 100, "includeHidden": false, "cursor": cursor])
            }
            try Task.checkCancellation()
            throw DiscoveryError.unavailable
        } onCancel: { stop() }
    }
}

