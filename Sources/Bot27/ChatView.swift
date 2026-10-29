import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ChatView: View {
    @EnvironmentObject var store: ChatStore
    @State private var dropTargeted = false

    var body: some View {
        if let bot = store.selectedBot {
            VStack(spacing: 0) {
                ZStack(alignment: .top) {
                    Transcript(bot: bot)
                    Button { store.edit(bot.id) } label: {
                        HStack(spacing: 8) {
                            BotAvatar(shape: bot.shape, color: bot.color, size: 22)
                            Text(bot.name).font(.system(size: 13.5, weight: .semibold))
                        }
                        .padding(.leading, 6)
                        .padding(.trailing, 14)
                        .frame(height: 34)
                        .background(Capsule().fill(.white))
                        .shadow(color: .black.opacity(0.08), radius: 4, y: 1)
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Edit Bot")
                    .padding(.top, 12)
                }
                Composer()
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                    .frame(maxWidth: 940)
            }
            .onDrop(of: [.fileURL, .image], isTargeted: $dropTargeted) { providers in
                store.attach(providers)
                return true
            }
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Theme.unread, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.unread.opacity(0.06)))
                        .overlay(Label("Drop images to attach", systemImage: "photo.on.rectangle.angled")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.unread))
                        .padding(12)
                        .allowsHitTesting(false)
                }
            }
        } else {
            VStack(spacing: 14) {
                BotAvatar(shape: 0, color: 0, size: 56)
                Text("No bots yet").font(.system(size: 17, weight: .semibold))
                Button("New Bot") { store.newBot() }
                    .buttonStyle(BlackCapsuleStyle())
            }
        }
    }
}

struct Transcript: View {
    @EnvironmentObject var store: ChatStore
    let bot: Bot

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if bot.messages.isEmpty {
                        VStack(spacing: 10) {
                            BotAvatar(shape: bot.shape, color: bot.color, size: 64)
                            Text(bot.name).font(.system(size: 20, weight: .semibold))
                            if !bot.instructions.isEmpty {
                                Text(bot.instructions)
                                    .font(.system(size: 13.5))
                                    .foregroundStyle(Theme.secondary)
                                    .multilineTextAlignment(.center)
                                    .frame(maxWidth: 360)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 140)
                    }
                    ForEach(Array(bot.messages.enumerated()), id: \.element.id) { i, message in
                        if i == 0 || message.date.timeIntervalSince(bot.messages[i - 1].date) > 3600 {
                            Text(Self.stamp(message.date))
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                        }
                        MessageRow(message: message, isLast: i == bot.messages.count - 1)
                        if bot.hasSummary && message.id == bot.summaryThrough {
                            Label("Earlier messages are summarized for \(bot.name)", systemImage: "text.append")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .help(bot.summary ?? "")
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 60)
                .padding(.bottom, 16)
                .frame(maxWidth: 940)
                .frame(maxWidth: .infinity)
                Color.clear.frame(height: 1).id("bottom")
            }
            .onChange(of: bot.messages.last?.content, initial: true) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: bot.id) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    static func stamp(_ date: Date) -> String {
        let cal = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if cal.isDateInToday(date) { return "Today \(time)" }
        if cal.isDateInYesterday(date) { return "Yesterday \(time)" }
        return date.formatted(.dateTime.month(.abbreviated).day()) + " " + time
    }
}

// MARK: - Messages

struct MessageRow: View {
    @EnvironmentObject var store: ChatStore
    let message: Message
    let isLast: Bool
    @State private var hover = false
    @State private var copied = false

    private let maxBubble: CGFloat = 560

    var body: some View {
        switch message.role {
        case .user where message.job != nil || message.notice != nil:
            Label(message.job ?? message.notice ?? "",
                  systemImage: message.notice == "Computer use on" ? "cursorarrow.rays"
                      : message.notice == "Browser use on" ? "globe"
                      : message.notice == "New session" ? "arrow.counterclockwise"
                      : message.notice == RecallSpec.notice ? "magnifyingglass"
                      : message.notice != nil ? "link"
                      : message.jobIsRoutine == true ? "clock.arrow.circlepath" : "checklist")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(Theme.chip))
                .frame(maxWidth: .infinity)
                .help(message.content)
        case .user:
            HStack {
                Spacer(minLength: 120)
                VStack(alignment: .trailing, spacing: 6) {
                    if let images = message.images, !images.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(images, id: \.self) { SentImage(name: $0) }
                        }
                    }
                    if !message.content.isEmpty {
                        let long = Fold.isLong(message.content)
                        let open = isOpen(defaultOpen: false)
                        // An open long message also gets the toggle on top, so folding it back doesn't
                        // mean scrolling to the end.
                        if long && open { FoldToggle(open: open) { toggleFold() } }
                        Text(message.content)
                            .font(.system(size: 14.5))
                            .lineSpacing(3)
                            .foregroundStyle(.white)
                            .textSelection(.enabled)
                            .folded(long && !open, fade: Theme.userBubble)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.userBubble))
                        if long { FoldToggle(open: open) { toggleFold() } }
                    }
                }
            }
        case .assistant:
            let streaming = store.isStreaming && isLast
            let parts = streaming ? (body: message.content, question: nil, options: [])
                : Self.splitOptions(message.content)
            VStack(alignment: .leading, spacing: 8) {
                if message.isError == true {
                    NoticeCard(message: message.content)
                } else if message.content.isEmpty && streaming {
                    TypingIndicator()
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.bubble))
                    if let activity = store.selectedID.flatMap({ store.activity[$0] }) {
                        ActivityLine(text: activity)
                    }
                } else {
                    if !parts.body.isEmpty {
                        let long = !streaming && Fold.isLong(parts.body)
                        let open = isOpen(defaultOpen: true)
                        if long && open { FoldToggle(open: open) { toggleFold() } }
                        MarkdownView(text: parts.body)
                            .folded(long && !open, fade: Theme.bubble)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.bubble))
                            .frame(maxWidth: maxBubble, alignment: .leading)
                        if long { FoldToggle(open: open) { toggleFold() } }
                    }
                    if !parts.options.isEmpty {
                        OptionsCard(question: parts.question, options: parts.options,
                                    enabled: isLast && !store.isStreaming)
                            .frame(maxWidth: maxBubble, alignment: .leading)
                    }
                    ForEach(Array((message.connectNotes ?? []).enumerated()), id: \.offset) { _, note in
                        ConnectNoteCard(note: note, messageID: message.id)
                            .frame(maxWidth: maxBubble, alignment: .leading)
                    }
                    ForEach(Array((message.jobNotes ?? []).enumerated()), id: \.offset) { _, note in
                        JobNoteCard(note: note, messageID: message.id)
                            .frame(maxWidth: maxBubble, alignment: .leading)
                    }
                    ForEach(Array((message.memoryNotes ?? []).enumerated()), id: \.offset) { i, note in
                        MemoryNoteCard(note: note, index: i, messageID: message.id)
                            .frame(maxWidth: maxBubble, alignment: .leading)
                    }
                    if streaming, let activity = store.selectedID.flatMap({ store.activity[$0] }) {
                        ActivityLine(text: activity)
                    }
                    if !streaming {
                        HStack(spacing: 0) {
                            IconButton(symbol: copied ? "checkmark" : "doc.on.doc", help: "Copy") {
                                copyToPasteboard(message.content)
                                copied = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                            }
                            if isLast {
                                IconButton(symbol: "arrow.clockwise", help: "Regenerate") { store.regenerate() }
                            }
                        }
                        .opacity(hover ? 1 : 0)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onHover { hover = $0 }
        }
    }

    private func isOpen(defaultOpen: Bool) -> Bool {
        store.toggledFolds.contains(message.id) ? !defaultOpen : defaultOpen
    }

    private func toggleFold() {
        if store.toggledFolds.contains(message.id) {
            store.toggledFolds.remove(message.id)
        } else {
            store.toggledFolds.insert(message.id)
        }
    }

    /// Pulls a trailing "question + A./B./C. options" block out of a reply.
    static func splitOptions(_ text: String) -> (body: String, question: String?, options: [(letter: String, text: String)]) {
        func blank(_ s: String?) -> Bool { s?.trimmingCharacters(in: .whitespaces).isEmpty == true }
        var lines = text.components(separatedBy: "\n")
        while blank(lines.last) { lines.removeLast() }
        var options: [(letter: String, text: String)] = []
        while let last = lines.last?.trimmingCharacters(in: .whitespaces),
              let m = last.firstMatch(of: #/^\**([A-F])[.)、:：]\**\s*(.+)$/#) {
            options.insert((String(m.1), String(m.2)), at: 0)
            lines.removeLast()
        }
        guard options.count >= 2, options.first?.letter == "A" else { return (text, nil, []) }
        while blank(lines.last) { lines.removeLast() }
        var question: String?
        if let last = lines.last?.trimmingCharacters(in: .whitespaces),
           last.hasSuffix("?") || last.hasSuffix("？") || last.hasSuffix("?**") || last.hasSuffix("？**") {
            question = last.replacingOccurrences(of: "**", with: "")
            lines.removeLast()
        }
        return (lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), question, options)
    }
}

struct OptionsCard: View {
    let question: String?
    let options: [(letter: String, text: String)]
    let enabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let question {
                Text(MarkdownView.inline(question))
                    .font(.system(size: 14.5, weight: .semibold))
                    .padding(.horizontal, 2)
                    .padding(.bottom, 8)
            }
            ForEach(options, id: \.letter) { option in
                OptionRow(letter: option.letter, text: option.text, enabled: enabled)
            }
        }
        .padding(14)
        .cardStyle()
    }
}

struct OptionRow: View {
    @EnvironmentObject var store: ChatStore
    let letter: String
    let text: String
    let enabled: Bool
    @State private var hover = false

    var body: some View {
        Button { store.send(text) } label: {
            HStack(spacing: 12) {
                Text(letter)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 22, height: 22)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.chip))
                Text(MarkdownView.inline(text))
                    .font(.system(size: 14))
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(hover && enabled ? Theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hover = $0 }
    }
}

struct NoticeCard: View {
    @EnvironmentObject var store: ChatStore
    let message: String

    var body: some View {
        if message == ChatStore.missingKeyNotice {
            VStack(alignment: .leading, spacing: 6) {
                Text("Bot27 needs an xAI API key").font(.system(size: 14.5, weight: .medium))
                Text("Add your key in Settings to send messages. It's stored in your macOS Keychain.")
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.secondary)
                HStack {
                    Spacer()
                    SettingsLink { Text("Open Settings") }
                        .buttonStyle(BlackCapsuleStyle())
                }
            }
            .padding(14)
            .cardStyle(radius: 16)
        } else {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Couldn't get a reply").font(.system(size: 14.5, weight: .medium))
                    Text(message).font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
                        .textSelection(.enabled)
                        .lineLimit(4)
                }
                Spacer(minLength: 8)
                Button("Try again") { store.regenerate() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5, weight: .medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Theme.chip))
            }
            .padding(12)
            .cardStyle(radius: 14)
        }
    }
}

/// Folding for long messages: clip to a fixed height and fade into the bubble.
enum Fold {
    static let height: CGFloat = 240

    static func isLong(_ text: String) -> Bool {
        text.count > 1000 || text.reduce(0) { $1 == "\n" ? $0 + 1 : $0 } >= 14
    }
}

extension View {
    @ViewBuilder
    func folded(_ folded: Bool, fade: Color) -> some View {
        if folded {
            frame(maxHeight: Fold.height, alignment: .top)
                .clipped()
                .overlay(alignment: .bottom) {
                    LinearGradient(colors: [fade.opacity(0), fade], startPoint: .top, endPoint: .bottom)
                        .frame(height: 60)
                        .allowsHitTesting(false)
                }
        } else {
            self
        }
    }
}

struct FoldToggle: View {
    let open: Bool
    let toggle: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: toggle) {
            Label(open ? "Show less" : "Show more", systemImage: open ? "chevron.up" : "chevron.down")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hover ? Theme.text : Theme.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(hover ? Theme.hover : .clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// A connection a bot asked for. Connecting gives it access to your data, so it waits for your click.
struct ConnectNoteCard: View {
    @EnvironmentObject var store: ChatStore
    let note: ConnectNote
    let messageID: UUID

    /// A service that wasn't set up may have been added at claude.ai since.
    private var connector: Connector? {
        store.connectors.first { $0.id == note.connectorID || $0.find(note.name) }
    }

    private var state: ConnectNote.State {
        note.state == .unavailable && connector?.isConnected == true ? .requested : note.state
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: state == .connected ? "checkmark.circle.fill"
                  : state == .unavailable ? "exclamationmark.circle" : isComputer ? "cursorarrow.rays"
                  : isBrowser ? "globe" : "link")
                .font(.system(size: 16))
                .foregroundStyle(state == .connected ? Color.green
                                 : state == .requested ? Theme.unread : Theme.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .semibold))
                if let detail { Text(detail).font(.system(size: 12.5)).foregroundStyle(Theme.secondary) }
            }
            Spacer(minLength: 8)
            if let botID = store.selectedID {
                switch state {
                case .requested:
                    Button("Not now") { store.declineConnect(bot: botID, message: messageID, connector: note.connectorID) }
                        .buttonStyle(.plain)
                        .font(.system(size: 12.5, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Theme.chip))
                    Button(isComputer || isBrowser ? "Allow" : "Connect") {
                        if let id = isComputer || isBrowser ? note.connectorID : connector?.id {
                            store.connect(bot: botID, message: messageID, connector: id)
                        }
                    }
                    .buttonStyle(BlackCapsuleStyle())
                    .disabled(store.isStreaming)
                case .unavailable:
                    Button("Refresh") { store.refreshConnectors() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12.5, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Theme.chip))
                    Link("Open claude.ai", destination: URL(string: "https://claude.ai/settings/connectors")!)
                        .buttonStyle(BlackCapsuleStyle())
                default:
                    EmptyView()
                }
            }
        }
        .padding(14)
        .cardStyle(radius: 16)
    }

    private var isComputer: Bool { note.connectorID == Connector.computerID }
    private var isBrowser: Bool { note.connectorID == Connector.browserID }

    private var title: String {
        if isBrowser {
            switch state {
            case .requested: return "Allow browser use?"
            case .connected: return "Browser use on"
            case .declined: return "Browser use not allowed"
            default: return "Browser use off"
            }
        }
        if isComputer {
            switch state {
            case .requested: return "Allow computer use?"
            case .connected: return "Computer use on"
            case .declined: return "Computer use not allowed"
            default: return "Computer use off"
            }
        }
        switch state {
        case .requested: return "Connect \(note.name)?"
        case .connected: return "\(note.name) connected"
        case .declined: return "\(note.name) not connected"
        case .unavailable: return "\(note.name) isn't set up yet"
        case .disconnected: return "\(note.name) disconnected"
        }
    }

    private var detail: String? {
        switch state {
        case .requested where isBrowser:
            var text = "Lets this bot use your Google Chrome, with your signed-in accounts, to open, read and act on pages. A bar at the top of the screen lets you stop it anytime."
            if !BrowserUse.isInstalled { text += " Needs the Claude in Chrome extension." }
            if store.selectedBot?.modelChoice.provider != .claude {
                text += " Also switches it to \(ModelChoice(provider: .claude, id: AppConfig.current.claudeModel).name)."
            }
            return text
        case .requested where isComputer:
            var text = "Lets this bot see your screen and use your mouse and keyboard. A bar at the top of the screen lets you stop it anytime."
            if !ComputerPermissions.granted { text += " macOS will ask you to allow Bot27." }
            if store.selectedBot?.modelChoice.provider != .claude {
                text += " Also switches it to \(ModelChoice(provider: .claude, id: AppConfig.current.claudeModel).name)."
            }
            return text
        case .requested:
            var text = "Lets this bot \(connector?.accessText ?? "read your \(note.name)"). Nothing is sent, changed or deleted."
            if store.selectedBot?.modelChoice.provider != .claude {
                text += " Also switches it to \(ModelChoice(provider: .claude, id: AppConfig.current.claudeModel).name)."
            }
            return text
        case .unavailable:
            return "Add it to your Claude account at claude.ai → Settings → Connectors, then press Refresh."
        default:
            return nil
        }
    }
}

/// A task or routine a bot set up (or removed) from chat, with Undo.
struct JobNoteCard: View {
    @EnvironmentObject var store: ChatStore
    let note: JobNote
    let messageID: UUID

    private var heading: String {
        let noun = note.isRoutine ? "Routine" : "Task"
        switch note.change {
        case .created: return "\(noun) added"
        case .deleted: return "\(noun) removed"
        case .undone: return "\(noun) undone"
        case .failed: return "Couldn't set up"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: note.change == .failed ? "exclamationmark.triangle.fill"
                  : note.isRoutine ? "clock.arrow.circlepath" : "checklist")
                .font(.system(size: 16))
                .foregroundStyle(note.change == .failed ? Theme.warning
                                 : note.change == .created ? Theme.unread : Theme.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(heading).font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
                Text(note.title)
                    .font(.system(size: 14, weight: .semibold))
                    .strikethrough(note.change == .undone || note.change == .deleted)
                Text(note.detail).font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
            }
            Spacer(minLength: 8)
            if note.change == .created, let jobID = note.jobID, let botID = store.selectedID,
               store.selectedBot?.jobList.contains(where: { $0.id == jobID }) == true {
                Button("Undo") { store.undoJob(bot: botID, message: messageID, job: jobID) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5, weight: .medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Theme.chip))
                Button("Edit") { store.edit(botID, tab: note.isRoutine ? .routines : .tasks) }
                    .buttonStyle(BlackCapsuleStyle())
            }
        }
        .padding(14)
        .cardStyle(radius: 16)
    }
}

/// A note a bot saved to or dropped from its memory, with Undo.
struct MemoryNoteCard: View {
    @EnvironmentObject var store: ChatStore
    let note: MemoryNote
    let index: Int
    let messageID: UUID

    private var heading: String {
        switch note.change {
        case .saved: return "Remembered"
        case .forgotten: return "Forgot"
        case .undone: return note.undid == .forgotten ? "Kept" : "Not remembered"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "brain")
                .font(.system(size: 13))
                .foregroundStyle(note.change == .saved ? Theme.unread : Theme.secondary)
            Text("\(heading) · \((note.file ?? .memory).rawValue)")
                .font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.secondary)
            Text(note.text)
                .font(.system(size: 13))
                .strikethrough(note.change == .forgotten || note.undid == .saved)
                .lineLimit(2)
            Spacer(minLength: 8)
            if note.change != .undone, let botID = store.selectedID {
                Button("Undo") { store.undoMemory(bot: botID, message: messageID, note: index) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Theme.chip))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .cardStyle(radius: 14)
    }
}

/// "Gmail · search threads" with a spinner, while a bot uses a connector.
struct ActivityLine: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.mini)
            Text(text).font(.system(size: 12)).foregroundStyle(Theme.secondary)
        }
        .padding(.leading, 4)
    }
}

struct BlackCapsuleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13.5, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(Theme.userBubble.opacity(configuration.isPressed ? 0.8 : 1)))
            .contentShape(Capsule())
    }
}

struct TypingIndicator: View {
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Theme.secondary)
                        .frame(width: 7, height: 7)
                        .opacity(0.3 + 0.7 * max(0, sin(t * 5 - Double(i) * 0.7)))
                }
            }
        }
    }
}

// MARK: - Composer

struct Composer: View {
    @EnvironmentObject var store: ChatStore
    @FocusState private var focused: Bool

    private var hasText: Bool { !store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var canSend: Bool { hasText || !store.pendingImages.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !store.pendingImages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(store.pendingImages, id: \.self) { name in
                            PendingThumbnail(name: name) { store.removePending(name) }
                        }
                    }
                    .padding(.top, 4)
                    .padding(.horizontal, 2)
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                Button(action: attach) {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.text.opacity(0.7))
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Theme.chip))
                }
                .buttonStyle(.plain)
                .help("Attach images or a text file")

                TextField("Type your answer, or talk about something else", text: $store.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14.5))
                    .lineLimit(1...8)
                    .focused($focused)
                    .padding(.vertical, 6)
                    .onKeyPress(.return, phases: .down) { press in
                        // Let input methods (e.g. Pinyin) confirm their candidate first.
                        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.hasMarkedText() {
                            return .ignored
                        }
                        if press.modifiers.contains(.shift) {
                            store.draft += "\n"
                        } else {
                            store.send()
                        }
                        return .handled
                    }

                Button(action: dictate) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.text.opacity(0.6))
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Theme.chip))
                }
                .buttonStyle(.plain)
                .help("Dictate")

                Button {
                    if store.isStreaming { store.stop() } else if canSend { store.send() } else { dictate() }
                } label: {
                    Image(systemName: store.isStreaming ? "stop.fill" : canSend ? "arrow.up" : "waveform")
                        .font(.system(size: store.isStreaming ? 11 : 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Theme.userBubble))
                }
                .buttonStyle(.plain)
                .help(store.isStreaming ? "Stop" : canSend ? "Send" : "Dictate")
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 8)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.white))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .stroke(focused ? Color.black.opacity(0.14) : Theme.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.04), radius: 6, y: 2)
        .onAppear { focused = true }
        .onChange(of: store.selectedID) { focused = true }
    }

    private func dictate() {
        focused = true
        DispatchQueue.main.async {
            NSApp.sendAction(Selector(("startDictation:")), to: nil, from: nil)
        }
    }

    private func attach() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .plainText, .sourceCode, .json, .commaSeparatedText, .xml, .yaml]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if ImageStore.isImage(url) {
                store.attach(fileURL: url)
            } else if let text = try? String(contentsOf: url, encoding: .utf8) {
                let snippet = String(text.prefix(60_000))
                let prefix = store.draft.isEmpty ? "" : store.draft + "\n\n"
                store.draft = prefix + "```\(url.lastPathComponent)\n\(snippet)\n```\n"
            }
        }
        focused = true
    }
}

struct ModelMenuItems: View {
    let selected: ModelChoice
    let pick: (ModelChoice) -> Void

    var body: some View {
        ForEach(AppConfig.Provider.allCases, id: \.self) { provider in
            Section(provider.label) {
                ForEach(AppConfig.models(for: provider), id: \.id) { model in
                    let choice = ModelChoice(provider: provider, id: model.id)
                    Button { pick(choice) } label: {
                        if choice == selected { Label(model.name, systemImage: "checkmark") } else { Text(model.name) }
                    }
                }
            }
        }
    }
}

struct PendingThumbnail: View {
    let name: String
    let remove: () -> Void
    @State private var hover = false

    var body: some View {
        Group {
            if let image = ImageStore.image(name) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Theme.chip
            }
        }
        .frame(width: 60, height: 60)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.border, lineWidth: 1))
        .overlay(alignment: .topTrailing) {
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Theme.userBubble))
            }
            .buttonStyle(.plain)
            .offset(x: 5, y: -5)
            .opacity(hover ? 1 : 0.85)
            .help("Remove")
        }
        .onHover { hover = $0 }
    }
}

/// An image in a sent message; click to open it in Preview.
struct SentImage: View {
    let name: String

    var body: some View {
        if let image = ImageStore.image(name) {
            let ratio = image.size.width / max(image.size.height, 1)
            Button { NSWorkspace.shared.open(ImageStore.url(name)) } label: {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(ratio, contentMode: .fit)
                    .frame(maxWidth: 260, maxHeight: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.border, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("Open in Preview")
        }
    }
}

func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}
