import Foundation

/// Something a bot does for you: a task (no time; runs when you press ▶) or a routine
/// (anything with a time: once, or repeating). Each run posts the prompt and the reply into its chat.
struct BotJob: Identifiable, Codable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case manual, once, hourly, daily, weekdays, weekly, interval

        var label: String {
            switch self {
            case .manual: return "On demand"
            case .once: return "Once"
            case .hourly: return "Hourly"
            case .interval: return "Interval"
            case .daily: return "Daily"
            case .weekdays: return "Weekdays"
            case .weekly: return "Weekly"
            }
        }

        /// Anything with a time is a routine (定时任务), even if it runs only once.
        var isRoutine: Bool { self != .manual }
        static var routineKinds: [Kind] { [.daily, .weekdays, .weekly, .hourly, .interval, .once] }
    }

    /// Minutes after midnight. The start is included; the end is excluded.
    /// An end before the start means the window crosses midnight.
    struct RunWindow: Codable, Equatable {
        var startMinute: Int
        var endMinute: Int

        var isValid: Bool {
            (0..<1440).contains(startMinute) && (0..<1440).contains(endMinute)
                && startMinute != endMinute
        }
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
    // Optional so existing saved jobs decode without a migration.
    var intervalMinutes: Int? = nil
    var runWindow: RunWindow? = nil
    var timeZoneID: String? = nil

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

    private var cal: Calendar {
        var calendar = Calendar.current
        if kind == .interval, let id = timeZoneID, let zone = TimeZone(identifier: id) {
            calendar.timeZone = zone
        }
        return calendar
    }

    var isValidSchedule: Bool {
        guard kind == .interval else { return true }
        return (1...1440).contains(intervalMinutes ?? 0)
            && (runWindow?.isValid ?? true)
            && (timeZoneID.map { TimeZone(identifier: $0) != nil } ?? true)
    }

    private var intervalSeconds: TimeInterval { Double(intervalMinutes ?? 0) * 60 }

    private func window(on day: Date) -> DateInterval? {
        guard let window = runWindow, window.isValid,
              let start = cal.date(bySettingHour: window.startMinute / 60,
                                   minute: window.startMinute % 60, second: 0, of: day),
              let endDay = cal.date(byAdding: .day, value: window.endMinute < window.startMinute ? 1 : 0, to: day),
              let end = cal.date(bySettingHour: window.endMinute / 60,
                                 minute: window.endMinute % 60, second: 0, of: endDay),
              end > start else { return nil }
        return DateInterval(start: start, end: end)
    }

    private func activeWindow(at now: Date) -> DateInterval? {
        for offset in [-1, 0] {
            guard let day = cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: now)),
                  let window = window(on: day), now >= window.start, now < window.end else { continue }
            return window
        }
        return nil
    }

    private func intervalSlot(at now: Date, next: Bool) -> Date? {
        guard isValidSchedule else { return nil }
        if runWindow == nil {
            // Without a window, begin one interval after creation or resume.
            let elapsed = floor(now.timeIntervalSince(createdAt) / intervalSeconds)
            let index = next ? max(1, elapsed + 1) : elapsed
            return index >= 1 ? createdAt.addingTimeInterval(index * intervalSeconds) : nil
        }
        if !next {
            // Do not catch up outside the allowed hours, including after reopening.
            guard let window = activeWindow(at: now) else { return nil }
            let index = floor(now.timeIntervalSince(window.start) / intervalSeconds)
            return window.start.addingTimeInterval(index * intervalSeconds)
        }
        for offset in -1...2 {
            guard let day = cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: now)),
                  let window = window(on: day) else { continue }
            let index = max(0, floor(now.timeIntervalSince(window.start) / intervalSeconds) + 1)
            let slot = window.start.addingTimeInterval(index * intervalSeconds)
            if slot > now && slot < window.end { return slot }
        }
        return nil
    }

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
        case .interval: return intervalSlot(at: now, next: false)
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
        case .interval: return intervalSlot(at: now, next: true)
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
        case .interval:
            var text = "Every \(intervalMinutes ?? 10) minutes"
            if let window = runWindow {
                text += " · \(Self.clockTime(window.startMinute))–\(Self.clockTime(window.endMinute))"
                if window.endMinute < window.startMinute { text += " next day" }
            }
            return text + " (\(timeZoneID ?? TimeZone.current.identifier))"
        case .daily: return "Every day at \(time)"
        case .weekdays: return "Weekdays at \(time)"
        case .weekly: return "Every \(cal.weekdaySymbols[(weekday - 1) % 7]) at \(time)"
        }
    }

    static func clockTime(_ minute: Int) -> String {
        String(format: "%02d:%02d", minute / 60, minute % 60)
    }

    static func parseTime(_ text: String) -> Int? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ $0.count == 2 && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }),
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return hour * 60 + minute
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
    var intervalMinutes: Int?
    var windowStart: String? // "HH:mm", inclusive
    var windowEnd: String?   // "HH:mm", exclusive; can cross midnight
    var timeZone: String?    // IANA identifier, e.g. "Asia/Shanghai"

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
        job.createdAt = now
        if kind == .interval {
            guard time == nil, date == nil, weekday == nil else { return nil }
            job.intervalMinutes = intervalMinutes
            job.timeZoneID = timeZone ?? TimeZone.current.identifier
            if windowStart != nil || windowEnd != nil {
                guard let start = windowStart.flatMap(BotJob.parseTime),
                      let end = windowEnd.flatMap(BotJob.parseTime) else { return nil }
                job.runWindow = .init(startMinute: start, endMinute: end)
            }
            return job.isValidSchedule ? job : nil
        }
        guard intervalMinutes == nil, windowStart == nil, windowEnd == nil, timeZone == nil else { return nil }
        if kind == .once {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm"
            guard let date = date.flatMap(f.date(from:)) else { return nil }
            job.date = date
        } else if let time {
            guard let minute = BotJob.parseTime(time),
                  let date = cal.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: now) else { return nil }
            job.date = date
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
        means half past each hour), interval (add "intervalMinutes": an integer from 1 to 1440), or once \
        (instead of time, add "date": "yyyy-MM-dd HH:mm"). For interval only, optionally add both "windowStart" \
        and "windowEnd" as HH:mm, and "timeZone" as an IANA identifier (Beijing = Asia/Shanghai). The start is \
        included, the end excluded; an earlier end crosses midnight. Equal start/end is invalid; omit both for \
        all-day runs. Intervals start at each window opening, or one interval after creation when no window is set. \
        Outside the window no scheduled run or catch-up starts. For example, one routine every 10 minutes from \
        Beijing 10:00 until 02:00 the next day uses "schedule": "interval", "intervalMinutes": 10, \
        "windowStart": "10:00", "windowEnd": "02:00", "timeZone": "Asia/Shanghai". Do not add time/date/weekday \
        to interval schedules. For a task, schedule is \
        "manual" with no time. Call them routines or tasks accordingly when you confirm. \
        Write the prompt as a full instruction to your future self. If the user didn't give a time, pick a sensible one \
        and say so. To delete a job: {"action": "delete", "id": "<id>"}. Never say you can't schedule things.

        Your current tasks and routines:
        \(list)
        """
    }
}
