import Foundation

// Deploy checks for Prod, the part that needs no network: which service a push belongs to, when
// to look, what a version's numbers are, how a new version compares with the one before it, which
// errors are new, the deploys list, the Watchdog stories, and the request budget. DatadogSource
// (Datadog.swift) does the fetching with these; the self-check (DeployCheckSelfCheck.swift) runs
// all of it on made-up answers.
//
// What it reads (all read only, with the Datadog sign-in or the keys):
//   POST /api/v2/query/timeseries  (timeseries_query): hits, errors and p95 of the service's
//       APM trace metrics, by env and version, over the last day. One request gives the deploys
//       list (when the busiest version changed), the new and the previous version, and the verdict.
//   POST /api/v2/query/scalar      (apm_read): the service's error spans, counted by `@version`,
//       `@error.type` and resource; the errors the new version has and the previous one has not.
//       When the version did not change after the push (many services report one constant
//       version), the spans after the push and the 20 minutes before it, grouped without version.
//   GET  /api/v2/events            (events_read): `source:(watchdog OR change_tracking)` in one
//       request: Watchdog's stories, and APM deployment events for the deploys list.

/// `prod` and `production` are one environment.
enum DeployEnv {
    static func isProd(_ env: String) -> Bool { ["prod", "production"].contains(env.lowercased()) }
}

/// Services the user hides (builds.json `hiddenServices`, "leads*" by default). An entry ending in
/// `*` names the service and its family: "leads*" is "leads" and anything starting "leads-". Any
/// other entry is that one service. All lowercase.
enum DeployHidden {
    static func matches(_ service: String, _ hidden: Set<String>) -> Bool {
        let name = service.lowercased()
        return hidden.contains { entry in
            let entry = entry.lowercased()
            guard entry.hasSuffix("*") else { return name == entry }
            let base = String(entry.dropLast())
            return !base.isEmpty && (name == base || name.hasPrefix(base + "-"))
        }
    }

    /// The text (a title) names a hidden service as a word of its own ("New error logs on leads").
    static func names(in text: String, _ hidden: Set<String>) -> Bool {
        text.lowercased().split { !($0.isLetter || $0.isNumber || "-_.".contains($0)) }.contains { matches(String($0), hidden) }
    }

    /// An incident of a hidden service: the service its fields name (`fields.services` or
    /// `fields.service`, a string or a list, as the incidents API gives them) or, with none, a title
    /// that names one.
    static func incident(_ attributes: [String: Any], hidden: Set<String>) -> Bool {
        if hidden.isEmpty { return false }
        var services: [String] = []
        let fields = attributes["fields"] as? [String: Any] ?? [:]
        for key in ["services", "service"] {
            let value = (fields[key] as? [String: Any])?["value"] ?? fields[key]
            if let text = value as? String { services.append(text) }
            if let list = value as? [String] { services += list }
        }
        if !services.isEmpty { return services.contains { matches($0, hidden) } }
        return names(in: attributes["title"] as? String ?? "", hidden)
    }

    /// The `service:<name>` words inside a monitor's query.
    static func services(inQuery query: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"(?i)\bservice:\s*["']?([A-Za-z0-9_.\-]+)"#) else { return [] }
        let range = NSRange(query.startIndex..., in: query)
        return regex.matches(in: query, range: range).compactMap { match in
            Range(match.range(at: 1), in: query).map { String(query[$0]) }
        }
    }
}

/// The Datadog service a repository deploys as, and the trace operation whose metrics are read
/// (`trace.<operation>.hits`; "http.request" unless builds.json says another).
struct DeployLink: Equatable, Sendable {
    var service: String
    var operation: String

    static let defaultOperation = "http.request"

    /// Letters, digits and . _ - : only: the value goes into a metric query.
    static func clean(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 120,
              value.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "._-:".unicodeScalars.contains($0) }) else { return nil }
        return value
    }
}

/// The 20 minutes after a push in which a linked service is watched (the same 20 minutes the
/// session row's Prod line uses).
enum DeployWindow {
    static let seconds: Double = 1200
    static func isOpen(pushedAt: Double, now: Double) -> Bool { now >= pushedAt && now - pushedAt < seconds }
}

// MARK: Which service a push belongs to

enum DeployRepo {
    /// The `services` entry for a folder: the key may be "workspace/repo", the repo's name alone,
    /// or the folder's own name; case does not matter. Nil: no entry, no deploy check.
    static func link(folder: String, repo: String?, services: [String: DeployLink]) -> DeployLink? {
        let name = URL(fileURLWithPath: folder).lastPathComponent
        var keys: [String] = []
        if let repo {
            keys.append(repo)
            if let slug = repo.split(separator: "/").last { keys.append(String(slug)) }
        }
        keys.append(name)
        for key in keys { if let link = services[key.lowercased()] { return link } }
        return nil
    }

    /// For each linked service, when a session of its repo last pushed, for the pushes still inside
    /// the 20 minutes. A service `hidden` names is never listed.
    static func pushes(sessions: [(folder: String, shippedAt: Double?)], repos: [String: String], services: [String: DeployLink],
                       hidden: Set<String>, now: Double) -> [String: Double] {
        var out: [String: Double] = [:]
        for session in sessions {
            guard let at = session.shippedAt, DeployWindow.isOpen(pushedAt: at, now: now),
                  let link = link(folder: session.folder, repo: repos[session.folder], services: services),
                  !DeployHidden.matches(link.service, hidden) else { continue }
            out[link.service] = max(out[link.service] ?? 0, at)
        }
        return out
    }
}

// MARK: When to look, and the budget

/// The hourly Datadog cap is 150. The standing polls take, with two numbers: monitors 60, incidents
/// 20, numbers 24, Watchdog 4 = 108. Deploy checks get what is left, less a reserve of 6, and never
/// more than 40, so the worst hour is 144 with two numbers.
enum DeployBudget {
    static let monitorsPerHour = 60
    static let incidentsPerHour = 20
    static let perNumberPerHour = 12
    static let watchdogPerHour = 4
    static let reserve = 6
    static let most = 40

    static func standing(numbers: Int) -> Int {
        monitorsPerHour + incidentsPerHour + perNumberPerHour * numbers + watchdogPerHour
    }

    /// Requests an hour the deploy checks may use.
    static func allowance(numbers: Int, cap: Int) -> Int {
        max(0, min(most, cap - standing(numbers: numbers) - reserve))
    }

    /// The most requests an hour all of Prod can make.
    static func worstCase(numbers: Int, cap: Int) -> Int {
        standing(numbers: numbers) + allowance(numbers: numbers, cap: cap)
    }
}

/// What to ask for now. A service is read only inside its 20 minutes: the series every minute, the
/// error spans every 3 minutes once there is something to compare, and nothing past the
/// allowance of the last hour. The service read longest ago goes first, so one busy service
/// cannot starve the others of the allowance.
enum DeployPlanner {
    static let seriesEvery: Double = 60
    static let errorsEvery: Double = 180
    static let watchdogEvery: Double = 900

    enum Kind: Equatable { case series, errors }
    struct Due: Equatable { var service: String; var kind: Kind }

    /// `beforeNeeded`: services whose error read must also fetch the 20 minutes before the push
    /// (a second request, the first time after each push).
    static func due(pushes: [String: Double], now: Double, lastSeries: [String: Double], lastErrors: [String: Double],
                    wantsErrors: Set<String>, beforeNeeded: Set<String> = [], slow: Double, used: Int, allowance: Int) -> [Due] {
        var out: [Due] = []
        var left = allowance - used
        let order = pushes.keys.sorted { (lastSeries[$0] ?? 0, $0) < (lastSeries[$1] ?? 0, $1) }
        for service in order {
            guard let at = pushes[service], DeployWindow.isOpen(pushedAt: at, now: now), left >= 1 else { continue }
            if now - (lastSeries[service] ?? 0) >= seriesEvery * slow {
                out.append(Due(service: service, kind: .series))
                left -= 1
            }
            let cost = beforeNeeded.contains(service) ? 2 : 1
            if left >= cost, wantsErrors.contains(service), now - (lastErrors[service] ?? 0) >= errorsEvery * slow {
                out.append(Due(service: service, kind: .errors))
                left -= cost
            }
        }
        return out
    }
}

// MARK: Numbers and the verdict

/// A version's numbers over a window. `p95` is in seconds, as the trace metrics give it.
struct VersionStats: Equatable, Sendable {
    var hits: Double
    var errors: Double
    var p95: Double?
    var minutes: Double

    var errorPercent: Double { hits > 0 ? errors / hits * 100 : 0 }
    var perMinute: Double { minutes > 0 ? hits / minutes : 0 }
    var p95ms: Double? { p95.map { $0 * 1000 } }
}

struct DeployVerdict: Equatable, Sendable {
    enum State: String, Sendable { case collecting, noPrevious, worse, better, same }
    enum Move: String, Sendable { case up = "▲", down = "▼", flat = "" }
    /// How a part of the line reads: only the worse parts are red, the better ones green.
    enum Tone: Sendable { case bad, good, plain }
    struct Part: Equatable, Sendable {
        var text: String
        var tone: Tone
    }

    var version: String
    var previous: String?
    /// Set when the numbers are the time since the push against an equal stretch before it (the
    /// version did not change): the stretch's minutes, 0 while there is too little of it.
    var sinceMinutes: Int?
    var state: State
    var errors: Move
    var latency: Move
    var traffic: Move
    /// The traffic fell to 40% or less of a service that had some.
    var trafficDropped = false
    var new: VersionStats
    var old: VersionStats?

    /// Too few requests on the new version to say anything.
    static let minHits: Double = 20

    /// `ready` false (the stretch since the push is under two buckets) says "collecting" whatever
    /// the counts.
    static func make(version: String, previous: String?, new: VersionStats, old: VersionStats?, sinceMinutes: Int? = nil, ready: Bool = true) -> DeployVerdict {
        func verdict(_ state: State, _ e: Move = .flat, _ l: Move = .flat, _ t: Move = .flat, dropped: Bool = false, old: VersionStats? = nil) -> DeployVerdict {
            DeployVerdict(version: version, previous: previous, sinceMinutes: sinceMinutes, state: state, errors: e, latency: l, traffic: t,
                          trafficDropped: dropped, new: new, old: old)
        }
        guard ready, new.hits >= minHits else { return verdict(.collecting) }
        guard let old, old.hits >= minHits, previous != nil || sinceMinutes != nil else { return verdict(.noPrevious) }
        // Errors: half a point and half as much again, either way.
        var errors = Move.flat
        if new.errorPercent - old.errorPercent >= 0.5, new.errorPercent >= old.errorPercent * 1.5 { errors = .up }
        if old.errorPercent - new.errorPercent >= 0.5, new.errorPercent <= old.errorPercent * 0.67 { errors = .down }
        // p95: 15% slower or faster, and at least 20 ms.
        var latency = Move.flat
        if let n = new.p95ms, let o = old.p95ms {
            if n >= o * 1.15, n - o >= 20 { latency = .up }
            if n <= o / 1.15, o - n >= 20 { latency = .down }
        }
        // Traffic: halved or doubled.
        var traffic = Move.flat
        if old.perMinute > 0 {
            if new.perMinute <= old.perMinute * 0.5 { traffic = .down }
            if new.perMinute >= old.perMinute * 2 { traffic = .up }
        }
        // Worse: more errors, slower, or the traffic down to 40% of a service that had some.
        let dropped = traffic == .down && new.perMinute <= old.perMinute * 0.4 && old.perMinute >= 5
        if errors == .up || latency == .up || dropped { return verdict(.worse, errors, latency, traffic, dropped: dropped, old: old) }
        if errors == .down || latency == .down { return verdict(.better, errors, latency, traffic, old: old) }
        return verdict(.same, errors, latency, traffic, old: old)
    }

    static func name(_ version: String) -> String {
        version.first?.isNumber == true ? "v\(version)" : version
    }

    static func percent(_ value: Double) -> String { String(format: value < 10 ? "%.1f%%" : "%.0f%%", value) }
    private static func percentNumber(_ value: Double) -> String { String(format: value < 10 ? "%.1f" : "%.0f", value) }

    /// A latency without its unit; `seconds` says whether it is told in seconds (one decimal) or ms.
    static func milliseconds(_ value: Double, seconds: Bool? = nil) -> String {
        (seconds ?? (value >= 1000)) ? String(format: "%.1f", value / 1000) : "\(Int(value.rounded()))"
    }

    /// "v1.4.2 vs v1.4.1", or "since push · 14m vs 14m before".
    var headline: String {
        if let minutes = sinceMinutes { return minutes > 0 ? "since push · \(minutes)m vs \(minutes)m before" : "since push" }
        guard let previous else { return Self.name(version) }
        return "\(Self.name(version)) vs \(Self.name(previous))"
    }

    /// The numbers, short enough for one line of the card: "errors 0.4→2.1% ▲", "p95 180→210ms ▲",
    /// "129→127/min". Empty while collecting.
    var parts: [Part] {
        func mark(_ move: Move) -> String { move == .flat ? "" : " \(move.rawValue)" }
        func tone(_ move: Move) -> Tone { move == .up ? .bad : move == .down ? .good : .plain }
        switch state {
        case .collecting:
            return []
        case .noPrevious:
            var out = [Part(text: "errors \(Self.percent(new.errorPercent))", tone: .plain)]
            if let ms = new.p95ms { out.append(Part(text: "p95 \(Self.milliseconds(ms))\(ms >= 1000 ? "s" : "ms")", tone: .plain)) }
            return out
        case .worse, .better, .same:
            guard let old else { return [] }
            var out = [Part(text: "errors \(Self.percentNumber(old.errorPercent))→\(Self.percent(new.errorPercent))\(mark(errors))", tone: tone(errors))]
            if let n = new.p95ms, let o = old.p95ms {
                let seconds = max(n, o) >= 1000
                out.append(Part(text: "p95 \(Self.milliseconds(o, seconds: seconds))→\(Self.milliseconds(n, seconds: seconds))\(seconds ? "s" : "ms")\(mark(latency))", tone: tone(latency)))
            }
            out.append(Part(text: "\(Int(old.perMinute.rounded()))→\(Int(new.perMinute.rounded()))/min\(mark(traffic))", tone: trafficDropped ? .bad : .plain))
            return out
        }
    }

    /// Whether the card shows the colored parts (else it shows `line` plainly).
    var comparesNumbers: Bool { state == .worse || state == .better || state == .same }

    /// "v1.4.2 vs v1.4.1: errors 0.4→2.1% ▲ · p95 180→210ms ▲ · 120→118/min".
    var line: String {
        let scope = sinceMinutes != nil ? "since push" : Self.name(version)
        switch state {
        case .collecting:
            return "\(scope): collecting, \(Int(new.hits)) requests so far"
        case .noPrevious:
            return "\(scope): " + parts.map(\.text).joined(separator: " · ") + (sinceMinutes != nil ? " (nothing before the push to compare)" : " (nothing earlier to compare)")
        case .worse, .better, .same:
            return "\(headline): " + parts.map(\.text).joined(separator: " · ")
        }
    }
}

// MARK: The series

/// One bucket of a version's numbers, `t` in seconds since 1970.
struct DeployBucket: Equatable, Sendable {
    var hits: Double
    var errors: Double
    /// Seconds.
    var p95: Double?
}

struct DeployEntry: Equatable, Sendable {
    var version: String
    var previous: String
    /// When the version became the busiest one.
    var at: Double
}

enum DeployAnalysis {
    typealias Merged = [String: [Double: DeployBucket]]

    struct Result: Equatable, Sendable {
        var deploys: [DeployEntry] = []
        var current: String?
        var previous: String?
        var changedAt: Double?
        var new: VersionStats?
        var old: VersionStats?
    }

    /// The longest window the two versions are compared over.
    static let longest: Double = 3600
    /// The version name of series with no version tag.
    static let untagged = "untagged"

    /// The time since a push against an equal stretch just before it, for a service whose version
    /// did not change. Whole buckets only: from the first bucket after the push to the last
    /// complete one. `ready` needs two of them.
    struct Since: Equatable, Sendable {
        var minutes: Int
        var ready: Bool
        var new: VersionStats?
        var old: VersionStats?
    }

    static func sincePush(_ merged: Merged, pushedAt: Double, now: Double, interval: Double) -> Since {
        let total = totals(merged)
        let first = (pushedAt / interval).rounded(.up) * interval
        let end = (now / interval).rounded(.down) * interval
        let count = Int(((end - first) / interval).rounded())
        guard count >= 2 else {
            return Since(minutes: 0, ready: false, new: stats(total, from: first, to: now + interval, minutes: max(1, (now - first) / 60), interval: interval), old: nil)
        }
        let length = Double(count) * interval
        return Since(minutes: Int((length / 60).rounded()), ready: true,
                     new: stats(total, from: first, to: end, minutes: length / 60, interval: interval),
                     old: stats(total, from: first - length, to: first, minutes: length / 60, interval: interval))
    }

    /// What the card shows for a service: the new version against the previous one when the
    /// version changed after the push (or a bucket before it), else, since many services report one
    /// constant version, the time since the push against an equal stretch before it.
    struct Comparison: Equatable, Sendable {
        var analysis: Result
        var verdict: DeployVerdict?
        /// The push the numbers are counted from; set only for the since-push comparison.
        var sincePushAt: Double?
        var note: String?
    }

    static func compare(_ merged: Merged, pushedAt: Double?, now: Double, interval: Double) -> Comparison {
        let analysis = analyze(merged, now: now, interval: interval)
        var out = Comparison(analysis: analysis)
        let changed = analysis.changedAt.map { at in pushedAt.map { at >= $0 - interval } ?? true } ?? false
        if changed || pushedAt == nil {
            if let version = analysis.current, let new = analysis.new {
                out.verdict = DeployVerdict.make(version: version, previous: analysis.previous, new: new, old: analysis.old)
            }
            return out
        }
        guard let pushedAt, let version = analysis.current else { return out }
        let since = sincePush(merged, pushedAt: pushedAt, now: now, interval: interval)
        out.sincePushAt = pushedAt
        if let new = since.new {
            out.verdict = DeployVerdict.make(version: version, previous: nil, new: new, old: since.old, sinceMinutes: since.minutes, ready: since.ready)
        } else {
            out.note = "Since the push: no requests yet"
        }
        return out
    }

    /// Every version's buckets added up: the service as a whole.
    static func totals(_ merged: Merged) -> [Double: DeployBucket] {
        var out: [Double: DeployBucket] = [:]
        var weighted: [Double: (sum: Double, weight: Double)] = [:]
        for buckets in merged.values {
            for (t, bucket) in buckets {
                var total = out[t] ?? DeployBucket(hits: 0, errors: 0, p95: nil)
                total.hits += bucket.hits
                total.errors += bucket.errors
                out[t] = total
                if let p = bucket.p95 {
                    let w = max(bucket.hits, 1)
                    let before = weighted[t] ?? (0, 0)
                    weighted[t] = (before.sum + p * w, before.weight + w)
                }
            }
        }
        for (t, pair) in weighted where pair.weight > 0 { out[t]?.p95 = pair.sum / pair.weight }
        return out
    }

    /// Parses a timeseries answer into one set of buckets per version, `prod` and `production`
    /// merged (counts added, p95 weighted by requests). Series are told apart by `query_index`:
    /// 0 hits, 1 errors, 2 p95. Series of another env are left out; one with no version tag is
    /// the version "untagged" (a constant version still compares since the push).
    static func parse(_ data: Data) -> Merged? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let attributes = (object["data"] as? [String: Any])?["attributes"] as? [String: Any],
              let series = attributes["series"] as? [[String: Any]],
              let times = (attributes["times"] as? [Any])?.map({ (($0 as? NSNumber)?.doubleValue ?? 0) / 1000 }),
              let values = attributes["values"] as? [[Any]] else { return nil }
        struct Key: Hashable { var version: String; var env: String; var t: Double }
        var hits: [Key: Double] = [:], errors: [Key: Double] = [:], p95: [Key: Double] = [:]
        for (index, item) in series.enumerated() where index < values.count {
            let tags = item["group_tags"] as? [String] ?? []
            let env = tags.first { $0.hasPrefix("env:") }.map { String($0.dropFirst(4)) } ?? "prod"
            guard DeployEnv.isProd(env) else { continue }
            var version = tags.first(where: { $0.hasPrefix("version:") }).map { String($0.dropFirst(8)) } ?? ""
            if version.isEmpty || version == "N/A" { version = untagged }
            let kind = (item["query_index"] as? NSNumber)?.intValue ?? index % 3
            for (slot, raw) in values[index].enumerated() where slot < times.count {
                guard let value = (raw as? NSNumber)?.doubleValue, value.isFinite else { continue }
                let key = Key(version: version, env: env.lowercased(), t: times[slot])
                switch kind {
                case 0: hits[key, default: 0] += value
                case 1: errors[key, default: 0] += value
                default: p95[key] = value
                }
            }
        }
        // One bucket per version and time: counts added over the envs, p95 weighted by requests.
        var merged: Merged = [:]
        var weighted: [String: [Double: (sum: Double, weight: Double)]] = [:]
        for key in Set(hits.keys).union(errors.keys).union(p95.keys) {
            var bucket = merged[key.version]?[key.t] ?? DeployBucket(hits: 0, errors: 0, p95: nil)
            bucket.hits += hits[key] ?? 0
            bucket.errors += errors[key] ?? 0
            merged[key.version, default: [:]][key.t] = bucket
            if let p = p95[key] {
                let w = max(hits[key] ?? 0, 1)
                let before = weighted[key.version]?[key.t] ?? (0, 0)
                weighted[key.version, default: [:]][key.t] = (before.sum + p * w, before.weight + w)
            }
        }
        for (version, byTime) in weighted {
            for (t, pair) in byTime where pair.weight > 0 { merged[version]?[t]?.p95 = pair.sum / pair.weight }
        }
        return merged
    }

    /// The deploys (the busiest version changing), and the current version against the one before
    /// it over the same length of time. A version that is busiest for a single bucket between two
    /// buckets of another is a straggler, not a deploy.
    static func analyze(_ merged: Merged, now: Double, interval: Double) -> Result {
        var runs: [(version: String, start: Double, length: Int)] = []
        for t in Set(merged.values.flatMap(\.keys)).sorted() {
            var busiest: (String, Double)?
            for (version, buckets) in merged {
                guard let hits = buckets[t]?.hits, hits >= 1 else { continue }
                if let best = busiest, hits < best.1 || (hits == best.1 && version > best.0) { continue }
                busiest = (version, hits)
            }
            guard let busiest else { continue }
            if runs.last?.version == busiest.0 { runs[runs.count - 1].length += 1 } else { runs.append((busiest.0, t, 1)) }
        }
        var i = 1
        while i < runs.count - 1 {
            if runs[i].length == 1, runs[i - 1].version == runs[i + 1].version {
                runs[i - 1].length += 1 + runs[i + 1].length
                runs.removeSubrange(i...(i + 1))
                i = max(1, i - 1)
            } else {
                i += 1
            }
        }
        var result = Result()
        for index in runs.indices.dropFirst() {
            result.deploys.append(DeployEntry(version: runs[index].version, previous: runs[index - 1].version, at: runs[index].start))
        }
        result.deploys.reverse()
        guard let last = runs.last else { return result }
        result.current = last.version
        guard runs.count >= 2 else {
            // One version all day: its last quarter hour, with nothing to compare it to.
            let from = max(last.start, now - 900)
            result.new = stats(merged[last.version], from: from, to: now + interval, minutes: max(1, (now - from) / 60), interval: interval)
            return result
        }
        let before = runs[runs.count - 2]
        result.previous = before.version
        result.changedAt = last.start
        let from = max(last.start, now - longest)
        let length = max(60, now - from)
        result.new = stats(merged[last.version], from: from, to: now + interval, minutes: length / 60, interval: interval)
        result.old = stats(merged[before.version], from: last.start - length, to: last.start, minutes: length / 60, interval: interval)
        return result
    }

    private static func stats(_ buckets: [Double: DeployBucket]?, from: Double, to: Double, minutes: Double, interval: Double) -> VersionStats? {
        guard let buckets else { return nil }
        var hits = 0.0, errors = 0.0, weighted = 0.0, weight = 0.0
        for (t, bucket) in buckets where t + interval > from && t < to {
            hits += bucket.hits
            errors += bucket.errors
            if let p95 = bucket.p95 {
                weighted += p95 * max(bucket.hits, 1)
                weight += max(bucket.hits, 1)
            }
        }
        guard hits > 0 else { return nil }
        return VersionStats(hits: hits, errors: errors, p95: weight > 0 ? weighted / weight : nil, minutes: minutes)
    }
}

// MARK: New errors

struct NewError: Equatable, Sendable {
    var type: String?
    var resource: String?
    var count: Int

    var line: String {
        [type, resource].compactMap { $0 }.joined(separator: " · ") + " · \(count)×"
    }
}

enum DeployErrors {
    struct Row: Equatable, Sendable {
        var version: String
        var type: String?
        var resource: String?
        var count: Int
    }

    /// Errors with no error type are known by their resource.
    private static func key(_ row: Row) -> String { row.type.map { "t:\($0)" } ?? "r:\(row.resource ?? "?")" }

    /// The error types (or resources, when a span has no type) the new version has and the previous
    /// one has not, the commonest first. Without a previous version nothing is new.
    static func newOnes(_ rows: [Row], version: String, previous: String?, limit: Int = 3) -> [NewError] {
        guard let previous else { return [] }
        let seenBefore = Set(rows.filter { $0.version == previous }.map(key))
        var merged: [String: NewError] = [:]
        var top: [String: Int] = [:]
        for row in rows where row.version == version && !seenBefore.contains(key(row)) {
            let k = key(row)
            var entry = merged[k] ?? NewError(type: row.type, resource: nil, count: 0)
            entry.count += row.count
            if row.count > top[k] ?? 0 { top[k] = row.count; entry.resource = row.resource }
            merged[k] = entry
        }
        return Array(merged.values.sorted { $0.count != $1.count ? $0.count > $1.count : $0.line < $1.line }.prefix(limit))
    }

    /// The error types the spans after a push have and the stretch before it did not (for a service
    /// whose version did not change).
    static func newSince(after: [Row], before: [Row], limit: Int = 3) -> [NewError] {
        let rows = after.map { Row(version: "after", type: $0.type, resource: $0.resource, count: $0.count) }
            + before.map { Row(version: "before", type: $0.type, resource: $0.resource, count: $0.count) }
        return newOnes(rows, version: "after", previous: "before", limit: limit)
    }

    /// Parses a scalar answer grouped by `@version` (optional), `@error.type` and `resource_name`.
    /// Rows without a version column carry the version "all".
    static func parse(_ data: Data) -> [Row]? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let columns = ((object["data"] as? [String: Any])?["attributes"] as? [String: Any])?["columns"] as? [[String: Any]] else { return nil }
        func text(_ value: Any?) -> String? {
            let raw = (value as? String) ?? (value as? [String])?.first
            guard let raw, !raw.isEmpty, raw != "N/A", raw != "null" else { return nil }
            return raw
        }
        func group(_ names: String...) -> [Any]? {
            columns.first { ($0["type"] as? String) == "group" && names.contains($0["name"] as? String ?? "") }?["values"] as? [Any]
        }
        guard let counts = columns.first(where: { ($0["type"] as? String) != "group" })?["values"] as? [Any] else { return nil }
        let versions = group("@version", "version"), types = group("@error.type", "error.type"), resources = group("resource_name")
        return counts.indices.compactMap { index in
            guard let count = (counts[index] as? NSNumber)?.intValue, count > 0 else { return nil }
            let version = versions.flatMap { index < $0.count ? text($0[index]) : nil } ?? (versions == nil ? "all" : DeployAnalysis.untagged)
            return Row(version: version, type: types.flatMap { index < $0.count ? text($0[index]) : nil },
                       resource: resources.flatMap { index < $0.count ? text($0[index]) : nil }, count: count)
        }
    }
}

// MARK: What Prod shows

struct DeployReport: Equatable, Sendable {
    var service: String
    /// When it was last read.
    var at: Double
    var version: String?
    var previous: String?
    var changedAt: Double?
    /// The push the numbers are counted from, when the version did not change after it.
    var sincePushAt: Double?
    var verdict: DeployVerdict?
    var newErrors: [NewError] = []
    /// The recent deploys, newest first (the series' own; the card adds the deploy events).
    var deploys: [DeployEntry] = []
    /// Why there is no verdict ("no version tag on its traces").
    var note: String?

    /// Shown for an hour after it was last read, then dropped.
    static let keepFor: Double = 3600
    var isWorse: Bool { verdict?.state == .worse }

    /// "v1.4.2 · 12 min ago".
    func deployLine(_ entry: DeployEntry, now: Double) -> String {
        "\(DeployVerdict.name(entry.version)) · \(ago(max(0, now - entry.at)))"
    }
}

struct WatchdogStory: Equatable, Sendable {
    var id: String
    var title: String
    var service: String?
    var at: Double
    /// From the event's `story_status` tag ("ongoing"); Datadog sends no priority.
    var status: String?
}

/// A deployment Datadog's APM deployment tracking noticed: `source:change_tracking`, titled
/// "New APM Deployment Version: <v>", tagged service, version and previous_version.
struct DeployEvent: Equatable, Sendable {
    var service: String
    var version: String
    var previous: String?
    var at: Double
}

enum Watchdog {
    /// A story with no status tag is active for this long.
    static let activeFor: Double = 3600
    /// How far back the one events request reaches: the deploy events' (the deploys list's day).
    static let lookback: Double = 86400

    /// One request for both: Watchdog's stories and the deploy events, newest first.
    static func items(now: Double) -> [URLQueryItem] {
        [URLQueryItem(name: "filter[query]", value: "source:(watchdog OR change_tracking)"),
         URLQueryItem(name: "filter[from]", value: String(Int64((now - lookback) * 1000))),
         URLQueryItem(name: "filter[to]", value: String(Int64(now * 1000))),
         URLQueryItem(name: "page[limit]", value: "100"),
         URLQueryItem(name: "sort", value: "-timestamp")]
    }

    private struct Event {
        var id: String
        var title: String
        var tags: [String]
        var at: Double
        func tag(_ name: String) -> String? { tags.first { $0.hasPrefix(name + ":") }.map { String($0.dropFirst(name.count + 1)) } }
        var isDeploy: Bool { title.hasPrefix("New APM Deployment Version") || tags.contains("source:change_tracking") }
    }

    private static func events(_ data: Data) -> [Event]? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = object["data"] as? [[String: Any]] else { return nil }
        return list.map { event in
            let attributes = event["attributes"] as? [String: Any] ?? [:]
            let inner = attributes["attributes"] as? [String: Any] ?? [:]
            let tags = (attributes["tags"] as? [String] ?? []) + (inner["tags"] as? [String] ?? [])
            var title = (inner["title"] as? String) ?? (attributes["title"] as? String) ?? ""
            if title.isEmpty { title = (attributes["message"] as? String)?.split(separator: "\n").first.map(String.init) ?? "" }
            var all = tags
            if !tags.contains(where: { $0.hasPrefix("service:") }), let service = inner["service"] as? String { all.append("service:\(service)") }
            return Event(id: event["id"] as? String ?? title, title: title, tags: all, at: buildTime(attributes["timestamp"]) ?? 0)
        }
    }

    /// The active stories in an events answer, newest first, one per title and service. Left out:
    /// deploy events, other environments, resolved stories (`story_status`), those with no status
    /// older than an hour, and a hidden service's, by its `service` tag or, without one, a title
    /// that names it ("New error logs were detected on leads").
    static func parse(_ data: Data, hidden: Set<String>, now: Double) -> [WatchdogStory]? {
        guard let list = events(data) else { return nil }
        var seen = Set<String>()
        var out: [WatchdogStory] = []
        for event in list where !event.isDeploy {
            let service = event.tag("service")
            if let service {
                if DeployHidden.matches(service, hidden) { continue }
            } else if DeployHidden.names(in: event.title, hidden) {
                continue
            }
            if let env = event.tag("env"), !DeployEnv.isProd(env) { continue }
            let status = event.tag("story_status")?.lowercased()
            if let status { guard status == "ongoing" else { continue } } else if now - event.at >= activeFor { continue }
            guard !event.title.isEmpty, seen.insert(event.title + "|" + (service ?? "")).inserted else { continue }
            out.append(WatchdogStory(id: event.id, title: String(event.title.prefix(120)), service: service, at: event.at, status: status))
        }
        return out
    }

    /// The deploy events in the same answer, newest first.
    static func parseDeploys(_ data: Data, hidden: Set<String>) -> [DeployEvent]? {
        guard let list = events(data) else { return nil }
        return list.compactMap { event in
            guard event.isDeploy, let service = event.tag("service"), !DeployHidden.matches(service, hidden) else { return nil }
            if let env = event.tag("env"), !DeployEnv.isProd(env) { return nil }
            var version = event.tag("version")
            if version == nil, let colon = event.title.lastIndex(of: ":") { version = event.title[event.title.index(after: colon)...].trimmingCharacters(in: .whitespaces) }
            guard let version, !version.isEmpty else { return nil }
            return DeployEvent(service: service, version: version, previous: event.tag("previous_version"), at: event.at)
        }
    }

    /// The story in Datadog's web app, on the org's own site.
    static func storyURL(site: String, id: String) -> URL? {
        URL(string: "https://\(DatadogConfig.webHost(site))/watchdog/story/\(id)")
    }
}

/// The deploys list of a service: what the metrics' busiest version showed, and Datadog's own
/// deployment events. An event wins over the same version seen in the metrics within an hour.
enum DeployFeed {
    static func merge(_ series: [DeployEntry], events: [DeployEvent], service: String, limit: Int = 5) -> [DeployEntry] {
        let mine = events.filter { $0.service.lowercased() == service.lowercased() }
        let fromEvents = mine.map { DeployEntry(version: $0.version, previous: $0.previous ?? "", at: $0.at) }
        let kept = series.filter { entry in !mine.contains { $0.version == entry.version && abs($0.at - entry.at) < 3600 } }
        return Array((fromEvents + kept).sorted { $0.at > $1.at }.prefix(limit))
    }
}

/// Why deploy checks show nothing, kept per kind of request: a note is cleared only when that
/// kind succeeds, so a held error read keeps saying why while the series read is fine.
struct DeployNotes: Equatable, Sendable {
    private var byKind: [String: String] = [:]
    mutating func set(_ kind: String, _ text: String) { byKind[kind] = text }
    mutating func clear(_ kind: String) { byKind[kind] = nil }
    /// The note to show: the series'; else the errors'.
    var text: String? { byKind["deploys"] ?? byKind["errors"] }
    func note(_ kind: String) -> String? { byKind[kind] }
}

// MARK: Sign-in scopes

enum DeployScopes {
    static let deployMissing = "Sign in again to see deploy checks"
    static let watchdogMissing = "Sign in again to see Watchdog"
    static let errorsMissing = "Sign in again to see new errors"

    /// What is missing from a sign-in's scopes, as the note Prod shows. Nil when the scope is there
    /// (or the keys are in use: Datadog's answer tells then).
    static func note(granted: [String]?, needs scope: String, message: String) -> String? {
        guard let granted else { return nil }
        return granted.contains(scope) ? nil : message
    }
}

// MARK: The requests' bodies

enum DeployQueries {
    /// The series' bucket, and how far back it reads (the deploys list's reach).
    static let interval: Double = 300
    static let lookback: Double = 86400
    /// `prod` and `production` are the only two prod env tags.
    static let env = "(env:prod OR env:production)"

    /// hits, errors and p95 of `trace.<operation>` by env and version: the query_index of each
    /// series is the order here (0, 1, 2).
    static func seriesBody(_ link: DeployLink, now: Double) -> Data? {
        let scope = "{service:\(link.service) AND \(env)} by {env,version}"
        let trace = "trace.\(link.operation)"
        let body: [String: Any] = ["data": ["type": "timeseries_request", "attributes": [
            "from": Int64((now - lookback) * 1000), "to": Int64(now * 1000), "interval": Int64(interval * 1000),
            "queries": [
                ["data_source": "metrics", "name": "hits", "query": "sum:\(trace).hits\(scope).as_count()"],
                ["data_source": "metrics", "name": "errors", "query": "sum:\(trace).errors\(scope).as_count()"],
                ["data_source": "metrics", "name": "p95", "query": "p95:\(trace)\(scope)"],
            ],
            "formulas": [["formula": "hits"], ["formula": "errors"], ["formula": "p95"]],
        ]]]
        return try? JSONSerialization.data(withJSONObject: body)
    }

    /// The service's error spans from `from` to `to`, counted by `@version` (the span facet; plain
    /// `version` matches nothing), error type and resource. `byVersion` false leaves the version
    /// out, for the since-push comparison.
    static func errorsBody(_ link: DeployLink, from: Double, to: Double, byVersion: Bool = true) -> Data? {
        func facet(_ name: String) -> [String: Any] { ["facet": name, "limit": 50, "sort": ["aggregation": "count", "order": "desc"]] }
        let groups = (byVersion ? [facet("@version")] : []) + [facet("@error.type"), facet("resource_name")]
        let body: [String: Any] = ["data": ["type": "scalar_request", "attributes": [
            "from": Int64(from * 1000), "to": Int64(to * 1000),
            "queries": [["data_source": "spans", "name": "errors", "compute": ["aggregation": "count"],
                         "search": ["query": "service:\(link.service) \(env) status:error"],
                         "group_by": groups]],
            "formulas": [["formula": "errors"]],
        ]]]
        return try? JSONSerialization.data(withJSONObject: body)
    }
}
