import Foundation
import VPNCore

/// `ai-notch-vpnd selfcheck`: the profile check and the management parser on fixed cases,
/// above all the ones that must be refused. Prints each failure; exits 1 if any.
enum SelfCheck {
    private static let pem = "<ca>\n-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n</ca>\n"

    private static let accepted: [(String, String)] = [
        ("plain client", "client\ndev tun\nproto udp\nremote vpn.example.com 1194\nresolv-retry infinite\nnobind\npersist-key\npersist-tun\nremote-cert-tls server\ncipher AES-256-GCM\nauth-user-pass\n" + pem),
        ("comments, blank lines, CRLF", "# a comment with ü\n; another\n\nclient\r\nremote a.example.com 443 tcp\r\n" + pem),
        ("double dash", "--client\n--remote a.example.com\n" + pem),
        ("connection blocks", "client\n<connection>\nremote a.example.com 1194 udp\n</connection>\n<connection>\nremote b.example.com 443 tcp\n</connection>\n" + pem),
        ("windows-only left out", "client\nremote a.example.com\nblock-outside-dns\nsetenv opt block-outside-dns\nregister-dns\n" + pem),
        ("access server style", "client\nremote a.example.com 1194 udp\nsetenv FORWARD_COMPATIBLE 1\nsetenv UV_ID abc\nsetenv PUSH_PEER_INFO\nstatic-challenge \"Enter OTP\" 1\nauth-user-pass\ndhcp-option DNS 10.0.0.1\ndns server 1 address 10.0.0.2\nverb 3\n" + pem + "<tls-crypt>\nkey\n</tls-crypt>\nkey-direction 1\n"),
        ("quoted parameters", "client\nremote a.example.com\nverify-x509-name \"C=US, O=Example, CN=vpn\" subject\n" + pem),
        ("byte order mark", "\u{FEFF}client\nremote a.example.com\n" + pem),
        ("inline user and password", "client\nremote a.example.com\n<auth-user-pass>\nme\nsecret\n</auth-user-pass>\n" + pem),
    ]

    private static let refused: [(String, String)] = [
        ("up script", "client\nremote a\nup /tmp/x.sh\n"),
        ("up with double dash", "client\nremote a\n--up /tmp/x.sh\n"),
        ("quoted directive", "client\nremote a\n\"up\" /tmp/x.sh\n"),
        ("escaped directive", "client\nremote a\nu\\p /tmp/x.sh\n"),
        ("setenv opt hides a script", "client\nremote a\nsetenv opt up /tmp/x.sh\n"),
        ("plugin", "client\nremote a\nplugin /tmp/x.so\n"),
        ("route-up", "client\nremote a\nroute-up /tmp/x\n"),
        ("script-security", "client\nremote a\nscript-security 2\n"),
        ("ca by path", "client\nremote a\nca /etc/master.passwd\n"),
        ("auth-user-pass file", "client\nremote a\nauth-user-pass /etc/sudoers\n"),
        ("log file", "client\nremote a\nlog /etc/sudoers\n"),
        ("config include", "client\nremote a\nconfig /tmp/other.ovpn\n"),
        ("engine", "client\nremote a\nengine dynamic\n"),
        ("providers", "client\nremote a\nproviders legacy default\n"),
        ("dns-updown", "client\nremote a\ndns-updown /tmp/x\n"),
        ("management", "client\nremote a\nmanagement 0.0.0.0 7505\n"),
        ("unknown directive", "client\nremote a\nfrobnicate\n"),
        ("long line splits", "client\nremote a\n# " + String(repeating: "x", count: 260) + "up /tmp/x\n"),
        ("inline up block", "client\nremote a\n<up>\n/tmp/x\n</up>\n"),
        ("inline with double dash", "client\nremote a\n--<up>\n/tmp/x\n</up>\n"),
        ("script inside connection", "client\n<connection>\nremote a\nup /tmp/x\n</connection>\n"),
        ("unclosed inline", "client\nremote a\n<ca>\nxx\n"),
        ("text after close tag", "client\nremote a\n<ca>\nxx\n</ca> up /tmp/x\n"),
        ("tap device", "client\nremote a\ndev tap\n"),
        ("NUL byte", "client\nremote a\0\n"),
        ("no remote", "client\n" + pem),
        ("unclosed quote", "client\nremote \"a\n"),
        ("bad backslash", "client\nremote a\\x\n"),
        ("setenv BASH_ENV", "client\nremote a\nsetenv BASH_ENV /tmp/x\n"),
        ("setenv DYLD", "client\nremote a\nsetenv DYLD_INSERT_LIBRARIES /tmp/x\n"),
        ("dhcp-option injection", "client\nremote a\ndhcp-option DOMAIN \"a\\\\nset State:/x\"\n"),
        ("http-proxy auth file", "client\nremote a\nhttp-proxy p 8080 /etc/passwd\n"),
        ("dev-node", "client\nremote a\ndev-node /dev/x\n"),
        ("user", "client\nremote a\nuser nobody\n"),
    ]

    static func run() -> Int32 {
        var failures = 0
        func fail(_ text: String) {
            failures += 1
            print("FAIL \(text)")
        }

        for (name, text) in accepted {
            switch OVPNProfile.check(Data(text.utf8)) {
            case .success(let profile):
                if name == "windows-only left out" {
                    if profile.dropped.count != 3 { fail("\(name): left out \(profile.dropped.count) lines, not 3") }
                    if profile.text.contains("block-outside-dns") { fail("\(name): block-outside-dns kept") }
                }
                if name == "connection blocks", profile.servers != ["a.example.com:1194/udp", "b.example.com:443/tcp"] {
                    fail("\(name): servers \(profile.servers)")
                }
                if name == "access server style", !profile.asksPassword { fail("\(name): asks for no password") }
                if name == "byte order mark", profile.text.hasPrefix("\u{FEFF}") { fail("\(name): BOM kept") }
            case .failure(let problem):
                fail("\(name) refused: \(problem)")
            }
        }
        for (name, text) in refused {
            if case .success = OVPNProfile.check(Data(text.utf8)) { fail("\(name) accepted") }
        }

        // The tokenizer against what OpenVPN reads.
        let tokenCases: [(String, [String]?)] = [
            ("remote a 1194", ["remote", "a", "1194"]),
            ("  remote   a  # comment", ["remote", "a"]),
            ("verify-x509-name \"a b\" name", ["verify-x509-name", "a b", "name"]),
            ("x 'a\\b'", ["x", "a\\b"]),
            ("x a\\ b", ["x", "a b"]),
            ("x a#b", ["x", "a#b"]),
            ("x \"a", nil),
            ("x a\\q", nil),
        ]
        for (line, expected) in tokenCases {
            let got = try? OVPNProfile.tokens(line)
            if got != expected { fail("tokens of \(line): \(got.map { "\($0)" } ?? "error"), expected \(expected.map { "\($0)" } ?? "error")") }
        }

        // The management interface.
        let events: [(String, MgmtEvent)] = [
            (">STATE:1700000000,CONNECTED,SUCCESS,10.8.0.2,203.0.113.5,1194,,,fd00::2",
             .state(name: "CONNECTED", detail: "SUCCESS", localIP: "10.8.0.2", remoteIP: "203.0.113.5", remotePort: "1194", localIPv6: "fd00::2")),
            (">BYTECOUNT:1024,2048", .bytes(received: 1024, sent: 2048)),
            (">HOLD:Waiting for hold release:0", .hold),
            (">PASSWORD:Need 'Auth' username/password", .needAuth(usernameOnly: false, challenge: nil)),
            (">PASSWORD:Need 'Auth' username/password SC:1,Enter PIN",
             .needAuth(usernameOnly: false, challenge: .init(echo: true, concatenate: false, text: "Enter PIN"))),
            (">PASSWORD:Need 'Auth' username", .needAuth(usernameOnly: true, challenge: nil)),
            (">PASSWORD:Need 'Private Key' password", .needPrivateKey),
            (">PASSWORD:Verification Failed: 'Auth'", .authFailed(reason: nil, challenge: nil)),
            (">PASSWORD:Verification Failed: 'Account locked'", .authFailed(reason: "Account locked", challenge: nil)),
            (">PASSWORD:Verification Failed: 'Auth' ['CRV1:R,E:Om01u7Fh4LrGBS7uh0SWmzwabUiGiW6l:Y3Ix:Please enter token PIN']",
             .authFailed(reason: nil, challenge: .init(echo: true, responseRequired: true, stateId: "Om01u7Fh4LrGBS7uh0SWmzwabUiGiW6l", username: "cr1", text: "Please enter token PIN"))),
            (">INFOMSG:WEB_AUTH::https://sso.example.com/a?b=c", .webAuth(url: "https://sso.example.com/a?b=c")),
            (">INFOMSG:OPEN_URL:https://sso.example.com/x", .webAuth(url: "https://sso.example.com/x")),
            (">INFOMSG:CR_TEXT:R,E:Enter code", .crText(echo: true, text: "Enter code")),
            (">FATAL:Cannot resolve host", .fatal("Cannot resolve host")),
            (">LOG:1700000000,I,Initialization Sequence Completed", .log("Initialization Sequence Completed")),
            ("SUCCESS: hold release succeeded", .other),
        ]
        for (line, expected) in events {
            let got = MgmtEvent.parse(line)
            if got != expected { fail("parse \(line): \(got)") }
        }

        // Answers: escaped, and never a line break.
        if Mgmt.quote("a\"b\\c") != "\"a\\\"b\\\\c\"" { fail("quote escaping: \(Mgmt.quote("a\"b\\c") ?? "nil")") }
        if Mgmt.quote("a\nsignal SIGTERM") != nil { fail("quote let a line break through") }
        if Mgmt.authAnswer(username: "u", password: "p\r", response: nil, challenge: nil, dynamic: nil) != nil { fail("authAnswer let a CR through") }
        let sc = Mgmt.authAnswer(username: "u", password: "pw", response: "123", challenge: .init(echo: false, concatenate: false, text: "OTP"), dynamic: nil)
        if sc != ["username \"Auth\" \"u\"", "password \"Auth\" \"SCRV1:cHc=:MTIz\""] { fail("static challenge answer: \(sc ?? [])") }
        let crv1 = Mgmt.authAnswer(username: "", password: "", response: "8675309", challenge: nil,
                                   dynamic: .init(echo: false, responseRequired: true, stateId: "Om01", username: "cr1", text: "PIN"))
        if crv1 != ["username \"Auth\" \"cr1\"", "password \"Auth\" \"CRV1::Om01::8675309\""] { fail("dynamic challenge answer: \(crv1 ?? [])") }

        print(failures == 0 ? "selfcheck: all \(accepted.count + refused.count + tokenCases.count + events.count + 5) cases pass" : "selfcheck: \(failures) failure(s)")
        return failures == 0 ? 0 : 1
    }
}
