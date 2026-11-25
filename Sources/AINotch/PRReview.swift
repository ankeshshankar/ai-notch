import Foundation
import ReviewCore

/// Automatic reviews of the pull requests I am asked to review, on the main thread. A pull
/// request that newly shows in "to review" (or has new commits) is queued, reviewed one at a
/// time by `PRReviewRunner`, and the verdict is kept next to it. Dedupe is by pull request and
/// commit (ReviewLedger, `~/.claude/notch/pr-reviews.json`, next to pr-seen.json); each report is
/// a file in `~/.claude/notch/reviews/<repo>-<id>-<commit>/report.md`.
///
/// Nothing is posted, commented or committed on a pull request from here. Approve and
/// request-changes are only ever made by `perform`, after a click and a confirm, on fresh data.
@MainActor
final class PRReviewStore: ObservableObject {
    /// Repositories the review skill knows.
    static let supportedRepos: Set<String> = ["homes-api-app", "homes-ecosystem"]
    static let autoKey = "prs.autoReview"

    @Published private(set) var ledger = ReviewLedger()
    /// "Approving…" while a click is carried out, by pull request key.
    @Published private(set) var acting: [String: String] = [:]
    /// What the last click came to ("Approved", "Not approved: …"), by key.
    @Published private(set) var notices: [String: String] = [:]
    @Published private(set) var autoOn: Bool
    @Published private(set) var hasWriteToken = false

    /// The signed-in user's uuid, for "already approved" (set by ReviewStore).
    var meUUID: () -> String? = { nil }

    private struct Queued { var ref: PullRequestRef; var head: String; var auto: Bool }
    private var queue: [Queued] = []
    private var running: (ref: PullRequestRef, head: String)?
    private var runner: PRReviewRunner?
    private var tokenCheckedAt: Double = 0

    init() {
        autoOn = UserDefaults.standard.object(forKey: Self.autoKey) as? Bool ?? true
        var loaded = Self.load()
        loaded.settleAfterRestart(now: Date().timeIntervalSince1970)
        ledger = loaded
    }

    // MARK: Paths

    nonisolated static var baseURL: URL {
        if let dir = ProcessInfo.processInfo.environment["CLAUDE_NOTCH_REVIEWS"], !dir.isEmpty { return URL(fileURLWithPath: dir, isDirectory: true) }
        return BitbucketConfig.home.appendingPathComponent(".claude/notch/reviews", isDirectory: true)
    }

    static var ledgerURL: URL {
        if let path = ProcessInfo.processInfo.environment["CLAUDE_NOTCH_REVIEW_LEDGER"], !path.isEmpty { return URL(fileURLWithPath: path) }
        if BitbucketConfig.isStubbed { return FileManager.default.temporaryDirectory.appendingPathComponent("ai-notch-pr-reviews-stub.json") }
        return BitbucketConfig.home.appendingPathComponent(".claude/notch/pr-reviews.json")
    }

    nonisolated static func folder(_ ref: PullRequestRef, head: String) -> URL {
        baseURL.appendingPathComponent("\(ref.repo)-\(ref.id)-\(head.prefix(12))", isDirectory: true)
    }

    func reportURL(_ record: ReviewRecord) -> URL? {
        guard record.reportFile != nil, let ref = PullRequestRef(key: record.key) else { return nil }
        let url = Self.folder(ref, head: record.head).appendingPathComponent("report.md")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func load() -> ReviewLedger {
        guard let data = try? Data(contentsOf: ledgerURL), let ledger = try? JSONDecoder().decode(ReviewLedger.self, from: data) else { return ReviewLedger() }
        return ledger
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(ledger) else { return }
        try? FileManager.default.createDirectory(at: Self.ledgerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.ledgerURL, options: .atomic)
    }

    // MARK: Reading

    static func supports(_ pr: PullRequest) -> Bool { pr.role == .reviewing && supportedRepos.contains(pr.ref.repo) }

    /// The run that counts for a row: the one for its head now; else the newest older one,
    /// which shows as outdated.
    func record(for pr: PullRequest) -> (record: ReviewRecord, outdated: Bool)? {
        if let head = pr.head, let record = ledger.record(pr.ref.key, head: head) { return (record, false) }
        if let latest = ledger.latest(pr.ref.key) { return (latest, pr.head != nil) }
        return nil
    }

    func gate(_ action: ReviewAction, for pr: PullRequest) -> ReviewGate {
        guard let found = record(for: pr), !found.outdated else { return .blocked("no review of the current commit") }
        let pipeline: PipelineState = pr.build.map { $0.state == .succeeded ? .green : .notGreen } ?? .unknown
        return ReviewGate.check(action, record: found.record, currentHead: pr.head, pipeline: pipeline,
                                alreadyApproved: pr.myReview == .approved)
    }

    // MARK: Queueing

    /// Each healthy poll: queue what is new, forget what closed.
    func observe(toReview: [PullRequest], healthy: Bool) {
        guard healthy else { return }
        let now = Date().timeIntervalSince1970
        for pr in toReview where Self.supports(pr) {
            guard let head = pr.head else { continue }
            if ReviewPolicy.shouldAutoQueue(key: pr.ref.key, head: head, isDraft: pr.isDraft, iReview: true, myReviewDone: pr.myReview != .none,
                                            updatedAt: pr.updatedAt, now: now, ledger: ledger, autoOn: autoOn) {
                enqueue(pr.ref, head: head, auto: true)
            }
        }
        var next = ledger
        next.prune(openKeys: Set(toReview.map(\.ref.key)), now: now)
        if next != ledger { ledger = next; save() }
    }

    /// "Review now" / "Re-review": queued for the pull request's head, whatever came before.
    func reviewNow(_ pr: PullRequest) {
        guard Self.supports(pr), let head = pr.head else { return }
        enqueue(pr.ref, head: head, auto: false)
    }

    func setAuto(_ on: Bool) {
        autoOn = on
        UserDefaults.standard.set(on, forKey: Self.autoKey)
    }

    func cancel(_ pr: PullRequest) {
        guard let head = pr.head else { return }
        if running?.ref == pr.ref, running?.head == head {
            runner?.cancel()
        } else if queue.contains(where: { $0.ref == pr.ref && $0.head == head }) {
            queue.removeAll { $0.ref == pr.ref && $0.head == head }
            if var record = ledger.record(pr.ref.key, head: head) {
                record.phase = .cancelled
                record.finishedAt = Date().timeIntervalSince1970
                ledger.set(record)
                save()
            }
        }
    }

    private func enqueue(_ ref: PullRequestRef, head: String, auto: Bool) {
        if let existing = ledger.record(ref.key, head: head), existing.isActive { return }
        var record = ReviewRecord(key: ref.key, head: head, phase: .queued, auto: auto, queuedAt: Date().timeIntervalSince1970)
        record.posted = nil
        ledger.set(record)
        save()
        queue.append(Queued(ref: ref, head: head, auto: auto))
        pump()
    }

    // MARK: Running

    /// One at a time: the next starts when the running one ends.
    private func pump() {
        guard running == nil, !queue.isEmpty else { return }
        let job = queue.removeFirst()
        guard var record = ledger.record(job.ref.key, head: job.head), record.phase == .queued else { pump(); return }
        guard let repo = Self.repoPath(job.ref) else {
            fail(&record, "no local clone of \(job.ref.repo) in builds.json")
            pump()
            return
        }
        guard let token = KeychainItem.read(service: BitbucketConfig.tokenService)?.secret else {
            fail(&record, "no Bitbucket read token")
            pump()
            return
        }
        record.phase = .reviewing
        record.startedAt = Date().timeIntervalSince1970
        ledger.set(record)
        save()
        running = (job.ref, job.head)
        let runner = PRReviewRunner()
        self.runner = runner
        let folder = Self.folder(job.ref, head: job.head)
        runner.start(.init(ref: job.ref, head: job.head, repoPath: repo, dir: folder, token: token)) { [weak self] outcome in
            Task { @MainActor in self?.finish(job.ref, head: job.head, outcome: outcome) }
        }
    }

    private func fail(_ record: inout ReviewRecord, _ message: String) {
        record.phase = .failed
        record.error = message
        record.finishedAt = Date().timeIntervalSince1970
        ledger.set(record)
        save()
    }

    private func finish(_ ref: PullRequestRef, head: String, outcome: PRReviewRunner.Outcome) {
        running = nil
        runner = nil
        defer { pump() }
        guard let existing = ledger.record(ref.key, head: head) else { return }
        let record = Self.settle(existing, ref: ref, outcome: outcome)
        ledger.set(record)
        save()
    }

    /// What a finished run means for its record: the report on disk, the verdict, or why it failed.
    nonisolated static func settle(_ existing: ReviewRecord, ref: PullRequestRef, outcome: PRReviewRunner.Outcome) -> ReviewRecord {
        var record = existing
        record.finishedAt = Date().timeIntervalSince1970
        switch outcome {
        case .cancelled:
            record.phase = .cancelled
        case .timedOut:
            record.phase = .failed
            record.error = "stopped after \(Int((PRReviewRunner.timeoutOverride ?? PRReviewRunner.timeout) / 60)) minutes"
        case .failed(let message):
            record.phase = .failed
            record.error = message
        case .finished(let output):
            record.costUSD = output.costUSD
            let folder = Self.folder(ref, head: existing.head)
            if !output.text.isEmpty {
                try? output.text.write(to: folder.appendingPathComponent("report.md"), atomically: true, encoding: .utf8)
                record.reportFile = "report.md"
            }
            if output.isError {
                record.phase = .failed
                record.error = String(output.text.prefix(160))
            } else if !output.denied.isEmpty {
                record.phase = .failed
                record.error = "needed a tool that is not allowed: " + output.denied.joined(separator: ", ")
            } else if let parsed = ReviewParse.parse(output.text) {
                record.phase = .done
                record.verdict = parsed.verdict
                record.findings = parsed.findings
            } else {
                record.phase = .failed
                record.error = "the report has no VERDICT line"
            }
        }
        return record
    }

    /// The clone from builds.json, `~` expanded.
    nonisolated static func repoPath(_ ref: PullRequestRef) -> String? {
        let repos = BitbucketConfig.loadRepos(scan: false)
        guard let path = repos.first(where: { $0.key == ref.repoKey })?.path else { return nil }
        let expanded = (path as NSString).expandingTildeInPath
        return FileManager.default.fileExists(atPath: expanded) ? expanded : nil
    }

    // MARK: Approve and request changes

    /// The click's second step: read the pull request again, check the gate on that, and only
    /// then send. Nothing here runs without the user's confirm in the view.
    func perform(_ action: ReviewAction, on pr: PullRequest) {
        let id = pr.ref.key
        guard acting[id] == nil else { return }
        let initial = gate(action, for: pr)
        guard initial.isAllowed else {
            notices[id] = "Not sent: " + Self.reason(initial)
            return
        }
        guard let head = pr.head else { return }
        acting[id] = action == .approve ? "Approving…" : "Requesting changes…"
        notices[id] = nil
        let ref = pr.ref
        let me = meUUID()
        Task { @MainActor in
            defer { acting[id] = nil }
            guard await PRReviewAPI.hasWriteTokenAsync() else {
                notices[id] = "Needs the write token: Setup → Pull requests"
                return
            }
            guard let fresh = await PRReviewAPI.fresh(ref, me: me) else {
                notices[id] = "Not sent: could not read the pull request"
                return
            }
            let again = ReviewGate.check(action, record: ledger.record(id, head: head), currentHead: fresh.head, pipeline: fresh.pipeline,
                                         isOpen: fresh.isOpen, alreadyApproved: fresh.alreadyApproved)
            guard again.isAllowed else {
                notices[id] = "Not sent: " + Self.reason(again)
                return
            }
            switch await PRReviewAPI.send(action, to: ref) {
            case .done:
                var record = ledger.record(id, head: head)
                record?.posted = action == .approve ? "approved" : "changes requested"
                if let record { ledger.set(record); save() }
                notices[id] = action == .approve ? "Approved" : "Changes requested"
            case .failed(let why):
                notices[id] = "Not sent: " + why
            }
        }
    }

    private static func reason(_ gate: ReviewGate) -> String {
        if case .blocked(let why) = gate { return why }
        return ""
    }

    /// Whether the write token is stored, read at most every 30 s (the cache is `hasWriteToken`).
    func refreshWriteToken() {
        let now = Date().timeIntervalSince1970
        guard now - tokenCheckedAt > 30 else { return }
        tokenCheckedAt = now
        Task {
            let has = await PRReviewAPI.hasWriteTokenAsync()
            await MainActor.run { if has != self.hasWriteToken { self.hasWriteToken = has } }
        }
    }

    func clearNotice(_ id: String) { notices[id] = nil }
}

extension PullRequestRef {
    /// "ws/repo#12".
    init?(key: String) {
        guard let hash = key.lastIndex(of: "#"), let id = Int(key[key.index(after: hash)...]) else { return nil }
        self.init(fullName: String(key[..<hash]), id: id)
    }
}

extension PRReviewAPI {
    static func hasWriteTokenAsync() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { continuation.resume(returning: hasWriteToken()) }
        }
    }
}
