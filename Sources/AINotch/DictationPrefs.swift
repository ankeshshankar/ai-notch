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
    static let defaultLocale = "en-IN"

    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: "dictation.enabled"); changed() } }
    @Published var hotkey: DictationHotkey { didSet { defaults.set(hotkey.rawValue, forKey: "dictation.hotkey"); changed() } }
    @Published var locale: String { didSet { defaults.set(locale, forKey: "dictation.locale"); changed() } }
    @Published var aiCleanup: Bool { didSet { defaults.set(aiCleanup, forKey: "dictation.aiCleanup") } }
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
        style = DictationStyle(rawValue: defaults.string(forKey: "dictation.style") ?? "") ?? .keepMyWords
        hasKey = DictationKey.exists()
    }

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
