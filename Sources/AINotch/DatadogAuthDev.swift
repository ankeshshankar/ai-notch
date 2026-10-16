import Foundation

/// Dev checks of the Datadog sign-in, never the app: `AINotch --datadog-auth <command>`.
///
/// With a stub server (CLAUDE_NOTCH_DATADOG_API) and CLAUDE_NOTCH_DATADOG_OAUTH_DIR, which keep
/// the token and the client list in files there (never the Keychain):
///
///     status                 the state in words
///     sign-in                the browser round trip (CLAUDE_NOTCH_DATADOG_TEST_BROWSER: a file a
///                            fake browser reads the authorize URL from); waits until it ends
///     token                  a bearer token as a request gets it (renewed when it ends within
///                            five minutes); prints its fingerprint, never the token
///     unauthorized           as after a 401 on that token: renewed once
///     watch <seconds>        the Prod source as the app runs it, headless: each snapshot
///     sign-out
///
/// Against the real site (no stub, no Keychain, no browser):
///
///     probe                  registers AI Notch once if no client is known for the site
///                            (~/.claude/notch/datadog-oauth-clients.json), builds the authorize
///                            URL and loads it without following redirects
///     keychain-selftest      writes, updates, reads and deletes a throwaway item
///                            (ai-notch.datadog-selftest) through the same Security calls
enum DatadogAuthDev {
    static func runIfAsked(_ arguments: [String]) {
        guard let index = arguments.firstIndex(of: "--datadog-auth") else { return }
        let command = index + 1 < arguments.count ? arguments[index + 1] : ""
        let argument = index + 2 < arguments.count ? arguments[index + 2] : nil
        let stubbed = DatadogOAuth.testDir != nil
        if !["probe", "keychain-selftest"].contains(command), !stubbed {
            fail("--datadog-auth \(command) runs only with CLAUDE_NOTCH_DATADOG_API and CLAUDE_NOTCH_DATADOG_OAUTH_DIR (a stub); the real sign-in is the app's.")
        }
        guard let site = BuildsConfig.current?.datadog?.site else { fail("no datadog part in \(BuildsConfig.displayPath)") }
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let auth = DatadogAuth.shared
            switch command {
            case "status":
                say(await auth.describe())
            case "sign-in":
                await auth.signIn(site: site)
                let started = Date()
                var last = ""
                while await auth.isSigningIn {
                    let line = await auth.describe()
                    if line != last { say("[\(Int(Date().timeIntervalSince(started)))s] \(line)"); last = line }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                say("result: \(await auth.describe())")
            case "token":
                say(describe(await auth.credential(site: site)))
                say(await auth.describe())
            case "unauthorized":
                let first = await auth.credential(site: site)
                guard case .bearer(let token) = first else { say(describe(first)); break }
                say("before: \(describe(first))")
                say("after 401: \(describe(await auth.unauthorized(access: token)))")
                say(await auth.describe())
            case "watch":
                let seconds = Double(argument ?? "") ?? 30
                let started = Date()
                let source = DatadogSource { snapshot in
                    let access: String
                    switch snapshot.access {
                    case .ok: access = "ok"
                    case .notConfigured: access = "not configured"
                    case .noKeys: access = "not connected"
                    case .signInAgain(let why): access = "sign in again (\(why))"
                    case .rejected(let why): access = "rejected (\(why))"
                    }
                    say("[\(Int(Date().timeIntervalSince(started)))s] access=\(access) via=\(snapshot.viaSignIn ? "sign-in" : "keys/none") monitors=\(snapshot.monitorTotal) alert=\(snapshot.alertCount) incidents=\(snapshot.incidents.count) problem=\(snapshot.problem?.text ?? "-") requests=\(snapshot.requestsLastHour)")
                }
                await source.start()
                try? await Task.sleep(for: .seconds(seconds))
                say(await auth.describe())
            case "sign-out":
                await auth.signOut()
                say(await auth.describe())
            case "probe":
                say(await probe(site: site))
            case "keychain-selftest":
                say(keychainSelfTest())
            default:
                say("usage: AINotch --datadog-auth status|sign-in|token|unauthorized|watch <s>|sign-out|probe|keychain-selftest")
            }
            done.signal()
        }
        done.wait()
        exit(0)
    }

    private static func fail(_ text: String) -> Never {
        FileHandle.standardError.write(Data((text + "\n").utf8))
        exit(2)
    }

    private static func say(_ text: String) {
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    }

    /// A credential in words: a token only as an 8-character fingerprint.
    private static func describe(_ credential: DatadogAuth.Credential) -> String {
        switch credential {
        case .bearer(let token): return "bearer \(KeychainItem.Found(secret: token).fingerprint.prefix(8))"
        case .ended(let why): return "ended: \(why)"
        case .unavailable(let why): return "unavailable: \(why)"
        case .none: return "none"
        }
    }

    /// The real site as far as it goes without a person: registration (once) and the authorize
    /// page's first answer.
    private static func probe(site: String) async -> String {
        var lines: [String] = []
        let redirect = DatadogOAuth.redirect(DatadogOAuth.ports[0])
        var client = DatadogClients.find(site: site, redirect: redirect)
        if let client {
            lines.append("client known for \(site): registered \(Date(timeIntervalSince1970: client.registeredAt)), \(client.redirectUris.count) redirects")
        } else {
            guard let url = DatadogOAuth.registerURL(site) else { return "no registration URL" }
            var request = URLRequest(url: url, timeoutInterval: 20)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let redirects = DatadogOAuth.ports.map(DatadogOAuth.redirect)
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["client_name": DatadogOAuth.clientName, "redirect_uris": redirects,
                                                                            "grant_types": ["authorization_code", "refresh_token"]])
            guard let (data, response) = try? await URLSession.shared.data(for: request), let http = response as? HTTPURLResponse else {
                return "registration: no answer"
            }
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            guard (200..<300).contains(http.statusCode), let id = object["client_id"] as? String else {
                return "registration refused: HTTP \(http.statusCode) \(String(decoding: data.prefix(300), as: UTF8.self))"
            }
            let registered = DatadogClient(clientId: id, clientName: object["client_name"] as? String ?? DatadogOAuth.clientName,
                                           redirectUris: object["redirect_uris"] as? [String] ?? redirects, registeredAt: Date().timeIntervalSince1970)
            DatadogClients.add(registered, site: site)
            client = registered
            lines.append("registered: HTTP \(http.statusCode), auth method \(object["token_endpoint_auth_method"] as? String ?? "?"), \(registered.redirectUris.count) redirects")
        }
        guard let client, var components = URLComponents(string: DatadogOAuth.authorizeBase(site)) else { return lines.joined(separator: "\n") }
        let verifier = DatadogOAuth.random(96)
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"), URLQueryItem(name: "client_id", value: client.clientId),
            URLQueryItem(name: "redirect_uri", value: redirect), URLQueryItem(name: "state", value: DatadogOAuth.random(24)),
            URLQueryItem(name: "scope", value: DatadogOAuth.scopes.sorted().joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: DatadogOAuth.challenge(verifier)), URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        guard let url = components.url else { return lines.joined(separator: "\n") }
        final class Stop: NSObject, URLSessionTaskDelegate {
            func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                            newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
        }
        let session = URLSession(configuration: .ephemeral, delegate: Stop(), delegateQueue: nil)
        if let (_, response) = try? await session.data(from: url), let http = response as? HTTPURLResponse {
            let location = http.value(forHTTPHeaderField: "Location").flatMap { URLComponents(string: $0) }
            let next = location?.queryItems?.first { $0.name == "next" }?.value.flatMap { URLComponents(string: $0) }
            lines.append("authorize \(url.host ?? "")\(url.path): HTTP \(http.statusCode)"
                + (location.map { " → \($0.host ?? "")\($0.path)" } ?? "")
                + (next.map { " (next \($0.path) with \(($0.queryItems ?? []).map(\.name).sorted().joined(separator: ",")))" } ?? ""))
        } else {
            lines.append("authorize: no answer")
        }
        return lines.joined(separator: "\n")
    }

    private static func keychainSelfTest() -> String {
        let service = "ai-notch.datadog-selftest", account = "probe"
        let first = Data(("{\"a\":\"" + String(repeating: "x", count: 6000) + "\"}").utf8)
        let second = Data("{\"b\":2}".utf8)
        var steps: [String] = []
        steps.append("add \(KeychainBlob.write(first, service: service, account: account, label: "AI Notch self-test"))")
        steps.append("read same \(KeychainBlob.read(service: service, account: account) == first)")
        steps.append("update \(KeychainBlob.write(second, service: service, account: account, label: "AI Notch self-test"))")
        steps.append("read updated \(KeychainBlob.read(service: service, account: account) == second)")
        steps.append("delete \(KeychainBlob.delete(service: service, account: account))")
        steps.append("gone \(KeychainBlob.read(service: service, account: account) == nil)")
        return "keychain: " + steps.joined(separator: ", ")
    }
}
