import AVFoundation
import AppKit
import Combine
import DictationCore
import Foundation
import Speech

/// Dictation: hold the hotkey anywhere to record, let go to have it typed into the focused app.
/// Speech-to-text is Apple's on-device SpeechAnalyzer (macOS 26); the text goes through the rule
/// clean-up and, with an API key saved, Claude Haiku; then it is pasted. Off until switched on
/// in Setup. Nothing is written to disk and no transcript is logged.
@MainActor
final class Dictation: ObservableObject {
    static let shared = Dictation()

    let prefs = DictationPrefs.shared
    let permissions = DictationPermissions.shared
    let pill = DictationPill()
    @Published private(set) var phase: DictationPhase = .idle
    /// The last thing that went wrong, for Setup (no text of what was said).
    @Published private(set) var lastNote: String?
    @Published private(set) var tapInstalled = false
    /// Whether the chosen language's model is installed, and the download's progress.
    @Published private(set) var localeInstalled: Bool?
    @Published private(set) var downloadProgress: Double?

    private let tap = DictationKeyTap()
    private var gesture = HotkeyGesture()
    private var retry: Timer?
    private var recorder: MicRecorder?
    private var speech: Task<SpeechSessionBox, Error>?
    private var processing: Task<Void, Never>?
    private var levelClock: Date = .distantPast
    private var maxLength: DispatchWorkItem?
    private var front: (name: String?, bundle: String?) = (nil, nil)
    private var askedInputMonitoring = false
    /// Set by a debug run: where the Claude call goes, in place of the API.
    var endpointOverride: URL?

    /// Boxes the macOS 26 type so this class can hold it on macOS 15.
    final class SpeechSessionBox: @unchecked Sendable { let value: Any; init(_ value: Any) { self.value = value } }

    /// Called once at launch.
    func start() {
        prefs.onChange = { [weak self] in self?.apply() }
        tap.handler = { [weak self] event in self?.receive(event) }
        apply()
    }

    /// After the switch, the key or the language changes.
    func apply() {
        permissions.refresh()
        retry?.invalidate()
        retry = nil
        guard prefs.enabled else {
            tap.uninstall()
            tapInstalled = false
            cancelRecording()
            return
        }
        tap.uninstall()
        installTap()
        if !tapInstalled {
            // Input Monitoring is granted in System Settings while the app runs: try again until it is.
            retry = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.installTap() }
            }
        }
        refreshLocale()
    }

    private func installTap() {
        if !CGPreflightListenEventAccess(), !askedInputMonitoring {
            askedInputMonitoring = true
            _ = CGRequestListenEventAccess()
        }
        tapInstalled = tap.install(hotkey: prefs.hotkey)
        permissions.refresh()
        if tapInstalled { retry?.invalidate(); retry = nil }
    }

    // MARK: Language models

    /// Looks up whether the chosen language is installed and downloads it when not.
    func refreshLocale() {
        guard #available(macOS 26.0, *) else { localeInstalled = nil; return }
        let id = prefs.locale
        Task { [weak self] in
            guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: id)) else {
                await MainActor.run { self?.localeInstalled = nil; self?.lastNote = "Language not supported" }
                return
            }
            let installed = await SpeechDictation.isInstalled(locale)
            await MainActor.run { self?.localeInstalled = installed }
            guard !installed, self?.prefs.enabled == true else { return }
            await self?.downloadLocale(locale)
        }
    }

    @available(macOS 26.0, *)
    private func downloadLocale(_ locale: Locale) async {
        downloadProgress = 0
        do {
            try await SpeechDictation.ensureAssets(for: locale) { fraction in
                Task { @MainActor in Dictation.shared.downloadProgress = fraction }
            }
            localeInstalled = true
        } catch {
            lastNote = "Language download failed"
        }
        downloadProgress = nil
    }

    // MARK: Keys

    private func receive(_ event: DictationKeyTap.Event) {
        guard prefs.enabled else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let action: HotkeyGesture.Action?
        switch event {
        case .hotkeyDown: action = busy ? nil : gesture.keyDown(at: now)
        case .hotkeyUp: action = gesture.keyUp(at: now)
        case .escape:
            if processing != nil { cancelProcessing(); return }
            action = gesture.escape()
        case .otherKey: action = gesture.otherKeyDown()
        }
        switch action {
        case .start?: beginRecording()
        case .stop?: finishRecording()
        case .cancel?: cancelRecording()
        case nil: break
        }
    }

    /// Transcribing or cleaning: a new dictation waits.
    private var busy: Bool { processing != nil }

    // MARK: Recording

    private func beginRecording() {
        guard #available(macOS 26.0, *) else { fail("Needs macOS 26"); return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            gesture.reset()
            Task { _ = await permissions.requestMicrophone() }
            fail("Allow the mic")
            return
        default:
            fail("No mic access")
            return
        }
        if DictationInsert.secureInputOn { fail("Secure field"); return }
        let app = NSWorkspace.shared.frontmostApplication
        front = (app?.localizedName, app?.bundleIdentifier)
        phase = .listening(since: Date())
        pill.model.wave?.clear()
        pill.show(phase)
        lastNote = nil

        let pump = AudioPump()
        pump.onLevel = { [weak self] level in
            DispatchQueue.main.async { self?.level(level) }
        }
        do {
            recorder = try MicRecorder(pump: pump)
        } catch {
            fail((error as? DictationError)?.short ?? "Mic error")
            return
        }
        let source = recorder!.format
        let id = prefs.locale
        speech = Task {
            let session = try await SpeechDictation.start(localeIdentifier: id, source: source, pump: pump)
            return SpeechSessionBox(session)
        }
        // A forgotten hands-free recording ends after five minutes.
        let limit = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.gesture.reset(); self?.finishRecording() } }
        maxLength = limit
        DispatchQueue.main.asyncAfter(deadline: .now() + 300, execute: limit)
    }

    /// Mic level for the waveform, about 20 times a second.
    private func level(_ level: Float) {
        guard case .listening = phase else { return }
        let now = Date()
        guard now.timeIntervalSince(levelClock) >= 0.05 else { return }
        levelClock = now
        pill.model.push(level: level)
    }

    private func finishRecording() {
        guard case .listening = phase, #available(macOS 26.0, *) else { return }
        maxLength?.cancel()
        recorder?.stop()
        recorder = nil
        phase = .transcribing
        pill.show(phase)
        let box = speech
        speech = nil
        let app = front
        processing = Task { [weak self] in
            await self?.transcribeAndInsert(session: box, app: app)
            self?.processing = nil
        }
    }

    private func cancelRecording() {
        maxLength?.cancel()
        recorder?.stop()
        recorder = nil
        let box = speech
        speech = nil
        gesture.reset()
        if case .listening = phase { phase = .idle; pill.hide() }
        if #available(macOS 26.0, *), let box {
            Task { if let s = try? await box.value.value as? SpeechDictation { await s.cancel() } }
        }
    }

    private func cancelProcessing() {
        processing?.cancel()
        processing = nil
        gesture.reset()
        phase = .idle
        pill.hide()
    }

    // MARK: After the recording

    @available(macOS 26.0, *)
    private func transcribeAndInsert(session box: Task<SpeechSessionBox, Error>?, app: (name: String?, bundle: String?)) async {
        let raw: String
        do {
            guard let box, let session = try await box.value.value as? SpeechDictation else { return fail("Mic error") }
            raw = try await session.finish()
        } catch let error as DictationError {
            lastNote = error.short
            return fail(error.short)
        } catch {
            return fail("Couldn't transcribe")
        }
        if Task.isCancelled { return }
        let text = await finalText(raw: raw, app: app)
        if Task.isCancelled { return }
        guard !text.isEmpty else { return fail("No speech") }
        await insertAndReport(text)
    }

    /// The rules' text, or Claude's version of it when a key is saved and the switch is on.
    func finalText(raw: String, app: (name: String?, bundle: String?)) async -> String {
        let style = prefs.style
        let rules = RuleCleaner.clean(raw, style: style)
        guard !rules.isEmpty else { return "" }
        guard prefs.aiCleanup, let key = DictationKey.read() else { return rules }
        phase = .cleaning
        pill.show(phase)
        let cleanup = endpointOverride.map { ClaudeCleanup(endpoint: $0) } ?? ClaudeCleanup()
        let result = await cleanup.clean(transcript: rules, fallback: rules, apiKey: key, style: style,
                                         context: AppContext.of(appName: app.name, bundleID: app.bundle), appName: app.name)
        if let failure = result.failure { lastNote = "AI clean-up skipped: \(failure)" }
        // Never Devanagari when the words are kept, whatever the model sent.
        return style == .keepMyWords ? LatinScript.transliterateDevanagari(result.text) : result.text
    }

    func insertAndReport(_ text: String) async {
        switch await DictationInsert.insert(text) {
        case .inserted:
            phase = .inserted
            pill.show(phase, autoHide: 1.0)
        case .secureField:
            fail("Secure field")
        case .copiedOnly:
            phase = .copied
            lastNote = "Accessibility is off: the text was copied, not typed"
            pill.show(phase, autoHide: 2.5)
            DictationPermissions.shared.refresh()
        }
        gesture.reset()
        if phase == .inserted || phase == .copied {
            Task { try? await Task.sleep(for: .seconds(1.2)); if self.phase == .inserted || self.phase == .copied { self.phase = .idle } }
        }
    }

    private func fail(_ message: String) {
        recorder?.stop()
        recorder = nil
        gesture.reset()
        phase = .message(message)
        lastNote = message
        pill.show(phase, autoHide: 2.2)
        Task { try? await Task.sleep(for: .seconds(2.3)); if case .message = self.phase { self.phase = .idle } }
    }
}
