import Foundation

/// Where the VPN helper and its OpenVPN live once installed, and how the app reaches it. Every
/// path here is owned by root and writable only by root: the helper runs as root, so nothing it
/// runs or reads may be something the user (or anything running as the user) can swap.
public enum VPNPaths {
    public static let label = "info.ankeshshiv.notch.vpn"
    /// The helper, OpenVPN and its DNS script. OpenVPN is built with this as its script folder, so
    /// it finds `dns-updown` here by itself (see scripts/build-openvpn.sh).
    public static let installDir = "/Library/PrivilegedHelperTools/\(label)"
    public static let helper = "\(installDir)/ai-notch-vpnd"
    public static let openvpn = "\(installDir)/openvpn"
    public static let dnsScript = "\(installDir)/dns-updown"
    public static let plist = "/Library/LaunchDaemons/\(label).plist"
    /// The imported profiles (checked, then written by the helper) and their index.
    public static let dataDir = "/Library/Application Support/\(label)"
    public static let profilesDir = "\(dataDir)/profiles"
    public static let index = "\(dataDir)/profiles.json"
    /// The helper's and OpenVPN's output.
    public static let log = "/Library/Logs/\(label).log"
    /// The app's requests: anyone may connect, the helper answers only the user it was installed for.
    public static let controlSocket = "/var/run/\(label).sock"
    /// OpenVPN's management interface, in a folder only root can enter.
    public static let runDir = "/var/run/\(label)"
    public static let managementSocket = "\(runDir)/mgmt.sock"

    /// Inside AINotch.app, what Install copies from: the helper and OpenVPN (signed nested code),
    /// and OpenVPN's DNS script with its licences (resources).
    public static let bundleHelper = "Contents/Helpers/ai-notch-vpnd"
    public static let bundleOpenVPN = "Contents/Helpers/openvpn"
    public static let bundleDNSScript = "Contents/Resources/OpenVPN/dns-updown"
}

/// The helper's version. The app compares the installed helper's with the one it carries and
/// offers an update when they differ.
public enum VPNBuild {
    public static let version = "1"
    /// The OpenVPN release scripts/build-openvpn.sh builds.
    public static let openvpnVersion = "2.7.8"
}
