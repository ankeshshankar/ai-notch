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
        // The notch app: reads the state files and draws them under the notch.
        .executableTarget(name: "AINotch", dependencies: ["NotchCore"], linkerSettings: [.linkedLibrary("sqlite3")]),
    ],
    swiftLanguageModes: [.v5]
)
