import Foundation

// Bitbucket Pipelines runs, read over the REST API with a read-only token from the Keychain.
// One workspace request (the gate) every 2 minutes tells which repositories were pushed to; a
// pushed repository, and one with a running run, is read every 25 s (stretched to stay under
// ~360 requests an hour); every repository is swept every 5 minutes for what the gate cannot
// see (manual, scheduled and rerun pipelines), and opening the notch reads every unmuted one not
// read in the last minute. Lists and steps are asked with If-None-Match, so
// an unchanged answer is a 304 with no body. Backoff on 429, X-RateLimit-NearLimit, or our own
// count nearing the cap. Paused while the screen is locked with nothing running. Read only:
// nothing is ever started, stopped or rerun. The token, the ETags, the count and the backoff live
// in BitbucketClient (its Pipelines lane), shared with the pull-request lane.

struct BitbucketRepo: Codable, Hashable, Sendable {
    var workspace: String
    var repo: String
    /// The local clone it was found in, for reference.
    var path: String?

    var key: String { "\(workspace)/\(repo)" }
}

struct PipelineStep: Equatable, Sendable, Identifiable {
    var id: String
    var name: String
    var state: BuildState
    var startedAt: Double?
    var completedAt: Double?
    /// Skipped because an earlier step failed (result NOT_RUN).
    var notRun = false
    /// Started by a click (`trigger: manual`), and waiting for it now (PENDING, stage PAUSED).
    var isManual = false
    var waitsForClick = false
    /// Held by a deployment lock (PENDING, stage HALTED): the environment's name.
    var lockedOn: String?
    var isHalted = false
}

/// Why a paused or halted run is not moving.
enum PipelineWait: Equatable, Sendable {
    /// The next step runs only when someone clicks it.
    case manualStep(String?)
    /// A deployment environment is locked by another run.
    case deploymentLock(String?)

    var label: String {
        switch self {
        case .manualStep: return "Waiting for manual step"
        case .deploymentLock: return "Waiting for deployment lock"
        }
    }

    var detail: String {
        switch self {
        case .manualStep(let step): return step.map { "Waiting for manual step: \($0)" } ?? "Waiting for a manual step"
        case .deploymentLock(let env): return env.map { "Waiting for deployment lock: \($0)" } ?? "Waiting for a deployment lock"
        }
    }
}

struct PipelineRun: Equatable, Sendable, Identifiable {
    var uuid: String
    var ref: PipelineRef
    var state: BuildState
    /// PAUSED or HALTED while IN_PROGRESS.
    var stage: String?
    /// The branch: `target.ref_name`, or a pull request's source branch (`target.source`; a PR
    /// pipeline's ref_name is null).
    var branch: String?
    var pullRequest: Int?
    var destination: String?
    /// What started it, for the row: "custom: eas-preview", "tag".
    var selector: String?
    /// The selector as a key for the ETA: "pull-requests:**", "branches:main", "custom:deploy-stage".
    var selectorKey: String
    var trigger: String?
    var commit: String?
    /// Who it is for: the pushing account on a push or PR run (checked against the commit
    /// author), whoever clicked on a manual one, "Scheduled" or "Bitbucket Pipelines" otherwise.
    var creator: String?
    var creatorUUID: String?
    var createdAt: Double
    var completedAt: Double?
    var steps: [PipelineStep] = []
    /// The median time of recent successful runs of the same repo and selector.
    var usualDuration: Double?
    /// The running step's latest log line, while the notch is open.
    var logLine: String?

    var id: String { ref.key }
    var url: URL { BitbucketConfig.runURL(ref) }
    var failedStep: PipelineStep? { steps.first { $0.state == .failed } }
    var runningStep: PipelineStep? { steps.first { $0.state == .running } }
    /// Branch or pull request: a newer run on the same one supersedes a waiting run.
    var refKey: String { pullRequest.map { "pr:\($0)" } ?? "branch:\(branch ?? "?"):\(selectorKey)" }

    /// The last time anything moved: a step starting or ending, else its creation.
    var lastChangeAt: Double {
        steps.flatMap { [$0.startedAt, $0.completedAt] }.compactMap { $0 }.max().map { max($0, createdAt) } ?? createdAt
    }

    /// Paused or halted with no step change for two hours: shown as waiting, no fast poll.
    func isStale(now: Double) -> Bool { state == .paused && now - lastChangeAt > BuildPolling.stalePause }
    func needsFastPoll(now: Double) -> Bool { state.isRunning || (state == .paused && !isStale(now: now)) }

    var wait: PipelineWait? {
        guard state == .paused else { return nil }
        if stage == "HALTED" || steps.contains(where: \.isHalted) {
            return .deploymentLock(steps.first { $0.isHalted }?.lockedOn)
        }
        return .manualStep(steps.first { $0.waitsForClick }?.name)
    }

    static func parse(_ object: [String: Any], repo: BitbucketRepo) -> PipelineRun? {
        guard let uuid = object["uuid"] as? String, let number = object["build_number"] as? Int,
              let created = buildTime(object["created_on"]) else { return nil }
        let target = object["target"] as? [String: Any] ?? [:]
        let selector = target["selector"] as? [String: Any]
        let pr = (target["pullrequest"] as? [String: Any]) ?? (target["pull_request"] as? [String: Any])
        let type = selector?["type"] as? String
        let pattern = selector?["pattern"] as? String
        var selectorText: String?
        switch type {
        // A branch or pull request shows as its own chip already.
        case "custom": selectorText = "custom: \(pattern ?? "?")"
        case "tags": selectorText = "tag"
        case "branches", "pull-requests", "default", nil: selectorText = nil
        default: selectorText = type
        }
        let trigger = (object["trigger"] as? [String: Any])?["name"] as? String
        let creatorObject = object["creator"] as? [String: Any]
        var creator = creatorObject?["display_name"] as? String
        // A scheduled run's creator is a system user with a uuid and no name.
        if creator == nil { creator = trigger?.uppercased() == "SCHEDULE" ? "Scheduled" : "Bitbucket Pipelines" }
        let state = object["state"] as? [String: Any]
        return PipelineRun(
            uuid: uuid, ref: PipelineRef(workspace: repo.workspace, repo: repo.repo, number: number),
            state: Self.state(state),
            stage: ((state?["stage"] as? [String: Any])?["name"] as? String)?.uppercased(),
            branch: (target["ref_name"] as? String) ?? (target["source"] as? String),
            pullRequest: pr?["id"] as? Int, destination: target["destination"] as? String,
            selector: selectorText, selectorKey: "\(type ?? "default"):\(pattern ?? "")",
            trigger: trigger,
            commit: (target["commit"] as? [String: Any])?["hash"] as? String,
            creator: creator, creatorUUID: creatorObject?["uuid"] as? String,
            createdAt: created, completedAt: buildTime(object["completed_on"]))
    }

    /// PENDING, IN_PROGRESS (stage RUNNING, PAUSED or HALTED), COMPLETED with SUCCESSFUL, FAILED,
    /// ERROR, STOPPED or EXPIRED. FAILED and ERROR are failures.
    static func state(_ state: [String: Any]?) -> BuildState {
        let name = (state?["name"] as? String ?? "").uppercased()
        let stage = ((state?["stage"] as? [String: Any])?["name"] as? String ?? "").uppercased()
        let result = ((state?["result"] as? [String: Any])?["name"] as? String ?? "").uppercased()
        switch name {
        case "PENDING", "PARSING", "READY": return stage == "PAUSED" || stage == "HALTED" ? .paused : .queued
        case "IN_PROGRESS", "RUNNING": return stage == "PAUSED" || stage == "HALTED" ? .paused : stage == "PENDING" ? .queued : .running
        case "COMPLETED":
            switch result {
            case "SUCCESSFUL": return .succeeded
            case "FAILED", "ERROR": return .failed
            default: return .canceled
            }
        default: return .queued
        }
    }

    static func parseStep(_ object: [String: Any]) -> PipelineStep? {
        guard let uuid = object["uuid"] as? String else { return nil }
        let state = object["state"] as? [String: Any]
        let result = ((state?["result"] as? [String: Any])?["name"] as? String ?? "").uppercased()
        let stage = state?["stage"] as? [String: Any]
        let stageName = (stage?["name"] as? String ?? "").uppercased()
        let manual = ((object["trigger"] as? [String: Any])?["type"] as? String ?? "").contains("manual")
        let environment = ((stage?["reason"] as? [String: Any])?["environment"] as? [String: Any])?["name"] as? String
        return PipelineStep(id: uuid, name: object["name"] as? String ?? "Step", state: Self.state(state),
                            startedAt: buildTime(object["started_on"]), completedAt: buildTime(object["completed_on"]),
                            notRun: result == "NOT_RUN", isManual: manual,
                            waitsForClick: stageName == "PAUSED", lockedOn: environment, isHalted: stageName == "HALTED")
    }
}

/// Whose runs are "mine": the token's owner. `GET /2.0/user` needs a scope the read-only token
/// lacks (read:user), so the owner is found from the commits: the Bitbucket user that commits with
/// the git email of the local clones is the account the token belongs to. Last resort: the git
/// user name against the creator's display name.
struct BitbucketOwner: Equatable, Sendable, Codable {
    var uuid: String?
    var name: String?
    /// How it was found, for ⓘ: "the /user endpoint", "commit email you@…", "display name".
    var how: String

    func owns(_ run: PipelineRun) -> Bool {
        if let uuid { return run.creatorUUID == uuid }
        if let name { return run.creator == name }
        return false
    }
}

/// Requests in the last hour, by kind, for ⓘ.
struct RequestCount: Equatable, Sendable {
    var total = 0
    var byKind: [String: Int] = [:]

    var summary: String {
        let order = ["gate", "list", "run", "steps", "log", "history", "owner", "report"]
        let parts = order.compactMap { kind in byKind[kind].flatMap { $0 > 0 ? "\(kind) \($0)" : nil } }
        return "\(total) in the last hour" + (parts.isEmpty ? "" : " (" + parts.joined(separator: ", ") + ")")
    }
}

struct BitbucketSnapshot: Equatable, Sendable {
    var runs: [PipelineRun] = []
    var status: SourceStatus?
    var fetchedAt: Double = 0
    var repoCount = 0
    var tokenExpiresAt: Double?
    var requests = RequestCount()
    var owner: BitbucketOwner?
    /// How many 304s (unchanged answers) in the last hour.
    var notModified = 0

    var requestsLastHour: Int { requests.total }
}

enum BitbucketConfig {
    /// The Keychain item (generic password) holding the API token.
    static let tokenService = "ai-notch.bitbucket"
    /// Atlassian API tokens are 192 characters; the interactive `security … -w` prompt keeps 128.
    static let truncatedLength = 128
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// Dev only: a stub server and its token, for tests without the real API.
    static var apiBase: String { ProcessInfo.processInfo.environment["CLAUDE_NOTCH_BITBUCKET_API"] ?? "https://api.bitbucket.org/2.0" }
    static var isStubbed: Bool { ProcessInfo.processInfo.environment["CLAUDE_NOTCH_BITBUCKET_API"] != nil }

    /// A run's page: `/pipelines/results/<n>` is the route bitbucket.org serves (checked on a
    /// public repository); the older `/addon/pipelines/home#!/results/<n>` now redirects to the
    /// list. Step links are left out (their ids change on rerun).
    static func runURL(_ ref: PipelineRef) -> URL {
        URL(string: "https://bitbucket.org/\(ref.workspace)/\(ref.repo)/pipelines/results/\(ref.number)")
            ?? URL(string: "https://bitbucket.org/\(ref.workspace)/\(ref.repo)/pipelines")!
    }

    /// builds.json's repositories, with the clones found under its search roots; none while
    /// it has no `bitbucket` part. Any thread.
    static func loadRepos(scan: Bool = true) -> [BitbucketRepo] {
        guard let bitbucket = BuildsConfig.current?.bitbucket else { return [] }
        return BuildsConfig.bitbucketRepos(bitbucket, scan: scan)
    }

    private static var cached: (at: Double, repos: [BitbucketRepo])?

    /// The list for the panel's menu, read at most once a minute, without scanning folders on
    /// the main thread (the clones the poller last found).
    @MainActor static func loadReposCached() -> [BitbucketRepo] {
        let now = Date().timeIntervalSince1970
        if let cached, now - cached.at < 60 { return cached.repos }
        let repos = loadRepos(scan: false)
        cached = (now, repos)
        return repos
    }

    /// Whose commits are mine: builds.json's `me.emails` (and `me.name`) when set; else the git
    /// identity of the local clones (`[user]` in their `.git/config`) and the global one
    /// (`~/.gitconfig`, `~/.config/git/config`): the emails and the name to find the token's
    /// owner by.
    static func gitIdentity(_ repos: [BitbucketRepo]) -> (emails: [String], name: String?) {
        let config = BuildsConfig.current
        if let config, !config.emails.isEmpty { return (config.emails, config.name) }
        var emails: [String] = []
        var name = config?.name
        let files = repos.compactMap { $0.path.map { URL(fileURLWithPath: $0).appendingPathComponent(".git/config") } }
            + [home.appendingPathComponent(".gitconfig"), home.appendingPathComponent(".config/git/config")]
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            var inUser = false
            for raw in text.split(separator: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("[") { inUser = line.lowercased().hasPrefix("[user"); continue }
                guard inUser, let eq = line.firstIndex(of: "=") else { continue }
                let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                if key == "email", !value.isEmpty, !emails.contains(value.lowercased()) { emails.append(value.lowercased()) }
                if key == "name", name == nil, !value.isEmpty { name = value }
            }
        }
        return (emails, name)
    }

    static let setupHelp = "Not connected. Create an Atlassian API token with the scopes read:repository, read:pipeline, read:pullrequest and read:user (Setup lists the steps), and store it in the Keychain as \(tokenService)."
    /// The command Setup shows: the token from the clipboard, which is then cleared. The
    /// interactive `-w` prompt silently keeps only 128 characters, and these tokens are 192.
    static let saveCommand = "security add-generic-password -U -s \(tokenService) -a api-token -j \"expires YYYY-MM-DD\" -w \"$(pbpaste)\" && pbcopy < /dev/null"
}

/// Follows a finished step's log redirect (307 to storage) without the token, keeping the range
/// and the ETag check.
private final class RedirectWithoutToken: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        var next = request
        if request.url?.host != task.originalRequest?.url?.host { next.setValue(nil, forHTTPHeaderField: "Authorization") }
        for header in ["Range", "If-None-Match"] {
            if let value = task.originalRequest?.value(forHTTPHeaderField: header) { next.setValue(value, forHTTPHeaderField: header) }
        }
        completionHandler(next)
    }
}

/// No cache, no cookies: nothing of a response stays on disk.
enum BuildHTTP {
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.timeoutIntervalForRequest = 30
        config.httpAdditionalHeaders = ["User-Agent": "AI-Notch"]
        return URLSession(configuration: config, delegate: RedirectWithoutToken(), delegateQueue: nil)
    }()

    /// A URL with its query encoded strictly: `+` (which Bitbucket reads as a space, or as "add
    /// this field" in `fields=`) and the quotes and braces of a `q=` filter included.
    static func url(_ base: String, _ query: [(String, String)]) -> URL? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=?\"{}<> ")
        let encoded = query.map { "\($0)=\($1.addingPercentEncoding(withAllowedCharacters: allowed) ?? $1)" }.joined(separator: "&")
        return URL(string: encoded.isEmpty ? base : "\(base)?\(encoded)")
    }

    /// A `next` link, with what Bitbucket drops from it (`fields`, and `sort` on some lists) put back.
    static func next(_ link: String, keeping query: [(String, String)]) -> URL? {
        guard var components = URLComponents(string: link) else { return nil }
        var items = components.queryItems ?? []
        for (name, value) in query where !items.contains(where: { $0.name == name }) {
            items.append(URLQueryItem(name: name, value: value))
        }
        components.queryItems = items
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }
}

/// Polls on the cooperative pool (never the main thread) and hands a snapshot to `onChange` only
/// when it changed.
actor BitbucketSource {
    private let onChange: @Sendable (BitbucketSnapshot) -> Void
    private var repos: [BitbucketRepo] = []
    private var reposReadAt: Double = 0
    private var reposConfig: BuildsConfig.Bitbucket?
    /// Every run we know, by repository and uuid: the newest page merged into what came before.
    private var known: [String: [String: PipelineRun]] = [:]
    private var listedAt: [String: Double] = [:]
    private var sweptAt: [String: Double] = [:]
    private var hotUntil: [String: Double] = [:]
    private var skipUntil: [String: Double] = [:]
    /// The gate: each repository's updated_on as last seen.
    private var updatedOn: [String: String] = [:]
    private var gateAt: Double = 0
    private var gateReady = false
    /// ETA history: when each repository's was read, and the medians by selector.
    private var historyAt: [String: Double] = [:]
    private var usual: [String: [String: Double]] = [:]
    /// Steps: when each run's were read, and for a failed run, that they were.
    private var stepsAt: [String: Double] = [:]
    private var stepsRead: Set<String> = []
    /// When each waiting run off the list's page was last read by itself.
    private var singleAt: [String: Double] = [:]
    private var logAt: [String: Double] = [:]
    /// The token, the ETags, the request count and the backoff: the client's Pipelines lane.
    private let client: BitbucketClient
    private static let lane = BitbucketLane.pipelines
    private var owner: BitbucketOwner?
    private var ownerTriedAt: Double = -.infinity
    private var status: SourceStatus?
    private var wantsNow = false
    /// The notch opened: every unmuted repository not listed in the last minute is listed.
    private var openSweep = false
    /// Repositories muted in the panel ("ws/repo"): left out of the sweep on opening.
    private var muted: Set<String> = []
    private var panelOpen = false
    private var last = BitbucketSnapshot()
    private var loop: Task<Void, Never>?
    private var countLoggedAt: Double = 0

    /// The hard ceiling, and what the schedule aims for. Bitbucket allows 1,000 an hour for
    /// these endpoints; this stays well under it.
    static let hourlyCap = BitbucketLane.pipelines.hourlyCap
    static let hourlyTarget: Double = BitbucketLane.pipelines.hourlyTarget

    init(client: BitbucketClient = .shared, onChange: @escaping @Sendable (BitbucketSnapshot) -> Void) {
        self.client = client
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

    /// The notch opened: the gate runs now if older than a minute, every unmuted repository not
    /// listed in the last minute is listed (a pipeline started by hand moves no updated_on), and
    /// a missing token is looked for. While it is open, a running step's last log line is read too.
    func refreshSoon() {
        wantsNow = true
        openSweep = true
    }

    func setPanelOpen(_ open: Bool) {
        panelOpen = open
        if open {
            wantsNow = true
            openSweep = true
        }
    }

    func setMuted(_ keys: Set<String>) {
        muted = keys
    }

    /// Setup's "Check Again": reads the Keychain at once.
    func recheckToken() async {
        await client.recheck()
        wantsNow = true
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
        // No `bitbucket` in builds.json: nothing to read, not even the Keychain.
        guard config != nil else {
            status = nil
            wantsNow = false
            return await publish()
        }
        if await !client.hasToken(for: Self.lane) {
            // After a rejection the Keychain is read on the next poll, then every minute, so a
            // re-saved token is picked up by itself; with none at all, every 10 minutes.
            switch await client.loadToken(for: Self.lane, urgent: wantsNow) {
            case .found: status = nil
            case .missing(let afterRejection): if !afterRejection { status = nil }
            case .notDue, .stillRejected: break
            }
        }
        guard await client.hasToken(for: Self.lane) else {
            if status == nil { status = SourceStatus(text: "not connected", help: BitbucketConfig.setupHelp, isSetup: true) }
            wantsNow = false
            return await publish()
        }
        guard !repos.isEmpty else {
            status = SourceStatus(text: "no repositories", help: "No repositories in \(BuildsConfig.displayPath): list them under bitbucket.repos, or give bitbucket.searchRoots to find the local clones with a bitbucket-pipelines.yml.", isSetup: true)
            return await publish()
        }
        guard await now >= client.pauseUntil(Self.lane) else { return await publish() }
        let anyFast = known.values.contains { $0.values.contains { $0.needsFastPoll(now: now) } }
        if BuildPolling.isScreenLocked && !anyFast { return }

        // Early backoff on our own count, before Bitbucket has to say anything.
        await client.backOffIfNearCap(Self.lane)
        await resolveOwner()

        let early = wantsNow
        wantsNow = false
        let opened = openSweep
        openSweep = false
        // 1. The gate: which repositories were pushed to.
        let gateSlow = await slow()
        let gateDue = now - gateAt >= BuildPolling.gate * gateSlow || (early && now - gateAt > BuildPolling.openRefresh)
        if gateDue { await gate() }
        // 2. Each repository that is due.
        let interval = await activeInterval()
        var swept: [String] = [], openListed: [String] = [], openSkipped = 0
        for repo in repos {
            guard await client.hasToken(for: Self.lane), await Date().timeIntervalSince1970 >= client.pauseUntil(Self.lane) else { break }
            if let skip = skipUntil[repo.key], now < skip { continue }
            let runs = (known[repo.key] ?? [:]).values
            let fast = runs.contains { $0.needsFastPoll(now: now) }
            let hot = (hotUntil[repo.key] ?? 0) > now
            let first = listedAt[repo.key] == nil
            let slow = await slow()
            let sweepDue = now - (sweptAt[repo.key] ?? 0) >= BuildPolling.sweep * slow
            let since = now - (listedAt[repo.key] ?? 0)
            // Opening the notch lists every unmuted repository not listed for a minute (longer
            // while slowed down), so repeated opening costs nothing more.
            let openDue = opened && !muted.contains(repo.key) && since >= BuildPolling.openRefresh * slow
            if opened && !openDue && !muted.contains(repo.key) { openSkipped += 1 }
            guard first || sweepDue || openDue || ((fast || hot) && since >= interval) else { continue }
            guard await requestCount() + 1 <= Self.hourlyCap else { break }
            if first || sweepDue { swept.append(repo.repo) } else if openDue && !((fast || hot) && since >= interval) { openListed.append(repo.repo) }
            await poll(repo, pagelen: first ? 10 : (fast || hot) ? 5 : 2, sweep: first || sweepDue)
        }
        if !swept.isEmpty { timing("bitbucket sweep: \(swept.count) repos (\(swept.joined(separator: ", ")))") }
        if opened {
            let slow = await slow()
            timing("bitbucket open: listed \(openListed.count), skipped \(openSkipped) read <\(Int(BuildPolling.openRefresh * slow)) s ago, gate \(gateDue ? "read" : "skipped")")
        }
        await publish()
        await logCountIfDue()
    }

    /// Dev: with CLAUDE_NOTCH_BUILD_TIMING, a line on stderr.
    private func timing(_ line: String) {
        guard ProcessInfo.processInfo.environment["CLAUDE_NOTCH_BUILD_TIMING"] != nil else { return }
        FileHandle.standardError.write(Data("\(line)\n".utf8))
    }

    /// 1, or 2 or 3 while the lane backs off.
    private func slow() async -> Double { await client.slow(Self.lane) }

    /// The lane's requests in the last hour.
    private func requestCount() async -> Int { await client.count(Self.lane) }

    /// 25 s for a repository with a running run, stretched so the busy polling and the idle
    /// gate and sweep together stay near the hourly target. A busy repository's sweep rides on
    /// its busy polls, so only the idle ones count toward the sweep's cost.
    private func activeInterval() async -> Double {
        var activeCost = 0.0
        var activeRepos = 0
        let now = self.now
        for repo in repos {
            let fast = known[repo.key]?.values.filter { $0.needsFastPoll(now: now) }.count ?? 0
            let hot = (hotUntil[repo.key] ?? 0) > now
            if fast > 0 || hot {
                // The list, each fast run's steps, and a log line while the notch is open.
                activeCost += 1 + Double(fast) * (panelOpen ? 2 : 1)
                activeRepos += 1
            }
        }
        guard activeCost > 0 else { return BuildPolling.busy }
        let idleCost = 3600 / BuildPolling.gate + Double(repos.count - activeRepos) * 3600 / BuildPolling.sweep
        let room = max(60, Self.hourlyTarget - idleCost)
        let slow = await slow()
        return max(BuildPolling.busy, 3600 * activeCost / room) * slow
    }

    // MARK: The gate

    /// One request for every repository: `updated_on` newer than the newest one seen. A push
    /// moves it some seconds before the push's pipeline exists, so a moved repository is read at
    /// the busy pace for a few minutes. Pipelines themselves (created, finished, manual,
    /// scheduled) do not move it; the sweep and the active polling cover those.
    private func gate() async {
        gateAt = now
        var byWorkspace: [String: [BitbucketRepo]] = [:]
        for repo in repos { byWorkspace[repo.workspace, default: []].append(repo) }
        for (workspace, list) in byWorkspace {
            let keys = list.map(\.key)
            let since = keys.compactMap { updatedOn[$0] }.max()
                ?? ISO8601DateFormatter().string(from: Date(timeIntervalSinceNow: -86_400))
            let slugs = list.map { "slug=\"\($0.repo)\"" }.joined(separator: " OR ")
            let query = [("q", "updated_on>\"\(since)\" AND (\(slugs))"), ("fields", "size,values.slug,values.updated_on"), ("pagelen", "100")]
            guard let url = BuildHTTP.url("\(BitbucketConfig.apiBase)/repositories/\(workspace)", query),
                  let (data, response) = await get(url, kind: "gate"), response.statusCode == 200,
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let values = object["values"] as? [[String: Any]] else { continue }
            for value in values {
                guard let slug = value["slug"] as? String, let updated = value["updated_on"] as? String else { continue }
                let key = "\(workspace)/\(slug)"
                if gateReady, updatedOn[key] != updated {
                    hotUntil[key] = now + BuildPolling.hot
                    listedAt[key] = 0
                }
                updatedOn[key] = updated
            }
        }
        gateReady = true
    }

    // MARK: One repository

    private static let runFields = [
        "uuid", "build_number", "created_on", "completed_on", "state.name", "state.stage.name", "state.result.name",
        "target.ref_name", "target.source", "target.destination", "target.pullrequest.id", "target.selector.type",
        "target.selector.pattern", "target.commit.hash", "trigger.name", "creator.uuid", "creator.display_name",
    ]

    private static let stepFields = [
        "uuid", "name", "started_on", "completed_on", "state.name", "state.result.name", "state.stage.name",
        "state.stage.reason.type", "state.stage.reason.environment.name", "trigger.type",
    ]

    private func base(_ repo: BitbucketRepo) -> String {
        "\(BitbucketConfig.apiBase)/repositories/\(repo.workspace)/\(repo.repo)/pipelines"
    }

    private func poll(_ repo: BitbucketRepo, pagelen: Int, sweep: Bool) async {
        let now = self.now
        listedAt[repo.key] = now
        if sweep { sweptAt[repo.key] = now }
        guard var page = await list(repo, pagelen: pagelen) else { return }
        var runs = known[repo.key] ?? [:]
        // A small page that is all new may have missed some: read a full one.
        if pagelen < 10, page.count == pagelen, page.allSatisfy({ runs[$0.uuid] == nil }), !runs.isEmpty,
           let full = await list(repo, pagelen: 10) {
            page = full
        }
        var changed: Set<String> = []
        for var run in page {
            let before = runs[run.uuid]
            run.steps = before?.steps ?? []
            run.logLine = before?.logLine
            if before == nil || before?.state != run.state || before?.stage != run.stage || before?.completedAt != run.completedAt {
                changed.insert(run.uuid)
            }
            runs[run.uuid] = run
        }
        // Runs not on this page that still matter: a running or waiting one is read by itself
        // (a running one on each poll, a stale waiting one on a sweep at most every 15 minutes).
        let onPage = Set(page.map(\.uuid))
        for (uuid, run) in runs where !onPage.contains(uuid) && run.state.isActive {
            let fast = run.needsFastPoll(now: now)
            let slow = await slow()
            guard fast || (sweep && now - (singleAt[uuid] ?? 0) >= BuildPolling.staleReread * slow),
                  !superseded(run, in: runs) || fast else { continue }
            singleAt[uuid] = now
            guard await requestCount() + 1 <= Self.hourlyCap, let fresh = await single(repo, uuid: uuid) else { continue }
            var updated = fresh
            updated.steps = run.steps
            updated.logLine = run.logLine
            if updated.state != run.state || updated.stage != run.stage { changed.insert(uuid) }
            runs[uuid] = updated
        }
        // Steps: every poll while a run moves (unchanged ones answer 304), once for a new waiting
        // run (to know since when) and again only when its state changes, and once for a failure.
        for (uuid, run) in runs {
            let wants = run.needsFastPoll(now: now)
                || (run.state == .paused && (stepsAt[uuid] == nil || changed.contains(uuid)))
                || (run.state == .failed && !stepsRead.contains(uuid) && now - (run.completedAt ?? now) < 6 * 3600)
                || (changed.contains(uuid) && run.state.isFinished && stepsAt[uuid] != nil)
            guard wants, await requestCount() + 1 <= Self.hourlyCap, let steps = await fetchSteps(repo, uuid: uuid) else { continue }
            runs[uuid]?.steps = steps
            stepsAt[uuid] = now
            if run.state.isFinished { stepsRead.insert(uuid) }
        }
        // While the notch is open: the running step's last log line.
        if panelOpen {
            for (uuid, run) in runs where run.state == .running {
                guard let step = run.runningStep, now - (logAt[uuid] ?? 0) >= BuildPolling.busy,
                      await requestCount() + 1 <= Self.hourlyCap else { continue }
                logAt[uuid] = now
                if let line = await liveLogLine(repo, run: uuid, step: step.id) { runs[uuid]?.logLine = line }
            }
        }
        for (uuid, run) in runs where run.state != .running && run.logLine != nil { runs[uuid]?.logLine = nil }
        known[repo.key] = prune(runs, now: now)
        if singleAt.count > 200 { singleAt = singleAt.filter { now - $0.value < 86_400 } }
        // ETA history, hourly while something runs here.
        if runs.values.contains(where: { $0.needsFastPoll(now: now) }), now - (historyAt[repo.key] ?? 0) > BuildPolling.history {
            await fetchHistory(repo)
        }
        if status?.isSetup != true { status = nil }
    }

    /// A newer run on the same branch or pull request makes a waiting one moot.
    private func superseded(_ run: PipelineRun, in runs: [String: PipelineRun]) -> Bool {
        runs.values.contains { $0.uuid != run.uuid && $0.refKey == run.refKey && $0.createdAt > run.createdAt }
    }

    /// Keeps what can still show: running and waiting runs, and the last two days' others, at
    /// most 25 per repository.
    private func prune(_ runs: [String: PipelineRun], now: Double) -> [String: PipelineRun] {
        let kept = runs.values.filter { run in
            run.needsFastPoll(now: now)
                || (run.state == .paused && now - run.createdAt < 7 * 86_400 && !superseded(run, in: runs))
                || now - run.createdAt < 2 * 86_400
        }
        let newest = kept.sorted { $0.createdAt > $1.createdAt }.prefix(25)
        return Dictionary(newest.map { ($0.uuid, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private func list(_ repo: BitbucketRepo, pagelen: Int) async -> [PipelineRun]? {
        let query = [("sort", "-created_on"), ("pagelen", "\(pagelen)"), ("fields", "values." + Self.runFields.joined(separator: ",values."))]
        guard let url = BuildHTTP.url("\(base(repo))/", query), let (data, response) = await get(url, kind: "list") else { return nil }
        if response.statusCode == 404 {
            // Renamed or gone: left alone for an hour.
            skipUntil[repo.key] = now + 3600
            noteBuildLog("bitbucket: \(repo.key) not found (404)")
            return nil
        }
        guard response.statusCode == 200,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let values = object["values"] as? [[String: Any]] else { return nil }
        return values.compactMap { PipelineRun.parse($0, repo: repo) }
    }

    private func single(_ repo: BitbucketRepo, uuid: String) async -> PipelineRun? {
        guard let id = uuid.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = BuildHTTP.url("\(base(repo))/\(id)", [("fields", Self.runFields.joined(separator: ","))]),
              let (data, response) = await get(url, kind: "run"), response.statusCode == 200,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return PipelineRun.parse(object, repo: repo)
    }

    private func fetchSteps(_ repo: BitbucketRepo, uuid: String) async -> [PipelineStep]? {
        guard let id = uuid.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = BuildHTTP.url("\(base(repo))/\(id)/steps/", [("pagelen", "100"), ("fields", "values." + Self.stepFields.joined(separator: ",values."))]),
              let (data, response) = await get(url, kind: "steps"), response.statusCode == 200,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let values = object["values"] as? [[String: Any]] else { return nil }
        return values.compactMap(PipelineRun.parseStep)
    }

    /// The median time (created to completed, from the timestamps: build seconds add up
    /// parallel steps) of the last ten successful runs per selector, from one page of the
    /// latest 40 successful runs. `status=` takes one value per parameter (PASSED here).
    private func fetchHistory(_ repo: BitbucketRepo) async {
        historyAt[repo.key] = now
        let query = [("sort", "-created_on"), ("pagelen", "40"), ("status", "PASSED"),
                     ("fields", "values.created_on,values.completed_on,values.target.selector.type,values.target.selector.pattern")]
        guard let url = BuildHTTP.url("\(base(repo))/", query), let (data, response) = await get(url, kind: "history"),
              response.statusCode == 200,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let values = object["values"] as? [[String: Any]] else { return }
        var durations: [String: [Double]] = [:]
        for value in values {
            guard let created = buildTime(value["created_on"]), let completed = buildTime(value["completed_on"]) else { continue }
            let selector = (value["target"] as? [String: Any])?["selector"] as? [String: Any]
            let key = "\(selector?["type"] as? String ?? "default"):\(selector?["pattern"] as? String ?? "")"
            if durations[key, default: []].count < 10 { durations[key, default: []].append(completed - created) }
        }
        usual[repo.key] = durations.compactMapValues(median)
    }

    /// The last non-empty line of a running step's log: a ranged request for its last 4 KB,
    /// with If-None-Match, so an unchanged log costs a 304 and no body.
    private func liveLogLine(_ repo: BitbucketRepo, run: String, step: String) async -> String? {
        guard let runId = run.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let stepId = step.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "\(base(repo))/\(runId)/steps/\(stepId)/log"),
              let (data, response) = await get(url, kind: "log", range: "bytes=-4096", accept: "application/octet-stream"),
              response.statusCode == 200 || response.statusCode == 206 else { return nil }
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").map(plainLogLine)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let last = lines.last else { return nil }
        let masked = Redact.mask(last)
        return masked.count > 140 ? String(masked.prefix(139)) + "…" : masked
    }

    // MARK: The token's owner

    private func resolveOwner() async {
        guard owner == nil, now - ownerTriedAt > BuildPolling.history else { return }
        ownerTriedAt = now
        let defaults = UserDefaults.standard
        let identity = BitbucketConfig.gitIdentity(repos)
        // A cached owner found by an email that is no longer mine is looked up again.
        if let data = defaults.data(forKey: "bitbucketOwner"), let cached = try? JSONDecoder().decode(BitbucketOwner.self, from: data), cached.uuid != nil,
           !cached.how.hasPrefix("commit email ") || identity.emails.contains(String(cached.how.dropFirst("commit email ".count))) {
            owner = cached
            return
        }
        // 1. The user endpoint, which needs read:user: tried once, remembered when refused.
        if !defaults.bool(forKey: "bitbucketUserEndpointRefused"),
           let url = BuildHTTP.url("\(BitbucketConfig.apiBase)/user", [("fields", "uuid,display_name")]),
           let (data, response) = await get(url, kind: "owner") {
            if response.statusCode == 200, let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let uuid = object["uuid"] as? String {
                save(BitbucketOwner(uuid: uuid, name: object["display_name"] as? String, how: "the /user endpoint"))
                return
            }
            if response.statusCode == 403 { defaults.set(true, forKey: "bitbucketUserEndpointRefused") }
        }
        // 2. The Bitbucket user behind commits made with my git email.
        if !identity.emails.isEmpty {
            for repo in repos.prefix(3) {
                guard let url = BuildHTTP.url("\(BitbucketConfig.apiBase)/repositories/\(repo.workspace)/\(repo.repo)/commits",
                                              [("pagelen", "50"), ("fields", "values.author.raw,values.author.user.uuid,values.author.user.display_name")]),
                      let (data, response) = await get(url, kind: "owner"), response.statusCode == 200,
                      let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let values = object["values"] as? [[String: Any]] else { continue }
                for value in values {
                    let author = value["author"] as? [String: Any]
                    let raw = (author?["raw"] as? String ?? "").lowercased()
                    let user = author?["user"] as? [String: Any]
                    guard let email = identity.emails.first(where: { raw.contains("<\($0)>") }), let uuid = user?["uuid"] as? String else { continue }
                    save(BitbucketOwner(uuid: uuid, name: user?["display_name"] as? String, how: "commit email \(email)"))
                    return
                }
            }
        }
        // 3. The git user name against the creator's display name.
        if let name = identity.name {
            owner = BitbucketOwner(uuid: nil, name: name, how: "display name")
            noteBuildLog("bitbucket: owner matched by display name only")
        }
    }

    private func save(_ found: BitbucketOwner) {
        owner = found
        if let data = try? JSONEncoder().encode(found) { UserDefaults.standard.set(data, forKey: "bitbucketOwner") }
        noteBuildLog("bitbucket: token owner found by \(found.how.hasPrefix("commit email") ? "commit email" : found.how)")
    }

    // MARK: Requests

    /// One request through the client's Pipelines lane. The client handles the token, the ETag
    /// (a 304 returns the last answer's body), the count and the backoff; this sets what the
    /// panel says: offline, a rejected or truncated token (401), a missing scope (403 on a list:
    /// the lane stops until another token is stored) and a 429.
    private func get(_ url: URL, kind: String, range: String? = nil, accept: String = "application/json") async -> (Data, HTTPURLResponse)? {
        switch await client.get(url, lane: Self.lane, kind: kind, range: range, accept: accept) {
        case .noToken:
            return nil
        case .offline:
            status = SourceStatus(text: "offline", help: "Bitbucket did not answer; it is tried again on the next poll.")
            return nil
        case .unauthorized(let truncated):
            status = truncated
                ? SourceStatus(text: "token looks truncated", help: "Bitbucket refused the token in \(BitbucketConfig.tokenService), and it is exactly \(BitbucketConfig.truncatedLength) characters: the interactive `security … -w` prompt cuts input there, and Atlassian tokens are 192. Copy the token and re-save it with:\n\(BitbucketConfig.saveCommand)", isSetup: true)
                : SourceStatus(text: "token rejected", help: "Bitbucket refused the token in \(BitbucketConfig.tokenService) (expired or revoked). Store a new one (Setup lists the steps); it is picked up within a minute.", isSetup: true)
            noteBuildLog("bitbucket: 401, token rejected\(truncated ? " (128 characters: looks truncated)" : "")")
            return nil
        case .rateLimited(let wait):
            status = SourceStatus(text: "rate limited", help: "Bitbucket asked to slow down; polling waits \(Int(max(30, wait))) s, then runs at a slower pace for 15 minutes.")
            noteBuildLog("bitbucket: 429, waiting \(Int(max(30, wait))) s")
            return nil
        case .response(let data, let http):
            if http.statusCode == 403, kind == "list" || kind == "gate" {
                status = SourceStatus(text: "needs read:pipeline", help: "The token in \(BitbucketConfig.tokenService) works but lacks a scope. Create one with read:repository, read:pipeline, read:pullrequest and read:user.", isSetup: true)
                await client.markLacksScope(Self.lane)
                noteBuildLog("bitbucket: 403 on \(url.path)")
                return nil
            }
            return (data, http)
        }
    }

    private func counts() async -> (RequestCount, Int) {
        await client.counts(Self.lane)
    }

    /// Dev: with CLAUDE_NOTCH_BUILD_TIMING, the rolling count every 5 minutes on stderr.
    private func logCountIfDue() async {
        guard ProcessInfo.processInfo.environment["CLAUDE_NOTCH_BUILD_TIMING"] != nil, now - countLoggedAt >= 300 else { return }
        countLoggedAt = now
        let (count, notModified) = await counts()
        FileHandle.standardError.write(Data("bitbucket requests: \(count.summary), 304s \(notModified)\n".utf8))
    }

    private func publish() async {
        let now = self.now
        var all: [PipelineRun] = []
        for repo in repos {
            for var run in (known[repo.key] ?? [:]).values {
                run.usualDuration = usual[repo.key]?[run.selectorKey]
                all.append(run)
            }
        }
        all.sort { $0.createdAt > $1.createdAt }
        let (count, notModified) = await counts()
        let snapshot = BitbucketSnapshot(runs: all, status: status, fetchedAt: listedAt.values.max() ?? 0, repoCount: repos.count,
                                         tokenExpiresAt: await client.tokenExpiry(for: Self.lane), requests: count, owner: owner,
                                         notModified: notModified)
        var compare = snapshot
        compare.fetchedAt = last.fetchedAt
        compare.requests = last.requests
        compare.notModified = last.notModified
        guard compare != last || snapshot.fetchedAt - last.fetchedAt > BuildPolling.openRefresh || now - lastSentAt > 60 else { return }
        last = snapshot
        lastSentAt = now
        onChange(snapshot)
    }

    private var lastSentAt: Double = 0

    /// Dev: one poll of one repository, as the poller does it.
    func debugFetch(_ repo: BitbucketRepo) async -> [PipelineRun] {
        await client.loadTokenNow()
        if repos.isEmpty { repos = [repo] }
        await resolveOwner()
        await poll(repo, pagelen: 10, sweep: true)
        await fetchHistory(repo)
        return (known[repo.key] ?? [:]).values.map { run in
            var run = run
            run.usualDuration = usual[repo.key]?[run.selectorKey]
            return run
        }.sorted { $0.createdAt > $1.createdAt }
    }

    func debugOwner() -> BitbucketOwner? { owner }
    func debugCounts() async -> RequestCount { await counts().0 }

    // MARK: Failure details

    /// What "Copy failure" copies for a run: where it ran, the failed step, its failed tests
    /// (when the step published a test report), and the end of its log.
    func failureReport(for key: String, easURLs: [URL]) async -> String {
        await client.loadTokenNow()
        guard var run = known.values.lazy.flatMap(\.values).first(where: { $0.id == key }) else {
            return "Bitbucket run \(key): not in the notch's data any more."
        }
        let repo = repos.first { $0.workspace == run.ref.workspace && $0.repo == run.ref.repo }
            ?? BitbucketRepo(workspace: run.ref.workspace, repo: run.ref.repo)
        if run.failedStep == nil, let steps = await fetchSteps(repo, uuid: run.uuid) { run.steps = steps }
        let step = run.failedStep
        var tail: [String]?
        var tests: [String]?
        if let step {
            tail = await logTail(repo, run: run.uuid, step: step.id)
            tests = await failedTests(repo, run: run.uuid, step: step.id)
        }
        return BitbucketFailure.compose(run: run, step: step, tail: tail, tests: tests, easURLs: easURLs)
    }

    /// The end of a step's log: a range request for the last 128 KB (a finished step's log
    /// redirects to storage, followed without the token), its last 100 lines.
    private func logTail(_ repo: BitbucketRepo, run: String, step: String) async -> [String]? {
        guard let runId = run.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let stepId = step.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "\(base(repo))/\(runId)/steps/\(stepId)/log") else { return nil }
        var answer = await get(url, kind: "report", range: "bytes=-131072", accept: "application/octet-stream")
        if answer?.1.statusCode == 416 { answer = await get(url, kind: "report", accept: "application/octet-stream") }
        guard let (data, response) = answer, response.statusCode == 200 || response.statusCode == 206 else { return nil }
        var lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).map(plainLogLine)
        // A ranged body starts mid-line.
        if response.statusCode == 206, lines.count > 1 { lines.removeFirst() }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return Array(lines.suffix(100))
    }

    /// The failed test cases of a step's test report, at most 20. The endpoint is not
    /// documented: a 404 means no report; each case is read for a name and a status under any of
    /// the keys seen in the wild, and anything else is skipped.
    private func failedTests(_ repo: BitbucketRepo, run: String, step: String) async -> [String]? {
        guard let runId = run.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let stepId = step.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        let query = [("pagelen", "100")]
        var next = BuildHTTP.url("\(base(repo))/\(runId)/steps/\(stepId)/test_reports/test_cases", query)
        var failed: [String] = []
        var pages = 0
        while let url = next, pages < 4, failed.count < 20 {
            pages += 1
            guard let (data, response) = await get(url, kind: "report"), response.statusCode == 200,
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { break }
            failed += BitbucketFailure.failedTestNames(in: object)
            next = (object["next"] as? String).flatMap { BuildHTTP.next($0, keeping: query) }
        }
        return failed.isEmpty ? nil : Array(failed.prefix(20))
    }
}

/// The text "Copy failure" copies for a run, masked.
enum BitbucketFailure {
    static func compose(run: PipelineRun, step: PipelineStep?, tail: [String]?, tests: [String]? = nil, easURLs: [URL]) -> String {
        var lines = [
            "Bitbucket pipeline \(run.state == .failed ? "failed" : run.state.rawValue): \(run.ref.repo) #\(run.ref.number)",
            "Repo: \(run.ref.workspace)/\(run.ref.repo)",
            "Branch: \(run.branch ?? "—")\(run.pullRequest.map { " (PR #\($0)\(run.destination.map { " → \($0)" } ?? ""))" } ?? "")",
            "Commit: \(run.commit ?? "—")",
            "Pipeline: #\(run.ref.number)\(run.selector.map { " · \($0)" } ?? "")\(run.creator.map { " · by \($0)" } ?? "")",
            "Run: \(run.url.absoluteString)",
            "Failed step: \(step?.name ?? "—")",
        ]
        lines += easURLs.map { "EAS build: \($0.absoluteString)" }
        if let tests, !tests.isEmpty {
            lines.append("")
            lines.append("--- failed tests (\(tests.count)\(tests.count >= 20 ? ", first 20" : "")) ---")
            lines += tests
        }
        if let step, let tail, !tail.isEmpty {
            lines.append("")
            lines.append("--- last \(tail.count) lines of \(step.name) ---")
            lines += tail
        } else if step != nil {
            lines.append("The step's log could not be read.")
        }
        return Redact.mask(lines.joined(separator: "\n"), keep: Set([run.commit].compactMap { $0 }))
    }

    /// Failed test names from a test_cases page, defensively: the schema is not documented.
    static func failedTestNames(in page: [String: Any]) -> [String] {
        let values = page["values"] as? [[String: Any]] ?? []
        return values.compactMap { item in
            let status = ["status", "result", "outcome", "state"].lazy.compactMap { key -> String? in
                if let text = item[key] as? String { return text }
                return (item[key] as? [String: Any])?["name"] as? String
            }.first?.uppercased() ?? ""
            guard status.contains("FAIL") || status.contains("ERROR") else { return nil }
            let name = ["fully_qualified_name", "name", "test_name", "testName", "title"].lazy.compactMap { item[$0] as? String }.first
            let suite = ["suite_name", "test_suite_name", "classname", "class_name"].lazy.compactMap { item[$0] as? String }.first
            guard let name, !name.isEmpty else { return nil }
            if let suite, !suite.isEmpty, !name.contains(suite) { return "\(suite) › \(name)" }
            return name
        }
    }
}
