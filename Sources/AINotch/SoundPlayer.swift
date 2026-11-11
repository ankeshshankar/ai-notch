import AppKit
import Foundation
import NotchCore

/// The notch's event sounds: Material Design sound resources by Google (CC BY 4.0, levels
/// adjusted), one short sound per kind of event so each can be learned by ear. The files are
/// built by scripts/dev/fetch-sounds.sh into Resources/Sounds.
enum EventSound: String, CaseIterable, Sendable {
    case needsInput, finished, failed, contextFull, prodAlert, buildFailed, buildPassed, prNews, trouble

    /// The file in the bundle's Sounds folder (without .m4a). Each event has its own.
    var file: String {
        switch self {
        case .needsInput: return "notification_simple-01"
        case .finished: return "state-change_confirm-up"
        case .failed: return "alert_error-01"
        case .contextFull: return "alert_simple"
        case .prodAlert: return "alert_high-intensity"
        case .buildFailed: return "alert_error-03"
        case .buildPassed: return "hero_simple-celebration-02"
        case .prNews: return "notification_decorative-02"
        case .trouble: return "notification_high-intensity"
        }
    }

    /// Plain words, for Setup.
    var title: String {
        switch self {
        case .needsInput: return "Agent needs you"
        case .finished: return "Agent finished"
        case .failed: return "Turn failed"
        case .contextFull: return "Context almost full"
        case .prodAlert: return "Production alert"
        case .buildFailed: return "Build failed"
        case .buildPassed: return "Build passed"
        case .prNews: return "Pull request news"
        case .trouble: return "VPN dropped, memory critical"
        }
    }

    /// Higher wins when two land within the collision window: production alert, needs input,
    /// failed turn, VPN or memory, build failed, context, pull request news, build passed, finished.
    var priority: Int {
        switch self {
        case .prodAlert: return 9
        case .needsInput: return 8
        case .failed: return 7
        case .trouble: return 6
        case .buildFailed: return 5
        case .contextFull: return 4
        case .prNews: return 3
        case .buildPassed: return 2
        case .finished: return 1
        }
    }
}

/// Which sound a state change calls for. A session seen for the first time (`before` nil) makes none:
/// the app starting is not news.
enum SoundCues {
    static func session(before: Phase?, now: Phase, tookSeconds: Double, soundAfterTurn: Double) -> EventSound? {
        guard let before, before != now else { return nil }
        if now == .waiting { return .needsInput }
        if now == .idle, before == .working, tookSeconds >= soundAfterTurn { return .finished }
        return nil
    }
}

/// The switches: `effects.sounds` (all), `sound.<event>` (each), `sound.volume` (0…1).
@MainActor
final class SoundPrefs: ObservableObject {
    static let shared = SoundPrefs()
    static let defaultVolume = 0.6

    @Published var master: Bool { didSet { defaults.set(master, forKey: "effects.sounds") } }
    @Published var volume: Double { didSet { defaults.set(volume, forKey: "sound.volume") } }
    @Published private(set) var off: Set<EventSound>

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        master = defaults.object(forKey: "effects.sounds") as? Bool ?? true
        volume = min(max(defaults.object(forKey: "sound.volume") as? Double ?? Self.defaultVolume, 0), 1)
        off = Set(EventSound.allCases.filter { defaults.object(forKey: "sound.\($0.rawValue)") as? Bool == false })
    }

    func isOn(_ event: EventSound) -> Bool { !off.contains(event) }

    func set(_ event: EventSound, on: Bool) {
        if on { off.remove(event) } else { off.insert(event) }
        defaults.set(on, forKey: "sound.\(event.rawValue)")
    }

    /// Whether this event may sound now.
    func allows(_ event: EventSound) -> Bool { master && isOn(event) }
}

/// Where a sound goes out. The app's is NSSound; the self-check's records.
@MainActor
protocol SoundBackend: AnyObject {
    func play(_ event: EventSound, volume: Float)
    func stop()
}

/// NSSound, made when a sound plays and let go when it ends: nothing is kept loaded or running
/// while silent (no audio engine, no cached samples).
@MainActor
final class NSSoundBackend: NSObject, SoundBackend, NSSoundDelegate {
    private var current: NSSound?
    /// A preview or self-check run never makes a noise.
    static let silent = CommandLine.arguments.contains { $0.hasPrefix("--preview") || $0.hasPrefix("--setup-preview") || $0.hasSuffix("selfcheck") }

    /// The Sounds folder in the bundle, or, for a bare binary run from `.build`, the repo's
    /// Resources/Sounds above it.
    static let directory: URL? = {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("Sounds", isDirectory: true),
           FileManager.default.fileExists(atPath: url.path) { return url }
        var dir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("Resources/Sounds", isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }()

    static func url(of event: EventSound) -> URL? {
        directory?.appendingPathComponent(event.file + ".m4a")
    }

    func play(_ event: EventSound, volume: Float) {
        stop()
        guard !Self.silent else { return }
        guard let url = Self.url(of: event), let sound = NSSound(contentsOf: url, byReference: false) else { return }
        sound.volume = volume
        sound.delegate = self
        current = sound
        sound.play()
    }

    func stop() {
        current?.delegate = nil
        current?.stop()
        current = nil
    }

    nonisolated func sound(_ sound: NSSound, didFinishPlaying flag: Bool) {
        Task { @MainActor in
            if self.current === sound { self.current = nil }
        }
    }
}

/// The one place sounds go through. Never overlaps itself: an event that lands within
/// `window` seconds of the one playing sounds only if its priority is higher (it then replaces
/// it); otherwise it is dropped. Respects the switches.
@MainActor
final class SoundPlayer {
    static let shared = SoundPlayer()
    static let window = 1.5

    var backend: SoundBackend
    let prefs: SoundPrefs
    private let clock: () -> Double
    private var lastStart: Double?
    private var lastEvent: EventSound?

    init(backend: SoundBackend? = nil, prefs: SoundPrefs? = nil, clock: (() -> Double)? = nil) {
        self.backend = backend ?? NSSoundBackend()
        self.prefs = prefs ?? SoundPrefs.shared
        self.clock = clock ?? { Date().timeIntervalSince1970 }
    }

    /// Plays `event` once if the switches allow and nothing at least as important is playing.
    /// Returns whether it was played.
    @discardableResult
    func play(_ event: EventSound) -> Bool {
        guard prefs.allows(event) else { return false }
        let now = clock()
        if let start = lastStart, let last = lastEvent, now - start < Self.window, event.priority <= last.priority { return false }
        start(event, at: now)
        return true
    }

    /// The ▶ in Setup: plays it whatever the switches say, replacing what plays.
    func preview(_ event: EventSound) {
        start(event, at: clock())
    }

    private func start(_ event: EventSound, at now: Double) {
        lastStart = now
        lastEvent = event
        backend.play(event, volume: Float(prefs.volume))
    }

    /// Whether a notification should be silent because the app plays its own sound for it.
    var replacesSystemSound: Bool { prefs.master }
}

/// A backend that only records, for the self-check.
@MainActor
final class FakeSoundBackend: SoundBackend {
    private(set) var played: [(EventSound, Float)] = []
    private(set) var stops = 0
    func play(_ event: EventSound, volume: Float) { played.append((event, volume)) }
    func stop() { stops += 1 }
}
