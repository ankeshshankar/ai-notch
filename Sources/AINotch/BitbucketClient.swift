import Foundation

// One Bitbucket connection for every source that reads Bitbucket: the token from the Keychain,
// the ETag cache, the hourly request count and the backoff. Each source polls in its own lane
// with its own budget (Pipelines 360 an hour, at most 390; pull requests 120, at most 150), so
// one lane's schedule never eats the other's. What one lane learns about the token is shared: a
// 401 drops it for both, and a token re-saved in the Keychain is picked up by both. A missing
// scope (a 403) is per lane: a token without read:pullrequest stops only the pull-request lane.
// A 429 pauses the lane that got it; a 429 or `X-RateLimit-NearLimit: true` slows both lanes
// for 15 minutes. Requests send If-None-Match with the lane's last ETag for the same URL, and a
// redirect to another host (a finished step's log, in storage) is followed without the token.

/// The kinds of Bitbucket polling, each with its own hourly budget.
enum BitbucketLane: String, Sendable, CaseIterable {
    case pipelines
    case pullRequests

    /// What the lane's schedule aims for in an hour. Bitbucket allows 1,000 an hour for
    /// repository data; both lanes together stay well under it (540 at most).
    var hourlyTarget: Double {
        switch self {
        case .pipelines: return 360
        case .pullRequests: return 120
        }
    }

    /// The lane's hard ceiling: no request past it within the last hour.
    var hourlyCap: Int {
        switch self {
        case .pipelines: return 390
        case .pullRequests: return 150
        }
    }

    /// For the timing lines on stderr: the Pipelines lane keeps the prefix it always had.
    var logPrefix: String { self == .pipelines ? "bitbucket" : "bitbucket-pr" }
}

/// What a request came back with. Every HTTP answer the client does not act on itself (200,
/// 206, a 304 replayed from the cache as 200 or 206, 403, 404, 400…) is a `response`.
enum BitbucketAnswer: Sendable {
    case response(Data, HTTPURLResponse)
    /// The lane has no usable token: none stored, rejected, or lacking the lane's scope.
    case noToken
    /// No answer at all (offline, a timeout).
    case offline
    /// 401: the token is dropped for both lanes. `truncated`: it is exactly 128 characters.
    case unauthorized(truncated: Bool)
    /// 429: this lane waits `wait` seconds (Retry-After, else 120), then both run slower.
    case rateLimited(wait: Double)
}

/// The result of looking for a token in the Keychain for a lane that has none it can use.
enum BitbucketTokenCheck: Sendable, Equatable {
    /// Not due yet: looked too recently.
    case notDue
    /// A token the lane can use (new, or no longer marked rejected).
    case found
    /// The same token that was rejected (or that lacks this lane's scope) is still there.
    case stillRejected
    /// Nothing in the Keychain. `afterRejection`: a token had been rejected before.
    case missing(afterRejection: Bool)
}

actor BitbucketClient {
    static let shared = BitbucketClient()

    private struct LaneState {
        var requests: [(at: Double, kind: String, notModified: Bool)] = []
        /// ETags and the bodies they stand for, by URL (and range).
        var etags: [String: (etag: String, data: Data)] = [:]
        var pauseUntil: Double = 0
        var slowUntil: Double = 0
        var slowFactor: Double = 1
        var tokenCheckedAt: Double = -.infinity
    }

    private var token: KeychainItem.Found?
    /// The fingerprint of a token Bitbucket rejected (401): the same one read again is not used.
    private var rejected: String?
    /// Per lane, the fingerprint of a token that lacks the lane's scope (403).
    private var lacksScope: [BitbucketLane: String] = [:]
    private var lanes: [BitbucketLane: LaneState] = [:]

    private var now: Double { Date().timeIntervalSince1970 }

    private func state(_ lane: BitbucketLane) -> LaneState { lanes[lane] ?? LaneState() }
    private func update(_ lane: BitbucketLane, _ change: (inout LaneState) -> Void) {
        var state = lanes[lane] ?? LaneState()
        change(&state)
        lanes[lane] = state
    }

    // MARK: The token

    /// Whether the lane has a token it can use now.
    func hasToken(for lane: BitbucketLane) -> Bool {
        guard let token else { return false }
        return lacksScope[lane] != token.fingerprint
    }

    /// Whether the lane's token was refused for a missing scope (and none newer was found).
    func lacksScope(for lane: BitbucketLane) -> Bool {
        guard let token, let fingerprint = lacksScope[lane] else { return false }
        return fingerprint == token.fingerprint
    }

    /// For a lane without a usable token: reads the Keychain when due. After a rejection (or with
    /// `urgent`, the notch opening) every `retry` seconds, else every `idle` seconds. A token with
    /// another fingerprint than the rejected one replaces it for both lanes.
    func loadToken(for lane: BitbucketLane, urgent: Bool, retry: Double = 60, idle: Double = BuildPolling.broken) -> BitbucketTokenCheck {
        let now = self.now
        let blocked = rejected ?? lacksScope[lane]
        let every = blocked != nil || urgent ? retry : idle
        guard now - state(lane).tokenCheckedAt > every else { return .notDue }
        update(lane) { $0.tokenCheckedAt = now }
        guard let found = Self.readToken() else {
            return .missing(afterRejection: blocked != nil)
        }
        if found.fingerprint == rejected || found.fingerprint == lacksScope[lane] {
            return .stillRejected
        }
        if blocked != nil { noteBuildLog("bitbucket: a new token was found in the Keychain") }
        token = found
        rejected = nil
        lacksScope = lacksScope.filter { $0.value == found.fingerprint }
        return .found
    }

    /// A lane whose token works but lacks the lane's scope: looks for a newer token in the
    /// Keychain every `every` seconds (the Pipelines lane never does this while it has one).
    /// True when a different token was found and taken for both lanes.
    func lookForNewerToken(for lane: BitbucketLane, every: Double) -> Bool {
        guard let current = token, lacksScope[lane] == current.fingerprint else { return false }
        let now = self.now
        guard now - state(lane).tokenCheckedAt > every else { return false }
        update(lane) { $0.tokenCheckedAt = now }
        guard let found = Self.readToken(), found.fingerprint != current.fingerprint, found.fingerprint != rejected else { return false }
        noteBuildLog("bitbucket: a new token was found in the Keychain")
        token = found
        rejected = nil
        lacksScope = lacksScope.filter { $0.value == found.fingerprint }
        return true
    }

    /// A dev check or Copy failure with no token yet: the Keychain, read at once.
    func loadTokenNow() {
        if token == nil { token = Self.readToken() }
    }

    /// The lane's token lacks its scope: the lane stops until a different token is stored.
    func markLacksScope(_ lane: BitbucketLane) {
        guard let token else { return }
        lacksScope[lane] = token.fingerprint
        update(lane) { $0.tokenCheckedAt = -.infinity }
    }

    /// Setup's "Check Again": forget rejections, and read the Keychain at the next look.
    func recheck() {
        rejected = nil
        lacksScope = [:]
        for lane in BitbucketLane.allCases { update(lane) { $0.tokenCheckedAt = -.infinity } }
    }

    /// When the lane's token expires, from the Keychain item's comment ("expires YYYY-MM-DD").
    func tokenExpiry(for lane: BitbucketLane) -> Double? {
        hasToken(for: lane) ? KeychainItem.expiry(in: token?.comment) : nil
    }

    /// A short hash of the token in use, never the token: what a cache is keyed by.
    func tokenFingerprint() -> String? { token?.fingerprint }

    private static func readToken() -> KeychainItem.Found? {
        // Dev: a stub's token from a file, which a test rewrites like a re-saved Keychain item.
        if BitbucketConfig.isStubbed, let file = ProcessInfo.processInfo.environment["CLAUDE_NOTCH_BITBUCKET_TEST_TOKEN_FILE"] {
            guard let secret = (try? String(contentsOfFile: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines), !secret.isEmpty else { return nil }
            return KeychainItem.Found(secret: secret, account: "stub", comment: nil)
        }
        if BitbucketConfig.isStubbed, let stub = ProcessInfo.processInfo.environment["CLAUDE_NOTCH_BITBUCKET_TEST_TOKEN"] {
            return KeychainItem.Found(secret: stub, account: "stub", comment: ProcessInfo.processInfo.environment["CLAUDE_NOTCH_BITBUCKET_TEST_EXPIRY"])
        }
        return KeychainItem.read(service: BitbucketConfig.tokenService)
    }

    // MARK: The budget

    /// The lane's requests in the last hour.
    func count(_ lane: BitbucketLane) -> Int {
        let now = self.now
        return state(lane).requests.reduce(0) { $0 + (now - $1.at <= 3600 ? 1 : 0) }
    }

    /// The lane's requests in the last hour by kind, and how many were 304s.
    func counts(_ lane: BitbucketLane) -> (RequestCount, Int) {
        let now = self.now
        var count = RequestCount()
        var notModified = 0
        update(lane) { $0.requests.removeAll { now - $0.at > 3600 } }
        for request in state(lane).requests {
            count.total += 1
            count.byKind[request.kind, default: 0] += 1
            if request.notModified { notModified += 1 }
        }
        return (count, notModified)
    }

    /// Early backoff on the lane's own count, before Bitbucket has to say anything: past 80% of
    /// its cap, the lane runs at half pace for 10 minutes.
    func backOffIfNearCap(_ lane: BitbucketLane) {
        let now = self.now
        update(lane) { $0.requests.removeAll { now - $0.at > 3600 } }
        guard state(lane).requests.count > lane.hourlyCap * 4 / 5 else { return }
        update(lane) {
            $0.slowUntil = max($0.slowUntil, now + 600)
            $0.slowFactor = max($0.slowFactor, 2)
        }
    }

    /// How much slower the lane runs now: 1, or 2 or 3 while backing off.
    func slow(_ lane: BitbucketLane) -> Double {
        let state = state(lane)
        return now < state.slowUntil ? state.slowFactor : 1
    }

    /// Until when the lane waits after a 429.
    func pauseUntil(_ lane: BitbucketLane) -> Double { state(lane).pauseUntil }

    private func slowBoth(until: Double, factor: Double) {
        for lane in BitbucketLane.allCases {
            update(lane) {
                $0.slowUntil = until
                $0.slowFactor = max($0.slowFactor, factor)
            }
        }
    }

    // MARK: Requests

    /// One request with the token, counted against the lane's budget. JSON answers are asked
    /// with the ETag of the lane's last answer for the same URL; a 304 returns that answer's body
    /// (as 200, or 206 for a range). Handles what is the same for every lane: 401 (the token is
    /// dropped, and the Keychain read again on the next look), 429 and NearLimit (back off).
    /// What a 403 means is the lane's to say (`markLacksScope`).
    func get(_ url: URL, lane: BitbucketLane, kind: String, range: String? = nil, accept: String = "application/json") async -> BitbucketAnswer {
        guard hasToken(for: lane), let token else { return .noToken }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("Bearer \(token.secret)", forHTTPHeaderField: "Authorization")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        if let range { request.setValue(range, forHTTPHeaderField: "Range") }
        let cacheKey = url.absoluteString + (range ?? "")
        let cached = state(lane).etags[cacheKey]
        if let cached { request.setValue(cached.etag, forHTTPHeaderField: "If-None-Match") }
        let started = Date()
        guard let (data, response) = try? await BuildHTTP.session.data(for: request),
              let http = response as? HTTPURLResponse else {
            let at = now
            update(lane) { $0.requests.append((at, kind, false)) }
            return .offline
        }
        let at = now
        update(lane) { $0.requests.append((at, kind, http.statusCode == 304)) }
        if ProcessInfo.processInfo.environment["CLAUDE_NOTCH_BUILD_TIMING"] != nil {
            FileHandle.standardError.write(Data("\(lane.logPrefix) \(kind) \(http.statusCode) \(url.path) \(data.count)B \(String(format: "%.2f", Date().timeIntervalSince(started)))s main=\(pthread_main_np() != 0)\n".utf8))
        }
        if http.value(forHTTPHeaderField: "X-RateLimit-NearLimit")?.lowercased() == "true" {
            slowBoth(until: at + 900, factor: 3)
        }
        switch http.statusCode {
        case 304:
            // No body to stand for it (the cache was cleared meanwhile): what the caller sees is a
            // 304, which no caller takes for an answer.
            guard let cached else { return .response(data, http) }
            return .response(cached.data, HTTPURLResponse(url: url, statusCode: range == nil ? 200 : 206, httpVersion: nil, headerFields: nil)!)
        case 401:
            let truncated = token.secret.count == BitbucketConfig.truncatedLength
            rejected = token.fingerprint
            self.token = nil
            // Read the Keychain again on each lane's next look.
            for lane in BitbucketLane.allCases { update(lane) { $0.tokenCheckedAt = -.infinity } }
            return .unauthorized(truncated: truncated)
        case 429:
            var wait = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "")
            // The pull-request lane also takes the rate-limit window's reset when there is no
            // Retry-After (anonymous answers carry only X-RateLimit-Reset).
            if wait == nil, lane == .pullRequests { wait = Double(http.value(forHTTPHeaderField: "X-RateLimit-Reset") ?? "") }
            let pause = max(30, wait ?? 120)
            update(lane) { $0.pauseUntil = at + pause }
            slowBoth(until: at + 900, factor: 2)
            return .rateLimited(wait: wait ?? 120)
        default:
            update(lane) { if at >= $0.slowUntil { $0.slowFactor = 1 } }
            if http.statusCode == 200 || http.statusCode == 206, let etag = http.value(forHTTPHeaderField: "ETag"), data.count < 512_000 {
                update(lane) {
                    if $0.etags.count > 300 { $0.etags.removeAll() }
                    $0.etags[cacheKey] = (etag, data)
                }
            }
            return .response(data, http)
        }
    }
}
