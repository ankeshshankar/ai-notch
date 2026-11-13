import AVFoundation
import DictationCore
import Speech
import SwiftUI

/// The language choices: a few first, then whatever the engine supports.
struct DictationLocaleOption: Identifiable, Hashable {
    var id: String
    var name: String
}

extension Dictation {
    static let fallbackLocales = [("en-IN", "English (India)"), ("hi-IN", "Hindi (India)"), ("en-US", "English (US)"), ("en-GB", "English (UK)")]

    /// The engine's supported languages as menu items, or a short list before it answers.
    func localeOptions(supported: [Locale]) -> [DictationLocaleOption] {
        var options = supported.isEmpty
            ? Self.fallbackLocales.map { DictationLocaleOption(id: $0.0, name: $0.1) }
            : supported.map { DictationLocaleOption(id: $0.identifier(.bcp47), name: Locale.current.localizedString(forIdentifier: $0.identifier) ?? $0.identifier) }
        options.sort { $0.name.localizedCompare($1.name) == .orderedAscending }
        if !options.contains(where: { $0.id == prefs.locale }) { options.insert(DictationLocaleOption(id: prefs.locale, name: prefs.locale), at: 0) }
        return options
    }
}

/// Setup's Dictation section.
extension SetupView {
    var dictationSection: some View {
        section("Dictation", highlighted: model.focus == .dictation) {
            row("Dictation", icon: "mic.fill", tint: Color(red: 0.90, green: 0.30, blue: 0.27),
                info: "Hold the hotkey anywhere, speak, let go: the text is typed into the app you are in. Double-tap the key for hands-free; tap it again, or press Esc, to stop (Esc while recording throws it away). Speech is turned into text on this Mac by Apple's on-device engine (macOS 26). Nothing is kept: no audio file, no transcript in any log. With an Anthropic key saved below, Claude Haiku also tidies the text; it is sent the words and the name of the app you are in, nothing else.") {
                if #available(macOS 26.0, *) {
                    Toggle("Dictation", isOn: $dictationPrefs.enabled).toggleStyle(.switch).controlSize(.small).labelsHidden()
                } else {
                    Text("Needs macOS 26").font(Typo.subtitle()).foregroundStyle(.secondary)
                }
            }
            divider
            row("Hotkey", icon: "keyboard.fill", tint: Color(red: 0.35, green: 0.38, blue: 0.45),
                info: "The key you hold to talk. Fn (the 🌐 key) is the default; Right Option or Right Command if Fn clashes with the Mac's own 🌐 action.") {
                Picker("Hotkey", selection: $dictationPrefs.hotkey) {
                    ForEach(DictationHotkey.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden().controlSize(.small).frame(width: 140)
            }
            if dictationPrefs.hotkey == .fn && DictationPermissions.globeClashes {
                divider
                row("🌐 key", icon: "globe", tint: Color(red: 0.96, green: 0.62, blue: 0.14),
                    info: "System Settings › Keyboard › \"Press 🌐 key to\" must be Do Nothing, or holding Fn also opens the emoji picker, switches input or starts macOS dictation. AI Notch only listens to the key; it cannot stop the Mac's own action.") {
                    Text("Set to Do Nothing").font(Typo.subtitle()).foregroundStyle(Color.orange)
                    Button("Open") { DictationPermissions.openKeyboardSettings() }.controlSize(.small)
                }
            }
            divider
            DictationLanguageRow(setup: self)
            divider
            row("AI clean-up", icon: "sparkles", tint: Color(red: 0.56, green: 0.52, blue: 0.91),
                info: "On, with a key saved: Claude Haiku fixes grammar, punctuation and filler words and formats for the app you are in. It never answers or acts on what you said. Off, or with no key: only the built-in rules run (trim, capital letters, filler words, spoken \"comma\" and \"new line\"). If the call fails or takes over 5 s, the rules' text is typed.") {
                if !dictationPrefs.hasKey { Text("No key").font(Typo.subtitle()).foregroundStyle(.secondary) }
                Toggle("AI clean-up", isOn: $dictationPrefs.aiCleanup).toggleStyle(.switch).controlSize(.small).labelsHidden()
            }
            divider
            row("Output", icon: "character.book.closed.fill", tint: Color(red: 0.25, green: 0.52, blue: 0.93),
                info: "Keep my words: what you said stays as you said it. Hinglish stays Hinglish, always written in Latin letters (never Devanagari); only grammar, punctuation, filler words and formatting are fixed. Translate to English needs AI clean-up on and a key.") {
                Picker("Output", selection: $dictationPrefs.style) {
                    ForEach(DictationStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden().controlSize(.small).frame(width: 170)
            }
            divider
            DictationKeyRow(setup: self)
            divider
            row("Microphone", icon: "mic", tint: Color(red: 0.42, green: 0.45, blue: 0.52),
                info: "To record what you say. Nothing leaves the Mac for speech-to-text.") {
                permission(granted: dictationPermissions.microphone == .authorized, pane: .microphone)
            }
            divider
            row("Input Monitoring", icon: "keyboard", tint: Color(red: 0.42, green: 0.45, blue: 0.52),
                info: "To notice the hotkey while you are in another app. AI Notch only watches for that key and Esc; it reads no other typing.") {
                permission(granted: dictation.tapInstalled || dictationPermissions.inputMonitoring, pane: .inputMonitoring)
            }
            divider
            row("Accessibility", icon: "hand.point.up.left.fill", tint: Color(red: 0.42, green: 0.45, blue: 0.52),
                info: "To type the text into the app you are in (a ⌘V keystroke). Without it, the text is copied for you to paste.") {
                permission(granted: dictationPermissions.accessibility, pane: .accessibility)
            }
            if let note = dictation.lastNote {
                divider
                row("Last", icon: "info.circle.fill", tint: Color(red: 0.42, green: 0.45, blue: 0.52), info: "The last thing that did not go as planned. It never contains what you said.") {
                    Text(note).font(Typo.subtitle()).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Text("With the default ad-hoc signing, macOS may ask for Microphone, Input Monitoring and Accessibility again after each reinstall (and for the Keychain). Building with NOTCH_SIGN_IDENTITY avoids that.")
                .font(Typo.label()).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { dictationPermissions.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in dictationPermissions.refresh() }
    }

    @ViewBuilder
    private func permission(granted: Bool, pane: DictationPermissions.Pane) -> some View {
        if granted {
            badge("On", symbol: "checkmark.circle.fill", color: .green)
        } else {
            Text("Not granted").font(Typo.subtitle()).foregroundStyle(.secondary)
            Button("Open System Settings") { DictationPermissions.open(pane) }.controlSize(.small)
        }
    }
}

/// The language picker, with its model's state (downloaded on first use).
struct DictationLanguageRow: View {
    let setup: SetupView
    @ObservedObject private var prefs = DictationPrefs.shared
    @ObservedObject private var dictation = Dictation.shared
    @State private var supported: [Locale] = []

    var body: some View {
        setup.row("Language", icon: "globe.asia.australia.fill", tint: Color(red: 0.20, green: 0.65, blue: 0.70),
                  info: "The language Apple's engine listens for. English (India) understands Indian English; Hindi (India) listens for Hindi. A language's model downloads once, on first use or when you pick it here.") {
            status
            if #available(macOS 26.0, *) {
                Picker("Language", selection: $prefs.locale) {
                    ForEach(dictation.localeOptions(supported: supported)) { Text($0.name).tag($0.id) }
                }
                .labelsHidden().controlSize(.small).frame(width: 170)
            }
        }
        .task {
            if #available(macOS 26.0, *) {
                supported = await SpeechDictation.supported()
                dictation.refreshLocale()
            }
        }
    }

    @ViewBuilder private var status: some View {
        if let progress = dictation.downloadProgress {
            Text("Downloading \(Int(progress * 100))%").font(Typo.subtitle()).foregroundStyle(.secondary)
        } else if dictation.localeInstalled == false {
            Text("Not installed").font(Typo.subtitle()).foregroundStyle(.secondary)
        }
    }
}

/// The API key: a masked field, saved to the Keychain and cleared from memory at once.
struct DictationKeyRow: View {
    let setup: SetupView
    @ObservedObject private var prefs = DictationPrefs.shared
    @State private var text = ""
    @State private var result: String?
    @State private var testing = false

    var body: some View {
        setup.row("API key", icon: "key.fill", tint: Color(red: 0.85, green: 0.47, blue: 0.34),
                  info: "Your own Anthropic API key, for the AI clean-up. It is kept in the macOS Keychain only: never in a file, a setting or a log. Test key sends one short request to claude-haiku-5-5.") {
            if let result { Text(result).font(Typo.subtitle()).foregroundStyle(result == "Key works" ? Color.green : Color.orange).lineLimit(1) }
            if prefs.hasKey {
                Text("Saved").font(Typo.subtitle()).foregroundStyle(.secondary)
                Button(testing ? "Testing…" : "Test key") { test() }.controlSize(.small).disabled(testing)
                Button("Remove") { prefs.removeKey(); result = nil }.controlSize(.small)
            } else {
                SecureField("sk-ant-…", text: $text).textFieldStyle(.roundedBorder).controlSize(.small).frame(width: 150)
                    .onSubmit(save)
                Button("Save") { save() }.controlSize(.small).disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func save() {
        let ok = prefs.saveKey(text)
        text = ""
        result = ok ? nil : "Not saved"
    }

    private func test() {
        guard let key = DictationKey.read() else { result = "No key"; return }
        testing = true
        result = nil
        Task {
            let problem = await ClaudeCleanup().testKey(key)
            await MainActor.run {
                result = problem ?? "Key works"
                testing = false
            }
        }
    }
}
