import Foundation
import SQLite3

// Cursor's agent keeps no token counts on disk, so its usage comes from the same usage events
// Cursor's own dashboard lists: one per model request, with tokens and what the plan counted for
// it. The sign-in is the one Cursor already holds (read from its settings database), and it is
// sent to cursor.com and nowhere else: never logged, never written to disk.
//
// Shape: `CursorUsageSource` (off main, read-only) fetches pages and parses them; `CursorLedger`
// folds the events into per-day, per-model totals that `UsageScanner` keeps in the usage ledger
// and publishes in its snapshot for the Usage panel.

/// One usage event from Cursor's dashboard, reduced to what the ledger needs.
struct CursorEvent: Equatable, Sendable {
    /// Conversation + model + timestamp: the same request is never counted twice.
    var key: String
    /// When it happened, in seconds.
    var time: Double
    var model: String
    /// Tokens, and the plan usage Cursor counted for the request in dollars.
    var tally: TokenTally
}

/// One page of the dashboard's events, newest first.
struct CursorPage: Equatable, Sendable {
    var events: [CursorEvent]
    /// Rows the page held, including any that carry no usage.
    var rowCount: Int
    /// The oldest row's time, whether or not it carried usage.
    var oldest: Double?
    /// How many events the dashboard says there are in all.
    var total: Int?
}

/// Whether Cursor's usage could be read, shown as one line in the Usage panel.
enum CursorUsageStatus: Equatable, Sendable {
    /// No Cursor on this Mac: nothing to show.
    case off
    case ok
    /// Read, but some of the history could not be and is left out.
    case partial
    case unavailable(String)
}

enum CursorEvents {
    /// The dashboard's answer as events, or nil when it is not the shape Cursor documents (then
    /// Cursor usage is "unavailable" rather than guessed at).
    static func parse(_ data: Data) -> CursorPage? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              root["usageEventsDisplay"] != nil || root["totalUsageEventsCount"] != nil else { return nil }
        let rows: [[String: Any]]
        if root["usageEventsDisplay"] == nil {
            rows = []
        } else if let list = root["usageEventsDisplay"] as? [[String: Any]] {
            rows = list
        } else {
            return nil
        }
        var page = CursorPage(events: [], rowCount: rows.count, oldest: nil, total: number(root["totalUsageEventsCount"]).map { Int($0) })
        for row in rows {
            if let time = number(row["timestamp"]).map({ $0 / 1000 }) {
                page.oldest = min(page.oldest ?? time, time)
            }
            if let event = event(from: row) { page.events.append(event) }
        }
        return page
    }

    /// One row as an event. Tokens come from `tokenUsage`, or from the compact `inn`/`out`/
    /// `cacheR`/`cacheW` form some rows use. The cost is the plan usage Cursor counted: the
    /// charged cents, the token total for free credit, and nothing for a request it did not charge.
    static func event(from row: [String: Any]) -> CursorEvent? {
        guard let stamp = number(row["timestamp"]), stamp > 0 else { return nil }
        let model = (row["model"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "cursor"
        var tally = TokenTally()
        let usage = row["tokenUsage"] as? [String: Any]
        if usage == nil, row["inn"] != nil || row["out"] != nil {
            tally.input = Int(number(row["inn"]) ?? 0)
            tally.output = Int(number(row["out"]) ?? 0)
            tally.cacheRead = Int(number(row["cacheR"]) ?? 0)
            tally.cacheWrite = Int(number(row["cacheW"]) ?? 0)
        } else if let usage {
            tally.input = Int(number(usage["inputTokens"]) ?? 0)
            tally.output = Int(number(usage["outputTokens"]) ?? 0)
            tally.cacheRead = Int(number(usage["cacheReadTokens"]) ?? 0)
            tally.cacheWrite = Int(number(usage["cacheWriteTokens"]) ?? 0)
        }
        let kind = row["kind"] as? String ?? ""
        var cents = 0.0
        if kind.hasSuffix("NOT_CHARGED") {
            cents = 0
        } else if kind == "USAGE_EVENT_KIND_FREE_CREDIT" {
            cents = number(usage?["totalCents"]) ?? 0
        } else {
            cents = number(row["chargedCents"]) ?? number(usage?["totalCents"]) ?? 0
        }
        tally.cost = max(0, cents) / 100
        guard tally.total > 0 || tally.cost > 0 else { return nil }
        let conversation = row["conversationId"] as? String ?? ""
        return CursorEvent(key: "\(conversation)\u{0}\(model)\u{0}\(Int(stamp))", time: stamp / 1000, model: model, tally: tally)
    }

    /// A JSON number, or a number written as a string (timestamps arrive as strings).
    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }
}

/// Cursor's totals as the usage ledger keeps them.
struct CursorLedger: Codable, Equatable {
    /// Whether the whole history was read once. Until then each poll goes on from `nextPage`.
    var complete = false
    var nextPage = 1
    /// The newest event time seen, in seconds.
    var newestAt = 0.0
    /// Requests counted so far.
    var events = 0
    /// Day → model → tally.
    var byDay: [String: [String: TokenTally]] = [:]
    /// What each recent request was counted as, to drop repeats and to take a later, larger
    /// reading of a request that was still streaming when first seen. Once the history is
    /// complete only the last `overlap` seconds are kept, dropped when a catch-up ends (never
    /// in the middle of one, or a page that moved between chunks would be counted twice).
    var recent: [String: Record] = [:]
    /// A catch-up that needs more than one chunk of pages: the page it goes on at and the time
    /// it stops at. Fixed when it began (the newest time moves as chunks are merged) and saved
    /// with the ledger, so a restart goes on instead of starting over from a later newest time.
    var run: Run?
    /// Polls in a row that made no progress at one place (the same page again, or a page
    /// Cursor answers badly). After `maxTries` the ledger gives up on that part.
    var failures = 0
    /// Some of the history could not be read and was left out; the panel says so for good.
    var partial = false

    /// How many polls in a row may get nowhere before the ledger gives up on that part.
    static let maxTries = 4

    init() {}

    // Older ledgers have none of the newer fields.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        complete = try values.decodeIfPresent(Bool.self, forKey: .complete) ?? false
        nextPage = try values.decodeIfPresent(Int.self, forKey: .nextPage) ?? 1
        newestAt = try values.decodeIfPresent(Double.self, forKey: .newestAt) ?? 0
        events = try values.decodeIfPresent(Int.self, forKey: .events) ?? 0
        byDay = try values.decodeIfPresent([String: [String: TokenTally]].self, forKey: .byDay) ?? [:]
        recent = try values.decodeIfPresent([String: Record].self, forKey: .recent) ?? [:]
        run = try values.decodeIfPresent(Run.self, forKey: .run)
        failures = try values.decodeIfPresent(Int.self, forKey: .failures) ?? 0
        partial = try values.decodeIfPresent(Bool.self, forKey: .partial) ?? false
    }

    struct Run: Codable, Equatable {
        var page: Int
        var cutoff: Double
    }

    struct Record: Codable, Equatable {
        var day: String
        var model: String
        var time: Double
        var tally: TokenTally
    }

    /// How far back a poll reads again: a request is still being updated for a short while.
    static let overlap: Double = 3600

    var isEmpty: Bool { events == 0 }

    /// Folds events in; returns whether the totals or the bookkeeping changed. Several rows with
    /// one conversation, model and time are one request read at different points of its stream:
    /// the largest counts. With a `cutoff`, anything older is taken as counted already.
    @discardableResult
    mutating func merge(_ incoming: [CursorEvent], cutoff: Double?) -> Bool {
        var best: [String: CursorEvent] = [:]
        for event in incoming {
            if let cutoff, event.time < cutoff { continue }
            if let other = best[event.key],
               (other.tally.cost, other.tally.output) >= (event.tally.cost, event.tally.output) { continue }
            best[event.key] = event
        }
        var changed = false
        for event in best.values {
            let day = UsageScanner.day(of: event.time)
            if let old = recent[event.key] {
                guard old.tally != event.tally else { continue }
                byDay[old.day, default: [:]][old.model, default: TokenTally()].add(old.tally, sign: -1)
            } else {
                events += 1
            }
            byDay[day, default: [:]][event.model, default: TokenTally()].add(event.tally)
            recent[event.key] = Record(day: day, model: event.model, time: event.time, tally: event.tally)
            newestAt = max(newestAt, event.time)
            changed = true
        }
        return changed
    }

    /// Where the next poll starts: the saved page of the backfill or of an unfinished catch-up,
    /// else the first page, reading back `overlap` seconds before the newest request. The time
    /// to stop at is nil while the history is still being read.
    func nextRequest() -> (page: Int, cutoff: Double?) {
        guard complete else { return (nextPage, nil) }
        if let run { return (run.page, run.cutoff) }
        return (1, newestAt - Self.overlap)
    }

    /// What one chunk of a poll did to the run.
    struct Outcome: Equatable {
        var changed: Bool
        /// Whether to read the next chunk now.
        var goOn: Bool
        /// The chunk got nowhere: the same page again, or a page Cursor answers badly. Later
        /// polls try again, spaced further apart each time.
        var stalled: Bool
        /// It got nowhere `maxTries` times: that part of the history is left out and marked.
        var gaveUp: Bool
    }

    /// Folds one chunk in and moves the run on. `nextPage` is where the poll stopped (nil: it
    /// reached the end or the cutoff); `ok` is whether it got there without an error; `repeated`
    /// is that the poll saw a page it had already read; `pageFailed` is that Cursor answered a
    /// page with something unusable (not a network or sign-in problem, which are no one page's fault).
    ///
    /// While the history is first being read a repeat never ends the backfill: it keeps its page
    /// and tries again later. A catch-up that repeats just ends (what it missed is read next time).
    mutating func take(_ found: [CursorEvent], nextPage next: Int?, ok: Bool, cutoff: Double?,
                       repeated: Bool = false, pageFailed: Bool = false) -> Outcome {
        let before = events
        var changed = merge(found, cutoff: cutoff)
        let progressed = events > before
        var next = next
        // A full chunk with nothing new that still says there are more pages: a dashboard
        // that ignores the page number.
        let sameAgain = repeated || (ok && next != nil && !found.isEmpty && !progressed)
        var stalled = false
        var gaveUp = false
        if progressed, failures != 0 {
            failures = 0
            changed = true
        }
        if sameAgain, complete {
            next = nil
        } else if sameAgain || pageFailed {
            stalled = true
            // Pages read before the repeat were new: go on from where it showed. A chunk of
            // nothing new moves nowhere, so it is read again as it was.
            if sameAgain, !progressed { next = complete ? nil : nextPage }
            if !progressed {
                failures += 1
                changed = true
                if failures >= Self.maxTries {
                    failures = 0
                    // A catch-up stuck on its first page loses nothing (the next one starts there
                    // again); stuck further on, the pages after it are a gap.
                    partial = partial || !complete || (next ?? 1) > 1
                    gaveUp = true
                    next = nil
                }
            }
        }
        if let next {
            if let cutoff {
                let saved = Run(page: next, cutoff: cutoff)
                if run != saved { run = saved; changed = true }
            } else if nextPage != next {
                nextPage = next
                changed = true
            }
        } else {
            if run != nil { run = nil; changed = true }
            if complete {
                let kept = recent.count
                pruneRecent()
                if recent.count != kept { changed = true }
            } else {
                finishBackfill()
                changed = true
            }
        }
        return Outcome(changed: changed, goOn: next != nil && ok && !stalled, stalled: stalled, gaveUp: gaveUp)
    }

    /// The whole history has been read: from now on only the recent requests are remembered.
    mutating func finishBackfill() {
        complete = true
        nextPage = 1
        run = nil
        pruneRecent()
    }

    private mutating func pruneRecent() {
        let floor = newestAt - Self.overlap
        recent = recent.filter { $0.value.time >= floor }
    }

    var total: TokenTally {
        var sum = TokenTally()
        for models in byDay.values { for tally in models.values { sum.add(tally) } }
        return sum
    }
}

/// Decides after each page whether to ask for another, so a dashboard that ignores the page
/// number (the same page again and again) or reports no end can not keep a poll going.
struct CursorPaging {
    enum Verdict: Equatable {
        case next
        /// The last page, or the cutoff: nothing more to read.
        case end
        /// A page whose requests were all on an earlier page of this poll.
        case repeated
    }

    /// Pages past what the dashboard's own count needs; a hard cap when it gives no count.
    static let margin = 2
    static let hardCap = 2000

    var cutoff: Double?
    private var seen = Set<String>()

    init(cutoff: Double?) { self.cutoff = cutoff }

    mutating func verdict(page: Int, fetched: CursorPage) -> Verdict {
        if !fetched.events.isEmpty {
            let keys = Set(fetched.events.map(\.key))
            if keys.isSubset(of: seen) { return .repeated }
            seen.formUnion(keys)
        }
        if fetched.rowCount < CursorUsageSource.pageSize { return .end }
        if let cutoff, let oldest = fetched.oldest, oldest < cutoff { return .end }
        let pages = fetched.total.map { ($0 + CursorUsageSource.pageSize - 1) / CursorUsageSource.pageSize + Self.margin } ?? Self.hardCap
        return page >= min(pages, Self.hardCap) ? .end : .next
    }
}

/// Refuses any redirect that leaves https://cursor.com (or www.cursor.com), so the sign-in's cookie never follows one.
final class CursorRedirectGuard: NSObject, URLSessionTaskDelegate {
    static func allows(_ url: URL?) -> Bool {
        guard url?.scheme == "https", let host = url?.host?.lowercased() else { return false }
        return host == "cursor.com" || host == "www.cursor.com"
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(Self.allows(request.url) ? request : nil)
    }
}

/// Fetches Cursor's usage events with the sign-in Cursor itself holds. Read-only; any failure
/// ends in a status the Usage panel shows, never in anything that blocks or breaks.
actor CursorUsageSource {
    static let pageSize = 50
    static let repeatedReason = "Cursor sent the same page again"
    private static let eventsURL = URL(string: "https://cursor.com/api/dashboard/get-filtered-usage-events")!

    /// What one poll found: events, where to go on (nil: it reached the end or the cutoff), and
    /// whether Cursor could be read.
    struct Poll: Sendable {
        var events: [CursorEvent] = []
        var nextPage: Int?
        var status: CursorUsageStatus = .ok
        /// It stopped on a page it had already read.
        var repeated = false
        /// Cursor answered a page with something unusable (an error status, a redirect, a shape
        /// this app cannot read), as opposed to being out of reach.
        var pageFailed = false
    }

    private enum Failure: Error {
        case unavailable(String)
        /// Cursor answered, but not with usable events.
        case badAnswer(String)
        case rateLimited(TimeInterval)
    }

    private let databasePath: String
    private let session: URLSession
    /// Kept in memory only, so a poll does not read the database again until the sign-in is refused.
    private var token: String?
    private var blockedUntil: Date?

    static var defaultDatabasePath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb").path
    }

    /// Whether Cursor is on this Mac at all.
    static var isInstalled: Bool { FileManager.default.fileExists(atPath: defaultDatabasePath) }

    init(databasePath: String = CursorUsageSource.defaultDatabasePath) {
        self.databasePath = databasePath
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        session = URLSession(configuration: config)
    }

    /// Reads up to `maxPages` pages from `firstPage` (newest first), stopping at a page whose
    /// oldest row is older than `cutoff`, or at the last page.
    func poll(from firstPage: Int, stopBefore cutoff: Double?, maxPages: Int) async -> Poll {
        var result = Poll()
        if let until = blockedUntil, until > Date() {
            result.nextPage = firstPage
            result.status = .unavailable("Cursor asked to slow down")
            return result
        }
        var page = firstPage
        var paging = CursorPaging(cutoff: cutoff)
        while page < firstPage + maxPages {
            do {
                let fetched = try await fetchPage(page)
                switch paging.verdict(page: page, fetched: fetched) {
                case .repeated:
                    result.nextPage = page
                    result.repeated = true
                    result.status = .unavailable(CursorUsageSource.repeatedReason)
                    return result
                case .end:
                    result.events += fetched.events
                    result.nextPage = nil
                    return result
                case .next:
                    result.events += fetched.events
                }
                page += 1
                try? await Task.sleep(nanoseconds: 250_000_000)
            } catch Failure.rateLimited(let seconds) {
                blockedUntil = Date().addingTimeInterval(seconds)
                result.nextPage = page
                result.status = .unavailable("Cursor asked to slow down")
                return result
            } catch Failure.badAnswer(let reason) {
                result.nextPage = page
                result.pageFailed = true
                result.status = .unavailable(reason)
                return result
            } catch Failure.unavailable(let reason) {
                result.nextPage = page
                result.status = .unavailable(reason)
                return result
            } catch {
                result.nextPage = page
                result.status = .unavailable("Can't reach cursor.com")
                return result
            }
        }
        result.nextPage = page
        return result
    }

    private func fetchPage(_ page: Int) async throws -> CursorPage {
        var refreshed = false
        while true {
            let signedIn = try currentToken()
            var request = URLRequest(url: Self.eventsURL)
            request.httpMethod = "POST"
            request.httpShouldHandleCookies = false
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.setValue("https://cursor.com", forHTTPHeaderField: "origin")
            request.setValue("https://cursor.com/dashboard", forHTTPHeaderField: "referer")
            request.setValue(try Self.cookie(for: signedIn), forHTTPHeaderField: "cookie")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["teamId": 0, "page": page, "pageSize": Self.pageSize])
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request, delegate: CursorRedirectGuard())
            } catch {
                throw Failure.unavailable("Can't reach cursor.com")
            }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch code {
            case 200:
                guard let parsed = CursorEvents.parse(data) else { throw Failure.badAnswer("Cursor sent an answer this app can't read") }
                return parsed
            case 401:
                // The sign-in may have been renewed since it was read: read it again once.
                if !refreshed {
                    refreshed = true
                    token = nil
                    continue
                }
                throw Failure.unavailable("Cursor sign-in expired: open Cursor")
            case 429:
                throw Failure.rateLimited(Self.retryAfter(response as? HTTPURLResponse))
            default:
                throw Failure.badAnswer(Self.failureReason(status: code))
            }
        }
    }

    /// What an unusable answer is called: a refused redirect says so instead of a bare status.
    static func failureReason(status: Int) -> String {
        if (300..<400).contains(status) { return "Cursor redirected the request away from cursor.com; not followed" }
        return "Cursor answered HTTP \(status)"
    }

    private func currentToken() throws -> String {
        if let token { return token }
        let value = try Self.readToken(databasePath)
        token = value
        return value
    }

    /// The `retry-after` header as seconds (a number or a date), a minute when absent, at most 15.
    private static func retryAfter(_ response: HTTPURLResponse?) -> TimeInterval {
        guard let text = response?.value(forHTTPHeaderField: "retry-after") else { return 60 }
        if let seconds = Double(text) { return min(max(seconds, 1), 900) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = formatter.date(from: text) { return min(max(date.timeIntervalSinceNow, 1), 900) }
        return 60
    }

    /// The cookie the dashboard sends: the account id (the token's `sub` claim), then the token.
    static func cookie(for token: String) throws -> String {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { throw Failure.unavailable("Cursor's sign-in is not readable") }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let subject = claims["sub"] as? String, !subject.isEmpty else {
            throw Failure.unavailable("Cursor's sign-in is not readable")
        }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
        let encoded = subject.addingPercentEncoding(withAllowedCharacters: allowed) ?? subject
        return "WorkosCursorSessionToken=\(encoded)%3A%3A\(token)"
    }

    /// The access token from Cursor's settings database, opened read-only. Cursor keeps the
    /// database open, so a locked read waits briefly, and a database that cannot be opened with
    /// its log is read as it lies on disk.
    private static func readToken(_ path: String) throws -> String {
        guard FileManager.default.fileExists(atPath: path) else { throw Failure.unavailable("Cursor is not installed or not signed in") }
        let base = URL(fileURLWithPath: path).absoluteString
        var value: String?
        var queried = false
        for options in ["?mode=ro", "?mode=ro&immutable=1"] where value == nil {
            var db: OpaquePointer?
            guard sqlite3_open_v2(base + options, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
                sqlite3_close(db)
                continue
            }
            sqlite3_busy_timeout(db, 1500)
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken'", -1, &statement, nil) == SQLITE_OK {
                let step = sqlite3_step(statement)
                if step == SQLITE_ROW {
                    queried = true
                    let count = Int(sqlite3_column_bytes(statement, 0))
                    value = count > 0 ? sqlite3_column_blob(statement, 0).map { String(decoding: Data(bytes: $0, count: count), as: UTF8.self) } ?? "" : ""
                } else if step == SQLITE_DONE {
                    // The database answered and has no token: Cursor is signed out.
                    queried = true
                    value = ""
                }
            }
            sqlite3_finalize(statement)
            sqlite3_close(db)
        }
        guard queried, let raw = value else { throw Failure.unavailable("Can't read Cursor's sign-in") }
        let token = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"").union(.whitespacesAndNewlines))
        if token.isEmpty { throw Failure.unavailable("Cursor is signed out") }
        // Newer Cursor builds may keep the token encrypted, readable only by Cursor itself.
        if token.hasPrefix("cursor-safe-storage:") { throw Failure.unavailable("Cursor keeps its sign-in encrypted") }
        return token
    }
}
