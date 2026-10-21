// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AINotch",
    platforms: [.macOS(.v15)],
    targets: [
        // The session-state model both executables share.
        .target(name: "NotchCore"),
        // Run by Claude Code and Cursor hooks: folds one hook event into the session's state file.
        .executableTarget(name: "ai-notch-hook", dependencies: ["NotchCore"]),
        // What the VPN helper and the app share: profile checks, the management protocol, the socket.
        .target(name: "VPNCore"),
        // The VPN helper: runs as root (a launch daemon), checks profiles and runs OpenVPN for the app.
        .executableTarget(name: "ai-notch-vpnd", dependencies: ["VPNCore"]),
        // The notch app: reads the state files and draws them under the notch.
        .executableTarget(name: "AINotch", dependencies: ["NotchCore", "VPNCore"], linkerSettings: [.linkedLibrary("sqlite3")]),
    ],
    swiftLanguageModes: [.v5]
)
