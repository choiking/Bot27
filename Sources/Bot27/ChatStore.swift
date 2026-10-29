import AppKit

struct Message: Identifiable, Codable, Equatable {
    enum Role: String, Codable { case user, assistant }

    var id = UUID()
    var role: Role
    var content: String
    var isError: Bool? = nil
    var date = Date()
    var images: [String]? = nil
    /// Set when a task or routine sent this message; shown as a small label instead of a bubble.
    var job: String? = nil
    var jobIsRoutine: Bool? = nil
    /// Jobs this reply set up or removed, shown as cards under it.
    var jobNotes: [JobNote]? = nil
    /// Connections this reply asked for, shown as cards with a Connect button.
    var connectNotes: [ConnectNote]? = nil
    /// Notes this reply saved to or dropped from the bot's memory, shown as cards under it.
    var memoryNotes: [MemoryNote]? = nil
    /// A small label instead of a bubble, e.g. "Gmail connected".
    var notice: String? = nil
}

struct JobNote: Codable, Equatable {
    enum Change: String, Codable { case created, deleted, undone, failed }
    var jobID: UUID?
    var title: String
    var detail: String
    var isRoutine: Bool
    var change: Change
}

struct Bot: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var instructions: String
    var shape: Int
    var color: Int
    var messages: [Message] = []
    var updatedAt = Date()
    var unread = false
    var provider: String? = nil
    var model: String? = nil
    var pinned: Bool? = nil
    /// IDs of the connectors (claude.ai MCP servers) this bot may use.
    var connections: [String]? = nil
    /// Lets the bot see the screen and use the mouse and keyboard (Claude models only).
    var computerUse: Bool? = nil
    /// Lets the bot use the user's Chrome via Claude in Chrome (Claude models only).
    var browserUse: Bool? = nil
    var jobs: [BotJob]? = nil
    /// Older messages folded into a summary, which the bot sees instead of them.
    var summary: String? = nil
    /// The last message the summary covers.
    var summaryThrough: UUID? = nil
    /// The "New session" notice the current session starts after; earlier messages stay on screen
    /// but the bot no longer sees them.
    var sessionStart: UUID? = nil
    /// When the user last sent a message, for the session reset policy.
    var lastActive: Date? = nil
    /// When the dreaming pass last ran for this bot.
    var lastDream: Date? = nil

    /// Index just past the summarized messages; 0 when there's no summary (or it's for a cleared chat).
    private var summaryEnd: Int {
        guard summary != nil, let through = summaryThrough,
              let i = messages.firstIndex(where: { $0.id == through }) else { return 0 }
        return i + 1
    }

    /// Index of the current session's first message.
    var sessionBegin: Int {
        guard let start = sessionStart, let i = messages.firstIndex(where: { $0.id == start }) else { return 0 }
        return i + 1
    }

    var hasSummary: Bool { summaryEnd > sessionBegin }

    /// The current session's messages.
    var sessionMessages: [Message] { Array(messages[sessionBegin...]) }

    /// The session's chat without notices or routine runs, which are sessions of their own.
    var chatMessages: [Message] {
        var kept: [Message] = [], inRoutine = false
        for m in sessionMessages {
            if m.role == .user && m.notice != RecallSpec.notice { inRoutine = m.job != nil }
            if !inRoutine && m.notice == nil { kept.append(m) }
        }
        return kept
    }

    /// The session's messages the summary doesn't cover; the bot sees these word for word.
    var recentMessages: [Message] { Array(messages[max(summaryEnd, sessionBegin)...]) }

    var jobList: [BotJob] {
        get { jobs ?? [] }
        set { jobs = newValue.isEmpty ? nil : newValue }
    }

    var isPinned: Bool { pinned == true }

    var modelChoice: ModelChoice {
        get {
            guard let p = provider.flatMap(AppConfig.Provider.init(rawValue:)), let model else { return .defaultChoice }
            return ModelChoice(provider: p, id: model)
        }
        set {
            provider = newValue.provider.rawValue
            model = newValue.id
        }
    }

    var preview: String {
        guard let last = messages.last(where: {
            !$0.content.isEmpty || $0.images?.isEmpty == false || $0.jobNotes?.isEmpty == false
                || $0.memoryNotes?.isEmpty == false
        }) else { return "No messages yet" }
        if last.content.isEmpty, let note = last.jobNotes?.first { return note.title }
        if last.content.isEmpty, let note = last.memoryNotes?.first { return note.text }
        if last.isError == true { return "Couldn't get a reply" }
        if last.content.isEmpty { return "Photo" }
        let line = last.content.split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        return line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "#", with: "")
            .replacingOccurrences(of: "`", with: "").trimmingCharacters(in: .whitespaces)
    }

    static let defaults: [Bot] = [
        Bot(name: "Assistant", instructions: "A sharp, friendly general assistant.", shape: 0, color: 0, pinned: true),
        Bot(name: "Writer", instructions: "Helps draft and polish emails, posts and docs. Reply in the user's language.", shape: 1, color: 1),
        Bot(name: "Coder", instructions: "A senior software engineer. Give working code with brief explanations.", shape: 2, color: 2),
        Bot(name: "Coach", instructions: "A practical, evidence-based health and fitness coach.", shape: 3, color: 3),
    ]
}

struct EditorRequest: Identifiable {
    let id = UUID()
    var bot: Bot
    var isNew: Bool
    var tab: BotEditor.Tab = .profile
}

@MainActor
final class ChatStore: ObservableObject {
    static let missingKeyNotice = "missing-api-key"

    @Published var bots: [Bot] = [] {
        didSet { Notifier.shared.badge(bots.filter(\.unread).count) }
    }
    @Published var selectedID: UUID?
    @Published var draft = ""
    @Published var pendingImages: [String] = []
    @Published var editor: EditorRequest?
    @Published private(set) var streaming: Set<UUID> = []
    /// What a streaming bot is doing right now, e.g. "Gmail · search threads".
    @Published private(set) var activity: [UUID: String] = [:]
    /// Bots controlling the computer right now; they get the stop bar.
    @Published private(set) var computerActive: Set<UUID> = []
    @Published private(set) var browserActive: Set<UUID> = []
    /// Long messages the user folded or unfolded, relative to the default (yours folded, replies open).
    @Published var toggledFolds: Set<UUID> = []
    /// Runs that may use the computer; the relay only accepts actions while there are some.
    private var computerRuns: Set<UUID> = [] {
        didSet { ComputerRelay.shared.active = !computerRuns.isEmpty }
    }
    @Published private(set) var connectors: [Connector] = []

    private var tasks: [UUID: Task<Void, Never>] = [:]
    /// Jobs started while their bot was busy; they run once it's free.
    private var queuedJobs: [(bot: UUID, job: UUID)] = []
    /// Bots whose older messages are being folded into their summary.
    private var compacting: Set<UUID> = []
    /// Bots whose dreaming pass is running.
    private var dreaming: Set<UUID> = []
    private var scheduler: Timer?
    private let fileURL: URL

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bot27", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("bots.json")
        AppConfig.migrate()
        load()
        if bots.isEmpty { bots = Bot.defaults }
        // Bots from before per-bot models start on the Settings default.
        for i in bots.indices where bots[i].provider == nil {
            bots[i].modelChoice = .defaultChoice
        }
        // One-time jobs used to count as tasks; anything with a time is a routine now.
        for i in bots.indices {
            let jobs = bots[i].jobList
            for m in bots[i].messages.indices {
                if let title = bots[i].messages[m].job, let job = jobs.first(where: { $0.title == title }) {
                    bots[i].messages[m].jobIsRoutine = job.isRoutine
                }
                bots[i].messages[m].jobNotes = bots[i].messages[m].jobNotes?.map { note in
                    var note = note
                    if let job = jobs.first(where: { $0.id == note.jobID }) { note.isRoutine = job.isRoutine }
                    return note
                }
            }
        }
        for bot in bots { MemoryStore.setUp(bot) }
        // The main bot starts pinned, once; after that pinning is the user's call.
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "pinnedMainBot") {
            if let i = bots.firstIndex(where: { $0.name == Bot.defaults[0].name }) { bots[i].pinned = true }
            defaults.set(true, forKey: "pinnedMainBot")
        }
        selectedID = sortedBots.first?.id
        if let data = defaults.data(forKey: "connectorCatalog"),
           let cached = try? JSONDecoder().decode([Connector].self, from: data) {
            connectors = cached
        }
        refreshConnectors()
        ComputerRelay.shared.start()
        Notifier.shared.open = { [weak self] id in self?.select(id) }
        Notifier.shared.isShowing = { [weak self] id in NSApp.isActive && self?.selectedID == id }
        Notifier.shared.setUp()
        // Asking is what puts Bot27 in System Settings' permission lists.
        if bots.contains(where: { $0.computerUse == true }), !ComputerPermissions.granted {
            ComputerPermissions.request()
        }
        scheduler = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.runDueJobs() }
        }
        Task {
            try? await Task.sleep(for: .seconds(3))
            runDueJobs()
        }
    }

    func refreshConnectors() {
        Task {
            // Connectors can still be "pending" when the CLI starts; retry, then keep the
            // last known tools for any that haven't finished connecting.
            var found: [Connector] = []
            for attempt in 0..<4 {
                if attempt > 0 { try? await Task.sleep(for: .seconds(3)) }
                found = await ClaudeCLI.discoverConnectors(custom: AppConfig.current.claudePath)
                if !found.contains(where: { $0.status == "pending" }) { break }
            }
            guard !found.isEmpty else { return }
            let previous = connectors
            found = found.map { c in
                guard c.status == "pending", let old = previous.first(where: { $0.id == c.id }), !old.tools.isEmpty
                else { return c }
                return old
            }
            connectors = found
            if let data = try? JSONEncoder().encode(found) {
                UserDefaults.standard.set(data, forKey: "connectorCatalog")
            }
        }
    }

    /// Sidebar order: pinned bots first, each group most recent first.
    var sortedBots: [Bot] { bots.filter(\.isPinned) + bots.filter { !$0.isPinned } }

    var selectedBot: Bot? { bots.first { $0.id == selectedID } }
    var isStreaming: Bool { selectedID.map { streaming.contains($0) } ?? false }

    // MARK: - Bots

    func select(_ id: UUID) {
        selectedID = id
        Notifier.shared.seen(bot: id)
        mutate(id) { $0.unread = false }
        save()
    }

    func newBot() {
        let used = Set(bots.map { $0.color })
        let color = Theme.avatarColors.indices.first { !used.contains($0) } ?? Int.random(in: 0..<Theme.avatarColors.count)
        var bot = Bot(name: "", instructions: "", shape: Int.random(in: 0..<Theme.avatarShapes), color: color)
        bot.modelChoice = .defaultChoice
        editor = EditorRequest(bot: bot, isNew: true)
    }

    func edit(_ id: UUID, tab: BotEditor.Tab = .profile) {
        guard let bot = bots.first(where: { $0.id == id }) else { return }
        editor = EditorRequest(bot: bot, isNew: false, tab: tab)
    }

    func commit(_ request: EditorRequest) {
        if request.isNew {
            MemoryStore.setUp(request.bot)
            bots.insert(request.bot, at: 0)
            select(request.bot.id)
        } else {
            mutate(request.bot.id) {
                $0.name = request.bot.name
                $0.instructions = request.bot.instructions
                $0.shape = request.bot.shape
                $0.color = request.bot.color
                $0.modelChoice = request.bot.modelChoice
                $0.connections = request.bot.connections
                $0.computerUse = request.bot.computerUse
                $0.browserUse = request.bot.browserUse
                // A job may have run while the editor was open; keep that run.
                let live = $0.jobList
                $0.jobList = request.bot.jobList.map { job in
                    guard let current = live.first(where: { $0.id == job.id }),
                          let ran = current.lastRun, ran > (job.lastRun ?? .distantPast) else { return job }
                    var merged = job
                    merged.lastRun = ran
                    return merged
                }
            }
        }
        save()
    }

    func togglePin(_ id: UUID) {
        mutate(id) { $0.pinned = !$0.isPinned }
        save()
    }

    // MARK: - Tasks & routines

    /// Runs a job now: posts its prompt into the bot's chat and replies to it.
    func runJob(bot botID: UUID, job jobID: UUID) {
        guard let bot = bots.first(where: { $0.id == botID }),
              let job = bot.jobList.first(where: { $0.id == jobID }) else { return }
        if streaming.contains(botID) {
            if !queuedJobs.contains(where: { $0.bot == botID && $0.job == jobID }) { queuedJobs.append((botID, jobID)) }
            return
        }
        mutate(botID) { bot in
            guard let i = bot.jobList.firstIndex(where: { $0.id == jobID }) else { return }
            bot.jobList[i].lastRun = Date()
            bot.messages.append(Message(role: .user, content: job.prompt, job: job.title,
                                        jobIsRoutine: job.isRoutine))
        }
        // Each run is its own session: the bot sees only the job's prompt, not the chat.
        respond(in: botID, isolated: true)
    }

    /// Starts a fresh session: the bot stops seeing earlier messages and their summary, and the end of
    /// the old one is saved as memory/YYYY-MM-DD-HHMM.md.
    func newSession(_ id: UUID) {
        guard let bot = bots.first(where: { $0.id == id }), !bot.sessionMessages.isEmpty else { return }
        DailyNotes.saveSession(bot.chatMessages, for: id)
        let notice = Message(role: .user, content: "", notice: "New session")
        mutate(id) {
            $0.messages.append(notice)
            $0.sessionStart = notice.id
            $0.summary = nil
            $0.summaryThrough = nil
        }
        save()
    }

    /// Runs the dreaming pass for a bot in the background: lasting notes from its recent daily notes go
    /// into MEMORY.md.
    func dream(_ id: UUID) {
        guard !dreaming.contains(id), let bot = bots.first(where: { $0.id == id }) else { return }
        let started = Date()
        guard let notes = Dreaming.input(for: id, since: bot.lastDream, now: started) else {
            mutate(id) { $0.lastDream = started }
            save()
            return
        }
        var config = AppConfig.current.with(Compaction.model(for: bot.modelChoice))
        config.systemPrompt = Dreaming.instructions(bot: id)
        let input = [Message(role: .user, content: "Recent daily notes:\n\n" + notes)]
        dreaming.insert(id)
        Task { [weak self] in
            let text = await Self.complete(config, input)
            self?.finishDream(id, text: text, at: started)
        }
    }

    private func finishDream(_ id: UUID, text: String?, at date: Date) {
        dreaming.remove(id)
        guard bots.contains(where: { $0.id == id }) else { return }
        // A failed pass waits for the next night rather than retrying every tick.
        mutate(id) { $0.lastDream = date }
        save()
        guard let text else { return }
        for block in MemorySpec.blocks(in: text) {
            guard let spec = block.spec else { continue }
            if let note = spec.saved {
                MemoryStore.add(note, for: id)
            } else if spec.action == "forget", let note = spec.text {
                MemoryStore.remove(note, for: id)
            }
        }
    }

    /// A whole reply to a one-off prompt, or nil if it failed.
    private static func complete(_ config: AppConfig, _ input: [Message]) async -> String? {
        var text = ""
        do {
            let replies: AsyncThrowingStream<String, Error>
            switch config.provider {
            case .claude: replies = ClaudeCLI(config: config).stream(input)
            case .gpt: replies = CodexCLI(config: config).stream(input)
            case .xai: replies = XAIClient(config: config).stream(input)
            }
            for try await delta in replies { text += delta }
        } catch {
            return nil
        }
        return text
    }

    /// Turns ```bot27-job, ```bot27-connect and ```bot27-memory blocks in the bot's latest reply into
    /// jobs, connection requests and memory notes, and replaces them with cards. A ```bot27-recall block
    /// posts the matching notes back; returns true when the bot should answer again with them.
    @discardableResult
    private func applyActionBlocks(in botID: UUID) -> Bool {
        guard let bot = bots.first(where: { $0.id == botID }), let i = bot.messages.indices.last,
              bot.messages[i].role == .assistant else { return false }
        let content = bot.messages[i].content
        let blocks = JobSpec.blocks(in: content)
        let connects = ConnectSpec.blocks(in: content)
        let memories = MemorySpec.blocks(in: content)
        let recalls = RecallSpec.blocks(in: content)
        guard !blocks.isEmpty || !connects.isEmpty || !memories.isEmpty || !recalls.isEmpty else { return false }

        // Routines run in sessions of their own and don't save notes. Search results aren't the user asking.
        let isRoutine = bot.messages[..<i].last(where: { $0.role == .user && $0.notice != RecallSpec.notice })?.job != nil
        // At most two searches in a row; then the bot has to answer.
        let searches = bot.messages[..<i].reversed()
            .prefix { $0.notice == RecallSpec.notice || $0.role == .assistant }
            .filter { $0.notice == RecallSpec.notice }.count
        let results = searches < 2 ? recalls.compactMap(\.spec).map { $0.results(for: botID) } : []
        var memoryNotes: [MemoryNote] = []
        for block in memories where !isRoutine {
            guard let spec = block.spec else { continue }
            if let text = spec.saved {
                if MemoryStore.add(text, for: botID, spec.target) {
                    memoryNotes.append(MemoryNote(text: text, change: .saved, file: spec.target))
                }
            } else if spec.action == "forget", let text = spec.text,
                      // The note may be in another file than the block says.
                      let file = ([spec.target] + MemoryFile.allCases.filter { $0 != spec.target })
                          .first(where: { MemoryStore.remove(text, for: botID, $0) }) {
                memoryNotes.append(MemoryNote(text: text, change: .forgotten, file: file))
            }
        }

        var connections = bot.connections ?? []
        var computerUse = bot.computerUse == true
        var browserUse = bot.browserUse == true
        var connectNotes: [ConnectNote] = []
        for block in connects {
            guard let spec = block.spec else { continue }
            let connector = connectors.first { $0.find(spec.connector) }
            if spec.connector.caseInsensitiveCompare(Connector.browserID) == .orderedSame {
                if spec.action == "disconnect" {
                    if browserUse {
                        browserUse = false
                        connectNotes.append(ConnectNote(connectorID: Connector.browserID, name: "Browser use", state: .disconnected))
                    }
                } else if !(browserUse && bot.modelChoice.provider == .claude) {
                    connectNotes.append(ConnectNote(connectorID: Connector.browserID, name: "Browser use", state: .requested))
                }
            } else if spec.connector.caseInsensitiveCompare(Connector.computerID) == .orderedSame {
                if spec.action == "disconnect" {
                    if computerUse {
                        computerUse = false
                        connectNotes.append(ConnectNote(connectorID: Connector.computerID, name: "Computer use", state: .disconnected))
                    }
                } else if !(computerUse && bot.modelChoice.provider == .claude) {
                    connectNotes.append(ConnectNote(connectorID: Connector.computerID, name: "Computer use", state: .requested))
                }
            } else if spec.action == "disconnect" {
                guard let connector, connections.contains(connector.id) else { continue }
                connections.removeAll { $0 == connector.id }
                connectNotes.append(ConnectNote(connectorID: connector.id, name: connector.name, state: .disconnected))
            } else if let connector, connector.isConnected {
                let usable = bot.modelChoice.provider == .claude && connections.contains(connector.id)
                if !usable {
                    connectNotes.append(ConnectNote(connectorID: connector.id, name: connector.name, state: .requested))
                }
            } else {
                connectNotes.append(ConnectNote(connectorID: connector?.id, name: connector?.name ?? spec.connector,
                                                state: .unavailable))
            }
        }

        var jobs = bot.jobList
        var notes: [JobNote] = []
        for block in blocks {
            guard let spec = block.spec else {
                notes.append(JobNote(title: "Couldn't set this up", detail: "The bot's request was malformed.",
                                     isRoutine: true, change: .failed))
                continue
            }
            if spec.action == "delete", let id = spec.id.flatMap(UUID.init(uuidString:)),
               let j = jobs.firstIndex(where: { $0.id == id }) {
                let job = jobs.remove(at: j)
                notes.append(JobNote(jobID: nil, title: job.title, detail: job.scheduleText,
                                     isRoutine: job.isRoutine, change: .deleted))
            } else if let job = spec.makeJob() {
                jobs.append(job)
                notes.append(JobNote(jobID: job.id, title: job.title, detail: job.scheduleText,
                                     isRoutine: job.isRoutine, change: .created))
            } else {
                notes.append(JobNote(title: spec.title ?? "Couldn't set this up",
                                     detail: "Missing or invalid schedule.", isRoutine: true, change: .failed))
            }
        }

        var cleaned = content
        let ranges = (blocks.map(\.range) + connects.map(\.range) + memories.map(\.range) + recalls.map(\.range))
            .sorted { $0.lowerBound > $1.lowerBound }
        for range in ranges { cleaned.removeSubrange(range) }
        cleaned = cleaned.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        mutate(botID) {
            $0.jobList = jobs
            $0.messages[i].content = cleaned
            $0.messages[i].jobNotes = notes.isEmpty ? nil : notes
            $0.messages[i].connectNotes = connectNotes.isEmpty ? nil : connectNotes
            $0.messages[i].memoryNotes = memoryNotes.isEmpty ? nil : memoryNotes
            $0.connections = connections.isEmpty ? nil : connections
            $0.computerUse = computerUse ? true : nil
            $0.browserUse = browserUse ? true : nil
            guard !results.isEmpty else { return }
            // A reply that only asked to search leaves nothing to show.
            if cleaned.isEmpty && notes.isEmpty && connectNotes.isEmpty && memoryNotes.isEmpty { $0.messages.remove(at: i) }
            $0.messages.append(Message(role: .user,
                                       content: results.joined(separator: "\n\n")
                                           + "\n\n(These are search results from Bot27, not a message from the user. Now answer the user's last message.)",
                                       notice: RecallSpec.notice))
        }
        return !results.isEmpty
    }

    /// The user approved a connection a bot asked for: enable it and let the bot carry on.
    func connect(bot botID: UUID, message messageID: UUID, connector connectorID: String) {
        guard !streaming.contains(botID) else { return }
        if connectorID == Connector.browserID {
            mutate(botID) { bot in
                bot.browserUse = true
                if bot.modelChoice.provider != .claude {
                    bot.modelChoice = ModelChoice(provider: .claude, id: AppConfig.current.claudeModel)
                }
                setConnectState(&bot, messageID, connectorID, .connected)
                bot.messages.append(Message(role: .user,
                                            content: "I turned on browser use for you. Please continue with my earlier request.",
                                            notice: "Browser use on"))
            }
            respond(in: botID)
            return
        }
        if connectorID == Connector.computerID {
            ComputerPermissions.request()
            mutate(botID) { bot in
                bot.computerUse = true
                if bot.modelChoice.provider != .claude {
                    bot.modelChoice = ModelChoice(provider: .claude, id: AppConfig.current.claudeModel)
                }
                setConnectState(&bot, messageID, connectorID, .connected)
                bot.messages.append(Message(role: .user,
                                            content: "I turned on computer use for you. Please continue with my earlier request.",
                                            notice: "Computer use on"))
            }
            respond(in: botID)
            return
        }
        guard let connector = connectors.first(where: { $0.id == connectorID }) else { return }
        mutate(botID) { bot in
            if bot.connections?.contains(connectorID) != true {
                bot.connections = (bot.connections ?? []) + [connectorID]
            }
            // Connections only work with Claude models.
            if bot.modelChoice.provider != .claude {
                bot.modelChoice = ModelChoice(provider: .claude, id: AppConfig.current.claudeModel)
            }
            setConnectState(&bot, messageID, connectorID, .connected)
            bot.messages.append(Message(role: .user,
                                        content: "I connected \(connector.name). Please continue with my earlier request.",
                                        notice: "\(connector.name) connected"))
        }
        respond(in: botID)
    }

    func declineConnect(bot botID: UUID, message messageID: UUID, connector connectorID: String?) {
        mutate(botID) { setConnectState(&$0, messageID, connectorID, .declined) }
        save()
    }

    private func setConnectState(_ bot: inout Bot, _ messageID: UUID, _ connectorID: String?, _ state: ConnectNote.State) {
        guard let m = bot.messages.firstIndex(where: { $0.id == messageID }) else { return }
        bot.messages[m].connectNotes = bot.messages[m].connectNotes?.map { note in
            var note = note
            if note.connectorID == connectorID { note.state = state }
            return note
        }
    }

    /// Removes a job a bot just created from chat.
    func undoJob(bot botID: UUID, message messageID: UUID, job jobID: UUID) {
        mutate(botID) { bot in
            bot.jobList.removeAll { $0.id == jobID }
            guard let m = bot.messages.firstIndex(where: { $0.id == messageID }) else { return }
            bot.messages[m].jobNotes = bot.messages[m].jobNotes?.map { note in
                var note = note
                if note.jobID == jobID { note.change = .undone }
                return note
            }
        }
        save()
    }

    /// Reverses a memory change a reply made: forgets a saved note or restores a forgotten one.
    func undoMemory(bot botID: UUID, message messageID: UUID, note index: Int) {
        mutate(botID) { bot in
            guard let m = bot.messages.firstIndex(where: { $0.id == messageID }),
                  let notes = bot.messages[m].memoryNotes, notes.indices.contains(index),
                  notes[index].change != .undone else { return }
            var note = notes[index]
            let file = note.file ?? .memory
            if note.change == .saved { MemoryStore.remove(note.text, for: botID, file) } else { MemoryStore.add(note.text, for: botID, file) }
            note.undid = note.change
            note.change = .undone
            bot.messages[m].memoryNotes?[index] = note
        }
        save()
    }

    private func runDueJobs() {
        let queued = queuedJobs
        queuedJobs = []
        for item in queued { runJob(bot: item.bot, job: item.job) }

        let now = Date()
        for bot in bots where !streaming.contains(bot.id) {
            if let job = bot.jobList.first(where: { $0.isDue(at: now) }) {
                runJob(bot: bot.id, job: job.id)
            }
        }
        // One bot dreams at a time.
        if Dreaming.enabled, dreaming.isEmpty,
           let bot = bots.first(where: { !streaming.contains($0.id) && Dreaming.due(last: $0.lastDream, now: now) }) {
            dream(bot.id)
        }
    }

    private func updateComputerBar() {
        let items = bots.compactMap { bot -> (id: UUID, label: String)? in
            let computer = computerActive.contains(bot.id), browser = browserActive.contains(bot.id)
            guard computer || browser else { return nil }
            let what = computer && browser ? "your computer and browser" : computer ? "your computer" : "your browser"
            return (bot.id, "\(bot.name) is using \(what)")
        }
        ComputerBar.shared.update(items: items) { [weak self] id in self?.stop(id) }
    }

    func setModel(_ id: UUID, _ choice: ModelChoice) {
        mutate(id) { $0.modelChoice = choice }
        save()
    }

    func clear(_ id: UUID) {
        stop(id)
        deleteImages(of: id)
        mutate(id) {
            $0.messages = []
            $0.summary = nil
            $0.summaryThrough = nil
            $0.sessionStart = nil
        }
        save()
    }

    func delete(_ id: UUID) {
        stop(id)
        deleteImages(of: id)
        MemoryStore.delete(id)
        bots.removeAll { $0.id == id }
        if selectedID == id { selectedID = sortedBots.first?.id }
        save()
    }

    private func deleteImages(of id: UUID) {
        guard let bot = bots.first(where: { $0.id == id }) else { return }
        ImageStore.delete(bot.messages.flatMap { $0.images ?? [] })
    }

    // MARK: - Attachments

    func attach(_ providers: [NSItemProvider]) {
        ImageStore.load(providers) { [weak self] name in self?.pendingImages.append(name) }
    }

    func attach(fileURL: URL) {
        if let name = ImageStore.save(fileURL: fileURL) { pendingImages.append(name) }
    }

    func removePending(_ name: String) {
        pendingImages.removeAll { $0 == name }
        ImageStore.delete([name])
    }

    // MARK: - Messages

    func send(_ option: String? = nil) {
        guard let id = selectedID, !streaming.contains(id) else { return }
        var text = (option ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        let images = option == nil ? pendingImages : []
        guard !text.isEmpty || !images.isEmpty else { return }
        if option == nil {
            draft = ""
            pendingImages = []
        }
        guard let bot = selectedBot else { return }
        if let rest = SessionPolicy.command(in: text) {
            newSession(id)
            text = rest
        } else if let last = bot.lastActive ?? bot.sessionMessages.last(where: { $0.job == nil })?.date,
                  SessionPolicy.expired(lastActive: last) {
            newSession(id)
        }
        guard !text.isEmpty || !images.isEmpty else { return }
        mutate(id) {
            $0.messages.append(Message(role: .user, content: text, images: images.isEmpty ? nil : images))
            $0.lastActive = Date()
        }
        respond(in: id)
    }

    func regenerate() {
        guard let id = selectedID, !streaming.contains(id) else { return }
        mutate(id) { bot in
            while bot.messages.last?.role == .assistant { bot.messages.removeLast() }
        }
        respond(in: id)
    }

    func stop(_ id: UUID? = nil) {
        guard let id = id ?? selectedID, let task = tasks[id] else { return }
        task.cancel()
        tasks[id] = nil
        streaming.remove(id)
        activity[id] = nil
        computerActive.remove(id)
        browserActive.remove(id)
        computerRuns.remove(id)
        updateComputerBar()
        mutate(id) { bot in
            if let last = bot.messages.last, last.role == .assistant, last.content.isEmpty {
                bot.messages.removeLast()
            }
        }
        save()
    }

    /// Replies in a bot's chat. A routine run (`isolated`) sees only its own messages.
    private func respond(in id: UUID, isolated: Bool = false) {
        guard let bot = bots.first(where: { $0.id == id }) else { return }
        let usable: (Message) -> Bool = { $0.isError != true && !($0.notice != nil && $0.content.isEmpty) }
        let routineStart = max(0, bot.messages.lastIndex(where: { $0.job != nil }) ?? bot.messages.count - 1)
        let history = isolated ? Array(bot.messages[routineStart...]).filter(usable) : bot.recentMessages.filter(usable)
        let daily = DailyNotes.recent(for: id)
        mutate(id) { $0.messages.append(Message(role: .assistant, content: "")) }
        moveToTop(id)

        var config = AppConfig.current.with(bot.modelChoice)
        let enabled = config.provider == .claude
            ? connectors.filter { $0.isConnected && bot.connections?.contains($0.id) == true }
            : []
        var connectionNote = ""
        if !enabled.isEmpty {
            connectionNote = "You can look things up in the user's \(enabled.map(\.name).joined(separator: ", ")). "
                + "Access is read-only: you cannot send, delete or change anything."
            if enabled.contains(where: \.canDraft) {
                connectionNote += " When asked to write an email, create a draft and tell the user it's waiting in their Drafts folder."
            }
        }
        let allConnectors = connectors
        let connectHint = Connector.chatInstructions(bot: bot, catalog: connectors, isClaude: config.provider == .claude)
        let useComputer = config.provider == .claude && bot.computerUse == true
        let useBrowser = config.provider == .claude && bot.browserUse == true
        config.systemPrompt = [config.systemPrompt, "Your name is \(bot.name).", bot.instructions, connectionNote,
                               useComputer ? ComputerPermissions.botRules : "",
                               useBrowser ? BrowserUse.botRules : "",
                               connectHint, BotJob.chatInstructions(existing: bot.jobList),
                               MemoryPrompt.chatInstructions(bot: id, main: !isolated),
                               daily.isEmpty ? "" : "Your notes from recent sessions (you don't have those chats):\n" + daily,
                               !isolated && bot.hasSummary ?"Older messages in this chat, summarized (the recent ones follow in full):\n"
                                   + (bot.summary ?? "") : "",
                               AppConfig.optionsHint,
                               // Last, so the rest of the prompt stays the same from one message to the next.
                               BotJob.clock()]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        guard config.provider != .xai || config.apiKey != nil else {
            finishLast(in: id, error: Self.missingKeyNotice)
            save()
            return
        }

        streaming.insert(id)
        if useComputer { computerRuns.insert(id) }
        tasks[id] = Task { [weak self] in
            do {
                let replies: AsyncThrowingStream<String, Error>
                switch config.provider {
                case .claude:
                    let onActivity: (String) -> Void = { text in
                        Task { @MainActor in self?.activity[id] = text.isEmpty ? nil : text }
                    }
                    let onComputer: () -> Void = {
                        Task { @MainActor in
                            guard let self, self.streaming.contains(id), !self.computerActive.contains(id) else { return }
                            self.computerActive.insert(id)
                            self.updateComputerBar()
                        }
                    }
                    let onBrowser: () -> Void = {
                        Task { @MainActor in
                            guard let self, self.streaming.contains(id), !self.browserActive.contains(id) else { return }
                            self.browserActive.insert(id)
                            self.updateComputerBar()
                        }
                    }
                    replies = ClaudeCLI(config: config, connectors: enabled, allConnectors: allConnectors,
                                        onActivity: onActivity, computerUse: useComputer,
                                        onComputer: onComputer, browserUse: useBrowser,
                                        onBrowser: onBrowser).stream(history)
                case .gpt: replies = CodexCLI(config: config).stream(history)
                case .xai: replies = XAIClient(config: config).stream(history)
                }
                for try await delta in replies {
                    self?.mutate(id) { bot in
                        guard !bot.messages.isEmpty else { return }
                        bot.messages[bot.messages.count - 1].content += delta
                    }
                }
            } catch {
                if !Task.isCancelled { self?.finishLast(in: id, error: error.localizedDescription) }
            }
            guard let self, !Task.isCancelled else { return }
            self.tasks[id] = nil
            self.streaming.remove(id)
            self.activity[id] = nil
            self.computerActive.remove(id)
            self.browserActive.remove(id)
            self.computerRuns.remove(id)
            self.updateComputerBar()
            if self.applyActionBlocks(in: id) {
                // The bot searched its notes; let it answer with the results.
                self.save()
                self.respond(in: id, isolated: isolated)
                return
            }
            if let bot = self.bots.first(where: { $0.id == id }) { Notifier.shared.replied(bot: bot) }
            if self.selectedID != id { self.mutate(id) { $0.unread = true } }
            self.save()
            self.compactIfNeeded(id)
        }
    }

    private func moveToTop(_ id: UUID) {
        mutate(id) { $0.updatedAt = Date() }
        if let idx = bots.firstIndex(where: { $0.id == id }), idx != 0 {
            bots.insert(bots.remove(at: idx), at: 0)
        }
    }

    /// Folds a long chat's older messages into its summary, after saving anything lasting in them
    /// to memory. Runs in the background; until it's done the bot just sees more messages.
    private func compactIfNeeded(_ id: UUID) {
        guard !compacting.contains(id), let bot = bots.first(where: { $0.id == id }) else { return }
        let recent = bot.recentMessages.filter { $0.isError != true }
        guard let cut = Compaction.cut(recent) else { return }
        let older = Array(recent[..<cut])
        guard let through = older.last?.id else { return }
        var config = AppConfig.current.with(Compaction.model(for: bot.modelChoice))
        config.systemPrompt = Compaction.instructions(bot: id)
        let input = [Message(role: .user, content: Compaction.prompt(summary: bot.hasSummary ? bot.summary : nil,
                                                                     messages: older))]
        compacting.insert(id)
        Task { [weak self] in
            let text = await Self.complete(config, input) ?? ""
            self?.finishCompaction(id, text: text, through: through)
        }
    }

    private func finishCompaction(_ id: UUID, text: String, through: UUID) {
        compacting.remove(id)
        // The chat may have been cleared meanwhile.
        guard let bot = bots.first(where: { $0.id == id }), bot.messages.contains(where: { $0.id == through }) else { return }
        for block in MemorySpec.blocks(in: text) {
            if let spec = block.spec, let note = spec.saved { MemoryStore.add(note, for: id, spec.target) }
        }
        let summary = MemorySpec.strip(text)
        guard !summary.isEmpty else { return }
        mutate(id) {
            $0.summary = summary
            $0.summaryThrough = through
        }
        save()
    }

    private func finishLast(in id: UUID, error: String) {
        mutate(id) { bot in
            guard let i = bot.messages.indices.last else { return }
            if bot.messages[i].content.isEmpty {
                bot.messages[i].content = error
                bot.messages[i].isError = true
            } else {
                bot.messages.append(Message(role: .assistant, content: error, isError: true))
            }
        }
    }

    private func mutate(_ id: UUID, _ body: (inout Bot) -> Void) {
        guard let idx = bots.firstIndex(where: { $0.id == id }) else { return }
        body(&bots[idx])
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let saved = try? JSONDecoder().decode([Bot].self, from: data) else { return }
        bots = saved
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(bots) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
