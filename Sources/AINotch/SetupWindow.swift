import AppKit
import ApplicationServices
import SwiftUI
import UserNotifications
import NotchCore
import VPNCore

/// The setup window's state: each item's live status, re-read every second while it is open.
/// Nothing is written until Set Up (or Disconnect) is clicked.
@MainActor
final class SetupModel: ObservableObject {
    @Published private(set) var location = AppLocation.current()
    @Published private(set) var claude: ItemStatus = .notSetUp
    /// Nil when there is no `~/.cursor`: the row is not shown.
    @Published private(set) var cursor: ItemStatus?
    /// Nil without `~/.codex` or `~/.gemini`: their rows are not shown.
    @Published private(set) var codex: ItemStatus?
    @Published private(set) var gemini: ItemStatus?
    /// Nil without `~/.config/opencode`.
    @Published private(set) var opencode: ItemStatus?
    @Published private(set) var login: ItemStatus = .notSetUp
    @Published private(set) var notifications: UNAuthorizationStatus?
    @Published private(set) var accessibility = false
    /// The optional items Set Up asks for.
    @Published var wantsNotifications = true
    @Published var wantsAccessibility = false
    /// The agent process watcher (AgentWatcher): on unless turned off here.
    @Published private(set) var watchAgents = AgentWatcher.isEnabled
    /// The last Set Up's or Disconnect's errors, by item.
    @Published private(set) var errors: [String: String] = [:]
    @Published private(set) var backups: [String] = []
    /// The last probe of this copy's hook (nil: not probed yet) and the hook's quarantine flag
    /// then. Probed when the window opens, on Set Up and on Check Again; never on the timer.
    @Published private(set) var probe: HookProbe.Result?
    @Published private(set) var quarantine: String?
    @Published private(set) var probing = false
    /// builds.json, and the build sources it sets up, from the running notch (nil when the file
    /// leaves a source out, and in a setup preview).
    @Published private(set) var buildsConfig = BuildsConfigInfo(nil, exists: false)
    @Published private(set) var eas: BuildSourceInfo?
    @Published private(set) var bitbucket: BuildSourceInfo?
    /// Pull requests: on or off in builds.json, and whether they read (nil without a bitbucket part).
    @Published private(set) var pullRequests: PRSetupInfo?
    @Published private(set) var prNotify = ReviewStore.NotifyPrefs.load()
    /// Prod (Datadog): its state, and which of its news notifies.
    @Published private(set) var prod = ProdSetupInfo.make(nil)
    @Published private(set) var prodAlerts = ProdAlertPrefs.load()
    /// The machine guard: on or off, and whether memory critical notifies.
    @Published private(set) var machineOn = UserDefaults.standard.object(forKey: "machine.enabled") as? Bool ?? true
    @Published private(set) var commandsOn = CommandsStore.isEnabled
    @Published private(set) var hotkeysOn = Hotkeys.isEnabled
    @Published private(set) var limitAlertsOn = LimitAlerts.isEnabled
    @Published private(set) var telemetryOn = AgentTelemetry.isOn()
    @Published private(set) var telemetryProblem: String?
    @Published private(set) var machineNotify = UserDefaults.standard.object(forKey: "machine.notifyCritical") as? Bool ?? true
    /// The section the window was opened for (the Prod chip's click): outlined for a moment.
    @Published private(set) var focus: SetupFocus?
    /// Counts the times a section was asked for, so asking again scrolls to it again.
    @Published private(set) var focusRequest = 0
    private var probedAt = Date.distantPast
    private var pendingProbe: HookProbe.Run?
    private var timer: Timer?

    var hookBlocked: Bool { probe.map { !$0.runs } ?? false }
    var requiredDone: Bool {
        location.problem == nil && !hookBlocked && claude.isDone && (cursor?.isDone ?? true)
            && (codex?.isDone ?? true) && (gemini?.isDone ?? true) && (opencode?.isDone ?? true) && login.isDone
    }
    /// Hooks in the user's files point at this copy (all of them or some).
    var connected: Bool {
        [claude, cursor, codex, gemini, opencode].contains { $0 == .done || $0 == .incomplete }
    }
    var unquarantineCommand: String { HookProbe.unquarantineCommand(location.bundle) }

    func start() {
        refresh()
        // The sign-in is read again (it may have changed while the window was closed).
        DatadogAuthModel.shared.reload()
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
        focus = nil
    }

    func setFocus(_ focus: SetupFocus?) {
        self.focus = focus
        guard focus != nil else { return }
        focusRequest += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            MainActor.assumeIsolated { if self?.focus == focus { self?.focus = nil } }
        }
    }

    func refresh() {
        let location = AppLocation.current()
        if location.bundle != self.location.bundle || location.problem != self.location.problem { self.location = location }
        set(\.claude, Setup.claudeStatus(location))
        if claude.isDone { UserDefaults.standard.set(location.bundle.path, forKey: SetupWindowController.connectedKey) }
        set(\.cursor, Setup.hasCursor ? Setup.cursorStatus(location) : nil)
        set(\.codex, Setup.hasCodex ? Setup.codexStatus(location) : nil)
        set(\.gemini, Setup.hasGemini ? Setup.geminiStatus(location) : nil)
        set(\.opencode, OpenCodePlugin.hasOpenCode ? OpenCodePlugin.status(hook: location.hook.path) : nil)
        set(\.login, Setup.loginStatus(location))
        set(\.accessibility, AXIsProcessTrusted())
        set(\.buildsConfig, BuildsConfigInfo(BuildsConfig.current, exists: BuildsConfig.fileExists))
        let builds = SetupWindowController.shared.builds
        set(\.eas, builds.flatMap { $0.easOn ? BuildSourceInfo.eas($0.eas) : nil })
        set(\.bitbucket, builds.flatMap { $0.bitbucketOn ? BuildSourceInfo.bitbucket($0.bitbucket) : nil })
        let reviews = SetupWindowController.shared.reviews
        set(\.pullRequests, PRSetupInfo.make(reviews))
        if let reviews { set(\.prNotify, reviews.notify) }
        let prodStore = SetupWindowController.shared.prod
        set(\.prod, ProdSetupInfo.make(prodStore))
        if let prodStore { set(\.prodAlerts, prodStore.alertPrefs) }
        if let machine = SetupWindowController.shared.machine {
            set(\.machineOn, machine.isOn)
            set(\.machineNotify, machine.notifyCritical)
        }
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

    /// Which Datadog alerts notify, pop the notch open or remind (the running notch's, else saved).
    func setProdAlerts(_ prefs: ProdAlertPrefs) {
        prodAlerts = prefs
        if let prod = SetupWindowController.shared.prod { prod.setAlertPrefs(prefs) } else { prefs.save() }
    }

    /// The pull-requests switch: written into builds.json (the source of truth), picked up
    /// within seconds.
    func setPullRequests(_ on: Bool) {
        errors["prs"] = BuildsConfig.setPullRequests(on)
        refresh()
    }

    func setPRNotify(_ prefs: ReviewStore.NotifyPrefs) {
        prNotify = prefs
        if let reviews = SetupWindowController.shared.reviews { reviews.setNotify(prefs) } else { prefs.save() }
    }

    /// Check Again for Bitbucket: Pipelines and pull requests read the Keychain again now.
    func recheckBitbucket() {
        SetupWindowController.shared.builds?.recheckBitbucket()
        SetupWindowController.shared.reviews?.recheckToken()
    }

    func setWatchAgents(_ on: Bool) {
        watchAgents = on
        UserDefaults.standard.set(on, forKey: AgentWatcher.enabledKey)
    }

    func setMachineOn(_ on: Bool) {
        machineOn = on
        if let machine = SetupWindowController.shared.machine { machine.setEnabled(on) } else { UserDefaults.standard.set(on, forKey: "machine.enabled") }
    }

    func setTelemetry(_ on: Bool) {
        telemetryProblem = on ? AgentTelemetry.turnOn(hook: location.hook) : AgentTelemetry.turnOff()
        telemetryOn = AgentTelemetry.isOn()
    }

    func setLimitAlerts(_ on: Bool) {
        limitAlertsOn = on
        UserDefaults.standard.set(on, forKey: LimitAlerts.enabledKey)
    }

    func setHotkeys(_ on: Bool) {
        hotkeysOn = on
        UserDefaults.standard.set(on, forKey: Hotkeys.enabledKey)
        Hotkeys.shared.apply()
    }

    func setCommandsOn(_ on: Bool) {
        commandsOn = on
        UserDefaults.standard.set(on, forKey: CommandsStore.enabledKey)
    }

    func setMachineNotify(_ on: Bool) {
        machineNotify = on
        if let machine = SetupWindowController.shared.machine { machine.setNotify(on) } else { UserDefaults.standard.set(on, forKey: "machine.notifyCritical") }
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

/// A section the window can open at.
enum SetupFocus: Equatable {
    case prod
    case vpn
}

/// builds.json in Setup: whether it is there and what it sets up.
struct BuildsConfigInfo: Equatable {
    var text: String
    var ok: Bool
    var isSetUp: Bool
    var problems: [String]

    init(_ config: BuildsConfig?, exists: Bool) {
        let parts = [config?.eas != nil ? "EAS" : nil, config?.bitbucket != nil ? "Bitbucket" : nil].compactMap { $0 }
        problems = config?.problems ?? []
        isSetUp = !parts.isEmpty
        ok = isSetUp && problems.isEmpty
        text = isSetUp ? parts.joined(separator: " · ") : exists ? "Check the file" : "Not set up"
    }
}

/// Prod's line in Setup: a few words, whether it works, its ⓘ, and whether the steps show.
struct ProdSetupInfo: Equatable {
    var text: String
    var ok: Bool
    var help: String
    /// No `datadog` in builds.json: the example shows.
    var needsConfig = false
    /// Not connected, the sign-in ended, or keys Datadog refused.
    var needsKeys = false

    static let about = "The footer's Prod chip: Datadog monitors (a search query from \(BuildsConfig.displayPath), muted ones count as OK), active incidents, and a few numbers, read with your Datadog sign-in (monitors_read, incident_read, timeseries_query, apm_read, events_read) or, without one, a read-only service-account key from the Keychain (\(DatadogConfig.keyService)). Monitors every minute (3 while the screen is locked), incidents every 3 minutes, the numbers every 5 and Watchdog every 15 (not while locked): about 110 requests an hour, up to 144 in the 20 minutes after a push from a linked repo (the deploy check), never more than 150, backing off on Datadog's rate-limit headers. Never mutes or changes anything in Datadog."

    @MainActor static func make(_ prod: ProdStore?) -> ProdSetupInfo {
        guard BuildsConfig.current?.datadog != nil else {
            return ProdSetupInfo(text: "Not set up", ok: false, help: about, needsConfig: true)
        }
        guard let prod else { return ProdSetupInfo(text: "Not connected", ok: false, help: about, needsKeys: true) }
        let snapshot = prod.snapshot
        switch snapshot.access {
        case .notConfigured, .noKeys:
            return ProdSetupInfo(text: "Not connected", ok: false, help: DatadogConfig.setupHelp + "\n\n" + about, needsKeys: true)
        case .signInAgain(let why):
            return ProdSetupInfo(text: "Sign in again", ok: false, help: why + "\n\n" + about, needsKeys: true)
        case .rejected(let why) where snapshot.viaSignIn:
            return ProdSetupInfo(text: "Refused", ok: false, help: why + "\n\n" + about)
        case .rejected(let why):
            return ProdSetupInfo(text: "Key rejected", ok: false, help: why + " Store new keys (the steps below); they are picked up within a minute.\n\n" + about, needsKeys: true)
        case .ok:
            if snapshot.monitorsAt == 0 {
                return ProdSetupInfo(text: snapshot.problem?.text.capitalizedFirst ?? "Checking…", ok: false, help: (snapshot.problem.map { $0.help + "\n\n" } ?? "") + about)
            }
            var notes = [snapshot.incidentsNote.map { "Incidents: \($0)." }, snapshot.numbersNote.map { "Numbers: \($0)." }].compactMap { $0 }
            if let problem = snapshot.problem { notes.insert("\(problem.text.capitalizedFirst): \(problem.help)", at: 0) }
            let count = snapshot.monitorTotal == 1 ? "1 monitor" : "\(snapshot.monitorTotal) monitors"
            let via = snapshot.viaSignIn ? "Read with your Datadog sign-in. " : "Read with the service-account keys. "
            return ProdSetupInfo(text: "Connected · \(count)", ok: notes.isEmpty,
                                 help: (notes.isEmpty ? "" : notes.joined(separator: "\n") + "\n\n") + via + about + " (\(snapshot.requestsLastHour) in the last hour.)")
        }
    }
}

/// Pull requests' line in Setup: on or off, whether they read, and its ⓘ. A missing scope is a
/// grey hint, never an error.
struct PRSetupInfo: Equatable {
    var text: String
    var ok: Bool
    var on: Bool
    var help: String
    /// The token cannot read pull requests (no read:pullrequest, none stored, refused): the
    /// steps can show.
    var needsToken = false

    static let about = "Your open pull requests and the ones waiting for your review, in the repositories of bitbucket in \(BuildsConfig.displayPath), with the same token as Pipelines (it needs read:pullrequest; read:user finds your account at once). Mine every 2 minutes, each repository's review list every 10 (20 while one of your pipelines runs), details only for what changed, and the merge checks of up to 4 of yours (those on a live session first) every 15 minutes: about 70 requests an hour for 7 repositories plus up to 18 for those checks, capped at 150, beside Pipelines' own budget. Read only. The switch writes \"pullRequests\" into the bitbucket part of that file."

    @MainActor static func make(_ reviews: ReviewStore?) -> PRSetupInfo? {
        guard let bitbucket = BuildsConfig.current?.bitbucket else { return nil }
        guard bitbucket.pullRequests else { return PRSetupInfo(text: "Off", ok: false, on: false, help: about) }
        guard let reviews else { return PRSetupInfo(text: "On", ok: false, on: true, help: about) }
        if let status = reviews.status {
            let needsToken = status.isSetup && status.text != "no repositories" && status.text != "who am I?"
            return PRSetupInfo(text: status.text.prefix(1).uppercased() + status.text.dropFirst(), ok: false, on: true,
                               help: status.help + "\n\n" + about, needsToken: needsToken)
        }
        if reviews.updatedAt == 0 { return PRSetupInfo(text: "Checking…", ok: false, on: true, help: about) }
        let repos = BitbucketConfig.loadReposCached().count
        return PRSetupInfo(text: "Connected · " + (repos == 1 ? "1 repo" : "\(repos) repos"), ok: true, on: true,
                           help: about + (reviews.requestSummary.isEmpty ? "" : " (\(reviews.requestSummary).)"))
    }
}

/// One build source's line in Setup: a few words, whether it works, and its ⓘ.
struct BuildSourceInfo: Equatable {
    var text: String
    var ok: Bool
    var help: String
    /// Not connected yet: Setup shows the steps.
    var needsSetup = false

    static func eas(_ snapshot: EASSnapshot) -> BuildSourceInfo {
        let about = "Read over Expo's GraphQL API (the one eas-cli uses) with the CLI's own login from ~/.expo/state.json, or an EXPO_TOKEN in the Keychain (\(EASConfig.tokenService)) if you store one; if that API fails or changes, the EAS CLI (eas build:list) stands in. A build in flight every 25 s, the list every 5 minutes (every minute while anything runs), paused while the screen is locked. Never starts or cancels a build."
        if let status = snapshot.status { return BuildSourceInfo(text: status.text, ok: false, help: status.help + "\n\n" + about) }
        if snapshot.fetchedAt == 0 { return BuildSourceInfo(text: "Checking…", ok: false, help: about) }
        let via = snapshot.via.map { " · \($0)" } ?? ""
        let fallback = snapshot.fallback.map { "GraphQL failed (\($0)); the CLI stands in for now.\n\n" } ?? ""
        return BuildSourceInfo(text: "Connected\(via)", ok: true, help: fallback + about)
    }

    static func bitbucket(_ snapshot: BitbucketSnapshot) -> BuildSourceInfo {
        let about = "Read over Bitbucket's API with a read-only token from the Keychain (\(BitbucketConfig.tokenService)): one workspace request every 2 minutes for pushes, every repository every 15 minutes, one with a running pipeline every 25 s, under 390 requests an hour (\(snapshot.requestsLastHour) in the last hour), paused while the screen is locked. Repositories: bitbucket in \(BuildsConfig.displayPath). Never starts, stops or reruns a pipeline."
        if let status = snapshot.status {
            return BuildSourceInfo(text: status.text.prefix(1).uppercased() + status.text.dropFirst(), ok: false, help: status.help + "\n\n" + about, needsSetup: status.isSetup)
        }
        if snapshot.fetchedAt == 0 { return BuildSourceInfo(text: "Checking…", ok: false, help: about) }
        var text = "Connected · " + (snapshot.repoCount == 1 ? "1 repository" : "\(snapshot.repoCount) repositories")
        if let expiry = snapshot.tokenExpiresAt {
            let days = Int((expiry - Date().timeIntervalSince1970) / 86_400)
            if days < 14 { text += " · token expires in \(max(0, days))d" }
        }
        return BuildSourceInfo(text: text, ok: true, help: about)
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
    /// The running notch's builds, for the Builds section.
    weak var builds: BuildStore?
    /// The running notch's prod health, for the Prod section.
    weak var prod: ProdStore?
    /// The running notch's machine guard, for the Machine section.
    weak var machine: MachineStore?
    /// The running notch's VPN, for the VPN section.
    weak var vpn: VPNStore?
    /// The running notch's pull requests, for the Builds section.
    weak var reviews: ReviewStore?
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
            || (Setup.hasCodex && here.contains(Setup.codexStatus(location)))
            || (Setup.hasGemini && here.contains(Setup.geminiStatus(location)))
            || UserDefaults.standard.string(forKey: Self.connectedKey) == location.bundle.path
        guard connected else { return }
        model.checkHook { [weak self] runs in
            if !runs { self?.show() }
        }
    }

    /// The window's width: the column the sections are laid out in.
    static let width: CGFloat = 440
    /// Kept clear of the screen's edges (menu bar and Dock excluded) when it fits itself.
    private static let margin: CGFloat = 24
    /// The scrolling sections' and the pinned buttons' heights, as SwiftUI lays them out.
    private var contentHeight: CGFloat = 0
    private var footerHeight: CGFloat = 0
    /// Resized by hand: the window no longer fits itself to its content until it is closed.
    private var userSized = false

    /// Opens the window on the notch's screen, as tall as its content up to that screen's
    /// visible height (past that it scrolls); with `focus`, that section is scrolled into view
    /// and outlined for a moment (the Prod chip's click when it is not connected).
    func show(focus: SetupFocus? = nil) {
        model.setFocus(focus)
        let window = self.window ?? makeWindow()
        model.start()
        if !window.isVisible {
            userSized = false
            // SwiftUI measures its parts during this layout; the window then fits them.
            window.contentView?.layoutSubtreeIfNeeded()
            fit(center: true)
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let view = SetupView(model: model, close: { [weak self] in self?.window?.close() },
                             confirmDisconnect: { [weak self] in self?.confirmDisconnect() },
                             measured: { [weak self] part, height in self?.measured(part, height) })
        let host = NSHostingController(rootView: view)
        // The window sizes itself (fit), so it can also be resized, zoomed and made full screen.
        host.sizingOptions = []
        let window = SetupNSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        window.collectionBehavior = [.fullScreenPrimary]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "AI Notch Setup"
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.level = .aboveNotch
        window.contentMinSize = NSSize(width: Self.width, height: 280)
        window.delegate = self
        let screen = Self.notchScreen.visibleFrame
        window.setContentSize(NSSize(width: Self.width, height: screen.height - 2 * Self.margin))
        self.window = window
        return window
    }

    /// The screen with the notch (the built-in display), as the notch itself picks it; else the
    /// main one.
    private static var notchScreen: NSScreen {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func measured(_ part: SetupView.Part, _ height: CGFloat) {
        switch part {
        case .content: if contentHeight == height { return } else { contentHeight = height }
        case .footer: if footerHeight == height { return } else { footerHeight = height }
        }
        // A section opening or closing (How, the steps) grows or shrinks the window, top edge
        // kept, unless it was resized by hand.
        if window?.isVisible == true { fit(center: false) }
    }

    /// The window's frame showing all of its content, at most `maxHeight` tall, top edge kept.
    private func fittingFrame(_ window: NSWindow, maxHeight: CGFloat) -> NSRect {
        // The title bar overlaps the content (full-size content view); SwiftUI insets for it.
        let titleBar = window.frame.height - window.contentLayoutRect.height
        let wanted = contentHeight + footerHeight + titleBar
        let height = min(max(wanted, window.minSize.height), maxHeight).rounded()
        return NSRect(x: window.frame.minX, y: window.frame.maxY - height, width: window.frame.width, height: height)
    }

    private func fit(center: Bool) {
        guard let window, contentHeight > 0, !userSized, !window.styleMask.contains(.fullScreen) else { return }
        let screen = center ? Self.notchScreen.visibleFrame : (window.screen ?? Self.notchScreen).visibleFrame
        var frame = fittingFrame(window, maxHeight: screen.height - 2 * Self.margin)
        if center {
            frame.origin = NSPoint(x: (screen.midX - frame.width / 2).rounded(), y: (screen.midY - frame.height / 2).rounded())
        } else {
            // Grown past the bottom: moved up, as far as the top margin.
            frame.origin.y = max(frame.minY, screen.minY + Self.margin)
            frame.origin.y = min(frame.minY, screen.maxY - Self.margin - frame.height)
        }
        if frame != window.frame { window.setFrame(frame, display: true) }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        userSized = true
    }

    /// Zoom (the green button, a double-click on the title bar): as tall as the content, up to
    /// the screen's visible height; zooming again goes back.
    func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame newFrame: NSRect) -> NSRect {
        let screen = (window.screen ?? Self.notchScreen).visibleFrame
        var frame = fittingFrame(window, maxHeight: screen.height)
        frame.origin.y = min(max(window.frame.maxY - frame.height, screen.minY), screen.maxY - frame.height)
        return frame
    }

    /// The window's number and frame, for a preview's screenshots.
    var windowInfo: (number: Int, frame: NSRect)? { window.map { ($0.windowNumber, $0.frame) } }

    func windowWillClose(_ notification: Notification) {
        userSized = false
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

/// The setup window. The app has no menu bar of its own (it is an accessory), so the window
/// takes the standard keys itself: Control-Command-F for full screen, Command-W to close.
final class SetupNSWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        switch (event.charactersIgnoringModifiers?.lowercased(), mods) {
        case ("f", [.control, .command]):
            toggleFullScreen(nil)
            return true
        case ("w", [.command]):
            performClose(nil)
            return true
        default:
            return super.performKeyEquivalent(with: event)
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
    /// Each part's height as laid out, for the window to fit itself to.
    var measured: (Part, CGFloat) -> Void = { _, _ in }

    enum Part { case content, footer }

    private var isDone: Bool { model.requiredDone }
    /// The sections are taller than the window shows: a line above the pinned buttons.
    @State private var overflows = false
    @State private var contentHeight: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
    @State private var showsBuildsExample = false
    @State private var showsProdExample = false
    @State private var showsProdSteps = false
    @State private var showsTokenSteps = false
    @ObservedObject private var auth = DatadogAuthModel.shared
    @ObservedObject private var effects = EffectsPrefs.shared
    /// The running notch's VPN (a placeholder that asks nothing in a setup preview).
    @ObservedObject private var vpn = SetupWindowController.shared.vpn ?? VPNStore()
    /// A team-signed build carries the widget and the app group it reads; an ad-hoc one neither.
    private let hasWidget: Bool = WidgetSnapshot.appGroup != nil
        && FileManager.default.fileExists(atPath: Bundle.main.bundleURL.appendingPathComponent("Contents/PlugIns/AINotchWidget.appex").path)

    /// The sections scroll (the window is at most the screen's visible height); the buttons stay
    /// pinned below them. The column keeps its width, centred, when the window is wider (full
    /// screen).
    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    content
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
                            contentHeight = height
                            measured(.content, height)
                        }
                        .frame(maxWidth: .infinity)
                }
                .scrollBounceBehavior(.basedOnSize)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { viewportHeight = $0 }
                .onAppear { scrollToFocus(proxy, animated: false) }
                .onChange(of: model.focusRequest) { scrollToFocus(proxy, animated: true) }
            }
            .onChange(of: contentHeight > viewportHeight + 1) { _, now in overflows = now }
            footer
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { measured(.footer, $0) }
        }
        .frame(minWidth: SetupWindowController.width, maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The section asked for, scrolled to the top of the window (after this layout pass, so it
    /// is laid out to scroll to).
    private func scrollToFocus(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let focus = model.focus else { return }
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo(focus, anchor: .top) }
            } else {
                proxy.scrollTo(focus, anchor: .top)
            }
        }
    }

    private var content: some View {
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
                if let codex = model.codex {
                    divider
                    row("Codex", icon: "chevron.left.forwardslash.chevron.right", tint: Color(red: 0.06, green: 0.55, blue: 0.42),
                        info: "Adds the hook to 10 Codex events, in ~/.codex/hooks.json: its turns, tools, subagents and permission prompts (answered in Codex, not the notch). Codex runs a new hook only once you trust it: in Codex, type /hooks and trust AI Notch's. A backup is saved first.") {
                        status(codex, done: "Connected", error: model.errors["codex"])
                    }
                }
                if let gemini = model.gemini {
                    divider
                    row("Gemini CLI", icon: "sparkles", tint: Color(red: 0.26, green: 0.52, blue: 0.96),
                        info: "Adds the hook to 7 Gemini CLI events, in ~/.gemini/settings.json: its turns, tools and the notification it raises when a tool waits for you. Not its model hooks, which run on every request. Your other settings stay as they are. A backup is saved first.") {
                        status(gemini, done: "Connected", error: model.errors["gemini"])
                    }
                }
                if let opencode = model.opencode {
                    divider
                    row("OpenCode", icon: "chevron.left.forwardslash.chevron.right", tint: Color(red: 0.20, green: 0.20, blue: 0.22),
                        info: "Adds a small plugin, ~/.config/opencode/plugins/ai-notch.js, that reports each OpenCode session (terminal, opencode serve or the desktop app) to the notch: working with its tool, waiting on a permission, idle. It only reports; nothing is answered or blocked. OpenCode loads it when it next starts. Disconnect removes it.") {
                        status(opencode, done: "Connected", error: model.errors["opencode"])
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
                row("Limit alerts", icon: "gauge.with.dots.needle.67percent", tint: Color(red: 0.96, green: 0.62, blue: 0.14),
                    info: "A notification, while unlocked too, when Claude's 5-hour or weekly limit passes 80% and again at 95%: when it resets and, from the last readings, when this pace runs out. Once per window and mark.") {
                    Toggle("", isOn: Binding(get: { model.limitAlertsOn }, set: { model.setLimitAlerts($0) }))
                        .toggleStyle(.switch).controlSize(.small).labelsHidden()
                }
                divider
                row("Jump to window", icon: "macwindow.on.rectangle", tint: Color(red: 0.25, green: 0.52, blue: 0.93),
                    info: "Accessibility access lets a click on a session raise its exact window. Without it, the app it runs in comes to the front.") {
                    optional(granted: model.accessibility, unavailable: false, denied: false,
                             wants: $model.wantsAccessibility, ask: model.askForAccessibility)
                }
                divider
                row("Other agents", icon: "cpu", tint: Color(red: 0.42, green: 0.45, blue: 0.52),
                    info: "Coding agents without hooks, found as processes: Aider, Goose, Amp, Factory Droid, Crush, GitHub Copilot CLI, OpenCode, Qwen Code, Kimi and others, and Codex or Gemini CLI where their hooks are not set up. Each shows as a row with its folder and the app it runs in; working or idle is read from its CPU. Add names in \(BuildsConfig.displayPath): \"agents\": {\"watch\": {\"mybot\": \"My Bot\"}, \"ignore\": [\"amp\"]}. Any agent or script can also report itself: ai-notch-hook report working --agent \"My Bot\" (see the README).") {
                    Toggle("", isOn: Binding(get: { model.watchAgents }, set: { model.setWatchAgents($0) }))
                        .toggleStyle(.switch).controlSize(.small).labelsHidden()
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

            effectsSection

            buildsSection

            prodSection
                .id(SetupFocus.prod)

            machineSection

            vpnSection
                .id(SetupFocus.vpn)

            if isDone {
                HStack(spacing: 10) {
                    NotchGlyph().frame(width: 34, height: 14)
                    Text("Hover the notch to see your sessions.").font(.system(size: 13, weight: .medium))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor.opacity(0.12)))
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 2)
        .frame(maxWidth: SetupWindowController.width)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Set Up / Done and the rest, always in view.
    private var footer: some View {
        VStack(spacing: 0) {
            Divider().opacity(overflows ? 1 : 0)
            buttons
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 20)
                .frame(maxWidth: SetupWindowController.width)
        }
    }

    private var buttons: some View {
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

    /// EAS builds and Bitbucket Pipelines in the notch: builds.json, each source's state, and
    /// the token steps.
    private var buildsSection: some View {
        section("Builds") {
            let config = model.buildsConfig
            row("Pipelines", icon: "hammer.fill", tint: Color(red: 0.55, green: 0.45, blue: 0.85), info: Self.configHelp) {
                Button(showsBuildsExample ? "Hide" : config.isSetUp ? "Example" : "How") {
                    showsBuildsExample.toggle()
                }
                .controlSize(.small)
                badge(config.text, symbol: config.ok ? "checkmark.circle.fill" : config.problems.isEmpty ? "circle.dashed" : "exclamationmark.circle.fill",
                      color: config.ok ? .green : config.problems.isEmpty ? .secondary : .orange)
                    .help(config.problems.isEmpty ? "" : "In \(BuildsConfig.displayPath): " + config.problems.joined(separator: "; "))
                    .lineLimit(1).fixedSize()
            }
            if showsBuildsExample { configSteps }
            if let eas = model.eas {
                divider
                row("EAS builds", icon: "shippingbox.fill", tint: Color(white: 0.2), info: eas.help) {
                    badge(eas.text, symbol: eas.ok ? "checkmark.circle.fill" : "circle.dashed", color: eas.ok ? .green : .secondary)
                }
            }
            if let bitbucket = model.bitbucket {
                divider
                row("Bitbucket Pipelines", icon: "arrow.triangle.branch", tint: Color(red: 0.15, green: 0.52, blue: 1.0), info: bitbucket.help) {
                    if bitbucket.needsSetup {
                        Button("Check Again", action: model.recheckBitbucket).controlSize(.small)
                    }
                    badge(bitbucket.text, symbol: bitbucket.ok ? "checkmark.circle.fill" : "circle.dashed", color: bitbucket.ok ? .green : .secondary)
                        .lineLimit(1).fixedSize()
                }
                if bitbucket.needsSetup { bitbucketSteps }
            }
            if let prs = model.pullRequests {
                divider
                pullRequestsRow(prs, stepsShown: model.bitbucket?.needsSetup == true)
            }
        }
    }

    static let bitbucketCommand = BitbucketConfig.saveCommand

    /// Pull requests: the switch, how they read (a missing scope in grey), which news notifies.
    @ViewBuilder
    private func pullRequestsRow(_ prs: PRSetupInfo, stepsShown: Bool) -> some View {
        row("Pull requests", icon: "arrow.triangle.pull", tint: Color(red: 0.15, green: 0.52, blue: 1.0), info: prs.help) {
            if let error = model.errors["prs"] {
                badge("Not saved", symbol: "exclamationmark.circle.fill", color: .orange).help(error)
            } else {
                badge(prs.text, symbol: prs.ok ? "checkmark.circle.fill" : "circle.dashed", color: prs.ok ? .green : .secondary)
                    .lineLimit(1).fixedSize()
            }
            Toggle("", isOn: Binding(get: { prs.on }, set: { model.setPullRequests($0) }))
                .toggleStyle(.switch).controlSize(.small).labelsHidden()
        }
        if prs.needsToken && !stepsShown {
            // A quiet hint: Pipelines works; pull requests wait for a token with the scope.
            HStack(spacing: 8) {
                Text("PRs need a new token.").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button(showsTokenSteps ? "Hide" : "How") { showsTokenSteps.toggle() }.controlSize(.small)
                Button("Check Again", action: model.recheckBitbucket).controlSize(.small)
            }
            .padding(.horizontal, 12).padding(.bottom, 8).padding(.leading, 32)
            if showsTokenSteps { bitbucketSteps }
        }
        if prs.on {
            divider
            row("Notify", icon: "bell.badge.fill", tint: Color(red: 0.90, green: 0.30, blue: 0.27),
                info: "Only while the screen is locked, once each: one of your pull requests approved, changes requested on it, new comments (grouped per pull request, at most every 10 minutes), a review asked of you, a failed build on yours (not when Pipelines already notified that run), one of yours merged or declined, and one of yours ready to merge (every merge check passes; once per commit). Right-click a row in the notch to mute a pull request.") {
                let notify = model.prNotify
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 10) {
                        Toggle("Approved", isOn: Binding(get: { notify.approved }, set: { var next = notify; next.approved = $0; model.setPRNotify(next) }))
                        Toggle("Changes", isOn: Binding(get: { notify.changes }, set: { var next = notify; next.changes = $0; model.setPRNotify(next) }))
                        Toggle("Comments", isOn: Binding(get: { notify.comments }, set: { var next = notify; next.comments = $0; model.setPRNotify(next) }))
                    }
                    HStack(spacing: 10) {
                        Toggle("Review requests", isOn: Binding(get: { notify.reviews }, set: { var next = notify; next.reviews = $0; model.setPRNotify(next) }))
                        Toggle("Failed builds", isOn: Binding(get: { notify.builds }, set: { var next = notify; next.builds = $0; model.setPRNotify(next) }))
                    }
                    HStack(spacing: 10) {
                        Toggle("Merged or declined", isOn: Binding(get: { notify.closed }, set: { var next = notify; next.closed = $0; model.setPRNotify(next) }))
                        Toggle("Ready to merge", isOn: Binding(get: { notify.ready }, set: { var next = notify; next.ready = $0; model.setPRNotify(next) }))
                    }
                }
                .toggleStyle(.checkbox).font(.system(size: 12)).fixedSize()
            }
            .padding(.vertical, 4)
        }
    }

    static let configHelp = """
    The Pipelines section shows EAS builds and Bitbucket Pipelines runs. It reads \(BuildsConfig.displayPath); with no file it stays hidden. Leave out a part you don't use.

    eas: account (the Expo account that owns the project), slug, projectId (extra.eas.projectId in the app config), and optionally cli, the path of an eas-cli 24 or later to fall back on. Sign in with `eas login`, or store an EXPO_TOKEN in the Keychain as \(EASConfig.tokenService).

    bitbucket: workspace, and repos as "name", "workspace/name" or {"workspace", "repo", "path"}. searchRoots adds every local clone under those folders (three levels deep) that has a bitbucket.org remote and a bitbucket-pipelines.yml.

    me (optional): {"emails": ["you@example.com"]}, the commit emails that make a run yours. Without it, your git user.email.

    AI Notch reads the file again within seconds of a change.
    """

    /// builds.json: an example to copy, and where it goes.
    private var configSteps: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Save as \(BuildsConfig.displayPath) with your own values. Leave out a part you don't use.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(BuildsConfig.example)
                .font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.07)))
            HStack(spacing: 8) {
                Text("searchRoots finds your Bitbucket clones.").font(.system(size: 11)).foregroundStyle(.secondary)
                InfoMark(text: Self.configHelp)
                Spacer(minLength: 0)
                CopyButton(text: BuildsConfig.example)
            }
        }
        .padding(.horizontal, 12).padding(.bottom, 10).padding(.leading, 32)
    }

    /// How to connect Bitbucket: a read-only token, stored in the Keychain.
    private var bitbucketSteps: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                Text("1. In Atlassian account settings → Security → API tokens, create an API token with scopes for Bitbucket: read:repository, read:pipeline, read:pullrequest and read:user (up to 365 days). A token cannot gain scopes later; a new one replaces the old.")
                Text("2. Paste this command into Terminal and put in the token's expiry date. Then copy the token and press Return: the command reads it from the clipboard and clears the clipboard. (Typing it at the `-w` prompt cuts it to 128 characters; these tokens are 192.)")
            }
            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(Self.bitbucketCommand)
                .font(.system(size: 10.5, design: .monospaced)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.07)))
            HStack(spacing: 8) {
                Text("3. Check Again (or open the notch). Nothing else to set.").font(.system(size: 11)).foregroundStyle(.secondary)
                InfoMark(text: "The token stays in your login Keychain (not synced) and is read with /usr/bin/security; it is never written to a file or a log. AI Notch warns 14 days before the date you give. To disconnect: security delete-generic-password -s \(BitbucketConfig.tokenService)")
                Spacer(minLength: 0)
                CopyButton(text: Self.bitbucketCommand)
            }
        }
        .padding(.horizontal, 12).padding(.bottom, 10).padding(.leading, 32)
    }

    /// Prod health from Datadog: its state, the steps to connect, and which news notifies.
    private var prodSection: some View {
        section("Prod", highlighted: model.focus == .prod) {
            let prod = model.prod
            row("Datadog", icon: "waveform.path.ecg", tint: Color(red: 0.39, green: 0.17, blue: 0.64), info: prod.help) {
                if prod.needsConfig {
                    Button(showsProdExample ? "Hide" : "How") { showsProdExample.toggle() }.controlSize(.small)
                }
                badge(prod.text, symbol: prod.ok ? "checkmark.circle.fill" : prod.text == "Key rejected" ? "exclamationmark.circle.fill" : "circle.dashed",
                      color: prod.ok ? .green : prod.text == "Key rejected" ? .orange : .secondary)
                    .lineLimit(1).fixedSize()
            }
            if prod.needsConfig && showsProdExample { prodConfigSteps }
            if !prod.needsConfig {
                signInRow
                if showsProdSteps && !isSignedIn { datadogSteps }
            }
            divider
            row("Agent analytics", icon: "chart.xyaxis.line", tint: Color(red: 0.39, green: 0.17, blue: 0.64), info: Self.telemetryHelp) {
                if let problem = model.telemetryProblem {
                    Text(problem).font(.system(size: 11)).foregroundStyle(.orange).lineLimit(2).frame(maxWidth: 220, alignment: .trailing)
                }
                Button(model.telemetryOn ? "Turn Off" : "Turn On…") { model.setTelemetry(!model.telemetryOn) }
                    .controlSize(.small)
                    .disabled(!model.telemetryOn && prod.needsConfig)
            }
            divider
            row("Datadog alerts", icon: "bell.badge.fill", tint: Color(red: 0.90, green: 0.30, blue: 0.27), info: Self.prodAlertsHelp) {
                EmptyView()
            }
            prodAlertsGroup
        }
    }

    static let hotkeysHelp = "⌃⌥Space opens or closes the notch. ⌃⌥J jumps to the session that needs you (one waiting first, else the one that finished last). While a prompt waits, ⌃⌥Y answers the oldest with Allow once (Approve plan for a plan) and ⌃⌥N with Deny (Keep planning); those two are taken only then. A shortcut another app already holds is left to it."

    static let telemetryHelp = "Sends Claude Code's own telemetry (sessions, tokens, cost, each tool call's name, outcome and time, how long prompts wait, API errors) to Datadog over OTLP, for Datadog's Agent Console and your own dashboards. Not your prompts, code or tool inputs. It needs a Datadog API key, kept in ~/.claude/notch/datadog-otlp.key (only you can read it) and handed over by AI Notch's hook; ~/.claude/settings.json gets the exporter settings, never the key. Sessions started after turning it on send it. Turn Off takes it all back out."

    static let prodAlertsHelp = "Datadog alerts notify even while you're at your Mac. Serious ones (a monitor alerting, an incident declared) also pop the notch open for about 6 s; Warn and recoveries only notify. Each news notifies once. Right-click the Prod chip to snooze everything for an hour."

    /// The alerts' checkboxes: what notifies, and how.
    private var prodAlertsGroup: some View {
        let prefs = model.prodAlerts
        func box(_ title: String, _ key: WritableKeyPath<ProdAlertPrefs, Bool>) -> some View {
            Toggle(title, isOn: Binding(get: { prefs[keyPath: key] }, set: { var next = prefs; next[keyPath: key] = $0; model.setProdAlerts(next) }))
        }
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 12) {
                box("Monitor alert", \.monitorAlert)
                box("Warn", \.monitorWarn)
                box("Recovered", \.recovered)
            }
            HStack(spacing: 12) {
                box("Incident declared", \.incidentDeclared)
                box("Incident changed", \.incidentChanged)
            }
            HStack(spacing: 12) {
                box("Incident resolved", \.incidentResolved)
                box("Error rate / latency", \.metrics)
            }
            Divider().padding(.vertical, 2)
            HStack(spacing: 12) {
                box("Pop open the notch", \.popOpen)
                box("Notify while unlocked", \.notifyUnlocked)
            }
            box("Remind every 2 h if still alerting", \.reminder)
        }
        .toggleStyle(.checkbox).font(.system(size: 12)).fixedSize()
        .padding(.horizontal, 12).padding(.bottom, 10).padding(.leading, 32)
    }

    /// builds.json's datadog part: an example to copy.
    private var prodConfigSteps: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Add this to \(BuildsConfig.displayPath) (inside its outer braces) with your own site, query and numbers.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(DatadogConfig.example)
                .font(.system(size: 9.5, design: .monospaced)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.07)))
            HStack(spacing: 8) {
                Text("monitors is the Manage Monitors search.").font(.system(size: 11)).foregroundStyle(.secondary)
                InfoMark(text: Self.prodConfigHelp)
                Spacer(minLength: 0)
                CopyButton(text: DatadogConfig.example)
            }
        }
        .padding(.horizontal, 12).padding(.bottom, 10).padding(.leading, 32)
    }

    static let prodConfigHelp = """
    site: your Datadog site (us1, us3, us5, eu, ap1, or its domain).

    monitors: a search as the Manage Monitors page takes it; AND, OR and parentheses work. Muted monitors count as OK.

    incidents: an incident search (default state:active); false leaves incidents out.

    health (optional, up to 3): numbers beside the chip. Each has a label, one query or named queries with a formula, an aggregator (avg by default), a unit (% or ms), a scale (1000 turns seconds into ms), amber (the chip turns amber above it, in the shown unit) and minutes (15 by default).

    Red comes only from a monitor in Alert or an active incident.
    """

    /// Sign in with Datadog: the button, the browser wait, who is signed in, and the keys as the
    /// other way in.
    private var signInRow: some View {
        let site = BuildsConfig.current?.datadog?.site ?? ""
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                switch auth.status {
                case .signedOut:
                    Button("Sign in with Datadog") { auth.signIn() }
                        .controlSize(.small).buttonStyle(.borderedProminent)
                    Text(site).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    InfoMark(text: "Opens Datadog's sign-in in your browser. Approve AI Notch there; it asks only to read monitors, incidents, metrics, traces and Watchdog events (monitors_read, incident_read, timeseries_query, apm_read, events_read). The tokens stay in your login Keychain (\(DatadogConfig.keyService), not synced) and renew by themselves for about 30 days.")
                    Spacer(minLength: 0)
                case .working(let text):
                    Image(systemName: "hourglass").foregroundStyle(.secondary)
                    Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("Cancel") { auth.cancel() }.controlSize(.small)
                case .waiting:
                    Image(systemName: "safari").foregroundStyle(.secondary)
                    Text("Waiting for the browser…").font(.system(size: 12))
                    InfoMark(text: "Approve AI Notch in the Datadog tab that opened. AI Notch waits 5 minutes for the answer on 127.0.0.1. Open Again shows the same page if you closed it.")
                    Spacer(minLength: 0)
                    Button("Open Again") { auth.reopen() }.controlSize(.small)
                    Button("Cancel") { auth.cancel() }.controlSize(.small)
                case .signedIn(let org, let tokenSite, let scopes, let expiry):
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Signed in\(org.map { " as \($0)" } ?? "")").font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
                        Text("Renews automatically").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    InfoMark(text: "\(tokenSite), scopes \(scopes.joined(separator: ", ")). The access token lasts an hour (this one until \(Self.clock.string(from: Date(timeIntervalSince1970: expiry)))) and renews itself; the sign-in lasts about 30 days, then asks again. Sign Out deletes the tokens from this Mac. \(DatadogOAuth.revokeHint)")
                    Spacer(minLength: 0)
                    Button("Sign Out") { auth.signOut() }.controlSize(.small)
                case .signInAgain(let why):
                    Image(systemName: "circle.dashed").foregroundStyle(.secondary)
                    Text("Sign in again").font(.system(size: 12)).foregroundStyle(.secondary)
                    InfoMark(text: why)
                    Spacer(minLength: 0)
                    Button("Sign In Again") { auth.signIn() }.controlSize(.small)
                }
            }
            if let note = auth.note {
                Text(note).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !isSignedIn {
                Button {
                    showsProdSteps.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showsProdSteps ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                        Text("Or use service-account keys")
                    }
                    .font(.system(size: 11)).foregroundStyle(.secondary).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.bottom, 10).padding(.leading, 32)
    }

    /// Signed in: no keys needed.
    private var isSignedIn: Bool {
        if case .signedIn = auth.status { return true }
        return false
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }()

    /// How to connect Datadog: an admin makes a service account and its keys; you store them.
    private var datadogSteps: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                Text("A Datadog admin:")
                ForEach(Array(DatadogConfig.adminSteps.enumerated()), id: \.offset) { index, step in
                    Text("\(index + 1). \(step)")
                }
                Text("Then copy each key and run its command; it reads the key from the clipboard and clears it.")
            }
            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach([DatadogConfig.apiKeyAccount, DatadogConfig.appKeyAccount], id: \.self) { account in
                HStack(alignment: .top, spacing: 8) {
                    Text(DatadogConfig.saveCommand(account))
                        .font(.system(size: 10.5, design: .monospaced)).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.07)))
                    CopyButton(text: DatadogConfig.saveCommand(account))
                }
            }
            HStack(spacing: 8) {
                Button("Check Again") { SetupWindowController.shared.prod?.recheck() }.controlSize(.small)
                InfoMark(text: "Both keys stay in your login Keychain (not synced) and are read with /usr/bin/security; they go only into the request headers, never to a file or a log. The application key needs only monitors_read, incident_read, timeseries_query, apm_read and events_read. Typing a key at the interactive -w prompt keeps only its first 128 characters, so the commands read the clipboard. To disconnect: security delete-generic-password -s \(DatadogConfig.keyService) -a \(DatadogConfig.apiKeyAccount), and again with -a \(DatadogConfig.appKeyAccount).")
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 12).padding(.bottom, 10).padding(.leading, 32)
    }

    /// The machine guard: on or off, which news notifies, and the optional settings.
    private var machineSection: some View {
        section("Machine") {
            row("Dev machine guard", icon: "memorychip", tint: Color(red: 0.16, green: 0.55, blue: 0.45), info: Self.machineHelp) {
                Toggle("", isOn: Binding(get: { model.machineOn }, set: { model.setMachineOn($0) }))
                    .toggleStyle(.switch).controlSize(.small).labelsHidden()
            }
            divider
            row("Notify", icon: "bell.badge.fill", tint: Color(red: 0.90, green: 0.30, blue: 0.27),
                info: "Only while the screen is locked: memory critical (under 2 GB available, or the kernel's critical pressure) for 30 seconds, naming the biggest dev process. Its one action opens the Machine panel; nothing is closed from a notification. It comes again only after 10 minutes back at normal.") {
                Toggle("Memory critical", isOn: Binding(get: { model.machineNotify }, set: { model.setMachineNotify($0) }))
                    .toggleStyle(.checkbox).font(.system(size: 12)).fixedSize()
                    .disabled(!model.machineOn)
            }
            divider
            row("Background commands", icon: "terminal", tint: Color(red: 0.35, green: 0.38, blue: 0.45), info: CommandsPanel.about) {
                Toggle("", isOn: Binding(get: { model.commandsOn }, set: { model.setCommandsOn($0) }))
                    .toggleStyle(.switch).controlSize(.small).labelsHidden()
            }
        }
    }

    static let machineHelp = """
    The footer's RAM chip and the Machine panel: free memory, and the dev processes holding it (Metro, Jest, make verify, turbo, the Android emulator, the iOS Simulator, Gradle and Kotlin daemons, adb, watchman), each with its footprint and whether it is idle. Close sends SIGTERM, and Force quit (a second click) SIGKILL only if it is still running 5 s later. Close idle never includes the emulator or the Simulator. Editors, terminals, shells, Claude Code, Codex and Cursor's agent are never touched.

    Optional, in \(BuildsConfig.displayPath):
    \(MachineConfig.example)
    warnBelowMB: amber under this much free memory. idleMinutes: quiet this long counts as idle. exclude: kinds never shown (metro, jest, verify, turbo, emulator, simulator, simulatorApp, gradle, kotlin, adb, watchman).
    """

    /// The light effects around the closed notch (NotchEffects): the style and when it plays.
    private var effectsSection: some View {
        section("Effects") {
            row("Keyboard shortcuts", icon: "keyboard", tint: Color(red: 0.35, green: 0.38, blue: 0.45), info: Self.hotkeysHelp) {
                Toggle("", isOn: Binding(get: { model.hotkeysOn }, set: { model.setHotkeys($0) }))
                    .toggleStyle(.switch).controlSize(.small).labelsHidden()
            }
            divider
            row("Style", icon: "sparkles", tint: Color(red: 0.93, green: 0.36, blue: 0.62),
                info: "Light around the closed notch. Scanner: a light running to and fro along its edge, in the working agent's colour. Neon: its edge in a turning rainbow. Lights: coloured bulbs under it, twinkling. Aurora: green, teal and violet light drifting under it. A session waiting on you shows the amber glow instead. Drawn by Core Animation at 30 fps at most, like the spinner.") {
                Picker("", selection: $effects.style) {
                    ForEach(EffectsPrefs.Style.allCases) { style in Text(style.title).tag(style) }
                }
                .labelsHidden().pickerStyle(.menu).fixedSize()
            }
            divider
            row("Only while working", icon: "bolt.fill", tint: Color(red: 0.96, green: 0.62, blue: 0.14),
                info: "On: the style plays while an agent works, a subagent runs or a pipeline runs. Off: whenever the notch is closed.") {
                Toggle("", isOn: $effects.onlyWhileWorking).toggleStyle(.switch).controlSize(.small).labelsHidden()
                    .disabled(effects.style == .off)
            }
            divider
            row("Pointer glow", icon: "cursorarrow.motionlines", tint: Color(red: 0.40, green: 0.55, blue: 0.95),
                info: "A soft light under the closed notch where the pointer is, brighter as it comes nearer (within 100 points).") {
                Toggle("", isOn: $effects.pointerGlow).toggleStyle(.switch).controlSize(.small).labelsHidden()
            }
            divider
            row("Sparkles when done", icon: "party.popper.fill", tint: Color(red: 0.30, green: 0.76, blue: 0.54),
                info: "A burst of coloured sparks from the notch when an agent finishes a turn.") {
                Toggle("", isOn: $effects.sparkles).toggleStyle(.switch).controlSize(.small).labelsHidden()
            }
            divider
            row("Compact rows", icon: "rectangle.compress.vertical", tint: Color(red: 0.42, green: 0.45, blue: 0.52),
                info: "Denser session rows: the project and model line goes and the agent's name moves up beside the title, so eight rows fit before the list scrolls instead of six.") {
                Toggle("", isOn: $effects.compactRows).toggleStyle(.switch).controlSize(.small).labelsHidden()
            }
            divider
            row("Keep the Mac awake while an agent works", icon: "moon.zzz.fill", tint: Color(red: 0.36, green: 0.40, blue: 0.80),
                info: "Stops the Mac sleeping on its own while an agent works and for 2 minutes after the last one stops, so a turn goes on with the screen locked. The display may still sleep. Shown as \"AI Notch: an agent is working\" in pmset -g assertions. Closing the lid still sleeps the Mac unless a display is attached.") {
                Toggle("", isOn: $effects.keepAwake).toggleStyle(.switch).controlSize(.small).labelsHidden()
            }
            divider
            row("Also on battery", icon: "battery.50percent", tint: Color(red: 0.42, green: 0.45, blue: 0.52),
                info: "Keeps the Mac awake on battery too, but lets go below 20% charge.") {
                Toggle("", isOn: $effects.keepAwakeOnBattery).toggleStyle(.switch).controlSize(.small).labelsHidden()
                    .disabled(!effects.keepAwake)
            }
        }
    }

    /// The VPN: its helper (install, update, remove), the chip, the drop notification, profiles.
    private var vpnSection: some View {
        section("VPN", highlighted: model.focus == .vpn) {
            row("OpenVPN helper", icon: "lock.shield.fill", tint: Color(red: 0.22, green: 0.52, blue: 0.88), info: Self.vpnHelp) {
                vpnHelperControl
            }
            divider
            row("Show in the notch", icon: "rectangle.topthird.inset.filled", tint: Color(red: 0.36, green: 0.42, blue: 0.52),
                info: "The VPN chip in the footer and the VPN panel. Off, both are hidden; a connection keeps running.") {
                Toggle("", isOn: Binding(get: { vpn.isOn }, set: { vpn.setEnabled($0) }))
                    .toggleStyle(.switch).controlSize(.small).labelsHidden()
            }
            divider
            row("Notify", icon: "bell.badge.fill", tint: Color(red: 0.90, green: 0.30, blue: 0.27),
                info: "When a connection that was up ends without Disconnect (the network went away, the server ended it). Also while the screen is unlocked: traffic has stopped going through the VPN. Its one action opens the VPN panel.") {
                Toggle("Connection dropped", isOn: Binding(get: { vpn.notifyDrop }, set: { vpn.setNotify($0) }))
                    .toggleStyle(.checkbox).font(.system(size: 12)).fixedSize()
            }
            if vpn.helper == .running {
                ForEach(vpn.profiles) { profile in
                    divider
                    row(profile.name, icon: "network", tint: Color(red: 0.30, green: 0.60, blue: 0.55),
                        info: profile.servers.joined(separator: ", ") + (profile.asksPassword ? ". Asks for a username and password." : "")) {
                        Button("Delete") { vpn.delete(profile.id) }
                            .controlSize(.small)
                            .disabled(vpn.session?.profileId == profile.id)
                            .help(vpn.session?.profileId == profile.id ? "Disconnect it first." : "Deletes the helper's copy and a saved password.")
                    }
                }
                divider
                HStack {
                    Text(vpn.profiles.isEmpty ? "No profiles yet." : "\(vpn.profiles.count) profile\(vpn.profiles.count == 1 ? "" : "s")")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Import Profile…") { vpn.importProfile() }.controlSize(.small)
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 36)
            }
            if let note = vpn.note {
                Text(note).font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.bottom, 8)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var vpnHelperControl: some View {
        if let working = vpn.working {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(working).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        } else {
            switch vpn.helper {
            case .unknown:
                Text("—").font(.system(size: 12)).foregroundStyle(.secondary)
            case .notInstalled:
                if VPNStore.hasBundledEngine {
                    Button("Install…") { vpn.install() }.controlSize(.small)
                } else {
                    Text("Not in this build").font(.system(size: 12)).foregroundStyle(.secondary)
                        .help("This copy of AI Notch was built without OpenVPN. Run scripts/build-openvpn.sh, then assemble the app again (see the README).")
                }
            case .notRunning:
                HStack(spacing: 8) {
                    badge("Not running", symbol: "exclamationmark.circle.fill", color: .orange)
                    if VPNStore.hasBundledEngine { Button("Reinstall…") { vpn.install() }.controlSize(.small) }
                    vpnRemoveMenu
                }
            case .running:
                HStack(spacing: 8) {
                    if vpn.needsUpdate {
                        Button("Update…") { vpn.install() }.controlSize(.small)
                    } else {
                        badge("Installed", symbol: "checkmark.circle.fill", color: .green)
                    }
                    vpnRemoveMenu
                }
            }
        }
    }

    private var vpnRemoveMenu: some View {
        Menu("Remove") {
            Button("Remove, Keep Profiles") { vpn.uninstall(keepProfiles: true) }
            Button("Remove with Profiles") { vpn.uninstall(keepProfiles: false) }
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .fixedSize()
    }

    static let vpnHelp = """
    An OpenVPN client in the notch, with nothing else to install. Install asks for your admin password once: it copies AI Notch's helper and OpenVPN \(VPNBuild.openvpnVersion) to \(VPNPaths.installDir) (only root can change them there) and starts the helper as a launch daemon, which runs OpenVPN for you and answers only your user.

    Profiles are .ovpn files. Each is checked when imported and refused if it would run a program, load code, or read or write a file by path (OpenVPN runs as root); certificates and keys must be inline. Windows-only lines are left out. DNS is set by OpenVPN's own macOS script. Passwords are asked in a small window and, if you choose, kept in your login Keychain.

    The helper's log: \(VPNPaths.log). Remove takes the helper, OpenVPN and (unless kept) the profiles away.
    """

    private var divider: some View { Divider().padding(.leading, 44) }

    private func section<Content: View>(_ title: String, highlighted: Bool = false, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(highlighted ? Color.accentColor : .secondary).padding(.leading, 4)
            VStack(spacing: 0) { content() }
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(highlighted ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: highlighted ? 2 : 1))
                .animation(.easeOut(duration: 0.3), value: highlighted)
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
