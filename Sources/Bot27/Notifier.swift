import AppKit
import UserNotifications

/// macOS notifications for replies you haven't seen, plus the Dock badge.
@MainActor
final class Notifier: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// Opens a bot when its notification is clicked.
    var open: ((UUID) -> Void)?
    /// Whether a bot is on screen right now, so its notifications can be skipped.
    var isShowing: ((UUID) -> Bool)?

    @Published private(set) var status: UNAuthorizationStatus = .notDetermined

    private var center: UNUserNotificationCenter { .current() }

    static var enabled: Bool { UserDefaults.standard.object(forKey: "notifyEnabled") as? Bool ?? true }
    static var showPreview: Bool { UserDefaults.standard.object(forKey: "notifyPreview") as? Bool ?? true }

    func setUp() {
        center.delegate = self
        if Self.enabled { requestPermission() } else { refreshStatus() }
    }

    func requestPermission() {
        center.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] _, _ in
            Task { @MainActor in self?.refreshStatus() }
        }
    }

    func refreshStatus() {
        center.getNotificationSettings { [weak self] settings in
            let status = settings.authorizationStatus
            Task { @MainActor in self?.status = status }
        }
    }

    /// A finished reply. Skipped while you're looking at that bot.
    func replied(bot: Bot) {
        guard Self.enabled, !(isShowing?(bot.id) ?? false), let last = bot.messages.last else { return }
        let content = UNMutableNotificationContent()
        content.title = bot.name
        content.body = Self.showPreview ? Self.preview(of: last) : "New message"
        content.sound = .default
        content.threadIdentifier = bot.id.uuidString
        content.userInfo = ["bot": bot.id.uuidString]
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func sendTest() {
        let content = UNMutableNotificationContent()
        content.title = "Bot27"
        content.body = Self.showPreview ? "This is how new replies will look." : "New message"
        content.sound = .default
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// Clears a bot's notifications once you open it.
    func seen(bot id: UUID) {
        center.getDeliveredNotifications { [weak self] delivered in
            let ids = delivered.filter { $0.request.content.threadIdentifier == id.uuidString }.map(\.request.identifier)
            guard !ids.isEmpty else { return }
            Task { @MainActor in self?.center.removeDeliveredNotifications(withIdentifiers: ids) }
        }
    }

    /// Number of bots with unread replies, on the Dock icon.
    func badge(_ count: Int) {
        NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
    }

    private static func preview(of message: Message) -> String {
        if message.isError == true { return "Couldn't get a reply" }
        if message.content.isEmpty {
            if let note = message.jobNotes?.first { return note.title }
            if let note = message.connectNotes?.first { return note.name }
            if let note = message.memoryNotes?.first { return note.text }
        }
        let flat = message.content
            .replacingOccurrences(of: "```bot27-[a-z]+[\\s\\S]*?```", with: "", options: .regularExpression)
            .replacingOccurrences(of: "[*#`>]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return flat.count > 160 ? String(flat.prefix(160)) + "…" : flat
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // Bot27 is in front but showing another bot: still show the banner.
        completionHandler([.banner, .sound, .list])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = (response.notification.request.content.userInfo["bot"] as? String).flatMap(UUID.init(uuidString:))
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.title == "Bot27" }?.makeKeyAndOrderFront(nil)
            if let id { self.open?(id) }
        }
        completionHandler()
    }
}
