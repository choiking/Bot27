#!/usr/bin/env python3
"""Render the production chat layout with fixtures; requires a macOS GUI session.

Uses an in-memory store and simple measurable message rows, so no user data,
model requests, notifications, or scheduled jobs are touched.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
HARNESS = r'''
import AppKit
import SwiftUI

struct Message: Identifiable {
    let id = UUID()
    var content: String
    let date = Date()
}
struct Bot: Identifiable {
    let id = UUID()
    var name = "Fixture"
    var instructions = "Empty conversation"
    var shape = 0
    var color = 0
    var messages: [Message]
    var hasSummary = false
    var summaryThrough: UUID? = nil
    var summary: String? = nil
}
@MainActor final class ChatStore: ObservableObject {
    @Published var selectedBot: Bot?
    func edit(_ id: UUID) {}
    func newBot() {}
    func attach(_ providers: [NSItemProvider]) {}
}
struct Composer: View {
    var body: some View { Text("Composer").frame(height: 40) }
}
struct BlackCapsuleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}
// Native views let the assertions check clipping by the real NSScrollView.
struct Probe: NSViewRepresentable {
    let id: UUID
    static var views: [UUID: NSView] = [:]
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        Self.views[id] = view
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { Self.views[id] = view }
    static func dismantleNSView(_ view: NSView, coordinator: ()) {
        views = views.filter { $0.value !== view }
    }
}
struct MessageRow: View {
    let message: Message
    let isLast: Bool
    var body: some View {
        Text(message.content.isEmpty ? "Typing…" : message.content)
            .font(.system(size: 14.5))
            .padding(14)
            .frame(maxWidth: 560, alignment: .leading)
            .background(Probe(id: message.id))
    }
}

@main struct Harness {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let store = ChatStore()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.title = "Bot27 transcript regression test"
        window.contentView = NSHostingView(rootView: ChatView().environmentObject(store))
        window.orderFront(nil)
        Task { @MainActor in
            func settle() async { try? await Task.sleep(for: .milliseconds(250)) }
            @MainActor func check(_ bot: Bot, _ label: String) {
                guard let last = bot.messages.last,
                      let view = Probe.views[last.id], view.window === window,
                      view.visibleRect.height > 1, view.visibleRect.width > 1 else {
                    print("FAIL: \(label): latest message is outside the viewport")
                    exit(1)
                }
                print("PASS: \(label)")
            }
            @MainActor func show(_ bot: Bot, _ label: String) async {
                store.selectedBot = bot
                await settle()
                check(bot, label)
            }
            let long = Bot(messages: (0..<300).map { index in
                Message(content: "Message \(index)\n" + String(repeating: "Variable height line\n", count: index % 9))
            })
            let short = Bot(messages: [Message(content: "Hello"), Message(content: "Same reply")])
            let sameTail = Bot(messages: [Message(content: "Different bot"), Message(content: "Same reply")])
            await show(long, "initial long conversation")
            for index in 0..<4 {
                await show(short, "long to short \(index)")
                await show(sameTail, "bots with identical last content \(index)")
                await show(long, "short to long \(index)")
            }
            for index in 0..<20 {
                store.selectedBot = index.isMultiple(of: 2) ? short : long
                try? await Task.sleep(for: .milliseconds(10))
            }
            await show(short, "rapid switching")
            store.selectedBot = Bot(messages: [])
            await settle()
            await show(long, "empty to long")
            // The last message ID changes while its text remains identical.
            var updated = long
            updated.messages.append(Message(content: long.messages.last!.content))
            await show(updated, "append identical content")
            updated.messages.append(Message(content: ""))
            await show(updated, "append typing placeholder")
            updated.messages[updated.messages.count - 1].content = String(repeating: "Streamed line\n", count: 20)
            await show(updated, "streaming content grows")
            window.setContentSize(NSSize(width: 620, height: 480))
            await settle()
            check(updated, "resize conversation")
            updated.messages = [Message(content: "New conversation")]
            await show(updated, "replace history in the same bot")
            window.orderOut(nil)
            print("All transcript checks passed")
            exit(0)
        }
        app.run()
    }
}
'''

with tempfile.TemporaryDirectory(prefix="bot27-transcript-test-") as directory:
    tmp = Path(directory)
    # Compile the real ChatView/Transcript, replacing only unrelated dependencies.
    source = (ROOT / "Sources/Bot27/ChatView.swift").read_text()
    (tmp / "ChatLayout.swift").write_text(source.split("// MARK: - Messages", 1)[0])
    (tmp / "Harness.swift").write_text(HARNESS)
    binary = tmp / "check"
    subprocess.run([
        "swiftc", "-parse-as-library", "-module-cache-path", str(tmp / "modules"),
        str(tmp / "ChatLayout.swift"), str(ROOT / "Sources/Bot27/Theme.swift"),
        str(tmp / "Harness.swift"), "-o", str(binary),
    ], check=True)
    subprocess.run([str(binary)], check=True, timeout=30)
