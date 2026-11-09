#!/usr/bin/env python3
"""Test production memory logic with temporary files, without model calls or user data."""
from pathlib import Path
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
HARNESS = r'''
import Foundation

struct Message {
    enum Role { case user, assistant }
    var id = UUID()
    var role: Role
    var content: String
    var isError: Bool? = nil
    var date: Date
    var images: [String]? = nil
    var job: String? = nil
    var notice: String? = nil
}
struct Bot { var id = UUID() }
struct ModelChoice {
    enum Provider { case claude, gpt }
    var provider: Provider
    var id: String
}

@main struct Harness {
    static func main() throws {
        let bot = Bot()
        MemoryStore.setUp(bot)
        let folder = DailyNotes.folder(for: bot.id)
        func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
        let first = date("2026-11-07T15:59:00Z") // 23:59 in Shanghai
        let next = date("2026-11-07T16:01:00Z")
        precondition(DailyNotes.stamp(first, "yyyy-MM-dd") == "2026-11-07")
        let oldFile = folder.appendingPathComponent("2026-11-07.md")
        let manual = "# My existing notes\n\nKeep this exact text.\n"
        try Data(manual.utf8).write(to: oldFile)
        let user = Message(role: .user, content: "Original user fact", date: first)
        let assistant = Message(role: .assistant, content: "Assistant response", date: next)
        let history = [
            user, assistant,
            Message(role: .user, content: "Routine prompt", date: next, job: "Inbox check"),
            Message(role: .assistant, content: "Private email content", date: next),
            Message(role: .user, content: "Routine search results", date: next, notice: RecallSpec.notice),
            Message(role: .assistant, content: "Still a routine", date: next),
            Message(role: .user, content: "", date: next, images: ["test.png"]),
            Message(role: .assistant, content: "Provider failure", isError: true, date: next),
            Message(role: .user, content: "Search output", date: next, notice: RecallSpec.notice),
            Message(role: .assistant, content: "", date: next),
            Message(role: .assistant, content: "After recall", date: next)
        ]
        try DailyNotes.save(history, for: bot.id)
        let old = try String(contentsOf: oldFile, encoding: .utf8)
        let newFile = folder.appendingPathComponent("2026-11-08.md")
        let new = try String(contentsOf: newFile, encoding: .utf8)
        precondition(old.hasPrefix(manual) && old.contains(user.id.uuidString))
        precondition(!old.contains(assistant.id.uuidString) && new.contains(assistant.id.uuidString))
        precondition(new.contains("[1 image(s) attached]") && new.contains("After recall"))
        for excluded in ["Routine prompt", "Private email content", "Still a routine", "Provider failure", "Search output"] {
            precondition(!new.contains(excluded), excluded)
        }
        try DailyNotes.save(history, for: bot.id)
        let unchanged = try String(contentsOf: newFile, encoding: .utf8)
        precondition(unchanged == new)
        // A later save appends without losing manual edits or repeating old messages.
        let edit = new + "\nUser annotation\n"
        try Data(edit.utf8).write(to: newFile)
        try DailyNotes.save(history + [Message(role: .user, content: "A later fact", date: next)], for: bot.id)
        let extended = try String(contentsOf: newFile, encoding: .utf8)
        precondition(extended.hasPrefix(edit) && extended.contains("A later fact"))
        precondition(extended.components(separatedBy: assistant.id.uuidString).count == 2)
        precondition(DailyNotes.recent(for: bot.id, now: next).contains("Original user fact"))
        precondition(NoteSearch.day("2026-11-08", for: bot.id).contains("A later fact"))
        precondition(Dreaming.input(for: bot.id, since: nil, now: next)?.contains("A later fact") == true)

        // A corrupt existing file is an error, never silently replaced.
        let broken = folder.appendingPathComponent("2026-11-09.md")
        let bad = Data([0xff, 0xfe, 0xff])
        try bad.write(to: broken)
        do {
            try DailyNotes.save([Message(role: .user, content: "Must not overwrite", date: date("2026-11-09T01:00:00Z"))], for: bot.id)
            fatalError("Expected invalid UTF-8 to fail")
        } catch {}
        let stillBad = try Data(contentsOf: broken)
        precondition(stillBad == bad)
        try FileManager.default.removeItem(at: broken)

        MemoryStore.write("Custom workspace instruction", for: bot.id, .agents)
        MemoryStore.write("MAIN_CHAT_PRIVATE_SENTINEL", for: bot.id, .memory)
        MemoryStore.setUp(bot) // Existing AGENTS.md must survive setup.
        let main = MemoryPrompt.chatInstructions(bot: bot.id, main: true)
        let routine = MemoryPrompt.chatInstructions(bot: bot.id, main: false)
        precondition(main.contains("Custom workspace instruction") && main.contains("MAIN_CHAT_PRIVATE_SENTINEL"))
        precondition(routine.contains("Custom workspace instruction") && !routine.contains("MAIN_CHAT_PRIVATE_SENTINEL"))
        precondition(!MemoryStore.add("Injected change", for: bot.id, .agents))
        precondition(!MemoryStore.remove("Custom workspace instruction", for: bot.id, .agents))
        precondition(MemoryStore.read(bot.id, .agents) == "Custom workspace instruction")
        precondition(MemoryFile(loose: "Agents.md") == .agents)
        let other = Bot()
        MemoryStore.setUp(other)
        precondition(!MemoryPrompt.chatInstructions(bot: other.id, main: true).contains("Custom workspace instruction"))
        precondition(DailyNotes.recent(for: other.id, now: next).isEmpty)
        print("PASS: daily backfill, local dates, deduplication, preserved edits, filtering, recall, dreaming input, AGENTS loading and bot isolation")
    }
}
'''


def main():
    with tempfile.TemporaryDirectory(prefix="bot27-memory-test-") as tmp:
        temp = Path(tmp)
        memory = (ROOT / "Sources/Bot27/Memory.swift").read_text()
        # Redirect only the storage root; all tested memory logic is production code.
        original = '''FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bot27/memory/\\(bot.uuidString)", isDirectory: true)'''
        assert memory.count(original) == 1
        memory = memory.replace(original, '''URL(fileURLWithPath: CommandLine.arguments[1])
            .appendingPathComponent(bot.uuidString, isDirectory: true)''')
        (temp / "Memory.swift").write_text(memory)
        (temp / "Harness.swift").write_text(HARNESS)
        binary = temp / "test-memory"
        subprocess.run(["swiftc", "-swift-version", "5", "-enable-bare-slash-regex",
                        "-module-cache-path", str(temp / "module-cache"),
                        str(temp / "Memory.swift"), str(temp / "Harness.swift"), "-o", str(binary)], check=True)
        subprocess.run([str(binary), str(temp / "memory")], env={**os.environ, "TZ": "Asia/Shanghai"}, check=True)


if __name__ == "__main__":
    main()
