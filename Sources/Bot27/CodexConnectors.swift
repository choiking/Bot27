import Foundation
import Darwin

/// Uses Codex's authenticated Apps runtime; Bot27 never reads or copies OAuth tokens.
enum CodexConnectors {
    static let gmailID = "codex_gmail"
    static let gmailAppID = "connector_2128aebfecb84f64a069897515042a44"
    static let toolPrefix = "mcp__codex_apps__gmail__"
    static let setupURL = URL(string: "https://chatgpt.com/apps/gmail/\(gmailAppID)")!

    /// Explicit allowlist: newly added Gmail tools remain off until reviewed.
    static let allowedTools: Set<String> = [
        "get_profile", "list_labels", "list_drafts", "search_emails", "search_email_ids",
        "read_email", "read_email_thread", "batch_read_email", "batch_read_email_threads",
        "read_attachment", "create_draft", "update_draft",
    ]

    static func gmail(status: String, tools: [String] = []) -> Connector {
        Connector(id: gmailID, name: "Gmail", status: status,
                  tools: tools.map { toolPrefix + $0 }, codexAppID: gmailAppID)
    }

    /// Per-run configuration. Keep every other app off and deny new tools by default.
    static func arguments(for connectors: [Connector]) -> [String] {
        let gmail = connectors.first { $0.id == gmailID && $0.codexAppID == gmailAppID && $0.isConnected }
        var settings = ["features.apps=\(gmail != nil)", "apps._default.enabled=false"]
        if let gmail {
            let prefix = "apps.\(gmailAppID)"
            settings += ["\(prefix).enabled=true", "\(prefix).default_tools_enabled=false",
                         "\(prefix).default_tools_approval_mode=\"prompt\""]
            for tool in Set(gmail.allowedTools.map(Connector.shortName)).sorted() {
                // Apps policy accepts the public tool title (`search_emails`), as well as
                // the raw MCP name (`gmail.search_emails`). Use titles to avoid dotted CLI keys.
                settings += ["\(prefix).tools.\(tool).enabled=true",
                             "\(prefix).tools.\(tool).approval_mode=\"approve\""]
            }
        }
        return settings.flatMap { ["-c", $0] }
    }

    static func statusText(_ connector: Connector) -> String {
        switch connector.status {
        case "cli-missing": return "Install Codex or set its CLI path in Settings."
        case "checking": return "Checking your ChatGPT Gmail connection…"
        case "unavailable": return "Couldn't check Gmail. Check your Codex login and network, update Codex if needed, then press Refresh."
        case "disabled": return "Gmail tools are unavailable. Check your ChatGPT app permissions, then press Refresh."
        default: return "Connect Gmail in ChatGPT using the same account as Codex, then press Refresh."
        }
    }

    /// Metadata only: no model turn and no mailbox tool calls. A timeout bounds startup/network failures.
    static func discover(custom: String, timeout: TimeInterval = 30) async -> Connector {
        guard let path = CodexCLI.locate(custom: custom) else { return gmail(status: "cli-missing") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.arguments = ["app-server", "-c", "features.plugins=false"]
            + arguments(for: [gmail(status: "connected", tools: allowedTools.sorted())])
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

        return await withTaskCancellationHandler {
            do {
                guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
                    return gmail(status: "unavailable")
                }
                try Task.checkCancellation()
                try process.run()
                let watchdog = Task.detached {
                    try? await Task.sleep(for: .seconds(timeout))
                    if !Task.isCancelled, process.isRunning { process.terminate() }
                }
                defer {
                    watchdog.cancel()
                    try? input.fileHandleForWriting.close()
                    if process.isRunning { process.terminate() }
                }
                try Task.checkCancellation()
                try send(1, "initialize", ["clientInfo": ["name": "bot27", "version": "1.0"],
                                           "capabilities": ["experimentalApi": true, "explicitGatewayOauth": true]])
                var expectedID = 1
                for try await line in output.fileHandleForReading.bytes.lines {
                    try Task.checkCancellation()
                    guard let response = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                          response["id"] as? Int == expectedID else { continue }
                    guard response["error"] == nil, let result = response["result"] as? [String: Any] else {
                        return gmail(status: "unavailable")
                    }
                    switch expectedID {
                    case 1:
                        try send(nil, "initialized")
                        expectedID = 2
                        try send(2, "app/installed", ["forceRefresh": true])
                    case 2:
                        guard let apps = result["apps"] as? [[String: Any]] else { return gmail(status: "unavailable") }
                        guard let app = apps.first(where: { $0["id"] as? String == gmailAppID }) else {
                            return gmail(status: "needs-auth")
                        }
                        guard app["enabled"] as? Bool == true, app["callable"] as? Bool == true else {
                            return gmail(status: "disabled")
                        }
                        expectedID = 3
                        try send(3, "app/read", ["appIds": [gmailAppID], "includeTools": true])
                    default:
                        guard let apps = result["apps"] as? [[String: Any]],
                              let app = apps.first(where: { $0["id"] as? String == gmailAppID }),
                              let summaries = app["toolSummaries"] as? [[String: Any]] else {
                            return gmail(status: "unavailable")
                        }
                        let tools = summaries.compactMap { tool -> String? in
                            guard tool["isEnabled"] as? Bool != false,
                                  let name = tool["name"] as? String, allowedTools.contains(name) else { return nil }
                            return name
                        }
                        return gmail(status: tools.isEmpty ? "disabled" : "connected", tools: tools)
                    }
                }
            } catch { /* Never reuse cached access after a failed refresh. */ }
            return gmail(status: "unavailable")
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}
