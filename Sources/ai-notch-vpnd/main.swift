import Foundation
import VPNCore

// AI Notch's VPN helper. As a launch daemon (root): `serve --uid <uid>`. Through the app's admin
// prompt: `install --uid <uid>` (from the app's copy) and `uninstall [--keep-profiles]`. Dev
// checks, never root: `check <file.ovpn>` prints what the helper would keep or refuse;
// `selfcheck` runs the profile and management parsers on fixed cases.

let args = CommandLine.arguments

func value(after flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func usage() -> Never {
    FileHandle.standardError.write(Data("usage: ai-notch-vpnd serve --uid <uid> | install --uid <uid> | uninstall [--keep-profiles] | check <file.ovpn> | selfcheck | version\n".utf8))
    exit(2)
}

switch args.count > 1 ? args[1] : "" {
case "serve":
    guard let uid = value(after: "--uid").flatMap({ UInt32($0) }) else { usage() }
    Daemon(allowedUID: uid).serve()
case "install":
    guard let uid = value(after: "--uid").flatMap({ UInt32($0) }), args[0].hasPrefix("/") else { usage() }
    // Run from the app's copy, Contents/Helpers/ai-notch-vpnd: the app holds the files to copy.
    let bundle = URL(fileURLWithPath: args[0]).resolvingSymlinksInPath()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
    exit(Installer.install(uid: uid, bundle: bundle))
case "uninstall":
    exit(Installer.uninstall(keepProfiles: args.contains("--keep-profiles")))
case "check":
    guard args.count > 2, let data = FileManager.default.contents(atPath: args[2]) else { usage() }
    switch OVPNProfile.check(data) {
    case .success(let profile):
        print("ok: \(profile.servers.joined(separator: ", "))\(profile.asksPassword ? ", asks for a password" : "")")
        for line in profile.dropped { print("left out \(line)") }
        exit(0)
    case .failure(let problem):
        print("refused: \(problem)")
        exit(1)
    }
case "selfcheck":
    exit(SelfCheck.run())
case "version":
    print("\(VPNBuild.version) (OpenVPN \(VPNBuild.openvpnVersion))")
default:
    usage()
}
