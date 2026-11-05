import Foundation
import Darwin

/// Talks to GPT through the locally installed Codex CLI, using the user's ChatGPT login.
/// `codex exec --json` reports whole messages rather than token deltas.
struct CodexCLI {
    var config: AppConfig
    /// Called with a short description of the tool in use, or "" once text resumes.
    var onActivity: ((String) -> Void)? = nil
    /// Lets the bot see the screen and use the mouse and keyboard, via `Bot27 --computer-mcp`.
    var computerUse = false
    var onComputer: (() -> Void)? = nil
    /// Lets the bot drive the user's Chrome, via the claude CLI's Claude in Chrome server.
    var browserUse = false
    var onBrowser: (() -> Void)? = nil

    /// Codex's name for the Claude in Chrome server; tools are reported as server + tool.
    private static let browserServer = "claude_in_chrome"

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

    /// TOML accepts JSON string escapes except the optional escaped slash (`\/`).
    private static func toml(_ value: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(data: (try? encoder.encode(value)) ?? Data(), encoding: .utf8) ?? "\"\""
    }

    /// `-c` overrides that add Bot27's MCP servers, with their tool calls approved up front
    /// (`codex exec` has no one to ask).
    private func mcpArgs() -> [String] {
        var servers: [(name: String, command: String, args: [String], extra: [String])] = []
        if computerUse, let exe = Bundle.main.executablePath {
            let relay = ComputerRelay.shared
            servers.append((ComputerMCP.server, exe, ["--computer-mcp"],
                            ["env={BOT27_RELAY_SOCKET=\(Self.toml(relay.path)), BOT27_RELAY_TOKEN=\(Self.toml(relay.token))}"]))
        }
        if browserUse, let claude = ClaudeCLI.locate(custom: config.claudePath) {
            let tools = BrowserUse.allowedTools.map { Self.toml(String($0.dropFirst(BrowserUse.prefix.count))) }
            servers.append((Self.browserServer, claude, ["--claude-in-chrome-mcp"],
                            ["enabled_tools=[\(tools.joined(separator: ", "))]", "tool_timeout_sec=120"]))
        }
        return servers.flatMap { server in
            (["command=\(Self.toml(server.command))",
              "args=[\(server.args.map(Self.toml).joined(separator: ", "))]",
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

            let workDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Bot27/codex", isDirectory: true)
            try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.currentDirectoryURL = workDir
            let conversation = ClaudeCLI.prompt(for: messages)
            process.arguments = ["exec", "--json", "--skip-git-repo-check", "--ephemeral", "-s", "read-only",
                                 "-m", config.gptModel, "-c", "model_reasoning_effort=low"]
                + mcpArgs()
                + conversation.images.map { "--image=" + ImageStore.url($0).path }
                + ["-"]
            process.environment = CLIEnvironment.make()

            let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = stderr

            let prompt = "<instructions>\n\(config.systemPrompt)\nYou are chatting, not coding: don't run commands or touch files.\n</instructions>\n\n"
                + (conversation.images.isEmpty ? "" : "Images 1–\(conversation.images.count) are attached in order.\n\n")
                + conversation.text

            let task = Task {
                do {
                    // A CLI can exit before reading a long conversation. Keep a broken
                    // stdin pipe from delivering SIGPIPE to the whole app.
                    guard fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    try process.run()
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
                            let name = server == Self.browserServer ? BrowserUse.prefix + tool : "mcp__\(server)__\(tool)"
                            onActivity?(Connector.describe(name, in: []))
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
                if process.isRunning { process.terminate() }
            }
        }
    }
}
