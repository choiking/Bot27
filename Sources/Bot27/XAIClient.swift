import Foundation

enum XAIError: LocalizedError {
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case let .http(code, body):
            let detail = body.isEmpty ? "" : ": \(body.prefix(400))"
            return "Request failed (HTTP \(code))\(detail)"
        }
    }
}

/// Streams chat completions from xAI (or any OpenAI-compatible endpoint).
struct XAIClient {
    var config: AppConfig

    private struct Chunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable { var content: String? }
            var delta: Delta
        }
        var choices: [Choice]
    }

    func stream(_ messages: [Message]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = URLRequest(url: config.baseURL.appendingPathComponent("chat/completions"))
                    req.httpMethod = "POST"
                    req.setValue("Bearer \(config.apiKey ?? "")", forHTTPHeaderField: "Authorization")
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    let recent = Set(messages.flatMap { $0.images ?? [] }.suffix(ClaudeCLI.maxImages))
                    let history: [[String: Any]] = [["role": "system", "content": config.systemPrompt]]
                        + messages.map { m -> [String: Any] in
                            let images = (m.images ?? []).filter(recent.contains).compactMap(ImageStore.base64)
                            guard !images.isEmpty else { return ["role": m.role.rawValue, "content": m.content] }
                            let parts: [[String: Any]] = [["type": "text", "text": m.content]]
                                + images.map { ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\($0)"]] }
                            return ["role": m.role.rawValue, "content": parts]
                        }
                    req.httpBody = try JSONSerialization.data(withJSONObject: [
                        "model": config.model,
                        "stream": true,
                        "messages": history,
                    ] as [String: Any])

                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        var body = ""
                        for try await line in bytes.lines { body += line }
                        throw XAIError.http(http.statusCode, body)
                    }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        if let chunk = try? JSONDecoder().decode(Chunk.self, from: Data(payload.utf8)),
                           let delta = chunk.choices.first?.delta.content, !delta.isEmpty {
                            continuation.yield(delta)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
