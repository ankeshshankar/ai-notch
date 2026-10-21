import Foundation

/// An .ovpn profile, checked before the helper (root) hands it to OpenVPN. Only directives a
/// client needs are let through, and none that runs a program, loads code, or reads or writes a
/// file by path: OpenVPN runs as root, so `up /path`, `plugin`, `ca /etc/…`, `log /…` in a
/// profile would be root's. Certificates and keys must be inline (`<ca>…</ca>`). Windows-only
/// directives are left out. Anything else unknown is refused, so a new or misspelt directive
/// fails closed.
///
/// Lines are read exactly as OpenVPN 2.7 reads them (options_parse.c: parse_line, the `--`
/// prefix it drops, inline blocks); the checked profile is the original lines, so what was
/// checked is what runs. Lines longer than 250 bytes are refused: OpenVPN reads a config in
/// 256-byte pieces, and the rest of a longer line would be read as a line of its own.
public struct OVPNProfile: Equatable, Sendable {
    /// The profile as OpenVPN will read it: the original lines, Windows-only ones left out.
    public var text: String
    /// "host:port/proto" of each `remote`, in order.
    public var servers: [String]
    /// Has `auth-user-pass`: connecting asks for a username and password.
    public var asksPassword: Bool
    /// The Windows-only lines left out, by line number and directive.
    public var dropped: [String]

    public struct Problem: Error, Equatable, Sendable, CustomStringConvertible {
        public var line: Int
        public var text: String
        public var description: String { line > 0 ? "Line \(line): \(text)" : text }
    }

    public static let maxBytes = 512 * 1024
    static let maxLine = 250

    public static func check(_ data: Data) -> Result<OVPNProfile, Problem> {
        do {
            var checker = Checker(data)
            return .success(try checker.run())
        } catch let problem as Problem {
            return .failure(problem)
        } catch {
            return .failure(Problem(line: 0, text: "\(error)"))
        }
    }

    /// One line's parameters as OpenVPN reads them (for the self-check).
    public static func tokens(_ line: String) throws -> [String] {
        try OVPNLine.tokens(Array(line.utf8))
    }
}

// MARK: Reading a line as OpenVPN does

enum OVPNLine {
    /// OpenVPN's `space()`: NUL or C `isspace` in the C locale.
    static func isSpace(_ c: UInt8) -> Bool {
        c == 0 || c == 0x20 || (c >= 0x09 && c <= 0x0D)
    }

    /// parse_line in options_parse.c, byte for byte: quotes, single quotes, backslash escapes, a
    /// comment where a parameter would start. Throws where OpenVPN would refuse the line.
    private enum State { case initial, quoted, unquoted, squoted, done }

    static func tokens(_ line: [UInt8]) throws -> [String] {
        var state = State.initial
        var backslash = false
        var parm: [UInt8] = []
        var out: [String] = []
        for c in line + [0] {
            var emit: UInt8 = 0
            if !backslash && c == UInt8(ascii: "\\") && state != .squoted {
                backslash = true
            } else {
                switch state {
                case .initial:
                    if !isSpace(c) {
                        if c == UInt8(ascii: ";") || c == UInt8(ascii: "#") { return try finish(out, state: state) }
                        if !backslash && c == UInt8(ascii: "\"") {
                            state = .quoted
                        } else if !backslash && c == UInt8(ascii: "'") {
                            state = .squoted
                        } else {
                            emit = c
                            state = .unquoted
                        }
                    }
                case .unquoted:
                    if !backslash && isSpace(c) { state = .done } else { emit = c }
                case .quoted:
                    if !backslash && c == UInt8(ascii: "\"") { state = .done } else { emit = c }
                case .squoted:
                    if c == UInt8(ascii: "'") { state = .done } else { emit = c }
                case .done:
                    break
                }
                if state == .done {
                    out.append(String(decoding: parm, as: UTF8.self))
                    parm = []
                    state = .initial
                }
                if backslash && emit != 0 {
                    guard emit == UInt8(ascii: "\\") || emit == UInt8(ascii: "\"") || isSpace(emit) else {
                        throw Fail("a backslash before “\(Character(Unicode.Scalar(emit)))” (OpenVPN refuses it)")
                    }
                }
                backslash = false
            }
            if emit != 0 { parm.append(emit) }
            // OpenVPN keeps at most 16 parameters and drops the rest of the line.
            if out.count >= 16 { throw Fail("more than 15 parameters on one line") }
        }
        return try finish(out, state: state)
    }

    private static func finish(_ out: [String], state: State) throws -> [String] {
        switch state {
        case .initial: return out
        case .quoted: throw Fail("no closing quotation mark (\")")
        case .squoted: throw Fail("no closing quotation mark (')")
        case .unquoted, .done: throw Fail("the line does not end cleanly")
        }
    }

    /// bypass_doubledash: a directive written `--name` is read as `name`.
    static func name(_ token: String) -> String {
        token.utf8.count >= 3 && token.hasPrefix("--") ? String(token.dropFirst(2)) : token
    }

    /// check_inline_file: a line that is one `<name>` token opens an inline block.
    static func inlineTag(_ tokens: [String]) -> String? {
        guard tokens.count == 1, let first = tokens.first, first.utf8.count >= 2,
              first.hasPrefix("<"), first.hasSuffix(">") else { return nil }
        return String(first.dropFirst().dropLast())
    }
}

struct Fail: Error {
    var text: String
    init(_ text: String) { self.text = text }
}

// MARK: The check

private struct Checker {
    let lines: [[UInt8]]
    var servers: [String] = []
    var asksPassword = false
    var dropped: [String] = []
    var keep: [Bool]
    /// The defaults a `remote` without its own port or protocol takes, from the top level.
    var port = "1194"
    var proto = "udp"

    init(_ data: Data) {
        var bytes = [UInt8](data)
        // read_config_file skips a UTF-8 byte order mark on the first line.
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
        var lines = bytes.split(separator: 0x0A, omittingEmptySubsequences: false).map { Array($0) }
        if lines.last?.isEmpty == true { lines.removeLast() }
        self.lines = lines
        keep = Array(repeating: true, count: lines.count)
    }

    mutating func run() throws -> OVPNProfile {
        guard lines.reduce(0, { $0 + $1.count + 1 }) <= OVPNProfile.maxBytes else {
            throw OVPNProfile.Problem(line: 0, text: "The profile is larger than 512 KB.")
        }
        var remotes: [(line: Int, tokens: [String])] = []
        var index = 0
        try walk(&index, until: nil, inConnection: false, remotes: &remotes)
        // Ports and protocols set anywhere at the top level apply to every remote.
        for remote in remotes { servers.append(server(remote.tokens)) }
        guard !servers.isEmpty else { throw OVPNProfile.Problem(line: 0, text: "The profile has no “remote” (the server to connect to).") }
        var text = ""
        for (i, line) in lines.enumerated() where keep[i] {
            text += String(decoding: line, as: UTF8.self) + "\n"
        }
        return OVPNProfile(text: text, servers: servers, asksPassword: asksPassword, dropped: dropped)
    }

    private func server(_ tokens: [String]) -> String {
        let host = tokens.count > 1 ? tokens[1] : "?"
        let port = tokens.count > 2 ? tokens[2] : self.port
        let proto = tokens.count > 3 ? tokens[3] : self.proto
        return "\(host):\(port)/\(proto.hasPrefix("tcp") ? "tcp" : "udp")"
    }

    /// Checks lines from `index` up to the closing `</connection>` (or the end).
    private mutating func walk(_ index: inout Int, until close: String?, inConnection: Bool,
                               remotes: inout [(line: Int, tokens: [String])]) throws {
        while index < lines.count {
            let number = index + 1
            let line = lines[index]
            index += 1
            if let close, startsWithTag(line, close) {
                try requireBlank(after: close, in: line, number)
                return
            }
            guard line.count <= OVPNProfile.maxLine else {
                throw OVPNProfile.Problem(line: number, text: "The line is longer than \(OVPNProfile.maxLine) characters.")
            }
            // A comment (or blank) line is skipped by OpenVPN whatever it holds.
            let start = line.drop { OVPNLine.isSpace($0) && $0 != 0 }
            if start.isEmpty || start.first == UInt8(ascii: "#") || start.first == UInt8(ascii: ";") { continue }
            for c in line where c == 0 || c >= 0x7F || (c < 0x20 && c != 0x09 && c != 0x0D) {
                throw OVPNProfile.Problem(line: number, text: c == 0 ? "The line holds a NUL byte." : "The line holds a character other than plain ASCII outside a comment.")
            }
            var tokens: [String]
            do {
                tokens = try OVPNLine.tokens(line)
            } catch let fail as Fail {
                throw OVPNProfile.Problem(line: number, text: "OpenVPN cannot read it: \(fail.text).")
            }
            guard !tokens.isEmpty else { continue }
            tokens[0] = OVPNLine.name(tokens[0])

            if let tag = OVPNLine.inlineTag(tokens) {
                try inline(tag, at: number, &index, inConnection: inConnection, remotes: &remotes)
                continue
            }
            var directive = tokens
            // `setenv opt X …` is read as `X …` (options.c, add_option).
            if directive[0] == "setenv", directive.count > 1, directive[1] == "opt" {
                directive = Array(directive.dropFirst(2))
                guard !directive.isEmpty else { throw OVPNProfile.Problem(line: number, text: "“setenv opt” names no directive.") }
            }
            switch try Rules.check(directive, inConnection: inConnection) {
            case .keep:
                if directive[0] == "remote" { remotes.append((number, directive)) }
                if directive[0] == "auth-user-pass" { asksPassword = true }
                if !inConnection, directive[0] == "port", directive.count > 1 { port = directive[1] }
                if !inConnection, directive[0] == "rport", directive.count > 1 { port = directive[1] }
                if !inConnection, directive[0] == "proto", directive.count > 1 { proto = directive[1] }
            case .drop:
                keep[number - 1] = false
                dropped.append("line \(number): \(directive[0]) (Windows only)")
            case .refuse(let why):
                throw OVPNProfile.Problem(line: number, text: why)
            }
        }
        if let close { throw OVPNProfile.Problem(line: 0, text: "“<\(close.dropFirst(2).dropLast())>” has no closing “\(close)”.") }
    }

    /// An inline block: certificates and keys as data, or a `<connection>` whose lines are
    /// checked like the profile's own.
    private mutating func inline(_ tag: String, at number: Int, _ index: inout Int, inConnection: Bool,
                                 remotes: inout [(line: Int, tokens: [String])]) throws {
        let close = "</\(tag)>"
        if tag == "connection" {
            guard !inConnection else { throw OVPNProfile.Problem(line: number, text: "A <connection> inside a <connection>.") }
            try walk(&index, until: close, inConnection: true, remotes: &remotes)
            return
        }
        guard Rules.inlineBlocks.contains(tag) else {
            throw OVPNProfile.Problem(line: number, text: "The inline block “<\(tag)>” is not supported.")
        }
        if tag == "auth-user-pass" { asksPassword = true }
        if inConnection, tag != "http-proxy-user-pass" {
            throw OVPNProfile.Problem(line: number, text: "“<\(tag)>” cannot be inside a <connection>.")
        }
        // The content is data (PEM, a key): only its end matters, and its lines' length.
        while index < lines.count {
            let line = lines[index]
            let lineNumber = index + 1
            index += 1
            guard line.count <= OVPNProfile.maxLine else {
                throw OVPNProfile.Problem(line: lineNumber, text: "The line is longer than \(OVPNProfile.maxLine) characters.")
            }
            if line.contains(0) { throw OVPNProfile.Problem(line: lineNumber, text: "The line holds a NUL byte.") }
            if startsWithTag(line, close) {
                try requireBlank(after: close, in: line, lineNumber)
                return
            }
        }
        throw OVPNProfile.Problem(line: number, text: "“<\(tag)>” has no closing “\(close)”.")
    }

    /// read_inline_file: a block ends at the first line that starts with its closing tag after
    /// leading spaces.
    private func startsWithTag(_ line: [UInt8], _ tag: String) -> Bool {
        let rest = line.drop { OVPNLine.isSpace($0) && $0 != 0 }
        return rest.starts(with: Array(tag.utf8))
    }

    /// OpenVPN ignores what follows a closing tag; anything there is refused rather than ignored.
    private func requireBlank(after tag: String, in line: [UInt8], _ number: Int) throws {
        let rest = line.drop { OVPNLine.isSpace($0) && $0 != 0 }.dropFirst(tag.utf8.count)
        guard rest.allSatisfy({ OVPNLine.isSpace($0) }) else {
            throw OVPNProfile.Problem(line: number, text: "Text after “\(tag)” on the same line.")
        }
    }
}

// MARK: The directives

enum Rules {
    enum Verdict: Equatable {
        case keep
        case drop
        case refuse(String)
    }

    /// Inline blocks that hold data.
    static let inlineBlocks: Set<String> = [
        "ca", "cert", "key", "extra-certs", "pkcs12", "tls-auth", "tls-crypt", "tls-crypt-v2",
        "crl-verify", "peer-fingerprint", "auth-user-pass", "http-proxy-user-pass",
    ]

    /// Directives that take a file path, allowed only as an inline block.
    static let pathOnly: Set<String> = [
        "ca", "cert", "key", "extra-certs", "pkcs12", "tls-auth", "tls-crypt", "tls-crypt-v2",
        "crl-verify", "http-proxy-user-pass", "secret", "dh", "capath", "askpass",
    ]

    /// Directives that run a program or load code.
    static let runs: Set<String> = [
        "up", "down", "down-pre", "up-delay", "up-restart", "route-up", "route-pre-down", "ipchange",
        "tls-verify", "learn-address", "client-connect", "client-disconnect", "client-crresponse",
        "auth-user-pass-verify", "plugin", "dns-updown", "script-security", "engine", "providers",
        "pkcs11-providers", "tls-export-cert", "setcon", "iproute",
    ]

    /// Directives that write or read files, change how OpenVPN runs as a process, or belong to
    /// the helper (it sets the management interface itself).
    static let helperOwned: Set<String> = [
        "config", "cd", "chroot", "user", "group", "daemon", "log", "log-append", "status",
        "status-version", "writepid", "syslog", "tmp-dir", "dev-node", "lladdr", "management",
        "management-client", "management-client-auth", "management-client-user", "management-client-group",
        "management-external-cert", "management-external-key", "management-forget-disconnect",
        "management-hold", "management-log-cache", "management-query-passwords", "management-query-proxy",
        "management-query-remote", "management-signal", "management-up-down", "machine-readable-output",
        "errors-to-stderr", "genkey", "mktun", "rmtun", "replay-persist", "ifconfig-pool-persist",
        "client-config-dir", "auth-gen-token-secret", "remap-usr1", "mark", "bind-dev", "route-table",
        "pkcs11-id", "pkcs11-id-management", "pkcs11-pin-cache", "pkcs11-cert-private",
        "pkcs11-private-mode", "pkcs11-protected-authentication", "cryptoapicert",
    ]

    /// Windows-only directives: left out, as macOS OpenVPN would refuse or ignore them.
    static let windowsOnly: Set<String> = [
        "block-outside-dns", "register-dns", "ip-win32", "route-method", "tap-sleep", "dhcp-renew",
        "dhcp-release", "dhcp-pre-release", "win-sys", "windows-driver", "service", "allow-nonadmin",
        "show-net-up", "dhcp-internal",
    ]

    /// What a client may set, with how many parameters each takes (min…max).
    static let allowed: [String: ClosedRange<Int>] = [
        "client": 0...0, "tls-client": 0...0, "pull": 0...0, "nobind": 0...0, "persist-key": 0...0,
        "persist-tun": 0...0, "persist-remote-ip": 0...0, "persist-local-ip": 0...0, "float": 0...0,
        "auth-nocache": 0...0, "mute-replay-warnings": 0...0, "remote-random": 0...0,
        "remote-random-hostname": 0...0, "push-peer-info": 0...0, "block-ipv6": 0...0,
        "route-nopull": 0...0, "ifconfig-nowarn": 0...0, "mlock": 0...0, "passtos": 0...0,
        "fast-io": 0...0, "tcp-nodelay": 0...0, "allow-pull-fqdn": 0...0, "allow-recursive-routing": 0...0,
        "disable-occ": 0...0, "single-session": 0...0, "tls-exit": 0...0, "opt-verify": 0...0,
        "comp-noadapt": 0...0, "disable-dco": 0...0, "tun-ipv6": 0...0, "mtu-test": 0...0,
        "suppress-timestamps": 0...0, "ping-timer-rem": 0...0,
        "dev": 1...1, "dev-type": 1...1, "proto": 1...1, "remote": 1...3, "port": 1...1, "lport": 1...1,
        "rport": 1...1, "local": 1...2, "bind": 0...1, "resolv-retry": 1...1, "connect-retry": 1...2,
        "connect-retry-max": 1...1, "connect-timeout": 1...1, "server-poll-timeout": 1...1,
        "explicit-exit-notify": 0...1, "keepalive": 2...2, "ping": 1...1, "ping-restart": 1...1,
        "ping-exit": 1...1, "inactive": 1...2, "session-timeout": 1...1, "remote-cert-tls": 1...1,
        "remote-cert-ku": 1...15, "remote-cert-eku": 1...1, "ns-cert-type": 1...1,
        "verify-x509-name": 1...2, "verify-hash": 1...2, "peer-fingerprint": 1...1,
        "tls-version-min": 1...2, "tls-version-max": 1...1, "tls-cipher": 1...1, "tls-ciphersuites": 1...1,
        "tls-groups": 1...1, "ecdh-curve": 1...1, "tls-cert-profile": 1...1, "tls-timeout": 1...1,
        "reneg-sec": 1...2, "reneg-bytes": 1...1, "reneg-pkts": 1...1, "hand-window": 1...1,
        "tran-window": 1...1, "cipher": 1...1, "data-ciphers": 1...1, "data-ciphers-fallback": 1...1,
        "ncp-ciphers": 1...1, "auth": 1...1, "key-direction": 1...1, "auth-user-pass": 0...1,
        "auth-retry": 1...1, "static-challenge": 2...3, "pull-filter": 2...2, "route": 1...4,
        "route-ipv6": 1...3, "route-gateway": 1...1, "route-ipv6-gateway": 1...1, "route-metric": 1...1,
        "route-delay": 0...2, "max-routes": 1...1, "redirect-gateway": 0...6, "redirect-private": 0...6,
        "topology": 1...1, "ifconfig": 2...2, "ifconfig-ipv6": 2...2, "tun-mtu": 1...2, "tun-mtu-extra": 1...1,
        "tun-mtu-max": 1...1, "link-mtu": 1...1, "mssfix": 0...2, "fragment": 1...2, "sndbuf": 1...1,
        "rcvbuf": 1...1, "txqueuelen": 1...1, "mtu-disc": 1...1, "comp-lzo": 0...1, "compress": 0...1,
        "allow-compression": 1...1, "verb": 1...1, "mute": 1...1, "replay-window": 1...2,
        "dhcp-option": 1...2, "dns": 2...15, "setenv": 1...2, "setenv-safe": 1...2,
        "ignore-unknown-option": 1...15, "echo": 0...15, "http-proxy": 1...2, "http-proxy-option": 1...2,
        "socks-proxy": 1...2, "x509-track": 1...1, "x509-username-field": 1...15, "key-derivation": 1...1,
        "connect-freq": 2...2, "tcp-queue-limit": 1...1, "ip-remote-hint": 0...1, "compat-mode": 1...1,
        "nice": 1...1, "auth-token-user": 1...1,
    ]

    /// Inside a <connection>: the parts of a connection entry.
    static let connectionAllowed: Set<String> = [
        "remote", "proto", "port", "lport", "rport", "local", "bind", "nobind", "float", "connect-retry",
        "connect-timeout", "server-poll-timeout", "http-proxy", "http-proxy-option", "socks-proxy",
        "explicit-exit-notify", "link-mtu", "tun-mtu", "tun-mtu-extra", "tun-mtu-max", "mssfix",
        "fragment", "mtu-disc",
    ]

    static func check(_ p: [String], inConnection: Bool) throws -> Verdict {
        let name = p[0]
        let args = Array(p.dropFirst())
        if runs.contains(name) { return .refuse("“\(name)” runs a program or loads code as root, which AI Notch does not allow.") }
        if pathOnly.contains(name) {
            return .refuse(inlineBlocks.contains(name)
                ? "“\(name)” must be inline (<\(name)>…</\(name)>): a file path would be read as root."
                : "“\(name)” reads a file as root, which AI Notch does not allow.")
        }
        if helperOwned.contains(name) { return .refuse("“\(name)” is set by AI Notch's helper, not by a profile.") }
        if windowsOnly.contains(name) { return inConnection ? .refuse("“\(name)” cannot be inside a <connection>.") : .drop }
        guard let range = allowed[name] else { return .refuse("“\(name)” is not supported.") }
        if inConnection, !connectionAllowed.contains(name) { return .refuse("“\(name)” cannot be inside a <connection>.") }
        guard range.contains(args.count) else {
            return .refuse("“\(name)” takes \(range.lowerBound == range.upperBound ? "\(range.lowerBound)" : "\(range.lowerBound) to \(range.upperBound)") parameter\(range.upperBound == 1 ? "" : "s"), not \(args.count).")
        }
        if let why = special(name, args) { return .refuse(why) }
        return .keep
    }

    /// Parameters that need more than a count.
    private static func special(_ name: String, _ a: [String]) -> String? {
        switch name {
        case "dev":
            let dev = a[0]
            let base = dev.hasPrefix("utun") ? "utun" : dev.hasPrefix("tun") ? "tun" : ""
            guard !base.isEmpty, dev.utf8.dropFirst(base.count).allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else {
                return "Only a tun device (dev tun) works on macOS, not “\(dev)”."
            }
        case "dev-type":
            if a[0] != "tun" { return "Only dev-type tun works on macOS." }
        case "auth-user-pass":
            // With a path OpenVPN reads that file as root and sends what it holds to the server.
            if let arg = a.first, arg != "username-only" {
                return "“auth-user-pass” with a file is not allowed; leave it bare and AI Notch asks for the password."
            }
        case "http-proxy":
            if a.count > 2 { return "“http-proxy” with a password file or “auto” is not supported." }
        case "socks-proxy":
            if a.count > 2 { return "“socks-proxy” with a password file is not supported." }
        case "setenv", "setenv-safe":
            if let why = envName(a[0]) { return why }
        case "dhcp-option":
            // Its values reach macOS's DNS settings through OpenVPN's dns-updown script.
            let kinds: Set<String> = ["DNS", "DNS6", "DOMAIN", "DOMAIN-SEARCH", "ADAPTER_DOMAIN_SUFFIX",
                                      "NTP", "NBS", "NBT", "NBDD", "WINS", "DISABLE-NBT", "PROXY_HTTP",
                                      "PROXY_HTTPS", "PROXY_BYPASS", "PROXY_AUTO_CONFIG_URL"]
            guard kinds.contains(a[0]) else { return "“dhcp-option \(a[0])” is not supported." }
            if a.dropFirst().contains(where: { !plainValue($0) }) { return "“dhcp-option \(a[0])” has characters a DNS name or address cannot have." }
        case "dns":
            if a.contains(where: { !plainValue($0) }) { return "“dns” has characters a DNS name or address cannot have." }
        case "ignore-unknown-option":
            if a.contains(where: { runs.contains($0) || helperOwned.contains($0) || pathOnly.contains($0) }) {
                return "“ignore-unknown-option” names a directive AI Notch does not allow."
            }
        default:
            break
        }
        return nil
    }

    /// A setenv name: an identifier, and none a shell or the loader would act on.
    private static func envName(_ name: String) -> String? {
        let letter: (UInt8) -> Bool = { $0 == UInt8(ascii: "_") || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) }
        let ok = name.utf8.first.map(letter) == true && name.utf8.allSatisfy { letter($0) || ($0 >= 0x30 && $0 <= 0x39) }
        let denied = ["PATH", "IFS", "ENV", "BASH_ENV", "SHELLOPTS", "BASHOPTS", "PS4", "HOME", "GENERIC_CONFIG", "CDPATH", "TMPDIR"]
        let deniedPrefix = ["LD_", "DYLD_", "BASH_FUNC", "MALLOC"]
        guard ok, !denied.contains(name), !deniedPrefix.contains(where: { name.hasPrefix($0) }) else {
            return "“setenv \(name)” is not allowed."
        }
        return nil
    }

    /// Letters, digits and . : _ - / [ ] (names, addresses, ports).
    private static func plainValue(_ value: String) -> Bool {
        value.utf8.allSatisfy { c in
            (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
                || [UInt8(ascii: "."), UInt8(ascii: ":"), UInt8(ascii: "_"), UInt8(ascii: "-"),
                    UInt8(ascii: "/"), UInt8(ascii: "["), UInt8(ascii: "]")].contains(c)
        }
    }
}
