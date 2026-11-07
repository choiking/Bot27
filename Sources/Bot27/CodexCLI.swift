import Foundation
import Darwin

/// Talks to GPT through the locally installed Codex CLI, using the user's ChatGPT login.
/// `codex exec --json` reports whole messages rather than token deltas.
struct CodexCLI {
    var config: AppConfig
    var connectors: [Connector] = []
    /// Called with a short description of the tool in use, or "" once text resumes.
    var onActivity: ((String) -> Void)? = nil
    /// Lets the bot see the screen and use the mouse and keyboard, via `Bot27 --computer-mcp`.
    var computerUse = false
    var onComputer: (() -> Void)? = nil
    /// Chrome control via the installed OpenAI cua_repl runtime, including its native window fallback.
    var browserUse = false
    var onBrowser: (() -> Void)? = nil

    /// MCP tool events identify the server and tool separately.
    private static let browserServer = NativeBrowser.server

    static let searchPaths = [
        "/opt/homebrew/bin/codex",
        "/usr/local/bin/codex",
        "~/.bun/bin/codex",
        "~/.local/bin/codex",
    ]

    static func locate(custom: String) -> String? {
        let candidates = (custom.isEmpty ? [] : [custom]) + searchPaths
        return candidates
            .map { NSString(string: $0).expandingTildeInPath }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private struct Event: Decodable {
        struct Item: Decodable { var type: String; var text: String?; var server: String?; var tool: String? }
        struct Failure: Decodable { var message: String }
        var type: String
        var item: Item?
        var error: Failure?
        var message: String?
    }

    /// Codex nests the API error as a JSON string; pull out the readable part.
    private static func readable(_ message: String) -> String {
        struct Wrapped: Decodable { struct Inner: Decodable { var message: String }; var error: Inner }
        return (try? JSONDecoder().decode(Wrapped.self, from: Data(message.utf8)))?.error.message ?? message
    }

    /// Foundation launches the CLI in its own process group on macOS. Stop that group
    /// as well as the CLI so a cua_repl child cannot keep controlling Chrome after Stop.
    private static func terminate(_ process: Process) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        if getpgid(pid) == pid { _ = kill(-pid, SIGTERM) }
        else { process.terminate() }
    }

    /// TOML accepts JSON string escapes except the optional escaped slash (`\/`).
    private static func toml(_ value: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(data: (try? encoder.encode(value)) ?? Data(), encoding: .utf8) ?? "\"\""
    }

    /// `-c` overrides that add Bot27's MCP servers, with their tool calls approved up front
    /// (`codex exec` has no one to ask).
    private func mcpArgs() throws -> [String] {
        var servers: [(name: String, command: String, args: [String], extra: [String])] = []
        if computerUse, let exe = Bundle.main.executablePath {
            let relay = ComputerRelay.shared
            servers.append((ComputerMCP.server, exe, ["--computer-mcp"],
                            ["env={BOT27_RELAY_SOCKET=\(Self.toml(relay.path)), BOT27_RELAY_TOKEN=\(Self.toml(relay.token))}"]))
        }
        if browserUse {
            guard let installed = NativeBrowser.locate() else {
                throw ClaudeError.failed(NativeBrowser.missingMessage)
            }
            let c = installed.configuration
            let env = (c.env ?? [:]).sorted { $0.key < $1.key }
                .map { "\(Self.toml($0.key))=\(Self.toml($0.value))" }.joined(separator: ", ")
            let forwarded = (c.env_vars ?? []).map(Self.toml).joined(separator: ", ")
            let enabled = NativeBrowser.tools.filter { c.enabled_tools?.contains($0) != false }
                .map(Self.toml).joined(separator: ", ")
            servers.append((Self.browserServer, c.command, c.args ?? [],
                            ["env={\(env)}", "env_vars=[\(forwarded)]", "enabled_tools=[\(enabled)]",
                             "startup_timeout_sec=\(Int(c.startup_timeout_sec ?? 120))", "tool_timeout_sec=120"]))
        }
        return servers.flatMap { server in
            (["command=\(Self.toml(server.command))",
              "args=[\(server.args.map(Self.toml).joined(separator: ", "))]",
              "enabled=true", "required=true", "startup_timeout_sec=30",
              "default_tools_approval_mode=\"approve\""] + server.extra)
                .flatMap { ["-c", "mcp_servers.\(server.name).\($0)"] }
        }
    }

    func stream(_ messages: [Message]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            guard let path = Self.locate(custom: config.codexPath) else {
                continuation.finish(throwing: ClaudeError.failed(
                    "Couldn't find the codex CLI. Install Codex and sign in with ChatGPT, or set its path in Settings."))
                return
            }
            let toolArgs: [String]
            do { toolArgs = try mcpArgs() }
            catch {
                continuation.finish(throwing: error)
                return
            }

            let workDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Bot27/codex", isDirectory: true)
            try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.currentDirectoryURL = workDir
            let conversation = ClaudeCLI.prompt(for: messages)
            // Load only the opted-in servers below. cua_repl is injected explicitly from the
            // installed OpenAI plugin, so no unrelated personal plugins/MCP servers are inherited.
            let disabledFeatures = ["shell_tool", "plugins", "computer_use", "browser_use",
                                    "browser_use_external", "in_app_browser"]
            process.arguments = ["exec", "--json", "--skip-git-repo-check", "--ephemeral", "--ignore-user-config", "-s", "read-only",
                                 "-m", config.gptModel, "-c", "model_reasoning_effort=low"]
                + disabledFeatures.flatMap { ["-c", "features.\($0)=false"] }
                + CodexConnectors.arguments(for: connectors)
                + toolArgs
                + conversation.images.map { "--image=" + ImageStore.url($0).path }
                + ["-"]
            process.environment = CLIEnvironment.make()

            let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = stderr

            let toolHint = computerUse || browserUse
                ? " Use the enabled Bot27 computer or browser tools when needed, following the rules above."
                : ""
            let prompt = "<instructions>\n\(config.systemPrompt)\nYou are chatting, not coding: don't run shell commands or edit files through coding tools.\(toolHint)\n</instructions>\n\n"
                + (conversation.images.isEmpty ? "" : "Images 1–\(conversation.images.count) are attached in order.\n\n")
                + conversation.text

            let task = Task {
                do {
                    // A CLI can exit before reading a long conversation. Keep a broken
                    // stdin pipe from delivering SIGPIPE to the whole app.
                    guard fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    try Task.checkCancellation()
                    try process.run()
                    if Task.isCancelled { Self.terminate(process) }
                    // Drain stderr concurrently: a full pipe can otherwise stall the CLI.
                    let diagnostics = Task.detached { () -> String in
                        var tail = Data()
                        while let chunk = try? stderr.fileHandleForReading.read(upToCount: 4096), !chunk.isEmpty {
                            tail.append(chunk)
                            if tail.count > 16_384 { tail = Data(tail.suffix(16_384)) }
                        }
                        return String(decoding: tail, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    var inputError: Error?
                    do {
                        // The older write(_:) API raises an Objective-C exception on
                        // EPIPE, which Swift's do/catch cannot handle.
                        try stdin.fileHandleForWriting.write(contentsOf: Data(prompt.utf8))
                    } catch {
                        inputError = error
                    }
                    try? stdin.fileHandleForWriting.close()

                    var replies = 0
                    var lastError: String?
                    var turnFailed = false
                    for try await line in stdout.fileHandleForReading.bytes.lines {
                        guard let event = try? JSONDecoder().decode(Event.self, from: Data(line.utf8)) else { continue }
                        if event.type == "item.started", event.item?.type == "mcp_tool_call",
                           let server = event.item?.server, let tool = event.item?.tool {
                            if server == ComputerMCP.server { onComputer?() }
                            if server == Self.browserServer { onBrowser?() }
                            // Hosted Apps report raw names such as `gmail.search_emails`.
                            let action = server == "codex_apps" ? tool.replacingOccurrences(of: ".", with: "__") : tool
                            let name = "mcp__\(server)__\(action)"
                            onActivity?(Connector.describe(name, in: connectors))
                        } else if event.type == "item.completed", event.item?.type == "agent_message",
                           let text = event.item?.text, !text.isEmpty {
                            onActivity?("")
                            continuation.yield(replies == 0 ? text : "\n\n" + text)
                            replies += 1
                        } else if event.type == "turn.failed" {
                            turnFailed = true
                            lastError = Self.readable(event.error?.message ?? "Codex request failed.")
                        } else if event.type == "error", let message = event.message {
                            lastError = Self.readable(message)
                        }
                    }
                    process.waitUntilExit()
                    let stderrText = await diagnostics.value
                    if inputError != nil || turnFailed || process.terminationStatus != 0 || replies == 0 {
                        let detail = lastError ?? (stderrText.isEmpty
                            ? (inputError?.localizedDescription ?? "GPT exited without a reply.") : stderrText)
                        let safeDetail = computerUse
                            ? detail.replacingOccurrences(of: ComputerRelay.shared.token, with: "[redacted]") : detail
                        throw ClaudeError.failed("Codex (exit \(process.terminationStatus)): \(safeDetail)")
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                Self.terminate(process)
            }
        }
    }
}
