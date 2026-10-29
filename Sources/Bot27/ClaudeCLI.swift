import Foundation

enum ClaudeError: LocalizedError {
    case notFound
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "Couldn't find the claude CLI. Install Claude Code and sign in, or set its path in Settings."
        case let .failed(detail):
            return detail.isEmpty ? "Claude exited without a reply." : String(detail.prefix(400))
        }
    }
}

/// Talks to Claude through the locally installed Claude Code CLI, so replies use
/// the user's existing Claude login instead of an API key.
struct ClaudeCLI {
    var config: AppConfig
    /// Connectors this bot may use; every other known connector is blocked outright.
    var connectors: [Connector] = []
    var allConnectors: [Connector] = []
    /// Called with a short description of the tool in use, or "" once text resumes.
    var onActivity: ((String) -> Void)? = nil
    /// Lets the bot see the screen and use the mouse and keyboard, via `Bot27 --computer-mcp`.
    var computerUse = false
    /// Called when the bot starts controlling the computer.
    var onComputer: (() -> Void)? = nil
    /// Lets the bot drive the user's Chrome through the Claude in Chrome extension.
    var browserUse = false
    /// Called when the bot starts using the browser.
    var onBrowser: (() -> Void)? = nil

    static let searchPaths = [
        "~/.bun/bin/claude",
        "~/.local/bin/claude",
        "~/.claude/local/claude",
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
    ]

    static func locate(custom: String) -> String? {
        let candidates = (custom.isEmpty ? [] : [custom]) + searchPaths
        return candidates
            .map { NSString(string: $0).expandingTildeInPath }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static let maxImages = 8

    /// The CLIs are stateless per call, so the whole conversation goes in the prompt.
    /// Images are numbered in the text and returned in the same order; only the most recent
    /// `maxImages` are attached.
    static func prompt(for messages: [Message]) -> (text: String, images: [String]) {
        let attached = Array(messages.flatMap { $0.images ?? [] }.suffix(maxImages))
        func body(_ m: Message) -> String {
            let markers = (m.images ?? []).map { name in
                attached.firstIndex(of: name).map { "[Image \($0 + 1)]" } ?? "[earlier image, no longer attached]"
            }
            return (markers + [m.content]).filter { !$0.isEmpty }.joined(separator: "\n")
        }
        guard messages.count > 1 else { return (messages.last.map(body) ?? "", attached) }
        let transcript = messages.map { m in
            m.role == .user ? "<user>\n\(body(m))\n</user>" : "<assistant>\n\(m.content)\n</assistant>"
        }
        let text = "Here is our conversation so far:\n\n" + transcript.joined(separator: "\n\n")
            + "\n\nReply to the latest <user> message. Output only your reply, without tags."
        return (text, attached)
    }

    /// One stream-json user message: each image labelled with its number, then the prompt.
    static func inputLine(for messages: [Message]) -> Data {
        let prompt = prompt(for: messages)
        var content: [[String: Any]] = []
        for (i, name) in prompt.images.enumerated() {
            guard let data = ImageStore.base64(name) else { continue }
            content.append(["type": "text", "text": "Image \(i + 1):"])
            content.append(["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": data]])
        }
        content.append(["type": "text", "text": prompt.text.isEmpty ? "(see image)" : prompt.text])
        let line: [String: Any] = ["type": "user", "message": ["role": "user", "content": content]]
        return ((try? JSONSerialization.data(withJSONObject: line)) ?? Data()) + Data("\n".utf8)
    }

    private struct Event: Decodable {
        struct Inner: Decodable {
            struct Delta: Decodable { var type: String?; var text: String? }
            struct Block: Decodable { var type: String; var name: String? }
            var type: String
            var delta: Delta?
            var content_block: Block?
        }
        var type: String
        var event: Inner?
        var is_error: Bool?
        var result: String?
    }

    /// Holds the CLI process of the current attempt so the stream can stop it.
    private final class Running: @unchecked Sendable {
        var process: Process?
    }

    private static let maxAttempts = 3

    func stream(_ messages: [Message]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            guard let path = Self.locate(custom: config.claudePath) else {
                continuation.finish(throwing: ClaudeError.notFound)
                return
            }
            let running = Running()
            let task = Task {
                do {
                    // A connector can fail to come up when the CLI starts; then the model would answer
                    // without it. Stop that attempt before it replies and start again.
                    for attempt in 1...Self.maxAttempts {
                        let missing = try await run(path: path, messages: messages, running: running,
                                                    retryIfMissing: attempt < Self.maxAttempts,
                                                    continuation: continuation)
                        if missing.isEmpty { break }
                        onActivity?("Connecting \(missing.joined(separator: ", "))…")
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                if running.process?.isRunning == true { running.process?.terminate() }
            }
        }
    }

    private struct InitEvent: Decodable {
        struct Server: Decodable { var name: String; var status: String }
        var subtype: String?
        var tools: [String]?
        var mcp_servers: [Server]?
    }

    /// One CLI run. Returns the names of enabled connectors that weren't connected when it started
    /// (only when `retryIfMissing`, in which case the run was stopped before replying).
    private func run(path: String, messages: [Message], running: Running, retryIfMissing: Bool,
                     continuation: AsyncThrowingStream<String, Error>.Continuation) async throws -> [String] {
        let workDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bot27/claude", isDirectory: true)
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.currentDirectoryURL = workDir
        var args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json",
                    "--verbose", "--include-partial-messages",
                    "--system-prompt", config.systemPrompt,
                    "--tools", "", "--setting-sources", "",
                    "--no-session-persistence"]
        var allowed: [String] = []
        if computerUse, let exe = Bundle.main.executablePath {
            let relay = ComputerRelay.shared
            let config = ["mcpServers": [ComputerMCP.server: [
                "command": exe, "args": ["--computer-mcp"],
                "env": ["BOT27_RELAY_SOCKET": relay.path, "BOT27_RELAY_TOKEN": relay.token],
            ]]]
            if let data = try? JSONSerialization.data(withJSONObject: config), let json = String(data: data, encoding: .utf8) {
                args += ["--mcp-config", json]
                allowed += ComputerMCP.toolIDs
            }
        }
        var blockedBrowser: [String] = []
        if browserUse {
            // --chrome adds the extension's server even with --strict-mcp-config.
            args.append("--chrome")
            allowed += BrowserUse.allowedTools
            blockedBrowser = BrowserUse.blockedTools
        }
        if connectors.isEmpty {
            args.append("--strict-mcp-config")
            if !blockedBrowser.isEmpty { args += ["--disallowedTools", blockedBrowser.joined(separator: ",")] }
        } else {
            // Only read and draft tools are allowed. Write tools of enabled connectors, and
            // whole servers the bot doesn't use, are removed so the model never sees them.
            let enabled = Set(connectors.map(\.id))
            let blocked = connectors.flatMap(\.blockedTools)
                + allConnectors.filter { !enabled.contains($0.id) }.map { "mcp__\($0.id)" }
                + blockedBrowser
            allowed += connectors.flatMap(\.allowedTools)
            if !blocked.isEmpty { args += ["--disallowedTools", blocked.joined(separator: ",")] }
        }
        if !allowed.isEmpty { args += ["--allowedTools", allowed.joined(separator: ",")] }
        if !config.claudeModel.isEmpty { args += ["--model", config.claudeModel] }
        process.arguments = args
        var env = CLIEnvironment.make()
        env["CLAUDE_CODE_DISABLE_CLAUDE_MDS"] = "1"
        // claude.ai connectors load in the background by default, so a one-shot reply can
        // start before they're connected; wait for them instead.
        env["MCP_CONNECTION_NONBLOCKING"] = "0"
        process.environment = env

        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        running.process = process

        try process.run()
        stdin.fileHandleForWriting.write(Self.inputLine(for: messages))
        try stdin.fileHandleForWriting.close()

        var gotText = false
        for try await line in stdout.fileHandleForReading.bytes.lines {
            if !connectors.isEmpty, line.contains("\"subtype\":\"init\""),
               let initEvent = try? JSONDecoder().decode(InitEvent.self, from: Data(line.utf8)),
               initEvent.subtype == "init" {
                let servers = initEvent.mcp_servers ?? []
                let missing = connectors.filter { c in
                    !servers.contains { s in
                        s.status == "connected"
                            && s.name.replacingOccurrences(of: "[^A-Za-z0-9]", with: "_", options: .regularExpression) == c.id
                    }
                }.map(\.name)
                Self.log("model=\(config.claudeModel) want=\(connectors.map(\.name)) servers=\(servers.map { "\($0.name):\($0.status)" }) tools=\(initEvent.tools?.count ?? 0) missing=\(missing)")
                if !missing.isEmpty && retryIfMissing {
                    process.terminate()
                    return missing
                }
                continue
            }
            guard let event = try? JSONDecoder().decode(Event.self, from: Data(line.utf8)) else { continue }
            if event.type == "stream_event", event.event?.type == "content_block_start",
               let block = event.event?.content_block {
                if block.type == "tool_use", let name = block.name {
                    if name.hasPrefix("mcp__\(ComputerMCP.server)__") { onComputer?() }
                    if name.hasPrefix(BrowserUse.prefix) { onBrowser?() }
                    onActivity?(Connector.describe(name, in: allConnectors))
                } else if block.type == "text" {
                    onActivity?("")
                    // Text after a tool call starts a new paragraph.
                    if gotText { continuation.yield("\n\n") }
                }
            } else if event.type == "stream_event", event.event?.type == "content_block_delta",
               event.event?.delta?.type == "text_delta", let text = event.event?.delta?.text {
                gotText = true
                continuation.yield(text)
            } else if event.type == "result" {
                if event.is_error == true { throw ClaudeError.failed(event.result ?? "") }
                if !gotText, let text = event.result, !text.isEmpty { continuation.yield(text) }
            }
        }
        process.waitUntilExit()
        if process.terminationStatus != 0 && !gotText {
            let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw ClaudeError.failed(err.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return []
    }

    /// One line per run in ~/Library/Application Support/Bot27/claude.log, for diagnosing connectors.
    static func log(_ text: String) {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bot27/claude.log")
        let line = Data("\(Date().formatted(.iso8601)) \(text)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: url)
        }
    }

    /// Starts the CLI just long enough to read its `system/init` event, which lists the
    /// MCP servers (claude.ai connectors) and their tools, then stops it before it replies.
    static func discoverConnectors(custom: String) async -> [Connector] {
        guard let path = locate(custom: custom) else { return [] }
        struct Init: Decodable {
            struct Server: Decodable { var name: String; var status: String }
            var type: String
            var subtype: String?
            var tools: [String]?
            var mcp_servers: [Server]?
        }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let workDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("Bot27/claude", isDirectory: true)
                try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.currentDirectoryURL = workDir
                process.arguments = ["-p", "--output-format", "stream-json", "--verbose", "--tools", "",
                                     "--setting-sources", "", "--no-session-persistence",
                                     "--model", "claude-haiku-5-5"]
                var env = CLIEnvironment.make()
                env["CLAUDE_CODE_DISABLE_CLAUDE_MDS"] = "1"
                env["MCP_CONNECTION_NONBLOCKING"] = "0"
                process.environment = env
                let stdin = Pipe(), stdout = Pipe()
                process.standardInput = stdin
                process.standardOutput = stdout
                process.standardError = FileHandle.nullDevice

                var result: [Connector] = []
                if (try? process.run()) != nil {
                    stdin.fileHandleForWriting.write(Data("hi".utf8))
                    try? stdin.fileHandleForWriting.close()
                    var buffer = Data()
                    reading: while true {
                        let chunk = stdout.fileHandleForReading.availableData
                        if chunk.isEmpty { break }
                        buffer.append(chunk)
                        while let newline = buffer.firstIndex(of: 10) {
                            let line = buffer[buffer.startIndex..<newline]
                            buffer = Data(buffer[buffer.index(after: newline)...])
                            if let event = try? JSONDecoder().decode(Init.self, from: line),
                               event.type == "system", event.subtype == "init" {
                                result = Connector.catalog(
                                    servers: (event.mcp_servers ?? []).map { ($0.name, $0.status) },
                                    tools: event.tools ?? [])
                                break reading
                            }
                        }
                    }
                    if process.isRunning { process.terminate() }
                }
                continuation.resume(returning: result)
            }
        }
    }
}
