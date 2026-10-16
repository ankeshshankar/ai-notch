import Foundation

// Prod health from Datadog, for the footer's Prod chip: the monitors a search query picks, the
// active incidents, and a few numbers. Read only, with a read-only application key; the notch
// never mutes, resolves or changes anything in Datadog. ProdStore.swift turns the snapshots into
// what the notch shows and notifies.
//
// Endpoints (Datadog's OpenAPI spec): GET /api/v1/monitor/search (monitors_read),
// GET /api/v2/incidents/search (incident_read, public beta), POST /api/v2/query/scalar
// (timeseries_query). With "Sign in with Datadog" (DatadogAuth.swift) a bearer token, else the
// headers DD-API-KEY and DD-APPLICATION-KEY.

enum DatadogConfig {
    /// The Keychain items (generic passwords): one service, two accounts.
    static let keyService = "ai-notch.datadog"
    static let apiKeyAccount = "api-key"
    static let appKeyAccount = "app-key"

    /// "us3" → "us3.datadoghq.com", "us1" → "datadoghq.com", "eu" → "datadoghq.eu"; a domain stays.
    static func domain(_ site: String) -> String {
        var text = site.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://", "http://", "app.", "api."] where text.hasPrefix(prefix) { text.removeFirst(prefix.count) }
        while text.hasSuffix("/") { text.removeLast() }
        switch text {
        case "", "us", "us1", "datadoghq.com": return "datadoghq.com"
        case "eu", "eu1", "datadoghq.eu": return "datadoghq.eu"
        case "gov", "us1-fed", "ddog-gov.com": return "ddog-gov.com"
        default: return text.contains(".") ? text : "\(text).datadoghq.com"
        }
    }

    /// Dev only: a stub server instead of the site's API (CLAUDE_NOTCH_DATADOG_API).
    static var stubBase: String? { ProcessInfo.processInfo.environment["CLAUDE_NOTCH_DATADOG_API"]?.nonEmpty }

    static func apiBase(_ site: String) -> String { stubBase ?? "https://api.\(site)" }

    /// The web app's host: app.datadoghq.com (US1), app.datadoghq.eu (EU1), app.ddog-gov.com,
    /// else the site itself (us3, us5, ap1: "us3.datadoghq.com").
    static func webHost(_ site: String) -> String {
        switch site {
        case "datadoghq.com", "datadoghq.eu", "ddog-gov.com": return "app.\(site)"
        default: return site
        }
    }

    // The web links. Datadog does not document these URL patterns; they are what its app shows in
    // the address bar, and all of them are built here so a change is one edit.

    static func monitorURL(site: String, id: Int64) -> URL? {
        URL(string: "https://\(webHost(site))/monitors/\(id)")
    }

    static func incidentURL(site: String, incident: ProdIncident) -> URL? {
        URL(string: "https://\(webHost(site))/incidents/\(incident.publicId.map(String.init) ?? incident.id)")
    }

    /// The Manage Monitors list filtered by the configured query.
    static func monitorsListURL(site: String, query: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = webHost(site)
        components.path = "/monitors/manage"
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }

    /// The command Setup shows for each key: read from the clipboard, which is then cleared
    /// (typing a secret at the interactive `-w` prompt keeps only its first 128 characters).
    static func saveCommand(_ account: String) -> String {
        "security add-generic-password -U -s \(keyService) -a \(account) -w \"$(pbpaste)\" && pbcopy < /dev/null"
    }

    /// builds.json's `datadog` part, with neutral values: Setup shows it and the README repeats it.
    static let example = """
    "datadog": {
      "site": "us3",
      "monitors": "(service:api AND env:production) OR service:gateway",
      "incidents": "state:active",
      "health": [
        { "label": "5xx", "unit": "%", "amber": 2, "aggregator": "sum",
          "queries": {
            "a": "sum:trace.http.request.hits.by_http_status{service:api,env:production,http.status_class:5xx}.as_count()",
            "b": "sum:trace.http.request.hits.by_http_status{service:api,env:production}.as_count()"
          },
          "formula": "100 * a / b" },
        { "label": "p95", "unit": "ms", "scale": 1000, "amber": 1000,
          "query": "p95:trace.http.request{service:api,env:production}" }
      ]
    }
    """

    /// The Datadog side, for an admin: a service account and its keys.
    static let adminSteps = [
        "Organization Settings → Service Accounts → New Service Account, role Datadog Read Only Role.",
        "Open it → New Key (an application key). In the key's panel, edit its scopes to monitors_read, incident_read and timeseries_query.",
        "Organization Settings → API Keys → New Key.",
    ]

    static let setupHelp = "Not connected. Sign in with Datadog in Setup → Prod, or have a Datadog admin create a service account with a read-only application key (monitors_read, incident_read, timeseries_query) and an API key and store both in the Keychain as \(keyService) (accounts \(apiKeyAccount) and \(appKeyAccount)). Setup lists the steps."
}

struct ProdMonitor: Equatable, Sendable {
    var id: Int64
    var name: String
    /// Alert, Warn, No Data, OK, Ignored, Skipped, Unknown.
    var status: String
}

struct ProdIncident: Equatable, Sendable {
    var id: String
    var publicId: Int?
    var title: String
    /// SEV-0 … SEV-5, UNKNOWN.
    var severity: String?
    var state: String
    var createdAt: Double?
}

/// A health number as shown: already scaled to its unit.
struct ProdNumber: Equatable, Sendable {
    var label: String
    var value: Double?
    var unit: String
    var amber: Double?

    var isOver: Bool {
        guard let value, let amber else { return false }
        return value > amber
    }

    /// "0.8%", "93ms", "1.2s", "–" with no data.
    var valueText: String {
        guard let value, value.isFinite else { return "–" }
        switch unit {
        case "%": return String(format: value < 10 ? "%.1f%%" : "%.0f%%", value)
        case "ms": return value >= 1000 ? String(format: "%.1fs", value / 1000) : "\(Int(value.rounded()))ms"
        default:
            let number = abs(value) >= 100 ? String(format: "%.0f", value) : String(format: "%.2g", value)
            return number + (unit.isEmpty ? "" : unit.count == 1 ? unit : " \(unit)")
        }
    }
}

struct ProdSnapshot: Equatable, Sendable {
    enum Access: Equatable, Sendable {
        /// No `datadog` part in builds.json.
        case notConfigured
        /// Not signed in, and no keys in the Keychain.
        case noKeys
        /// Datadog refused the sign-in's refresh token (expired, revoked), and there are no keys: why.
        case signInAgain(String)
        /// Datadog refused the keys (401, or 403 on the monitor search): why, in a sentence.
        case rejected(String)
        case ok
    }

    var access: Access = .notConfigured
    /// Reading with the Datadog sign-in (else the keys).
    var viaSignIn = false
    /// Something passing: offline, rate limited, a server error, a query Datadog refused.
    var problem: SourceStatus?
    var site = ""
    var monitorQuery = ""
    /// When the monitor search last answered; 0 before.
    var monitorsAt: Double = 0
    var monitorTotal = 0
    /// Monitors by status, from the search's facets (muted ones are left out of the search).
    var statusCounts: [String: Int] = [:]
    /// The monitors not OK (Alert, Warn, No Data), Alert first.
    var monitors: [ProdMonitor] = []
    var incidentsOn = false
    var incidentsAt: Double = 0
    var incidents: [ProdIncident] = []
    /// Why incidents are not read ("needs incident_read").
    var incidentsNote: String?
    var numbersAt: Double = 0
    var numbers: [ProdNumber] = []
    var numbersNote: String?
    var requestsLastHour = 0

    var alertCount: Int { statusCounts["Alert"] ?? monitors.filter { $0.status == "Alert" }.count }
    var warnCount: Int { statusCounts["Warn"] ?? monitors.filter { $0.status == "Warn" }.count }
}

/// No redirects: the keys stay with the host they were meant for.
private final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private enum DatadogHTTP {
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.timeoutIntervalForRequest = 20
        config.httpAdditionalHeaders = ["User-Agent": "AI-Notch"]
        return URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
    }()
}

/// Polls on the cooperative pool (never the main thread) and hands a snapshot to `onChange` only
/// when it changed. Each kind of request has its own pace, and a rate limit on one holds only it:
///
/// - monitors every 60 s (every 3 minutes while the screen is locked),
/// - incidents every 3 minutes,
/// - the numbers every 5 minutes, one request each, not while locked.
///
/// About 104 requests an hour unlocked with two numbers, 40 locked; a hard cap of 150.
actor DatadogSource {
    enum Kind: String, CaseIterable { case monitors, incidents, numbers }

    /// The credential in use: the Datadog sign-in (preferred), or the API and application keys.
    private enum Via: Equatable { case signIn, keys }

    private let onChange: @Sendable (ProdSnapshot) -> Void
    private var config: BuildsConfig.Datadog?
    private var via: Via?
    private var keys: (api: KeychainItem.Found, app: KeychainItem.Found)?
    private var keysCheckedAt: Double = -.infinity
    /// The fingerprint of keys Datadog refused: the same ones read again are not retried.
    private var rejected: String?
    private var wantsKeys = false
    private var snapshot = ProdSnapshot()
    private var last = ProdSnapshot()
    private var lastSentAt: Double = 0
    private var fetchedAt: [Kind: Double] = [:]
    /// A kind held back by a rate limit (429, or few requests left) until then.
    private var holdUntil: [Kind: Double] = [:]
    /// A 403 on incidents or the numbers (a missing scope): tried again after an hour.
    private var noAccessUntil: [Kind: Double] = [:]
    private var slowUntil: Double = 0
    private var requests: [Double] = []
    private var loop: Task<Void, Never>?
    private var countLoggedAt: Double = 0

    static let hourlyCap = 150
    /// Dev: every kind at this pace instead (CLAUDE_NOTCH_DATADOG_EVERY=<seconds>).
    static let testEvery = Double(ProcessInfo.processInfo.environment["CLAUDE_NOTCH_DATADOG_EVERY"] ?? "")

    init(onChange: @escaping @Sendable (ProdSnapshot) -> Void) {
        self.onChange = onChange
    }

    func start() {
        guard loop == nil else { return }
        loop = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Setup's Check Again: the Keychain is read at once and everything is fetched again.
    func recheck() async {
        await DatadogAuth.shared.reload()
        keysCheckedAt = -.infinity
        rejected = nil
        wantsKeys = true
        noAccessUntil = [:]
        fetchedAt = [:]
    }

    private var now: Double { Date().timeIntervalSince1970 }

    private func interval(_ kind: Kind, locked: Bool) -> Double? {
        let slow: Double = now < slowUntil ? 2 : 1
        if let every = Self.testEvery { return every * slow }
        switch kind {
        case .monitors: return (locked ? 180 : 60) * slow
        case .incidents: return 180 * slow
        case .numbers: return locked ? nil : 300 * slow
        }
    }

    // MARK: The schedule

    private func tick() async {
        let now = self.now
        let config = BuildsConfig.current?.datadog
        if config != self.config {
            if config?.site != self.config?.site || config?.monitors != self.config?.monitors {
                // Another site or query: what was read no longer stands.
                let access = snapshot.access
                snapshot = ProdSnapshot()
                snapshot.access = access
            }
            self.config = config
            fetchedAt = [:]
        }
        guard let config else {
            snapshot = ProdSnapshot()
            return publish()
        }
        snapshot.site = config.site
        snapshot.monitorQuery = config.monitors
        snapshot.incidentsOn = config.incidents != nil
        if config.incidents == nil { snapshot.incidents = []; snapshot.incidentsNote = nil }
        if config.health.isEmpty { snapshot.numbers = []; snapshot.numbersNote = nil }

        // The sign-in first: an in-memory check, no request. Without one (or once it ended),
        // the keys as before.
        let signIn = await DatadogAuth.shared.availability(site: config.site)
        if case .signedIn = signIn {
            if via != .signIn {
                via = .signIn
                fetchedAt = [:]
                if snapshot.access != .ok { snapshot.access = .ok }
                noteBuildLog("datadog: reading with the Datadog sign-in")
            }
        } else if via == .signIn {
            via = nil
            fetchedAt = [:]
        }
        snapshot.viaSignIn = via == .signIn

        if via != .signIn, keys == nil {
            // Missing keys are looked for every 2 minutes (at once on Check Again); after a
            // rejection every minute, so re-saved keys are picked up by themselves.
            let every: Double = wantsKeys || rejected != nil ? 60 : 120
            if wantsKeys || now - keysCheckedAt > every {
                keysCheckedAt = now
                wantsKeys = false
                if let found = Self.readKeys() {
                    let print = found.api.fingerprint + found.app.fingerprint
                    if print != rejected {
                        noteBuildLog(rejected != nil ? "datadog: new keys found" : "datadog: keys found")
                        keys = found
                        rejected = nil
                        snapshot.access = .ok
                        fetchedAt = [:]
                    }
                } else if rejected == nil {
                    snapshot.access = .noKeys
                }
            }
        }
        if via != .signIn { via = keys != nil ? .keys : nil }
        guard via != nil else {
            switch (signIn, snapshot.access) {
            case (.ended(let why), _): snapshot.access = .signInAgain(why)
            case (_, .rejected): break
            default: snapshot.access = .noKeys
            }
            return publish()
        }

        let locked = BuildPolling.isScreenLocked
        requests.removeAll { now - $0 > 3600 }
        for kind in Kind.allCases {
            guard via != nil else { break }
            if kind == .incidents, config.incidents == nil { continue }
            if kind == .numbers, config.health.isEmpty { continue }
            guard let every = interval(kind, locked: locked) else { continue }
            if let until = noAccessUntil[kind], now < until { continue }
            if now < holdUntil[kind] ?? 0 { continue }
            guard now - (fetchedAt[kind] ?? 0) >= every else { continue }
            let cost = kind == .numbers ? config.health.count : 1
            guard requests.count + cost <= Self.hourlyCap else {
                if snapshot.problem == nil {
                    snapshot.problem = SourceStatus(text: "paused", help: "AI Notch's own cap of \(Self.hourlyCap) Datadog requests an hour was reached; it goes on as the hour rolls over.")
                }
                break
            }
            fetchedAt[kind] = now
            switch kind {
            case .monitors: await fetchMonitors(config)
            case .incidents: await fetchIncidents(config)
            case .numbers: await fetchNumbers(config)
            }
        }
        publish()
        logCountIfDue()
    }

    // MARK: Requests

    /// One request with the sign-in's bearer token or the keys, counted against the hourly cap.
    /// Handles what changes the schedule: 401 (with the sign-in: renewed once and retried; with
    /// the keys, and 403 on the monitor search: rejected), 403 on incidents or the numbers (a
    /// missing scope), 429 and few requests left (that kind waits for the reset).
    private func send(_ kind: Kind, _ url: URL, body: Data? = nil, retried: Bool = false) async -> Data? {
        guard let via else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 20)
        var bearer: String?
        switch via {
        case .keys:
            guard let keys else { return nil }
            request.setValue(keys.api.secret, forHTTPHeaderField: "DD-API-KEY")
            request.setValue(keys.app.secret, forHTTPHeaderField: "DD-APPLICATION-KEY")
        case .signIn:
            switch await DatadogAuth.shared.credential(site: snapshot.site) {
            case .bearer(let token):
                bearer = token
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            case .ended(let why):
                signInEnded(why)
                return nil
            case .unavailable(let why):
                snapshot.problem = SourceStatus(text: "offline", help: why)
                return nil
            case .none:
                self.via = nil
                return nil
            }
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        requests.append(now)
        let started = Date()
        guard let (data, response) = try? await DatadogHTTP.session.data(for: request),
              let http = response as? HTTPURLResponse else {
            snapshot.problem = SourceStatus(text: "offline", help: "Datadog did not answer; it is tried again on the next poll.")
            return nil
        }
        if ProcessInfo.processInfo.environment["CLAUDE_NOTCH_BUILD_TIMING"] != nil {
            FileHandle.standardError.write(Data("datadog \(kind.rawValue) \(http.statusCode) \(url.path) \(data.count)B \(String(format: "%.2f", Date().timeIntervalSince(started)))s\n".utf8))
        }
        let header = { (name: String) in http.value(forHTTPHeaderField: name).flatMap { Double($0.trimmingCharacters(in: .whitespaces)) } }
        let limit = header("X-RateLimit-Limit"), remaining = header("X-RateLimit-Remaining")
        let reset = header("X-RateLimit-Reset") ?? header("Retry-After")
        let bucket = http.value(forHTTPHeaderField: "X-RateLimit-Name") ?? kind.rawValue
        switch http.statusCode {
        case 200..<300:
            // Few requests left in this window: wait for the reset rather than meet a 429.
            if let limit, let remaining, remaining <= max(1, (limit / 10).rounded(.down)) {
                let wait = max(5, reset ?? 60)
                holdUntil[kind] = now + wait
                noteBuildLog("datadog: \(bucket) has \(Int(remaining)) of \(Int(limit)) requests left, \(kind.rawValue) waits \(Int(wait)) s")
            }
            return data
        case 401 where bearer != nil:
            // A stale or revoked access token: renewed once, and the request sent again.
            if !retried, let bearer, case .bearer = await DatadogAuth.shared.unauthorized(access: bearer) {
                noteBuildLog("datadog: 401 on \(url.path), sign-in renewed, sent again")
                return await send(kind, url, body: body, retried: true)
            }
            if case .ended(let why) = await DatadogAuth.shared.availability(site: snapshot.site) {
                signInEnded(why)
            } else {
                snapshot.problem = SourceStatus(text: "sign-in refused", help: "Datadog answered 401 to a renewed sign-in; tried again on the next poll.")
            }
            return nil
        case 401:
            reject("Datadog refused the API key (401): wrong, revoked, or for another site than \(snapshot.site).")
            return nil
        case 403 where kind == .monitors && bearer != nil:
            // The user's role (or the granted scopes) cannot read monitors: held for 10 minutes.
            noAccessUntil[kind] = now + 600
            snapshot.access = .rejected("Datadog refused the monitor search (403): your Datadog role lacks monitors_read, or it was not granted at sign-in. Tried again in 10 minutes.")
            noteBuildLog("datadog: 403 on the monitor search with the sign-in; tried again in 10 minutes")
            return nil
        case 403 where kind == .monitors:
            reject("Datadog refused the keys on the monitor search (403): the application key lacks monitors_read, or the two keys belong to different organizations.")
            return nil
        case 403:
            noAccessUntil[kind] = now + 3600
            let scope = kind == .incidents ? "incident_read" : "timeseries_query"
            if kind == .incidents { snapshot.incidentsNote = "needs \(scope)" } else { snapshot.numbersNote = "needs \(scope)" }
            noteBuildLog("datadog: 403 on \(url.path), \(bearer != nil ? "the sign-in" : "the application key") lacks \(scope); tried again in an hour")
            return nil
        case 429:
            let wait = max(10, reset ?? 60)
            holdUntil[kind] = now + wait
            slowUntil = now + 900
            snapshot.problem = SourceStatus(text: "rate limited", help: "Datadog asked to slow down (\(bucket)); \(kind.rawValue) waits \(Int(wait)) s, then everything runs at half pace for 15 minutes.")
            noteBuildLog("datadog: 429 on \(bucket), \(kind.rawValue) waits \(Int(wait)) s, half pace for 15 minutes")
            return nil
        default:
            let message = Self.errorText(data)
            if http.statusCode == 400, kind == .numbers {
                snapshot.numbersNote = "query refused: \(message ?? "400")"
            } else if http.statusCode == 400, kind == .incidents {
                snapshot.incidentsNote = "query refused: \(message ?? "400")"
            } else {
                snapshot.problem = SourceStatus(text: http.statusCode == 400 ? "query refused" : "Datadog error \(http.statusCode)",
                                                help: "\(url.path) answered \(http.statusCode)\(message.map { ": \($0)" } ?? ""). Tried again on the next poll.")
            }
            noteBuildLog("datadog: \(http.statusCode) on \(url.path)\(message.map { ": \($0)" } ?? "")")
            return nil
        }
    }

    /// The sign-in's refresh token was refused: the keys, if any, take over on the next tick.
    private func signInEnded(_ why: String) {
        via = nil
        fetchedAt = [:]
        snapshot.viaSignIn = false
        snapshot.access = .signInAgain(why)
    }

    private func reject(_ why: String) {
        guard let keys else { return }
        rejected = keys.api.fingerprint + keys.app.fingerprint
        self.keys = nil
        keysCheckedAt = now
        snapshot.access = .rejected(why)
        noteBuildLog("datadog: keys rejected: \(why)")
    }

    /// The `errors` of a Datadog error answer, in one line (never echoes a request header).
    private static func errorText(_ data: Data) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let errors: [String]
        if let list = object["errors"] as? [Any] {
            errors = list.compactMap { ($0 as? String) ?? (($0 as? [String: Any])?["detail"] as? String) ?? (($0 as? [String: Any])?["title"] as? String) }
        } else if let text = object["errors"] as? String {
            errors = [text]
        } else {
            errors = []
        }
        let line = errors.joined(separator: "; ").split(whereSeparator: \.isNewline).joined(separator: " ")
        return line.isEmpty ? nil : String(line.prefix(200))
    }

    private func url(_ path: String, _ items: [URLQueryItem]) -> URL? {
        guard let config, var components = URLComponents(string: DatadogConfig.apiBase(config.site) + path) else { return nil }
        components.queryItems = items
        // `+` would read as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }

    // MARK: Monitors

    /// One search: the configured query without muted monitors (they count as OK), 100 a page.
    /// The badge comes from the status facets; the names from the page.
    private func fetchMonitors(_ config: BuildsConfig.Datadog) async {
        guard let url = url("/api/v1/monitor/search", [
            URLQueryItem(name: "query", value: "(\(config.monitors)) AND muted:false"),
            URLQueryItem(name: "per_page", value: "100"),
        ]), let data = await send(.monitors, url) else { return }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = object["monitors"] as? [[String: Any]] else {
            snapshot.problem = SourceStatus(text: "unexpected answer", help: "The monitor search answered without a monitors list.")
            return
        }
        var counts: [String: Int] = [:]
        for facet in ((object["counts"] as? [String: Any])?["status"] as? [[String: Any]]) ?? [] {
            if let name = facet["name"] as? String, let count = (facet["count"] as? NSNumber)?.intValue { counts[name] = count }
        }
        let monitors = list.compactMap { item -> ProdMonitor? in
            guard let id = (item["id"] as? NSNumber)?.int64Value else { return nil }
            return ProdMonitor(id: id, name: item["name"] as? String ?? "Monitor \(id)", status: item["status"] as? String ?? "Unknown")
        }
        if counts.isEmpty { for monitor in monitors { counts[monitor.status, default: 0] += 1 } }
        let rank = ["Alert": 0, "Warn": 1, "No Data": 2]
        snapshot.monitors = monitors.filter { rank[$0.status] != nil }
            .sorted { (rank[$0.status] ?? 9, $0.name) < (rank[$1.status] ?? 9, $1.name) }
        snapshot.statusCounts = counts
        snapshot.monitorTotal = ((object["metadata"] as? [String: Any])?["total_count"] as? NSNumber)?.intValue ?? monitors.count
        snapshot.monitorsAt = now
        snapshot.access = .ok
        snapshot.problem = nil
    }

    // MARK: Incidents

    private func fetchIncidents(_ config: BuildsConfig.Datadog) async {
        guard let query = config.incidents,
              let url = url("/api/v2/incidents/search", [URLQueryItem(name: "query", value: query), URLQueryItem(name: "page[size]", value: "25")]),
              let data = await send(.incidents, url) else { return }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let attributes = (object["data"] as? [String: Any])?["attributes"] as? [String: Any],
              let list = attributes["incidents"] as? [[String: Any]] else {
            snapshot.incidentsNote = "unexpected answer"
            return
        }
        snapshot.incidents = list.compactMap { wrapper -> ProdIncident? in
            guard let data = wrapper["data"] as? [String: Any], let id = data["id"] as? String else { return nil }
            let attributes = data["attributes"] as? [String: Any] ?? [:]
            let state = (attributes["state"] as? String ?? "active").lowercased()
            guard state != "resolved" else { return nil }
            return ProdIncident(id: id, publicId: (attributes["public_id"] as? NSNumber)?.intValue,
                                title: (attributes["title"] as? String)?.nonEmpty ?? "Incident",
                                severity: (attributes["severity"] as? String).flatMap { $0 == "UNKNOWN" ? nil : $0 },
                                state: state, createdAt: buildTime(attributes["created"]))
        }
        .sorted { ($0.createdAt ?? 0) > ($1.createdAt ?? 0) }
        snapshot.incidentsAt = now
        snapshot.incidentsNote = nil
    }

    // MARK: Numbers

    /// One scalar request per number, over its window; a request that fails leaves its number
    /// as it was.
    private func fetchNumbers(_ config: BuildsConfig.Datadog) async {
        guard let url = url("/api/v2/query/scalar", []) else { return }
        var numbers = snapshot.numbers.count == config.health.count ? snapshot.numbers : config.health.map {
            ProdNumber(label: $0.label, value: nil, unit: $0.unit, amber: $0.amber)
        }
        var anyAnswered = false
        for (index, health) in config.health.enumerated() {
            guard via != nil, now >= noAccessUntil[.numbers] ?? 0, now >= holdUntil[.numbers] ?? 0 else { break }
            let to = (now * 1000).rounded()
            let body: [String: Any] = ["data": ["type": "scalar_request", "attributes": [
                "from": Int64(to - health.window * 1000), "to": Int64(to),
                "queries": health.queries.map { ["data_source": "metrics", "name": $0.name, "query": $0.query, "aggregator": health.aggregator] },
                "formulas": [["formula": health.formula]],
            ]]]
            guard let json = try? JSONSerialization.data(withJSONObject: body), let data = await send(.numbers, url, body: json) else { continue }
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            let columns = ((object["data"] as? [String: Any])?["attributes"] as? [String: Any])?["columns"] as? [[String: Any]] ?? []
            let names = Set(health.queries.map(\.name))
            let numberColumns = columns.filter { ($0["type"] as? String) != "group" && $0["values"] is [Any] }
            // The formula's column; with a single query it may carry the query's name.
            let column = numberColumns.first { !names.contains($0["name"] as? String ?? "") } ?? numberColumns.first
            let raw = ((column?["values"] as? [Any])?.first as? NSNumber)?.doubleValue
            numbers[index] = ProdNumber(label: health.label, value: raw.map { $0 * health.scale }, unit: health.unit, amber: health.amber)
            anyAnswered = true
            if raw == nil, let errors = object["errors"] as? String, !errors.isEmpty {
                snapshot.numbersNote = String(errors.prefix(200))
            }
        }
        snapshot.numbers = numbers
        if anyAnswered {
            snapshot.numbersAt = now
            if numbers.allSatisfy({ $0.value != nil }) { snapshot.numbersNote = nil }
        }
    }

    // MARK: Publishing

    private func publish() {
        var next = snapshot
        next.requestsLastHour = requests.filter { now - $0 <= 3600 }.count
        var compare = next
        compare.requestsLastHour = last.requestsLastHour
        // The request count alone changes every poll: sent at most once a minute.
        guard compare != last || (next.requestsLastHour != last.requestsLastHour && now - lastSentAt > 60) else { return }
        last = next
        lastSentAt = now
        onChange(next)
    }

    /// Dev: with CLAUDE_NOTCH_BUILD_TIMING, the rolling count every 5 minutes on stderr.
    private func logCountIfDue() {
        guard ProcessInfo.processInfo.environment["CLAUDE_NOTCH_BUILD_TIMING"] != nil, now - countLoggedAt >= 300 else { return }
        countLoggedAt = now
        FileHandle.standardError.write(Data("datadog requests: \(requests.count) in the last hour\n".utf8))
    }

    private static func readKeys() -> (api: KeychainItem.Found, app: KeychainItem.Found)? {
        // Dev: a stub's keys from a file (two lines: API key, application key), which a test
        // rewrites like re-saved Keychain items. Only with a stub server.
        if DatadogConfig.stubBase != nil, let file = ProcessInfo.processInfo.environment["CLAUDE_NOTCH_DATADOG_TEST_KEYS_FILE"] {
            let lines = ((try? String(contentsOfFile: file, encoding: .utf8)) ?? "").split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard lines.count >= 2 else { return nil }
            return (KeychainItem.Found(secret: lines[0], account: DatadogConfig.apiKeyAccount),
                    KeychainItem.Found(secret: lines[1], account: DatadogConfig.appKeyAccount))
        }
        guard let api = KeychainItem.read(service: DatadogConfig.keyService, account: DatadogConfig.apiKeyAccount),
              let app = KeychainItem.read(service: DatadogConfig.keyService, account: DatadogConfig.appKeyAccount) else { return nil }
        return (api, app)
    }
}
