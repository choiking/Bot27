import SwiftUI

struct SettingsView: View {
    @AppStorage("provider") private var provider = AppConfig.Provider.claude.rawValue
    @AppStorage("claudeModel") private var claudeModel = AppConfig.defaultClaudeModel
    @AppStorage("claudePath") private var claudePath = ""
    @AppStorage("gptModel") private var gptModel = AppConfig.defaultGPTModel
    @AppStorage("codexPath") private var codexPath = ""
    @AppStorage("model") private var model = AppConfig.defaultModel
    @AppStorage("baseURL") private var baseURL = AppConfig.defaultBaseURL
    @AppStorage("systemPrompt") private var systemPrompt = AppConfig.defaultSystemPrompt
    @State private var apiKey = Keychain.read() ?? ""
    @State private var saved = false

    var body: some View {
        Form {
            Section {
                Picker("New bots use", selection: $provider) {
                    ForEach(AppConfig.Provider.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                }
            } footer: {
                Text("Each bot keeps its own model; change it in Edit Bot.")
                    .foregroundStyle(.secondary)
            }

            if provider == AppConfig.Provider.claude.rawValue {
                Section {
                    Picker("Default model", selection: $claudeModel) {
                        ForEach(AppConfig.claudeModels, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    TextField("CLI path", text: $claudePath, prompt: Text(ClaudeCLI.locate(custom: "") ?? "Not found"))
                    if let found = ClaudeCLI.locate(custom: claudePath) {
                        Label(found, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.system(size: 12))
                    } else {
                        Label("Claude Code CLI not found", systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                            .font(.system(size: 12))
                    }
                } header: {
                    Text("Claude")
                } footer: {
                    Text("Replies come from the Claude Code CLI on this Mac, using the account you're signed in with. Run `claude` in Terminal once to sign in.")
                        .foregroundStyle(.secondary)
                }
            } else if provider == AppConfig.Provider.gpt.rawValue {
                Section {
                    Picker("Default model", selection: $gptModel) {
                        ForEach(AppConfig.gptModels, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    TextField("CLI path", text: $codexPath, prompt: Text(CodexCLI.locate(custom: "") ?? "Not found"))
                    if let found = CodexCLI.locate(custom: codexPath) {
                        Label(found, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.system(size: 12))
                    } else {
                        Label("Codex CLI not found", systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                            .font(.system(size: 12))
                    }
                } header: {
                    Text("GPT")
                } footer: {
                    Text("Replies come from the Codex CLI on this Mac, using your ChatGPT login. Run `codex login` in Terminal once to sign in. GPT replies arrive whole rather than word by word.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    SecureField("API key", text: $apiKey, prompt: Text("xai-…"))
                        .onChange(of: apiKey) { saved = false }
                    HStack {
                        Button("Save Key") {
                            Keychain.save(apiKey)
                            saved = true
                        }
                        if saved {
                            Label("Saved to Keychain", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                        Spacer()
                        Link("Get a key", destination: URL(string: "https://console.x.ai")!)
                    }
                    TextField("Model ID", text: $model)
                    TextField("Base URL", text: $baseURL)
                } header: {
                    Text("xAI API")
                } footer: {
                    Text("Stored in your macOS Keychain. The XAI_API_KEY environment variable is used if no key is saved.")
                        .foregroundStyle(.secondary)
                }
            }

            NotificationSettings()

            SessionSettings()

            ComputerUseSettings()

            Section("System Prompt") {
                TextEditor(text: $systemPrompt)
                    .font(.system(size: 13))
                    .frame(height: 90)
                Button("Reset to Default") { systemPrompt = AppConfig.defaultSystemPrompt }
            }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 620)
    }
}

/// The macOS permissions computer use needs, with their live status.
struct ComputerUseSettings: View {
    @State private var screen = ComputerPermissions.screenRecording
    @State private var accessibility = ComputerPermissions.accessibility
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Section {
            PermissionRow(icon: "display", title: "Screen Recording",
                          detail: "Lets Bot27 see the screen for bots with computer use.",
                          granted: screen,
                          pane: "Privacy_ScreenCapture")
            PermissionRow(icon: "cursorarrow.rays", title: "Accessibility",
                          detail: "Lets Bot27 click and type for bots with computer use.",
                          granted: accessibility,
                          pane: "Privacy_Accessibility")
            HStack {
                if !screen {
                    Text("macOS applies Screen Recording after Bot27 reopens.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !screen {
                    Button("Reopen Bot27", action: relaunch)
                }
                Button {
                    ComputerPermissions.request()
                    refresh()
                } label: {
                    Label("Check again", systemImage: "arrow.clockwise")
                }
            }
        } header: {
            Text("Computer Use")
        } footer: {
            Text("Permissions are managed by macOS. Computer use stays off until you turn it on for a bot.")
                .foregroundStyle(.secondary)
        }
        .onReceive(timer) { _ in refresh() }
    }

    private func refresh() {
        screen = ComputerPermissions.screenRecording
        accessibility = ComputerPermissions.accessibility
    }

    private func relaunch() {
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-n", Bundle.main.bundlePath]
        try? open.run()
        NSApp.terminate(nil)
    }
}

private struct PermissionRow: View {
    let icon: String
    let title: String
    let detail: String
    let granted: Bool
    let pane: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Spacer()
            Label(granted ? "Granted" : "Not granted",
                  systemImage: granted ? "checkmark.circle" : "exclamationmark.circle")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(granted ? Color.green : Color.orange)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill((granted ? Color.green : Color.orange).opacity(0.12)))
            Button("Manage") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
            }
        }
        .padding(.vertical, 2)
    }
}

struct SessionSettings: View {
    @AppStorage("sessionReset") private var mode = SessionPolicy.Mode.off.rawValue
    @AppStorage("sessionIdleMinutes") private var idleMinutes = SessionPolicy.defaultIdleMinutes
    @AppStorage("sessionResetHour") private var hour = SessionPolicy.defaultHour
    @AppStorage("dreaming") private var dreaming = false

    var body: some View {
        Section {
            Picker("Start a new session", selection: $mode) {
                ForEach(SessionPolicy.Mode.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
            }
            if mode == SessionPolicy.Mode.idle.rawValue {
                Stepper("After \(idleMinutes) minutes idle", value: $idleMinutes, in: 15...1440, step: 15)
            } else if mode == SessionPolicy.Mode.daily.rawValue {
                Picker("At", selection: $hour) {
                    ForEach(0..<24, id: \.self) { h in
                        Text(Calendar.current.date(bySettingHour: h, minute: 0, second: 0, of: Date())!
                            .formatted(date: .omitted, time: .shortened)).tag(h)
                    }
                }
            }
            Toggle("Dream every night at 3:00", isOn: $dreaming)
        } header: {
            Text("Sessions")
        } footer: {
            Text("A new session starts only when you send /new or /reset, or when this rule says the last one expired, checked on your next message. Changing topic doesn't start one, and long chats are summarized instead. A reset saves the session's last 15 messages to the bot's memory/ folder; every session reads today's and yesterday's notes, and bots can search older ones. Routines run in sessions of their own, without MEMORY.md. Dreaming moves lasting daily notes into MEMORY.md.")
                .foregroundStyle(.secondary)
        }
    }
}

struct NotificationSettings: View {
    @AppStorage("notifyEnabled") private var enabled = true
    @AppStorage("notifyPreview") private var preview = true
    @ObservedObject private var notifier = Notifier.shared

    var body: some View {
        Section {
            Toggle("Notify me about new replies", isOn: $enabled)
                .onChange(of: enabled) { if enabled { notifier.requestPermission() } }
            Toggle("Show message preview", isOn: $preview)
                .disabled(!enabled)
            HStack {
                switch notifier.status {
                case .authorized, .provisional:
                    Label("Allowed by macOS", systemImage: "checkmark.circle").foregroundStyle(.green)
                case .denied:
                    Label("Turned off for Bot27 in System Settings", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                default:
                    Label("Not set up yet", systemImage: "questionmark.circle").foregroundStyle(.secondary)
                }
                Spacer()
                if notifier.status == .denied {
                    Button("Open Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=com.bot27.app")!)
                    }
                } else if notifier.status == .notDetermined {
                    Button("Allow") { notifier.requestPermission() }
                } else {
                    Button("Send Test") { notifier.sendTest() }
                }
            }
            .font(.system(size: 12))
        } header: {
            Text("Notifications")
        } footer: {
            Text("You're notified when a bot replies and you aren't looking at it. The Dock icon shows how many bots have unread replies.")
                .foregroundStyle(.secondary)
        }
        .onAppear { notifier.refreshStatus() }
    }
}
