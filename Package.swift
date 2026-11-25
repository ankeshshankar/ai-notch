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
        // Dictation's logic without the UI: the clean-up rules, the Claude request and reply, the
        // hotkey gestures, the pasteboard round trip. Unit-tested (`swift test`).
        .target(name: "DictationCore"),
        .testTarget(name: "DictationCoreTests", dependencies: ["DictationCore"]),
        // The automatic review's logic without the UI: verdict parsing, the ledger that dedupes runs,
        // the approve gate, the headless command. Unit-tested (`swift test`).
        .target(name: "ReviewCore"),
        .testTarget(name: "ReviewCoreTests", dependencies: ["ReviewCore"]),
        // The notch app: reads the state files and draws them under the notch.
        .executableTarget(name: "AINotch", dependencies: ["NotchCore", "VPNCore", "DictationCore", "ReviewCore"], linkerSettings: [.linkedLibrary("sqlite3")]),
    ],
    swiftLanguageModes: [.v5]
)
