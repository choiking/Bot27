import SwiftUI

struct BotEditor: View {
    enum Tab: String, CaseIterable { case profile = "Profile", tasks = "Tasks", routines = "Routines", memory = "Files" }

    @EnvironmentObject var store: ChatStore
    @Environment(\.dismiss) private var dismiss
    @State var request: EditorRequest
    @State private var tab: Tab
    /// The notes files as opened, and as edited here.
    private let savedFiles: [MemoryFile: String]
    @State private var files: [MemoryFile: String]
    @State private var file = MemoryFile.user

    init(request: EditorRequest) {
        _request = State(initialValue: request)
        _tab = State(initialValue: request.tab)
        savedFiles = Dictionary(uniqueKeysWithValues: MemoryFile.allCases.map { ($0, MemoryStore.read(request.bot.id, $0)) })
        _files = State(initialValue: savedFiles)
    }

    private var canSave: Bool { !request.bot.name.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                BotAvatar(shape: request.bot.shape, color: request.bot.color, size: 52)
                Text(request.isNew ? "New Bot" : "Edit Bot")
                    .font(.system(size: 20, weight: .semibold))
            }

            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { tab in
                    let count = tab == .tasks ? request.bot.jobList.filter { !$0.isRoutine }.count
                        : tab == .routines ? request.bot.jobList.filter(\.isRoutine).count : 0
                    Text(count > 0 ? "\(tab.rawValue) \(count)" : tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            ScrollView {
                Group {
                    switch tab {
                    case .profile: profile
                    case .tasks: JobsList(bot: $request.bot, routines: false, run: run)
                    case .routines: JobsList(bot: $request.bot, routines: true, run: run)
                    case .memory: memoryTab
                    }
                }
                .padding(.bottom, 4)
            }
            .scrollIndicators(.never)
            .frame(height: 470)

            HStack {
                if !request.isNew {
                    Button("Delete Bot", role: .destructive) {
                        store.delete(request.bot.id)
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(request.isNew ? "Create" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(24)
        .frame(width: 480)
        .background(Theme.bg)
    }

    private func save() {
        request.bot.name = request.bot.name.trimmingCharacters(in: .whitespaces)
        // Only an edit made here is written, so notes the bot saved meanwhile aren't lost.
        for file in MemoryFile.allCases where files[file] != savedFiles[file] {
            MemoryStore.write(files[file] ?? "", for: request.bot.id, file)
        }
        store.commit(request)
        dismiss()
    }

    private var memoryTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("This bot's own files; other bots can't see them. Every chat reads all three, and routines read all but MEMORY.md. The bot adds lines as you talk, and you can edit anything.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Picker("", selection: $file) {
                    ForEach(MemoryFile.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                Text(file.caption)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(2)
            }
            TextEditor(text: Binding(get: { files[file] ?? "" }, set: { files[file] = $0 }))
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .frame(height: 270)
                .whiteField(padding: 6)
                .overlay(alignment: .topLeading) {
                    if (files[file] ?? "").isEmpty {
                        Text("Nothing yet. Tell the bot something about yourself, or write notes here like:\n- Prefers short answers")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.secondary.opacity(0.7))
                            .padding(11)
                            .allowsHitTesting(false)
                    }
                }
            HStack {
                Text("The folder also holds daily notes in memory/.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
                Spacer()
                Button {
                    let folder = MemoryStore.folder(for: request.bot.id)
                    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(folder)
                } label: {
                    Label("Open Memory Folder", systemImage: "folder")
                }
            }
        }
    }

    /// Saves the bot, closes the editor and runs the job in the chat so you can watch it.
    private func run(_ job: BotJob) {
        guard canSave else { return }
        save()
        store.select(request.bot.id)
        store.runJob(bot: request.bot.id, job: job.id)
    }

    private var profile: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                FieldLabel("Look")
                HStack(spacing: 10) {
                    ForEach(0..<Theme.avatarShapes, id: \.self) { shape in
                        Button { request.bot.shape = shape } label: {
                            BotAvatar(shape: shape, color: request.bot.color, size: 34)
                                .padding(5)
                                .background(RoundedRectangle(cornerRadius: 10)
                                    .stroke(request.bot.shape == shape ? Theme.text : .clear, lineWidth: 2))
                        }
                        .buttonStyle(.plain)
                    }
                }
                HStack(spacing: 10) {
                    ForEach(Theme.avatarColors.indices, id: \.self) { i in
                        Button { request.bot.color = i } label: {
                            Circle().fill(Theme.avatarColors[i])
                                .frame(width: 22, height: 22)
                                .padding(3)
                                .overlay(Circle().stroke(request.bot.color == i ? Theme.text : .clear, lineWidth: 2))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                FieldLabel("Name")
                TextField("e.g. 推特 bot", text: $request.bot.name)
                    .textFieldStyle(.plain)
                    .whiteField()
            }

            VStack(alignment: .leading, spacing: 6) {
                FieldLabel("Model")
                Menu {
                    ModelMenuItems(selected: request.bot.modelChoice) { request.bot.modelChoice = $0 }
                } label: {
                    Text(request.bot.modelChoice.name)
                }
                .fixedSize()
            }

            ConnectionsPicker(bot: $request.bot)

            BrowserUsePicker(bot: $request.bot)

            ComputerUsePicker(bot: $request.bot)

            VStack(alignment: .leading, spacing: 6) {
                FieldLabel("What should this bot do?")
                TextEditor(text: $request.bot.instructions)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .frame(height: 100)
                    .whiteField(padding: 6)
            }
        }
    }
}

/// Per-bot switch for browser use through the Claude in Chrome extension.
struct BrowserUsePicker: View {
    @Binding var bot: Bot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldLabel("Browser use")
            if bot.modelChoice.provider != .claude {
                Text("Browser use works with Claude models.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.secondary)
            } else {
                Toggle(isOn: Binding(get: { bot.browserUse == true },
                                     set: { bot.browserUse = $0 ? true : nil })) {
                    Text("Let this bot use Google Chrome to open, read and act on web pages")
                        .font(.system(size: 13))
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .whiteField()
                if bot.browserUse == true && !BrowserUse.isInstalled {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                        Text("Needs Google Chrome with the Claude in Chrome extension.")
                        Link("Get it", destination: URL(string: "https://claude.ai/chrome")!)
                    }
                    .font(.system(size: 11.5))
                }
                Text("Off by default. Uses your signed-in Chrome, in its own tab. It won't run scripts, upload files, enter passwords or payment details, and asks before sending or posting anything.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Per-bot switch for computer use, with the macOS permissions it needs.
struct ComputerUsePicker: View {
    @Binding var bot: Bot
    @State private var granted = ComputerPermissions.granted
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldLabel("Computer use")
            if bot.modelChoice.provider != .claude {
                Text("Computer use works with Claude models.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.secondary)
            } else {
                Toggle(isOn: Binding(get: { bot.computerUse == true },
                                     set: { on in
                                         bot.computerUse = on ? true : nil
                                         if on { ComputerPermissions.request() }
                                     })) {
                    Text("Let this bot see the screen and use the mouse and keyboard")
                        .font(.system(size: 13))
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .whiteField()
                if bot.computerUse == true && !granted {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                        Text("Allow Bot27 under Accessibility and Screen & System Audio Recording in System Settings → Privacy & Security, then reopen Bot27.")
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Open") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                        }
                    }
                    .font(.system(size: 11.5))
                }
                Text("Off by default. A bar at the top of the screen shows when it's in control, with a Stop button. It won't enter passwords or payment details, and asks before sending or deleting anything.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onReceive(timer) { _ in granted = ComputerPermissions.granted }
    }
}

struct FieldLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
    }
}

extension View {
    func whiteField(padding: CGFloat = 10) -> some View {
        self.padding(padding)
            .background(RoundedRectangle(cornerRadius: 10).fill(.white))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
    }
}

// MARK: - Tasks & routines

struct JobsList: View {
    @Binding var bot: Bot
    let routines: Bool
    let run: (BotJob) -> Void
    @State private var editing: JobEditRequest?

    private var jobs: [BotJob] { bot.jobList.filter { $0.isRoutine == routines } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(routines
                 ? "Routines run at a set time while Bot27 is open: once, or on a repeating schedule like a morning inbox summary. If Bot27 was closed, a missed run happens once when it opens."
                 : "Tasks have no time. They're saved jobs you run with ▶ whenever you want; anything with a time is a routine. Each run and its reply appear in this bot's chat.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !jobs.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(jobs.enumerated()), id: \.element.id) { i, job in
                        if i > 0 { Divider().padding(.leading, 12) }
                        JobRow(job: job,
                               toggle: { on in
                                   update(job.id) {
                                       $0.enabled = on
                                       if on { $0.createdAt = Date() }
                                   }
                               },
                               edit: { editing = JobEditRequest(job: job, isNew: false) },
                               run: { run(job) })
                    }
                }
                .background(RoundedRectangle(cornerRadius: 12).fill(.white))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border))
            }

            Button {
                editing = JobEditRequest(job: routines ? .newRoutine() : .newTask(), isNew: true)
            } label: {
                Label(routines ? "New Routine" : "New Task", systemImage: "plus")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.unread)
        }
        .sheet(item: $editing) { request in
            JobEditor(request: request) { saved in
                if request.isNew {
                    bot.jobList.append(saved)
                } else {
                    update(saved.id) { $0 = saved }
                }
            } delete: {
                bot.jobList.removeAll { $0.id == request.job.id }
            }
        }
    }

    private func update(_ id: UUID, _ change: (inout BotJob) -> Void) {
        guard let i = bot.jobList.firstIndex(where: { $0.id == id }) else { return }
        change(&bot.jobList[i])
    }
}

struct JobRow: View {
    let job: BotJob
    let toggle: (Bool) -> Void
    let edit: () -> Void
    let run: () -> Void
    @State private var hover = false

    private var status: String {
        if job.isDone, let ran = job.lastRun { return "Done " + ran.formatted(date: .abbreviated, time: .shortened) }
        var parts: [String] = []
        if job.enabled, let next = job.nextSlot(after: Date()) {
            parts.append("Next " + next.formatted(date: .abbreviated, time: .shortened))
        }
        if let ran = job.lastRun { parts.append("Last " + ran.formatted(date: .abbreviated, time: .shortened)) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: job.isRoutine ? "clock.arrow.circlepath" : job.isDone ? "checkmark.circle.fill" : "checklist")
                .font(.system(size: 14))
                .foregroundStyle(job.isDone ? Color.green : Theme.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.title.isEmpty ? "Untitled" : job.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(job.scheduleText)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.secondary)
                if !status.isEmpty {
                    Text(status).font(.system(size: 11)).foregroundStyle(Theme.secondary.opacity(0.8))
                }
            }
            Spacer(minLength: 6)
            if job.isRoutine && !job.isDone {
                Toggle("", isOn: Binding(get: { job.enabled }, set: toggle))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .help(job.enabled ? "Pause routine" : "Resume routine")
            }
            Button(action: run) {
                Image(systemName: "play.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Theme.userBubble))
            }
            .buttonStyle(.plain)
            .help("Run now")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(hover ? Theme.hover : .clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: edit)
        .onHover { hover = $0 }
        .help("Click to edit")
    }
}

struct JobEditRequest: Identifiable {
    let id = UUID()
    var job: BotJob
    var isNew: Bool
}

struct JobEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var job: BotJob
    private let isNew: Bool
    private let onSave: (BotJob) -> Void
    private let onDelete: () -> Void

    init(request: JobEditRequest, save: @escaping (BotJob) -> Void, delete: @escaping () -> Void) {
        _job = State(initialValue: request.job)
        isNew = request.isNew
        onSave = save
        onDelete = delete
    }


    private var noun: String { job.isRoutine ? "Routine" : "Task" }
    private var canSave: Bool {
        !job.title.trimmingCharacters(in: .whitespaces).isEmpty
            && !job.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isNew ? "New \(noun)" : "Edit \(noun)").font(.system(size: 17, weight: .semibold))

            VStack(alignment: .leading, spacing: 6) {
                FieldLabel("Title")
                TextField(job.isRoutine ? "e.g. Morning inbox summary" : "e.g. Draft follow-up emails", text: $job.title)
                    .textFieldStyle(.plain)
                    .whiteField()
            }

            VStack(alignment: .leading, spacing: 6) {
                FieldLabel("What should the bot do?")
                TextEditor(text: $job.prompt)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .frame(height: 110)
                    .whiteField(padding: 6)
            }

            if job.isRoutine {
                VStack(alignment: .leading, spacing: 8) {
                    FieldLabel("When")
                    Picker("", selection: $job.kind) {
                        ForEach(BotJob.Kind.routineKinds, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    switch job.kind {
                    case .manual:
                        EmptyView()
                    case .once:
                        DatePicker("Run at", selection: $job.date, in: Date()...)
                    case .hourly:
                        Picker("At minute", selection: minute) {
                            ForEach([0, 15, 30, 45], id: \.self) { Text(String(format: ":%02d", $0)).tag($0) }
                        }
                        .fixedSize()
                    case .daily, .weekdays:
                        DatePicker("Time", selection: $job.date, displayedComponents: .hourAndMinute)
                    case .weekly:
                        HStack {
                            Picker("Day", selection: $job.weekday) {
                                ForEach(1...7, id: \.self) { Text(Calendar.current.weekdaySymbols[$0 - 1]).tag($0) }
                            }
                            .fixedSize()
                            DatePicker("at", selection: $job.date, displayedComponents: .hourAndMinute)
                        }
                    }
                    if let next = job.nextSlot(after: Date()) {
                        Text("Next run: " + next.formatted(date: .complete, time: .shortened))
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.secondary)
                    }
                }
            } else {
                Text("No time: runs when you press ▶. To run it at a time, make it a routine instead.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
            }

            HStack {
                if !isNew {
                    Button("Delete", role: .destructive) {
                        onDelete()
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Done") {
                    job.title = job.title.trimmingCharacters(in: .whitespaces)
                    // A rescheduled one-off task should run again; an edited routine starts
                    // from now rather than firing for a time that already passed today.
                    if job.kind == .once, job.date > Date() { job.lastRun = nil }
                    if job.isRoutine { job.createdAt = Date() }
                    onSave(job)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(22)
        .frame(width: 420)
        .onChange(of: job.kind) {
            // Switching to "Once" shouldn't leave a time that has already passed.
            if job.kind == .once, job.date <= Date() { job.date = Date().addingTimeInterval(3600) }
        }
        .background(Theme.bg)
    }

    private var minute: Binding<Int> {
        Binding {
            Calendar.current.component(.minute, from: job.date)
        } set: { m in
            job.date = Calendar.current.date(bySetting: .minute, value: m, of: job.date) ?? job.date
        }
    }
}
