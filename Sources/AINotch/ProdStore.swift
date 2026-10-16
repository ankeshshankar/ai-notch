import AppKit
import Foundation

/// Prod health for the notch: the footer's Prod chip, the corner dot, the ⚠ in the wing, the
/// alert banner and the notifications. Fetching happens in `DatadogSource`, off the main thread;
/// this only takes its snapshots, publishes when what shows changed, and runs apart from the
/// build sources, so a failure in one never stalls the other. What changed between snapshots, and
/// how it is told, is `ProdAlertEngine` and `ProdAlertPlanner` (ProdAlerts.swift).
@MainActor
final class ProdStore: ObservableObject {
    /// The chip's colour: grey (not connected, keys rejected, no answer yet or for 10 minutes),
    /// green, amber (a monitor warns, or a number is over its line), red (a monitor alerts, or
    /// an incident is active). Auth problems are grey, never red.
    enum Level: Int, Comparable {
        case unknown, ok, warn, alert
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    /// Setup's older three switches, kept for its Notify row: a view onto `alertPrefs`.
    /// `alerts` is a monitor going to Alert, `incidents` all three incident kinds, `recoveries`
    /// a monitor back to OK.
    struct NotifyPrefs: Equatable {
        var alerts = true
        var incidents = true
        var recoveries = true

        init(alerts: Bool = true, incidents: Bool = true, recoveries: Bool = true) {
            self.alerts = alerts
            self.incidents = incidents
            self.recoveries = recoveries
        }

        init(_ prefs: ProdAlertPrefs) {
            alerts = prefs.monitorAlert
            incidents = prefs.incidentDeclared || prefs.incidentChanged || prefs.incidentResolved
            recoveries = prefs.recovered
        }

        func apply(to prefs: inout ProdAlertPrefs) {
            prefs.monitorAlert = alerts
            if incidents != NotifyPrefs(prefs).incidents {
                prefs.incidentDeclared = incidents
                prefs.incidentChanged = incidents
                prefs.incidentResolved = incidents
            }
            prefs.recovered = recoveries
        }

        static func load() -> NotifyPrefs { NotifyPrefs(ProdAlertPrefs.load()) }

        func save() {
            var prefs = ProdAlertPrefs.load()
            apply(to: &prefs)
            prefs.save()
        }
    }

    @Published private(set) var snapshot = ProdSnapshot()
    /// builds.json has a `datadog` part: the chip shows.
    @Published private(set) var isOn = false
    /// Alerts and incidents that started since the notch was last looked at, still open.
    @Published private(set) var unseen: Set<String> = []
    @Published private(set) var snoozedUntil: Double
    /// Which Datadog news notifies and pops the notch open (Setup's checkboxes).
    @Published private(set) var alertPrefs = ProdAlertPrefs.load()
    /// The banner the notch drops for alert-level news, for `headsUpFor` seconds (longer while
    /// the pointer is on it).
    @Published private(set) var headsUp: ProdHeadsUp?
    /// Moves with the clock: the snooze ending, data going stale.
    @Published private(set) var now = Date().timeIntervalSince1970

    static let snoozeFor: Double = 3600
    /// No monitor answer for this long: grey again.
    static let staleAfter: Double = 600
    static let headsUpFor: Double = 6
    private static let snoozeKey = "prod.snoozedUntil"

    /// Why the banner may not drop now ("full screen"), or nil; the notch controller answers.
    var popBlocker: (() -> String?)?

    private var source: DatadogSource?
    private var engine = ProdAlertEngine()
    private var trackedFor = ""
    private var isLooking = false
    private var timer: Timer?
    private var headsUpCount = 0
    private var headsUpHovered = false
    private var headsUpEnd: DispatchWorkItem?

    init() {
        snoozedUntil = UserDefaults.standard.double(forKey: Self.snoozeKey)
    }

    func start() {
        Notifier.shared.onProdSnooze = { [weak self] in self?.snooze() }
        startConfigured()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.startConfigured()
                let now = Date().timeIntervalSince1970
                // Only what shows moves: a snooze ending, or the data turning stale.
                let wasSnoozed = self.snoozedUntil > self.now, isSnoozed = self.snoozedUntil > now
                let wasStale = self.now - self.snapshot.monitorsAt >= Self.staleAfter
                let isStale = now - self.snapshot.monitorsAt >= Self.staleAfter
                if wasSnoozed != isSnoozed || wasStale != isStale || now - self.now >= 30 { self.now = now }
            }
        }
    }

    /// The source starts once builds.json has a `datadog` part (checked every few seconds, so a
    /// file written while the app runs takes effect without a restart); it idles without one.
    private func startConfigured() {
        let on = BuildsConfig.current?.datadog != nil
        if on != isOn { isOn = on }
        guard on, source == nil else { return }
        let source = DatadogSource { [weak self] snapshot in
            Task { @MainActor in self?.take(snapshot) }
        }
        self.source = source
        Task { await source.start() }
    }

    /// Setup's Check Again.
    func recheck() {
        BuildsConfig.reload()
        startConfigured()
        if let source { Task { await source.recheck() } }
    }

    // MARK: What shows

    var isSnoozed: Bool { snoozedUntil > now }

    var level: Level {
        guard snapshot.access == .ok, snapshot.monitorsAt > 0, now - snapshot.monitorsAt < Self.staleAfter else { return .unknown }
        if snapshot.alertCount > 0 || !snapshot.incidents.isEmpty { return .alert }
        if snapshot.warnCount > 0 || snapshot.numbers.contains(where: \.isOver) { return .warn }
        return .ok
    }

    /// The corner dot: a monitor alerting or an incident open, not snoozed.
    var hasOpenAlert: Bool { isOn && !isSnoozed && level == .alert }
    /// The wing's ⚠: one of those that started since the notch was last looked at.
    var hasUnseenAlert: Bool { isOn && !isSnoozed && !unseen.isEmpty }

    var alertingMonitors: [ProdMonitor] { snapshot.monitors.filter { $0.status == "Alert" } }

    /// The chip's click: the one alerting monitor or incident, else the filtered monitor list.
    var clickURL: URL? {
        let site = snapshot.site
        let monitors = alertingMonitors
        if monitors.count + snapshot.incidents.count == 1 {
            if let monitor = monitors.first { return DatadogConfig.monitorURL(site: site, id: monitor.id) }
            if let incident = snapshot.incidents.first { return DatadogConfig.incidentURL(site: site, incident: incident) }
        }
        return DatadogConfig.monitorsListURL(site: site, query: snapshot.monitorQuery)
    }

    /// What grey means, in a few words.
    var greyReason: String? {
        switch snapshot.access {
        case .notConfigured: return "Not set up"
        case .noKeys: return "Not connected"
        case .signInAgain: return "Sign in again"
        case .rejected: return snapshot.viaSignIn ? "Refused" : "Key rejected"
        case .ok:
            if snapshot.monitorsAt == 0 { return snapshot.problem?.text.capitalizedFirst ?? "Checking…" }
            if now - snapshot.monitorsAt >= Self.staleAfter { return "No answer since \(ago(now - snapshot.monitorsAt))" }
            return nil
        }
    }

    // MARK: Actions

    func open() {
        if snapshot.access != .ok {
            // Not connected, the sign-in ended, refused: Setup, at its Prod section.
            SetupWindowController.shared.show(focus: .prod)
        } else if let url = clickURL {
            NSWorkspace.shared.open(url)
        }
    }

    func snooze() {
        setSnooze(Date().timeIntervalSince1970 + Self.snoozeFor)
        dismissHeadsUp()
    }

    func unsnooze() {
        setSnooze(0)
    }

    private func setSnooze(_ until: Double) {
        snoozedUntil = until
        UserDefaults.standard.set(until, forKey: Self.snoozeKey)
        now = Date().timeIntervalSince1970
        noteBuildLog(until > 0 ? "prod: snoozed for an hour" : "prod: snooze ended")
    }

    /// Setup's checkboxes: every switch at once.
    func setAlertPrefs(_ prefs: ProdAlertPrefs) {
        guard prefs != alertPrefs else { return }
        alertPrefs = prefs
        prefs.save()
        if !prefs.popOpen { dismissHeadsUp() }
    }

    /// Setup's older Notify row (Alerts, Incidents, Recoveries).
    var notify: NotifyPrefs { NotifyPrefs(alertPrefs) }

    func setNotify(_ prefs: NotifyPrefs) {
        var next = alertPrefs
        prefs.apply(to: &next)
        setAlertPrefs(next)
    }

    /// The pointer is over the open notch (or left it): what is open counts as seen.
    func setLooking(_ looking: Bool) {
        isLooking = looking
        if looking, !unseen.isEmpty { unseen = [] }
    }

    // MARK: The banner

    /// The banner's Open: the monitor or incident, else the filtered list.
    func openHeadsUp() {
        if let url = headsUp?.url ?? clickURL { NSWorkspace.shared.open(url) }
        if let keys = headsUp?.keys { unseen.subtract(keys) }
        dismissHeadsUp()
    }

    func dismissHeadsUp() {
        headsUpEnd?.cancel()
        headsUpEnd = nil
        headsUpHovered = false
        if headsUp != nil { headsUp = nil }
    }

    /// The pointer is on the banner: it stays; once it leaves, it goes after a short grace.
    func setHeadsUpHovered(_ hovered: Bool) {
        guard headsUp != nil, hovered != headsUpHovered else { return }
        headsUpHovered = hovered
        if hovered {
            headsUpEnd?.cancel()
            headsUpEnd = nil
        } else {
            endHeadsUp(after: 1.5)
        }
    }

    private func showHeadsUp(_ next: ProdHeadsUp) {
        headsUpCount += 1
        var banner = next
        banner.id = headsUpCount
        headsUp = banner
        endHeadsUp(after: Self.headsUpFor)
    }

    private func endHeadsUp(after seconds: Double) {
        headsUpEnd?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.headsUpHovered else { return }
                self.headsUpEnd = nil
                if self.headsUp != nil { self.headsUp = nil }
            }
        }
        headsUpEnd = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    // MARK: Snapshots

    private func take(_ next: ProdSnapshot) {
        now = Date().timeIntervalSince1970
        // Another site or query: the next answer is history again.
        let identity = next.site + "|" + next.monitorQuery
        if identity != trackedFor {
            trackedFor = identity
            engine.reset()
            unseen = []
        }
        if next != snapshot { snapshot = next }
        let events = engine.take(next, now: now, reminders: alertPrefs.reminder)
        // The log gets kinds and ids only, never a monitor's or an incident's name.
        for event in events {
            noteBuildLog("prod: \(event.kind.rawValue) (\(event.key))")
            if event.popsOpen, !isLooking { unseen.insert(event.key) }
        }
        deliver(events, site: next.site, query: next.monitorQuery)
        // Only what is still open stays unseen.
        let kept = unseen.intersection(engine.openKeys)
        if kept != unseen { unseen = kept }
    }

    /// One poll's news: one notification (even while the screen is unlocked, unless turned off)
    /// and, for alert-level news, the banner, unless snoozed or a full-screen app is in front.
    private func deliver(_ events: [ProdAlertEvent], site: String, query: String) {
        guard !events.isEmpty else { return }
        let popBlocked = alertPrefs.popOpen && events.contains(where: \.popsOpen) ? popBlocker?() : nil
        let plan = ProdAlertPlanner.plan(events, prefs: alertPrefs, snoozed: isSnoozed, locked: Notifier.shared.isScreenLocked,
                                         popBlocked: popBlocked, listURL: DatadogConfig.monitorsListURL(site: site, query: query))
        if !plan.held.isEmpty { noteBuildLog("prod: held back (\(plan.held.joined(separator: ", ")))") }
        if let notice = plan.notice { Notifier.shared.postProd(notice) }
        if let banner = plan.headsUp {
            showHeadsUp(banner)
            noteBuildLog("prod: banner (\(banner.keys.joined(separator: ",")))")
        }
    }

    /// "SEV-2 · #123 Checkout errors".
    static func incidentLine(_ incident: ProdIncident) -> String { ProdAlertEngine.incidentLine(incident) }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
