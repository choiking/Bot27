import Foundation
import Darwin

struct ClaudeModel: Codable, Equatable, Identifiable {
    var value: String
    var displayName: String
    var description: String?
    var id: String { value }
}

enum ClaudeModels {
    static let cacheKey = "claudeModelCatalog"
    static var cached: [ClaudeModel] {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let models = try? JSONDecoder().decode([ClaudeModel].self, from: data) else { return [] }
        return models
    }

    enum DiscoveryError: LocalizedError {
        case missingCLI, unavailable, invalidCatalog
        var errorDescription: String? {
            switch self {
            case .missingCLI: return "Install Claude Code or set its CLI path in Settings."
            case .unavailable: return "Couldn't update Claude models. Check your Claude login and network; Bot27 will retry automatically."
            case .invalidCatalog: return "Claude returned an unreadable model list. Update Claude Code; Bot27 will retry automatically."
            }
        }
    }

    /// The Agent SDK initialize control response contains supportedModels(). Never
    /// send a user message: discovering models must not start an inference request.
    static func discover(custom: String, timeout: TimeInterval = 25) async throws -> [ClaudeModel] {
        guard let path = ClaudeCLI.locate(custom: custom) else { throw DiscoveryError.missingCLI }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json",
                             "--verbose", "--safe-mode", "--tools", "", "--setting-sources", "",
                             "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}", "--no-session-persistence"]
        process.environment = CLIEnvironment.make()
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
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
            let requestID = UUID().uuidString
            let request: [String: Any] = ["type": "control_request", "request_id": requestID,
                                           "request": ["subtype": "initialize", "hooks": [:]]]
            var data = try JSONSerialization.data(withJSONObject: request)
            data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
            for try await line in output.fileHandleForReading.bytes.lines {
                try Task.checkCancellation()
                guard let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      event["type"] as? String == "control_response",
                      let response = event["response"] as? [String: Any],
                      response["request_id"] as? String == requestID else { continue }
                guard response["subtype"] as? String == "success" else { throw DiscoveryError.unavailable }
                guard let result = response["response"] as? [String: Any], let models = result["models"],
                      let data = try? JSONSerialization.data(withJSONObject: models),
                      let found = try? JSONDecoder().decode([ClaudeModel].self, from: data) else {
                    throw DiscoveryError.invalidCatalog
                }
                var seen = Set<String>()
                guard !found.contains(where: { $0.value.isEmpty || $0.displayName.isEmpty }) else {
                    throw DiscoveryError.invalidCatalog
                }
                return found.filter { seen.insert($0.value).inserted }
            }
            try Task.checkCancellation()
            throw DiscoveryError.unavailable
        } onCancel: { stop() }
    }
}
