import Foundation

// The Prod page's data and the rules on it, all pure so `--prodpage-selfcheck` can check them on
// made-up answers: the range, the health numbers' series (min, max, change, level), the timeline
// ("what happened before": merged, ordered, bounded) and the small local history of what this app
// itself saw. Fetching is ProdPageSource.swift; the views are ProdPageViews.swift.

/// How far back the page looks. Remembered.
enum ProdRange: String, CaseIterable, Sendable {
    case hour, day, week

    var seconds: Double { self == .hour ? 3600 : self == .day ? 86_400 : 604_800 }
    /// The series' bucket: about 60, 48 and 42 points.
    var intervalMs: Int64 { self == .hour ? 60_000 : self == .day ? 1_800_000 : 14_400_000 }
    var label: String { self == .hour ? "1 h" : self == .day ? "24 h" : "7 d" }
    var words: String { self == .hour ? "the last hour" : self == .day ? "the last 24 hours" : "the last 7 days" }

    private static let key = "prod.range"
    static func saved() -> ProdRange { ProdRange(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .day }
    func save() { UserDefaults.standard.set(rawValue, forKey: Self.key) }
}

// MARK: Performance

/// One health number over the range.
struct ProdSeries: Equatable, Sendable {
    enum Level: Equatable, Sendable { case ok, amber, red }

    var label: String
    var unit: String
    var amber: Double?
    /// Oldest first, already in the shown unit (scaled).
    var values: [Double] = []
    /// Why there is nothing to draw ("needs timeseries_query"), else nil.
    var note: String?

    var minimum: Double? { values.min() }
    var maximum: Double? { values.max() }
    var first: Double? { values.first }
    var last: Double? { values.last }

    /// The change from the start of the range to its end: points for a percentage, else a percent.
    var changeText: String? {
        guard values.count >= 2, let first, let last else { return nil }
        let delta = last - first
        if unit == "%" { return abs(delta) < 0.05 ? "flat" : String(format: "%+.1f pt", delta) }
        guard abs(first) > 1e-9 else { return abs(delta) < 1e-9 ? "flat" : nil }
        let percent = delta / abs(first) * 100
        return abs(percent) < 1 ? "flat" : String(format: "%+.0f%%", percent)
    }

    /// Amber over `amber`; red at twice it (the one line a number is configured with).
    func level(_ value: Double?) -> Level {
        guard let value, let amber, amber > 0 else { return .ok }
        return value >= amber * 2 ? .red : value > amber ? .amber : .ok
    }

    func text(_ value: Double?) -> String { ProdNumber(label: label, value: value, unit: unit, amber: amber).valueText }

    /// At most `buckets` points for a sparkline: each the mean of its slice; shorter series as they are.
    func spark(buckets: Int) -> [Double] {
        guard buckets > 1, values.count > buckets else { return values }
        return (0..<buckets).map { index in
            let from = index * values.count / buckets, to = max(from + 1, (index + 1) * values.count / buckets)
            let slice = values[from..<min(to, values.count)]
            return slice.reduce(0, +) / Double(slice.count)
        }
    }
}

enum ProdSeriesParse {
    /// The first series of a timeseries answer with its values, scaled, in time order; nil when the
    /// answer is not a timeseries answer, [] when it has no numbers.
    static func values(_ data: Data, scale: Double) -> [Double]? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let attributes = (object["data"] as? [String: Any])?["attributes"] as? [String: Any],
              let values = attributes["values"] as? [[Any]] else { return nil }
        let times = (attributes["times"] as? [Any])?.map { ($0 as? NSNumber)?.doubleValue ?? 0 } ?? []
        guard let row = values.first(where: { !$0.isEmpty }) else { return [] }
        var points: [(t: Double, v: Double)] = []
        for (index, raw) in row.enumerated() {
            guard let value = (raw as? NSNumber)?.doubleValue, value.isFinite else { continue }
            points.append((index < times.count ? times[index] : Double(index), value * scale))
        }
        return points.sorted { $0.t < $1.t }.map(\.v)
    }
}

// MARK: The timeline

/// One thing that happened in prod.
struct ProdTimelineEntry: Equatable, Sendable, Codable {
    enum Kind: String, Codable, Sendable {
        case alert, warn, recovered, incidentOpened, incidentResolved, deploy, watchdog
    }

    var kind: Kind
    var at: Double
    var title: String
    var detail: String?
    /// What it is about: "m:<monitor id>", "i:<incident id>", "d:<service>:<version>", "w:<story id>".
    var key: String
    var publicId: Int?
    /// A Watchdog story with its own key (it can open its page).
    var hasStoryKey = false
    /// Seen by this app itself, not read from Datadog.
    var observed = false

    var id: String { "\(kind.rawValue)|\(key)|\(Int(at))" }

    /// The page in Datadog's web app this entry opens, for `site`; checked by SafeLink when opened.
    func url(site: String, query: String) -> URL? {
        let id = String(key.dropFirst(2))
        switch key.prefix(2) {
        case "m:": return Int64(id).flatMap { DatadogConfig.monitorURL(site: site, id: $0) }
        case "i:": return DatadogConfig.incidentURL(site: site, incident: ProdIncident(id: id, publicId: publicId, title: title, severity: nil, state: "", createdAt: nil))
        case "w:": return hasStoryKey ? Watchdog.storyURL(site: site, id: id) : DatadogConfig.monitorsListURL(site: site, query: query)
        case "d:":
            let service = SafeLink.segment(String(id.split(separator: ":", maxSplits: 1).first ?? ""))
            return service.isEmpty ? nil : URL(string: "https://\(DatadogConfig.webHost(site))/apm/services/\(service)")
        default: return nil
        }
    }

    /// The same thing twice: a monitor going to Alert is one entry whoever saw it first.
    var sameThing: String { "\(kind.rawValue)|\(key)" }
}

enum ProdTimeline {
    /// How long and how many entries the local history keeps.
    static let keepFor: Double = 7 * 86_400
    static let keepMost = 300
    /// Two sightings of one thing within this long are one.
    static let samePlaceWindow: Double = 300
    /// What the page lists at most.
    static let showMost = 100

    /// Datadog's entries and this app's own, newest first, inside `range`: one entry per thing
    /// (Datadog's wins over the app's own sighting within `samePlaceWindow`), none from the future,
    /// at most `showMost`.
    static func merge(remote: [ProdTimelineEntry], local: [ProdTimelineEntry], now: Double, range: ProdRange, limit: Int = showMost) -> [ProdTimelineEntry] {
        let from = now - range.seconds
        func inside(_ entry: ProdTimelineEntry) -> Bool { entry.at >= from && entry.at <= now + 60 }
        var kept: [ProdTimelineEntry] = []
        for entry in remote.filter(inside).sorted(by: order) where !kept.contains(where: { $0.sameThing == entry.sameThing && abs($0.at - entry.at) <= samePlaceWindow }) {
            kept.append(entry)
        }
        for entry in local.filter(inside).sorted(by: order) where !kept.contains(where: { $0.sameThing == entry.sameThing && abs($0.at - entry.at) <= samePlaceWindow }) {
            kept.append(entry)
        }
        return Array(kept.sorted(by: order).prefix(limit))
    }

    /// Newest first; a tie by key, so the order never shuffles.
    static func order(_ a: ProdTimelineEntry, _ b: ProdTimelineEntry) -> Bool {
        a.at != b.at ? a.at > b.at : a.id < b.id
    }

    /// The local history after a new entry: no duplicate sighting, nothing older than a week,
    /// at most `keepMost` (the newest).
    static func bounded(_ entries: [ProdTimelineEntry], adding entry: ProdTimelineEntry? = nil, now: Double) -> [ProdTimelineEntry] {
        var all = entries
        if let entry, !all.contains(where: { $0.sameThing == entry.sameThing && abs($0.at - entry.at) <= samePlaceWindow }) { all.append(entry) }
        return Array(all.filter { $0.at >= now - keepFor }.sorted(by: order).prefix(keepMost))
    }

    /// "12:41" today, "Tue 12:41" within a week.
    static func timeText(_ at: Double, now: Double, calendar: Calendar = .current) -> String {
        let date = Date(timeIntervalSince1970: at)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = calendar.isDate(date, inSameDayAs: Date(timeIntervalSince1970: now)) ? "HH:mm" : "EEE HH:mm"
        return formatter.string(from: date)
    }
}

// MARK: Reading Datadog's answers

extension ProdTimelineEntry {
    /// Monitor alert events (`source:alert`): [Triggered], [Warn], [Recovered] and so on. An event
    /// of a monitor outside `monitorIds` (when that set is complete), of a hidden service or of
    /// another env is left out; so is anything that is not a trigger, a warning or a recovery.
    static func alerts(_ data: Data, hidden: Set<String>, monitorIds: Set<Int64>?) -> [ProdTimelineEntry]? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = object["data"] as? [[String: Any]] else { return nil }
        var out: [ProdTimelineEntry] = []
        for event in list {
            let attributes = event["attributes"] as? [String: Any] ?? [:]
            let inner = attributes["attributes"] as? [String: Any] ?? [:]
            let tags = (attributes["tags"] as? [String] ?? []) + (inner["tags"] as? [String] ?? [])
            func tag(_ name: String) -> String? { tags.first { $0.hasPrefix(name + ":") }.map { String($0.dropFirst(name.count + 1)) } }
            var title = (inner["title"] as? String) ?? (attributes["title"] as? String) ?? ""
            if title.isEmpty { title = (attributes["message"] as? String)?.split(separator: "\n").first.map(String.init) ?? "" }
            let monitor = inner["monitor"] as? [String: Any]
            let idValue = (inner["monitor_id"] as? NSNumber)?.int64Value ?? (monitor?["id"] as? NSNumber)?.int64Value ?? tag("monitor_id").flatMap { Int64($0) }
            guard let id = idValue, let at = buildTime(attributes["timestamp"]) else { continue }
            if let monitorIds, !monitorIds.contains(id) { continue }
            if let service = tag("service"), DeployHidden.matches(service, hidden) { continue }
            if let env = tag("env"), !DeployEnv.isProd(env) { continue }
            let status = ((inner["status"] as? String) ?? (attributes["status"] as? String) ?? "").lowercased()
            let lead = title.lowercased()
            let kind: Kind
            if status == "ok" || status == "success" || lead.hasPrefix("[recovered") || lead.hasPrefix("[resolved") {
                kind = .recovered
            } else if status == "warn" || status == "warning" || lead.hasPrefix("[warn") {
                kind = .warn
            } else if ["error", "alert", "critical", "emergency"].contains(status) || lead.hasPrefix("[triggered") || lead.hasPrefix("[alert") || lead.hasPrefix("[re-triggered") {
                kind = .alert
            } else {
                continue
            }
            out.append(ProdTimelineEntry(kind: kind, at: at, title: String(cleaned(title).prefix(120)), detail: nil, key: "m:\(id)"))
        }
        return out
    }

    /// "[Triggered on {host:a}] API errors" → "API errors".
    static func cleaned(_ title: String) -> String {
        var text = title.trimmingCharacters(in: .whitespaces)
        while text.hasPrefix("["), let close = text.firstIndex(of: "]") {
            text = String(text[text.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        }
        return text.isEmpty ? title : text
    }

    /// Watchdog stories of any status, and the deployments, from an events answer.
    static func stories(_ data: Data, hidden: Set<String>) -> [ProdTimelineEntry]? {
        guard let list = Watchdog.events(data) else { return nil }
        var out: [ProdTimelineEntry] = []
        for event in list where !event.title.isEmpty {
            let service = event.tag("service")
            if let service { if DeployHidden.matches(service, hidden) { continue } } else if DeployHidden.names(in: event.title, hidden) { continue }
            if let env = event.tag("env"), !DeployEnv.isProd(env) { continue }
            if event.isDeploy {
                guard let service else { continue }
                var version = event.tag("version")
                if version == nil, let colon = event.title.lastIndex(of: ":") { version = event.title[event.title.index(after: colon)...].trimmingCharacters(in: .whitespaces) }
                guard let version, !version.isEmpty else { continue }
                out.append(ProdTimelineEntry(kind: .deploy, at: event.at, title: "\(service) \(version)", detail: event.tag("previous_version").map { "from \($0)" },
                                             key: "d:\(service):\(version)"))
            } else if event.tags.contains(where: { $0.hasPrefix("story_") || $0 == "source:watchdog" }) {
                out.append(ProdTimelineEntry(kind: .watchdog, at: event.at, title: String(event.title.prefix(120)), detail: event.tag("story_status"),
                                             key: "w:\(event.storyKey ?? event.id)", hasStoryKey: event.storyKey != nil))
            }
        }
        return out
    }

    /// Incidents opened, and resolved, from an incident search's list (the raw `incidents` array).
    static func incidents(_ list: [[String: Any]], hidden: Set<String>) -> [ProdTimelineEntry] {
        var out: [ProdTimelineEntry] = []
        for wrapper in list {
            guard let data = wrapper["data"] as? [String: Any], let id = data["id"] as? String else { continue }
            let attributes = data["attributes"] as? [String: Any] ?? [:]
            if DeployHidden.incident(attributes, hidden: hidden) { continue }
            let public_ = (attributes["public_id"] as? NSNumber)?.intValue
            let severity = (attributes["severity"] as? String).flatMap { $0 == "UNKNOWN" ? nil : $0 }
            let title = ((attributes["title"] as? String)?.nonEmpty ?? "Incident")
            let line = [severity, public_.map { "#\($0)" }].compactMap { $0 }.joined(separator: " · ")
            let shown = String((line.isEmpty ? title : "\(line) \(title)").prefix(120))
            if let created = buildTime(attributes["created"]) {
                out.append(ProdTimelineEntry(kind: .incidentOpened, at: created, title: shown, detail: nil, key: "i:\(id)", publicId: public_))
            }
            if let resolved = buildTime(attributes["resolved"]) {
                out.append(ProdTimelineEntry(kind: .incidentResolved, at: resolved, title: shown, detail: nil, key: "i:\(id)", publicId: public_))
            }
        }
        return out
    }

    /// The monitors that are not OK now, at their last trigger (the search's own timestamp): what
    /// is open shows even when the events could not be read.
    static func triggers(_ monitors: [ProdMonitor]) -> [ProdTimelineEntry] {
        monitors.compactMap { monitor in
            guard let at = monitor.triggeredAt, at > 0, monitor.status == "Alert" || monitor.status == "Warn" else { return nil }
            return ProdTimelineEntry(kind: monitor.status == "Alert" ? .alert : .warn, at: at, title: monitor.name, detail: nil, key: "m:\(monitor.id)")
        }
    }
}

// MARK: What the app asks, and what it got

/// What the actor keeps for the page between ticks.
struct PageState {
    var open = false
    var range = ProdRange.day
    /// The monitors the configured query covers (for the alert events), and whether the list is all of them.
    var monitorIds: Set<Int64> = []
    var monitorIdsComplete = false
    var incidentEntries: [ProdTimelineEntry] = []
    /// The last Watchdog request's answer (24 hours of stories and deployments), read again for
    /// 1 h and 24 h instead of asking again.
    var eventsData: (data: Data, at: Double)?
    /// Per range: what was read and when.
    var series: [ProdRange: (series: [ProdSeries], at: Double)] = [:]
    var alerts: [ProdRange: (entries: [ProdTimelineEntry], at: Double)] = [:]
    var events: [ProdRange: (entries: [ProdTimelineEntry], at: Double)] = [:]
    var notes: [String: String] = [:]
    var published = ProdPageData()
}

/// What the page shows from Datadog, handed to the main thread when it changed.
struct ProdPageData: Equatable, Sendable {
    var range = ProdRange.day
    var series: [ProdSeries] = []
    var seriesAt: Double = 0
    /// Datadog's entries: alerts and recoveries, incidents, deploys, Watchdog stories.
    var remote: [ProdTimelineEntry] = []
    var remoteAt: Double = 0
    /// Why a part is missing, by part: "series", "alerts", "events".
    var notes: [String: String] = [:]
    /// The page's own requests in the last hour.
    var requestsLastHour = 0
}

/// How often the page reads while it is open, and its hourly allowance.
enum ProdPagePlan {
    static let seriesEvery: Double = 60
    static let alertsEvery: Double = 120
    /// The 7-day events request (Watchdog and deploys), the other ranges read what the poller has.
    static let weekEventsEvery: Double = 300
    static let hourlyCap = 240

    /// Requests an hour while the page stays open: one series request per number a minute, the
    /// alert events every 2 minutes, and, on 7 d, the events every 5.
    static func perHourOpen(numbers: Int, range: ProdRange) -> Int {
        Int(3600 / seriesEvery) * numbers + Int(3600 / alertsEvery) + (range == .week ? Int(3600 / weekEventsEvery) : 0)
    }
}

// MARK: The local history

/// What this app itself saw, for the timeline when Datadog has no history to give: a small file,
/// bounded to 7 days and 300 entries. No file in a preview unless CLAUDE_NOTCH_PROD_HISTORY says where.
enum ProdHistoryFile {
    static var url: URL? {
        if let path = ProcessInfo.processInfo.environment["CLAUDE_NOTCH_PROD_HISTORY"], !path.isEmpty { return URL(fileURLWithPath: path) }
        if CommandLine.arguments.contains("--preview") { return nil }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/notch/prod-history.json")
    }

    static func load(_ url: URL?, now: Double) -> [ProdTimelineEntry] {
        guard let url, let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([ProdTimelineEntry].self, from: data) else { return [] }
        return ProdTimeline.bounded(entries, now: now)
    }

    static func save(_ entries: [ProdTimelineEntry], to url: URL?) {
        guard let url, let data = try? JSONEncoder().encode(entries) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// The page's model on the main thread: Datadog's data, the local history, the range and whether it is open.
@MainActor
final class ProdPageModel: ObservableObject {
    @Published private(set) var data = ProdPageData()
    @Published private(set) var local: [ProdTimelineEntry]
    @Published private(set) var range: ProdRange
    /// Told when the page opens, closes or changes its range, so the source reads only then.
    var onVisibility: ((Bool, ProdRange) -> Void)?
    private(set) var isOpen = false
    private let file: URL?

    init(file: URL? = ProdHistoryFile.url, range: ProdRange = .saved(), now: Double = Date().timeIntervalSince1970) {
        self.file = file
        self.range = range
        local = ProdHistoryFile.load(file, now: now)
    }

    func setOpen(_ open: Bool) {
        guard open != isOpen else { return }
        isOpen = open
        onVisibility?(open, range)
    }

    func setRange(_ next: ProdRange) {
        guard next != range else { return }
        range = next
        next.save()
        onVisibility?(isOpen, next)
    }

    func take(_ next: ProdPageData) {
        if next != data { data = next }
    }

    /// What this app saw: kept in the file, bounded.
    func record(_ entry: ProdTimelineEntry, now: Double = Date().timeIntervalSince1970) {
        let next = ProdTimeline.bounded(local, adding: entry, now: now)
        guard next != local else { return }
        local = next
        ProdHistoryFile.save(next, to: file)
    }

    func timeline(now: Double, current: [ProdTimelineEntry]) -> [ProdTimelineEntry] {
        ProdTimeline.merge(remote: data.remote + current, local: local, now: now, range: range)
    }
}
