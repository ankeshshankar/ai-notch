import AppKit
import DictationCore

/// "Type as I speak": types each final phrase into the focused box, one at a time. Before every
/// phrase it checks the app in front is still the one dictation began in, that secure input is
/// off and that Accessibility is on; if not, it stops typing and holds the rest back for the
/// clipboard. Never deletes anything. Holds the words in memory only and never logs them.
@MainActor
final class LiveTyper {
    enum Stop: Equatable {
        case appChanged, secureField, noAccessibility, cancelled

        /// Short pill text once the rest has been copied.
        var copiedMessage: String {
            switch self {
            case .appChanged: return "App changed, copied"
            case .secureField: return "Secure field, copied"
            case .noAccessibility: return "No access, copied"
            case .cancelled: return ""
            }
        }

        /// The line shown under the pill the moment typing stops.
        var notice: String {
            switch self {
            case .appChanged: return "App changed: typing stopped, the rest will be copied"
            case .secureField: return "Secure field: typing stopped, the rest will be copied"
            case .noAccessibility: return "Accessibility is off: typing stopped, the rest will be copied"
            case .cancelled: return ""
            }
        }
    }

    /// What was typed so far (joining and capitalisation read it) and what was held back.
    private(set) var typed = ""
    private(set) var rest = ""
    private(set) var stopped: Stop?
    private(set) var phrases = 0
    private let style: DictationStyle
    private let startPID: pid_t?
    private let startBundle: String?
    /// Hooks for tests and the dev run.
    var frontmost: () -> (pid: pid_t?, bundle: String?) = {
        let app = NSWorkspace.shared.frontmostApplication
        return (app?.processIdentifier, app?.bundleIdentifier)
    }
    var secureInputOn: () -> Bool = { DictationInsert.secureInputOn }
    var accessibilityOn: () -> Bool = { DictationInsert.accessibilityOn }
    var post: (String) -> Void = { DictationInsert.typeUnicode($0) }
    var onStop: ((Stop) -> Void)?

    init(style: DictationStyle, app: NSRunningApplication? = NSWorkspace.shared.frontmostApplication) {
        self.style = style
        startPID = app?.processIdentifier
        startBundle = app?.bundleIdentifier
    }

    var hasText: Bool { !typed.isEmpty || !rest.isEmpty }

    /// A phrase Apple marked final.
    func accept(_ raw: String) {
        guard stopped != .cancelled else { return }
        phrases += 1
        let text = LiveText.phrase(raw, typedSoFar: typed + rest, style: style)
        guard !text.isEmpty else { return }
        if stopped == nil, let reason = blocker() {
            stopped = reason
            onStop?(reason)
        }
        if stopped != nil { rest += text; return }
        post(text)
        typed += text
    }

    /// Esc: no more typing; what is typed stays.
    func cancel() { stopped = .cancelled }

    private func blocker() -> Stop? {
        let now = frontmost()
        if let startBundle, let bundle = now.bundle { if bundle != startBundle { return .appChanged } }
        else if let startPID, let pid = now.pid, pid != startPID { return .appChanged }
        if secureInputOn() { return .secureField }
        if !accessibilityOn() { return .noAccessibility }
        return nil
    }
}
