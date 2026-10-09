import AppKit

/// A preview window for screenshots, never the app: it skips the one-copy check and the first-launch setup.
let isPreviewRun = CommandLine.arguments.contains("--preview") || CommandLine.arguments.contains("--setup-preview")
let showSetupNotification = Notification.Name("info.ankeshshiv.notch.show-setup")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = SessionStore()
    private var controller: NotchController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The panel follows the system's appearance, live. `--preview --theme light|dark` (or
        // `--setup-preview`) forces one for screenshots.
        let args = CommandLine.arguments
        if isPreviewRun, let i = args.firstIndex(of: "--theme"), i + 1 < args.count {
            NSApp.appearance = NSAppearance(named: args[i + 1] == "light" ? .aqua : .darkAqua)
        }
        let setup = SetupWindowController.shared
        // `--setup-preview`: the setup window alone (no notch, no socket), for screenshots; with
        // CLAUDE_NOTCH_SETUP_HOME it reads and writes a copy of a home folder.
        if args.contains("--setup-preview") {
            setup.quitsOnClose = true
            setup.show()
            // Its number and frame once SwiftUI has laid it out, for `screencapture -l` and clicks.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                guard let info = setup.windowInfo else { return }
                FileHandle.standardError.write(Data("setup-window \(info.number) \(Int(info.frame.minX)) \(Int(info.frame.minY)) \(Int(info.frame.width)) \(Int(info.frame.height))\n".utf8))
            }
            return
        }
        let firstLaunch = !args.contains("--preview") && setup.shouldShowAtLaunch()
        // A copy not set up yet asks for notifications from Set Up, not on its first launch.
        Notifier.shared.asksAtLaunch = !firstLaunch
        store.start()
        controller = NotchController(store: store)
        // Another copy opened while this one runs asks this one to show the window (see below).
        DistributedNotificationCenter.default().addObserver(forName: showSetupNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { SetupWindowController.shared.show() }
        }
        if firstLaunch { setup.show() }
    }

    /// Opening the app again (Finder, Spotlight, `open`) shows the setup window: the app has no
    /// other window or Dock icon.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !isPreviewRun { SetupWindowController.shared.show() }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Hooks still waiting see the socket close and leave the prompt to the editor.
        store.approvals.stop()
    }

    /// A widget row's link.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "ainotch" { store.open(url) }
    }
}

if let index = CommandLine.arguments.firstIndex(of: "--scan-usage"), index + 1 < CommandLine.arguments.count {
    UsageScanner.scanOnce(ledger: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
    exit(0)
}

// A dev check, never the app: without a path it says so and stops.
if let index = CommandLine.arguments.firstIndex(of: "--chat-title") {
    guard index + 1 < CommandLine.arguments.count, !CommandLine.arguments[index + 1].isEmpty else {
        FileHandle.standardError.write(Data("usage: AINotch --chat-title <transcript.jsonl>\n".utf8))
        exit(2)
    }
    ChatTitles.printTitles(of: CommandLine.arguments[index + 1])
    exit(0)
}

// The setup logic without the window, for tests against a copy of a home folder
// (CLAUDE_NOTCH_SETUP_HOME): `--setup-cli status|apply|disconnect`.
if let index = CommandLine.arguments.firstIndex(of: "--setup-cli") {
    let command = index + 1 < CommandLine.arguments.count ? CommandLine.arguments[index + 1] : ""
    exit(MainActor.assumeIsolated { Setup.runCLI(command) })
}

// One copy at a time: a second launch (from a disk image, another folder, or a login item beside
// a copy started by hand) asks the running one to show its setup window, then leaves. A clean
// exit, so the login item does not restart it.
if !isPreviewRun, let bundleId = Bundle.main.bundleIdentifier,
   NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).contains(where: { $0.processIdentifier != getpid() }) {
    DistributedNotificationCenter.default().postNotificationName(showSetupNotification, object: nil, userInfo: nil, deliverImmediately: true)
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
