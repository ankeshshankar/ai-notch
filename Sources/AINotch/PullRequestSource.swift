import Foundation

// Polls Bitbucket for my open pull requests and the ones waiting for my review, in the client's
// pull-request lane (120 requests an hour, at most 150), on the cooperative pool. Read only.
//
// - Mine: `GET /workspaces/{ws}/pullrequests/{my uuid}?state=OPEN` (the older
//   `/pullrequests/{user}` now answers 404, "no API hosted at this URL"), every 2 minutes;
//   opening the notch reads it when older than a minute.
// - To review: per repository, `GET /repositories/{ws}/{repo}/pullrequests?q=…`, every 10
//   minutes (20 while one of my pipelines runs). The query asks for mine too,
//   `state="OPEN" AND (author.uuid="{me}" OR reviewers.uuid="{me}")`, so a repository in
//   another workspace needs no workspace request of its own; if Bitbucket refuses the OR, it
//   falls back to `reviewers.uuid` alone.
// - Details, only for what changed: `/statuses` when updated_on moved (and every 4 minutes while
//   a build of mine is in progress), `/comments?sort=-updated_on&pagelen=10` when comment_count
//   moved. Merge checks only when asked.
// A token without read:pullrequest (a 403 naming the scope) stops only this lane, quietly; a
// newer token in the Keychain is looked for every 10 minutes. Nothing here touches Pipelines'
// lane, status or budget.

struct PullRequestSnapshot: Equatable, Sendable {
    /// Mine and the ones I review, newest update first.
    var prs: [PullRequest] = []
    var status: SourceStatus?
    /// When mine and the review lists were last read.
    var mineFetchedAt: Double = 0
    var reviewFetchedAt: Double = 0
    var repoCount = 0
    var me: BitbucketOwner?
    /// Whether the combined author-or-reviewer query works (nil: not tried yet).
    var combinedQuery: Bool?
}

actor PullRequestSource {
    private static let lane = BitbucketLane.pullRequests
    private let client: BitbucketClient
    private let onChange: @Sendable (PullRequestSnapshot) -> Void
    private let onEvents: @Sendable ([PREvent]) -> Void

    private var repos: [BitbucketRepo] = []
    private var reposReadAt: Double = 0
    private var reposConfig: BuildsConfig.Bitbucket?
    private var me: BitbucketOwner?
    private var meTriedAt: Double = -.infinity
    private var status: SourceStatus?

    /// What each read last returned, by pull request key: mine per workspace, the rest per
    /// repository. The merged view prefers the newer updated_on.
    private var fromMine: [String: [String: PullRequest]] = [:]
    private var fromRepo: [String: [String: PullRequest]] = [:]
    private var mineAt: [String: Double] = [:]
    private var reviewAt: [String: Double] = [:]
    private var skipUntil: [String: Double] = [:]
    /// Lists that fail with source.* (a pull request from a deleted fork): asked without it.
    private var noSource: Set<String> = []
    private var combined: Bool?

    private struct Details {
        var statusesFor: String?
        var statusesAt: Double = 0
        var build: PRBuild?
        var commentsFor: Int?
        var comments: [PRComment] = []
    }
    private var details: [String: Details] = [:]

    private var seen: [String: PRSeenEntry] = [:]
    private var seenLoaded = false
    /// No seen-state file at the start: the first full look only records.
    private var silentUntilCovered = false
    private var covered: Set<String> = []
    private var seenDirty = false

    private var wantsNow = false
    private var myPipelineRunning = false
    private var last = PullRequestSnapshot()
    private var lastSent = false
    private var loop: Task<Void, Never>?

    init(client: BitbucketClient = .shared, onChange: @escaping @Sendable (PullRequestSnapshot) -> Void,
         onEvents: @escaping @Sendable ([PREvent]) -> Void = { _ in }) {
        self.client = client
        self.onChange = onChange
        self.onEvents = onEvents
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

    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// The notch opened: mine is read if older than a minute, and a missing token looked for.
    func refreshSoon() { wantsNow = true }

    /// One of my pipelines runs: the review lists are read every 20 minutes instead of 10.
    func setMyPipelineRunning(_ running: Bool) { myPipelineRunning = running }

    /// Setup's "Check Again".
    func recheckToken() async {
        await client.recheck()
        wantsNow = true
    }

    /// I looked at these pull requests: their comments so far are no longer new.
    func markSeen(_ keys: [String]) {
        let now = self.now
        for key in keys where seen[key] != nil { seen[key]?.seenAt = now }
        seenDirty = true
        saveSeen()
        publish()
    }

    private var now: Double { Date().timeIntervalSince1970 }

    // MARK: The schedule

    private func tick() async {
        let now = self.now
        let config = BuildsConfig.current?.bitbucket
        if config != reposConfig || now - reposReadAt > 300 || repos.isEmpty && now - reposReadAt > 60 {
            reposConfig = config
            reposReadAt = now
            repos = BitbucketConfig.loadRepos()
        }
        guard let config, config.pullRequests else {
            status = nil
            fromMine = [:]
            fromRepo = [:]
            wantsNow = false
            return publish()
        }
        if !seenLoaded {
            let loaded = PRSeenStore.load()
            seen = loaded.entries
            silentUntilCovered = !loaded.existed
            seenLoaded = true
        }
        // The token: shared with Pipelines. Without one this lane can use, look for one.
        if await !client.hasToken(for: Self.lane) {
            if await client.lacksScope(for: Self.lane) {
                if await client.lookForNewerToken(for: Self.lane, every: wantsNow ? 60 : BuildPolling.broken) { status = nil }
            } else if case .found = await client.loadToken(for: Self.lane, urgent: wantsNow) {
                status = nil
            }
        }
        guard await client.hasToken(for: Self.lane) else {
            status = await client.lacksScope(for: Self.lane)
                ? Self.scopeStatus
                : SourceStatus(text: "not connected", help: BitbucketConfig.setupHelp, isSetup: true)
            wantsNow = false
            return publish()
        }
        // A token to use: what said otherwise is over (the checks below set theirs again).
        if status?.isSetup == true { status = nil }
        guard !repos.isEmpty else {
            status = SourceStatus(text: "no repositories", help: "No repositories in \(BuildsConfig.displayPath) for pull requests.", isSetup: true)
            return publish()
        }
        guard await now >= client.pauseUntil(Self.lane) else { return publish() }
        await client.backOffIfNearCap(Self.lane)
        await resolveMe()
        guard let uuid = me?.uuid else {
            status = SourceStatus(text: "who am I?", help: "Pull requests need your Bitbucket account: the token's /user (scope read:user), or commits made with your git email in one of the repositories.", isSetup: true)
            wantsNow = false
            return publish()
        }

        let slow = await client.slow(Self.lane)
        let locked = BuildPolling.isScreenLocked
        let opened = wantsNow
        wantsNow = false
        // 1. Mine, per workspace (only the main one once the combined query covers the rest).
        let workspaces = mineWorkspaces(config)
        let mineEvery = PRBudget.mineInterval(workspaces: workspaces.count, locked: locked) * slow
        for workspace in workspaces {
            let since = now - (mineAt[workspace] ?? 0)
            guard since >= mineEvery || (opened && since > PRBudget.openRefresh) else { continue }
            guard await room(1) else { break }
            await fetchMine(workspace, me: uuid)
        }
        // 2. Each repository's review list.
        let interval = PRBudget.reviewInterval(repos: repos.count, mineWorkspaces: workspaces.count,
                                               pipelineRunning: myPipelineRunning, locked: locked) * slow
        for repo in repos {
            guard await client.hasToken(for: Self.lane), await Date().timeIntervalSince1970 >= client.pauseUntil(Self.lane) else { break }
            if let skip = skipUntil[repo.key], now < skip { continue }
            guard now - (reviewAt[repo.key] ?? 0) >= interval else { continue }
            guard await room(1) else { break }
            await fetchRepo(repo, me: uuid)
        }
        // 3. Details of what changed.
        await fetchDetails(me: uuid, slow: slow)
        // 4. Events, then the snapshot.
        derive(me: uuid)
        publish()
    }

    static let scopeStatus = SourceStatus(
        text: "needs read:pullrequest",
        help: "PRs need the read:pullrequest scope. Bitbucket API tokens cannot gain scopes: create a new one with read:repository, read:pipeline, read:pullrequest and read:user, and store it as \(BitbucketConfig.tokenService) (it replaces the current one; Pipelines keeps working).",
        isSetup: true)

    /// Within the lane's cap for `cost` more requests.
    private func room(_ cost: Int) async -> Bool {
        await client.count(Self.lane) + cost <= Self.lane.hourlyCap
    }

    /// The workspaces mine is read in: the configured one (or the most common), and the others
    /// too until the combined query is known to cover them.
    private func mineWorkspaces(_ config: BuildsConfig.Bitbucket) -> [String] {
        var counts: [String: Int] = [:]
        for repo in repos { counts[repo.workspace, default: 0] += 1 }
        let main = config.workspace ?? counts.max { $0.value < $1.value }?.key
        guard let main else { return [] }
        if combined == true { return [main] }
        return [main] + counts.keys.filter { $0 != main }.sorted()
    }

    // MARK: Reads

    private func fetchMine(_ workspace: String, me uuid: String) async {
        mineAt[workspace] = now
        guard let user = uuid.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-"))) else { return }
        let base = "\(BitbucketConfig.apiBase)/workspaces/\(workspace)/pullrequests/\(user)"
        var withSource = !noSource.contains("ws:\(workspace)")
        for _ in 0..<2 {
            let query = [("state", "OPEN"), ("pagelen", "50"), ("fields", PRParse.listFields(withSource: withSource))]
            guard let url = BuildHTTP.url(base, query), let (data, response) = await get(url, kind: "mine") else { return }
            if response.statusCode == 400, withSource, PRParse.isSourceError(data) {
                noSource.insert("ws:\(workspace)")
                withSource = false
                continue
            }
            if response.statusCode == 404 {
                status = SourceStatus(text: "PRs unavailable", help: "Bitbucket did not find the workspace pull-request list for \(workspace) (404).")
                noteBuildLog("bitbucket prs: 404 on the workspace list")
                return
            }
            guard response.statusCode == 200, let page = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
            var found: [String: PullRequest] = [:]
            for value in page["values"] as? [[String: Any]] ?? [] {
                guard let pr = PRParse.pullRequest(value, me: uuid, repo: nil) else { continue }
                found[pr.id] = pr
            }
            fromMine[workspace] = found
            // Mine that closed: gone from this list, so gone from the repositories' older
            // answers too (they are read only every 10 to 20 minutes).
            for (repoKey, list) in fromRepo where repoKey.hasPrefix("\(workspace)/") {
                fromRepo[repoKey] = list.filter { $0.value.role != .mine || found[$0.key] != nil }
            }
            covered.insert("ws:\(workspace)")
            clearTransientStatus()
            return
        }
    }

    private func fetchRepo(_ repo: BitbucketRepo, me uuid: String) async {
        reviewAt[repo.key] = now
        let base = "\(BitbucketConfig.apiBase)/repositories/\(repo.workspace)/\(repo.repo)/pullrequests"
        var withSource = !noSource.contains(repo.key)
        for _ in 0..<3 {
            let both = combined != false
            let filter = both
                ? "state=\"OPEN\" AND (author.uuid=\"\(uuid)\" OR reviewers.uuid=\"\(uuid)\")"
                : "state=\"OPEN\" AND reviewers.uuid=\"\(uuid)\""
            let query = [("q", filter), ("pagelen", "50"), ("fields", PRParse.listFields(withSource: withSource))]
            guard let url = BuildHTTP.url(base, query), let (data, response) = await get(url, kind: "review") else { return }
            switch response.statusCode {
            case 200:
                if both, combined == nil {
                    combined = true
                    noteBuildLog("bitbucket prs: the combined author-or-reviewer query works")
                }
                guard let page = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
                var found: [String: PullRequest] = [:]
                for value in page["values"] as? [[String: Any]] ?? [] {
                    guard let pr = PRParse.pullRequest(value, me: uuid, repo: repo) else { continue }
                    // Without the combined query this list holds only the ones I review.
                    if !both, pr.role == .mine { continue }
                    found[pr.id] = pr
                }
                fromRepo[repo.key] = found
                covered.insert(repo.key)
                clearTransientStatus()
                return
            case 400 where withSource && PRParse.isSourceError(data):
                noSource.insert(repo.key)
                withSource = false
            case 400 where both:
                combined = false
                noteBuildLog("bitbucket prs: the combined query was refused (400); reviewers only")
            case 403, 404:
                // No access to this repository (a scope 403 was handled in get): left for an hour.
                skipUntil[repo.key] = now + 3600
                noteBuildLog("bitbucket prs: \(response.statusCode) on a repository's list; skipped for an hour")
                return
            default:
                return
            }
        }
    }

    /// Statuses for a pull request whose updated_on moved (or a build of mine in progress, every
    /// 4 minutes); comments when comment_count moved. Mine first, newest first, a few a poll,
    /// and only while the lane is under its target (the cap is never passed).
    private func fetchDetails(me uuid: String, slow: Double) async {
        let now = self.now
        let prs = merged().sorted { ($0.role == .mine ? 0 : 1, -$0.updatedAt) < ($1.role == .mine ? 0 : 1, -$1.updatedAt) }
        var budget = PRBudget.detailsPerTick
        for pr in prs {
            guard budget > 0 else { break }
            var info = details[pr.id] ?? Details()
            let building = pr.role == .mine && (info.build?.state.isRunning ?? false)
            let wantsStatuses = info.statusesFor != pr.updatedOn || (building && now - info.statusesAt >= PRBudget.buildRecheck * slow)
            let wantsComments = pr.commentCount > 0 && info.commentsFor != pr.commentCount
            if pr.commentCount == 0 { info.comments = []; info.commentsFor = 0 }
            if wantsStatuses || wantsComments {
                let count = await client.count(Self.lane)
                guard Double(count) < Self.lane.hourlyTarget, count + (wantsStatuses ? 1 : 0) + (wantsComments ? 1 : 0) <= Self.lane.hourlyCap else { break }
            }
            let base = "\(BitbucketConfig.apiBase)/repositories/\(pr.ref.workspace)/\(pr.ref.repo)/pullrequests/\(pr.ref.id)"
            if wantsStatuses, let url = BuildHTTP.url("\(base)/statuses", [("pagelen", "20"), ("fields", PRParse.statusFields)]) {
                budget -= 1
                info.statusesAt = now
                if let (data, response) = await get(url, kind: "statuses"), response.statusCode == 200,
                   let page = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                    info.build = PRParse.build(page)
                    info.statusesFor = pr.updatedOn
                }
            }
            if wantsComments, let url = BuildHTTP.url("\(base)/comments", [("sort", "-updated_on"), ("pagelen", "10"), ("fields", PRParse.commentFields)]) {
                budget -= 1
                if let (data, response) = await get(url, kind: "comments"), response.statusCode == 200,
                   let page = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                    info.comments = PRParse.comments(page)
                    info.commentsFor = pr.commentCount
                }
            }
            details[pr.id] = info
        }
    }

    /// Merge checks for one pull request, read now (never on a schedule). Nil when it is not
    /// known or the read failed.
    func mergeability(for key: String) async -> PRMergeability? {
        guard let pr = merged().first(where: { $0.id == key }), await room(1) else { return nil }
        let base = "\(BitbucketConfig.apiBase)/repositories/\(pr.ref.workspace)/\(pr.ref.repo)/pullrequests/\(pr.ref.id)/mergeability/checks"
        guard let url = URL(string: base), let (data, response) = await get(url, kind: "merge"), response.statusCode == 200,
              let page = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return PRParse.mergeability(page, now: now)
    }

    // MARK: Who I am

    /// My Bitbucket uuid: cached, else `/user` (needs read:user; tried once per token), else the
    /// account behind commits made with my git email (as Pipelines finds the token's owner).
    private func resolveMe() async {
        guard me == nil, now - meTriedAt > BuildPolling.history else { return }
        meTriedAt = now
        let defaults = UserDefaults.standard
        let useCache = !BitbucketConfig.isStubbed
        let identity = BitbucketConfig.gitIdentity(repos)
        if useCache {
            for key in ["bitbucketPRUser", "bitbucketOwner"] {
                guard let data = defaults.data(forKey: key), let cached = try? JSONDecoder().decode(BitbucketOwner.self, from: data),
                      cached.uuid != nil else { continue }
                // One found by an email that is no longer mine is looked up again.
                if cached.how.hasPrefix("commit email "), !identity.emails.contains(String(cached.how.dropFirst("commit email ".count))) { continue }
                me = cached
                return
            }
        }
        let fingerprint = await client.tokenFingerprint() ?? ""
        if !useCache || defaults.string(forKey: "bitbucketPRUserRefused") != fingerprint,
           let url = BuildHTTP.url("\(BitbucketConfig.apiBase)/user", [("fields", "uuid,display_name")]),
           let (data, response) = await get(url, kind: "owner", scopeIsLaneWide: false) {
            if response.statusCode == 200, let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let uuid = object["uuid"] as? String {
                return save(BitbucketOwner(uuid: uuid, name: object["display_name"] as? String, how: "the /user endpoint"))
            }
            if response.statusCode == 403, useCache { defaults.set(fingerprint, forKey: "bitbucketPRUserRefused") }
        }
        for repo in repos.prefix(3) where !identity.emails.isEmpty {
            guard let url = BuildHTTP.url("\(BitbucketConfig.apiBase)/repositories/\(repo.workspace)/\(repo.repo)/commits",
                                          [("pagelen", "50"), ("fields", "values.author.raw,values.author.user.uuid,values.author.user.display_name")]),
                  let (data, response) = await get(url, kind: "owner", scopeIsLaneWide: false), response.statusCode == 200,
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            for value in object["values"] as? [[String: Any]] ?? [] {
                let author = value["author"] as? [String: Any]
                let raw = (author?["raw"] as? String ?? "").lowercased()
                let user = author?["user"] as? [String: Any]
                guard let email = identity.emails.first(where: { raw.contains("<\($0)>") }), let uuid = user?["uuid"] as? String else { continue }
                return save(BitbucketOwner(uuid: uuid, name: user?["display_name"] as? String, how: "commit email \(email)"))
            }
        }
    }

    private func save(_ found: BitbucketOwner) {
        me = found
        if !BitbucketConfig.isStubbed, let data = try? JSONEncoder().encode(found) {
            UserDefaults.standard.set(data, forKey: "bitbucketPRUser")
        }
        noteBuildLog("bitbucket prs: my account found by \(found.how.hasPrefix("commit email") ? "commit email" : found.how)")
    }

    // MARK: Requests

    /// One request in the pull-request lane. A 403 naming a scope stops the lane quietly (when
    /// `scopeIsLaneWide`); a 401 or 429 sets this lane's status only.
    private func get(_ url: URL, kind: String, scopeIsLaneWide: Bool = true) async -> (Data, HTTPURLResponse)? {
        switch await client.get(url, lane: Self.lane, kind: kind) {
        case .noToken:
            return nil
        case .offline:
            status = SourceStatus(text: "offline", help: "Bitbucket did not answer; it is tried again on the next poll.")
            return nil
        case .unauthorized:
            status = SourceStatus(text: "token rejected", help: "Bitbucket refused the token in \(BitbucketConfig.tokenService). Pipelines says more.", isSetup: true)
            noteBuildLog("bitbucket prs: 401")
            return nil
        case .rateLimited(let wait):
            status = SourceStatus(text: "rate limited", help: "Bitbucket asked to slow down; pull requests wait \(Int(max(30, wait))) s, then run slower for 15 minutes.")
            noteBuildLog("bitbucket prs: 429, waiting \(Int(max(30, wait))) s")
            return nil
        case .response(let data, let http):
            if http.statusCode == 403, scopeIsLaneWide, PRParse.isScopeError(data) {
                status = Self.scopeStatus
                await client.markLacksScope(Self.lane)
                noteBuildLog("bitbucket prs: 403, the token lacks read:pullrequest")
                return nil
            }
            return (data, http)
        }
    }

    private func clearTransientStatus() {
        if status?.isSetup != true { status = nil }
        if status == Self.scopeStatus { status = nil }
    }

    // MARK: Merging, events, the snapshot

    /// Every pull request from the reads, one per key, the newer updated_on winning, with its
    /// details.
    private func merged() -> [PullRequest] {
        var all: [String: PullRequest] = [:]
        for source in Array(fromMine.values) + Array(fromRepo.values) {
            for (key, pr) in source where all[key].map({ $0.updatedOn < pr.updatedOn }) ?? true {
                all[key] = pr
            }
        }
        return all.values.map { pr in
            var pr = pr
            if let info = details[pr.id] {
                pr.build = info.build
                pr.recentComments = info.comments
            }
            return pr
        }
    }

    /// The events since the last poll, and the seen-state brought up to date (saved when it
    /// changed). With no seen-state file at the start, the first full look (mine and every
    /// repository read once) only records.
    private func derive(me uuid: String) {
        let now = self.now
        let silent = silentUntilCovered
        if silentUntilCovered {
            // Silent through the poll that completes the first full look, then not.
            let needed = Set(repos.map(\.key)).union(mineWorkspaces(reposConfig ?? BuildsConfig.Bitbucket(workspace: nil, repos: [], searchRoots: [])).map { "ws:\($0)" })
            if needed.isSubset(of: covered) { silentUntilCovered = false }
        }
        var events: [PREvent] = []
        for pr in merged() {
            let entry = seen[pr.id]
            let (found, next) = PREvents.derive(pr, entry: entry, me: uuid, now: now, silent: silent)
            events += found
            if next != entry {
                seen[pr.id] = next
                seenDirty = true
            }
        }
        let stale = seen.filter { now - $0.value.aliveAt > PREvents.forgetAfter }.keys
        for key in stale { seen[key] = nil; seenDirty = true }
        saveSeen()
        if !events.isEmpty { onEvents(events) }
    }

    private func saveSeen() {
        guard seenDirty else { return }
        seenDirty = false
        PRSeenStore.save(seen)
    }

    private func publish() {
        var prs = merged()
        if let uuid = me?.uuid {
            for index in prs.indices { prs[index].newComments = PREvents.newComments(prs[index], entry: seen[prs[index].id], me: uuid) }
        }
        prs.sort { $0.updatedAt > $1.updatedAt }
        let snapshot = PullRequestSnapshot(prs: prs, status: status, mineFetchedAt: mineAt.values.max() ?? 0,
                                           reviewFetchedAt: reviewAt.values.max() ?? 0, repoCount: repos.count, me: me,
                                           combinedQuery: combined)
        var compare = snapshot
        compare.mineFetchedAt = last.mineFetchedAt
        compare.reviewFetchedAt = last.reviewFetchedAt
        guard compare != last || !lastSent else { return }
        last = snapshot
        lastSent = true
        onChange(snapshot)
    }

    // MARK: Dev

    func debugCounts() async -> (RequestCount, Int) { await client.counts(Self.lane) }
    func debugMe() -> BitbucketOwner? { me }
    func debugCombined() -> Bool? { combined }
}
