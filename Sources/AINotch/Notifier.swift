import AppKit
import CoreGraphics
import UserNotifications

/// macOS notifications for the moments that matter when you are away from the screen: a session
/// waiting on you, and a long turn finishing. They show on the lock screen as your notification
/// settings allow; "Open" (or a click) unlocks to the session's window.
@MainActor
final class Notifier: NSObject {
    static let shared = Notifier()
    /// Opens the session a notification names.
    var onOpen: ((String) -> Void)?

    private let log = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/notch/notch.log")

    /// Notifications need an app bundle; a bare binary (a build run from `.build`) has none.
    private var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    /// False for a copy that is not set up yet: the permission prompt then waits for Set up
    /// instead of greeting a first launch.
    var asksAtLaunch = true

    func setUp() {
        guard isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let open = UNNotificationAction(identifier: "open", title: "Open", options: [.foreground])
        center.setNotificationCategories([UNNotificationCategory(identifier: "session", actions: [open], intentIdentifiers: [], options: [])])
        if asksAtLaunch { requestPermission { _ in } }
    }

    /// macOS asks once; later calls answer with the choice made then.
    func requestPermission(_ done: @escaping @MainActor (Bool) -> Void) {
        guard isAvailable else { done(false); return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            Task { @MainActor in
                self.note("notifications \(granted ? "allowed" : "not allowed")\(error.map { ": \($0.localizedDescription)" } ?? "")")
                done(granted)
            }
        }
    }

    /// The permission's state; nil without an app bundle.
    func permission(_ done: @escaping @MainActor (UNAuthorizationStatus?) -> Void) {
        guard isAvailable else { done(nil); return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status = settings.authorizationStatus
            Task { @MainActor in done(status) }
        }
    }

    /// Whether the screen is locked now (the login window's own flag).
    var isScreenLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    /// One notification per session: a newer one replaces the older.
    /// `title` is the chat's name, on one line; `subtitle` the project and what happened.
    func post(session: String, title: String, subtitle: String, body: String) {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        let flat = title.split(whereSeparator: \.isNewline).joined(separator: " ")
        content.title = flat.count > 80 ? String(flat.prefix(79)) + "…" : flat
        content.subtitle = subtitle
        content.body = body
        content.categoryIdentifier = "session"
        content.userInfo = ["session": session]
        content.sound = .default
        let request = UNNotificationRequest(identifier: "session-\(session)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            Task { @MainActor in self.note("posted “\(subtitle)”\(error.map { " failed: \($0.localizedDescription)" } ?? "")") }
        }
    }

    private func note(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        guard let data = "\(stamp) \(line)\n".data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: log) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: log)
        }
    }
}

extension Notifier: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let session = response.notification.request.content.userInfo["session"] as? String
        Task { @MainActor in
            if let session { Notifier.shared.onOpen?(session) }
            completionHandler()
        }
    }
}
