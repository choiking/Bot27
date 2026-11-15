import Foundation

@main struct JobsChecks {
    static func date(_ value: String, zone: String = "Asia/Shanghai") -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: zone)!
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.date(from: value)!
    }

    static func spec(_ fields: [String: Any], now: Date) -> BotJob? {
        var json = fields
        json["action"] = "create"
        json["title"] = "Inbox check"
        json["prompt"] = "Check Gmail"
        let data = try! JSONSerialization.data(withJSONObject: json)
        return (try? JSONDecoder().decode(JobSpec.self, from: data))?.makeJob(now: now)
    }

    static func main() throws {
        let created = date("2026-11-15 09:59:00")
        let fields: [String: Any] = ["schedule": "interval", "intervalMinutes": 10,
                                   "windowStart": "10:00", "windowEnd": "02:00", "timeZone": "Asia/Shanghai"]
        let job = spec(fields, now: created)!
        precondition(job.createdAt == created)
        precondition(!job.isDue(at: created))
        precondition(job.isDue(at: date("2026-11-15 10:00:00")))
        precondition(job.lastSlot(before: date("2026-11-16 01:59:59")) == date("2026-11-16 01:50:00"))
        precondition(!job.isDue(at: date("2026-11-16 02:00:00")))
        precondition(!job.isDue(at: date("2026-11-16 09:59:59")))
        precondition(job.nextSlot(after: date("2026-11-16 01:50:00")) == date("2026-11-16 10:00:00"))
        precondition(job.nextSlot(after: date("2026-11-15 23:50:00")) == date("2026-11-16 00:00:00"))
        precondition(job.nextSlot(after: date("2026-11-15 10:00:00")) == date("2026-11-15 10:10:00"))

        // Polling repeatedly must run exactly once per slot across several midnight boundaries.
        var polling = job
        var runs = 0
        var now = date("2026-11-15 10:00:00")
        let end = date("2026-11-18 10:00:00")
        while now < end {
            if polling.isDue(at: now) {
                polling.lastRun = now
                runs += 1
                precondition(!polling.isDue(at: now.addingTimeInterval(1)))
            }
            now = now.addingTimeInterval(30)
        }
        precondition(runs == 96 * 3)

        var resumed = job
        resumed.createdAt = date("2026-11-16 00:03:00")
        precondition(!resumed.isDue(at: date("2026-11-16 00:09:59")))
        precondition(resumed.isDue(at: date("2026-11-16 00:10:00")))
        resumed.enabled = false
        precondition(!resumed.isDue(at: date("2026-11-16 00:10:00")))

        var catchup = job
        precondition(catchup.isDue(at: date("2026-11-17 11:37:00")))
        catchup.lastRun = date("2026-11-17 11:37:00")
        precondition(!catchup.isDue(at: date("2026-11-17 11:39:59")))
        precondition(catchup.isDue(at: date("2026-11-17 11:40:00")))

        var daytime = job
        daytime.runWindow = .init(startMinute: 600, endMinute: 660)
        daytime.intervalMinutes = 7
        precondition(daytime.lastSlot(before: date("2026-11-15 10:59:59")) == date("2026-11-15 10:56:00"))
        precondition(!daytime.isDue(at: date("2026-11-15 11:00:00")))
        precondition(daytime.nextSlot(after: date("2026-11-15 10:56:00")) == date("2026-11-16 10:00:00"))
        daytime.intervalMinutes = 1440
        precondition(daytime.nextSlot(after: date("2026-11-15 10:00:00")) == date("2026-11-16 10:00:00"))

        let allDay = spec(["schedule": "interval", "intervalMinutes": 10], now: created)!
        precondition(!allDay.isDue(at: created.addingTimeInterval(599)))
        precondition(allDay.isDue(at: created.addingTimeInterval(600)))
        precondition(allDay.nextSlot(after: created) == created.addingTimeInterval(600))
        precondition(allDay.nextSlot(after: created.addingTimeInterval(600)) == created.addingTimeInterval(1200))

        // Calendar boundaries, including short and long DST nights.
        var dst = job
        dst.timeZoneID = "America/New_York"
        dst.runWindow = .init(startMinute: 0, endMinute: 240)
        for day in ["2026-03-08", "2026-11-01"] {
            let opening = date(day + " 00:00:00", zone: "America/New_York")
            let closing = date(day + " 04:00:00", zone: "America/New_York")
            dst.createdAt = opening.addingTimeInterval(-1)
            var cursor = opening.addingTimeInterval(-1)
            var count = 0
            while let slot = dst.nextSlot(after: cursor), slot < closing {
                precondition(slot > cursor && dst.isDue(at: slot))
                cursor = slot
                count += 1
            }
            precondition(count == (day == "2026-03-08" ? 18 : 30))
            precondition(!dst.isDue(at: closing))
        }

        for invalid: [String: Any] in [
            ["intervalMinutes": 0], ["intervalMinutes": -5], ["intervalMinutes": 1441],
            ["intervalMinutes": 1.5], ["intervalMinutes": "10"],
            ["windowStart": "24:00"], ["windowEnd": "02:60"], ["windowStart": "10:00:00"],
            ["windowEnd": "10:00"], ["timeZone": "Not/AZone"], ["time": "10:00"],
        ] {
            precondition(spec(fields.merging(invalid) { _, new in new }, now: created) == nil)
        }
        precondition(spec(["schedule": "interval"], now: created) == nil)
        precondition(spec(["schedule": "interval", "intervalMinutes": 10, "windowStart": "10:00"], now: created) == nil)
        precondition(spec(["schedule": "daily", "intervalMinutes": 10], now: created) == nil)

        let roundTrip = try JSONDecoder().decode(BotJob.self, from: JSONEncoder().encode(job))
        precondition(roundTrip == job)
        // Legacy persisted jobs have no new keys and must still load and schedule normally.
        var legacy = BotJob(title: "Daily", prompt: "Check", kind: .daily, date: created)
        legacy.createdAt = created.addingTimeInterval(-86400)
        let encoded = try JSONEncoder().encode(legacy)
        let oldJSON = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        precondition(oldJSON["intervalMinutes"] == nil && oldJSON["runWindow"] == nil && oldJSON["timeZoneID"] == nil)
        let restored = try JSONDecoder().decode(BotJob.self, from: encoded)
        precondition(restored == legacy && restored.isDue(at: created))
        for kind in [BotJob.Kind.hourly, .daily, .weekdays, .weekly, .once] {
            var existing = legacy
            existing.kind = kind
            precondition(existing.nextSlot(after: created.addingTimeInterval(-1)) != nil)
        }
        legacy.kind = .manual
        precondition(!legacy.isDue(at: created) && legacy.nextSlot(after: created) == nil)
        print("PASS: interval boundaries, deduplication, catch-up, resume, validation, DST and persistence (host: \(TimeZone.current.identifier))")
    }
}
