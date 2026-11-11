import AppKit
import Foundation

/// Where a link comes from. Every URL that reaches `NSWorkspace.open` from remote data or a
/// notification goes through `SafeLink`: https only (plain http only for this Mac's own ports and
/// a VPN's sign-in page), a host the source can really have, no embedded credentials, no port.
enum LinkSource {
    case bitbucket
    case expo
    case datadog
    /// A notification's link: any of the three above.
    case anyKnown
    /// `http://localhost:<port>`, built here from a number.
    case localhost
    /// A VPN server's sign-in page: its host is the server's own, so only the scheme is held.
    case vpnSignIn
}

enum SafeLink {
    /// Datadog's web sites: app.datadoghq.com, us3.datadoghq.com, app.datadoghq.eu, app.ddog-gov.com.
    private static let datadogDomains = ["datadoghq.com", "datadoghq.eu", "ddog-gov.com"]

    static func allows(_ url: URL, for source: LinkSource) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(), !host.isEmpty,
              url.user == nil, url.password == nil else { return false }
        switch source {
        case .localhost:
            return scheme == "http" && (host == "localhost" || host == "127.0.0.1")
        case .vpnSignIn:
            return scheme == "https" || scheme == "http"
        case .bitbucket, .expo, .datadog, .anyKnown:
            guard scheme == "https", url.port == nil else { return false }
            switch source {
            case .bitbucket: return bitbucket(host)
            case .expo: return expo(host)
            case .datadog: return datadog(host)
            default: return bitbucket(host) || expo(host) || datadog(host)
            }
        }
    }

    private static func bitbucket(_ host: String) -> Bool { host == "bitbucket.org" || host == "www.bitbucket.org" }
    private static func expo(_ host: String) -> Bool { host == "expo.dev" || host.hasSuffix(".expo.dev") }
    private static func datadog(_ host: String) -> Bool {
        datadogDomains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// The URL if the source may have sent it, else nil.
    static func checked(_ url: URL?, for source: LinkSource) -> URL? {
        guard let url, allows(url, for: source) else { return nil }
        return url
    }

    /// Opens it in the default browser; false (and a line in the log) for a link the source may not send.
    @MainActor @discardableResult
    static func open(_ url: URL?, for source: LinkSource) -> Bool {
        guard let url else { return false }
        guard allows(url, for: source) else {
            NotchLog.append("link refused: \(url.scheme ?? "no scheme")://\(url.host ?? "no host")")
            return false
        }
        return NSWorkspace.shared.open(url)
    }

    /// One path segment from remote data (an id, a slug), percent-encoded so it cannot add
    /// a slash, a query or a fragment. "." and ".." (a browser would walk up) and "" give "".
    static func segment(_ text: String) -> String {
        if text.isEmpty || text == "." || text == ".." { return "" }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#%")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    // MARK: Self-check (`AINotch --link-selfcheck`)

    static func runIfAsked(_ arguments: [String]) {
        guard arguments.contains("--link-selfcheck") else { return }
        exit(selfCheck())
    }

    static func selfCheck() -> Int32 {
        var failures = 0, checks = 0
        func expect(_ condition: Bool, _ what: String) {
            checks += 1
            if !condition { failures += 1; print("FAIL \(what)") }
        }
        func ok(_ text: String, _ source: LinkSource) -> Bool { URL(string: text).map { allows($0, for: source) } ?? false }

        expect(ok("https://bitbucket.org/ws/repo/pull-requests/5", .bitbucket), "bitbucket: its own page")
        expect(!ok("http://bitbucket.org/ws/repo", .bitbucket), "bitbucket: plain http refused")
        expect(!ok("file:///etc/passwd", .bitbucket) && !ok("javascript:alert(1)", .bitbucket) && !ok("x-apple.systempreferences:com.apple.Notifications-Settings.extension", .bitbucket), "bitbucket: other schemes refused")
        expect(!ok("https://bitbucket.org.evil.example/ws", .bitbucket) && !ok("https://evilbitbucket.org/ws", .bitbucket), "bitbucket: look-alike hosts refused")
        expect(!ok("https://bitbucket.org@evil.example/x", .bitbucket) && !ok("https://user:pw@bitbucket.org/x", .bitbucket), "bitbucket: credentials in the link refused")
        expect(!ok("https://bitbucket.org:8443/x", .bitbucket), "bitbucket: a port refused")
        expect(!ok("https://github.com/ws/repo", .bitbucket), "bitbucket: another host refused")
        expect(ok("https://expo.dev/accounts/a/projects/b/builds/c", .expo) && ok("https://staging.expo.dev/x", .expo), "expo: expo.dev and its subdomains")
        expect(!ok("https://notexpo.dev/x", .expo) && !ok("https://expo.dev.evil.example/x", .expo) && !ok("https://bitbucket.org/x", .expo), "expo: look-alikes and other sources refused")
        expect(ok("https://us5.datadoghq.com/monitors/1", .datadog) && ok("https://app.datadoghq.eu/x", .datadog) && ok("https://app.ddog-gov.com/x", .datadog), "datadog: its sites")
        expect(!ok("https://datadoghq.com.evil.example/x", .datadog) && !ok("https://fakedatadoghq.com/x", .datadog) && !ok("http://app.datadoghq.com/x", .datadog), "datadog: look-alikes and http refused")
        expect(ok("https://bitbucket.org/x", .anyKnown) && ok("https://expo.dev/x", .anyKnown) && ok("https://app.datadoghq.com/x", .anyKnown) && !ok("https://example.com/x", .anyKnown), "a notification's link: the three sources only")
        expect(ok("http://localhost:3000", .localhost) && !ok("https://localhost:3000", .localhost) && !ok("http://evil.example:3000", .localhost), "localhost: http on this Mac only")
        expect(ok("https://vpn.example.com/auth?id=1", .vpnSignIn) && ok("http://10.0.0.1/auth", .vpnSignIn) && !ok("file:///tmp/x", .vpnSignIn) && !ok("ftp://vpn.example.com", .vpnSignIn), "vpn sign-in: http or https only")
        expect(checked(nil, for: .bitbucket) == nil && checked(URL(string: "https://bitbucket.org/x"), for: .bitbucket) != nil && checked(URL(string: "https://evil.example/x"), for: .bitbucket) == nil, "checked: nil in, nil out")

        // A remote id never changes the path it sits in.
        expect(segment("s2") == "s2" && segment("a/b") == "a%2Fb" && segment("a?x=1#f") == "a%3Fx=1%23f" && segment("a b") == "a%20b" && segment("..") == "" && segment("") == "", "segment: encoded")
        expect(segment("100%") == "100%25", "segment: a percent sign is encoded, not passed through")
        let story = Watchdog.storyURL(site: "us5.datadoghq.com", id: "x/../../monitors?q=1#z")
        expect(story?.host == "us5.datadoghq.com" && story?.path.hasPrefix("/watchdog/story/") == true && story?.query == nil && story?.fragment == nil, "watchdog story link: a hostile id stays in the path: \(story?.absoluteString ?? "nil")")
        expect(Watchdog.storyURL(site: "us5.datadoghq.com", id: "s2")?.absoluteString == "https://us5.datadoghq.com/watchdog/story/s2", "watchdog story link: a plain id unchanged")
        let hostile = EASBuild.pageURL(owner: "a b", slug: "x/y", id: "é?")
        expect(hostile.host == "expo.dev" && hostile.query == nil, "expo build link: odd names cannot crash or leave the path: \(hostile.absoluteString)")

        print("link selfcheck: \(checks - failures)/\(checks)")
        return failures == 0 ? 0 : 1
    }
}
