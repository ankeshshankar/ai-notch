import AppKit
import Foundation

// Datadog alerts: what changed between two Prod snapshots, and how it is told. Pure parts only
// (no clock, no screen, no notification center), so `--prod-alerts-selfcheck` runs them on made-up
// snapshots. ProdStore feeds the engine each snapshot and delivers the plan.
//
// - Monitors: to Alert, to Warn, back to OK from either (No Data is list-only: no event). A monitor
//   that changes state 3 times in 15 minutes, going back into a state it had left (OK → Alert →
//   OK → Alert, Warn → Alert → Warn → Alert), is "flapping": one notice, then 30 minutes of quiet,
//   after which a state different from the one the notice named is told once. A one-way episode
//   (OK → Warn → Alert → OK) is told change by change.
// - Incidents: declared, severity changed (escalated when the number drops), resolved.
// - Numbers: over their `amber` line for 2 polls in a row, then under it for 2 polls.
// - The first answer of each kind after launch (or a change of site or query) is history.
// - All the news of one poll goes out as one notification.

/// Which Datadog news notifies and pops the notch open. Setup's checkboxes; kept in
/// UserDefaults (`prod.alerts`, JSON). A key missing from a stored copy takes its default.
struct ProdAlertPrefs: Codable, Equatable, Sendable {
    /// A monitor going to Alert (pops the notch open).
    var monitorAlert = true
    /// A monitor going to Warn (notification only).
    var monitorWarn = true
    /// A monitor back to OK from Alert or Warn (notification only).
    var recovered = true
    /// An incident declared (pops the notch open).
    var incidentDeclared = true
    /// An incident's severity changed (an escalation pops the notch open).
    var incidentChanged = true
    /// An incident resolved (notification only).
    var incidentResolved = true
    /// A health number crossing its line, up (pops open) and back down.
    var metrics = true
    /// Alert-level news drops a banner from the notch for a few seconds.
    var popOpen = true
    /// Datadog news notifies while the screen is unlocked too (the other sources only when locked).
    var notifyUnlocked = true
    /// A monitor still alerting is told again every 2 hours.
    var reminder = false

    static let defaultsKey = "prod.alerts"
    /// The three switches before these: `alerts`, `incidents`, `recoveries`.
    static let legacyKey = "prod.notify"

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ProdAlertPrefs()
        monitorAlert = try c.decodeIfPresent(Bool.self, forKey: .monitorAlert) ?? d.monitorAlert
        monitorWarn = try c.decodeIfPresent(Bool.self, forKey: .monitorWarn) ?? d.monitorWarn
        recovered = try c.decodeIfPresent(Bool.self, forKey: .recovered) ?? d.recovered
        incidentDeclared = try c.decodeIfPresent(Bool.self, forKey: .incidentDeclared) ?? d.incidentDeclared
        incidentChanged = try c.decodeIfPresent(Bool.self, forKey: .incidentChanged) ?? d.incidentChanged
        incidentResolved = try c.decodeIfPresent(Bool.self, forKey: .incidentResolved) ?? d.incidentResolved
        metrics = try c.decodeIfPresent(Bool.self, forKey: .metrics) ?? d.metrics
        popOpen = try c.decodeIfPresent(Bool.self, forKey: .popOpen) ?? d.popOpen
        notifyUnlocked = try c.decodeIfPresent(Bool.self, forKey: .notifyUnlocked) ?? d.notifyUnlocked
        reminder = try c.decodeIfPresent(Bool.self, forKey: .reminder) ?? d.reminder
    }

    static func load(_ defaults: UserDefaults = .standard) -> ProdAlertPrefs {
        if let data = defaults.data(forKey: defaultsKey), let prefs = try? JSONDecoder().decode(ProdAlertPrefs.self, from: data) {
            return prefs
        }
        // From the older switches, only a choice to turn something off carries over.
        var prefs = ProdAlertPrefs()
        if let old = defaults.dictionary(forKey: legacyKey) {
            if old["alerts"] as? Bool == false { prefs.monitorAlert = false }
            if old["incidents"] as? Bool == false {
                prefs.incidentDeclared = false
                prefs.incidentChanged = false
                prefs.incidentResolved = false
            }
        }
        return prefs
    }

    func save(_ defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    func allows(_ kind: ProdAlertEvent.Kind) -> Bool {
        switch kind {
        case .monitorAlert: return monitorAlert
        case .monitorWarn: return monitorWarn
        case .monitorRecovered: return recovered
        case .monitorFlapping: return monitorAlert || monitorWarn || recovered
        case .monitorReminder: return reminder && monitorAlert
        case .incidentDeclared: return incidentDeclared
        case .incidentChanged: return incidentChanged
        case .incidentResolved: return incidentResolved
        case .metricOver, .metricNormal: return metrics
        }
    }
}

/// One change in prod. `name` and `detail` are for the notification and the banner only, never
/// for the log (which gets `kind` and `key`).
struct ProdAlertEvent: Equatable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case monitorAlert, monitorWarn, monitorRecovered, monitorFlapping, monitorReminder
        case incidentDeclared, incidentChanged, incidentResolved
        case metricOver, metricNormal
    }

    var kind: Kind
    /// "m:<monitor id>", "i:<incident id>", "n:<number label>".
    var key: String
    var name: String
    var detail: String = ""
    var url: URL?
    /// An incident's severity got worse.
    var escalated = false

    /// Alert-level: drops the banner from the notch. Warn, recoveries, flapping and reminders
    /// only notify.
    var popsOpen: Bool {
        switch kind {
        case .monitorAlert, .incidentDeclared, .metricOver: return true
        case .incidentChanged: return escalated
        default: return false
        }
    }
}

/// The diff between successive snapshots, with its memory: what was open, how often each monitor
/// changed lately, and each number's streak.
struct ProdAlertEngine {
    static let flapWindow: Double = 15 * 60
    static let flapChanges = 3
    static let flapQuiet: Double = 30 * 60
    static let remindEvery: Double = 2 * 3600
    /// Polls in a row over (or under) a number's line before it counts.
    static let streak = 2

    private struct Metric {
        var over = 0
        var under = 0
        var alerted: Bool
    }

    private(set) var monitorsPrimed = false
    private var monitorsAt: Double = 0
    /// Monitors not OK: Alert, Warn, No Data.
    private var status: [Int64: String] = [:]
    private var names: [Int64: String] = [:]
    /// Each monitor's recent changes: when, and the state it went into.
    private var changes: [Int64: [(at: Double, to: String)]] = [:]
    private var quietUntil: [Int64: Double] = [:]
    /// The state a flapping notice named, told again if it differs when the quiet ends.
    private var flapStatus: [Int64: String] = [:]
    private var alertToldAt: [Int64: Double] = [:]
    private(set) var incidentsPrimed = false
    private var incidentsAt: Double = 0
    private var incidents: [String: ProdIncident] = [:]
    private var numbersAt: Double = 0
    private var metrics: [String: Metric] = [:]

    /// Another site or query: the next answer is history again.
    mutating func reset() { self = ProdAlertEngine() }

    /// What is open now: alerting monitors, incidents, numbers over their line.
    var openKeys: Set<String> {
        var keys = Set(status.filter { $0.value == "Alert" }.map { "m:\($0.key)" })
        keys.formUnion(incidents.keys.map { "i:\($0)" })
        keys.formUnion(metrics.filter(\.value.alerted).map { "n:\($0.key)" })
        return keys
    }

    /// The changes in `snapshot` since the last one. A snapshot that is not a live answer (keys
    /// refused, not connected) changes nothing: a grey chip is not a recovery.
    mutating func take(_ snapshot: ProdSnapshot, now: Double, reminders: Bool = false) -> [ProdAlertEvent] {
        guard snapshot.access == .ok else { return [] }
        var events: [ProdAlertEvent] = []
        if snapshot.monitorsAt > monitorsAt {
            monitorsAt = snapshot.monitorsAt
            events += monitorsChanged(snapshot, now: now, reminders: reminders)
        }
        if !snapshot.incidentsOn {
            incidentsPrimed = false
            incidents = [:]
            incidentsAt = 0
        } else if snapshot.incidentsAt > incidentsAt {
            incidentsAt = snapshot.incidentsAt
            events += incidentsChanged(snapshot)
        }
        if snapshot.numbersAt > numbersAt {
            numbersAt = snapshot.numbersAt
            events += numbersChanged(snapshot)
        }
        return events
    }

    // MARK: Monitors

    private mutating func monitorsChanged(_ s: ProdSnapshot, now: Double, reminders: Bool) -> [ProdAlertEvent] {
        let current = Dictionary(s.monitors.map { ($0.id, $0.status) }, uniquingKeysWith: { a, _ in a })
        for monitor in s.monitors { names[monitor.id] = monitor.name }
        guard monitorsPrimed else {
            monitorsPrimed = true
            status = current
            for (id, state) in current where state == "Alert" { alertToldAt[id] = now }
            return []
        }
        // The page holds the first 100 monitors; when the facets count more not-OK ones than it
        // lists, one missing from it may still alert, so it keeps its state.
        let notOK = ["Alert", "Warn", "No Data"].reduce(0) { $0 + (s.statusCounts[$1] ?? 0) }
        let complete = s.statusCounts.isEmpty || s.monitors.count >= notOK
        var events: [ProdAlertEvent] = []
        for id in Set(status.keys).union(current.keys).sorted() {
            let old = status[id] ?? "OK"
            let new = current[id] ?? (complete ? "OK" : old)
            guard new != old else { continue }
            status[id] = new == "OK" ? nil : new
            guard let kind = Self.monitorKind(from: old, to: new) else { continue }
            var recent = (changes[id] ?? []).filter { now - $0.at < Self.flapWindow }
            recent.append((now, new))
            changes[id] = recent
            if let until = quietUntil[id] {
                if now < until { continue }
                // The quiet is over and it changed again: told as any change.
                quietUntil[id] = nil
                flapStatus[id] = nil
            }
            // Flapping: enough changes, and back into a state it had left (not a one-way episode).
            if recent.count >= Self.flapChanges, Set(recent.map(\.to)).count < recent.count {
                quietUntil[id] = now + Self.flapQuiet
                flapStatus[id] = new
                changes[id] = []
                events.append(monitorEvent(.monitorFlapping, id, s, detail: "\(recent.count) changes in 15 min, now \(new)"))
                continue
            }
            if kind == .monitorAlert { alertToldAt[id] = now }
            events.append(monitorEvent(kind, id, s, detail: Self.monitorDetail(kind, from: old)))
        }
        // A flapping monitor's quiet ended: its state, once, if it is not the one told.
        for (id, until) in quietUntil where now >= until {
            quietUntil[id] = nil
            let told = flapStatus.removeValue(forKey: id) ?? "OK"
            let state = status[id] ?? "OK"
            guard state != told, let kind = Self.monitorKind(from: told, to: state) else { continue }
            if kind == .monitorAlert { alertToldAt[id] = now }
            events.append(monitorEvent(kind, id, s, detail: "Settled after flapping"))
        }
        for id in alertToldAt.keys where status[id] != "Alert" { alertToldAt[id] = nil }
        if reminders {
            for (id, state) in status.sorted(by: { $0.key < $1.key }) where state == "Alert" && now >= quietUntil[id] ?? 0 {
                let key = "m:\(id)"
                guard !events.contains(where: { $0.key == key }) else { continue }
                let told = alertToldAt[id] ?? now
                if alertToldAt[id] == nil { alertToldAt[id] = now }
                guard now - told >= Self.remindEvery else { continue }
                alertToldAt[id] = now
                events.append(monitorEvent(.monitorReminder, id, s, detail: "Alerting for over \(Int((now - told) / 3600)) h"))
            }
        }
        return events
    }

    private static func monitorKind(from old: String, to new: String) -> ProdAlertEvent.Kind? {
        switch new {
        case "Alert": return .monitorAlert
        case "Warn": return .monitorWarn
        case "OK" where old == "Alert" || old == "Warn": return .monitorRecovered
        default: return nil
        }
    }

    private static func monitorDetail(_ kind: ProdAlertEvent.Kind, from old: String) -> String {
        switch kind {
        case .monitorAlert: return old == "Warn" ? "Warn → Alert" : "Now in Alert"
        case .monitorWarn: return old == "Alert" ? "Alert → Warn" : "Now in Warn"
        case .monitorRecovered: return "\(old) → OK"
        default: return ""
        }
    }

    private func monitorEvent(_ kind: ProdAlertEvent.Kind, _ id: Int64, _ s: ProdSnapshot, detail: String) -> ProdAlertEvent {
        ProdAlertEvent(kind: kind, key: "m:\(id)", name: names[id] ?? "Monitor \(id)", detail: detail,
                       url: DatadogConfig.monitorURL(site: s.site, id: id))
    }

    // MARK: Incidents

    private mutating func incidentsChanged(_ s: ProdSnapshot) -> [ProdAlertEvent] {
        let current = Dictionary(s.incidents.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        guard incidentsPrimed else {
            incidentsPrimed = true
            incidents = current
            return []
        }
        var events: [ProdAlertEvent] = []
        for incident in s.incidents where incidents[incident.id] == nil {
            events.append(ProdAlertEvent(kind: .incidentDeclared, key: "i:\(incident.id)", name: Self.incidentLine(incident),
                                         detail: incident.severity ?? "", url: DatadogConfig.incidentURL(site: s.site, incident: incident)))
        }
        for incident in s.incidents {
            guard let old = incidents[incident.id], old.severity != incident.severity else { continue }
            let was = Self.rank(old.severity), now = Self.rank(incident.severity)
            events.append(ProdAlertEvent(kind: .incidentChanged, key: "i:\(incident.id)", name: Self.incidentLine(incident),
                                         detail: "\(old.severity ?? "Unknown") → \(incident.severity ?? "Unknown")",
                                         url: DatadogConfig.incidentURL(site: s.site, incident: incident), escalated: now < was))
        }
        for (id, incident) in incidents.sorted(by: { $0.key < $1.key }) where current[id] == nil {
            events.append(ProdAlertEvent(kind: .incidentResolved, key: "i:\(id)", name: Self.incidentLine(incident),
                                         detail: incident.severity ?? "", url: DatadogConfig.incidentURL(site: s.site, incident: incident)))
        }
        incidents = current
        return events
    }

    /// SEV-1 → 1; unknown sorts after every known severity.
    static func rank(_ severity: String?) -> Int {
        guard let severity, let number = Int(severity.uppercased().replacingOccurrences(of: "SEV-", with: "")) else { return 99 }
        return number
    }

    /// "SEV-2 · #123 Checkout errors".
    static func incidentLine(_ incident: ProdIncident) -> String {
        ([incident.severity, incident.publicId.map { "#\($0)" }].compactMap { $0 } + [incident.title]).joined(separator: " · ")
    }

    // MARK: Numbers

    private mutating func numbersChanged(_ s: ProdSnapshot) -> [ProdAlertEvent] {
        var events: [ProdAlertEvent] = []
        for number in s.numbers {
            guard let value = number.value, value.isFinite, let amber = number.amber else { continue }
            let over = value > amber
            guard var metric = metrics[number.label] else {
                // Its first value is history: over it counts as already told.
                metrics[number.label] = Metric(alerted: over)
                continue
            }
            if over {
                metric.over += 1
                metric.under = 0
            } else {
                metric.under += 1
                metric.over = 0
            }
            let line = ProdNumber(label: "", value: amber, unit: number.unit).valueText
            if !metric.alerted, metric.over >= Self.streak {
                metric.alerted = true
                events.append(ProdAlertEvent(kind: .metricOver, key: "n:\(number.label)", name: number.label,
                                             detail: "\(number.valueText), over \(line)", url: DatadogConfig.monitorsListURL(site: s.site, query: s.monitorQuery)))
            } else if metric.alerted, metric.under >= Self.streak {
                metric.alerted = false
                events.append(ProdAlertEvent(kind: .metricNormal, key: "n:\(number.label)", name: number.label,
                                             detail: "\(number.valueText), under \(line)", url: DatadogConfig.monitorsListURL(site: s.site, query: s.monitorQuery)))
            }
            metrics[number.label] = metric
        }
        let labels = Set(s.numbers.map(\.label))
        for label in metrics.keys where !labels.contains(label) { metrics[label] = nil }
        return events
    }
}

/// One notification for a poll's news.
struct ProdNotice: Equatable, Sendable {
    var title: String
    var subtitle: String
    var body: String
    var url: URL?
    /// For the log: "monitorAlert×2,incidentDeclared".
    var kinds: String
    var keys: [String]
}

/// The banner the notch drops: alert-level news only.
struct ProdHeadsUp: Equatable, Identifiable, Sendable {
    var id: Int
    var title: String
    var subtitle: String
    var url: URL?
    var keys: [String]
}

/// What to do with a poll's news, given the switches and the moment.
struct ProdAlertPlan: Equatable {
    var notice: ProdNotice?
    /// The banner's content; nil when nothing pops (the id is set by the store).
    var headsUp: ProdHeadsUp?
    /// Why news was held back, for the log: "snoozed", "off", "full screen", "unlocked".
    var held: [String] = []
}

enum ProdAlertPlanner {
    static func plan(_ events: [ProdAlertEvent], prefs: ProdAlertPrefs, snoozed: Bool, locked: Bool,
                     popBlocked: String?, listURL: URL?) -> ProdAlertPlan {
        var plan = ProdAlertPlan()
        guard !events.isEmpty else { return plan }
        if snoozed {
            plan.held.append("snoozed")
            return plan
        }
        let told = events.filter { prefs.allows($0.kind) }
        if told.count < events.count { plan.held.append("off") }
        guard !told.isEmpty else { return plan }
        if locked || prefs.notifyUnlocked {
            plan.notice = notice(told, listURL: listURL)
        } else {
            plan.held.append("unlocked")
        }
        let popping = told.filter(\.popsOpen)
        if !popping.isEmpty, prefs.popOpen, !locked {
            if let popBlocked {
                plan.held.append(popBlocked)
            } else {
                plan.headsUp = ProdHeadsUp(id: 0, title: title(popping), subtitle: subtitle(popping),
                                           url: popping.count == 1 ? popping[0].url : listURL, keys: popping.map(\.key))
            }
        }
        return plan
    }

    static func notice(_ events: [ProdAlertEvent], listURL: URL?) -> ProdNotice {
        var counts: [ProdAlertEvent.Kind: Int] = [:]
        for event in events { counts[event.kind, default: 0] += 1 }
        let kinds = ProdAlertEvent.Kind.allCases.compactMap { kind in counts[kind].map { $0 > 1 ? "\(kind.rawValue)×\($0)" : kind.rawValue } }
        let body: String
        if events.count == 1 {
            body = events[0].detail
        } else {
            var lines = events.prefix(4).map { "\(short($0.kind)): \($0.name)\($0.detail.isEmpty ? "" : " (\($0.detail))")" }
            if events.count > 4 { lines.append("+\(events.count - 4) more") }
            body = lines.joined(separator: "\n")
        }
        return ProdNotice(title: title(events), subtitle: subtitle(events), body: body,
                          url: events.count == 1 ? events[0].url : listURL, kinds: kinds.joined(separator: ","), keys: events.map(\.key))
    }

    /// "Datadog · Monitor alerting", "Datadog · 3 monitors alerting", "Datadog · 2 alerting · 1 recovered".
    static func title(_ events: [ProdAlertEvent]) -> String {
        var counts: [ProdAlertEvent.Kind: Int] = [:]
        for event in events { counts[event.kind, default: 0] += 1 }
        if events.count == 1 { return "Datadog · " + single(events[0]) }
        if counts.count == 1, let kind = counts.keys.first { return "Datadog · \(events.count) " + plural(kind) }
        let parts = ProdAlertEvent.Kind.allCases.compactMap { kind in counts[kind].map { "\($0) \(short(kind).lowercased())" } }
        return "Datadog · " + parts.joined(separator: " · ")
    }

    static func subtitle(_ events: [ProdAlertEvent]) -> String {
        var seen = Set<String>()
        return events.map(\.name).filter { seen.insert($0).inserted }.joined(separator: ", ")
    }

    private static func single(_ event: ProdAlertEvent) -> String {
        switch event.kind {
        case .monitorAlert: return "Monitor alerting"
        case .monitorWarn: return "Monitor warning"
        case .monitorRecovered: return "Recovered"
        case .monitorFlapping: return "Monitor flapping"
        case .monitorReminder: return "Still alerting"
        case .incidentDeclared: return event.detail.isEmpty ? "Incident declared" : "Incident \(event.detail) declared"
        case .incidentChanged: return "Incident \(event.detail)"
        case .incidentResolved: return "Incident resolved"
        case .metricOver: return "\(event.name) high"
        case .metricNormal: return "\(event.name) back to normal"
        }
    }

    private static func plural(_ kind: ProdAlertEvent.Kind) -> String {
        switch kind {
        case .monitorAlert: return "monitors alerting"
        case .monitorWarn: return "monitors warning"
        case .monitorRecovered: return "monitors recovered"
        case .monitorFlapping: return "monitors flapping"
        case .monitorReminder: return "monitors still alerting"
        case .incidentDeclared: return "incidents declared"
        case .incidentChanged: return "incidents changed"
        case .incidentResolved: return "incidents resolved"
        case .metricOver: return "numbers high"
        case .metricNormal: return "numbers back to normal"
        }
    }

    /// A kind in a word or two, for mixed titles and the body's lines.
    private static func short(_ kind: ProdAlertEvent.Kind) -> String {
        switch kind {
        case .monitorAlert: return "Alerting"
        case .monitorWarn: return "Warning"
        case .monitorRecovered: return "Recovered"
        case .monitorFlapping: return "Flapping"
        case .monitorReminder: return "Still alerting"
        case .incidentDeclared: return "Declared"
        case .incidentChanged: return "Changed"
        case .incidentResolved: return "Resolved"
        case .metricOver: return "High"
        case .metricNormal: return "Normal"
        }
    }
}

// MARK: Self-check

/// `AINotch --prod-alerts-selfcheck`: the engine and the planner on made-up snapshots; exits 1 on
/// any failure. Neutral names only.
enum ProdAlertsCheck {
    static func runIfAsked(_ arguments: [String]) {
        guard arguments.contains("--prod-alerts-selfcheck") else { return }
        exit(run())
    }

    static func run() -> Int32 {
        var failures = 0, checks = 0
        func expect(_ condition: Bool, _ what: String) {
            checks += 1
            if !condition {
                failures += 1
                print("FAIL \(what)")
            }
        }
        func kinds(_ events: [ProdAlertEvent]) -> [String] { events.map { "\($0.kind.rawValue) \($0.key)" } }

        var clock: Double = 1_000_000
        var snap = ProdSnapshot()
        snap.access = .ok
        snap.site = "us3.datadoghq.com"
        snap.monitorQuery = "service:api"
        snap.incidentsOn = true
        func monitors(_ list: [(Int64, String)]) {
            clock += 60
            snap.monitors = list.map { ProdMonitor(id: $0.0, name: "Monitor \($0.0)", status: $0.1) }
            snap.statusCounts = [:]
            for m in snap.monitors { snap.statusCounts[m.status, default: 0] += 1 }
            snap.monitorsAt = clock
        }
        func incidents(_ list: [(String, String?)]) {
            clock += 60
            snap.incidents = list.map { ProdIncident(id: $0.0, publicId: 7, title: "Checkout errors", severity: $0.1, state: "active") }
            snap.incidentsAt = clock
        }
        func number(_ value: Double) {
            clock += 300
            snap.numbers = [ProdNumber(label: "5xx", value: value, unit: "%", amber: 2)]
            snap.numbersAt = clock
        }

        // 1. The first snapshot is history: an open alert, incident and high number say nothing.
        var engine = ProdAlertEngine()
        monitors([(1, "Alert"), (2, "Warn")])
        incidents([("a", "SEV-2")])
        number(5)
        expect(engine.take(snap, now: clock).isEmpty, "first snapshot is history")
        expect(engine.openKeys == ["m:1", "i:a", "n:5xx"], "history counts as open: \(engine.openKeys.sorted())")
        // Unchanged answers: nothing.
        expect(engine.take(snap, now: clock).isEmpty, "same snapshot again: nothing")
        monitors([(1, "Alert"), (2, "Warn")])
        expect(engine.take(snap, now: clock).isEmpty, "same states, newer answer: nothing")

        // 2. Monitor transitions.
        monitors([(1, "Alert"), (2, "Alert"), (3, "Warn"), (4, "No Data")])
        var events = engine.take(snap, now: clock)
        expect(kinds(events) == ["monitorAlert m:2", "monitorWarn m:3"], "warn→alert and OK→warn, No Data silent: \(kinds(events))")
        expect(events.first?.popsOpen == true && events.last?.popsOpen == false, "alert pops, warn does not")
        monitors([(2, "Alert"), (3, "Warn")])
        events = engine.take(snap, now: clock)
        expect(kinds(events) == ["monitorRecovered m:1"], "alert→OK recovers, No Data→OK silent, warn→OK: \(kinds(events))")
        expect(events.first?.popsOpen == false, "recovery does not pop")
        monitors([(2, "Alert")])
        events = engine.take(snap, now: clock)
        expect(kinds(events) == ["monitorRecovered m:3"], "warn→OK recovers: \(kinds(events))")

        // A page that lists fewer not-OK monitors than the facets count: missing ones keep their state.
        clock += 60
        snap.monitors = []
        snap.statusCounts = ["Alert": 1, "OK": 150]
        snap.monitorsAt = clock
        expect(engine.take(snap, now: clock).isEmpty, "missing from a partial page is not a recovery")
        expect(engine.openKeys.contains("m:2"), "still open after a partial page")

        // A grey snapshot changes nothing.
        var grey = snap
        grey.access = .rejected("no")
        grey.monitorsAt = clock + 1
        grey.monitors = []
        grey.statusCounts = [:]
        expect(engine.take(grey, now: clock).isEmpty, "keys refused is not a recovery")

        // 3. Grouping per poll: three monitors in one answer → one notice.
        monitors([(2, "Alert"), (10, "Alert"), (11, "Alert"), (12, "Alert")])
        events = engine.take(snap, now: clock)
        expect(events.count == 3, "three alerts in one poll: \(kinds(events))")
        let list = DatadogConfig.monitorsListURL(site: snap.site, query: snap.monitorQuery)
        var plan = ProdAlertPlanner.plan(events, prefs: ProdAlertPrefs(), snoozed: false, locked: false, popBlocked: nil, listURL: list)
        expect(plan.notice?.title == "Datadog · 3 monitors alerting", "grouped title: \(plan.notice?.title ?? "nil")")
        expect(plan.notice?.url == list, "grouped notice opens the filtered list")
        expect(plan.notice?.kinds == "monitorAlert×3", "kinds for the log: \(plan.notice?.kinds ?? "")")
        expect(plan.headsUp?.title == "Datadog · 3 monitors alerting" && plan.headsUp?.url == list, "one banner for the poll")
        // Mixed kinds in one poll.
        let mixed = [ProdAlertEvent(kind: .monitorAlert, key: "m:1", name: "A"), ProdAlertEvent(kind: .monitorAlert, key: "m:2", name: "B"),
                     ProdAlertEvent(kind: .monitorRecovered, key: "m:3", name: "C")]
        plan = ProdAlertPlanner.plan(mixed, prefs: ProdAlertPrefs(), snoozed: false, locked: false, popBlocked: nil, listURL: list)
        expect(plan.notice?.title == "Datadog · 2 alerting · 1 recovered", "mixed title: \(plan.notice?.title ?? "nil")")
        expect(plan.notice?.body.split(separator: "\n").count == 3, "mixed body lists each")
        expect(plan.headsUp?.keys == ["m:1", "m:2"], "the banner only for the alert-level ones")

        // A single event: its own title and link.
        let one = ProdAlertEvent(kind: .monitorAlert, key: "m:5", name: "Monitor 5", url: DatadogConfig.monitorURL(site: snap.site, id: 5))
        plan = ProdAlertPlanner.plan([one], prefs: ProdAlertPrefs(), snoozed: false, locked: false, popBlocked: nil, listURL: list)
        expect(plan.notice?.title == "Datadog · Monitor alerting" && plan.notice?.url?.path == "/monitors/5", "single title and link")

        // 4. Delivery rules: snooze, prefs, full screen, locked.
        plan = ProdAlertPlanner.plan([one], prefs: ProdAlertPrefs(), snoozed: true, locked: false, popBlocked: nil, listURL: list)
        expect(plan.notice == nil && plan.headsUp == nil && plan.held == ["snoozed"], "snooze silences notices and pop-opens")
        plan = ProdAlertPlanner.plan([one], prefs: ProdAlertPrefs(), snoozed: false, locked: false, popBlocked: "full screen", listURL: list)
        expect(plan.notice != nil && plan.headsUp == nil && plan.held == ["full screen"], "full screen: notify only")
        plan = ProdAlertPlanner.plan([one], prefs: ProdAlertPrefs(), snoozed: false, locked: true, popBlocked: nil, listURL: list)
        expect(plan.notice != nil && plan.headsUp == nil, "locked: notify, no banner")
        var prefs = ProdAlertPrefs()
        prefs.notifyUnlocked = false
        plan = ProdAlertPlanner.plan([one], prefs: prefs, snoozed: false, locked: false, popBlocked: nil, listURL: list)
        expect(plan.notice == nil && plan.headsUp != nil, "unlocked notifications off: banner only")
        plan = ProdAlertPlanner.plan([one], prefs: prefs, snoozed: false, locked: true, popBlocked: nil, listURL: list)
        expect(plan.notice != nil, "unlocked notifications off still notifies when locked")
        prefs = ProdAlertPrefs()
        prefs.popOpen = false
        plan = ProdAlertPlanner.plan([one], prefs: prefs, snoozed: false, locked: false, popBlocked: nil, listURL: list)
        expect(plan.notice != nil && plan.headsUp == nil, "pop-open off")
        prefs = ProdAlertPrefs()
        prefs.monitorAlert = false
        plan = ProdAlertPlanner.plan([one], prefs: prefs, snoozed: false, locked: false, popBlocked: nil, listURL: list)
        expect(plan.notice == nil && plan.headsUp == nil && plan.held == ["off"], "alerts off")
        let warn = ProdAlertEvent(kind: .monitorWarn, key: "m:6", name: "Monitor 6")
        let recovered = ProdAlertEvent(kind: .monitorRecovered, key: "m:7", name: "Monitor 7")
        plan = ProdAlertPlanner.plan([warn, recovered], prefs: ProdAlertPrefs(), snoozed: false, locked: false, popBlocked: nil, listURL: list)
        expect(plan.notice != nil && plan.headsUp == nil, "warn and recovery notify without popping")

        // 5. Flapping: the third change in 15 minutes is one notice, then 30 minutes of quiet.
        engine = ProdAlertEngine()
        monitors([])
        _ = engine.take(snap, now: clock)
        monitors([(20, "Alert")])
        expect(kinds(engine.take(snap, now: clock)) == ["monitorAlert m:20"], "flap 1: alert")
        monitors([])
        expect(kinds(engine.take(snap, now: clock)) == ["monitorRecovered m:20"], "flap 2: recovered")
        monitors([(20, "Alert")])
        events = engine.take(snap, now: clock)
        expect(kinds(events) == ["monitorFlapping m:20"], "flap 3: one flapping notice: \(kinds(events))")
        expect(events.first?.popsOpen == false, "flapping does not pop")
        plan = ProdAlertPlanner.plan(events, prefs: ProdAlertPrefs(), snoozed: false, locked: false, popBlocked: nil, listURL: list)
        expect(plan.notice?.title == "Datadog · Monitor flapping", "flapping title")
        var quiet = 0
        for state in ["OK", "Alert", "OK", "Alert", "OK"] {
            monitors(state == "OK" ? [] : [(Int64(20), state)])
            quiet += engine.take(snap, now: clock).count
        }
        expect(quiet == 0, "quiet for 30 minutes after the flapping notice: \(quiet)")
        // Settled in OK during the quiet; when it ends: told once, as it differs from the Alert
        // the notice named.
        clock += ProdAlertEngine.flapQuiet
        monitors([])
        events = engine.take(snap, now: clock)
        expect(kinds(events) == ["monitorRecovered m:20"] && events.first?.detail == "Settled after flapping",
               "after the quiet, the settled state once: \(kinds(events))")
        monitors([])
        expect(engine.take(snap, now: clock).isEmpty, "then nothing")
        // A change right as the quiet ends is told once, not twice.
        monitors([(22, "Alert")]); _ = engine.take(snap, now: clock)
        monitors([]); _ = engine.take(snap, now: clock)
        monitors([(22, "Alert")])
        expect(kinds(engine.take(snap, now: clock)) == ["monitorFlapping m:22"], "second monitor flaps")
        clock += ProdAlertEngine.flapQuiet
        monitors([])
        events = engine.take(snap, now: clock)
        expect(kinds(events) == ["monitorRecovered m:22"], "a change as the quiet ends: once: \(kinds(events))")
        // A one-way episode (OK → Warn → Alert → OK) in 3 minutes is told change by change.
        monitors([(23, "Warn")])
        expect(kinds(engine.take(snap, now: clock)) == ["monitorWarn m:23"], "episode 1: warn")
        monitors([(23, "Alert")])
        expect(kinds(engine.take(snap, now: clock)) == ["monitorAlert m:23"], "episode 2: alert")
        monitors([])
        events = engine.take(snap, now: clock)
        expect(kinds(events) == ["monitorRecovered m:23"], "episode 3: recovered, not flapping: \(kinds(events))")
        // Warn and Alert bouncing is flapping.
        monitors([(24, "Warn")]); _ = engine.take(snap, now: clock)
        monitors([(24, "Alert")]); _ = engine.take(snap, now: clock)
        monitors([(24, "Warn")])
        expect(kinds(engine.take(snap, now: clock)) == ["monitorFlapping m:24"], "warn/alert bouncing flaps")
        // Two changes, then a pause longer than the window: no flapping.
        monitors([(21, "Alert")])
        _ = engine.take(snap, now: clock)
        monitors([])
        _ = engine.take(snap, now: clock)
        clock += ProdAlertEngine.flapWindow
        monitors([(21, "Alert")])
        expect(kinds(engine.take(snap, now: clock)) == ["monitorAlert m:21"], "changes spread over more than 15 minutes do not flap")

        // 6. Incidents: declared, escalated, de-escalated, resolved.
        incidents([])
        _ = engine.take(snap, now: clock)
        incidents([("b", "SEV-3")])
        events = engine.take(snap, now: clock)
        expect(kinds(events) == ["incidentDeclared i:b"] && events[0].popsOpen, "declared pops: \(kinds(events))")
        plan = ProdAlertPlanner.plan(events, prefs: ProdAlertPrefs(), snoozed: false, locked: false, popBlocked: nil, listURL: list)
        expect(plan.notice?.title == "Datadog · Incident SEV-3 declared", "declared title: \(plan.notice?.title ?? "")")
        expect(plan.notice?.url?.path == "/incidents/7", "incident link")
        incidents([("b", "SEV-2")])
        events = engine.take(snap, now: clock)
        expect(kinds(events) == ["incidentChanged i:b"] && events[0].escalated && events[0].popsOpen, "escalation pops")
        plan = ProdAlertPlanner.plan(events, prefs: ProdAlertPrefs(), snoozed: false, locked: false, popBlocked: nil, listURL: list)
        expect(plan.notice?.title == "Datadog · Incident SEV-3 → SEV-2", "changed title: \(plan.notice?.title ?? "")")
        incidents([("b", "SEV-4")])
        events = engine.take(snap, now: clock)
        expect(kinds(events) == ["incidentChanged i:b"] && !events[0].popsOpen, "de-escalation does not pop")
        incidents([])
        events = engine.take(snap, now: clock)
        expect(kinds(events) == ["incidentResolved i:b"] && !events[0].popsOpen, "resolved does not pop")

        // 7. Numbers: two polls over before alerting, two under before back to normal.
        engine = ProdAlertEngine()
        number(1)
        expect(engine.take(snap, now: clock).isEmpty, "number history")
        number(3)
        expect(engine.take(snap, now: clock).isEmpty, "one poll over: nothing yet")
        number(1)
        expect(engine.take(snap, now: clock).isEmpty, "back under resets the streak")
        number(3)
        expect(engine.take(snap, now: clock).isEmpty, "over again: one poll")
        number(4)
        events = engine.take(snap, now: clock)
        expect(kinds(events) == ["metricOver n:5xx"] && events[0].popsOpen, "two polls over: high, pops: \(kinds(events))")
        number(5)
        expect(engine.take(snap, now: clock).isEmpty, "still over: once")
        number(1)
        expect(engine.take(snap, now: clock).isEmpty, "one poll under: nothing yet")
        number(1.5)
        events = engine.take(snap, now: clock)
        expect(kinds(events) == ["metricNormal n:5xx"] && !events[0].popsOpen, "two polls under: back to normal, no pop")
        plan = ProdAlertPlanner.plan(events, prefs: ProdAlertPrefs(), snoozed: false, locked: false, popBlocked: nil, listURL: list)
        expect(plan.notice?.title == "Datadog · 5xx back to normal", "metric title: \(plan.notice?.title ?? "")")
        var noData = snap
        noData.numbers = [ProdNumber(label: "5xx", value: nil, unit: "%", amber: 2)]
        noData.numbersAt = clock + 300
        expect(engine.take(noData, now: clock).isEmpty, "no value: no change")

        // 8. Reminder: off by default; on, every 2 hours while still alerting.
        engine = ProdAlertEngine()
        monitors([])
        _ = engine.take(snap, now: clock)
        monitors([(30, "Alert")])
        _ = engine.take(snap, now: clock)
        clock += ProdAlertEngine.remindEvery
        monitors([(30, "Alert")])
        expect(engine.take(snap, now: clock, reminders: false).isEmpty, "no reminder by default")
        monitors([(30, "Alert")])
        events = engine.take(snap, now: clock, reminders: true)
        expect(kinds(events) == ["monitorReminder m:30"], "reminder after 2 hours: \(kinds(events))")
        monitors([(30, "Alert")])
        expect(engine.take(snap, now: clock, reminders: true).isEmpty, "not again right after")
        expect(!ProdAlertPrefs().reminder && ProdAlertPrefs().allows(.monitorAlert), "defaults: all on except the reminder")

        // 9. Prefs: Codable with defaults for missing keys, and the older switches.
        let suite = "ai-notch-selfcheck-\(getpid())"
        if let defaults = UserDefaults(suiteName: suite) {
            defaults.set(Data(#"{"monitorWarn":false}"#.utf8), forKey: ProdAlertPrefs.defaultsKey)
            let loaded = ProdAlertPrefs.load(defaults)
            expect(!loaded.monitorWarn && loaded.monitorAlert && loaded.notifyUnlocked && !loaded.reminder, "missing keys take defaults")
            defaults.removeObject(forKey: ProdAlertPrefs.defaultsKey)
            defaults.set(["alerts": true, "incidents": false, "recoveries": false], forKey: ProdAlertPrefs.legacyKey)
            let migrated = ProdAlertPrefs.load(defaults)
            expect(migrated.monitorAlert && !migrated.incidentDeclared && !migrated.incidentResolved && migrated.recovered, "older switches: only an off carries over")
            var changed = ProdAlertPrefs()
            changed.reminder = true
            changed.popOpen = false
            changed.save(defaults)
            expect(ProdAlertPrefs.load(defaults) == changed, "save and load")
            defaults.removePersistentDomain(forName: suite)
        }

        // 10. The full-screen check the banner respects.
        let screen = NSRect(x: 0, y: 0, width: 1800, height: 1169)
        func window(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, layer: Int = 0, pid: Int = 999) -> [String: Any] {
            [kCGWindowLayer as String: layer, kCGWindowOwnerPID as String: pid,
             kCGWindowBounds as String: CGRect(x: x, y: y, width: w, height: h).dictionaryRepresentation]
        }
        let full = NotchController.fullScreenAhead(windows: [window(0, 39, 1800, 1130)], screen: screen, primary: screen, underNotch: 39, me: 1)
        let zoomed = NotchController.fullScreenAhead(windows: [window(0, 39, 1800, 1060)], screen: screen, primary: screen, underNotch: 39, me: 1)
        let own = NotchController.fullScreenAhead(windows: [window(0, 0, 1800, 1169, pid: 1)], screen: screen, primary: screen, underNotch: 39, me: 1)
        expect(full && !zoomed && !own, "full screen: \(full) zoomed: \(zoomed) own window: \(own)")

        print("prod alerts selfcheck: \(checks - failures)/\(checks) passed")
        return failures == 0 ? 0 : 1
    }
}
