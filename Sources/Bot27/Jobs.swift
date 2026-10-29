import Foundation

/// Something a bot does for you: a task (no time; runs when you press ▶) or a routine
/// (anything with a time: once, or repeating). Each run posts the prompt and the reply into its chat.
struct BotJob: Identifiable, Codable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case manual, once, hourly, daily, weekdays, weekly

        var label: String {
            switch self {
            case .manual: return "On demand"
            case .once: return "Once"
            case .hourly: return "Hourly"
            case .daily: return "Daily"
            case .weekdays: return "Weekdays"
            case .weekly: return "Weekly"
            }
        }

        /// Anything with a time is a routine (定时任务), even if it runs only once.
        var isRoutine: Bool { self != .manual }
        static var routineKinds: [Kind] { [.daily, .weekdays, .weekly, .hourly, .once] }
    }

    var id = UUID()
    var title: String
    var prompt: String
    var kind: Kind
    /// `once`: when to run. Repeating kinds use its time of day (hourly: just the minute).
    var date: Date
    /// `weekly`: Calendar weekday, 1 = Sunday … 7 = Saturday.
    var weekday: Int = 2
    var enabled = true
    var lastRun: Date? = nil
    /// Scheduled since: slots before this never run (set on create, edit and resume).
    var createdAt = Date()

    var isRoutine: Bool { kind.isRoutine }
    var isDone: Bool { kind == .once && lastRun != nil }

    static func newTask() -> BotJob {
        BotJob(title: "", prompt: "", kind: .manual, date: Date())
    }

    static func newRoutine() -> BotJob {
        let eight = Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: Date()) ?? Date()
        return BotJob(title: "", prompt: "", kind: .daily, date: eight)
    }

    // MARK: - Schedule

    private var cal: Calendar { .current }

    private func at(_ day: Date) -> Date? {
        let t = cal.dateComponents([.hour, .minute], from: date)
        return cal.date(bySettingHour: t.hour ?? 0, minute: t.minute ?? 0, second: 0, of: day)
    }

    private func runsOn(_ day: Date) -> Bool {
        let wd = cal.component(.weekday, from: day)
        switch kind {
        case .weekdays: return (2...6).contains(wd)
        case .weekly: return wd == weekday
        default: return true
        }
    }

    /// The latest scheduled time at or before `now`.
    func lastSlot(before now: Date) -> Date? {
        switch kind {
        case .manual: return nil
        case .once: return date <= now ? date : nil
        case .hourly:
            var c = cal.dateComponents([.year, .month, .day, .hour], from: now)
            c.minute = cal.component(.minute, from: date)
            guard let slot = cal.date(from: c) else { return nil }
            return slot <= now ? slot : slot.addingTimeInterval(-3600)
        case .daily, .weekdays, .weekly:
            for offset in 0...7 {
                guard let day = cal.date(byAdding: .day, value: -offset, to: cal.startOfDay(for: now)),
                      runsOn(day), let slot = at(day), slot <= now else { continue }
                return slot
            }
            return nil
        }
    }

    /// The next scheduled time after `now`, for display.
    func nextSlot(after now: Date) -> Date? {
        switch kind {
        case .manual: return nil
        case .once: return lastRun == nil && date > now ? date : nil
        case .hourly: return lastSlot(before: now).map { $0.addingTimeInterval(3600) }
        case .daily, .weekdays, .weekly:
            for offset in 0...8 {
                guard let day = cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: now)),
                      runsOn(day), let slot = at(day), slot > now else { continue }
                return slot
            }
            return nil
        }
    }

    /// Due when a scheduled time has passed since the last run (or since it was made).
    /// Missed runs while Bot27 was closed collapse into one catch-up run.
    func isDue(at now: Date) -> Bool {
        guard enabled, !isDone, let slot = lastSlot(before: now) else { return false }
        if kind == .once { return lastRun == nil }
        return slot > max(lastRun ?? .distantPast, createdAt)
    }

    var scheduleText: String {
        let time = date.formatted(date: .omitted, time: .shortened)
        switch kind {
        case .manual: return "On demand"
        case .once: return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        case .hourly: return String(format: "Every hour at :%02d", cal.component(.minute, from: date))
        case .daily: return "Every day at \(time)"
        case .weekdays: return "Weekdays at \(time)"
        case .weekly: return "Every \(cal.weekdaySymbols[(weekday - 1) % 7]) at \(time)"
        }
    }
}

// MARK: - Jobs set up from chat

/// What a bot writes in a ```bot27-job fenced block to create or delete one of its jobs.
struct JobSpec: Decodable {
    var action: String
    var id: String?
    var title: String?
    var prompt: String?
    var schedule: String?
    var time: String?      // "HH:mm"
    var date: String?      // "yyyy-MM-dd HH:mm", for once
    var weekday: String?   // "monday" … "sunday", for weekly

    static let fence = "bot27-job"

    /// The block and what it decodes to, for every job block in a reply.
    static func blocks(in text: String) -> [(range: Range<String.Index>, spec: JobSpec?)] {
        text.matches(of: #/```bot27-job[ \t]*\n([\s\S]*?)```/#).map { match in
            (match.range, try? JSONDecoder().decode(JobSpec.self, from: Data(String(match.1).utf8)))
        }
    }

    func makeJob(now: Date = Date()) -> BotJob? {
        guard action == "create",
              let title = title?.trimmingCharacters(in: .whitespaces), !title.isEmpty,
              let prompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty,
              let kind = BotJob.Kind(rawValue: schedule ?? "daily") else { return nil }
        let cal = Calendar.current
        var job = BotJob(title: title, prompt: prompt, kind: kind, date: now)
        if kind == .once {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm"
            guard let date = date.flatMap(f.date(from:)) else { return nil }
            job.date = date
        } else if let time {
            let parts = time.split(separator: ":").compactMap { Int($0) }
            let hour = parts.count == 2 ? parts[0] : 0, minute = parts.last ?? 0
            job.date = cal.date(bySettingHour: hour, minute: minute, second: 0, of: now) ?? now
        }
        if kind == .weekly {
            let names = cal.weekdaySymbols.map { $0.lowercased() }
            guard let day = weekday?.lowercased(),
                  let i = names.firstIndex(where: { $0.hasPrefix(day.prefix(3)) }) else { return nil }
            job.weekday = i + 1
        }
        return job
    }
}

extension BotJob {
    /// Tells the bot it can set up its own jobs, and what it already has.
    /// The current time, which the bot needs to schedule things. Kept apart so it can go at the end of the prompt.
    static func clock(now: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm, EEEE"
        return "It is now \(f.string(from: now)) (\(TimeZone.current.identifier))."
    }

    static func chatInstructions(existing: [BotJob]) -> String {
        let list = existing.isEmpty ? "none"
            : existing.map { "- id \($0.id.uuidString): \($0.title) (\($0.scheduleText)\($0.enabled ? "" : ", paused"))" }
                .joined(separator: "\n")
        return """
        You live in Bot27, which keeps two kinds of jobs for you:
        - Routines (定时任务): anything tied to a time, whether once ("remind me at 3pm", "in 10 minutes") or repeating \
        ("every morning"). Bot27 sends you the prompt at that time (while it is open) and you answer in this chat, with \
        the same abilities and connections you have now.
        - Tasks (任务): saved jobs with no time, which the user runs with a ▶ button whenever they want.
        Set them up yourself by including a block like this in your reply (it is hidden from the user, who sees a \
        confirmation card with Undo):

        ```bot27-job
        {"action": "create", "title": "Daily email summary", "prompt": "Summarize the emails from the last 24 hours…", "schedule": "daily", "time": "09:00"}
        ```

        For a routine, schedule is one of: daily, weekdays, weekly (add "weekday": "monday"), hourly ("time": "00:30" \
        means half past each hour), or once (instead of time, add "date": "yyyy-MM-dd HH:mm"). For a task, schedule is \
        "manual" with no time. Call them routines or tasks accordingly when you confirm. \
        Write the prompt as a full instruction to your future self. If the user didn't give a time, pick a sensible one \
        and say so. To delete a job: {"action": "delete", "id": "<id>"}. Never say you can't schedule things.

        Your current tasks and routines:
        \(list)
        """
    }
}
