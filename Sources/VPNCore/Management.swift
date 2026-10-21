import Foundation

/// One line from OpenVPN's management interface (doc/management-notes.txt), as the helper uses it.
public enum MgmtEvent: Equatable, Sendable {
    /// >STATE:time,name,detail,local IPv4,remote,remote port,local,local port,local IPv6
    case state(name: String, detail: String, localIP: String, remoteIP: String, remotePort: String, localIPv6: String)
    /// >BYTECOUNT:in,out
    case bytes(received: Int64, sent: Int64)
    /// >HOLD: waiting for "hold release".
    case hold
    /// >PASSWORD:Need 'Auth' username/password [SC:flags,text], or 'Auth' username alone.
    case needAuth(usernameOnly: Bool, challenge: StaticChallenge?)
    /// >PASSWORD:Need 'Private Key' password
    case needPrivateKey
    /// >PASSWORD:Verification Failed: 'Auth' (or the server's own reason), possibly a dynamic
    /// challenge to answer on the next request.
    case authFailed(reason: String?, challenge: DynamicChallenge?)
    case privateKeyFailed
    /// >INFOMSG:WEB_AUTH:flags:url or OPEN_URL:url: a sign-in page to open.
    case webAuth(url: String)
    /// >INFOMSG:CR_TEXT:flags:text: a challenge answered with cr-response.
    case crText(echo: Bool, text: String)
    /// >FATAL:text
    case fatal(String)
    /// >LOG:time,flags,text
    case log(String)
    /// >NEED-OK / >NEED-STR: OpenVPN waits on something AI Notch does not offer.
    case need(String)
    /// Anything else: a command's SUCCESS/ERROR, >INFO, >ECHO.
    case other

    public struct StaticChallenge: Equatable, Sendable, Codable {
        public var echo: Bool
        /// The response goes after the password as is, not as SCRV1.
        public var concatenate: Bool
        public var text: String

        public init(echo: Bool, concatenate: Bool, text: String) {
            self.echo = echo
            self.concatenate = concatenate
            self.text = text
        }
    }

    public struct DynamicChallenge: Equatable, Sendable, Codable {
        public var echo: Bool
        public var responseRequired: Bool
        public var stateId: String
        public var username: String
        public var text: String

        public init(echo: Bool, responseRequired: Bool, stateId: String, username: String, text: String) {
            self.echo = echo
            self.responseRequired = responseRequired
            self.stateId = stateId
            self.username = username
            self.text = text
        }
    }

    public static func parse(_ raw: String) -> MgmtEvent {
        let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
        guard line.hasPrefix(">"), let colon = line.firstIndex(of: ":") else { return .other }
        let kind = line[line.index(after: line.startIndex)..<colon]
        let body = String(line[line.index(after: colon)...])
        switch kind {
        case "STATE":
            let f = body.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            func at(_ i: Int) -> String { i < f.count ? f[i] : "" }
            return .state(name: at(1), detail: at(2), localIP: at(3), remoteIP: at(4), remotePort: at(5), localIPv6: at(8))
        case "BYTECOUNT":
            let f = body.split(separator: ",")
            guard f.count == 2, let received = Int64(f[0]), let sent = Int64(f[1]) else { return .other }
            return .bytes(received: received, sent: sent)
        case "HOLD":
            return .hold
        case "PASSWORD":
            return password(body)
        case "INFOMSG":
            if body.hasPrefix("WEB_AUTH:") {
                // WEB_AUTH:flags:url (the flags never hold a colon; the URL does).
                let rest = body.dropFirst("WEB_AUTH:".count)
                guard let sep = rest.firstIndex(of: ":") else { return .other }
                return .webAuth(url: String(rest[rest.index(after: sep)...]))
            }
            if body.hasPrefix("OPEN_URL:") { return .webAuth(url: String(body.dropFirst("OPEN_URL:".count))) }
            if body.hasPrefix("CR_TEXT:") {
                let rest = body.dropFirst("CR_TEXT:".count)
                guard let sep = rest.firstIndex(of: ":") else { return .other }
                let flags = rest[..<sep].split(separator: ",")
                return .crText(echo: flags.contains("E"), text: String(rest[rest.index(after: sep)...]))
            }
            return .other
        case "FATAL":
            return .fatal(body)
        case "LOG":
            let f = body.split(separator: ",", maxSplits: 2, omittingEmptySubsequences: false)
            return .log(f.count == 3 ? String(f[2]) : body)
        case "NEED-OK", "NEED-STR":
            return .need(body)
        default:
            return .other
        }
    }

    private static func password(_ body: String) -> MgmtEvent {
        if body.hasPrefix("Need 'Auth' username/password") {
            let rest = body.dropFirst("Need 'Auth' username/password".count).trimmingCharacters(in: .whitespaces)
            guard rest.hasPrefix("SC:") else { return .needAuth(usernameOnly: false, challenge: nil) }
            // SC:flags,text: bit 0 echo, bit 1 concatenate.
            let sc = rest.dropFirst(3)
            let comma = sc.firstIndex(of: ",") ?? sc.endIndex
            let flags = Int(sc[..<comma]) ?? 0
            let text = comma < sc.endIndex ? String(sc[sc.index(after: comma)...]) : ""
            return .needAuth(usernameOnly: false, challenge: StaticChallenge(echo: flags & 1 != 0, concatenate: flags & 2 != 0, text: text))
        }
        if body.hasPrefix("Need 'Auth' username") { return .needAuth(usernameOnly: true, challenge: nil) }
        if body.hasPrefix("Need 'Private Key' password") { return .needPrivateKey }
        if body.hasPrefix("Verification Failed: 'Private Key'") { return .privateKeyFailed }
        if body.hasPrefix("Verification Failed: ") {
            let rest = String(body.dropFirst("Verification Failed: ".count))
            // ['CRV1:flags:state_id:username_base64:text']
            if let start = rest.range(of: "['CRV1:"), rest.hasSuffix("']") {
                let inner = rest[start.upperBound..<rest.index(rest.endIndex, offsetBy: -2)]
                let parts = inner.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false)
                if parts.count == 4 {
                    let flags = parts[0].split(separator: ",")
                    let user = Data(base64Encoded: String(parts[2])).map { String(decoding: $0, as: UTF8.self) } ?? ""
                    return .authFailed(reason: nil, challenge: DynamicChallenge(echo: flags.contains("E"), responseRequired: flags.contains("R"),
                                                                                stateId: String(parts[1]), username: user, text: String(parts[3])))
                }
            }
            if rest == "'Auth'" { return .authFailed(reason: nil, challenge: nil) }
            let reason = rest.hasPrefix("'") && rest.hasSuffix("'") && rest.count >= 2 ? String(rest.dropFirst().dropLast()) : rest
            return .authFailed(reason: reason, challenge: nil)
        }
        // Auth-Token and the rest: never logged, nothing to do.
        return .other
    }
}

/// Commands to the management interface.
public enum Mgmt {
    /// A parameter in double quotes, `\` and `"` escaped (the config file's rules). Nil for a
    /// value no command line can carry: a line break or NUL would end the command and start
    /// another, so such a value is refused, never cleaned.
    public static func quote(_ value: String) -> String? {
        guard value.utf8.count <= 240, !value.utf8.contains(where: { $0 == 0x0A || $0 == 0x0D || $0 == 0 }) else { return nil }
        var out = "\""
        for c in value {
            if c == "\\" || c == "\"" { out.append("\\") }
            out.append(c)
        }
        return out + "\""
    }

    public static func base64(_ value: String) -> String { Data(value.utf8).base64EncodedString() }

    /// The lines that answer a username/password request, or nil when a value cannot be sent.
    public static func authAnswer(username: String, password: String, response: String?,
                                  challenge: MgmtEvent.StaticChallenge?, dynamic: MgmtEvent.DynamicChallenge?) -> [String]? {
        var user = username
        var secret = password
        if let dynamic {
            user = dynamic.username
            secret = "CRV1::\(dynamic.stateId)::\(response ?? "")"
        } else if let challenge {
            secret = challenge.concatenate ? password + (response ?? "") : "SCRV1:\(base64(password)):\(base64(response ?? ""))"
        }
        guard let u = quote(user), let p = quote(secret) else { return nil }
        return ["username \"Auth\" \(u)", "password \"Auth\" \(p)"]
    }
}
