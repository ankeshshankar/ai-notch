import AppKit
import CryptoKit
import Darwin
import Foundation
import Security

// Sign in with Datadog: OAuth 2 in the browser, the way Datadog's own CLI (pup) does it
// (github.com/DataDog/pup, src/auth): Dynamic Client Registration of a public client
// (RFC 7591) once per site, the authorization code with PKCE S256 and a state, a single-use
// listener on 127.0.0.1 for the browser's answer, and the code exchanged for an access token
// (about an hour) and a refresh token (about 30 days). REST endpoints then take
// `Authorization: Bearer <access token>` instead of the API and application keys.
//
// The tokens live in the Keychain item `ai-notch.datadog` (account `oauth`) as one JSON blob;
// the client id, which is not a secret, in ~/.claude/notch/datadog-oauth-clients.json. No token,
// code or verifier ever reaches a log or a file.

enum DatadogOAuth {
    /// Read only: the monitor search, the incident search, the scalar query.
    static let scopes = ["incident_read", "monitors_read", "timeseries_query"]
    static let clientName = "AI Notch"
    /// The loopback ports pup registers; the listener takes the first free one.
    static let ports: [UInt16] = [8000, 8080, 8888, 9000]
    static let callbackPath = "/oauth/callback"
    static let tokenAccount = "oauth"
    /// The access token is renewed this long before it ends.
    static let renewBefore: Double = 300
    /// What Setup says about revoking, beyond deleting the token on this Mac.
    static let revokeHint = "To revoke it in Datadog too: Organization Settings → Mobile and Third-Party Access → AI Notch → Users (an admin, or a role with org_authorized_apps_write)."

    static func redirect(_ port: UInt16) -> String { "http://127.0.0.1:\(port)\(callbackPath)" }

    private static var env: [String: String] { ProcessInfo.processInfo.environment }

    /// Dev: with a stub server, the token and the client list are files in this folder instead
    /// of the Keychain and ~/.claude/notch (CLAUDE_NOTCH_DATADOG_OAUTH_DIR). A stub without it
    /// has no sign-in, so the key-based stub tests run as before.
    static var testDir: URL? {
        guard DatadogConfig.stubBase != nil, let dir = env["CLAUDE_NOTCH_DATADOG_OAUTH_DIR"]?.nonEmpty else { return nil }
        return URL(fileURLWithPath: dir)
    }

    /// Off with a stub server that has no test folder: nothing may touch the real Keychain then.
    static var isAvailable: Bool { DatadogConfig.stubBase == nil || testDir != nil }

    /// How long the listener waits for the browser (CLAUDE_NOTCH_DATADOG_AUTH_TIMEOUT with a stub).
    static var waitLimit: Double {
        if DatadogConfig.stubBase != nil, let value = Double(env["CLAUDE_NOTCH_DATADOG_AUTH_TIMEOUT"] ?? ""), value > 0 { return value }
        return 300
    }

    /// Dev: with a stub, the authorize URL is appended to this file instead of opening a browser,
    /// for a fake browser to follow (CLAUDE_NOTCH_DATADOG_TEST_BROWSER).
    static var testBrowser: String? {
        DatadogConfig.stubBase == nil ? nil : env["CLAUDE_NOTCH_DATADOG_TEST_BROWSER"]?.nonEmpty
    }

    /// The authorize page: the site's web host (us3.datadoghq.com, app.datadoghq.com).
    static func authorizeBase(_ site: String) -> String {
        DatadogConfig.stubBase.map { $0 + "/oauth2/v1/authorize" } ?? "https://\(DatadogConfig.webHost(site))/oauth2/v1/authorize"
    }

    /// Registration and the token endpoint: the API host, as pup calls them.
    static func registerURL(_ site: String) -> URL? { URL(string: DatadogConfig.apiBase(site) + "/api/v2/oauth2/register") }
    static func tokenURL(_ site: String) -> URL? { URL(string: DatadogConfig.apiBase(site) + "/api/v2/oauth2/token") }

    static var clientsFile: URL {
        testDir?.appendingPathComponent("clients.json")
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/notch/datadog-oauth-clients.json")
    }

    /// A host Datadog owns, to trust the `domain` the browser's answer names.
    static func isDatadogHost(_ host: String) -> Bool {
        ["datadoghq.com", "datadoghq.eu", "ddog-gov.com"].contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// URL-safe base64 of `count` random bytes, without padding.
    static func random(_ count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        if SecRandomCopyBytes(kSecRandomDefault, count, &bytes) != errSecSuccess {
            for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        }
        return base64URL(Data(bytes))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// PKCE S256: BASE64URL(SHA256(verifier)).
    static func challenge(_ verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func formBody(_ items: [(String, String)]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return Data(items.map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }.joined(separator: "&").utf8)
    }
}

/// The sign-in's state, for Setup and the chip.
enum DatadogSignIn: Equatable, Sendable {
    case signedOut
    /// Registering, opening the browser, or exchanging the code: a few words.
    case working(String)
    /// The browser has Datadog's page; the listener waits for its answer.
    case waiting
    case signedIn(org: String?, site: String, scopes: [String], expiry: Double)
    /// Datadog refused the refresh token (expired, revoked): why.
    case signInAgain(String)
}

/// The Keychain blob.
struct DatadogToken: Codable, Equatable, Sendable {
    var access: String
    var refresh: String
    /// When the access token ends (seconds since 1970).
    var expiry: Double
    var scopes: [String]
    var clientId: String
    var site: String
    /// The organization's name, from the browser's answer.
    var org: String?
    var signedInAt: Double
    /// Datadog refused the refresh token: the tokens are wiped and this says why, so "Sign in
    /// again" survives a restart.
    var ended: String?

    enum CodingKeys: String, CodingKey {
        case access, refresh, expiry, scopes, site, org, ended
        case clientId = "client_id"
        case signedInAt = "signed_in_at"
    }
}

/// A registered client (public: no secret).
struct DatadogClient: Codable, Equatable, Sendable {
    var clientId: String
    var clientName: String
    var redirectUris: [String]
    var registeredAt: Double

    enum CodingKeys: String, CodingKey {
        case clientId = "client_id"
        case clientName = "client_name"
        case redirectUris = "redirect_uris"
        case registeredAt = "registered_at"
    }
}

/// One generic-password item through the Security framework, so the secret never sits on a
/// command line. Not synchronized: it stays on this Mac.
enum KeychainBlob {
    private static func match(_ service: String, _ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func read(service: String, account: String) -> Data? {
        var query = match(service, account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    @discardableResult
    static func write(_ data: Data, service: String, account: String, label: String) -> OSStatus {
        let status = SecItemUpdate(match(service, account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard status == errSecItemNotFound else { return status }
        var add = match(service, account)
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = label
        add[kSecAttrSynchronizable as String] = kCFBooleanFalse
        return SecItemAdd(add as CFDictionary, nil)
    }

    @discardableResult
    static func delete(service: String, account: String) -> OSStatus {
        SecItemDelete(match(service, account) as CFDictionary)
    }
}

/// Where the token blob lives: the Keychain, or a file with a stub.
enum DatadogTokenStore {
    private static var file: URL? { DatadogOAuth.testDir?.appendingPathComponent("token.json") }

    static func load() -> DatadogToken? {
        let data: Data?
        if let file { data = try? Data(contentsOf: file) } else {
            data = KeychainBlob.read(service: DatadogConfig.keyService, account: DatadogOAuth.tokenAccount)
        }
        return data.flatMap { try? JSONDecoder().decode(DatadogToken.self, from: $0) }
    }

    @discardableResult
    static func save(_ token: DatadogToken) -> Bool {
        guard let data = try? JSONEncoder().encode(token) else { return false }
        if let file {
            return (try? data.write(to: file, options: .atomic)) != nil
        }
        let status = KeychainBlob.write(data, service: DatadogConfig.keyService, account: DatadogOAuth.tokenAccount, label: "AI Notch: Datadog sign-in")
        if status != errSecSuccess { noteBuildLog("datadog: could not save the sign-in to the Keychain (OSStatus \(status))") }
        return status == errSecSuccess
    }

    static func delete() {
        if let file { try? FileManager.default.removeItem(at: file); return }
        KeychainBlob.delete(service: DatadogConfig.keyService, account: DatadogOAuth.tokenAccount)
    }
}

/// The registered clients, by site: not secret, so a plain file.
enum DatadogClients {
    static func load() -> [String: [DatadogClient]] {
        guard let data = try? Data(contentsOf: DatadogOAuth.clientsFile) else { return [:] }
        return (try? JSONDecoder().decode([String: [DatadogClient]].self, from: data)) ?? [:]
    }

    static func save(_ all: [String: [DatadogClient]]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(all) else { return }
        try? FileManager.default.createDirectory(at: DatadogOAuth.clientsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: DatadogOAuth.clientsFile, options: .atomic)
    }

    /// A client of this site that may send the browser back to `redirect`.
    static func find(site: String, redirect: String) -> DatadogClient? {
        load()[site]?.last { $0.redirectUris.contains(redirect) }
    }

    static func add(_ client: DatadogClient, site: String) {
        var all = load()
        all[site, default: []].removeAll { $0.clientId == client.clientId }
        all[site, default: []].append(client)
        save(all)
    }

    static func forget(_ clientId: String, site: String) {
        var all = load()
        all[site]?.removeAll { $0.clientId == clientId }
        if all[site]?.isEmpty == true { all[site] = nil }
        save(all)
    }
}

/// The listener on 127.0.0.1 for the browser's answer: single use, it answers one callback with
/// the right state and stops. Other paths get a 404, a wrong state a 400 (and it keeps waiting).
final class LoopbackCallback: @unchecked Sendable {
    struct Answer: Sendable {
        var code: String?
        var error: String?
        var errorDescription: String?
        var org: String?
        var domain: String?
    }

    enum Outcome: Sendable {
        case answer(Answer)
        case timedOut
        case cancelled
    }

    let port: UInt16
    private let fd: Int32
    private let state: String
    private let queue = DispatchQueue(label: "ai-notch.datadog-callback")
    private var source: DispatchSourceRead?
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Outcome, Never>?
    private var finished: Outcome?

    private init(fd: Int32, port: UInt16, state: String) {
        self.fd = fd
        self.port = port
        self.state = state
    }

    /// Binds 127.0.0.1 on the first free port of `ports` (0: any free port). Nil when none is.
    /// No SO_REUSEADDR: a port another server listens on (even on 0.0.0.0) counts as taken.
    static func bind(ports: [UInt16], state: String) -> LoopbackCallback? {
        for port in ports {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { continue }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard bound == 0, listen(fd, 8) == 0 else { close(fd); continue }
            var actual = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &actual) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
            }
            _ = fcntl(fd, F_SETFL, O_NONBLOCK)
            let callback = LoopbackCallback(fd: fd, port: UInt16(bigEndian: actual.sin_port), state: state)
            callback.start()
            return callback
        }
        return nil
    }

    private func start() {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptAll() }
        let fd = self.fd
        source.setCancelHandler { close(fd) }
        self.source = source
        source.resume()
    }

    private func acceptAll() {
        while true {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            handle(client)
        }
    }

    /// Reads one request (up to 16 KB, 5 s), answers it, and closes the connection only after
    /// the browser has (up to 2 s): the side that closes first keeps the port in TIME_WAIT, and
    /// that should be the browser's port, so this one is free again at once.
    private func handle(_ client: Int32) {
        defer {
            var linger = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &linger, socklen_t(MemoryLayout<timeval>.size))
            var drain = [UInt8](repeating: 0, count: 1024)
            while read(client, &drain, drain.count) > 0 {}
            close(client)
        }
        _ = fcntl(client, F_SETFL, 0)
        var one: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var wait = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        var request = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while request.count < 16_384, request.range(of: Data("\r\n\r\n".utf8)) == nil {
            let count = read(client, &buffer, buffer.count)
            guard count > 0 else { break }
            request.append(contentsOf: buffer[0..<count])
        }
        let line = String(decoding: request, as: UTF8.self).split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET", let components = URLComponents(string: "http://127.0.0.1" + parts[1]),
              components.path == DatadogOAuth.callbackPath else {
            respond(client, status: "404 Not Found", page: nil)
            return
        }
        // Form-encoded, as Datadog (and pup's parser) has it: `+` is a space.
        let items: [(String, String)] = (components.percentEncodedQuery ?? "").split(separator: "&").map { pair in
            let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? "" }
            return (parts.first ?? "", parts.count > 1 ? parts[1] : "")
        }
        let value = { (name: String) in items.first { $0.0 == name }?.1 }
        guard let state = value("state"), Self.same(state, self.state) else {
            respond(client, status: "400 Bad Request", page: Self.page(title: "This sign-in link is not current.",
                                                                       text: "Start again from AI Notch's Setup."))
            return
        }
        let answer = Answer(code: value("code")?.nonEmpty, error: value("error")?.nonEmpty, errorDescription: value("error_description"),
                            org: value("dd_org_name")?.nonEmpty, domain: value("domain")?.nonEmpty)
        if answer.error != nil {
            respond(client, status: "200 OK", page: Self.page(title: "Sign-in did not finish.", text: "You can close this tab. AI Notch shows what Datadog said."))
        } else if answer.code != nil {
            respond(client, status: "200 OK", page: Self.page(title: "You can close this tab.", text: "AI Notch finishes signing in to Datadog."))
        } else {
            respond(client, status: "400 Bad Request", page: Self.page(title: "Datadog sent no code.", text: "Start again from AI Notch's Setup."))
            return
        }
        finish(.answer(answer))
    }

    private func respond(_ client: Int32, status: String, page: String?) {
        let body = Data((page ?? "").utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nConnection: close\r\n\r\n"
        let data = Data(head.utf8) + body
        data.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let count = write(client, raw.baseAddress!.advanced(by: sent), raw.count - sent)
                guard count > 0 else { return }
                sent += count
            }
        }
    }

    private static func same(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private static func page(title: String, text: String) -> String {
        """
        <!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>AI Notch</title>
        <style>:root{color-scheme:light dark}body{font:15px -apple-system,system-ui,sans-serif;display:grid;place-items:center;min-height:90vh;margin:0 16px}
        h1{font-size:20px;margin:0 0 8px}p{margin:0;opacity:.7}</style></head>
        <body><main><h1>\(title)</h1><p>\(text)</p></main></body></html>
        """
    }

    /// Waits for the browser's answer, the timeout, or a cancel; whichever comes first.
    func wait(timeout: Double) async -> Outcome {
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.finish(.timedOut) }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
                lock.lock()
                if let finished {
                    lock.unlock()
                    continuation.resume(returning: finished)
                    return
                }
                self.continuation = continuation
                lock.unlock()
            }
        } onCancel: {
            self.finish(.cancelled)
        }
    }

    func cancel() { finish(.cancelled) }

    private func finish(_ outcome: Outcome) {
        lock.lock()
        guard finished == nil else { lock.unlock(); return }
        finished = outcome
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        source?.cancel()
        continuation?.resume(returning: outcome)
    }
}

/// No redirects for the sign-in's own requests either.
private final class NoRedirectOAuth: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// The sign-in: registration, the browser round trip, renewing, signing out. One per app; the
/// Prod source asks it for a bearer token before each request.
actor DatadogAuth {
    static let shared = DatadogAuth()

    /// What the source gets for a request.
    enum Credential: Sendable, Equatable {
        case bearer(String)
        /// Datadog refused the refresh token: why.
        case ended(String)
        /// Renewing failed for now (offline, a server error): why.
        case unavailable(String)
        /// No sign-in for this site.
        case none
    }

    /// The cheap check the source makes every tick: no request, no renewal.
    enum Availability: Sendable, Equatable {
        case signedIn(org: String?)
        case ended(String)
        case none
    }

    private enum Failure: Error {
        case invalidClient(String)
        case invalidGrant(String)
        /// Refused for another reason (a 4xx): ends a renewal too.
        case refused(String)
        /// Offline or a server error: tried again later.
        case transient(String)

        var message: String {
            switch self {
            case .invalidClient(let text), .invalidGrant(let text), .refused(let text), .transient(let text): return text
            }
        }
    }

    private struct Issued {
        var access: String
        var refresh: String?
        var expiresIn: Double
        var scopes: [String]?
    }

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 20
        config.httpAdditionalHeaders = ["User-Agent": "AI-Notch"]
        return URLSession(configuration: config, delegate: NoRedirectOAuth(), delegateQueue: nil)
    }()

    private var token: DatadogToken?
    private var loaded = false
    private var status: DatadogSignIn = .signedOut
    private var note: String?
    private var signInTask: Task<Void, Never>?
    private var callback: LoopbackCallback?
    private var authorizeURL: URL?
    private var refreshTask: Task<Credential, Never>?
    /// When the current access token was issued (this run only): a 401 right after means the
    /// sign-in itself is refused, not that the token went stale.
    private var issuedAt: Double = 0
    private var refreshFailedAt: Double = -.infinity

    private var now: Double { Date().timeIntervalSince1970 }

    // MARK: State

    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        guard DatadogOAuth.isAvailable else { return }
        token = DatadogTokenStore.load()
        publish()
    }

    /// Setup opening, Check Again: the store is read again.
    func reload() {
        loaded = false
        ensureLoaded()
        publish()
    }

    func availability(site: String) -> Availability {
        ensureLoaded()
        guard let token, token.site == site else { return .none }
        if let ended = token.ended { return .ended(ended) }
        return .signedIn(org: token.org)
    }

    private func derived() -> DatadogSignIn {
        guard let token else { return .signedOut }
        if let ended = token.ended { return .signInAgain(ended) }
        return .signedIn(org: token.org, site: token.site, scopes: token.scopes, expiry: token.expiry)
    }

    private func publish(_ next: DatadogSignIn? = nil) {
        status = next ?? derived()
        let status = self.status, note = self.note
        DispatchQueue.main.async {
            MainActor.assumeIsolated { DatadogAuthModel.shared.take(status, note: note) }
        }
    }

    // MARK: Tokens for requests

    /// A bearer token for `site`, renewed first when it ends within five minutes.
    func credential(site: String) async -> Credential {
        ensureLoaded()
        guard let token, token.site == site else { return .none }
        if let ended = token.ended { return .ended(ended) }
        if now < token.expiry - DatadogOAuth.renewBefore { return .bearer(token.access) }
        return await renew(from: token.access)
    }

    /// A request with `access` got a 401: renewed once, unless that token is brand new (then the
    /// sign-in itself is refused).
    func unauthorized(access: String) async -> Credential {
        ensureLoaded()
        guard let token, token.ended == nil else { return token?.ended.map { .ended($0) } ?? .none }
        if token.access != access { return .bearer(token.access) }
        if now - issuedAt < 30 {
            end("Datadog refused the sign-in (401) right after it was issued. Sign in again; if it keeps happening, your Datadog role may lack monitors_read.")
            return .ended(self.token?.ended ?? "")
        }
        return await renew(from: access, force: true)
    }

    /// One renewal at a time: callers that arrive meanwhile wait for the same one.
    private func renew(from access: String, force: Bool = false) async -> Credential {
        if let token, token.ended == nil, token.access != access, now < token.expiry - 5 { return .bearer(token.access) }
        if let refreshTask { return await refreshTask.value }
        // A failed renewal is not retried for a minute (the token may still work meanwhile).
        if now - refreshFailedAt < 60 {
            if let token, !force, now < token.expiry { return .bearer(token.access) }
            return .unavailable("Datadog's sign-in did not answer; AI Notch tries again in a minute.")
        }
        let task = Task { await self.runRenewal() }
        refreshTask = task
        let result = await task.value
        refreshTask = nil
        return result
    }

    private func runRenewal() async -> Credential {
        guard var current = token, current.ended == nil else { return .none }
        guard !current.refresh.isEmpty else {
            end("Datadog gave no refresh token, so the sign-in lasted an hour.")
            return .ended(token?.ended ?? "")
        }
        guard let url = DatadogOAuth.tokenURL(current.site) else { return .none }
        let result = await tokenRequest(url, [("grant_type", "refresh_token"), ("client_id", current.clientId), ("refresh_token", current.refresh)])
        switch result {
        case .success(let issued):
            current.access = issued.access
            if let refresh = issued.refresh { current.refresh = refresh }
            current.expiry = now + issued.expiresIn
            if let scopes = issued.scopes { current.scopes = scopes }
            token = current
            issuedAt = now
            DatadogTokenStore.save(current)
            noteBuildLog("datadog: sign-in renewed (\(Int(issued.expiresIn / 60)) min)")
            publish()
            return .bearer(current.access)
        case .failure(.transient(let why)):
            refreshFailedAt = now
            noteBuildLog("datadog: renewing the sign-in failed for now: \(why)")
            if now < current.expiry { return .bearer(current.access) }
            return .unavailable(why)
        case .failure(.invalidClient):
            DatadogClients.forget(current.clientId, site: current.site)
            end("AI Notch's registration in Datadog is gone. Sign in again; it registers anew.")
            return .ended(token?.ended ?? "")
        case .failure(.invalidGrant):
            end("Your Datadog sign-in ended (it lasts about 30 days, or was revoked).")
            return .ended(token?.ended ?? "")
        case .failure(.refused(let why)):
            end("Datadog refused to renew the sign-in: \(why)")
            return .ended(token?.ended ?? "")
        }
    }

    /// The refresh token is refused: the tokens are wiped, the reason kept.
    private func end(_ why: String) {
        guard var current = token else { return }
        current.access = ""
        current.refresh = ""
        current.ended = why
        token = current
        DatadogTokenStore.save(current)
        noteBuildLog("datadog: sign-in ended: \(why)")
        publish()
    }

    // MARK: Sign in, sign out

    /// Starts the browser round trip (a second call while one runs opens the page again).
    func signIn(site: String) {
        guard DatadogOAuth.isAvailable else { return }
        guard signInTask == nil else { reopen(); return }
        note = nil
        signInTask = Task { await self.runSignIn(site: site) }
    }

    func cancelSignIn() {
        signInTask?.cancel()
        callback?.cancel()
    }

    /// The browser tab was closed: the same page again.
    func reopen() {
        guard let authorizeURL, signInTask != nil else { return }
        Task { await Self.open(authorizeURL) }
    }

    func signOut() {
        cancelSignIn()
        DatadogTokenStore.delete()
        token = nil
        note = "Signed out on this Mac. To revoke it in Datadog too: Organization Settings → Mobile and Third-Party Access."
        noteBuildLog("datadog: signed out")
        publish()
    }

    private func runSignIn(site: String) async {
        defer {
            signInTask = nil
            callback = nil
            authorizeURL = nil
            publish()
        }
        ensureLoaded()
        var retried = false
        while !Task.isCancelled {
            publish(.working("Opening Datadog…"))
            let state = DatadogOAuth.random(24)
            let verifier = DatadogOAuth.random(96)
            // A pup port, else any free port with a registration of its own.
            guard let listener = LoopbackCallback.bind(ports: DatadogOAuth.ports, state: state)
                ?? LoopbackCallback.bind(ports: [0], state: state) else {
                note = "No free port on 127.0.0.1 for Datadog's answer."
                return
            }
            callback = listener
            let redirect = DatadogOAuth.redirect(listener.port)
            var client = DatadogClients.find(site: site, redirect: redirect)
            if client == nil {
                let redirects = DatadogOAuth.ports.contains(listener.port) ? DatadogOAuth.ports.map(DatadogOAuth.redirect) : [redirect]
                switch await register(site: site, redirects: redirects) {
                case .success(let registered):
                    DatadogClients.add(registered, site: site)
                    client = registered
                    noteBuildLog("datadog: registered AI Notch with \(site) (\(registered.redirectUris.count == 1 ? "1 loopback redirect" : "\(registered.redirectUris.count) loopback redirects"))")
                case .failure(let failure):
                    listener.cancel()
                    if Task.isCancelled { return }
                    note = failure.message
                    noteBuildLog("datadog: registration failed: \(failure.message)")
                    return
                }
            }
            guard let client, var components = URLComponents(string: DatadogOAuth.authorizeBase(site)) else { listener.cancel(); return }
            components.queryItems = [
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "client_id", value: client.clientId),
                URLQueryItem(name: "redirect_uri", value: redirect),
                URLQueryItem(name: "state", value: state),
                URLQueryItem(name: "scope", value: DatadogOAuth.scopes.sorted().joined(separator: " ")),
                URLQueryItem(name: "code_challenge", value: DatadogOAuth.challenge(verifier)),
                URLQueryItem(name: "code_challenge_method", value: "S256"),
            ]
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
            guard let url = components.url else { listener.cancel(); return }
            authorizeURL = url
            noteBuildLog("datadog: sign-in waiting for the browser on 127.0.0.1:\(listener.port)")
            await Self.open(url)
            publish(.waiting)
            let outcome = await listener.wait(timeout: DatadogOAuth.waitLimit)
            listener.cancel()
            callback = nil
            authorizeURL = nil
            switch outcome {
            case .cancelled:
                noteBuildLog("datadog: sign-in cancelled")
                return
            case .timedOut:
                note = "No answer from the browser in \(Int(DatadogOAuth.waitLimit / 60)) minutes. Sign in to try again."
                noteBuildLog("datadog: sign-in timed out")
                return
            case .answer(let answer):
                if let error = answer.error {
                    if ["invalid_client", "unauthorized_client"].contains(error), !retried {
                        retried = true
                        DatadogClients.forget(client.clientId, site: site)
                        noteBuildLog("datadog: Datadog no longer knows the client (\(error)); registering again")
                        continue
                    }
                    note = error == "access_denied" ? "Access was not allowed in Datadog." : "Datadog said \(error)\(answer.errorDescription.map { ": \($0)" } ?? "")."
                    noteBuildLog("datadog: sign-in refused in the browser: \(error)")
                    return
                }
                if let domain = answer.domain.map(DatadogConfig.domain), DatadogOAuth.isDatadogHost(domain), domain != site {
                    note = "Your Datadog organization is on \(domain). Set \"site\" in builds.json to it, then sign in again."
                    noteBuildLog("datadog: sign-in landed on \(domain), builds.json says \(site)")
                    return
                }
                guard let code = answer.code, let tokenURL = DatadogOAuth.tokenURL(site) else { return }
                publish(.working("Finishing…"))
                let result = await tokenRequest(tokenURL, [("grant_type", "authorization_code"), ("client_id", client.clientId), ("code", code),
                                                           ("redirect_uri", redirect), ("code_verifier", verifier)])
                switch result {
                case .success(let issued):
                    let signedIn = DatadogToken(access: issued.access, refresh: issued.refresh ?? "", expiry: now + issued.expiresIn,
                                                scopes: issued.scopes ?? DatadogOAuth.scopes, clientId: client.clientId, site: site,
                                                org: answer.org, signedInAt: now, ended: nil)
                    token = signedIn
                    issuedAt = now
                    refreshFailedAt = -.infinity
                    note = DatadogTokenStore.save(signedIn) ? nil : "Signed in, but the Keychain did not keep it; it lasts until AI Notch quits."
                    noteBuildLog("datadog: signed in to \(site) (scopes \(signedIn.scopes.joined(separator: " "))\(issued.refresh == nil ? ", no refresh token" : ""))")
                    return
                case .failure(.invalidClient) where !retried:
                    retried = true
                    DatadogClients.forget(client.clientId, site: site)
                    noteBuildLog("datadog: the token endpoint does not know the client; registering again")
                    continue
                case .failure(let failure):
                    if Task.isCancelled { return }
                    note = "Signing in failed: \(failure.message)"
                    noteBuildLog("datadog: code exchange failed: \(failure.message)")
                    return
                }
            }
        }
    }

    private static func open(_ url: URL) async {
        if let file = DatadogOAuth.testBrowser {
            let line = Data((url.absoluteString + "\n").utf8)
            if let handle = FileHandle(forWritingAtPath: file) {
                handle.seekToEndOfFile()
                handle.write(line)
                try? handle.close()
            } else {
                FileManager.default.createFile(atPath: file, contents: line, attributes: [.posixPermissions: 0o600])
            }
            return
        }
        await MainActor.run { _ = NSWorkspace.shared.open(url) }
    }

    // MARK: Requests

    /// DCR: a public client with loopback redirects, as pup registers it.
    private func register(site: String, redirects: [String]) async -> Result<DatadogClient, Failure> {
        guard let url = DatadogOAuth.registerURL(site) else { return .failure(.refused("no registration URL")) }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let body: [String: Any] = ["client_name": DatadogOAuth.clientName, "redirect_uris": redirects,
                                   "grant_types": ["authorization_code", "refresh_token"]]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse else {
            return .failure(.transient("Datadog did not answer the registration."))
        }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(http.statusCode), let id = object["client_id"] as? String, !id.isEmpty else {
            return .failure(.refused("Datadog refused to register AI Notch (HTTP \(http.statusCode)\(Self.errorText(object).map { ": \($0)" } ?? "")). The key-based setup still works."))
        }
        return .success(DatadogClient(clientId: id, clientName: object["client_name"] as? String ?? DatadogOAuth.clientName,
                                      redirectUris: object["redirect_uris"] as? [String] ?? redirects, registeredAt: now))
    }

    /// The token endpoint, for the code and for renewals (form-encoded, no client secret).
    private func tokenRequest(_ url: URL, _ form: [(String, String)]) async -> Result<Issued, Failure> {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = DatadogOAuth.formBody(form)
        guard let (data, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse else {
            return .failure(.transient("Datadog did not answer."))
        }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if (200..<300).contains(http.statusCode) {
            guard let access = (object["access_token"] as? String)?.nonEmpty else { return .failure(.transient("Datadog answered without a token.")) }
            let expiresIn = (object["expires_in"] as? NSNumber)?.doubleValue ?? 3600
            let scopes = (object["scope"] as? String)?.split(separator: " ").map(String.init).filter { !$0.isEmpty }
            return .success(Issued(access: access, refresh: (object["refresh_token"] as? String)?.nonEmpty,
                                   expiresIn: max(60, expiresIn), scopes: scopes?.isEmpty == false ? scopes : nil))
        }
        let code = object["error"] as? String ?? ""
        let text = Self.errorText(object).map { "\($0) (HTTP \(http.statusCode))" } ?? "HTTP \(http.statusCode)"
        if code == "invalid_client" || code == "unauthorized_client" { return .failure(.invalidClient(text)) }
        if code == "invalid_grant" { return .failure(.invalidGrant(text)) }
        if http.statusCode == 429 || http.statusCode >= 500 { return .failure(.transient(text)) }
        return .failure(.refused(text))
    }

    /// An OAuth error (`error`, `error_description`) or Datadog's `errors`, in one short line.
    private static func errorText(_ object: [String: Any]) -> String? {
        var parts: [String] = []
        if let error = object["error"] as? String { parts.append(error) }
        if let description = object["error_description"] as? String { parts.append(description) }
        if let errors = object["errors"] as? [Any] {
            parts += errors.compactMap { ($0 as? String) ?? (($0 as? [String: Any])?["detail"] as? String) ?? (($0 as? [String: Any])?["title"] as? String) }
        }
        let line = parts.joined(separator: ": ").split(whereSeparator: \.isNewline).joined(separator: " ")
        return line.isEmpty ? nil : String(line.prefix(200))
    }

    // MARK: Dev

    /// `--datadog-auth status`: the state in words, never a token.
    func describe() -> String {
        ensureLoaded()
        let client = token.map { token in DatadogClients.load()[token.site]?.contains { $0.clientId == token.clientId } == true ? "client known" : "client gone" } ?? "-"
        switch derived() {
        case .signedOut: return "signed out" + (note.map { " (\($0))" } ?? "")
        case .signedIn(let org, let site, let scopes, let expiry):
            return "signed in to \(site) as \(org ?? "?"), scopes \(scopes.joined(separator: " ")), access ends in \(Int(expiry - now)) s, \(client)"
        case .signInAgain(let why): return "sign in again: \(why)"
        case .working(let text): return text
        case .waiting: return "waiting"
        }
    }

    var isSigningIn: Bool { signInTask != nil }
    var currentNote: String? { note }
}

/// The sign-in on the main thread, for Setup and the chip.
@MainActor
final class DatadogAuthModel: ObservableObject {
    static let shared = DatadogAuthModel()
    @Published private(set) var status: DatadogSignIn = .signedOut
    /// The last attempt's outcome in a sentence (a failure, "Signed out on this Mac.").
    @Published private(set) var note: String?

    func take(_ status: DatadogSignIn, note: String?) {
        if self.status != status { self.status = status }
        if self.note != note { self.note = note }
    }

    func signIn() {
        guard let site = BuildsConfig.current?.datadog?.site else { return }
        Task { await DatadogAuth.shared.signIn(site: site) }
    }

    func cancel() { Task { await DatadogAuth.shared.cancelSignIn() } }
    func reopen() { Task { await DatadogAuth.shared.reopen() } }
    func signOut() { Task { await DatadogAuth.shared.signOut() } }
    func reload() { Task { await DatadogAuth.shared.reload() } }
}
