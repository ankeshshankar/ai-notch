import Foundation

/// Pull requests for the panel, on the main thread: mine and the ones waiting for my review,
/// split into the rows that need something (shown inline) and a count of the quiet ones. Fed by
/// PullRequestSource, which runs only while builds.json has a `bitbucket` part with
/// `pullRequests` not false; a failure there never touches Pipelines.
@MainActor
final class ReviewStore: ObservableObject {
    /// Whether pull requests are set up (builds.json); the section hides without it.
    @Published private(set) var isOn = false
    /// Every open pull request of mine, newest update first.
    @Published private(set) var mine: [PullRequest] = []
    /// Every open one I review, newest update first.
    @Published private(set) var toReview: [PullRequest] = []
    /// The rows to show: what needs something (PRNeed), most urgent first, then newest.
    @Published private(set) var attention: [PullRequest] = []
    /// The quiet ones, only counted.
    @Published private(set) var quietCount = 0
    /// Why nothing new shows (nil while all is well). `isSetup` ones are quiet: "needs
    /// read:pullrequest", "not connected", "who am I?".
    @Published private(set) var status: SourceStatus?
    @Published private(set) var me: BitbucketOwner?
    /// When mine was last read (0: never).
    @Published private(set) var updatedAt: Double = 0
    /// The pull-request lane's requests in the last hour, for ⓘ ("41 in the last hour (mine 30, …)").
    @Published private(set) var requestSummary = ""
    /// The latest events, newest first (at most 20), for a look in ⓘ or a test.
    @Published private(set) var recentEvents: [PREvent] = []

    /// Called with each poll's events, after the ones Pipelines already told about are dropped.
    /// The notification step sets this (and posts only while the screen is locked).
    var onEvents: (([PREvent]) -> Void)?
    /// Whether Pipelines already notified a run (BuildStore's notified set): a failed build on
    /// a pull request of mine is then not announced twice.
    var pipelineNotified: ((PipelineRef) -> Bool)?

    /// Attention rows with news I have not looked at yet: the collapsed wing's pull-request slot.
    @Published private(set) var unseenCount = 0
    /// Pull requests muted from their row's menu (by key): no row, no wing, no notification,
    /// until they close.
    @Published private(set) var muted: Set<String>
    @Published private(set) var notify = NotifyPrefs.load()

    private var source: PullRequestSource?
    private var timer: Timer?
    /// The last snapshot's pull requests, before muting.
    private var all: [PullRequest] = []
    /// News already looked at, as "key|part" (a review request, an approval count, the newest
    /// comment, a build failure): a part not in here is unseen.
    private var seenNews: Set<String>
    /// The pointer is over the open notch: news counts as seen as it arrives.
    private var looking = false
    /// The rows on show while looking: their comments stop counting as new once the notch closes
    /// (not at once, so a row does not vanish under the pointer).
    private var shownWhileLooking: [String: PullRequest] = [:]

    var needsCount: Int { attention.count }
    /// The section has rows to show inline (two columns: the right one).
    var showsBlock: Bool { isOn && !attention.isEmpty }
    /// Something to say at all: pull requests, or a reason there are none.
    var hasAnything: Bool { isOn && (!mine.isEmpty || !toReview.isEmpty || status != nil) }
    /// Not readable now for a setup reason (no read:pullrequest, no token): quiet, grey.
    var isQuietSetup: Bool { status?.isSetup == true }

    /// Which pull-request news notifies (only while the screen is locked); Setup's checkboxes.
    struct NotifyPrefs: Equatable {
        var approved = true
        var changes = true
        var comments = true
        var reviews = true
        var builds = true

        private static let key = "prs.notify"

        static func load() -> NotifyPrefs {
            var prefs = NotifyPrefs()
            guard let object = UserDefaults.standard.dictionary(forKey: key) else { return prefs }
            prefs.approved = object["approved"] as? Bool ?? true
            prefs.changes = object["changes"] as? Bool ?? true
            prefs.comments = object["comments"] as? Bool ?? true
            prefs.reviews = object["reviews"] as? Bool ?? true
            prefs.builds = object["builds"] as? Bool ?? true
            return prefs
        }

        func save() {
            UserDefaults.standard.set(["approved": approved, "changes": changes, "comments": comments, "reviews": reviews, "builds": builds], forKey: Self.key)
        }

        func allows(_ kind: PREvent.Kind) -> Bool {
            switch kind {
            case .approved: return approved
            case .changesRequested: return changes
            case .newComments: return comments
            case .reviewRequested: return reviews
            case .buildFailed: return builds
            }
        }
    }

    /// Against a stub, the mute and seen lists live under keys of their own, so a test never
    /// touches the real ones.
    private static var suffix: String { BitbucketConfig.isStubbed ? ".stub" : "" }
    private static var mutedKey: String { "prs.muted" + suffix }
    private static var seenKey: String { "prs.seenNews" + suffix }

    init() {
        muted = Set(UserDefaults.standard.stringArray(forKey: Self.mutedKey) ?? [])
        seenNews = Set(UserDefaults.standard.stringArray(forKey: Self.seenKey) ?? [])
    }

    func start() {
        startConfigured()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.startConfigured() }
        }
    }

    /// Starts the source once builds.json turns pull requests on (checked every 5 s). The source
    /// stops reading by itself when they are turned off.
    private func startConfigured() {
        let config = BuildsConfig.current?.bitbucket
        let on = config?.pullRequests == true
        if on != isOn { isOn = on }
        guard on, source == nil else { return }
        let source = PullRequestSource(onChange: { [weak self] snapshot in
            Task { @MainActor in self?.take(snapshot) }
        }, onEvents: { [weak self] events in
            Task { @MainActor in self?.take(events) }
        })
        self.source = source
        Task { await source.start() }
    }

    /// The notch opened: mine is read if older than a minute.
    func panelOpened() {
        if let source { Task { await source.refreshSoon() } }
    }

    /// One of my pipelines is running (BuildStore knows): the review lists slow to every 20 min.
    func setMyPipelineRunning(_ running: Bool) {
        if let source { Task { await source.setMyPipelineRunning(running) } }
    }

    /// The rows were on screen: their comments so far stop counting as new.
    func markSeen(_ prs: [PullRequest]) {
        let keys = prs.filter { $0.newComments > 0 }.map(\.id)
        guard !keys.isEmpty, let source else { return }
        Task { await source.markSeen(keys) }
    }

    /// Setup's "Check Again".
    func recheckToken() {
        if let source { Task { await source.recheckToken() } }
    }

    /// Merge checks, read now (one request); nil when unknown or the read failed.
    func mergeability(for pr: PullRequest) async -> PRMergeability? {
        guard let source else { return nil }
        return await source.mergeability(for: pr.id)
    }

    private func take(_ snapshot: PullRequestSnapshot) {
        let prs = snapshot.prs
        all = prs
        let mine = prs.filter { $0.role == .mine }
        let toReview = prs.filter { $0.role == .reviewing }
        if mine != self.mine { self.mine = mine }
        if toReview != self.toReview { self.toReview = toReview }
        // A muted pull request that closed is forgotten (only from a healthy, read answer).
        if snapshot.status == nil, snapshot.mineFetchedAt > 0, !muted.isEmpty {
            let open = Set(prs.map(\.id))
            if !muted.isSubset(of: open) { setMuted(muted.intersection(open)) }
        }
        refreshAttention()
        if snapshot.status != status { status = snapshot.status }
        if snapshot.me != me { me = snapshot.me }
        if snapshot.mineFetchedAt != updatedAt { updatedAt = snapshot.mineFetchedAt }
        if let source {
            Task {
                let (count, notModified) = await source.debugCounts()
                let summary = ReviewStore.summary(count, notModified: notModified)
                await MainActor.run { if summary != self.requestSummary { self.requestSummary = summary } }
            }
        }
    }

    private func take(_ events: [PREvent]) {
        let kept = ReviewStore.dropAlreadyNotified(events, pipelineNotified: pipelineNotified)
        if kept.count < events.count {
            noteBuildLog("bitbucket prs: \(events.count - kept.count) failed build(s) Pipelines already notified, not announced again")
        }
        guard !kept.isEmpty else { return }
        recentEvents = Array((kept.reversed() + recentEvents).prefix(20))
        onEvents?(kept)
    }

    // MARK: On screen

    /// The rows to show (muted ones left out), the quiet count and the unseen news, from the last
    /// snapshot. News that arrives while I look is seen there and then.
    private func refreshAttention() {
        let attention = ReviewStore.attention(all).filter { !muted.contains($0.id) }
        if attention != self.attention { self.attention = attention }
        let quiet = all.count - attention.count
        if quiet != quietCount { quietCount = quiet }
        if looking {
            for pr in attention { shownWhileLooking[pr.id] = pr }
            let parts = attention.flatMap(Self.newsParts)
            if !Set(parts).isSubset(of: seenNews) { rememberSeen(parts) }
        }
        let unseen = attention.filter { !Set(Self.newsParts($0)).isSubset(of: seenNews) }.count
        if unseen != unseenCount { unseenCount = unseen }
    }

    /// What counts as news on a row, each part once: a review request, who asked for changes, an
    /// approval count, the newest comment by someone else, a failed build.
    nonisolated static func newsParts(_ pr: PullRequest) -> [String] {
        var parts: [String] = []
        for need in pr.needs {
            switch need {
            case .reviewRequested: parts.append("review")
            case .changesRequested: parts.append("changes:" + pr.changesRequestedBy.sorted().joined(separator: ","))
            case .approved: parts.append("approved:\(pr.approvals)")
            case .buildFailed: parts.append("build:" + (pr.build?.key ?? ""))
            case .newComments: parts.append("comments:\(Int(pr.recentComments.map(\.createdAt).max() ?? 0))")
            }
        }
        return parts.map { "\(pr.id)|\($0)" }
    }

    private func rememberSeen(_ parts: [String]) {
        seenNews.formUnion(parts)
        // Only what belongs to an open pull request is kept.
        let open = Set(all.map(\.id))
        if !open.isEmpty { seenNews = seenNews.filter { open.contains(String($0.split(separator: "|", maxSplits: 1).first ?? "")) } }
        UserDefaults.standard.set(Array(seenNews).sorted(), forKey: Self.seenKey)
    }

    /// The pointer is over the open notch (true), or it closed or the pointer left a pinned one
    /// (false). Looking makes the rows' news seen; when it ends, the comments they showed stop
    /// counting as new.
    func setLooking(_ looking: Bool) {
        guard looking != self.looking else { return }
        self.looking = looking
        if looking {
            refreshAttention()
        } else if !shownWhileLooking.isEmpty {
            markSeen(Array(shownWhileLooking.values))
            shownWhileLooking = [:]
        }
    }

    /// A row's "Mark seen": its news is seen and its comments are no longer new.
    func markRowSeen(_ pr: PullRequest) {
        rememberSeen(Self.newsParts(pr))
        markSeen([pr])
        refreshAttention()
    }

    func isMuted(_ pr: PullRequest) -> Bool { muted.contains(pr.id) }

    func toggleMute(_ pr: PullRequest) {
        var next = muted
        if next.contains(pr.id) { next.remove(pr.id) } else { next.insert(pr.id) }
        setMuted(next)
        refreshAttention()
    }

    private func setMuted(_ next: Set<String>) {
        muted = next
        UserDefaults.standard.set(Array(next).sorted(), forKey: Self.mutedKey)
    }

    func setNotify(_ prefs: NotifyPrefs) {
        notify = prefs
        prefs.save()
    }

    /// The notification step (`onEvents`): each event of a pull request that is not muted and
    /// whose kind is ticked in Setup, only while the screen is locked (Notifier decides that).
    func post(_ events: [PREvent]) {
        for event in events where !muted.contains(event.pr.key) && notify.allows(event.kind) {
            Notifier.shared.postPullRequest(event)
        }
    }

    // MARK: Pure parts

    /// The rows that need something, most urgent need first, then the newest update.
    nonisolated static func attention(_ prs: [PullRequest]) -> [PullRequest] {
        func rank(_ pr: PullRequest) -> Int { pr.needs.first.flatMap { PRNeed.allCases.firstIndex(of: $0) } ?? PRNeed.allCases.count }
        return prs.filter(\.needsSomething).sorted { (rank($0), -$0.updatedAt) < (rank($1), -$1.updatedAt) }
    }

    /// A failed build on my pull request whose Pipelines run was already notified is dropped.
    nonisolated static func dropAlreadyNotified(_ events: [PREvent], pipelineNotified: ((PipelineRef) -> Bool)?) -> [PREvent] {
        events.filter { event in
            if case .buildFailed(let pipeline?) = event.kind, pipelineNotified?(pipeline) == true { return false }
            return true
        }
    }

    nonisolated static func summary(_ count: RequestCount, notModified: Int) -> String {
        let order = ["mine", "review", "statuses", "comments", "merge", "owner"]
        let parts = order.compactMap { kind in count.byKind[kind].flatMap { $0 > 0 ? "\(kind) \($0)" : nil } }
        return "\(count.total) in the last hour" + (parts.isEmpty ? "" : " (" + parts.joined(separator: ", ") + ")")
            + (notModified > 0 ? ", \(notModified) unchanged" : "")
    }
}
