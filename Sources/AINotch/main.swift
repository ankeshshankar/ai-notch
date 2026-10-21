import AppKit

/// A preview window for screenshots, never the app: it skips the one-copy check and the first-launch setup.
let isPreviewRun = CommandLine.arguments.contains("--preview") || CommandLine.arguments.contains("--setup-preview")
let showSetupNotification = Notification.Name("info.ankeshshiv.notch.show-setup")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = SessionStore()
    private let builds = BuildStore()
    private let prod = ProdStore()
    private let machine = MachineStore()
    private let vpn = VPNStore()
    private let reviews = ReviewStore()
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
            // `--focus prod|vpn`: opened at a section, as the grey Prod chip's click does.
            let focus = args.firstIndex(of: "--focus").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
            setup.show(focus: focus == "prod" ? .prod : focus == "vpn" ? .vpn : nil)
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
        builds.start()
        prod.start()
        machine.start()
        vpn.start()
        CommandsStore.shared.start()
        // Pull requests: notified through Notifier (locked screen only), a failed build Pipelines
        // already announced left out, and read less often while one of my pipelines runs.
        reviews.onEvents = { [weak reviews] events in reviews?.post(events) }
        reviews.pipelineNotified = { [weak builds] ref in builds?.hasNotified(ref) ?? false }
        builds.onMyPipelineRunning = { [weak reviews] running in reviews?.setMyPipelineRunning(running) }
        reviews.start()
        SetupWindowController.shared.builds = builds
        SetupWindowController.shared.prod = prod
        SetupWindowController.shared.machine = machine
        SetupWindowController.shared.vpn = vpn
        SetupWindowController.shared.reviews = reviews
        controller = NotchController(store: store, builds: builds, prod: prod, machine: machine, vpn: vpn, reviews: reviews)
        // Another copy opened while this one runs asks this one to show the window (see below).
        DistributedNotificationCenter.default().addObserver(forName: showSetupNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { SetupWindowController.shared.show() }
        }
        if firstLaunch { setup.show() } else if !args.contains("--preview") { setup.checkHookAtLaunch() }
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

// Dev checks of the pull-request data layer, never the app: `--pr-selfcheck`, `--pr-watch <s>`.
PullRequestDev.runIfAsked(CommandLine.arguments)

// Dev checks of the Datadog sign-in, never the app: `--datadog-auth <command>` (stub or probe).
DatadogAuthDev.runIfAsked(CommandLine.arguments)

// Dev check of Prod's alerts (snapshot diffing, grouping, flapping), never the app: `--prod-alerts-selfcheck`.
ProdAlertsCheck.runIfAsked(CommandLine.arguments)

// Dev checks of the build sources, never the app: a failure report as Copy failure copies it
// (`--eas-failure <build id>`, `--bitbucket-failure <ws/repo#n>`), one poll of a repository as
// the app reads it (`--bitbucket-runs <ws/repo>`), EAS over GraphQL against the CLI, timed
// (`--eas-compare -`), and the masking alone (`--redact <file>`).
if let index = CommandLine.arguments.firstIndex(where: { ["--eas-failure", "--bitbucket-failure", "--bitbucket-runs", "--bitbucket-watch", "--eas-compare", "--redact"].contains($0) }) {
    let flag = CommandLine.arguments[index]
    guard index + 1 < CommandLine.arguments.count else {
        FileHandle.standardError.write(Data("usage: AINotch \(flag) <argument>\n".utf8))
        exit(2)
    }
    let argument = CommandLine.arguments[index + 1]
    if flag == "--redact" {
        let text = (try? String(contentsOfFile: argument, encoding: .utf8)) ?? ""
        print(Redact.mask(text))
        exit(0)
    }
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        var text = ""
        if flag == "--bitbucket-watch" {
            // The poller as the app runs it, headless, for <seconds>: each snapshot it publishes.
            let seconds = Double(argument) ?? 60
            let started = Date()
            let source = BitbucketSource { snapshot in
                let t = Int(Date().timeIntervalSince(started))
                let active = snapshot.runs.filter { $0.state.isRunning }.count
                let waiting = snapshot.runs.filter { $0.state == .paused }.count
                FileHandle.standardError.write(Data("[\(t)s] status=\(snapshot.status?.text ?? "ok") runs=\(snapshot.runs.count) running=\(active) waiting=\(waiting) owner=\(snapshot.owner?.how ?? "-") requests: \(snapshot.requests.summary), 304s \(snapshot.notModified)\n".utf8))
            }
            await source.start()
            // CLAUDE_NOTCH_TEST_OPENS="70,90,140": the notch opens at those seconds (as the panel
            // does it) and closes 3 s later, to time the sweep on opening.
            let opens = (ProcessInfo.processInfo.environment["CLAUDE_NOTCH_TEST_OPENS"] ?? "").split(separator: ",").compactMap { Double($0) }
            if !opens.isEmpty {
                Task.detached {
                    for at in opens.sorted() {
                        let wait = at - Date().timeIntervalSince(started)
                        if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                        FileHandle.standardError.write(Data("[\(Int(Date().timeIntervalSince(started)))s] notch opened\n".utf8))
                        await source.setPanelOpen(true)
                        try? await Task.sleep(for: .seconds(3))
                        await source.setPanelOpen(false)
                    }
                }
            }
            try? await Task.sleep(for: .seconds(seconds))
            text = "after \(Int(seconds)) s: \(await source.debugCounts().summary)"
        } else if flag == "--eas-compare" {
            text = EASSource.debugCompare()
        } else if flag == "--bitbucket-runs", let slash = argument.firstIndex(of: "/") {
            let source = BitbucketSource { _ in }
            let repo = BitbucketRepo(workspace: String(argument[..<slash]), repo: String(argument[argument.index(after: slash)...]),
                                     path: BitbucketConfig.loadRepos().first { $0.key == argument }?.path)
            let runs = await source.debugFetch(repo)
            let owner = await source.debugOwner()
            let now = Date().timeIntervalSince1970
            var lines = ["owner: \(owner.map { "\($0.name ?? "?") \($0.uuid ?? "-") via \($0.how)" } ?? "none")"]
            for run in runs {
                let mine = owner?.owns(run) == true ? "mine" : "    "
                let wait = run.wait.map { " | \($0.detail)" } ?? ""
                let usual = run.usualDuration.map { " | usual \(shortDuration($0))" } ?? ""
                lines.append("#\(run.ref.number) \(mine) \(run.state.rawValue)\(run.stage.map { "/\($0)" } ?? "") stale=\(run.isStale(now: now)) fast=\(run.needsFastPoll(now: now)) | \(run.branch ?? "-")\(run.pullRequest.map { " PR #\($0)" } ?? "") | \(run.selectorKey) | \(run.trigger ?? "-") | \(run.creator ?? "-") | steps \(run.steps.count)\(wait)\(usual)")
            }
            lines.append("requests: \(await source.debugCounts().summary)")
            text = lines.joined(separator: "\n")
        } else if flag == "--eas-failure" {
            let id = argument
            let build = EASBuild(id: id, state: .failed, platform: "", createdAt: 0, url: EASBuild.pageURL(owner: EASConfig.settings?.account ?? "_", slug: EASConfig.settings?.slug ?? "_", id: id))
            text = await EASFailure.report(for: build, pipelineURL: nil)
        } else if let ref = PipelineRef.find(in: "bb:" + argument) {
            let source = BitbucketSource { _ in }
            let runs = await source.debugFetch(BitbucketRepo(workspace: ref.workspace, repo: ref.repo))
            FileHandle.standardError.write(Data("runs: \(runs.map { "#\($0.ref.number) \($0.state.rawValue) steps \($0.steps.count)" }.joined(separator: ", "))\n".utf8))
            text = await source.failureReport(for: ref.key, easURLs: [])
        }
        print(text)
        done.signal()
    }
    done.wait()
    exit(0)
}

// Dev checks of the machine guard, never the app: `--machine-selfcheck <fixtures.json>` runs the
// classifier and safety rules on saved process tables; `--machine-scan [seconds]` scans this Mac
// twice that far apart (CPU needs two) and prints each row: kind, pid, footprint, state, plan.
if let index = CommandLine.arguments.firstIndex(of: "--machine-selfcheck") {
    guard index + 1 < CommandLine.arguments.count else {
        FileHandle.standardError.write(Data("usage: AINotch --machine-selfcheck <fixtures.json>\n".utf8))
        exit(2)
    }
    exit(MachineSelfCheck.run(fixtures: CommandLine.arguments[index + 1]))
}
if let index = CommandLine.arguments.firstIndex(of: "--machine-scan") {
    let seconds = index + 1 < CommandLine.arguments.count ? Double(CommandLine.arguments[index + 1]) ?? 3 : 3
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        let source = MachineSource { _ in }
        _ = await source.debugLines()
        try? await Task.sleep(for: .seconds(seconds))
        print((await source.debugLines()).joined(separator: "\n"))
        if index + 2 < CommandLine.arguments.count, let count = Int(CommandLine.arguments[index + 2]) { print(await source.benchmark(count)) }
        done.signal()
    }
    done.wait()
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
