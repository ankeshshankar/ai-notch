import Foundation
import ReviewCore

/// Automatic reviews of the pull requests I am asked to review, on the main thread. A pull
/// request that newly shows in "to review" (or has new commits) is queued, reviewed one at a
/// time by `PRReviewRunner`, and the verdict is kept next to it. Dedupe is by pull request and
/// commit (ReviewLedger, `~/.claude/notch/pr-reviews.json`, next to pr-seen.json); each report is
/// a file in `~/Library/Application Support/AINotch/reviews/<repo>-<id>-<commit>/report.md` (outside
/// `~/.claude`, where Claude Code refuses writes; older ones stay readable in `~/.claude/notch/reviews`).
///
/// Nothing is posted, commented or committed on a pull request from here. Approve and
/// request-changes are only ever made by `perform`, after a click and a confirm, on fresh data.
@MainActor
final class PRReviewStore: ObservableObject {
    /// Repositories the review skill knows.
    static let autoKey = "prs.autoReview"

    @Published private(set) var ledger = ReviewLedger()
    /// "Approving…" while a click is carried out, by pull request key.
    @Published private(set) var acting: [String: String] = [:]
    /// What the last click came to ("Approved", "Not approved: …"), by key.
    @Published private(set) var notices: [String: String] = [:]
    @Published private(set) var autoOn: Bool
    @Published private(set) var hasWriteToken = false
    /// Unseen developer replies under my comments, by pull request key.
    @Published private(set) var unseenReplies: [String: Int] = [:]

    /// The signed-in user's uuid, for "already approved" (set by ReviewStore).
    var meUUID: () -> String? = { nil }
    /// A review (or follow-up) reached a verdict: the notch's notification and the waiting count hang off this.
    var onFinished: (PullRequestRef, ReviewRecord) -> Void = { _, _ in }

    private struct Queued { var ref: PullRequestRef; var head: String; var auto: Bool; var base: ReviewRecord? = nil; var branch: BranchTarget? = nil }
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

    /// Dev self-check only.
    func injectLedgerForCheck(_ value: ReviewLedger) { ledger = value }

    // MARK: Paths

    /// A dev run (a preview, a self-check, a live check): it never uses the real ledger or review folders. Without
    /// CLAUDE_NOTCH_REVIEWS / CLAUDE_NOTCH_REVIEW_LEDGER it gets a temporary one, so a forgotten variable cannot reach them.
    nonisolated static var isDevRun: Bool {
        CommandLine.arguments.contains { $0.hasPrefix("--review-") || $0.hasPrefix("--pr-") || $0.hasPrefix("--board-") || $0 == "--preview" || $0 == "--setup-preview" }
    }

    nonisolated static var devScratch: URL { FileManager.default.temporaryDirectory.appendingPathComponent("ai-notch-dev-reviews", isDirectory: true) }

    nonisolated static var realBaseURL: URL { BitbucketConfig.home.appendingPathComponent("Library/Application Support/AINotch/reviews", isDirectory: true) }

    nonisolated static var baseURL: URL {
        if let dir = ProcessInfo.processInfo.environment["CLAUDE_NOTCH_REVIEWS"], !dir.isEmpty { return URL(fileURLWithPath: dir, isDirectory: true) }
        if isDevRun { return devScratch.appendingPathComponent("reviews", isDirectory: true) }
        return realBaseURL
    }

    /// Inside the real review folders (current or legacy).
    nonisolated static func isRealFolder(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return [realBaseURL, legacyBaseURL].contains { path.hasPrefix($0.standardizedFileURL.resolvingSymlinksInPath().path + "/") }
    }

    /// Where reviews were kept before they moved out of `~/.claude` (read only: reports there still open).
    nonisolated static var legacyBaseURL: URL {
        BitbucketConfig.home.appendingPathComponent(".claude/notch/reviews", isDirectory: true)
    }

    static var ledgerURL: URL {
        if let path = ProcessInfo.processInfo.environment["CLAUDE_NOTCH_REVIEW_LEDGER"], !path.isEmpty { return URL(fileURLWithPath: path) }
        if BitbucketConfig.isStubbed { return FileManager.default.temporaryDirectory.appendingPathComponent("ai-notch-pr-reviews-stub.json") }
        if isDevRun { return devScratch.appendingPathComponent("ledger.json") }
        return BitbucketConfig.home.appendingPathComponent(".claude/notch/pr-reviews.json")
    }

    nonisolated static func folder(_ ref: PullRequestRef, head: String) -> URL {
        baseURL.appendingPathComponent("\(ref.repo)-\(ref.id)-\(head.prefix(12))", isDirectory: true)
    }

    func folder(for record: ReviewRecord) -> URL? {
        PullRequestRef(key: record.key).map { Self.folder($0, head: record.head) }
    }

    func reportURL(_ record: ReviewRecord) -> URL? {
        guard record.reportFile != nil, let ref = PullRequestRef(key: record.key) else { return nil }
        let name = "\(ref.repo)-\(ref.id)-\(record.head.prefix(12))"
        let bases = ProcessInfo.processInfo.environment["CLAUDE_NOTCH_REVIEWS"] == nil ? [Self.baseURL, Self.legacyBaseURL] : [Self.baseURL]
        return bases.map { $0.appendingPathComponent(name, isDirectory: true).appendingPathComponent("report.md") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
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

    /// A pull request I review in a repository with a local clone in builds.json (or the stub's).
    static func supports(_ pr: PullRequest) -> Bool { pr.role == .reviewing && (BitbucketConfig.isStubbed || repoPath(pr.ref) != nil) }

    /// My own pull request, reviewed by hand for me only ("Review my PR").
    static func supportsOwn(_ pr: PullRequest) -> Bool { pr.role == .mine && (BitbucketConfig.isStubbed || repoPath(pr.ref) != nil) }

    /// Branch reviews kept in the ledger, as rows for the window (a negative number stands in for the pull request id).
    var branchPRs: [PullRequest] { Self.branchPRs(in: ledger) }

    nonisolated static func branchPRs(in ledger: ReviewLedger) -> [PullRequest] {
        var newest: [String: ReviewRecord] = [:]
        for record in ledger.records.values where record.branch != nil {
            if let old = newest[record.key], (old.finishedAt ?? old.queuedAt) >= (record.finishedAt ?? record.queuedAt) { continue }
            newest[record.key] = record
        }
        return newest.values.sorted { ($0.finishedAt ?? $0.queuedAt) > ($1.finishedAt ?? $1.queuedAt) }.compactMap { record in
            guard let ref = PullRequestRef(key: record.key) else { return nil }
            return PullRequest(ref: ref, title: "Branch \(record.branch ?? "")", isDraft: false, author: PRPerson(uuid: nil, name: "You"),
                               source: record.branch, destination: record.target, role: .mine, participants: [], myReview: .none,
                               taskCount: 0, commentCount: 0, updatedOn: "", updatedAt: record.finishedAt ?? record.queuedAt, url: nil, head: record.head)
        }
    }

    /// The pull requests waiting for my call: review done on the current commit, nothing approved, requested or posted since.
    func waitingKeys(_ prs: [PullRequest], muted: Set<String>) -> [String] {
        ReviewWaiting.keys(prs.filter { $0.role == .reviewing }.map {
            WaitingInput(key: $0.ref.key, head: $0.head, decided: $0.myReview != .none, muted: muted.contains($0.id))
        }, ledger: ledger)
    }

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

    private func pipelineState(_ pr: PullRequest) -> PipelineState { pr.build.map { $0.state == .succeeded ? .green : .notGreen } ?? .unknown }

    /// The combined actions on offer for the cards switched on, each with its gate.
    func combinedOptions(for pr: PullRequest, pending: [SuggestedComment]) -> [(action: CombinedAction, gate: ReviewGate)] {
        guard let found = record(for: pr), !found.outdated else { return [] }
        return ReviewGate.combinedOptions(pending: pending, record: found.record, currentHead: pr.head, pipeline: pipelineState(pr), alreadyApproved: pr.myReview == .approved)
    }

    /// "Approve anyway", from the cards and the threads as last read (the click reads them again).
    func overrideGate(for pr: PullRequest, session: PRChatSession?) -> OverrideGate {
        guard let session, let found = record(for: pr), !found.outdated else { return .unavailable("no review of the current commit") }
        return ReviewGate.checkOverride(cards: session.cards, replies: session.replies, record: found.record, currentHead: pr.head,
                                        pipeline: pipelineState(pr), alreadyApproved: pr.myReview == .approved)
    }

    // MARK: Replies

    func setUnseenReplies(_ key: String, _ count: Int) {
        if (unseenReplies[key] ?? 0) != count { unseenReplies[key] = count > 0 ? count : nil }
    }

    /// Reads the replies under my comments on a pull request into its review folder and counts the unseen ones.
    func refreshReplies(_ ref: PullRequestRef, head: String) async {
        guard let raw = await PRReviewAPI.rawComments(ref) else { return }
        let folder = Self.folder(ref, head: head)
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        let file = ReplyFiles.update(raw: raw, ref: ref, folder: folder, me: meUUID(), posted: [])
        setUnseenReplies(ref.key, file.unseen(ReplyFiles.seen(ref)))
        await autoReadReplies(ref, head: head, file: file)
    }

    private var autoReading: Set<String> = []

    /// The replies nobody has read yet are read once per newest reply (Haiku, a disagreement again on Opus) and the
    /// classification saved in `replies.json`. Never in a dev run; a failed read is not repeated for the same reply.
    func autoReadReplies(_ ref: PullRequestRef, head: String, file: RepliesFile) async {
        let todo = file.unreadToTry()
        guard !todo.isEmpty, !Self.isDevRun, let repo = Self.repoPath(ref), autoReading.insert(ref.key).inserted else { return }
        defer { autoReading.remove(ref.key) }
        guard let token = KeychainItem.read(service: BitbucketConfig.tokenService)?.secret else { return }
        let folder = Self.folder(ref, head: head)
        let runner = PRReviewRunner()
        let result = await ReplyReading.read(threads: todo, head: head) { input, model in
            await withCheckedContinuation { continuation in
                runner.start(PRReviewRunner.Job(ref: ref, head: head, repoPath: repo, dir: folder, token: token, replyRead: .init(inputJSON: input, model: model))) { continuation.resume(returning: $0) }
            }
        }
        var fresh = ReplyFiles.load(folder)
        fresh.apply(result.analyses)
        fresh.markTried(todo)
        ReplyFiles.save(fresh, folder: folder)
    }

    // MARK: Queueing

    /// Each healthy poll: queue what is new, forget what closed.
    func observe(toReview: [PullRequest], healthy: Bool) {
        guard healthy else { return }
        let now = Date().timeIntervalSince1970
        for pr in toReview where Self.supports(pr) {
            guard let head = pr.head else { continue }
            if ReviewPolicy.shouldAutoQueue(key: pr.ref.key, head: head, isDraft: pr.isDraft, iReview: true, myReviewDone: pr.myReview != .none,
                                            updatedAt: pr.updatedAt, now: now, ledger: ledger, autoOn: autoOn, repos: ReviewRepos.load()) {
                enqueue(pr.ref, head: head, auto: true)
            } else if ReviewLedger.shouldResume(ledger.record(pr.ref.key, head: head), head: head, isDraft: pr.isDraft, iReview: true,
                                                myReviewDone: pr.myReview != .none, autoOn: autoOn, repos: ReviewRepos.load()) {
                // The notch quit mid-review: once more, quietly (a second interruption stays failed).
                enqueue(pr.ref, head: head, auto: true, resumed: true)
            }
        }
        var next = ledger
        next.prune(openKeys: Set(toReview.map(\.ref.key)), now: now)
        if next != ledger { ledger = next; save() }
    }

    /// "Review now" / "Re-review": queued for the pull request's head; a follow-up when an
    /// older commit has a finished review, unless `full`. My own pull request is reviewed here too (for me only).
    func reviewNow(_ pr: PullRequest, full: Bool = false) {
        guard Self.supports(pr) || Self.supportsOwn(pr), let head = pr.head else { return }
        enqueue(pr.ref, head: head, auto: false, full: full, own: pr.role == .mine)
    }

    /// "Review a branch…": a branch of a known repository against its target, for me only.
    @discardableResult
    func reviewBranch(repoKey: String, branch: String, target: String, head: String) -> PullRequestRef? {
        guard ReviewBranch.isValid(branch), ReviewBranch.isValid(target), let ref = PullRequestRef(fullName: repoKey, id: ReviewBranch.pseudoID(repoKey: repoKey, branch: branch)) else { return nil }
        enqueue(ref, head: head, auto: false, full: true, own: true, branch: BranchTarget(branch: branch, target: target, head: head))
        return ref
    }

    /// A review's cards were posted: it no longer waits for my call.
    func notePosted(key: String, head: String, count: Int) {
        guard count > 0, var record = ledger.record(key, head: head) else { return }
        record.commentsPosted = (record.commentsPosted ?? 0) + count
        ledger.set(record)
        save()
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

    private func enqueue(_ ref: PullRequestRef, head: String, auto: Bool, resumed: Bool = false, full: Bool = false, own: Bool = false, branch: BranchTarget? = nil) {
        if let existing = ledger.record(ref.key, head: head), existing.isActive { return }
        // One pass per head: never a second while one of its own is queued or running.
        if queue.contains(where: { $0.ref == ref && $0.head == head }) || (running?.ref == ref && running?.head == head) { return }
        var record = ReviewRecord(key: ref.key, head: head, phase: .queued, auto: auto, queuedAt: Date().timeIntervalSince1970)
        record.posted = nil
        if resumed { record.resumed = true }
        var base: ReviewRecord?
        if branch == nil, case .followUp(let found) = ReviewPolicy.plan(key: ref.key, head: head, ledger: ledger, full: full) {
            // The chat of a follow-up goes on in the full review's session; the pass itself starts fresh.
            base = found
            record.baseHead = found.head
            record.sessionID = found.sessionID
            record.own = found.own
        }
        if own { record.own = true }
        if let branch { record.branch = branch.branch; record.target = branch.target; record.own = true }
        ledger.set(record)
        save()
        queue.append(Queued(ref: ref, head: head, auto: auto, base: base, branch: branch))
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
        var spec = PRReviewRunner.Job(ref: job.ref, head: job.head, repoPath: repo, dir: folder, token: token, branch: job.branch)
        let done: @Sendable (PRReviewRunner.Outcome) -> Void = { [weak self] outcome in
            Task { @MainActor in self?.finish(job.ref, head: job.head, outcome: outcome) }
        }
        guard let base = job.base else { runner.start(spec, done: done); return }
        // A follow-up: what the last review said and did, and the comments on the pull request now.
        Task { @MainActor in
            let (log, commits) = await self.followUpInput(job.ref, base: base, head: job.head)
            let raw = await PRReviewAPI.rawComments(job.ref)
            var existing: [ExistingComment] = raw?.map(\.existing) ?? []
            if raw == nil { existing = await PRReviewAPI.comments(job.ref) ?? [] }
            var threads: [ReplyThread] = []
            var others: [ExistingComment] = []
            if let raw {
                let file = ReplyFiles.update(raw: raw, ref: job.ref, folder: folder, me: self.meUUID(), posted: ReplyFiles.postedIDs(log))
                self.setUnseenReplies(job.ref.key, file.unseen(ReplyFiles.seen(job.ref)))
                threads = file.threads.filter { file.needsAttention($0) }
                others = OtherThreads.open(raw, mine: Set(file.myRoots ?? []), me: self.meUUID())
            }
            if var current = self.ledger.record(job.ref.key, head: job.head) { current.commitCount = commits; self.ledger.set(current); self.save() }
            let input = FollowUp.inputJSON(previousHead: base.head, newHead: job.head, previous: base, log: log, existing: existing, replyThreads: threads,
                                          othersOpen: others, previousGate: base.mergeGate)
            spec.followUp = .init(baseHead: base.head, inputJSON: input, readReplies: !threads.isEmpty)
            runner.start(spec, done: done)
        }
    }

    /// The previous review's cards (its `chat.json`, else its `comments.json`) and the number of new commits.
    private func followUpInput(_ ref: PullRequestRef, base: ReviewRecord, head: String) async -> (ChatLog, Int?) {
        let folder = Self.cardsFolder(ref, base: base.head, head: head)
        let log = FollowUp.baseLog(chatJSON: try? Data(contentsOf: folder.appendingPathComponent("chat.json")),
                                   commentsJSON: try? Data(contentsOf: folder.appendingPathComponent("comments.json")), sessionID: base.sessionID)
        return (log, await PRReviewAPI.commitsSince(ref, reviewed: base.head, head: head))
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
        var record = Self.settle(existing, ref: ref, outcome: outcome)
        if let baseHead = existing.baseHead {
            record = Self.settleFollowUp(record, existing: existing, ref: ref, outcome: outcome, previous: ledger.record(ref.key, head: baseHead))
        }
        if case .finished = outcome {
            // The run is kept as runs/<n>/; a full run's cards are rebuilt from it without losing what I did to the old ones.
            if existing.baseHead == nil, record.phase == .done { Self.rebuildCards(ref, head: existing.head) }
            ReviewRuns.finish(Self.folder(ref, head: existing.head))
        }
        if record.phase == .done, record.notified != true, record.own != true {
            record.notified = true
            ledger.set(record)
            save()
            let finished = record
            Task { @MainActor in
                await self.refreshReplies(ref, head: finished.head)
                self.onFinished(ref, finished)
            }
            return
        }
        ledger.set(record)
        save()
    }

    /// A follow-up's result: its `followup.json` folded into the cards of the review it follows, the
    /// open findings counted from them, and the full review's session kept for the chat.
    nonisolated static func settleFollowUp(_ settled: ReviewRecord, existing: ReviewRecord, ref: PullRequestRef, outcome: PRReviewRunner.Outcome,
                                        previous: ReviewRecord? = nil) -> ReviewRecord {
        guard case .finished = outcome, let baseHead = existing.baseHead else { return settled }
        var record = settled
        record.sessionID = existing.sessionID
        let folder = Self.folder(ref, head: existing.head)
        if case .finished(let output) = outcome {
            // The read of the author's replies rides on the follow-up's report.
            let parsed = ReplyBlocks.parse(output.text)
            if !parsed.analyses.isEmpty {
                var file = ReplyFiles.load(folder)
                file.apply(parsed.analyses, model: ReviewModels.full)
                ReplyFiles.save(file, folder: folder)
            }
        }
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("followup.json")), let result = FollowUp.parse(data) else {
            // No structured answer: the report's VERDICT line still counts, nothing is marked.
            return record
        }
        let baseFolder = Self.cardsFolder(ref, base: baseHead, head: existing.head)
        var log = FollowUp.baseLog(chatJSON: try? Data(contentsOf: baseFolder.appendingPathComponent("chat.json")),
                                   commentsJSON: try? Data(contentsOf: baseFolder.appendingPathComponent("comments.json")), sessionID: existing.sessionID)
        let missing = FollowUp.missingCards(previous: previous, log: log)
        let note = log.applyFollowUp(result, from: baseHead, to: existing.head, commits: existing.commitCount, at: Date().timeIntervalSince1970)
        // The gate the follow-up leaves: its own, plus the open findings and any card it could not check. APPROVE only over READY.
        record.mergeGate = FollowUp.finalGate(reported: result.gate, previous: previous?.mergeGate, open: log.openFindings, missingCards: missing)
        let standing = FollowUp.standingVerdict(note.verdict, findings: log.openFindings, gate: record.mergeGate)
        log.restateVerdict(standing, note: note.id)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        if let encoded = try? encoder.encode(log) { try? encoded.write(to: folder.appendingPathComponent("chat.json"), options: .atomic) }
        record.findings = log.openFindings
        record.phase = .done
        record.error = nil
        // The note, the record, the window and the gate all read this one verdict.
        record.verdict = standing
        return record
    }

    /// A new full run on a folder that already has cards: `chat.json` gets the cards of the new `comments.json`
    /// (matched by finding id, else path and line); a folder with no `chat.json` is seeded when the window opens it.
    nonisolated static func rebuildCards(_ ref: PullRequestRef, head: String) {
        let folder = Self.folder(ref, head: head)
        guard let chat = try? Data(contentsOf: folder.appendingPathComponent("chat.json")), var log = try? JSONDecoder().decode(ChatLog.self, from: chat), log.seeded,
              let comments = try? Data(contentsOf: folder.appendingPathComponent("comments.json")) else { return }
        log.rebuild(from: CommentParse.file(comments), report: try? String(contentsOf: folder.appendingPathComponent("review.md"), encoding: .utf8))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        if let data = try? encoder.encode(log) { try? data.write(to: folder.appendingPathComponent("chat.json"), options: .atomic) }
    }

    /// Where a follow-up reads the cards from: the review it follows, or (a second pass on a head that already has a
    /// follow-up) that head's own `chat.json`, so what I posted, resolved or skipped since is not lost.
    nonisolated static func cardsFolder(_ ref: PullRequestRef, base: String, head: String) -> URL {
        let own = folder(ref, head: head)
        if let data = try? Data(contentsOf: own.appendingPathComponent("chat.json")), let log = try? JSONDecoder().decode(ChatLog.self, from: data),
           log.followUps.contains(where: { $0.id == "fu-\(head.prefix(12))" }) { return own }
        return folder(ref, head: base)
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
            record.sessionID = output.sessionID
            let folder = Self.folder(ref, head: existing.head)
            if !output.text.isEmpty {
                try? output.text.write(to: folder.appendingPathComponent("report.md"), atomically: true, encoding: .utf8)
                record.reportFile = "report.md"
            }
            if output.isError {
                record.phase = .failed
                record.error = String(output.text.prefix(160))
            } else if let parsed = ReviewParse.parse(output.text) {
                // A refused tool does not fail a review that reached a verdict, but it can no
                // longer approve (the gate), and the row says so.
                record.denied = output.denied.isEmpty ? nil : output.denied
                record.phase = .done
                record.verdict = parsed.verdict
                record.findings = parsed.findings
                // A full run's merge gate; none written (an older skill) means today's rules.
                if existing.baseHead == nil {
                    record.mergeGate = (try? Data(contentsOf: folder.appendingPathComponent("gate.json"))).flatMap(GateFile.parse)
                }
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

    /// "Resolve N fixed" after its confirm; the result goes to the status row, which also redraws the Approve buttons.
    func resolveAllFixed(_ items: [ResolveItem], on pr: PullRequest, session: PRChatSession) {
        let id = pr.ref.key
        guard acting[id] == nil, !session.posting, !items.isEmpty else { return }
        acting[id] = "Resolving \(items.count)…"
        notices[id] = nil
        let (ref, me) = (pr.ref, meUUID())
        Task { @MainActor in
            defer { acting[id] = nil }
            guard await PRReviewAPI.hasWriteTokenAsync() else { notices[id] = "Needs the write token: Setup → Pull requests"; return }
            guard let fresh = await PRReviewAPI.fresh(ref, me: me), fresh.isOpen else { notices[id] = "Not resolved: could not read the open pull request"; return }
            notices[id] = await session.resolveAllFixed(items, currentHead: fresh.head)
        }
    }

    /// "Approve anyway" after its confirm: the pull request, the pipeline and my threads are read again, the same
    /// override gate is checked on that, and only then the approval is sent (nothing is posted).
    func performOverride(on pr: PullRequest, session: PRChatSession) {
        let id = pr.ref.key
        guard acting[id] == nil, !session.posting, let head = pr.head else { return }
        let initial = overrideGate(for: pr, session: session)
        guard initial.isAvailable else { if case .unavailable(let why) = initial { notices[id] = "Not sent: " + why }; return }
        acting[id] = "Approving…"
        notices[id] = nil
        let ref = pr.ref
        let me = meUUID()
        Task { @MainActor in
            defer { acting[id] = nil }
            guard await PRReviewAPI.hasWriteTokenAsync() else { notices[id] = "Needs the write token: Setup → Pull requests"; return }
            guard let fresh = await PRReviewAPI.fresh(ref, me: me) else { notices[id] = "Not sent: could not read the pull request"; return }
            guard let raw = await PRReviewAPI.rawComments(ref) else { notices[id] = "Not sent: could not read the comments"; return }
            let cards = session.cards
            let replies = ReplyFiles.update(raw: raw, ref: ref, folder: session.folder, me: me, posted: Set(cards.compactMap(\.postedID)))
            let again = ReviewGate.checkOverride(cards: cards, replies: replies, record: ledger.record(id, head: head), currentHead: fresh.head,
                                                 pipeline: fresh.pipeline, isOpen: fresh.isOpen, alreadyApproved: fresh.alreadyApproved)
            guard again.isAvailable else { if case .unavailable(let why) = again { notices[id] = "Not sent: " + why }; return }
            switch await PRReviewAPI.send(.approve, to: ref) {
            case .done:
                var record = ledger.record(id, head: head)
                record?.posted = "approved"
                if let record { ledger.set(record); save() }
                notices[id] = "Approved anyway"
            case .failed(let why):
                notices[id] = "Not sent: " + why
            }
        }
    }

    /// "Post N + Request changes" / "Post N + Approve" / "Approve with comments": one confirm in the view, then
    /// the same checks on fresh data as the single actions, the comments (and their tasks), and only when every
    /// comment went out, the approval or the request for changes.
    func performCombined(_ action: CombinedAction, on pr: PullRequest, session: PRChatSession) {
        let id = pr.ref.key
        guard acting[id] == nil, !session.posting, let head = pr.head else { return }
        let pending = PostPlan.pending(session.cards)
        let initial = ReviewGate.checkCombined(action, pending: pending, record: ledger.record(id, head: head), currentHead: pr.head,
                                               pipeline: pipelineState(pr), alreadyApproved: pr.myReview == .approved)
        guard initial.isAllowed else { notices[id] = "Not sent: " + Self.reason(initial); return }
        acting[id] = "Posting…"
        notices[id] = nil
        let ref = pr.ref
        let me = meUUID()
        Task { @MainActor in
            defer { acting[id] = nil }
            guard await PRReviewAPI.hasWriteTokenAsync() else { notices[id] = "Needs the write token: Setup → Pull requests"; return }
            guard let fresh = await PRReviewAPI.fresh(ref, me: me) else { notices[id] = "Not sent: could not read the pull request"; return }
            let again = ReviewGate.checkCombined(action, pending: pending, record: ledger.record(id, head: head), currentHead: fresh.head,
                                                 pipeline: fresh.pipeline, isOpen: fresh.isOpen, alreadyApproved: fresh.alreadyApproved)
            guard again.isAllowed else { notices[id] = "Not sent: " + Self.reason(again); return }
            if action != .approveWithComments || !pending.isEmpty {
                guard await session.postPending() else { notices[id] = "Not sent: " + (session.notice ?? "the comments were not posted"); return }
            }
            acting[id] = action.final == .approve ? "Approving…" : "Requesting changes…"
            switch await PRReviewAPI.send(action.final, to: ref) {
            case .done:
                var record = ledger.record(id, head: head)
                record?.posted = action.final == .approve ? "approved" : "changes requested"
                if let record { ledger.set(record); save() }
                let n = pending.count
                notices[id] = (action.final == .approve ? "Approved" : "Changes requested") + " · \(n) comment\(n == 1 ? "" : "s") posted"
            case .failed(let why):
                notices[id] = "Comments posted, not \(action.final == .approve ? "approved" : "requested"): " + why
            }
        }
    }

    private static func reason(_ gate: ReviewGate) -> String {
        if case .blocked(let why) = gate { return why }
        return ""
    }

    /// Whether the write token is stored, read at most every 30 s (the cache is `hasWriteToken`).
    func refreshWriteToken(force: Bool = false) {
        let now = Date().timeIntervalSince1970
        guard force || now - tokenCheckedAt > 30 else { return }
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
