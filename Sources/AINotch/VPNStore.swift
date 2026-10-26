import AppKit
import Foundation
import UniformTypeIdentifiers
import VPNCore

/// The VPN for the notch: the footer's VPN chip, the VPN panel, the sign-in window, the wing's
/// "dropped" mark and its notification. OpenVPN runs in AI Notch's helper (`ai-notch-vpnd`, a
/// launch daemon installed once with an admin password); this asks it over its socket, off the
/// main thread, and publishes only what changes.
@MainActor
final class VPNStore: ObservableObject {
    enum Helper: Equatable {
        case unknown
        /// No launch daemon: Setup offers Install.
        case notInstalled
        /// Installed, but its socket does not answer (starting, or stopped).
        case notRunning
        case running
    }

    @Published private(set) var helper: Helper = .unknown
    @Published private(set) var status: VPNStatus?
    /// Setup's switch: off, the chip and the panel do not show (a connection keeps running).
    @Published private(set) var isOn: Bool
    @Published private(set) var notifyDrop: Bool
    /// A connection that was up ended without Disconnect, not seen yet: the wing's slot.
    @Published private(set) var unseenDrop = false
    /// Install, Remove, Import running: what it is doing.
    @Published private(set) var working: String?
    /// The last action's result or error, for a few seconds.
    @Published private(set) var note: String?
    /// OpenVPN's last lines, when asked for (the panel's Log).
    @Published private(set) var log: [String] = []
    /// The helper answers but refuses (installed for another user on this Mac).
    @Published private(set) var helperError: String?

    private static let enabledKey = "vpn.enabled"
    private static let notifyKey = "vpn.notifyDrop"
    static let keychainService = "info.ankeshshiv.notch.vpn"
    private var panelOpen = false
    private var timer: Timer?
    private var asking = false
    private var nextAsk = Date.distantPast
    /// The prompt last acted on, so each is handled once.
    private var handledPrompt = -1
    /// Saved credentials are tried once per connect; a refusal asks.
    private var autoAnswered: Set<String> = []
    private var seenEnd: Double = 0
    private var noteWork: DispatchWorkItem?
    /// Opens the notch on the VPN panel (a notification's Open).
    var reveal: (() -> Void)?

    init() {
        let defaults = UserDefaults.standard
        isOn = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        notifyDrop = defaults.object(forKey: Self.notifyKey) as? Bool ?? true
    }

    func start() {
        Notifier.shared.onVPN = { [weak self] in self?.reveal?() }
        guard timer == nil else { return }
        // A slow tick that asks the helper when the interval has passed (or at once after poke).
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        tick()
    }

    private func tick() {
        guard !asking, Date() >= nextAsk else { return }
        asking = true
        Task {
            await refresh()
            asking = false
            nextAsk = Date().addingTimeInterval(interval)
        }
    }

    /// Asks again now (after an action, the panel opening).
    private func poke() {
        nextAsk = .distantPast
        tick()
    }

    /// How soon to ask again: every second while connecting or asking, 2 s with the panel open,
    /// 5 s while connected, else 15 s (30 s without a helper).
    private var interval: Double {
        guard helper == .running else { return helper == .notRunning ? 5 : 30 }
        if let session = status?.session, session.phase != .connected { return 1 }
        if panelOpen { return 2 }
        return status?.session != nil ? 5 : 15
    }

    func setPanelOpen(_ open: Bool) {
        guard open != panelOpen else { return }
        panelOpen = open
        if open {
            if unseenDrop { unseenDrop = false }
            poke()
        }
    }

    func setEnabled(_ on: Bool) {
        isOn = on
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        if !on { unseenDrop = false }
    }

    func setNotify(_ on: Bool) {
        notifyDrop = on
        UserDefaults.standard.set(on, forKey: Self.notifyKey)
    }

    // MARK: What shows

    /// The chip shows once the helper is installed (or a build carries it and Setup is on).
    var showsChip: Bool { isOn && (helper == .running || helper == .notRunning) }
    var showsSlot: Bool { isOn && unseenDrop }
    var profiles: [VPNProfileInfo] { status?.profiles ?? [] }
    var session: VPNSession? { status?.session }

    func profile(_ id: String?) -> VPNProfileInfo? { profiles.first { $0.id == id } }

    /// This build carries the helper and OpenVPN (scripts/build-openvpn.sh ran before assembling).
    static var bundledHelper: URL { Bundle.main.bundleURL.appendingPathComponent(VPNPaths.bundleHelper) }
    static var hasBundledEngine: Bool {
        [VPNPaths.bundleHelper, VPNPaths.bundleOpenVPN, VPNPaths.bundleDNSScript].allSatisfy {
            FileManager.default.fileExists(atPath: Bundle.main.bundleURL.appendingPathComponent($0).path)
        }
    }

    /// The installed helper is another version than the one this app carries.
    var needsUpdate: Bool {
        guard let version = status?.version else { return false }
        return version != VPNBuild.version && Self.hasBundledEngine
    }

    enum Level { case off, busy, connected, problem }

    var level: Level {
        guard helper == .running else { return helper == .notRunning ? .problem : .off }
        if let session {
            if session.phase == .connected { return .connected }
            return session.problem != nil ? .problem : .busy
        }
        if let end = status?.lastEnd, !end.byUser, end.reason != nil { return .problem }
        return .off
    }

    /// The chip's words: "Work" connected, "Connecting", "Off".
    var chipText: String {
        if helper == .notRunning { return "VPN —" }
        if let session {
            let name = profile(session.profileId)?.name ?? "VPN"
            return session.phase == .connected ? name : session.prompt != nil ? "Sign in" : session.phase == .exiting ? "Disconnecting" : "Connecting"
        }
        return "VPN off"
    }

    static func bytes(_ count: Int64) -> String {
        let value = Double(count)
        if value < 1024 { return "\(count) B" }
        if value < 1024 * 1024 { return String(format: "%.0f KB", value / 1024) }
        if value < 1024 * 1024 * 1024 { return String(format: "%.1f MB", value / 1024 / 1024) }
        return String(format: "%.2f GB", value / 1024 / 1024 / 1024)
    }

    // MARK: Asking the helper

    private func refresh() async {
        guard FileManager.default.fileExists(atPath: VPNPaths.plist) else {
            set(helper: .notInstalled)
            if status != nil { status = nil }
            return
        }
        switch await VPNClient.send(VPNRequest(.status)) {
        case .reply(let reply):
            set(helper: .running)
            if let next = reply.status { take(next) }
            let problem = reply.ok ? nil : reply.error
            if helperError != problem { helperError = problem }
        case .notRunning:
            set(helper: .notRunning)
        case .failed:
            set(helper: .notRunning)
        }
    }

    private func set(helper next: Helper) {
        if helper != next { helper = next }
    }

    private func take(_ next: VPNStatus) {
        if next != status { status = next }
        // A connection that was up and ended without Disconnect.
        if let end = next.lastEnd, end.at > seenEnd {
            if seenEnd > 0, !end.byUser, end.wasConnected {
                if isOn, !panelOpen { unseenDrop = true }
                noteBuildLog("vpn: connection dropped")
                if notifyDrop {
                    Notifier.shared.postVPN(title: "VPN disconnected", subtitle: profile(end.profileId)?.name ?? "VPN",
                                            body: end.reason ?? "The connection ended. Open shows the VPN panel.")
                }
            }
            seenEnd = end.at
        } else if seenEnd == 0 {
            seenEnd = next.lastEnd?.at ?? 1
        }
        guard let session = next.session else {
            VPNSignInController.shared.close()
            return
        }
        if session.phase == .connected { autoAnswered.remove(session.profileId) }
        guard let prompt = session.prompt else {
            VPNSignInController.shared.close()
            return
        }
        guard prompt.id != handledPrompt else { return }
        handledPrompt = prompt.id
        handle(prompt, session: session)
    }

    /// A new prompt: saved credentials answer a plain password request once; a sign-in page
    /// opens in the browser; anything else asks in the sign-in window.
    private func handle(_ prompt: VPNPrompt, session: VPNSession) {
        let profileId = session.profileId
        switch prompt.kind {
        case .webAuth:
            if let text = prompt.url, let url = URL(string: text), ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(url)
                show(note: "Sign-in page opened in your browser")
            }
        case .password where prompt.text == nil && prompt.failure == nil && !autoAnswered.contains(profileId):
            if let saved = Self.saved(profileId) {
                autoAnswered.insert(profileId)
                Task { await self.answer(prompt, username: saved.username, password: saved.password, response: nil, remember: nil) }
                return
            }
            VPNSignInController.shared.show(prompt: prompt, profile: profile(profileId), store: self)
        default:
            VPNSignInController.shared.show(prompt: prompt, profile: profile(profileId), store: self)
        }
    }

    // MARK: Actions

    func connect(_ id: String) {
        autoAnswered.remove(id)
        run(VPNRequest(.connect, id: id))
    }

    func disconnect() {
        VPNSignInController.shared.close()
        run(VPNRequest(.disconnect))
    }

    func delete(_ id: String) {
        Self.forget(id)
        run(VPNRequest(.delete, id: id))
    }

    func rename(_ id: String, to name: String) {
        run(VPNRequest(.rename, id: id, name: name))
    }

    /// The sign-in window's answer; `remember` saves (true) or forgets (false) the password.
    func answer(_ prompt: VPNPrompt, username: String, password: String, response: String?, remember: Bool?) async {
        guard let profileId = session?.profileId else { return }
        if prompt.kind == .password || prompt.kind == .usernameOnly {
            UserDefaults.standard.set(username, forKey: "vpn.username.\(profileId)")
        }
        if prompt.kind == .password, let remember {
            if remember { Self.save(profileId, password: password) } else { Self.forget(profileId) }
        }
        let request = VPNRequest(.answer, prompt: prompt.id, username: username, password: password, response: response)
        if case .reply(let reply) = await VPNClient.send(request), !reply.ok {
            show(note: reply.error ?? "Not taken")
        }
        poke()
    }

    func loadLog() {
        Task {
            if case .reply(let reply) = await VPNClient.send(VPNRequest(.log)) { log = reply.log ?? [] }
        }
    }

    private func run(_ request: VPNRequest) {
        Task {
            switch await VPNClient.send(request) {
            case .reply(let reply):
                if let next = reply.status { take(next) }
                if !reply.ok { show(note: reply.error ?? "Failed") }
            case .notRunning:
                show(note: "The VPN helper is not running")
            case .failed(let why):
                show(note: why)
            }
            poke()
        }
    }

    /// Choose an .ovpn file and hand it to the helper, which checks it and keeps a copy.
    func importProfile() {
        let panel = NSOpenPanel()
        panel.title = "Import an OpenVPN profile"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = ["ovpn", "conf"].compactMap { UTType(filenameExtension: $0) } + [.plainText]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModalAboveNotch({ panel.runModal() }) == .OK, let url = panel.url else { return }
        importProfile(at: url)
    }

    func importProfile(at url: URL) {
        guard let data = try? Data(contentsOf: url), data.count <= OVPNProfile.maxBytes else {
            show(note: "Could not read the file (or it is over 512 KB)")
            return
        }
        // Checked here first for a quick answer; the helper checks again, and its check counts.
        if case .failure(let problem) = OVPNProfile.check(data) {
            show(note: "Not imported. \(problem)")
            return
        }
        let name = url.deletingPathExtension().lastPathComponent
        working = "Importing…"
        Task {
            let outcome = await VPNClient.send(VPNRequest(.importProfile, name: name, config: String(decoding: data, as: UTF8.self)), timeout: 10)
            working = nil
            switch outcome {
            case .reply(let reply):
                if let next = reply.status { take(next) }
                if reply.ok {
                    let dropped = reply.dropped ?? []
                    show(note: "Imported \(name)" + (dropped.isEmpty ? "" : " · left out \(dropped.count) Windows-only line\(dropped.count == 1 ? "" : "s")"))
                } else {
                    show(note: "Not imported. \(reply.error ?? "")")
                }
            case .notRunning:
                show(note: "The VPN helper is not running")
            case .failed(let why):
                show(note: why)
            }
        }
    }

    // MARK: Installing the helper

    /// Install (or update): one admin prompt, then the helper copies itself, OpenVPN and its DNS
    /// script to /Library/PrivilegedHelperTools and starts as a launch daemon.
    func install() {
        guard Self.hasBundledEngine else {
            show(note: "This build has no VPN engine (see the README)")
            return
        }
        let command = Self.shellQuote(Self.bundledHelper.path) + " install --uid \(getuid())"
        admin(command, prompt: "AI Notch wants to install its VPN helper, which runs OpenVPN.", doing: "Installing…", done: "VPN helper installed")
    }

    /// Remove: the helper, OpenVPN and (unless kept) the imported profiles.
    func uninstall(keepProfiles: Bool) {
        disconnect()
        let command = Self.shellQuote(VPNPaths.helper) + " uninstall" + (keepProfiles ? " --keep-profiles" : "")
        admin(command, prompt: "AI Notch wants to remove its VPN helper.", doing: "Removing…", done: "VPN helper removed")
        if !keepProfiles { for profile in profiles { Self.forget(profile.id) } }
    }

    private func admin(_ command: String, prompt: String, doing: String, done: String) {
        working = doing
        Task {
            let error = await Self.runAsAdmin(command, prompt: prompt)
            working = nil
            show(note: error ?? done)
            noteBuildLog("vpn: \(done.lowercased())\(error.map { " failed: \($0)" } ?? "")")
            try? await Task.sleep(for: .seconds(1))
            poke()
        }
    }

    /// `do shell script … with administrator privileges`: macOS's own password prompt; the
    /// command runs as root. Nil on success, else why not.
    private static func runAsAdmin(_ command: String, prompt: String) async -> String? {
        let script = "do shell script \(appleQuote(command)) with prompt \(appleQuote(prompt)) with administrator privileges"
        return await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            let errors = Pipe()
            process.standardError = errors
            process.standardOutput = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                return "osascript did not start"
            }
            let data = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus != 0 else { return nil }
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.contains("-128") ? "Cancelled" : text.isEmpty ? "Failed" : text
        }.value
    }

    static func shellQuote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func appleQuote(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    // MARK: Saved credentials

    /// The username last used for a profile (UserDefaults) and its password if saved (Keychain).
    static func saved(_ profileId: String) -> (username: String, password: String)? {
        guard let username = UserDefaults.standard.string(forKey: "vpn.username.\(profileId)"),
              let data = KeychainBlob.read(service: keychainService, account: profileId) else { return nil }
        return (username, String(decoding: data, as: UTF8.self))
    }

    static func savedUsername(_ profileId: String) -> String {
        UserDefaults.standard.string(forKey: "vpn.username.\(profileId)") ?? ""
    }

    static func hasSavedPassword(_ profileId: String) -> Bool {
        KeychainBlob.read(service: keychainService, account: profileId) != nil
    }

    private static func save(_ profileId: String, password: String) {
        KeychainBlob.write(Data(password.utf8), service: keychainService, account: profileId, label: "AI Notch VPN")
    }

    static func forget(_ profileId: String) {
        KeychainBlob.delete(service: keychainService, account: profileId)
    }

    private func show(note text: String) {
        note = text
        noteWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.note = nil } }
        noteWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
    }
}

/// The helper's control socket, one request at a time, off the main thread.
enum VPNClient {
    enum Outcome {
        case reply(VPNReply)
        case notRunning
        case failed(String)
    }

    private static let queue = DispatchQueue(label: "info.ankeshshiv.notch.vpn-client")

    static func send(_ request: VPNRequest, timeout: Int = 3) async -> Outcome {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: exchange(request, timeout: timeout)) }
        }
    }

    private static func exchange(_ request: VPNRequest, timeout: Int) -> Outcome {
        do {
            let data = try UnixSocket.exchange(VPNPaths.controlSocket, VPNWire.encode(request), timeout: timeout)
            guard let reply = VPNWire.decode(VPNReply.self, data) else { return .failed("The VPN helper's answer could not be read") }
            return .reply(reply)
        } catch let failure as UnixSocket.Failure {
            return failure.isNotRunning ? .notRunning : .failed(failure.description)
        } catch {
            return .failed("\(error)")
        }
    }
}
