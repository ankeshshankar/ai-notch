import AVFoundation
import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import DictationCore
import Security
import Speech

/// Dictation's settings (UserDefaults, none of them secret) and what it needs from the system.
/// The API key is not here: it lives in the Keychain only (`DictationKey`).
@MainActor
final class DictationPrefs: ObservableObject {
    static let shared = DictationPrefs()
    /// Hindi (India) hears Hinglish better than English (India); a saved choice always wins.
    static let defaultLocale = "hi-IN"

    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: "dictation.enabled"); changed() } }
    @Published var hotkey: DictationHotkey { didSet { defaults.set(hotkey.rawValue, forKey: "dictation.hotkey"); changed() } }
    @Published var locale: String { didSet { defaults.set(locale, forKey: "dictation.locale"); changed() } }
    @Published var aiCleanup: Bool { didSet { defaults.set(aiCleanup, forKey: "dictation.aiCleanup") } }
    /// Type each phrase into the focused box as it is heard, instead of one paste at the end.
    @Published var typeLive: Bool { didSet { defaults.set(typeLive, forKey: "dictation.typeLive") } }
    /// The user's own words (names, jargon) for the engine and the clean-up, one per line or comma-separated.
    @Published var vocabulary: String { didSet { defaults.set(vocabulary, forKey: "dictation.vocabulary") } }
    /// Which Apple recogniser: automatic picks the speech one for Hindi (it keeps English words in
    /// Latin letters, the dictation one writes Devanagari and drops them) and the dictation one,
    /// which takes custom vocabulary, for other languages.
    @Published var engine: DictationEngineChoice { didSet { defaults.set(engine.rawValue, forKey: "dictation.engine"); changed() } }
    @Published var style: DictationStyle { didSet { defaults.set(style.rawValue, forKey: "dictation.style") } }
    /// Whether a key is saved (the key itself is never held here).
    @Published private(set) var hasKey: Bool

    /// Called when the enable switch, hotkey or language changes: the controller re-applies them.
    var onChange: () -> Void = {}
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.bool(forKey: "dictation.enabled")
        hotkey = DictationHotkey(rawValue: defaults.string(forKey: "dictation.hotkey") ?? "") ?? .fn
        locale = defaults.string(forKey: "dictation.locale") ?? Self.defaultLocale
        aiCleanup = defaults.object(forKey: "dictation.aiCleanup") as? Bool ?? true
        typeLive = defaults.bool(forKey: "dictation.typeLive")
        vocabulary = defaults.string(forKey: "dictation.vocabulary") ?? ""
        engine = DictationEngineChoice(rawValue: defaults.string(forKey: "dictation.engine") ?? "") ?? .auto
        style = DictationStyle(rawValue: defaults.string(forKey: "dictation.style") ?? "") ?? .keepMyWords
        hasKey = DictationKey.exists()
    }

    /// The engine to ask for with `locale` (nil: dictation first, speech as the fallback).
    func enginePreference(for locale: String) -> SpeechEngine? {
        switch engine {
        case .auto: return locale.lowercased().hasPrefix("hi") ? .speech : nil
        case .dictation: return .dictation
        case .speech: return .speech
        }
    }

    var userTerms: [String] { DictationVocabulary.parse(vocabulary) }

    private func changed() { onChange() }

    func refreshKey() { hasKey = DictationKey.exists() }

    func saveKey(_ key: String) -> Bool {
        let ok = DictationKey.save(key)
        refreshKey()
        return ok
    }

    func removeKey() {
        DictationKey.remove()
        refreshKey()
    }

    /// AI clean-up runs when it is on and a key is saved.
    var aiActive: Bool { aiCleanup && hasKey }
}

enum DictationEngineChoice: String, CaseIterable {
    case auto, dictation, speech
    var title: String {
        switch self {
        case .auto: return "Automatic"
        case .dictation: return "Apple Dictation"
        case .speech: return "Apple Speech"
        }
    }
}

/// The Anthropic API key, in the macOS Keychain and nowhere else: never a file, UserDefaults, the
/// app group, the ledger or a log. Read only when a dictation needs it.
enum DictationKey {
    static let service = "info.ankeshshiv.notch.dictation"
    static let account = "anthropic-api-key"

    private static var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    /// Whether a key is saved, without reading it (no password prompt).
    static func exists() -> Bool {
        var query = base
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    static func read() -> String? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    @discardableResult
    static func save(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return false }
        remove()
        var item = base
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecAttrLabel as String] = "AI Notch dictation (Anthropic API key)"
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func remove() { SecItemDelete(base as CFDictionary) }
}

/// What dictation needs from macOS, and where to grant it.
@MainActor
final class DictationPermissions: ObservableObject {
    static let shared = DictationPermissions()

    @Published private(set) var microphone: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @Published private(set) var inputMonitoring = CGPreflightListenEventAccess()
    @Published private(set) var accessibility = AXIsProcessTrusted()

    func refresh() {
        microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        inputMonitoring = CGPreflightListenEventAccess()
        accessibility = AXIsProcessTrusted()
    }

    enum Pane: String {
        case microphone = "Privacy_Microphone"
        case inputMonitoring = "Privacy_ListenEvent"
        case accessibility = "Privacy_Accessibility"
    }

    static func open(_ pane: Pane) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)") { NSWorkspace.shared.open(url) }
    }

    static func openKeyboardSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") { NSWorkspace.shared.open(url) }
    }

    /// Asks for the microphone once (the system sheet), then refreshes.
    func requestMicrophone() async -> Bool {
        let ok = await AVCaptureDevice.requestAccess(for: .audio)
        refresh()
        return ok
    }

    /// The 🌐 key's own action clashes with Fn unless it is "Do Nothing".
    static var globeClashes: Bool {
        let value = CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, "com.apple.HIToolbox" as CFString)
        return GlobeKeySetting.clashes(usageType: (value as? NSNumber)?.intValue)
    }
}
