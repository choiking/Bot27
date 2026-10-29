import Foundation

/// Talks to GPT through the locally installed Codex CLI, using the user's ChatGPT login.
/// `codex exec --json` reports whole messages rather than token deltas.
struct CodexCLI {
    var config: AppConfig

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
        struct Item: Decodable { var type: String; var text: String? }
        struct Failure: Decodable { var message: String }
        var type: String
        var item: Item?
        var error: Failure?
    }

    /// Codex nests the API error as a JSON string; pull out the readable part.
    private static func readable(_ message: String) -> String {
        struct Wrapped: Decodable { struct Inner: Decodable { var message: String }; var error: Inner }
        return (try? JSONDecoder().decode(Wrapped.self, from: Data(message.utf8)))?.error.message ?? message
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
                + conversation.images.map { "--image=" + ImageStore.url($0).path }
                + ["-"]
            process.environment = CLIEnvironment.make()

            let stdin = Pipe(), stdout = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice

            let prompt = "<instructions>\n\(config.systemPrompt)\nYou are chatting, not coding: don't run commands or touch files.\n</instructions>\n\n"
                + (conversation.images.isEmpty ? "" : "Images 1–\(conversation.images.count) are attached in order.\n\n")
                + conversation.text

            let task = Task {
                do {
                    try process.run()
                    stdin.fileHandleForWriting.write(Data(prompt.utf8))
                    try stdin.fileHandleForWriting.close()

                    var replies = 0
                    for try await line in stdout.fileHandleForReading.bytes.lines {
                        guard let event = try? JSONDecoder().decode(Event.self, from: Data(line.utf8)) else { continue }
                        if event.type == "item.completed", event.item?.type == "agent_message",
                           let text = event.item?.text, !text.isEmpty {
                            continuation.yield(replies == 0 ? text : "\n\n" + text)
                            replies += 1
                        } else if event.type == "turn.failed" {
                            throw ClaudeError.failed(Self.readable(event.error?.message ?? ""))
                        }
                    }
                    process.waitUntilExit()
                    if replies == 0 { throw ClaudeError.failed("GPT exited without a reply.") }
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
