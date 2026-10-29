import Foundation

/// An MCP server the claude CLI can reach, such as a claude.ai connector (Gmail, Notion…).
struct Connector: Identifiable, Codable, Equatable {
    var id: String       // tool prefix, e.g. "claude_ai_Gmail"
    var name: String     // "Gmail"
    var status: String   // "connected", "needs-auth", …
    var tools: [String]  // full tool names, e.g. "mcp__claude_ai_Gmail__search_threads"

    var isConnected: Bool { status == "connected" }

    enum Access { case read, draft, write }

    private static let readVerbs: Set<String> = [
        "get", "list", "search", "read", "query", "fetch", "find", "suggest", "view", "lookup",
        "guide", "export", "retrieve", "describe",
    ]
    private static let writeWords: Set<String> = [
        "send", "delete", "trash", "untrash", "create", "update", "remove", "move", "archive", "apply",
        "label", "unlabel", "mark", "unmark", "reply", "forward", "respond", "add", "set", "edit", "write",
        "post", "upload", "batch", "duplicate", "comment", "invite", "share",
    ]

    static func shortName(_ tool: String) -> String { tool.components(separatedBy: "__").last ?? tool }

    /// Bots may read and draft; anything that sends, changes or deletes is blocked.
    /// Unknown verbs count as writes, so new tools stay blocked until they're recognised.
    static func access(_ tool: String) -> Access {
        let words = shortName(tool).lowercased().split { $0 == "_" || $0 == "-" }.map(String.init)
        if words.contains("draft"), words.first == "create" || words.first == "update" { return .draft }
        if words.contains(where: writeWords.contains) { return .write }
        return words.prefix(2).contains(where: readVerbs.contains) ? .read : .write
    }

    var allowedTools: [String] { tools.filter { Self.access($0) != .write } }
    var blockedTools: [String] { tools.filter { Self.access($0) == .write } }
    var canDraft: Bool { tools.contains { Self.access($0) == .draft } }

    /// "mcp__claude_ai_Gmail__search_threads" → "Gmail · search threads"
    static func describe(_ tool: String, in connectors: [Connector]) -> String {
        let action = shortName(tool).replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        let owner = tool.hasPrefix("mcp__\(ComputerMCP.server)__") ? "Computer"
            : tool.hasPrefix(BrowserUse.prefix) ? "Browser"
            : connectors.first { tool.hasPrefix("mcp__\($0.id)__") }?.name
        return owner.map { "\($0) · \(action)" } ?? action
    }

    /// Builds the catalog from the claude CLI's `system/init` event.
    static func catalog(servers: [(name: String, status: String)], tools: [String]) -> [Connector] {
        servers.map { server in
            let id = server.name.replacingOccurrences(of: "[^A-Za-z0-9]", with: "_", options: .regularExpression)
            let name = server.name.hasPrefix("claude.ai ") ? String(server.name.dropFirst(10)) : server.name
            return Connector(id: id, name: name, status: server.status,
                             tools: tools.filter { $0.hasPrefix("mcp__\(id)__") })
        }
    }
}

// MARK: - Connecting from chat

/// What a bot writes in a ```bot27-connect block to ask for (or drop) a connection.
struct ConnectSpec: Decodable {
    var connector: String
    var action: String?  // "connect" (default) or "disconnect"

    static let fence = "bot27-connect"

    static func blocks(in text: String) -> [(range: Range<String.Index>, spec: ConnectSpec?)] {
        text.matches(of: #/```bot27-connect[ \t]*\n([\s\S]*?)```/#).map { match in
            (match.range, try? JSONDecoder().decode(ConnectSpec.self, from: Data(String(match.1).utf8)))
        }
    }
}

/// A connection a bot asked for in chat. Connecting needs the user's click.
struct ConnectNote: Codable, Equatable {
    enum State: String, Codable { case requested, connected, declined, unavailable, disconnected }
    var connectorID: String?
    var name: String
    var state: State
}

extension Connector {
    /// Computer use is requested like a connector, but it's Bot27's own tool rather than a claude.ai service.
    static let computerID = "computer"
    static let browserID = "browser"

    func find(_ name: String) -> Bool {
        self.name.caseInsensitiveCompare(name) == .orderedSame || id == name
    }

    var accessText: String {
        canDraft ? "search and read your \(name) and draft emails" : "search and read your \(name)"
    }

    /// Tells the bot what it's connected to, and how to ask for more.
    static func chatInstructions(bot: Bot, catalog: [Connector], isClaude: Bool) -> String {
        let mine = isClaude ? catalog.filter { $0.isConnected && bot.connections?.contains($0.id) == true } : []
        let available = catalog.filter { c in c.isConnected && !mine.contains { $0.id == c.id } }
        let unset = catalog.filter { !$0.isConnected }
        var text = """
        Connections: Bot27 can connect you to the user's services through their Claude account.
        Connected for you now: \(mine.isEmpty ? "none" : mine.map(\.name).joined(separator: ", ")).
        Available to connect: \(available.isEmpty ? "none" : available.map(\.name).joined(separator: ", ")).
        Not set up in the user's Claude account yet: \(unset.isEmpty ? "none" : unset.map(\.name).joined(separator: ", ")) \
        (other services like Notion can be added at claude.ai → Settings → Connectors).
        Computer use (see the screen and use the mouse and keyboard of this Mac, for tasks in apps or websites that no \
        connector covers): \(isClaude && bot.computerUse == true ? "on" : "off; ask for it with {\"connector\": \"Computer\"}").
        Browser use (use the user's Google Chrome to open, read and act on web pages; better than computer use for \
        anything on the web): \(isClaude && bot.browserUse == true ? "on" : "off; ask for it with {\"connector\": \"Browser\"}").
        If a request needs a service you aren't connected to, don't ask the user to paste, screenshot or export things. \
        Ask to connect it by including this block in your reply, plus one short sentence on what you'll do once connected:

        ```bot27-connect
        {"connector": "Gmail"}
        ```

        The user sees a Connect button (the block itself is hidden); when they press it you get access and continue \
        their request automatically. Use the same block for services that aren't set up yet: the user gets a link to add them. \
        Access is read-only, plus email drafts. To drop a connection: {"connector": "Gmail", "action": "disconnect"}.
        """
        if !isClaude {
            text += " Connecting also switches you to a Claude model, because connections only work with Claude."
        }
        return text
    }
}
