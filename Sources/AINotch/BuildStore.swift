import AppKit
import Foundation

/// A link from one run to the other source's: by the ` bb:ws/repo#n` the EAS build's message
/// carries, or inferred from the commit and the time.
struct BuildLink: Equatable, Hashable {
    var label: String
    var url: URL
    var inferred: Bool
}

/// One row of the Pipelines section, whichever source it came from.
struct BuildRow: Identifiable, Equatable {
    enum Source: String { case eas, bitbucket }

    var id: String
    var source: Source
    var state: BuildState
    var title: String
    var detail: String?
    /// Why it failed, in a line.
    var failure: String?
    /// "ios" or "android" for an EAS build.
    var platform: String?
    var chips: [String]
    var startedAt: Double
    var finishedAt: Double?
    var url: URL
    var links: [BuildLink]
    var steps: [PipelineStep]
    var isUnseen: Bool
    /// Started by me: a Bitbucket run whose creator is the token's owner; an EAS build linked to
    /// one of those, or started from the CLI's login (weak: that account may be shared).
    var isMine = false
    /// What Mute mutes: "ws/repo" for a Bitbucket run, "eas" for an EAS build; and its name.
    var muteKey = ""
    var muteName = ""
    var branch: String?
    var isPinned = false
    /// Paused or halted with nothing moving for two hours.
    var isStale = false
    /// A newer run on the same branch or pull request exists.
    var isSuperseded = false
    var wait: PipelineWait?
    /// Where it is now: "▸ Static checks · ~4m left", "#3 in queue · ~5m wait", "Run gradlew".
    var progress: String?
    var logLine: String?
    /// A finished internal EAS build's page, to install from, until its artifacts expire.
    var installURL: URL?
    var expiresAt: Double?
    var docsURL: URL?
}

/// Both sources, merged for the panel: which runs show, the links between them, what was seen,
/// the notifications, and Copy failure. Fetching happens in the sources, off the main thread;
/// this only takes their snapshots, and publishes when what shows changed.
@MainActor
final class BuildStore: ObservableObject {
    enum CopyState: Equatable { case working, copied, failed }

    @Published private(set) var eas = EASSnapshot()
    @Published private(set) var bitbucket = BitbucketSnapshot()
    /// What the section shows, in order.
    @Published private(set) var rows: [BuildRow] = []
    /// How many more rows "All" would show, and how many a mute or the branch filter hides.
    @Published private(set) var hiddenByScope = 0
    @Published private(set) var hiddenByFilter = 0
    @Published private(set) var copying: [String: CopyState] = [:]
    @Published private(set) var prefs = PipelinePrefs.load()
    @Published private(set) var health = ServiceHealth()
    /// Branches and repositories the menu offers.
    @Published private(set) var branches: [String] = []
    @Published private(set) var repos: [(key: String, name: String)] = []
    /// Which sources builds.json sets up (or a preview's fixtures stand in for): only those run
    /// and show. With neither, the section stays hidden.
    @Published private(set) var easOn = false
    @Published private(set) var bitbucketOn = false

    /// A finished run shows this long; a failure stays until the notch has been opened.
    static let recentFor: Double = 180
    /// A stale waiting run (the newest on its branch) shows for a week.
    static let waitingFor: Double = 7 * 86_400

    private let isPreview = CommandLine.arguments.contains("--preview")
    private var easSource: EASSource?
    private var bitbucketSource: BitbucketSource?
    private var statusPoller: ServiceStatusPoller?
    private var fixtures: BuildFixtures?
    private var seen: Set<String> = []
    /// Failures shown while the notch is open stay until it closes, though now seen.
    private var held: Set<String> = []
    private var isOpen = false
    /// When each source's first snapshot came: what finished before it is history, not news.
    private var baseline: [BuildRow.Source: Double] = [:]
    private var known: [String: BuildState] = [:]
    private var notified: Set<String> = []
    /// Runs whose finish was actually posted as a notification (a subset of `notified`).
    private var posted: Set<String> = []
    /// Whether one of my Bitbucket pipelines runs or is queued, as last told.
    private var myPipelineRunning = false
    /// Told when that changes: the pull-request lane reads its review lists less often meanwhile.
    var onMyPipelineRunning: ((Bool) -> Void)?
    private var timer: Timer?
    /// When the last Bitbucket snapshot came (the source sends one at least every minute while it
    /// polls), and the EAS boost last sent: a stale snapshot never keeps EAS fast.
    private var bitbucketTakenAt: Double = 0
    private var boostSent: (reason: String?, at: Double) = (nil, 0)
    private var mainTime: Double = 0
    private var mainCount = 0
    private var reportedAt = Date().timeIntervalSince1970

    /// Runs that are really running or queued: what the live line and the spinner count.
    var activeCount: Int { rows.filter { $0.state.isRunning }.count }
    var waitingCount: Int { rows.filter { $0.state == .paused }.count }
    var failedCount: Int { rows.filter { $0.state == .failed }.count }
    var hasUnseenFailure: Bool { rows.contains { $0.isUnseen } }
    var hasActive: Bool { rows.contains { $0.state.isRunning } }
    /// Whether the section has anything to say: rows, rows behind the switch, or a status badge.
    var showsSection: Bool {
        guard easOn || bitbucketOn else { return false }
        return !rows.isEmpty || hiddenByScope > 0 || hiddenByFilter > 0 || prefs.branch != nil
            || (easOn && health.eas != nil) || (bitbucketOn && health.bitbucket != nil)
    }

    func start() {
        Notifier.shared.onBuild = { [weak self] id, action in self?.notificationAction(id, action) }
        if isPreview, let fixtures = BuildFixtures.load() {
            self.fixtures = fixtures
            fixtures.start { [weak self] eas, bitbucket, health in
                guard let self else { return }
                if let eas { self.take(eas: eas) }
                if let bitbucket { self.take(bitbucket: bitbucket) }
                if let health { self.health = health; self.recompute() }
            }
        }
        startConfigured()
        // Visibility moves with the clock (recent runs drop after three minutes).
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                let started = Date()
                self?.startConfigured()
                self?.recompute()
                self?.measure(started)
            }
        }
    }

    /// Starts each source once builds.json sets it up (checked every few seconds, so a file
    /// written while the app runs takes effect without a restart). A source whose part leaves
    /// the file stops reading by itself and empties; it is hidden here.
    private func startConfigured() {
        let config = BuildsConfig.current
        let eas = fixtures?.hasEAS == true || config?.eas != nil
        let bitbucket = fixtures?.hasBitbucket == true || config?.bitbucket != nil
        if eas != easOn { easOn = eas }
        if bitbucket != bitbucketOn { bitbucketOn = bitbucket }
        if eas, easSource == nil, fixtures?.hasEAS != true {
            let source = EASSource { [weak self] snapshot in
                Task { @MainActor in self?.take(eas: snapshot) }
            }
            easSource = source
            source.start()
            if isOpen { source.setPanelOpen(true) }
        }
        if bitbucket, bitbucketSource == nil, fixtures?.hasBitbucket != true {
            let source = BitbucketSource { [weak self] snapshot in
                Task { @MainActor in self?.take(bitbucket: snapshot) }
            }
            bitbucketSource = source
            let muted = prefs.muted
            let open = isOpen
            Task {
                await source.setMuted(muted)
                if open { await source.setPanelOpen(true) }
                await source.start()
            }
        }
        if eas || bitbucket, statusPoller == nil, fixtures?.hasHealth != true {
            let poller = ServiceStatusPoller { [weak self] health in
                Task { @MainActor in
                    self?.health = health
                    self?.recompute()
                }
            }
            statusPoller = poller
            poller.start()
        }
    }

    /// The notch opened: failures on show count as seen, and stale data is refreshed. Pinned open
    /// with the pointer away (`looking: false`), the sources read as for an open notch but
    /// nothing counts as seen.
    func panelOpened(looking: Bool = true) {
        isOpen = looking
        if looking {
            held = Set(rows.filter { $0.state == .failed }.map(\.id))
            seen.formUnion(held)
        }
        easSource?.refreshSoon()
        easSource?.setPanelOpen(true)
        if let bitbucketSource { Task { await bitbucketSource.setPanelOpen(true) } }
        recompute()
    }

    /// Pinned open, the pointer left: what was held lets go as when the notch closes, and a
    /// failure that arrives now stays unseen (its ✕ in the wing) until the pointer comes back.
    /// The sources keep reading as for an open notch.
    func lookedAway() {
        isOpen = false
        held = []
        recompute()
    }

    func panelClosed() {
        isOpen = false
        held = []
        easSource?.setPanelOpen(false)
        if let bitbucketSource { Task { await bitbucketSource.setPanelOpen(false) } }
        recompute()
    }

    /// Setup's Check Again.
    func recheckBitbucket() {
        BuildsConfig.reload()
        startConfigured()
        if let bitbucketSource { Task { await bitbucketSource.recheckToken() } }
    }

    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    /// The newest running run, for the header's live summary.
    var newestActive: BuildRow? { rows.filter { $0.state.isRunning }.max { $0.startedAt < $1.startedAt } }

    // MARK: Preferences

    func setScope(_ scope: PipelinePrefs.Scope) {
        prefs.scope = scope
        prefs.save()
        recompute()
    }

    func toggleMute(_ key: String) {
        if prefs.muted.contains(key) { prefs.muted.remove(key) } else { prefs.muted.insert(key) }
        prefs.save()
        if let bitbucketSource { let muted = prefs.muted; Task { await bitbucketSource.setMuted(muted) } }
        recompute()
    }

    func togglePin(_ id: String) {
        if let index = prefs.pinned.firstIndex(of: id) { prefs.pinned.remove(at: index) } else { prefs.pinned.append(id) }
        prefs.save()
        recompute()
    }

    func setBranch(_ branch: String?) {
        prefs.branch = branch
        prefs.save()
        recompute()
    }

    // MARK: Snapshots

    private func take(eas snapshot: EASSnapshot) {
        let started = Date()
        if snapshot != eas { eas = snapshot }
        if snapshot.fetchedAt > 0 { noteTransitions(.eas, items: snapshot.builds.map { ("eas:\($0.id)", $0.state, $0.completedAt) }) }
        recompute()
        measure(started)
    }

    private func take(bitbucket snapshot: BitbucketSnapshot) {
        let started = Date()
        if snapshot != bitbucket { bitbucket = snapshot }
        bitbucketTakenAt = Date().timeIntervalSince1970
        if snapshot.fetchedAt > 0 { noteTransitions(.bitbucket, items: snapshot.runs.map { ("bb:\($0.id)", $0.state, $0.completedAt) }) }
        // A running pipeline may start an EAS build: EAS reads its list more often meanwhile.
        easSource?.setOthersActive(snapshot.runs.contains { $0.state.isRunning })
        let mineRunning = snapshot.runs.contains { $0.state.isRunning && snapshot.owner?.owns($0) == true }
        if mineRunning != myPipelineRunning {
            myPipelineRunning = mineRunning
            onMyPipelineRunning?(mineRunning)
        }
        recompute()
        measure(started)
    }

    /// Finishes since the last snapshot (by row id), once each: notified when it is mine (passed
    /// and failed, while the screen is locked), and failures marked unseen. The first snapshot
    /// is history: only failures from the last few minutes count as unseen, and nothing is
    /// notified.
    private func noteTransitions(_ source: BuildRow.Source, items: [(String, BuildState, Double?)]) {
        let now = Date().timeIntervalSince1970
        let first = baseline[source] == nil
        if first { baseline[source] = now }
        for (id, state, finishedAt) in items {
            let before = known[id]
            known[id] = state
            guard state == .succeeded || state == .failed, !notified.contains(id) else { continue }
            notified.insert(id)
            if first {
                if (finishedAt ?? 0) < now - Self.recentFor { seen.insert(id) }
                continue
            }
            let isNews = before?.isActive == true || (before == nil && (finishedAt ?? now) >= (baseline[source] ?? now) - 60)
            if isNews { notify(id) }
        }
    }

    private func notify(_ id: String) {
        guard Notifier.shared.isScreenLocked || (isPreview && CommandLine.arguments.contains("--notify-unlocked")) else { return }
        let rows = allRows(now: Date().timeIntervalSince1970)
        // "All" is for looking: only my own runs notify.
        guard let row = rows.first(where: { $0.id == id }), row.isMine, !prefs.muted.contains(row.muteKey) else { return }
        let failed = row.state == .failed
        posted.insert(id)
        let source = row.source == .eas ? "EAS build" : "Bitbucket pipeline"
        Notifier.shared.postBuild(id: id, title: "\(source) \(failed ? "failed" : "passed")",
                                  subtitle: ([row.title] + row.chips.prefix(1)).joined(separator: " · "),
                                  body: failed ? (row.failure ?? row.detail ?? "") : (row.detail ?? "Took \(elapsed((row.finishedAt ?? row.startedAt) - row.startedAt))"),
                                  failed: failed)
    }

    /// Whether Pipelines posted this run's finish: the pull-request lane then does not announce
    /// the same failed build again.
    func hasNotified(_ ref: PipelineRef) -> Bool {
        posted.contains("bb:\(ref.key)")
    }

    private func notificationAction(_ id: String, _ action: Notifier.BuildAction) {
        let row = allRows(now: Date().timeIntervalSince1970).first { $0.id == id }
        switch action {
        case .open: if let row { open(row.url) }
        case .copy: if let row { copyFailure(row) }
        }
    }

    // MARK: Rows

    private func recompute() {
        let now = Date().timeIntervalSince1970
        var all = allRows(now: now)
        // A failure that arrives while the notch is open is seen there and then.
        if isOpen {
            let shown = all.filter { $0.isUnseen }.map(\.id)
            if !shown.isEmpty {
                seen.formUnion(shown)
                held.formUnion(shown)
                all = allRows(now: now)
            }
        }
        let shown = all.filter { show($0, now: now) }
        let unmuted = shown.filter { $0.isPinned || !prefs.muted.contains($0.muteKey) }
        let branched = unmuted.filter { $0.isPinned || prefs.branch == nil || $0.branch == prefs.branch }
        let scoped = branched.filter { $0.isPinned || prefs.scope == .all || $0.isMine }
        let ordered = scoped.sorted { a, b in
            func rank(_ r: BuildRow) -> Int {
                switch r.state {
                case .running: return 0
                case .queued: return 1
                case .failed: return r.isUnseen ? 2 : 4
                case .paused: return r.isStale ? 5 : 3
                default: return 4
                }
            }
            if rank(a) != rank(b) { return rank(a) < rank(b) }
            return (a.finishedAt ?? a.startedAt) > (b.finishedAt ?? b.startedAt)
        }
        if ordered != rows { rows = ordered }
        let hidden = branched.count - scoped.count
        if hidden != hiddenByScope { hiddenByScope = hidden }
        let filtered = shown.count - branched.count
        if filtered != hiddenByFilter { hiddenByFilter = filtered }
        // The menu: branches of what shows in either scope (newest first), and every repository.
        var seenBranches: [String] = []
        for row in shown.sorted(by: { $0.startedAt > $1.startedAt }) {
            if let branch = row.branch, !seenBranches.contains(branch) { seenBranches.append(branch) }
        }
        if let branch = prefs.branch, !seenBranches.contains(branch) { seenBranches.insert(branch, at: 0) }
        let nextBranches = Array(seenBranches.prefix(12))
        if nextBranches != branches { branches = nextBranches }
        var nextRepos: [(key: String, name: String)] = easOn ? [("eas", "EAS builds")] : []
        if bitbucketOn { for repo in BitbucketConfig.loadReposCached() { nextRepos.append((repo.key, repo.repo)) } }
        if nextRepos.map(\.key) != repos.map(\.key) { repos = nextRepos }
        sendBoost(now: now)
    }

    // MARK: EAS while my pipeline runs

    /// Tells EAS when one of my pipelines is running or queued, so a build it queues shows within
    /// about 25 s: on a change, and every 30 s while it holds (EAS lets it lapse after two
    /// minutes without word). Never waits on either source.
    private func sendBoost(now: Double) {
        guard let easSource else { return }
        let reason = Self.boostReason(bitbucket, muted: prefs.muted, now: now,
                                      fresh: fixtures?.hasBitbucket == true || now - bitbucketTakenAt < 300,
                                      easRepos: Set(eas.builds.compactMap { $0.pipeline.map { "\($0.workspace)/\($0.repo)" } }))
        guard reason != boostSent.reason || (reason != nil && now - boostSent.at >= 30) else { return }
        boostSent = (reason, now)
        easSource.setPipelineBoost(reason)
    }

    /// My running or queued pipeline (not paused or stale), from a fresh snapshot of a healthy
    /// source, in an unmuted repository, unless EAS itself is muted: the one most likely to start
    /// an EAS build first (its step or selector says EAS, or its repository ("ws/repo") is in
    /// `easRepos`, those whose pipelines EAS builds name), as a few words for the log.
    nonisolated static func boostReason(_ snapshot: BitbucketSnapshot, muted: Set<String>, now: Double, fresh: Bool,
                                        easRepos: Set<String> = []) -> String? {
        guard fresh, snapshot.status == nil, !muted.contains("eas"), let owner = snapshot.owner else { return nil }
        let mine = snapshot.runs.filter {
            $0.state.isRunning && owner.owns($0) && !muted.contains("\($0.ref.workspace)/\($0.ref.repo)")
        }
        guard !mine.isEmpty else { return nil }
        func easLike(_ text: String?) -> Bool {
            guard let text else { return false }
            return text.range(of: #"(?i)(^|[^a-z])eas([^a-z]|$)"#, options: .regularExpression) != nil
        }
        if let run = mine.first(where: { easLike($0.runningStep?.name) || easLike($0.selector) }) {
            let what = easLike(run.runningStep?.name) ? "step \(run.runningStep?.name ?? "")" : run.selector ?? ""
            return "\(run.ref.repo) #\(run.ref.number), \(what)"
        }
        if let run = mine.first(where: { easRepos.contains("\($0.ref.workspace)/\($0.ref.repo)") }) {
            return "\(run.ref.repo) #\(run.ref.number)"
        }
        let run = mine[0]
        return "\(run.ref.repo) #\(run.ref.number), \(run.state.rawValue)"
    }

    /// Running and queued runs, waiting ones (a stale one only while it is the newest on its
    /// branch, for a week), anything that finished in the last three minutes, a failure not yet
    /// seen, and pinned runs.
    private func show(_ row: BuildRow, now: Double) -> Bool {
        if row.isPinned { return true }
        switch row.state {
        case .running, .queued: return true
        case .paused: return !row.isSuperseded && (!row.isStale || now - row.startedAt < Self.waitingFor)
        case .failed: return now - (row.finishedAt ?? now) < Self.recentFor || row.isUnseen || held.contains(row.id)
        default: return now - (row.finishedAt ?? now) < Self.recentFor
        }
    }

    /// Every run both sources know, as rows, with the links between them.
    private func allRows(now: Double) -> [BuildRow] {
        var easLinks: [String: [BuildLink]] = [:]
        var runLinks: [String: [BuildLink]] = [:]
        var linkedRuns: [String: [String]] = [:]
        let runs = bitbucketOn ? bitbucket.runs : []
        let builds = easOn ? eas.builds : []
        let owner = bitbucket.owner
        let mineRuns = Set(runs.filter { owner?.owns($0) == true }.map(\.id))
        for build in builds {
            let label = "EAS \(build.platformName)"
            if let ref = build.pipeline {
                easLinks[build.id] = [BuildLink(label: "#\(ref.number)", url: BitbucketConfig.runURL(ref), inferred: false)]
                linkedRuns[build.id] = [ref.key]
                if runs.contains(where: { $0.id == ref.key }) {
                    runLinks[ref.key, default: []].append(BuildLink(label: label, url: build.url, inferred: false))
                }
            } else if let commit = build.commit,
                      let run = runs.filter({ $0.commit == commit && build.createdAt >= $0.createdAt - 60 && build.createdAt <= ($0.completedAt ?? now) + 120 })
                          .min(by: { abs(build.createdAt - $0.createdAt) < abs(build.createdAt - $1.createdAt) }) {
                easLinks[build.id] = [BuildLink(label: "#\(run.ref.number)", url: run.url, inferred: true)]
                linkedRuns[build.id] = [run.id]
                runLinks[run.id, default: []].append(BuildLink(label: label, url: build.url, inferred: true))
            }
        }
        let pinned = Set(prefs.pinned)
        var rows: [BuildRow] = []
        for build in builds {
            let id = "eas:\(build.id)"
            let message = build.message.map(PipelineRef.strip)?.nonEmpty ?? build.commitMessage.map { String($0.split(separator: "\n").first ?? "") }
            let localMine = build.actorKind == "User" && build.actor != nil && build.actor == eas.cliUser
            let mine = (linkedRuns[build.id] ?? []).contains(where: mineRuns.contains) || localMine
            var progress: String?
            switch build.state {
            case .queued:
                let place = build.queuePosition.map { "#\($0) in queue" }
                let wait = build.waitLeft.map { "~\(shortDuration($0)) wait" }
                progress = [place, wait].compactMap { $0 }.joined(separator: " · ").nonEmpty ?? "Waiting for a builder"
            case .running:
                let phase = build.phase ?? (build.workerStartedAt == nil ? "Starting builder" : "Building")
                progress = ([phase, etaText(median: build.usualDuration, elapsed: now - build.createdAt)].compactMap { $0 }).joined(separator: " · ")
            default: break
            }
            rows.append(BuildRow(
                id: id, source: .eas, state: build.state,
                title: [build.platformName, build.profile].compactMap { $0 }.joined(separator: " "),
                detail: message,
                failure: build.state == .failed ? failureLine(code: build.errorCode, message: build.errorMessage) : nil,
                platform: build.platform, chips: [build.version].compactMap { $0 },
                startedAt: build.createdAt, finishedAt: build.state.isActive ? nil : build.completedAt ?? build.createdAt,
                url: build.url, links: (easLinks[build.id] ?? []).sorted { $0.label < $1.label }, steps: [],
                isUnseen: build.state == .failed && mine && !seen.contains(id),
                isMine: mine, muteKey: "eas", muteName: "EAS builds", branch: nil, isPinned: pinned.contains(id),
                progress: progress,
                installURL: build.isInstallable(now: now) ? build.url : nil, expiresAt: build.expiresAt, docsURL: build.docsURL))
        }
        // Waiting runs a newer run on the same branch or pull request has overtaken.
        var newest: [String: Double] = [:]
        for run in runs {
            let key = "\(run.ref.workspace)/\(run.ref.repo)|\(run.refKey)"
            newest[key] = max(newest[key] ?? 0, run.createdAt)
        }
        for run in runs {
            let id = "bb:\(run.id)"
            let mine = mineRuns.contains(run.id)
            let detail = [run.selector, run.creator].compactMap { $0 }.joined(separator: " · ")
            var progress: String?
            if run.state == .running {
                progress = (["▸ \(run.runningStep?.name ?? "Running")", etaText(median: run.usualDuration, elapsed: now - run.createdAt)].compactMap { $0 }).joined(separator: " · ")
            } else if run.state == .queued {
                progress = "Waiting for a runner"
            }
            let stale = run.isStale(now: now)
            rows.append(BuildRow(
                id: id, source: .bitbucket, state: run.state,
                title: "\(run.ref.repo) #\(run.ref.number)",
                detail: detail.nonEmpty,
                failure: run.state == .failed ? (run.failedStep.map { "\($0.name) failed" } ?? "Pipeline failed") : nil,
                platform: nil,
                chips: [run.branch, run.pullRequest.map { "PR #\($0)" }].compactMap { $0 },
                startedAt: run.createdAt, finishedAt: run.state.isActive ? nil : run.completedAt ?? run.createdAt,
                url: run.url, links: (runLinks[run.id] ?? []).sorted { $0.label < $1.label }, steps: run.steps,
                isUnseen: run.state == .failed && mine && !seen.contains(id),
                isMine: mine, muteKey: "\(run.ref.workspace)/\(run.ref.repo)", muteName: run.ref.repo, branch: run.branch,
                isPinned: pinned.contains(id), isStale: stale,
                isSuperseded: (newest["\(run.ref.workspace)/\(run.ref.repo)|\(run.refKey)"] ?? 0) > run.createdAt,
                wait: run.wait, progress: progress, logLine: run.logLine))
        }
        return rows
    }

    private func failureLine(code: String?, message: String?) -> String {
        switch (code, message) {
        case let (code?, message?): return "\(code): \(message)"
        case let (nil, message?): return message
        case let (code?, nil): return code
        default: return "Build failed"
        }
    }

    // MARK: Copy failure

    func copyFailure(_ row: BuildRow) {
        guard copying[row.id] != .working else { return }
        copying[row.id] = .working
        let id = row.id
        let pipelineURL = row.links.first?.url
        let easURLs = row.links.map(\.url)
        let build = eas.builds.first { "eas:\($0.id)" == id }
        let source = bitbucketSource
        let fixtures = self.fixtures
        Task { [weak self] in
            var text: String?
            if let fixture = fixtures?.report(for: id, easURLs: easURLs) {
                text = fixture
            } else if let build {
                text = await EASFailure.report(for: build, pipelineURL: pipelineURL)
            } else if let source, id.hasPrefix("bb:") {
                text = await source.failureReport(for: String(id.dropFirst(3)), easURLs: easURLs)
            }
            guard let self else { return }
            if let text, !text.isEmpty {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                self.copying[id] = .copied
                noteBuildLog("copied failure details for \(id.hasPrefix("eas:") ? "an EAS build" : "a Bitbucket run")")
            } else {
                self.copying[id] = .failed
            }
            try? await Task.sleep(for: .seconds(2.5))
            self.copying[id] = nil
        }
    }

    /// Dev: what the main thread spends on builds, every minute with CLAUDE_NOTCH_BUILD_TIMING.
    private func measure(_ started: Date) {
        mainTime += Date().timeIntervalSince(started)
        mainCount += 1
        let now = Date().timeIntervalSince1970
        guard ProcessInfo.processInfo.environment["CLAUDE_NOTCH_BUILD_TIMING"] != nil, now - reportedAt >= 60 else { return }
        FileHandle.standardError.write(Data("builds main-thread: \(mainCount) updates, \(String(format: "%.2f", mainTime * 1000)) ms total, \(String(format: "%.3f", mainTime * 1000 / Double(max(1, mainCount)))) ms each, over \(Int(now - reportedAt)) s\n".utf8))
        mainTime = 0
        mainCount = 0
        reportedAt = now
    }
}
