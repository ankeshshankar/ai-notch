import AppKit
import ApplicationServices
import SwiftUI
import UserNotifications
import NotchCore

/// The setup window's state: each item's live status, re-read every second while it is open.
/// Nothing is written until Set Up (or Disconnect) is clicked.
@MainActor
final class SetupModel: ObservableObject {
    @Published private(set) var location = AppLocation.current()
    @Published private(set) var claude: ItemStatus = .notSetUp
    /// Nil when there is no `~/.cursor`: the row is not shown.
    @Published private(set) var cursor: ItemStatus?
    @Published private(set) var login: ItemStatus = .notSetUp
    @Published private(set) var notifications: UNAuthorizationStatus?
    @Published private(set) var accessibility = false
    /// The optional items Set Up asks for.
    @Published var wantsNotifications = true
    @Published var wantsAccessibility = false
    /// The last Set Up's or Disconnect's errors, by item.
    @Published private(set) var errors: [String: String] = [:]
    @Published private(set) var backups: [String] = []
    /// The last probe of this copy's hook (nil: not probed yet) and the hook's quarantine flag
    /// then. Probed when the window opens, on Set Up and on Check Again; never on the timer.
    @Published private(set) var probe: HookProbe.Result?
    @Published private(set) var quarantine: String?
    @Published private(set) var probing = false
    private var probedAt = Date.distantPast
    private var pendingProbe: HookProbe.Run?
    private var timer: Timer?

    var hookBlocked: Bool { probe.map { !$0.runs } ?? false }
    var requiredDone: Bool { location.problem == nil && !hookBlocked && claude.isDone && (cursor?.isDone ?? true) && login.isDone }
    /// Hooks in the user's files point at this copy (all of them or some).
    var connected: Bool { claude == .done || claude == .incomplete || cursor == .done || cursor == .incomplete }
    var unquarantineCommand: String { HookProbe.unquarantineCommand(location.bundle) }

    func start() {
        refresh()
        // A probe from the launch check a moment ago stands; otherwise check again.
        if Date().timeIntervalSince(probedAt) > 5 { checkHook() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        let location = AppLocation.current()
        if location.bundle != self.location.bundle || location.problem != self.location.problem { self.location = location }
        set(\.claude, Setup.claudeStatus(location))
        if claude.isDone { UserDefaults.standard.set(location.bundle.path, forKey: SetupWindowController.connectedKey) }
        set(\.cursor, Setup.hasCursor ? Setup.cursorStatus(location) : nil)
        set(\.login, Setup.loginStatus(location))
        set(\.accessibility, AXIsProcessTrusted())
        Notifier.shared.permission { [weak self] status in self?.set(\.notifications, status) }
    }

    /// Publishes only a change, so the once-a-second refresh redraws nothing when nothing moved.
    private func set<T: Equatable>(_ key: ReferenceWritableKeyPath<SetupModel, T>, _ value: T) {
        if self[keyPath: key] != value { self[keyPath: key] = value }
    }

    /// Probes the hook off the main thread (answered within `HookProbe.timeout`) and calls `then`
    /// on the main thread with whether it ran.
    func checkHook(then: ((Bool) -> Void)? = nil) {
        guard location.problem == nil else { return }
        guard !probing else { return }
        probing = true
        let hook = location.hook
        // A probe macOS is still judging is waited on, not stacked with another (see killAfter).
        let run = pendingProbe.flatMap { $0.isRunning ? $0 : nil } ?? HookProbe.Run(hook)
        pendingProbe = run
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = run.result()
            let mark = HookProbe.quarantine(hook)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.note(result, quarantine: mark)
                    then?(result.runs)
                }
            }
        }
    }

    /// A probe's outcome, from `checkHook` or the launch check.
    func note(_ result: HookProbe.Result, quarantine: String?) {
        probing = false
        probedAt = Date()
        probe = result
        self.quarantine = quarantine
    }

    /// Set Up and Check Again: the hook must run first; only then is anything written.
    func setUp() {
        checkHook { [weak self] runs in
            guard runs, let self, let probe = self.probe else { return }
            self.connect(probe)
        }
    }

    private func connect(_ probe: HookProbe.Result) {
        let outcome = Setup.connect(location, probe: probe)
        errors = outcome.errors
        backups = outcome.written.compactMap { $0.backup.map(SetupPaths.short) }
        UserDefaults.standard.set(location.bundle.path, forKey: SetupWindowController.seenKey)
        if location.problem == nil {
            if wantsNotifications, notifications == .notDetermined {
                Notifier.shared.requestPermission { [weak self] _ in self?.refresh() }
            }
            if wantsAccessibility, !accessibility { askForAccessibility() }
        }
        refresh()
    }

    func disconnect() {
        let outcome = Setup.disconnect()
        UserDefaults.standard.removeObject(forKey: SetupWindowController.connectedKey)
        errors = outcome.errors
        backups = outcome.written.compactMap { $0.backup.map(SetupPaths.short) }
        refresh()
    }

    func askForNotifications() {
        if notifications == .denied {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
        } else {
            Notifier.shared.requestPermission { [weak self] _ in self?.refresh() }
        }
    }

    func askForAccessibility() {
        // The notch's first jump would ask too; asked here, it does not ask again.
        UserDefaults.standard.set(true, forKey: "askedForAccessibility")
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}

/// The window itself: opened on a first launch, when the app is opened again, and from the
/// panel's footer.
@MainActor
final class SetupWindowController: NSObject, NSWindowDelegate {
    static let shared = SetupWindowController()
    /// The app path whose setup window was last seen: a copy moved elsewhere shows it again.
    static let seenKey = "setupSeenPath"
    /// The app path whose hooks were last seen connected. Hooks gone from under it without the
    /// window's Disconnect (a Homebrew upgrade's uninstall step takes them out) show it again.
    static let connectedKey = "setupConnectedPath"
    /// A preview's window quits the app when it closes.
    var quitsOnClose = false
    let model = SetupModel()
    private var window: NSWindow?

    /// A first launch of this copy that is not set up shows the window by itself, and so does a
    /// launch that finds the hooks this copy had gone.
    func shouldShowAtLaunch() -> Bool {
        let location = AppLocation.current()
        let defaults = UserDefaults.standard
        if location.problem != nil { return true }
        if Setup.claudeStatus(location).isDone {
            defaults.set(location.bundle.path, forKey: Self.connectedKey)
            return false
        }
        let path = location.bundle.path
        return defaults.string(forKey: Self.seenKey) != path || defaults.string(forKey: Self.connectedKey) == path
    }

    /// A launch that does not show the window by itself: when the hooks point at this copy, its
    /// hook is probed in the background, and one macOS now blocks shows the window with that
    /// state (as hooks gone from under it do).
    func checkHookAtLaunch() {
        let location = AppLocation.current()
        guard location.problem == nil else { return }
        let here: [ItemStatus] = [.done, .incomplete]
        let connected = here.contains(Setup.claudeStatus(location))
            || (Setup.hasCursor && here.contains(Setup.cursorStatus(location)))
            || UserDefaults.standard.string(forKey: Self.connectedKey) == location.bundle.path
        guard connected else { return }
        model.checkHook { [weak self] runs in
            if !runs { self?.show() }
        }
    }

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: SetupView(model: model, close: { [weak self] in self?.window?.close() },
                                                               confirmDisconnect: { [weak self] in self?.confirmDisconnect() }))
            host.sizingOptions = .preferredContentSize
            let window = NSWindow(contentViewController: host)
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.title = "AI Notch Setup"
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.delegate = self
            // Its SwiftUI size first, so it is centred at the size it shows.
            window.setContentSize(host.view.fittingSize)
            window.center()
            self.window = window
        }
        model.start()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    /// The window's number and frame, for a preview's screenshots.
    var windowInfo: (number: Int, frame: NSRect)? { window.map { ($0.windowNumber, $0.frame) } }

    func windowWillClose(_ notification: Notification) {
        model.stop()
        UserDefaults.standard.set(model.location.bundle.path, forKey: Self.seenKey)
        if quitsOnClose { NSApp.terminate(nil) }
    }

    private func confirmDisconnect() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Disconnect AI Notch?"
        alert.informativeText = "Its hooks leave Claude Code and Cursor, and your status line goes back to your own command. A backup is saved first."
        alert.addButton(withTitle: "Disconnect").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated { self?.model.disconnect() }
        }
    }
}

/// The wordmark's orange-to-lilac, a step darker on light.
private let wordmark = LinearGradient(
    colors: [
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(srgbRed: 0.88, green: 0.52, blue: 0.40, alpha: 1) : NSColor(srgbRed: 0.76, green: 0.37, blue: 0.24, alpha: 1) }),
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(srgbRed: 0.71, green: 0.67, blue: 0.96, alpha: 1) : NSColor(srgbRed: 0.42, green: 0.36, blue: 0.82, alpha: 1) }),
    ],
    startPoint: .leading, endPoint: .trailing
)

struct SetupView: View {
    @ObservedObject var model: SetupModel
    var close: () -> Void
    var confirmDisconnect: () -> Void

    private var isDone: Bool { model.requiredDone }
    /// A team-signed build carries the widget and the app group it reads; an ad-hoc one neither.
    private let hasWidget: Bool = WidgetSnapshot.appGroup != nil
        && FileManager.default.fileExists(atPath: Bundle.main.bundleURL.appendingPathComponent("Contents/PlugIns/AINotchWidget.appex").path)

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().interpolation(.high)
                    .frame(width: 88, height: 88)
                (Text("Welcome to ") + Text("AI Notch").foregroundStyle(wordmark))
                    .font(.system(size: 22, weight: .bold))
                Text(isDone ? "You're all set." : "Your agents' sessions, live under the notch.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            .padding(.top, 8)

            if let problem = model.location.problem { blocked(problem) } else if model.hookBlocked { hookBlocked }

            section("Connect") {
                row("Claude Code", icon: "terminal.fill", tint: Color(red: 0.85, green: 0.47, blue: 0.34),
                    info: "Adds AI Notch's hook to 13 Claude Code events and wraps your status line, in ~/.claude/settings.json. Your own hooks and settings stay as they are. A backup is saved first.") {
                    status(model.claude, done: "Connected", error: model.errors["claude"])
                }
                if let cursor = model.cursor {
                    divider
                    row("Cursor", icon: "cursorarrow.rays", tint: Color(red: 0.45, green: 0.42, blue: 0.86),
                        info: "Adds the hook to 8 events of Cursor's own agent, in ~/.cursor/hooks.json. Cursor's permission hooks are left alone. A backup is saved first.") {
                        status(cursor, done: "Connected", error: model.errors["cursor"])
                    }
                }
                divider
                row("Open at login", icon: "power", tint: Color(red: 0.36, green: 0.62, blue: 0.40),
                    info: "A login item (~/Library/LaunchAgents/info.ankeshshiv.notch.plist) starts AI Notch when you log in and restarts it if it crashes. Quit in the notch keeps it quit until your next login.") {
                    status(model.login, done: "On", error: model.errors["login"])
                }
            }

            section("Optional") {
                row("Notifications", icon: "bell.badge.fill", tint: Color(red: 0.90, green: 0.30, blue: 0.27),
                    info: "Only while the screen is locked: a session that needs you, or a long turn finishing.") {
                    optional(granted: model.notifications == .authorized || model.notifications == .provisional,
                             unavailable: model.notifications == nil,
                             denied: model.notifications == .denied,
                             wants: $model.wantsNotifications, ask: model.askForNotifications)
                }
                divider
                row("Jump to window", icon: "macwindow.on.rectangle", tint: Color(red: 0.25, green: 0.52, blue: 0.93),
                    info: "Accessibility access lets a click on a session raise its exact window. Without it, the app it runs in comes to the front.") {
                    optional(granted: model.accessibility, unavailable: false, denied: false,
                             wants: $model.wantsAccessibility, ask: model.askForAccessibility)
                }
                divider
                if hasWidget {
                    row("Desktop widget", icon: "square.grid.2x2.fill", tint: Color(red: 0.20, green: 0.65, blue: 0.70),
                        info: "Right-click the desktop, choose Edit Widgets, and search for AI Notch.") {
                        Text("Edit Widgets").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                } else {
                    row("Desktop widget", icon: "square.grid.2x2.fill", tint: Color(red: 0.20, green: 0.65, blue: 0.70),
                        info: "macOS only runs a widget from an app signed with an Apple team. This build is signed ad hoc, so it has none; the notch works the same. A build you sign with your own team includes it (see the README).") {
                        Text("Needs a signed build").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            }

            if isDone {
                HStack(spacing: 10) {
                    NotchGlyph().frame(width: 34, height: 14)
                    Text("Hover the notch to see your sessions.").font(.system(size: 13, weight: .medium))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor.opacity(0.12)))
            }

            HStack(spacing: 10) {
                if isDone {
                    Button("Disconnect…", action: confirmDisconnect)
                        .controlSize(.large)
                    if !model.backups.isEmpty { InfoMark(text: "Backups: " + model.backups.joined(separator: ", ")) }
                    Spacer()
                    Button("Done", action: close)
                        .keyboardShortcut(.defaultAction)
                        .controlSize(.large)
                        .buttonStyle(.borderedProminent)
                } else if model.location.problem == nil && model.hookBlocked {
                    Button("Not Now", action: close)
                        .controlSize(.large)
                    // Hooks already pointing at a blocked helper stall every event: offer to take them out.
                    if model.connected {
                        Button("Disconnect…", action: confirmDisconnect)
                            .controlSize(.large)
                    }
                    Spacer()
                    Button(model.probing ? "Checking…" : "Check Again", action: model.setUp)
                        .keyboardShortcut(.defaultAction)
                        .controlSize(.large)
                        .buttonStyle(.borderedProminent)
                        .disabled(model.probing)
                } else {
                    Button("Not Now", action: close)
                        .controlSize(.large)
                    Spacer()
                    Button("Set Up", action: model.setUp)
                        .keyboardShortcut(.defaultAction)
                        .controlSize(.large)
                        .buttonStyle(.borderedProminent)
                        .disabled(model.location.problem != nil || model.probing)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 20)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func blocked(_ problem: AppLocation.Problem) -> some View {
        let text: String
        let info: String
        switch problem {
        case .diskImage:
            text = "Move AI Notch to Applications first."
            info = "It is running from the disk image. Drag it to Applications, eject the disk image, and open it from Applications. The hooks point at the app where it lives, so it has to stay there."
        case .translocated:
            text = "Move AI Notch to Applications first."
            info = "macOS is running a quarantined copy from a temporary folder (App Translocation). Move the app to Applications in Finder and open it from there."
        case .missingHook:
            text = "This copy has no hook."
            info = "Contents/MacOS/ai-notch-hook is missing from the app. Install it again."
        }
        return HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).font(.system(size: 13, weight: .medium))
            InfoMark(text: info)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.14)))
    }

    /// The helper does not run: the one command that frees it, to copy, and Check Again below.
    private var hookBlocked: some View {
        var info = "Claude Code and Cursor run AI Notch's helper (Contents/MacOS/ai-notch-hook) directly, and macOS does not let it run"
            + (model.quarantine != nil ? ": it still carries the download's quarantine" : "")
            + ", so every hook event would stall until macOS stops it. The command removes the quarantine from this copy of AI Notch only. Set Up connects nothing until the helper runs. Right after the command, macOS can take a little while to let it run; click Check Again once more."
        if case .blocked(let why) = model.probe { info += "\n\nCheck: \(HookProbe.describe(why))." }
        if let mark = model.quarantine { info += " Quarantine flag: \(mark)" }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("macOS is blocking AI Notch's helper.").font(.system(size: 13, weight: .medium))
                InfoMark(text: info)
                Spacer(minLength: 0)
            }
            Text(model.unquarantineCommand)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.07)))
            HStack(spacing: 8) {
                Text("Run it in Terminal, then Check Again.").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                CopyButton(text: model.unquarantineCommand)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.14)))
    }

    private var divider: some View { Divider().padding(.leading, 44) }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 4)
            VStack(spacing: 0) { content() }
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        }
    }

    private func row<Trailing: View>(_ title: String, icon: String, tint: Color, info: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(tint.gradient))
            Text(title).font(.system(size: 13))
            InfoMark(text: info)
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 40)
    }

    @ViewBuilder
    private func status(_ status: ItemStatus, done: String, error: String?) -> some View {
        if let error {
            badge("Failed", symbol: "xmark.octagon.fill", color: .red).help(error)
        } else {
            switch status {
            case .done: badge(done, symbol: "checkmark.circle.fill", color: .green)
            case .notSetUp: badge("Not set up", symbol: "circle.dashed", color: .secondary)
            case .otherCopy(let path): badge("Other copy", symbol: "arrow.triangle.2.circlepath", color: .orange)
                .help("Points at \(path). Set Up moves it to this copy.")
            case .incomplete: badge("Incomplete", symbol: "circle.lefthalf.filled", color: .orange)
                .help("Some entries are missing or differ. Set Up completes them.")
            case .failed(let why): badge("Error", symbol: "exclamationmark.circle.fill", color: .red).help(why)
            }
        }
    }

    private func badge(_ text: String, symbol: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text).foregroundStyle(color == .secondary ? Color.secondary : Color.primary)
        }
        .font(.system(size: 12))
    }

    /// An optional item: on once granted; before Set Up a checkbox for whether to ask; after,
    /// a button that asks.
    @ViewBuilder
    private func optional(granted: Bool, unavailable: Bool, denied: Bool, wants: Binding<Bool>, ask: @escaping () -> Void) -> some View {
        if granted {
            badge("On", symbol: "checkmark.circle.fill", color: .green)
        } else if unavailable {
            Text("Needs the app").font(.system(size: 12)).foregroundStyle(.secondary)
        } else if denied {
            Button("Open Settings", action: ask).controlSize(.small)
        } else if isDone {
            Button("Turn On", action: ask).controlSize(.small)
        } else {
            Toggle("", isOn: wants).toggleStyle(.checkbox).labelsHidden()
                .help(wants.wrappedValue ? "Set Up asks for this." : "Set Up skips this.")
        }
    }
}

/// Copies a command; says "Copied" for a moment after.
private struct CopyButton: View {
    var text: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
        } label: {
            Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
        }
        .controlSize(.small)
    }
}

/// A tiny notch: the black strip under the top edge.
private struct NotchGlyph: View {
    var body: some View {
        ZStack(alignment: .top) {
            Rectangle().fill(Color.primary.opacity(0.18)).frame(height: 1.5)
            UnevenRoundedRectangle(bottomLeadingRadius: 5, bottomTrailingRadius: 5, style: .continuous)
                .fill(Color.black)
                .frame(width: 22, height: 9)
                .overlay(UnevenRoundedRectangle(bottomLeadingRadius: 5, bottomTrailingRadius: 5, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
        }
    }
}
