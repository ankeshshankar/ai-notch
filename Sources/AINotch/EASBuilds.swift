import Foundation

// EAS builds. First over Expo's GraphQL API (the one eas-cli itself uses: `app.byId.builds` for
// the list, `builds.byId` for a build in flight), with the CLI's own login or an EXPO_TOKEN; that
// API is undocumented, so every answer is checked and any auth or schema problem falls back to
// the CLI (`eas build:list --json`) for 10 minutes, with a line in notch.log. Polled on a queue of
// its own: a build in flight every 25 s, the list every minute while anything runs, every 5
// minutes otherwise; paused while the screen is locked with nothing running. Read only: nothing
// is ever started or cancelled.

/// A Bitbucket Pipelines run named by number: what an EAS build's message points at.
struct PipelineRef: Hashable, Sendable {
    var workspace: String
    var repo: String
    var number: Int

    var key: String { "\(workspace)/\(repo)#\(number)" }

    /// ` bb:<workspace>/<repo>#<build_number>`, anywhere in a message, as a whole word.
    private static let pattern = try! NSRegularExpression(pattern: #"(?:^|\s)bb:([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)#([0-9]{1,9})(?=\s|$)"#)

    static func find(in message: String?) -> PipelineRef? {
        guard let message else { return nil }
        let ns = message as NSString
        guard let match = pattern.matches(in: message, range: NSRange(location: 0, length: ns.length)).last,
              let number = Int(ns.substring(with: match.range(at: 3))) else { return nil }
        return PipelineRef(workspace: ns.substring(with: match.range(at: 1)), repo: ns.substring(with: match.range(at: 2)), number: number)
    }

    /// The message without its link, for display.
    static func strip(_ message: String) -> String {
        let ns = message as NSString
        return pattern.stringByReplacingMatches(in: message, range: NSRange(location: 0, length: ns.length), withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct EASBuild: Equatable, Sendable, Identifiable {
    var id: String
    var state: BuildState
    /// "ios" or "android".
    var platform: String
    var profile: String?
    var appVersion: String?
    var buildVersion: String?
    var commit: String?
    var commitMessage: String?
    var message: String?
    /// Who started it: a user (the CLI's account) or a robot ("Bitbucket Pipeline").
    var actor: String?
    var actorKind: String?
    var createdAt: Double
    var completedAt: Double?
    var errorCode: String?
    var errorMessage: String?
    var docsURL: URL?
    var url: URL
    /// The pipeline its message names (` bb:ws/repo#n`), if any.
    var pipeline: PipelineRef?
    /// INTERNAL, STORE, SIMULATOR.
    var distribution: String?
    var isSimulator = false
    /// While queued: its place and the wait EAS expects.
    var queuePosition: Int?
    var initialQueuePosition: Int?
    var waitLeft: Double?
    /// When a builder picked it up; nil while it waits for one.
    var workerStartedAt: Double?
    /// When its artifacts expire (internal builds keep them for 90 days).
    var expiresAt: Double?
    /// The phase in its log while it builds, read while the notch is open.
    var phase: String?
    /// The median time of the last ten finished builds of the same platform and profile.
    var usualDuration: Double?

    var platformName: String { platform == "ios" ? "iOS" : platform == "android" ? "Android" : platform.capitalized }
    var historyKey: String { "\(platform)|\(profile ?? "")" }

    /// A finished internal build whose artifacts have not expired: its page installs it.
    func isInstallable(now: Double) -> Bool {
        state == .succeeded && distribution?.uppercased() == "INTERNAL" && !isSimulator && (expiresAt ?? .infinity) > now
    }

    /// "0.0.16 (9)".
    var version: String? {
        switch (appVersion, buildVersion) {
        case let (version?, build?): return "\(version) (\(build))"
        case let (version?, nil): return version
        case let (nil, build?): return "build \(build)"
        default: return nil
        }
    }

    /// The build page; EAS's JSON has no URL of its own.
    static func pageURL(owner: String, slug: String, id: String) -> URL {
        URL(string: "https://expo.dev/accounts/\(owner)/projects/\(slug)/builds/\(id)")!
    }

    /// From the CLI's JSON or the GraphQL answer (the same BuildFragment either way).
    static func parse(_ object: [String: Any]) -> EASBuild? {
        guard let id = object["id"] as? String, let created = buildTime(object["createdAt"]) else { return nil }
        let app = object["app"] as? [String: Any]
        let owner = (app?["ownerAccount"] as? [String: Any])?["name"] as? String ?? EASConfig.settings?.account ?? "_"
        let slug = app?["slug"] as? String ?? EASConfig.settings?.slug ?? "_"
        let error = object["error"] as? [String: Any]
        let message = object["message"] as? String
        let actor = object["initiatingActor"] as? [String: Any]
        return EASBuild(
            id: id, state: state(object["status"] as? String), platform: (object["platform"] as? String ?? "").lowercased(),
            profile: object["buildProfile"] as? String, appVersion: object["appVersion"] as? String,
            buildVersion: object["appBuildVersion"] as? String, commit: object["gitCommitHash"] as? String,
            commitMessage: object["gitCommitMessage"] as? String, message: message,
            actor: actor?["displayName"] as? String, actorKind: actor?["__typename"] as? String,
            createdAt: created, completedAt: buildTime(object["completedAt"]),
            errorCode: error?["errorCode"] as? String, errorMessage: error?["message"] as? String,
            docsURL: (error?["docsUrl"] as? String).flatMap(URL.init(string:)),
            url: pageURL(owner: owner, slug: slug, id: id), pipeline: PipelineRef.find(in: message),
            distribution: object["distribution"] as? String, isSimulator: object["isForIosSimulator"] as? Bool ?? false,
            queuePosition: object["queuePosition"] as? Int, initialQueuePosition: object["initialQueuePosition"] as? Int,
            waitLeft: (object["estimatedWaitTimeLeftSeconds"] as? NSNumber)?.doubleValue,
            workerStartedAt: buildTime(object["workerStartedAt"]), expiresAt: buildTime(object["expirationDate"]),
            // Fixtures only: the phase and the usual time, which the source fills in for real builds.
            phase: object["phase"] as? String, usualDuration: (object["usualDuration"] as? NSNumber)?.doubleValue)
    }

    /// NEW, IN_QUEUE, IN_PROGRESS, PENDING_CANCEL, ERRORED, FINISHED, CANCELED.
    static func state(_ status: String?) -> BuildState {
        switch (status ?? "").lowercased().replacingOccurrences(of: "_", with: "-") {
        case "new", "in-queue", "pending": return .queued
        case "in-progress", "pending-cancel": return .running
        case "finished": return .succeeded
        case "errored": return .failed
        case "canceled", "cancelled": return .canceled
        default: return .queued
        }
    }

    /// Minimal shape check of one GraphQL build: what the rows cannot do without.
    static func isValid(_ object: [String: Any]) -> Bool {
        object["id"] is String && object["status"] is String && object["platform"] is String && buildTime(object["createdAt"]) != nil
    }
}

struct EASSnapshot: Equatable, Sendable {
    var builds: [EASBuild] = []
    /// Nil while it works.
    var status: SourceStatus?
    /// When the last fetch succeeded.
    var fetchedAt: Double = 0
    /// "GraphQL" or "CLI", and the last list call's time.
    var via: String?
    var callSeconds: Double?
    /// Why the last GraphQL call fell back to the CLI.
    var fallback: String?
    /// The CLI's login, which a build "started by me locally" names (often a shared account).
    var cliUser: String?
    /// GraphQL calls in the last hour.
    var callsLastHour = 0
}

/// The project comes from builds.json (`eas`: account, slug, projectId, and optionally the
/// eas-cli to fall back on). The CLI runs in a minimal project folder of the notch's own (never
/// the app's repository: eas-cli forces EXPO_NO_DOTENV, so a real app config may fail without
/// its env).
enum EASConfig {
    /// The project, or nil while builds.json has no `eas` part.
    static var settings: BuildsConfig.EAS? { BuildsConfig.current?.eas }
    static let minimumMajor = 24
    /// An optional EXPO_TOKEN, if the user stored one (the older name is still read); else the
    /// CLI's own login.
    static let tokenService = "ai-notch.expo"
    static let legacyTokenService = "ai-notch.expo-token"

    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    static var folder: URL { home.appendingPathComponent(".claude/notch/eas", isDirectory: true) }

    static func readToken() -> String? {
        KeychainItem.read(service: tokenService)?.secret ?? KeychainItem.read(service: legacyTokenService)?.secret
    }

    /// The CLI's login in ~/.expo/state.json: only the session secret and the user name are
    /// read, and the secret goes nowhere but the request header.
    static func cliSession() -> (secret: String, user: String?)? {
        if let test = ProcessInfo.processInfo.environment["CLAUDE_NOTCH_EAS_TEST_SESSION"] { return (test, "test") }
        guard let data = try? Data(contentsOf: home.appendingPathComponent(".expo/state.json")),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let auth = object["auth"] as? [String: Any], let secret = auth["sessionSecret"] as? String, !secret.isEmpty else { return nil }
        return (secret, auth["username"] as? String)
    }

    /// Writes the folder's three files: app.json follows builds.json (rewritten when the project
    /// changes), the other two are written when missing.
    static func ensureFolder() {
        guard let settings else { return }
        let app: [String: Any] = ["expo": ["name": settings.slug, "slug": settings.slug, "owner": settings.account,
                                           "extra": ["eas": ["projectId": settings.projectId]]]]
        guard let appJSON = try? JSONSerialization.data(withJSONObject: app, options: [.sortedKeys]) else { return }
        let files: [(String, Data, Bool)] = [
            ("app.json", appJSON + Data("\n".utf8), true),
            ("eas.json", Data("{}\n".utf8), false),
            ("package.json", Data((#"{"name":"ai-notch-eas","private":true,"version":"0.0.0"}"# + "\n").utf8), false),
        ]
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, body, follows) in files {
            let url = folder.appendingPathComponent(name)
            let current = try? Data(contentsOf: url)
            if current == nil || (follows && current != body) { try? body.write(to: url, options: .atomic) }
        }
    }

    /// nvm's node folders, newest first: a GUI app does not inherit the shell's PATH, and the
    /// CLI's shim runs `node` from PATH.
    static var nodeBins: [String] {
        let root = home.appendingPathComponent(".nvm/versions/node")
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        let sorted = versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        return sorted.map { root.appendingPathComponent($0).appendingPathComponent("bin").path }
            .filter { FileManager.default.isExecutableFile(atPath: $0 + "/node") }
    }

    static var path: String { (nodeBins + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]).joined(separator: ":") }

    /// The CLI to run: builds.json's `eas.cli`, else an `eas` on the explicit PATH that is new
    /// enough. Nil: none found. Run off the main thread (it may ask a candidate its version).
    static func findCLI() -> (path: String?, problem: String?) {
        if let pinned = settings?.cli, FileManager.default.isExecutableFile(atPath: pinned) { return (pinned, nil) }
        var tooOld: String?
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/eas"
            guard FileManager.default.isExecutableFile(atPath: candidate) else { continue }
            let version = runProcess(candidate, ["--version"], environment: environment(token: nil), directory: folder, timeout: 20)
            let text = version.map { String(decoding: $0.output, as: UTF8.self) } ?? ""
            // "eas-cli/24.7.0 darwin-arm64 node-v24.13.0"
            if let range = text.range(of: #"eas-cli/(\d+)\."#, options: .regularExpression),
               let major = Int(text[range].dropFirst(8).dropLast()), major >= minimumMajor {
                return (candidate, nil)
            }
            tooOld = text.split(separator: " ").first.map(String.init) ?? candidate
        }
        return (nil, tooOld.map { "Only \($0) found; AI Notch needs eas-cli \(minimumMajor) or later. Set eas.cli in \(BuildsConfig.displayPath) to a newer one." })
    }

    /// A clean environment: nothing of the app's own, the explicit PATH, and no VCS.
    static func environment(token: String?) -> [String: String] {
        var env: [String: String] = [
            "HOME": home.path, "PATH": path, "LANG": "en_US.UTF-8",
            "EAS_NO_VCS": "1", "EAS_PROJECT_ROOT": folder.path,
            "EXPO_NO_TELEMETRY": "1", "CI": "1", "NO_COLOR": "1",
        ]
        if let user = ProcessInfo.processInfo.environment["USER"] { env["USER"] = user }
        if let token { env["EXPO_TOKEN"] = token }
        return env
    }

    /// The JSON in the CLI's output: it may print notices before it.
    static func json(in output: Data) -> Any? {
        if let value = try? JSONSerialization.jsonObject(with: output) { return value }
        let text = String(decoding: output, as: UTF8.self)
        guard let start = text.firstIndex(where: { $0 == "[" || $0 == "{" }) else { return nil }
        // The first line that opens the JSON.
        var index = start
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("[") || line.hasPrefix("{") { index = line.startIndex; break }
        }
        return try? JSONSerialization.jsonObject(with: Data(text[index...].utf8))
    }
}

/// Expo's GraphQL API, as eas-cli 24 calls it: the same queries and BuildFragment fields. Calls
/// block their (background) caller; never on the main thread.
enum EASGraphQL {
    static var endpoint: URL {
        URL(string: ProcessInfo.processInfo.environment["CLAUDE_NOTCH_EAS_GRAPHQL"] ?? "https://api.expo.dev/graphql")!
    }

    /// eas-cli's BuildFragment (graphql/types/Build.js), less fingerprint, runtime and the update
    /// channel, plus when the builder started.
    static let fragment = """
    fragment BuildFragment on Build {
      id status platform
      error { errorCode message docsUrl }
      artifacts { buildUrl xcodeBuildLogsUrl applicationArchiveUrl buildArtifactsUrl }
      initiatingActor { __typename id displayName }
      logFiles
      app { __typename id name slug ownerAccount { id name } }
      distribution iosEnterpriseProvisioning buildProfile appIdentifier sdkVersion appVersion appBuildVersion
      gitCommitHash gitCommitMessage
      initialQueuePosition queuePosition estimatedWaitTimeLeftSeconds priority
      createdAt updatedAt message completedAt expirationDate isForIosSimulator workerStartedAt
      metrics { buildWaitTime buildQueueTime buildDuration }
    }
    """

    static let listQuery = "query ViewBuildsOnApp($appId: String!, $offset: Int!, $limit: Int!, $filter: BuildFilter) { app { byId(appId: $appId) { id builds(offset: $offset, limit: $limit, filter: $filter) { id ...BuildFragment } } } }\n" + fragment
    static let byIdQuery = "query BuildsByIdQuery($buildId: ID!) { builds { byId(buildId: $buildId) { id ...BuildFragment } } }\n" + fragment

    enum Auth {
        case token(String)
        case session(String)
    }

    struct Failure: Error, Equatable {
        var reason: String
        var isAuth = false
    }

    /// The builds list, newest first (a filter narrows it: {"platform": "IOS", "buildProfile":
    /// "preview", "status": "FINISHED"}).
    static func list(auth: Auth, limit: Int, filter: [String: Any]? = nil) -> Result<[[String: Any]], Failure> {
        guard let projectId = EASConfig.settings?.projectId else { return .failure(Failure(reason: "no eas project in builds.json")) }
        var variables: [String: Any] = ["appId": projectId, "offset": 0, "limit": limit]
        if let filter { variables["filter"] = filter }
        switch post(auth: auth, query: listQuery, variables: variables) {
        case .failure(let failure): return .failure(failure)
        case .success(let data):
            guard let builds = ((data["app"] as? [String: Any])?["byId"] as? [String: Any])?["builds"] as? [[String: Any]] else {
                return .failure(Failure(reason: "unexpected shape: no app.byId.builds"))
            }
            guard builds.allSatisfy(EASBuild.isValid) else { return .failure(Failure(reason: "unexpected shape: a build without id, status, platform or createdAt")) }
            return .success(builds)
        }
    }

    static func byId(auth: Auth, id: String) -> Result<[String: Any], Failure> {
        switch post(auth: auth, query: byIdQuery, variables: ["buildId": id]) {
        case .failure(let failure): return .failure(failure)
        case .success(let data):
            guard let build = (data["builds"] as? [String: Any])?["byId"] as? [String: Any], EASBuild.isValid(build) else {
                return .failure(Failure(reason: "unexpected shape: no builds.byId"))
            }
            return .success(build)
        }
    }

    private static func post(auth: Auth, query: String, variables: [String: Any]) -> Result<[String: Any], Failure> {
        var request = URLRequest(url: endpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        switch auth {
        case .token(let token): request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        case .session(let secret): request.setValue(secret, forHTTPHeaderField: "expo-session")
        }
        guard let body = try? JSONSerialization.data(withJSONObject: ["query": query, "variables": variables]) else {
            return .failure(Failure(reason: "could not encode the query"))
        }
        request.httpBody = body
        // Dev: a field EAS does not have, to prove the fallback on a schema change.
        if ProcessInfo.processInfo.environment["CLAUDE_NOTCH_EAS_TEST_SCHEMA"] != nil,
           let broken = try? JSONSerialization.data(withJSONObject: ["query": query.replacingOccurrences(of: "queuePosition ", with: "queuePositionGone "), "variables": variables]) {
            request.httpBody = broken
        }
        guard let (data, response) = syncData(request) else { return .failure(Failure(reason: "no answer")) }
        if response.statusCode == 401 || response.statusCode == 403 {
            return .failure(Failure(reason: "HTTP \(response.statusCode)", isAuth: true))
        }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard response.statusCode == 200 || object?["errors"] != nil else { return .failure(Failure(reason: "HTTP \(response.statusCode)")) }
        guard let object else { return .failure(Failure(reason: "not JSON")) }
        if let errors = object["errors"] as? [[String: Any]], !errors.isEmpty {
            let codes = errors.compactMap { ($0["extensions"] as? [String: Any])?["errorCode"] as? String }
            let isAuth = codes.contains { $0.contains("UNAUTHORIZED") || $0.contains("UNAUTHENTICATED") }
            let schema = errors.contains { ($0["message"] as? String ?? "").hasPrefix("Cannot query field") }
            let status = response.statusCode == 200 ? "" : ", HTTP \(response.statusCode)"
            return .failure(Failure(reason: (isAuth ? "not authorized (\(codes.first ?? "?"))" : schema ? "schema changed" : "error \(codes.first ?? "?")") + status, isAuth: isAuth))
        }
        guard let data = object["data"] as? [String: Any] else { return .failure(Failure(reason: "no data")) }
        return .success(data)
    }

    /// A request on the caller's (background) thread.
    static func syncData(_ request: URLRequest) -> (Data, HTTPURLResponse)? {
        assert(!Thread.isMainThread, "syncData blocks: never on the main thread")
        final class Box: @unchecked Sendable { var value: (Data, HTTPURLResponse)? }
        let done = DispatchSemaphore(value: 0)
        let box = Box()
        let task = BuildHTTP.session.dataTask(with: request) { data, response, _ in
            if let data, let http = response as? HTTPURLResponse { box.value = (data, http) }
            done.signal()
        }
        task.resume()
        done.wait()
        return box.value
    }
}

/// Polls on its own queue and hands a snapshot to `onChange` (on that queue) only when it
/// changed. Every field below is touched on `queue` alone.
final class EASSource: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ai-notch.eas", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var snapshot = EASSnapshot()
    private var nextAt: Double = 0
    private var wantsNow = false
    private var cli: String?
    private var cliCheckedAt: Double = -.infinity
    private var token: String?
    private var tokenCheckedAt: Double = -.infinity
    /// GraphQL is skipped until then after a failure; the CLI stands in.
    private var graphqlRetryAt: Double = 0
    private var listAt: Double = 0
    private var historyAt: [String: Double] = [:]
    private var usual: [String: Double] = [:]
    private var phaseAt: [String: Double] = [:]
    private var calls: [Double] = []
    private var panelOpen = false
    private var othersActive = false
    /// The project being read (builds.json's `eas.projectId`).
    private var projectId: String?
    /// One of my Bitbucket pipelines is running or queued (it may queue a build): why, and until
    /// when the word holds. The store repeats it while it is true, so a Bitbucket poller that
    /// stops talking lets it lapse instead of keeping EAS fast.
    private var boostReason: String?
    private var boostUntil: Double = 0
    static let boostHold: Double = 120
    private let onChange: @Sendable (EASSnapshot) -> Void

    init(onChange: @escaping @Sendable (EASSnapshot) -> Void) {
        self.onChange = onChange
    }

    func start() {
        queue.async { [self] in
            EASConfig.ensureFolder()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 1, repeating: 2, leeway: .seconds(1))
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
        }
    }

    /// The notch opened: data older than a minute is fetched now.
    func refreshSoon() {
        queue.async { [self] in
            if Date().timeIntervalSince1970 - snapshot.fetchedAt > BuildPolling.openRefresh { wantsNow = true }
        }
    }

    func setPanelOpen(_ open: Bool) {
        queue.async { [self] in panelOpen = open }
    }

    /// A Bitbucket run is going, which may start a build: the list is read every minute.
    func setOthersActive(_ active: Bool) {
        queue.async { [self] in othersActive = active }
    }

    /// One of my pipelines is running or queued (`reason`), or none is (nil): while one is, the
    /// list is read every 25 s, so a build it queues shows within about that. Never blocks.
    func setPipelineBoost(_ reason: String?) {
        queue.async { [self] in
            let now = Date().timeIntervalSince1970
            let was = isBoosted(now: now)
            boostReason = reason
            boostUntil = reason == nil ? 0 : now + Self.boostHold
            if reason != nil && !was {
                noteBuildLog("eas: list every \(Int(BuildPolling.busy)) s while my pipeline runs (\(reason!))")
                // Sooner than the idle tick it may be waiting for.
                nextAt = min(nextAt, now + BuildPolling.busy)
            } else if reason == nil && was {
                noteBuildLog("eas: my pipelines are done; back to the usual pace")
            }
            timing("eas boost \(reason ?? "off")")
        }
    }

    private func isBoosted(now: Double) -> Bool { boostReason != nil && now < boostUntil }

    private func tick() {
        let now = Date().timeIntervalSince1970
        // No project in builds.json: nothing to read, and nothing of an earlier one kept.
        guard let settings = EASConfig.settings else {
            if projectId != nil || snapshot != EASSnapshot() {
                projectId = nil
                snapshot = EASSnapshot()
                send()
            }
            return
        }
        if settings.projectId != projectId {
            // Another project: what was known belongs to the old one.
            if projectId != nil {
                snapshot = EASSnapshot()
                usual = [:]
                historyAt = [:]
                phaseAt = [:]
                listAt = 0
                send()
            }
            projectId = settings.projectId
            cliCheckedAt = -.infinity
            wantsNow = true
        }
        guard wantsNow || now >= nextAt else { return }
        let boosted = isBoosted(now: now)
        let active = snapshot.builds.contains { $0.state.isActive } || boosted
        if BuildPolling.isScreenLocked && !active {
            nextAt = now + 30
            return
        }
        let forced = wantsNow
        wantsNow = false
        if now - tokenCheckedAt > BuildPolling.broken {
            tokenCheckedAt = now
            token = EASConfig.readToken()
        }
        if now < graphqlRetryAt || !fetchGraphQL(now: now, forced: forced) {
            fetchCLI(now: now)
        }
        let broken = snapshot.status != nil && snapshot.builds.isEmpty
        let building = snapshot.builds.contains { $0.state.isActive }
        // Boosted on the CLI fallback (a node process per call): every minute, not 25 s.
        let boostPace = Date().timeIntervalSince1970 < graphqlRetryAt ? 60 : BuildPolling.busy
        let pace = broken ? BuildPolling.broken : building ? BuildPolling.busy : boosted ? boostPace : othersActive ? 60 : BuildPolling.idle
        nextAt = Date().timeIntervalSince1970 + pace
        timing("eas next in \(Int(pace)) s\(boosted ? " (boost)" : "")")
    }

    // MARK: GraphQL

    private func auth() -> (EASGraphQL.Auth, String?)? {
        if let token { return (.token(token), nil) }
        if let session = EASConfig.cliSession() { return (.session(session.secret), session.user) }
        return nil
    }

    /// The list when due (every 25 s while one of my pipelines runs and no build is in flight,
    /// every minute while anything runs, else on the idle tick), a build in flight by itself in
    /// between. False: it failed, and the CLI should stand in.
    private func fetchGraphQL(now: Double, forced: Bool) -> Bool {
        guard let (auth, user) = auth() else {
            fallBack(EASGraphQL.Failure(reason: "no EXPO_TOKEN and no CLI login in ~/.expo/state.json", isAuth: true), now: now)
            return false
        }
        calls.removeAll { now - $0 > 3600 }
        var next = snapshot
        next.cliUser = user ?? next.cliUser
        let anyActive = snapshot.builds.contains { $0.state.isActive }
        let boosted = isBoosted(now: now)
        // Boosted with nothing in flight: the list itself is the busy poll, to catch a new build.
        let listEvery = boosted && !anyActive ? BuildPolling.busy - 5 : (anyActive || othersActive || boosted) ? 60 : BuildPolling.idle - 5
        let listDue = forced || snapshot.fetchedAt == 0 || snapshot.via != "GraphQL" || now - listAt >= listEvery
        if listDue {
            let started = Date()
            calls.append(now)
            switch EASGraphQL.list(auth: auth, limit: 10) {
            case .failure(let failure):
                fallBack(failure, now: now)
                return false
            case .success(let list):
                let took = Date().timeIntervalSince(started)
                timing("eas graphql list \(String(format: "%.2f", took))s")
                listAt = now
                next.builds = merge(list.compactMap(EASBuild.parse))
                next.callSeconds = took
            }
        } else {
            for build in snapshot.builds where build.state.isActive {
                let started = Date()
                calls.append(now)
                switch EASGraphQL.byId(auth: auth, id: build.id) {
                case .failure(let failure):
                    fallBack(failure, now: now)
                    return false
                case .success(let object):
                    timing("eas graphql byId \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
                    if let fresh = EASBuild.parse(object), let index = next.builds.firstIndex(where: { $0.id == fresh.id }) {
                        next.builds[index] = merge([fresh])[0]
                        if build.state == .running, panelOpen { readPhase(object, into: &next.builds[index], now: now) }
                    }
                }
            }
        }
        // ETA history for what runs now, hourly per platform and profile.
        for build in next.builds where build.state.isActive {
            let key = build.historyKey
            guard now - (historyAt[key] ?? 0) > BuildPolling.history else { continue }
            historyAt[key] = now
            var filter: [String: Any] = ["platform": build.platform.uppercased(), "status": "FINISHED"]
            if let profile = build.profile { filter["buildProfile"] = profile }
            calls.append(now)
            if case .success(let list) = EASGraphQL.list(auth: auth, limit: 10, filter: filter) {
                let durations = list.compactMap(EASBuild.parse).compactMap { b in b.completedAt.map { $0 - b.createdAt } }
                usual[key] = median(durations)
            }
        }
        next.builds = next.builds.map { var b = $0; b.usualDuration = usual[b.historyKey] ?? b.usualDuration; return b }
        if snapshot.via != "GraphQL" && snapshot.fallback != nil { noteBuildLog("eas: GraphQL works again") }
        next.via = "GraphQL"
        next.fallback = nil
        next.status = nil
        next.fetchedAt = Date().timeIntervalSince1970
        next.callsLastHour = calls.count
        commit(next)
        return true
    }

    /// Keeps what only a later call knows (the phase) across a list that does not carry it.
    private func merge(_ fresh: [EASBuild]) -> [EASBuild] {
        let previous = Dictionary(snapshot.builds.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return fresh.map { build in
            var build = build
            if build.state == .running, build.phase == nil { build.phase = previous[build.id]?.phase }
            if build.usualDuration == nil { build.usualDuration = usual[build.historyKey] }
            return build
        }.sorted { $0.createdAt > $1.createdAt }
    }

    /// The phase a running build is in: the last `phase` in the newest log file, from its last
    /// 64 KB. EAS has no field for it; the log may not be there until a phase ends. Every 25 s at
    /// most, while the notch is open.
    private func readPhase(_ object: [String: Any], into build: inout EASBuild, now: Double) {
        guard now - (phaseAt[build.id] ?? 0) >= BuildPolling.busy,
              let last = (object["logFiles"] as? [String])?.last, let url = URL(string: last) else { return }
        phaseAt[build.id] = now
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("bytes=-65536", forHTTPHeaderField: "Range")
        guard let (data, response) = EASGraphQL.syncData(request), response.statusCode == 200 || response.statusCode == 206 else { return }
        let text = String(decoding: data.suffix(65536), as: UTF8.self)
        for line in text.split(separator: "\n").reversed() {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let phase = object["phase"] as? String else { continue }
            build.phase = EASFailure.phaseTitle(phase)
            return
        }
    }

    private func fallBack(_ failure: EASGraphQL.Failure, now: Double) {
        graphqlRetryAt = now + BuildPolling.broken
        if snapshot.fallback != failure.reason {
            noteBuildLog("eas: GraphQL \(failure.reason); using the CLI for 10 minutes")
        }
        snapshot.fallback = failure.reason
        if failure.isAuth { token = nil; tokenCheckedAt = -.infinity }
    }

    // MARK: The CLI

    private func fetchCLI(now: Double) {
        if cli == nil || now - cliCheckedAt > BuildPolling.broken {
            cliCheckedAt = now
            let found = EASConfig.findCLI()
            cli = found.path
            if cli == nil {
                publish(status: SourceStatus(text: "EAS CLI not found", help: found.problem ?? "No eas-cli \(EASConfig.minimumMajor)+ found: set eas.cli in \(BuildsConfig.displayPath), or install eas-cli where nvm or Homebrew put it.", isSetup: true))
                return
            }
        }
        guard let cli else { return }
        EASConfig.ensureFolder()
        let started = Date()
        let result = runProcess(cli, ["build:list", "--json", "--non-interactive", "--limit", "10"],
                                environment: EASConfig.environment(token: token), directory: EASConfig.folder, timeout: 60)
        let took = Date().timeIntervalSince(started)
        timing("eas cli build:list \(String(format: "%.2f", took))s")
        guard let result else {
            publish(status: SourceStatus(text: "EAS CLI did not start", help: "Could not run \(cli)."))
            return
        }
        if result.timedOut {
            publish(status: SourceStatus(text: "EAS timed out", help: "eas build:list took over a minute; it is tried again later."))
            return
        }
        guard result.status == 0, let list = EASConfig.json(in: result.output) as? [[String: Any]] else {
            let errors = Redact.mask(result.errors).lowercased()
            if errors.contains("log in") || errors.contains("login") || errors.contains("logged in") || errors.contains("unauthorized") {
                publish(status: SourceStatus(text: "EAS logged out", help: "The EAS CLI is not logged in. Run `eas login` in Terminal, as a user with access to the project.", isSetup: true))
            } else {
                let last = Redact.mask(result.errors).split(separator: "\n").last.map(String.init) ?? "exit \(result.status)"
                publish(status: SourceStatus(text: "EAS failed", help: "eas build:list: \(last)"))
            }
            noteBuildLog("eas: build:list failed (exit \(result.status))")
            return
        }
        var next = snapshot
        let builds = list.compactMap(EASBuild.parse)
        // Without GraphQL, the usual time comes from what the list has.
        var durations: [String: [Double]] = [:]
        for build in builds where build.state == .succeeded {
            if let done = build.completedAt { durations[build.historyKey, default: []].append(done - build.createdAt) }
        }
        next.builds = merge(builds).map { var b = $0; b.usualDuration = usual[b.historyKey] ?? median(durations[b.historyKey] ?? []); return b }
        next.status = nil
        next.via = "CLI"
        next.callSeconds = took
        next.cliUser = EASConfig.cliSession()?.user ?? next.cliUser
        next.fetchedAt = Date().timeIntervalSince1970
        next.callsLastHour = calls.count
        commit(next)
    }

    private func timing(_ line: String) {
        if ProcessInfo.processInfo.environment["CLAUDE_NOTCH_BUILD_TIMING"] != nil {
            FileHandle.standardError.write(Data("\(line) main=\(Thread.isMainThread)\n".utf8))
        }
    }

    private var lastSentAt: Double = 0

    private func commit(_ next: EASSnapshot) {
        // The time alone never counts as a change.
        var a = next, b = snapshot
        a.fetchedAt = 0; b.fetchedAt = 0
        a.callSeconds = nil; b.callSeconds = nil
        a.callsLastHour = 0; b.callsLastHour = 0
        let changed = a != b
        snapshot = next
        if changed || snapshot.fetchedAt - lastSentAt > BuildPolling.openRefresh { send() }
    }

    private func publish(status: SourceStatus) {
        guard status != snapshot.status else { return }
        snapshot.status = status
        send()
    }

    private func send() {
        lastSentAt = snapshot.fetchedAt
        onChange(snapshot)
    }

    /// Dev: one list call each way, timed: (GraphQL seconds or failure, CLI seconds, build count).
    static func debugCompare() -> String {
        var lines: [String] = []
        let session = EASConfig.cliSession()
        let auth: EASGraphQL.Auth? = EASConfig.readToken().map { .token($0) } ?? session.map { .session($0.secret) }
        for round in 1...3 {
            let started = Date()
            if let auth {
                switch EASGraphQL.list(auth: auth, limit: 10) {
                case .success(let list): lines.append("graphql list #\(round): \(String(format: "%.2f", Date().timeIntervalSince(started)))s, \(list.compactMap(EASBuild.parse).count) builds")
                case .failure(let failure): lines.append("graphql list #\(round): FAILED (\(failure.reason)\(failure.isAuth ? ", auth" : "")) after \(String(format: "%.2f", Date().timeIntervalSince(started)))s → the app would fall back to the CLI")
                }
            } else {
                lines.append("graphql: no auth → the app would fall back to the CLI")
            }
        }
        if let cli = EASConfig.findCLI().path {
            for round in 1...2 {
                let started = Date()
                let result = runProcess(cli, ["build:list", "--json", "--non-interactive", "--limit", "10"],
                                        environment: EASConfig.environment(token: EASConfig.readToken()), directory: EASConfig.folder, timeout: 60)
                let count = (result.flatMap { EASConfig.json(in: $0.output) as? [[String: Any]] })?.count ?? -1
                lines.append("cli build:list #\(round): \(String(format: "%.2f", Date().timeIntervalSince(started)))s, \(count) builds, exit \(result?.status ?? -1)")
            }
        }
        return lines.joined(separator: "\n")
    }
}

/// What "Copy failure" copies for an EAS build: what failed (with EAS's error code and docs
/// link) and the end of its failing phase's log, read fresh (the log links are signed for 15
/// minutes on each call, so none is stored).
enum EASFailure {
    /// Off the main thread: reads the build over GraphQL (else `eas build:view`) and its logs.
    static func report(for build: EASBuild, pipelineURL: URL?) async -> String {
        let view = await fetchView(build.id)
        var logs: [URL] = []
        var fresh = build
        if let view {
            fresh = EASBuild.parse(view) ?? build
            logs = (view["logFiles"] as? [String] ?? []).compactMap(URL.init(string:))
        }
        var lines: [String] = [
            "EAS build \(fresh.state == .failed ? "failed" : fresh.state.rawValue): \(fresh.platformName) · \(fresh.profile ?? "?")",
            "Version: \(fresh.version ?? "—")",
            "Commit: \(fresh.commit ?? "—")\(fresh.commitMessage.map { " \"\(firstLine($0))\"" } ?? "")",
            "Error code: \(fresh.errorCode ?? "—")",
            "Error: \(fresh.errorMessage ?? "—")",
        ]
        if let docs = fresh.docsURL { lines.append("Docs: \(docs.absoluteString)") }
        var phaseName = "—"
        var tail: [String] = []
        var extra: [String] = []
        var problems: [String] = []
        if view == nil { problems.append("The build could not be read: the log is missing.") }
        for url in logs {
            guard let data = await fetchLog(url) else {
                problems.append("A log file could not be fetched.")
                continue
            }
            let text = String(decoding: data, as: UTF8.self)
            if url.path.hasSuffix("-xcode.txt") || !text.hasPrefix("{") {
                // Xcode's own log: plain text, format unverified; its end is what helps.
                let plain = text.split(separator: "\n", omittingEmptySubsequences: false).map(plainLogLine)
                if !plain.isEmpty { extra = ["", "--- Xcode log, last \(min(60, plain.count)) lines ---"] + plain.suffix(60) }
                continue
            }
            let parsed = parseJSONL(text)
            if parsed.phase != nil || tail.isEmpty {
                phaseName = parsed.phase.map(phaseTitle) ?? phaseName
                tail = parsed.lines
            }
        }
        lines.append("Failing phase: \(phaseName)")
        lines.append("Build: \(fresh.url.absoluteString)")
        if let pipelineURL { lines.append("Pipeline: \(pipelineURL.absoluteString)") }
        lines += problems
        if !tail.isEmpty {
            lines.append("")
            lines.append("--- last \(tail.count) lines of \(phaseName == "—" ? "the log" : phaseName) ---")
            lines += tail
        }
        lines += extra
        return Redact.mask(lines.joined(separator: "\n"), keep: Set([fresh.commit].compactMap { $0 }))
    }

    /// The failing phase is the first `END_PHASE` with `result: failed` (never the level: a
    /// doctor warning logs at 50 and passes); its last 100 messages. No failed phase: the log's
    /// last 100 messages.
    static func parseJSONL(_ text: String) -> (phase: String?, lines: [String]) {
        var entries: [(phase: String?, msg: String)] = []
        var failed: String?
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            let phase = object["phase"] as? String
            if object["marker"] as? String == "END_PHASE", object["result"] as? String == "failed", failed == nil { failed = phase }
            if object["marker"] != nil { continue }
            if let msg = object["msg"] as? String { entries.append((phase, msg)) }
        }
        let chosen = failed.map { phase in entries.filter { $0.phase == phase } } ?? entries
        let lines = chosen.flatMap { $0.msg.split(separator: "\n", omittingEmptySubsequences: false).map(plainLogLine) }
        return (failed, Array(lines.suffix(100)))
    }

    /// "RUN_GRADLEW" → "Run gradlew".
    static func phaseTitle(_ phase: String) -> String {
        let words = phase.lowercased().split(separator: "_").joined(separator: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    private static func firstLine(_ text: String) -> String {
        String(text.split(separator: "\n").first ?? "").trimmingCharacters(in: .whitespaces)
    }

    /// GraphQL `builds.byId`, else `eas build:view --json`.
    private static func fetchView(_ id: String) async -> [String: Any]? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let token = EASConfig.readToken()
                let auth: EASGraphQL.Auth? = token.map { .token($0) } ?? EASConfig.cliSession().map { .session($0.secret) }
                if let auth {
                    switch EASGraphQL.byId(auth: auth, id: id) {
                    case .success(let object): return continuation.resume(returning: object)
                    case .failure(let failure): noteBuildLog("eas: GraphQL \(failure.reason) for Copy failure; using the CLI")
                    }
                }
                let found = EASConfig.findCLI()
                guard let cli = found.path else { return continuation.resume(returning: nil) }
                EASConfig.ensureFolder()
                let result = runProcess(cli, ["build:view", id, "--json"], environment: EASConfig.environment(token: token),
                                        directory: EASConfig.folder, timeout: 60)
                let object = result.flatMap { $0.status == 0 ? EASConfig.json(in: $0.output) as? [String: Any] : nil }
                continuation.resume(returning: object)
            }
        }
    }

    /// The log body is Brotli-compressed (`content-encoding: br`); URLSession undoes that.
    private static func fetchLog(_ url: URL) async -> Data? {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await BuildHTTP.session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
