import AppKit
import CoreGraphics
import UserNotifications

/// macOS notifications for the moments that matter when you are away from the screen: a session
/// waiting on you, and a long turn finishing. They show on the lock screen as your notification
/// settings allow; "Open" (or a click) unlocks to the session's window. Datadog news is the one
/// exception to "only while locked": it notifies while unlocked too (Setup can turn that off).
@MainActor
final class Notifier: NSObject {
    static let shared = Notifier()
    /// Opens the session a notification names.
    var onOpen: ((String) -> Void)?
    /// A build notification's action: open the run, or copy its failure details.
    enum BuildAction { case open, copy }
    var onBuild: ((String, BuildAction) -> Void)?
    /// A machine guard notification's Open: the notch on its Machine panel.
    var onMachine: (() -> Void)?
    /// A VPN notification's Open: the notch on its VPN panel.
    var onVPN: (() -> Void)?
    /// A Datadog notification's Snooze 1 h.
    var onProdSnooze: (() -> Void)?

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
        // A failed build or run also offers its failure details, copied without opening anything.
        let copy = UNNotificationAction(identifier: "copy", title: "Copy failure details", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "session", actions: [open], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: "build", actions: [open], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: "build-failed", actions: [copy, open], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: "alert", actions: [open], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: "pullrequest", actions: [open], intentIdentifiers: [], options: []),
            // Datadog: Open, or silence its notifications and banners for an hour.
            UNNotificationCategory(identifier: "prod", actions: [open, UNNotificationAction(identifier: "snooze", title: "Snooze 1 h", options: [])],
                                   intentIdentifiers: [], options: []),
        ])
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

    /// A build or run that passed or failed; one notification per run. `title` names the source.
    func postBuild(id: String, title: String, subtitle: String, body: String, failed: Bool) {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        let flat = body.split(whereSeparator: \.isNewline).joined(separator: " ")
        content.body = flat.count > 160 ? String(flat.prefix(159)) + "…" : flat
        content.categoryIdentifier = failed ? "build-failed" : "build"
        content.userInfo = ["build": id]
        content.sound = .default
        let request = UNNotificationRequest(identifier: "build-\(id)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            Task { @MainActor in self.note("posted “\(title)”\(error.map { " failed: \($0.localizedDescription)" } ?? "")") }
        }
    }

    /// One poll's Datadog news, grouped (see ProdAlertPlanner): posted while the screen is
    /// unlocked too, which only Prod does. "Open" (or a click) opens the monitor, incident or
    /// filtered list; "Snooze 1 h" silences Prod for an hour. Each notification stays in the list
    /// (a new identifier each time). The log gets the kinds and ids, never a title or name.
    func postProd(_ notice: ProdNotice) {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = notice.title
        let flat = notice.subtitle.split(whereSeparator: \.isNewline).joined(separator: " ")
        content.subtitle = flat.count > 80 ? String(flat.prefix(79)) + "…" : flat
        content.body = notice.body
        content.categoryIdentifier = "prod"
        content.threadIdentifier = "prod"
        var info: [String: String] = ["prod": "1"]
        if let url = notice.url { info["url"] = url.absoluteString }
        content.userInfo = info
        content.sound = .default
        prodCount += 1
        let request = UNNotificationRequest(identifier: "prod-\(Int(Date().timeIntervalSince1970))-\(prodCount)", content: content, trigger: nil)
        let what = "\(notice.kinds) [\(notice.keys.joined(separator: ","))]"
        UNUserNotificationCenter.current().add(request) { error in
            Task { @MainActor in self.note("posted a prod notification: \(what)\(error.map { " failed: \($0.localizedDescription)" } ?? "")") }
        }
    }

    private var prodCount = 0

    /// A VPN connection dropped. Unlike the other status news it notifies while unlocked too:
    /// traffic has stopped going through the VPN. Its one action opens the VPN panel.
    func postVPN(title: String, subtitle: String, body: String) {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        content.body = body
        content.categoryIdentifier = "alert"
        content.userInfo = ["vpn": "1"]
        content.sound = .default
        let request = UNNotificationRequest(identifier: "vpn-dropped", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            Task { @MainActor in self.note("posted “\(title)”\(error.map { " failed: \($0.localizedDescription)" } ?? "")") }
        }
    }

    /// The machine guard's memory-critical news: only while the screen is locked, like the other
    /// status news. Its one action is Open (the notch's Machine panel); nothing is ever closed
    /// from a notification.
    func postMachine(title: String, subtitle: String, body: String) {
        guard isAvailable, Self.mayPostAlerts else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        content.body = body
        content.categoryIdentifier = "alert"
        content.userInfo = ["machine": "1"]
        content.sound = .default
        let request = UNNotificationRequest(identifier: "machine-critical", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            Task { @MainActor in self.note("posted “\(title)”\(error.map { " failed: \($0.localizedDescription)" } ?? "")") }
        }
    }

    /// News on a pull request (approved, changes requested, new comments, a review request, a
    /// failed build): only while the screen is locked, like the other status news. One per pull
    /// request and kind, a newer one replacing the older. "Open" (or a click) opens it on the web.
    /// The log gets the kind only, never the title.
    func postPullRequest(_ event: PREvent) {
        guard isAvailable, Self.mayPostAlerts else { return }
        let content = UNMutableNotificationContent()
        switch event.kind {
        case .approved: content.title = "Pull request approved"
        case .changesRequested: content.title = "Changes requested"
        case .newComments: content.title = "New comments"
        case .reviewRequested: content.title = "Review requested"
        case .buildFailed: content.title = "Pull request build failed"
        }
        let flat = "\(event.pr.repo) #\(event.pr.id) · " + event.title.split(whereSeparator: \.isNewline).joined(separator: " ")
        content.subtitle = flat.count > 80 ? String(flat.prefix(79)) + "…" : flat
        if case .buildFailed(let pipeline?) = event.kind {
            content.body = "Pipeline #\(pipeline.number) failed"
        } else {
            content.body = event.text
        }
        content.categoryIdentifier = "pullrequest"
        if let url = event.url { content.userInfo = ["url": url.absoluteString] }
        content.sound = .default
        let request = UNNotificationRequest(identifier: "pr-\(event.pr.key)-\(event.tag)", content: content, trigger: nil)
        let tag = event.tag
        UNUserNotificationCenter.current().add(request) { error in
            Task { @MainActor in self.note("posted a pull-request notification (\(tag))\(error.map { " failed: \($0.localizedDescription)" } ?? "")") }
        }
    }

    /// Status news notifies only while the screen is locked; a preview may say otherwise.
    static var mayPostAlerts: Bool {
        shared.isScreenLocked || (CommandLine.arguments.contains("--preview") && CommandLine.arguments.contains("--notify-unlocked"))
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
        let info = response.notification.request.content.userInfo
        let session = info["session"] as? String
        let build = info["build"] as? String
        let url = (info["url"] as? String).flatMap(URL.init(string:))
        let machine = info["machine"] != nil
        let vpn = info["vpn"] != nil
        let prod = info["prod"] != nil
        let action = response.actionIdentifier
        Task { @MainActor in
            if prod {
                // Snooze opens nothing; a dismissal neither.
                if action == "snooze" {
                    Notifier.shared.onProdSnooze?()
                } else if action != UNNotificationDismissActionIdentifier, let url {
                    NSWorkspace.shared.open(url)
                }
                completionHandler()
                return
            }
            if let url { NSWorkspace.shared.open(url) }
            if machine, action != UNNotificationDismissActionIdentifier { Notifier.shared.onMachine?() }
            if vpn, action != UNNotificationDismissActionIdentifier { Notifier.shared.onVPN?() }
            if let session { Notifier.shared.onOpen?(session) }
            if let build { Notifier.shared.onBuild?(build, action == "copy" ? .copy : .open) }
            completionHandler()
        }
    }
}

extension Notifier {
    /// A Claude usage limit crossed 80% or 95%: notifies while unlocked too (you are about to be
    /// stopped mid-work). One per window, threshold and reset.
    func postLimit(id: String, title: String, body: String) {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: "limit-\(id)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            Task { @MainActor in self.note("posted limit \(id)\(error.map { " failed: \($0.localizedDescription)" } ?? "")") }
        }
    }
}

/// Watches Claude's usage limits for the 80% and 95% marks, with the time to the reset and, when
/// two readings allow, when this pace runs out.
@MainActor
final class LimitAlerts {
    static let shared = LimitAlerts()
    static let enabledKey = "limits.alerts"
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
    private static let sentKey = "limits.alertsSent"
    private static let marks: [Double] = [95, 80]

    /// The previous reading per window, for the pace.
    private var previous: [String: (used: Double, at: Double)] = [:]

    func check(_ limits: ToolLimits) {
        guard Self.isEnabled else { return }
        for (name, window) in [("5-hour", limits.fiveHour), ("weekly", limits.weekly)] {
            guard let window else { continue }
            let used = window.usedPercent
            var pace: Double?
            if let last = previous[name], limits.at > last.at + 60, used > last.used {
                pace = (used - last.used) / (limits.at - last.at)
            }
            if previous[name].map({ used < $0.used }) ?? true || pace != nil { previous[name] = (used, limits.at) }
            guard let mark = Self.marks.first(where: { used >= $0 }) else { continue }
            let reset = window.resetsAt.map { Int($0 / 60) } ?? Int(limits.at / 86400)
            let id = "\(name)-\(Int(mark))-\(reset)"
            var sent = UserDefaults.standard.stringArray(forKey: Self.sentKey) ?? []
            guard !sent.contains(id) else { continue }
            sent = Array((sent + [id]).suffix(40))
            UserDefaults.standard.set(sent, forKey: Self.sentKey)
            var parts: [String] = []
            if let resets = window.resetsAt, resets > limits.at { parts.append("Resets in \(elapsed(resets - limits.at)).") }
            if let pace, pace > 0 {
                let left = (100 - used) / pace
                if let resets = window.resetsAt, limits.at + left < resets {
                    parts.append("At this pace it runs out in about \(elapsed(left)).")
                }
            }
            Notifier.shared.postLimit(id: id, title: "Claude \(name) limit at \(Int(used.rounded()))%", body: parts.joined(separator: " "))
        }
    }
}
