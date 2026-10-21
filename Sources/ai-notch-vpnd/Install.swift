import Foundation
import VPNCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Install and uninstall, run as root through the admin prompt the app shows (AppleScript's
/// `do shell script … with administrator privileges`). Install copies the helper, OpenVPN and
/// its DNS script out of the app into a folder only root can write, so what runs as root is
/// never a file in the user's Applications folder, and starts the launch daemon.
enum Installer {
    private static let files = ["ai-notch-vpnd", "openvpn", "dns-updown"]

    /// `bundle` is AINotch.app; the files come from where VPNPaths says it carries them.
    static func install(uid: uid_t, bundle: String) -> Int32 {
        guard geteuid() == 0 else { return fail("install must run as root") }
        let sources = [bundle + "/" + VPNPaths.bundleHelper, bundle + "/" + VPNPaths.bundleOpenVPN, bundle + "/" + VPNPaths.bundleDNSScript]
        for path in sources {
            var st = stat()
            guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
                return fail("\(path) is missing (a build without the VPN engine; see scripts/build-openvpn.sh)")
            }
        }
        // A running helper stops first (it stops OpenVPN).
        _ = run("/bin/launchctl", ["bootout", "system/\(VPNPaths.label)"])
        do {
            if !FileManager.default.fileExists(atPath: "/Library/PrivilegedHelperTools") {
                try Files.secureDir("/Library/PrivilegedHelperTools", mode: 0o755)
            }
            try Files.secureDir(VPNPaths.installDir, mode: 0o755)
            for (name, path) in zip(files, sources) {
                // Copied as bytes: no extended attributes (the download's quarantine) come along.
                guard let data = FileManager.default.contents(atPath: path) else { return fail("cannot read \(path)") }
                try Files.write(data, to: "\(VPNPaths.installDir)/\(name)", mode: 0o755)
            }
            try Files.secureDir(VPNPaths.dataDir, mode: 0o700)
            try Files.secureDir(VPNPaths.profilesDir, mode: 0o700)
            let plist: [String: Any] = [
                "Label": VPNPaths.label,
                "ProgramArguments": [VPNPaths.helper, "serve", "--uid", String(uid)],
                "RunAtLoad": true,
                "KeepAlive": true,
                "StandardErrorPath": VPNPaths.log,
                "StandardOutPath": VPNPaths.log,
                "ProcessType": "Interactive",
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try Files.write(data, to: VPNPaths.plist, mode: 0o644)
        } catch {
            return fail("\(error)")
        }
        let status = run("/bin/launchctl", ["bootstrap", "system", VPNPaths.plist])
        guard status == 0 else { return fail("launchctl bootstrap exited \(status)") }
        print("installed the VPN helper \(VPNBuild.version) for uid \(uid)")
        return 0
    }

    static func uninstall(keepProfiles: Bool) -> Int32 {
        guard geteuid() == 0 else { return fail("uninstall must run as root") }
        _ = run("/bin/launchctl", ["bootout", "system/\(VPNPaths.label)"])
        unlink(VPNPaths.plist)
        unlink(VPNPaths.controlSocket)
        for name in files { unlink("\(VPNPaths.installDir)/\(name)") }
        rmdir(VPNPaths.installDir)
        unlink(VPNPaths.managementSocket)
        rmdir(VPNPaths.runDir)
        if !keepProfiles {
            try? FileManager.default.removeItem(atPath: VPNPaths.dataDir)
            unlink(VPNPaths.log)
        }
        print("removed the VPN helper\(keepProfiles ? " (profiles kept)" : "")")
        return 0
    }

    private static func run(_ path: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return -1
        }
        process.waitUntilExit()
        return process.terminationStatus
    }

    private static func fail(_ text: String) -> Int32 {
        FileHandle.standardError.write(Data("ai-notch-vpnd: \(text)\n".utf8))
        return 1
    }
}
