import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: ChatStore

    var body: some View {
        HStack(spacing: 0) {
            SidebarView()
                .frame(width: 280)
            Rectangle().fill(Theme.border).frame(width: 1)
            ChatView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.bg)
        }
        .foregroundStyle(Theme.text)
        .ignoresSafeArea()
        .sheet(item: $store.editor) { request in
            BotEditor(request: request)
        }
    }
}

struct SidebarView: View {
    @EnvironmentObject var store: ChatStore
    @State private var searching = false
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var filtered: [Bot] {
        query.isEmpty ? store.sortedBots : store.sortedBots.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.messages.contains { $0.content.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Spacer()
                CircleButton(symbol: "magnifyingglass", help: "Search") {
                    searching.toggle()
                    if searching { searchFocused = true } else { query = "" }
                }
                CircleButton(symbol: "plus", help: "New Bot") { store.newBot() }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 12)

            if searching {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.secondary)
                    TextField("Search bots and messages", text: $query)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                        .onExitCommand { searching = false; query = "" }
                }
                .font(.system(size: 13))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Capsule().fill(.white))
                .overlay(Capsule().stroke(Theme.border, lineWidth: 1))
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(filtered) { bot in
                        BotRow(bot: bot, selected: bot.id == store.selectedID,
                               typing: store.streaming.contains(bot.id))
                    }
                }
                .padding(.horizontal, 12)
            }
            .scrollIndicators(.never)

            HStack(spacing: 10) {
                HStack(spacing: 10) {
                    Text(String(NSFullUserName().prefix(1)).uppercased())
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.secondary)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Theme.chip))
                        .overlay(Circle().stroke(Theme.border, lineWidth: 1))
                    Text(NSFullUserName())
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 4)
                .padding(.trailing, 12)
                .frame(height: 36)
                .background(Capsule().fill(.white))

                SettingsLink {
                    Image(systemName: "gearshape")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.text)
                        .frame(width: 64, height: 36)
                        .background(Capsule().fill(.white))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Settings")
            }
            .padding(16)
        }
        .background(Theme.sidebar)
    }
}

struct BotRow: View {
    @EnvironmentObject var store: ChatStore
    let bot: Bot
    let selected: Bool
    let typing: Bool
    @State private var hover = false

    var body: some View {
        Button { store.select(bot.id) } label: {
            HStack(spacing: 12) {
                BotAvatar(shape: bot.shape, color: bot.color, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(bot.name)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                        if bot.isPinned {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Theme.secondary)
                                .rotationEffect(.degrees(45))
                                .help("Pinned")
                        }
                    }
                    Text(typing ? "typing…" : bot.preview)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if bot.unread {
                    Circle().fill(Theme.unread).frame(width: 8, height: 8)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 58)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? Theme.selected : hover ? Theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .contextMenu {
            Button(bot.isPinned ? "Unpin" : "Pin to Top") { store.togglePin(bot.id) }
            Button("Edit Bot…") { store.edit(bot.id) }
            Button("New Session") { store.newSession(bot.id) }
                .disabled(store.streaming.contains(bot.id))
            Button("Dream Now") { store.dream(bot.id) }
            Button("Clear Conversation") { store.clear(bot.id) }
            Divider()
            Button("Delete Bot", role: .destructive) { store.delete(bot.id) }
        }
    }
}

/// Per-bot switches for claude.ai connectors. Access is read-only, plus drafts.
struct ConnectionsPicker: View {
    @EnvironmentObject var store: ChatStore
    @Binding var bot: Bot

    private func binding(_ id: String) -> Binding<Bool> {
        Binding {
            bot.connections?.contains(id) ?? false
        } set: { on in
            var ids = bot.connections ?? []
            ids.removeAll { $0 == id }
            if on { ids.append(id) }
            bot.connections = ids.isEmpty ? nil : ids
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Connections").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
                Spacer()
                Button { store.refreshConnectors() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.secondary)
                .help("Refresh connectors")
            }
            if bot.modelChoice.provider != .claude {
                Text("Connections work with Claude models.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.secondary)
            } else if store.connectors.isEmpty {
                Text("No connectors yet. Add Gmail, Notion and more at claude.ai → Settings → Connectors.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(store.connectors) { connector in
                        Toggle(isOn: binding(connector.id)) {
                            HStack {
                                Text(connector.name).font(.system(size: 13))
                                Spacer()
                                if !connector.isConnected {
                                    Text("Sign in at claude.ai").font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
                                } else if connector.canDraft {
                                    Text("Read · drafts").font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
                                } else {
                                    Text("Read only").font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
                                }
                            }
                        }
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .disabled(!connector.isConnected)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 10).fill(.white))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
                Text("Bots can search and read. Nothing is sent, changed or deleted; emails become drafts.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.secondary)
            }
        }
    }
}
