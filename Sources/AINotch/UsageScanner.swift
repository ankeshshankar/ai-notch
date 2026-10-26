import Foundation
import NotchCore
import SQLite3

/// Tokens and their price at Anthropic's API rates, added up over replies.
struct TokenTally: Codable, Equatable, Sendable {
    var input = 0
    var output = 0
    var cacheWrite = 0
    var cacheRead = 0
    var cost = 0.0

    var total: Int { input + output + cacheWrite + cacheRead }
    var isEmpty: Bool { total == 0 }

    mutating func add(_ other: TokenTally, sign: Int = 1) {
        input += sign * other.input
        output += sign * other.output
        cacheWrite += sign * other.cacheWrite
        cacheRead += sign * other.cacheRead
        cost += Double(sign) * other.cost
    }
}

/// Lines of code changed: what Claude Code's edits added and removed, and in how many files.
struct LineTally: Codable, Equatable, Sendable {
    var added = 0
    var removed = 0
    var files = 0

    var isEmpty: Bool { added == 0 && removed == 0 }

    mutating func add(_ other: LineTally) {
        added += other.added
        removed += other.removed
        files += other.files
    }
}

/// Where a changed file belongs: its git repository's root, found by walking up, else nil.
final class RepoResolver: @unchecked Sendable {
    private var roots: [String: String?] = [:]

    func root(of file: String) -> String? {
        var dir = (file as NSString).deletingLastPathComponent
        var visited: [String] = []
        while dir.count > 1 {
            if let known = roots[dir] {
                for path in visited { roots[path] = known }
                return known
            }
            visited.append(dir)
            if FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent(".git")) {
                for path in visited { roots[path] = dir }
                return dir
            }
            dir = (dir as NSString).deletingLastPathComponent
        }
        for path in visited { roots[path] = .some(nil) }
        return nil
    }
}

/// Per-million-token rates (input, output, cache read) from the Claude API model table (2026-09-25).
/// Cache writes cost 1.25× input for the 5-minute cache and 2× for the 1-hour cache; fast mode doubles.
enum Pricing {
    static func rates(_ model: String, fast: Bool) -> (input: Double, output: Double, cacheRead: Double)? {
        let id = model.lowercased()
        let base: (Double, Double, Double)
        if id.contains("fable") || id.contains("mythos") { base = (10, 50, 0.25) }
        else if id.contains("opus-5-5") { base = (4, 20, 0.20) }
        else if id.contains("opus-5") || id.contains("opus-4-8") || id.contains("opus-4-7") || id.contains("opus-4-6") || id.contains("opus-4-5") { base = (5, 25, 0.50) }
        else if id.contains("opus") { base = (15, 75, 1.50) }
        else if id.contains("sonnet-5") { base = (2, 10, 0.20) }
        else if id.contains("sonnet") { base = (3, 15, 0.30) }
        else if id.contains("haiku-4") { base = (1, 5, 0.10) }
        else if id.contains("haiku") { base = (0.8, 4, 0.08) }
        else { return nil }
        let scale = fast ? 2.0 : 1.0
        return (base.0 * scale, base.1 * scale, base.2 * scale)
    }

    static func tally(model: String, usage: [String: Any]) -> TokenTally {
        func int(_ value: Any?) -> Int { (value as? Int) ?? (value as? NSNumber)?.intValue ?? 0 }
        var tally = TokenTally()
        tally.input = int(usage["input_tokens"])
        tally.output = int(usage["output_tokens"])
        tally.cacheRead = int(usage["cache_read_input_tokens"])
        tally.cacheWrite = int(usage["cache_creation_input_tokens"])
        let creation = usage["cache_creation"] as? [String: Any]
        let write1h = int(creation?["ephemeral_1h_input_tokens"])
        let write5m = creation == nil ? tally.cacheWrite : int(creation?["ephemeral_5m_input_tokens"])
        guard let rate = rates(model, fast: (usage["speed"] as? String) == "fast") else { return tally }
        let perToken = 1.0 / 1_000_000
        tally.cost = (Double(tally.input) * rate.input
            + Double(tally.output) * rate.output
            + Double(tally.cacheRead) * rate.cacheRead
            + Double(write5m) * rate.input * 1.25
            + Double(write1h) * rate.input * 2) * perToken
        return tally
    }
}

/// What one transcript has added up to, and where reading it stopped.
private struct FileUsage: Codable {
    var offset: UInt64 = 0
    var sessionId: String
    var isAgent: Bool
    var firstAt: Double?
    /// How Claude Code was started: `claude-vscode` (the VS Code / Cursor extension) or `cli`.
    var entrypoint: String?
    var byDay: [String: TokenTally] = [:]
    /// The same, split by model: day → model → tally.
    var byDayModel: [String: [String: TokenTally]] = [:]
    /// Lines its edits changed: day → repository root ("" outside any repository) → lines.
    var byDayLines: [String: [String: LineTally]] = [:]
    /// The last replies seen, by message id: a reply is written once per content block, so a
    /// repeat replaces the earlier count instead of adding to it.
    var recent: [String: Recent] = [:]
    var recentOrder: [String] = []
    /// `codex` for a Codex session log; nil for a Claude Code transcript.
    var kind: String?
    /// Codex: the model the latest turn ran on, and the session's running token total
    /// (input, cached input, cache writes, output) as of the last event read.
    var codexModel: String?
    var codexTotal: [Int]?
    /// Codex: the service tier the thread runs on (`priority` costs more), whether the log has
    /// per-response usage records (then they alone count), and the responses already counted.
    var codexTier: String?
    var codexUsesRecords: Bool?
    var seenIds: [String]?
    /// Codex: the log's own thread and start; a forked thread's log first replays its parent's
    /// events, which are neither this thread's nor this log's to count.
    var codexThread: String?
    var codexStart: Double?

    struct Recent: Codable { var day: String; var model: String; var tally: TokenTally }
}

private struct Ledger: Codable {
    /// Bumped when what a file records changes; an older ledger is rebuilt from the transcripts.
    static let currentVersion = 8
    var version = Ledger.currentVersion
    var files: [String: FileUsage] = [:]
    /// Daily totals of transcripts that are gone (Claude Code deletes them after 30 days by
    /// default), so the history keeps growing past what is on disk.
    var archive: [String: TokenTally] = [:]
    var archiveLines: [String: [String: LineTally]] = [:]
    /// OpenCode's usage, read whole from its database each scan: day → model → tally. A day the
    /// database no longer holds stays as it was.
    var openCode: [String: [String: TokenTally]] = [:]
    /// Cursor's usage events folded into day → model totals. Not in any transcript, so a rebuild
    /// keeps it (the dashboard could be read again, but only a page at a time).
    var cursor: CursorLedger?
    /// Codex's plan limits from its newest `token_count` event (not a total: no version bump).
    var codexLimits: ToolLimits?
}

/// A session's recent spend and its prompt cache, kept in memory only.
struct LiveSpend: Equatable, Sendable {
    /// Reply id → (time, cost), for the last `LiveSpend.window` seconds.
    var replies: [String: SpendPoint] = [:]
    /// The main thread's last reply, and the cache lifetime its last cache write asked for.
    var lastReplyAt: Double?
    var cacheTTL: Double?

    struct SpendPoint: Equatable, Sendable { var time: Double; var cost: Double }
    static let window: Double = 15 * 60

    /// Dollars per minute over the last ten minutes, or since `since` (the turn's start) when that
    /// is later; nil with nothing spent.
    func perMinute(now: Double, since: Double?) -> Double? {
        let start = max(now - 600, since ?? 0)
        let spent = replies.values.filter { $0.time >= start }.reduce(0) { $0 + $1.cost }
        guard spent > 0 else { return nil }
        return spent / max(1, (now - start) / 60)
    }

    /// When the prompt cache goes cold: its lifetime after the last reply (each use renews it).
    var coldAt: Double? {
        guard let lastReplyAt, let cacheTTL else { return nil }
        return lastReplyAt + cacheTTL
    }
}

/// One day's tokens for one place Claude Code ran and one model.
struct UsageRow: Equatable, Sendable {
    var day: String
    var source: String
    var model: String
    var tally: TokenTally
}

/// The part of any ledger version a rebuild keeps.
private struct ArchiveOnly: Decodable {
    var archive: [String: TokenTally]?
    var archiveLines: [String: [String: LineTally]]?
    var cursor: CursorLedger?
}

/// What the app shows: per session (its own transcript and its subagents'), and per day.
struct UsageSnapshot: Equatable, Sendable {
    var rows: [UsageRow] = []
    var sessions: [String: TokenTally] = [:]
    var agentShare: [String: TokenTally] = [:]
    var firstAt: [String: Double] = [:]
    var byDay: [String: TokenTally] = [:]
    var earliestDay: String?
    var isScanning = true
    /// Lines Claude Code changed: day → repository root ("" outside any repository) → lines.
    var lines: [String: [String: LineTally]] = [:]
    /// Each session's last minutes: its replies' cost (subagents included) and its prompt cache.
    var live: [String: LiveSpend] = [:]
    var codexLimits: ToolLimits?
    /// Whether Cursor's usage could be read (shown as a line in the Usage panel).
    var cursor: CursorUsageStatus = .off

    func total(sinceDay day: String) -> TokenTally {
        var sum = TokenTally()
        for (key, tally) in byDay where key >= day { sum.add(tally) }
        return sum
    }

    var allTime: TokenTally {
        var sum = TokenTally()
        for tally in byDay.values { sum.add(tally) }
        return sum
    }

    /// Totals since `day` (nil: all time), by where Claude Code ran and by model.
    func breakdown(sinceDay day: String?) -> (bySource: [(String, TokenTally)], byModel: [(String, TokenTally)]) {
        var sources: [String: TokenTally] = [:]
        var models: [String: TokenTally] = [:]
        for row in rows where day.map({ row.day >= $0 }) ?? true {
            sources[row.source, default: TokenTally()].add(row.tally)
            models[row.model, default: TokenTally()].add(row.tally)
        }
        let sorted: ([String: TokenTally]) -> [(String, TokenTally)] = { $0.sorted { $0.value.cost > $1.value.cost }.map { ($0.key, $0.value) } }
        return (sorted(sources), sorted(models))
    }
}

/// Reads Claude Code's transcripts in the background, only the lines added since the last
/// read, and keeps the running totals in `~/.claude/notch/usage-ledger.json`.
final class UsageScanner: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ai-notch.usage", qos: .utility)
    private let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    private let ledgerURL: URL
    private var ledger = Ledger()
    private var isRunning = false
    /// Whether this scan changed the ledger: only then is it written and a snapshot sent.
    private var isDirty = false
    private var hasSentSnapshot = false
    /// Recent spend and caches per session, in memory: seeded from the ends of recently written
    /// transcripts at launch, then from each scan's new lines.
    private var live: [String: LiveSpend] = [:]
    /// OpenCode's database and its write-ahead log as last read (size and time of each).
    private var openCodeStamp: [Double]?
    /// Cursor's dashboard, polled at most once a minute; nothing else waits on it.
    private let cursorSource = CursorUsageSource()
    private var cursorStatus: CursorUsageStatus = .off
    private var isPollingCursor = false
    /// After a poll that got nowhere, no new request until then (further apart each time).
    private var cursorNotBefore = Date.distantPast
    /// A file untouched this long has written its last reply: its dedupe lists can go.
    /// (Repeats of one reply were at most 538 s apart in 1,169 transcripts.)
    private let settledAfter: Double = 3600
    private let repos = RepoResolver()
    private let prices = PriceBook()
    /// Codex's configured `service_tier` (`~/.codex/config.toml`): the tier of a thread that does
    /// not record its own, as logs from before Codex recorded it.
    private var codexDefaultTier: String?
    private let home = FileManager.default.homeDirectoryForCurrentUser
    private let onUpdate: @Sendable (UsageSnapshot) -> Void

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func day(of time: Double) -> String { dayFormatter.string(from: Date(timeIntervalSince1970: time)) }
    static func date(of day: String) -> Date? { dayFormatter.date(from: day) }

    init(ledger: URL? = nil, onUpdate: @escaping @Sendable (UsageSnapshot) -> Void) {
        ledgerURL = ledger ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/notch/usage-ledger.json")
        self.onUpdate = onUpdate
    }

    /// `AINotch --scan-usage <ledger>`: one scan into that ledger file, then a summary on
    /// stdout. A dev check: run it on a copy holding only the archive to time a full rebuild.
    static func scanOnce(ledger: URL) {
        let scanner = UsageScanner(ledger: ledger) { _ in }
        let started = Date()
        var again = 0.0
        scanner.queue.sync {
            scanner.load()
            scanner.scan()
            // A second pass with nothing new: the cost of the scan every 15 seconds.
            let second = Date()
            scanner.scan()
            again = -second.timeIntervalSinceNow
        }
        var byKind: [String: TokenTally] = [:]
        for usage in scanner.ledger.files.values {
            for tally in usage.byDay.values { byKind[usage.kind ?? "claude", default: TokenTally()].add(tally) }
        }
        for models in scanner.ledger.openCode.values { for tally in models.values { byKind["opencode", default: TokenTally()].add(tally) } }
        if let cursor = scanner.ledger.cursor { byKind["cursor", default: TokenTally()].add(cursor.total) }
        for (kind, tally) in byKind.sorted(by: { $0.key < $1.key }) {
            print("\(kind)\t\(tally.total)\t\(String(format: "%.4f", tally.cost))")
        }
        if let codex = scanner.ledger.codexLimits {
            print("codex limits\t\(codex.fiveHour.map { "5h \($0.usedPercent)%" } ?? "-")\t\(codex.weekly.map { "week \($0.usedPercent)%" } ?? "-")\tplan \(codex.plan ?? "-")\tas of \(Int(Date().timeIntervalSince1970 - codex.at))s ago")
        }
        let now = Date().timeIntervalSince1970
        for (session, entry) in scanner.live.sorted(by: { ($0.value.lastReplyAt ?? 0) > ($1.value.lastReplyAt ?? 0) }) {
            let rate = entry.perMinute(now: now, since: nil).map { String(format: "$%.3f/min", $0) } ?? "-"
            let cold = entry.coldAt.map { "cache cold in \(Int(($0 - now) / 60))m (ttl \(Int(entry.cacheTTL ?? 0))s)" } ?? "cache -"
            print("live\t\(session.prefix(8))\t\(entry.replies.count) replies\t\(rate)\t\(cold)")
        }
        print("files\t\(scanner.ledger.files.count)\tseconds\t\(String(format: "%.1f", -started.timeIntervalSinceNow - again))\trescan\t\(String(format: "%.3f", again))")
    }

    func start() {
        queue.async { [self] in
            load()
            scan()
            pollCursor()
        }
        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.queue.async { self?.scan() }
        }
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.queue.async { self?.pollCursor() }
        }
    }

    private func load() {
        defer {
            if ledger.codexLimits == nil { ledger.codexLimits = backfillCodexLimits() }
            seedLive()
        }
        guard let data = try? Data(contentsOf: ledgerURL) else { return }
        if let saved = try? JSONDecoder().decode(Ledger.self, from: data), saved.version == Ledger.currentVersion {
            ledger = saved
            onUpdate(snapshot(scanning: true))
        } else if let saved = try? JSONDecoder().decode(ArchiveOnly.self, from: data) {
            // An older format is rebuilt from the transcripts, but the totals of transcripts
            // already deleted exist nowhere else: they carry over.
            ledger.archive = saved.archive ?? [:]
            ledger.archiveLines = saved.archiveLines ?? [:]
            ledger.cursor = saved.cursor
        }
    }

    private func scan() {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        if let config = try? String(contentsOf: home.appendingPathComponent(".codex/config.toml"), encoding: .utf8),
           let line = config.split(separator: "\n").first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("service_tier") }),
           let value = line.split(separator: "=").last?.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) {
            codexDefaultTier = value
        }
        var seen = Set<String>()
        // Parsing leaves autoreleased objects behind; one pool per file keeps a rebuild's peak
        // to the largest file instead of the sum of them all.
        for (path, sessionId, isAgent) in transcripts() {
            seen.insert(path)
            autoreleasepool { read(path, sessionId: sessionId, isAgent: isAgent, kind: nil) }
        }
        for path in codexLogs() {
            seen.insert(path)
            autoreleasepool { read(path, sessionId: (path as NSString).lastPathComponent, isAgent: false, kind: "codex") }
        }
        for path in qwenLogs() {
            seen.insert(path)
            autoreleasepool { read(path, sessionId: (path as NSString).lastPathComponent, isAgent: false, kind: "qwen") }
        }
        readOpenCode()
        // A transcript that is gone leaves its daily totals behind in the archive.
        for (path, usage) in ledger.files where !seen.contains(path) {
            for (day, tally) in usage.byDay { ledger.archive[day, default: TokenTally()].add(tally) }
            for (day, repos) in usage.byDayLines {
                for (repo, lines) in repos { ledger.archiveLines[day, default: [:]][repo, default: LineTally()].add(lines) }
            }
            ledger.files[path] = nil
            isDirty = true
        }
        publish()
    }

    /// Writes the ledger and sends a snapshot when something changed.
    private func publish() {
        if isDirty, let data = try? JSONEncoder().encode(ledger) {
            try? data.write(to: ledgerURL, options: .atomic)
        }
        if isDirty || !hasSentSnapshot { onUpdate(snapshot(scanning: false)) }
        hasSentSnapshot = true
        isDirty = false
    }

    /// Reads Cursor's newest usage events (all of its history the first time, in chunks), then
    /// folds them into the ledger. The request runs off this queue; only the merge comes back.
    private func pollCursor() {
        guard !isPollingCursor, Date() >= cursorNotBefore else { return }
        guard CursorUsageSource.isInstalled else {
            setCursorStatus(.off)
            return
        }
        isPollingCursor = true
        let state = ledger.cursor ?? CursorLedger()
        let first = state.nextRequest()
        let cutoff = first.cutoff
        let pages = state.complete ? 40 : 20
        Task.detached(priority: .utility) { [self, cursorSource] in
            let poll = await cursorSource.poll(from: first.page, stopBefore: cutoff, maxPages: pages)
            queue.async { self.mergeCursor(poll, cutoff: cutoff) }
        }
    }

    private func mergeCursor(_ poll: CursorUsageSource.Poll, cutoff: Double?) {
        isPollingCursor = false
        var state = ledger.cursor ?? CursorLedger()
        let outcome = state.take(poll.events, nextPage: poll.nextPage, ok: poll.status == .ok, cutoff: cutoff,
                                 repeated: poll.repeated, pageFailed: poll.pageFailed)
        if outcome.changed || ledger.cursor == nil {
            ledger.cursor = state
            isDirty = true
        }
        if outcome.stalled, !outcome.gaveUp {
            // Two, four, eight minutes between tries.
            cursorNotBefore = Date().addingTimeInterval(60 * Double(1 << min(state.failures, 4)) - 5)
        } else {
            cursorNotBefore = .distantPast
        }
        var status = poll.status
        if outcome.gaveUp {
            status = .ok
        } else if poll.repeated || (outcome.stalled && status == .ok) {
            status = .unavailable(CursorUsageSource.repeatedReason + (state.complete ? "" : "; retrying"))
        }
        let statusChanged = effectiveCursorStatus(status) != effectiveCursorStatus(cursorStatus)
        cursorStatus = status
        if isDirty { publish() } else if statusChanged { onUpdate(snapshot(scanning: false)) }
        // More pages to read and Cursor is answering: go on now, not in a minute.
        if outcome.goOn { pollCursor() }
    }

    /// Read fine, but with part of the history left out: the panel keeps saying so.
    private func effectiveCursorStatus(_ status: CursorUsageStatus) -> CursorUsageStatus {
        status == .ok && ledger.cursor?.partial == true ? .partial : status
    }

    private func setCursorStatus(_ status: CursorUsageStatus) {
        guard cursorStatus != status else { return }
        cursorStatus = status
        onUpdate(snapshot(scanning: false))
    }

    /// Every main transcript (`<project>/<session>.jsonl`) and subagent transcript
    /// (`<project>/<session>/subagents/agent-*.jsonl`), each with its session.
    private func transcripts() -> [(String, String, Bool)] {
        var found: [(String, String, Bool)] = []
        let fm = FileManager.default
        for project in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            for entry in (try? fm.contentsOfDirectory(at: project, includingPropertiesForKeys: nil)) ?? [] {
                if entry.pathExtension == "jsonl" {
                    found.append((entry.path, entry.deletingPathExtension().lastPathComponent, false))
                } else {
                    let agents = entry.appendingPathComponent("subagents")
                    for file in (try? fm.contentsOfDirectory(at: agents, includingPropertiesForKeys: nil)) ?? [] where file.pathExtension == "jsonl" {
                        found.append((file.path, entry.lastPathComponent, true))
                    }
                }
            }
        }
        return found
    }

    /// Codex's session logs: `~/.codex/sessions/<year>/<month>/<day>/*.jsonl`.
    private func codexLogs() -> [String] {
        let root = home.appendingPathComponent(".codex/sessions")
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        return walker.compactMap { ($0 as? URL).flatMap { $0.pathExtension == "jsonl" ? $0.path : nil } }
    }

    /// Qwen Code's chats: `~/.qwen/projects/<project>/chats/*.jsonl`.
    private func qwenLogs() -> [String] {
        let root = home.appendingPathComponent(".qwen/projects")
        var found: [String] = []
        for project in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            let chats = project.appendingPathComponent("chats")
            for file in (try? FileManager.default.contentsOfDirectory(at: chats, includingPropertiesForKeys: nil)) ?? [] where file.pathExtension == "jsonl" {
                found.append(file.path)
            }
        }
        return found
    }

    private func fresh(_ sessionId: String, _ isAgent: Bool, _ kind: String?) -> FileUsage {
        var usage = FileUsage(sessionId: sessionId, isAgent: isAgent)
        usage.kind = kind
        if let kind { usage.entrypoint = kind }
        return usage
    }

    /// Whether `id` was counted already in this log; remembers the last 64.
    private func isRepeat(_ id: String, in usage: inout FileUsage) -> Bool {
        var seen = usage.seenIds ?? []
        if seen.contains(id) { return true }
        seen.append(id)
        if seen.count > 64 { seen.removeFirst(seen.count - 64) }
        usage.seenIds = seen
        return false
    }

    private func count(_ tally: TokenTally, model: String, at time: Double, into usage: inout FileUsage) {
        if usage.firstAt == nil { usage.firstAt = time }
        let day = Self.day(of: time)
        usage.byDay[day, default: TokenTally()].add(tally)
        usage.byDayModel[day, default: [:]][model, default: TokenTally()].add(tally)
    }

    /// A tally priced from the list: on Codex's tier, at the long-request rate past 272K input.
    private func priced(_ tally: TokenTally, model: String, tier: String?, inputTotal: Int) -> TokenTally {
        var tally = tally
        guard let rate = prices.rate(model) else { return tally }
        let isLong = inputTotal > 272_000
        tally.cost = Double(tally.input) * rate.price("input", tier: tier, isLong: isLong)
            + Double(tally.cacheRead) * rate.price("cacheRead", tier: tier, isLong: isLong)
            + Double(tally.cacheWrite) * rate.price("cacheWrite", tier: tier, isLong: isLong)
            + Double(tally.output) * rate.price("output", tier: tier, isLong: isLong)
        return tally
    }

    /// A Qwen Code reply's `usageMetadata`: its prompt counts the cached part too, and the reply
    /// is the rest of the total.
    private func takeQwen(_ line: Data.SubSequence, into usage: inout FileUsage) {
        guard line.range(of: Data("\"usageMetadata\"".utf8)) != nil,
              let entry = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
              let meta = entry["usageMetadata"] as? [String: Any] ?? (entry["message"] as? [String: Any])?["usageMetadata"] as? [String: Any],
              let stamp = entry["timestamp"] as? String, let time = Self.isoFormatter.date(from: stamp)?.timeIntervalSince1970 else { return }
        if let id = entry["uuid"] as? String, isRepeat(id, in: &usage) { return }
        let prompt = meta["promptTokenCount"] as? Int ?? 0
        let cached = meta["cachedContentTokenCount"] as? Int ?? 0
        let total = meta["totalTokenCount"] as? Int ?? prompt + (meta["candidatesTokenCount"] as? Int ?? 0)
        var tally = TokenTally()
        tally.input = max(0, prompt - cached)
        tally.cacheRead = cached
        tally.output = max(0, total - prompt)
        guard tally.total > 0 else { return }
        let model = entry["model"] as? String ?? "qwen"
        count(priced(tally, model: model, tier: nil, inputTotal: prompt), model: model, at: time, into: &usage)
    }

    private func read(_ path: String, sessionId: String, isAgent: Bool, kind: String?) {
        var usage = ledger.files[path] ?? fresh(sessionId, isAgent, kind)
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size < usage.offset { usage = fresh(sessionId, isAgent, kind) } // rewritten
        guard size > usage.offset else {
            if ledger.files[path] != nil, Self.hasDedupeLists(usage), Self.age(handle) > settledAfter {
                usage.recent = [:]
                usage.recentOrder = []
                usage.seenIds = nil
                ledger.files[path] = usage
                isDirty = true
            }
            return
        }
        isDirty = true
        if usage.kind == "codex", usage.offset == 0 {
            // Whether the log has per-response records at all decides how it is counted, and the
            // first records can come after a replayed history's totals, so look before reading.
            if Self.contains(handle, Data("\"token_usage_record\"".utf8)) { usage.codexUsesRecords = true }
        }
        try? handle.seek(toOffset: usage.offset)

        var pending = Data()
        var isDone = false
        while !isDone {
            autoreleasepool {
                guard let chunk = try? handle.read(upToCount: Self.chunkSize), !chunk.isEmpty else {
                    isDone = true
                    return
                }
                pending.append(chunk)
                // Only whole lines: a line still being written is read next time.
                guard let lastNewline = pending.lastIndex(of: 0x0A) else { return }
                let complete = pending[pending.startIndex...lastNewline]
                for line in complete.split(separator: 0x0A) {
                    switch usage.kind {
                    case "codex": takeCodex(line, into: &usage)
                    case "qwen": takeQwen(line, into: &usage)
                    default: take(line, into: &usage)
                    }
                }
                usage.offset += UInt64(complete.count)
                pending = Data(pending[pending.index(after: lastNewline)...])
            }
        }
        ledger.files[path] = usage
    }

    private static let chunkSize = 4 << 20

    private static func hasDedupeLists(_ usage: FileUsage) -> Bool {
        !usage.recent.isEmpty || !usage.recentOrder.isEmpty || !(usage.seenIds ?? []).isEmpty
    }

    /// Seconds since the open file was last written.
    private static func age(_ handle: FileHandle) -> Double {
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else { return 0 }
        let mtime = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
        return Date().timeIntervalSince1970 - mtime
    }

    /// Whether the file holds `needle`, read a chunk at a time (a Codex log can pass 400 MB).
    private static func contains(_ handle: FileHandle, _ needle: Data) -> Bool {
        try? handle.seek(toOffset: 0)
        var carry = Data()
        while true {
            let found: Bool? = autoreleasepool {
                guard let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty else { return nil }
                var window = carry
                window.append(chunk)
                if window.range(of: needle) != nil { return true }
                // A match can straddle two chunks.
                carry = Data(window.suffix(needle.count - 1))
                return false
            }
            guard let found else { return false }
            if found { return true }
        }
    }

    private func take(_ line: Data.SubSequence, into usage: inout FileUsage) {
        // Most lines carry no usage; a byte search is far cheaper than parsing them.
        let wantsStart = usage.firstAt == nil || usage.entrypoint == nil
        let isEdit = line.range(of: Data("\"toolUseResult\"".utf8)) != nil && line.range(of: Data("\"filePath\"".utf8)) != nil
        guard wantsStart || isEdit || line.range(of: Data("\"usage\"".utf8)) != nil else { return }
        guard let entry = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { return }
        let time = (entry["timestamp"] as? String).flatMap { Self.isoFormatter.date(from: $0) }?.timeIntervalSince1970
        if usage.firstAt == nil, let time { usage.firstAt = time }
        if usage.entrypoint == nil, let entrypoint = entry["entrypoint"] as? String { usage.entrypoint = entrypoint }
        if isEdit, let time, let result = entry["toolUseResult"] as? [String: Any], let file = result["filePath"] as? String,
           let (added, removed) = Self.lineCounts(result) {
            let repo = repos.root(of: file) ?? ""
            usage.byDayLines[Self.day(of: time), default: [:]][repo, default: LineTally()]
                .add(LineTally(added: added, removed: removed, files: 1))
            return
        }
        guard entry["type"] as? String == "assistant",
              let message = entry["message"] as? [String: Any],
              let counts = message["usage"] as? [String: Any],
              let model = message["model"] as? String, !model.hasPrefix("<"),
              let time else { return }
        let id = message["id"] as? String ?? (entry["uuid"] as? String ?? UUID().uuidString)
        let tally = Pricing.tally(model: model, usage: counts)
        let day = Self.day(of: time)
        if let earlier = usage.recent[id] {
            usage.byDay[earlier.day, default: TokenTally()].add(earlier.tally, sign: -1)
            usage.byDayModel[earlier.day, default: [:]][earlier.model, default: TokenTally()].add(earlier.tally, sign: -1)
        } else {
            usage.recentOrder.append(id)
            if usage.recentOrder.count > 16 { usage.recent[usage.recentOrder.removeFirst()] = nil }
        }
        usage.recent[id] = FileUsage.Recent(day: day, model: model, tally: tally)
        usage.byDay[day, default: TokenTally()].add(tally)
        usage.byDayModel[day, default: [:]][model, default: TokenTally()].add(tally)
        noteLive(session: usage.sessionId, isAgent: usage.isAgent, id: id, time: time, cost: tally.cost, counts: counts)
    }

    /// A reply of the last minutes: its cost toward the session's burn rate, and, on the main
    /// thread, its time and cache lifetime (1 hour if it wrote to the 1-hour cache, else 5 minutes).
    private func noteLive(session: String, isAgent: Bool, id: String, time: Double, cost: Double, counts: [String: Any]) {
        let now = Date().timeIntervalSince1970
        // The cache lives up to an hour after a reply; the burn rate looks at a quarter of that.
        guard time > now - 4200 else { return }
        var entry = live[session] ?? LiveSpend()
        if time > now - LiveSpend.window { entry.replies[id] = LiveSpend.SpendPoint(time: time, cost: cost) }
        if !isAgent, time >= (entry.lastReplyAt ?? 0) {
            entry.lastReplyAt = time
            let creation = counts["cache_creation"] as? [String: Any]
            let oneHour = LimitsFile.number(creation?["ephemeral_1h_input_tokens"]) ?? 0
            let fiveMinutes = LimitsFile.number(creation?["ephemeral_5m_input_tokens"]) ?? 0
            if oneHour > 0 { entry.cacheTTL = 3600 } else if fiveMinutes > 0 { entry.cacheTTL = 300 }
            // A reply that only read the cache renews it on the lifetime it already had.
        }
        live[session] = entry
    }

    /// The live figures of transcripts written in the last 70 minutes, from their last 1 MB, so a
    /// relaunch knows the burn rate and the caches at once. Only `live` is touched, never the ledger.
    private func seedLive() {
        let now = Date().timeIntervalSince1970
        for (path, sessionId, isAgent) in transcripts() {
            guard let date = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date,
                  now - date.timeIntervalSince1970 < 4200,
                  let handle = FileHandle(forReadingAtPath: path) else { continue }
            defer { try? handle.close() }
            autoreleasepool {
                let size = (try? handle.seekToEnd()) ?? 0
                try? handle.seek(toOffset: size > 1 << 20 ? size - (1 << 20) : 0)
                let tail = (try? handle.readToEnd()) ?? Data()
                for line in tail.split(separator: 0x0A) where line.range(of: Data("\"usage\"".utf8)) != nil {
                    guard let entry = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                          entry["type"] as? String == "assistant", let message = entry["message"] as? [String: Any],
                          let counts = message["usage"] as? [String: Any], let model = message["model"] as? String, !model.hasPrefix("<"),
                          let time = (entry["timestamp"] as? String).flatMap({ Self.isoFormatter.date(from: $0) })?.timeIntervalSince1970,
                          let id = message["id"] as? String else { continue }
                    noteLive(session: sessionId, isAgent: isAgent, id: id, time: time, cost: Pricing.tally(model: model, usage: counts).cost, counts: counts)
                }
            }
        }
    }

    /// Codex's limits from the ends of its newest logs, for a ledger that read them before it kept them.
    private func backfillCodexLimits() -> ToolLimits? {
        let logs = codexLogs().compactMap { path -> (String, Double)? in
            guard let date = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date else { return nil }
            return (path, date.timeIntervalSince1970)
        }.sorted { $0.1 > $1.1 }.prefix(12)
        var best: ToolLimits?
        for (path, _) in logs {
            guard let handle = FileHandle(forReadingAtPath: path) else { continue }
            defer { try? handle.close() }
            autoreleasepool {
                let size = (try? handle.seekToEnd()) ?? 0
                try? handle.seek(toOffset: size > 512 << 10 ? size - (512 << 10) : 0)
                let tail = (try? handle.readToEnd()) ?? Data()
                for line in tail.split(separator: 0x0A) where line.range(of: Data("\"rate_limits\"".utf8)) != nil {
                    guard let entry = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                          let payload = entry["payload"] as? [String: Any],
                          let limits = Self.codexLimits(payload, entry: entry), limits.at > (best?.at ?? 0) else { continue }
                    best = limits
                }
            }
        }
        return best
    }

    /// A `token_count` event's `rate_limits`: the Codex limit's windows, by their length.
    static func codexLimits(_ payload: [String: Any], entry: [String: Any]) -> ToolLimits? {
        guard let rates = payload["rate_limits"] as? [String: Any],
              (rates["limit_id"] as? String).map({ $0 == "codex" }) ?? true,
              let stamp = entry["timestamp"] as? String, let time = isoFormatter.date(from: stamp)?.timeIntervalSince1970 else { return nil }
        var five: LimitWindow?, week: LimitWindow?
        for key in ["primary", "secondary"] {
            guard let window = rates[key] as? [String: Any], let used = LimitsFile.number(window["used_percent"]) else { continue }
            let minutes = (window["window_minutes"] as? Int) ?? 0
            let reset = LimitsFile.number(window["resets_at"]) ?? LimitsFile.number(window["resets_in_seconds"]).map { time + $0 }
            let limit = LimitWindow(usedPercent: used, resetsAt: reset, minutes: minutes)
            if minutes > 0, minutes <= 24 * 60 { five = limit } else { week = limit }
        }
        guard five != nil || week != nil else { return nil }
        return ToolLimits(fiveHour: five, weekly: week, plan: rates["plan_type"] as? String, at: time, source: "codex-log")
    }

    /// A Codex log line. Newer logs carry one `token_usage_record` per API response, and those
    /// alone count: in multi-agent threads `token_count` re-reports usage already counted. Older
    /// logs have only `token_count`, whose running total grows by one request each time. Input
    /// counts the cached part too, so that is split out; the price follows the thread's tier.
    private func takeCodex(_ line: Data.SubSequence, into usage: inout FileUsage) {
        let isTurn = line.range(of: Data("\"turn_context\"".utf8)) != nil
        let isRecord = line.range(of: Data("\"token_usage_record\"".utf8)) != nil
        let isSettings = line.range(of: Data("\"thread_settings_applied\"".utf8)) != nil
        let isMeta = usage.codexThread == nil && line.range(of: Data("\"session_meta\"".utf8)) != nil
        guard isTurn || isRecord || isSettings || isMeta || line.range(of: Data("\"token_count\"".utf8)) != nil else { return }
        guard let entry = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
              let payload = entry["payload"] as? [String: Any] else { return }
        if isMeta, entry["type"] as? String == "session_meta" {
            // Only the log's first session_meta is its own; a fork replays its parent's after it.
            usage.codexThread = payload["id"] as? String ?? payload["session_id"] as? String
            if let stamp = entry["timestamp"] as? String ?? payload["timestamp"] as? String {
                usage.codexStart = Self.isoFormatter.date(from: stamp)?.timeIntervalSince1970
            }
            return
        }
        if isTurn {
            if let model = payload["model"] as? String { usage.codexModel = model }
            return
        }
        if isSettings {
            if let tier = (payload["thread_settings"] as? [String: Any])?["service_tier"] as? String { usage.codexTier = tier }
            return
        }
        guard let stamp = entry["timestamp"] as? String, let time = Self.isoFormatter.date(from: stamp)?.timeIntervalSince1970 else { return }
        if let start = usage.codexStart, time < start - 1 { return } // replayed from the parent
        func counts(_ usage: [String: Any]?) -> [Int] {
            ["input_tokens", "cached_input_tokens", "cache_write_input_tokens", "output_tokens"].map { (usage?[$0] as? Int) ?? 0 }
        }
        var delta: [Int]
        if entry["type"] as? String == "token_usage_record" {
            usage.codexUsesRecords = true
            if let own = usage.codexThread, let thread = payload["thread_id"] as? String, thread != own { return }
            if let id = payload["response_id"] as? String, isRepeat(id, in: &usage) { return }
            delta = counts(payload["usage"] as? [String: Any])
        } else {
            if payload["type"] as? String == "token_count", let limits = Self.codexLimits(payload, entry: entry),
               limits.at > (ledger.codexLimits?.at ?? 0) {
                ledger.codexLimits = limits
            }
            guard payload["type"] as? String == "token_count", let info = payload["info"] as? [String: Any],
                  let total = info["total_token_usage"] as? [String: Any] else { return }
            let now = counts(total)
            let before = usage.codexTotal ?? [0, 0, 0, 0]
            usage.codexTotal = now
            guard usage.codexUsesRecords != true else { return }
            delta = zip(now, before).map { $0 - $1 }
            if delta.contains(where: { $0 < 0 }) { delta = counts(info["last_token_usage"] as? [String: Any]) } // a reset total
        }
        guard delta.contains(where: { $0 > 0 }) else { return }
        var tally = TokenTally()
        tally.cacheRead = delta[1]
        tally.input = max(0, delta[0] - delta[1])
        tally.cacheWrite = delta[2]
        tally.output = delta[3]
        let model = usage.codexModel ?? "codex"
        count(priced(tally, model: model, tier: usage.codexTier ?? codexDefaultTier, inputTotal: delta[0]), model: model, at: time, into: &usage)
    }

    /// OpenCode's assistant messages from its database, read-only: tokens, model, and the cost it
    /// recorded (priced from the list when it recorded none).
    private func readOpenCode() {
        let path = home.appendingPathComponent(".local/share/opencode/opencode.db").path
        guard FileManager.default.fileExists(atPath: path) else { return }
        // The database is hundreds of MB: read it again only once it or its log has changed.
        let stamp = [path, path + "-wal"].flatMap { file -> [Double] in
            let attributes = try? FileManager.default.attributesOfItem(atPath: file)
            return [(attributes?[.size] as? NSNumber)?.doubleValue ?? -1,
                    (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1]
        }
        guard stamp != openCodeStamp else { return }
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { sqlite3_close(db); return }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2000)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT data FROM message WHERE data LIKE '%\"tokens\"%'", -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        var fresh: [String: [String: TokenTally]] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let text = sqlite3_column_text(statement, 0),
                  let message = (try? JSONSerialization.jsonObject(with: Data(String(cString: text).utf8))) as? [String: Any],
                  message["role"] as? String == "assistant",
                  let tokens = message["tokens"] as? [String: Any],
                  let created = (message["time"] as? [String: Any])?["created"] as? Double else { continue }
            let cache = tokens["cache"] as? [String: Any]
            var tally = TokenTally()
            tally.input = tokens["input"] as? Int ?? 0
            tally.output = (tokens["output"] as? Int ?? 0) + (tokens["reasoning"] as? Int ?? 0)
            tally.cacheRead = cache?["read"] as? Int ?? 0
            tally.cacheWrite = cache?["write"] as? Int ?? 0
            guard tally.total > 0 else { continue }
            let model = message["modelID"] as? String ?? "opencode"
            if let cost = message["cost"] as? Double, cost > 0 {
                tally.cost = cost
            } else {
                tally = priced(tally, model: model, tier: nil, inputTotal: tally.input + tally.cacheRead + tally.cacheWrite)
            }
            fresh[Self.day(of: created / 1000), default: [:]][model, default: TokenTally()].add(tally)
        }
        for (day, models) in fresh where ledger.openCode[day] != models {
            ledger.openCode[day] = models
            isDirty = true
        }
        // Stamped only once read whole, so a busy database is tried again next scan.
        openCodeStamp = stamp
    }

    /// An Edit or Write result's lines: its diff's + and − lines, or a new file's every line.
    static func lineCounts(_ result: [String: Any]) -> (Int, Int)? {
        if let hunks = result["structuredPatch"] as? [[String: Any]], !hunks.isEmpty {
            var added = 0, removed = 0
            for hunk in hunks {
                for line in hunk["lines"] as? [String] ?? [] {
                    if line.hasPrefix("+") { added += 1 } else if line.hasPrefix("-") { removed += 1 }
                }
            }
            return (added, removed)
        }
        if result["type"] as? String == "create", let content = result["content"] as? String {
            return (content.isEmpty ? 0 : content.split(separator: "\n", omittingEmptySubsequences: false).count, 0)
        }
        return nil
    }

    private func snapshot(scanning: Bool) -> UsageSnapshot {
        var snap = UsageSnapshot(isScanning: scanning)
        snap.byDay = ledger.archive
        snap.lines = ledger.archiveLines
        var rows: [String: UsageRow] = [:]
        for (day, tally) in ledger.archive {
            rows["\(day)|archived|"] = UsageRow(day: day, source: "archived", model: "earlier transcripts", tally: tally)
        }
        for (day, models) in ledger.openCode {
            for (model, tally) in models {
                snap.byDay[day, default: TokenTally()].add(tally)
                rows["\(day)|opencode|\(model)"] = UsageRow(day: day, source: "opencode", model: model, tally: tally)
            }
        }
        for (day, models) in ledger.cursor?.byDay ?? [:] {
            for (model, tally) in models where !tally.isEmpty || tally.cost > 0 {
                snap.byDay[day, default: TokenTally()].add(tally)
                rows["\(day)|cursor|\(model)"] = UsageRow(day: day, source: "cursor", model: model, tally: tally)
            }
        }
        for usage in ledger.files.values {
            var fileTotal = TokenTally()
            for (day, tally) in usage.byDay {
                snap.byDay[day, default: TokenTally()].add(tally)
                fileTotal.add(tally)
            }
            for (day, repos) in usage.byDayLines {
                for (repo, lines) in repos { snap.lines[day, default: [:]][repo, default: LineTally()].add(lines) }
            }
            let source = usage.entrypoint ?? "unknown"
            for (day, models) in usage.byDayModel {
                for (model, tally) in models {
                    let key = "\(day)|\(source)|\(model)"
                    var row = rows[key] ?? UsageRow(day: day, source: source, model: model, tally: TokenTally())
                    row.tally.add(tally)
                    rows[key] = row
                }
            }
            snap.sessions[usage.sessionId, default: TokenTally()].add(fileTotal)
            if usage.isAgent { snap.agentShare[usage.sessionId, default: TokenTally()].add(fileTotal) }
            if !usage.isAgent, let first = usage.firstAt { snap.firstAt[usage.sessionId] = first }
        }
        let cutoff = Date().timeIntervalSince1970 - LiveSpend.window
        for (session, entry) in live {
            var kept = entry
            kept.replies = entry.replies.filter { $0.value.time > cutoff }
            live[session] = kept
        }
        snap.live = live
        snap.codexLimits = ledger.codexLimits
        snap.cursor = effectiveCursorStatus(cursorStatus)
        snap.earliestDay = snap.byDay.filter { !$0.value.isEmpty }.keys.min()
        snap.rows = Array(rows.values)
        return snap
    }
}

/// 820, 12.4K, 84.2M, 1.2B.
func compactTokens(_ n: Int) -> String {
    let value = Double(n)
    if value >= 1e9 { return String(format: "%.1fB", value / 1e9) }
    if value >= 1e6 { return String(format: "%.1fM", value / 1e6) }
    if value >= 1e3 { return String(format: "%.1fK", value / 1e3) }
    return "\(n)"
}

/// $0.42, $41.20, $1,240.
func money(_ amount: Double) -> String {
    if amount >= 1000 {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return "$" + (formatter.string(from: NSNumber(value: amount)) ?? String(format: "%.0f", amount))
    }
    return String(format: "$%.2f", amount)
}
