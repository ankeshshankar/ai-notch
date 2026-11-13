import AppKit
import Carbon.HIToolbox
import DictationCore

/// Types text into the focused app: the text goes on the pasteboard, a ⌘V is posted, and the
/// clipboard is put back afterwards, every type of it.
@MainActor
enum DictationInsert {
    enum Outcome: Equatable {
        case inserted
        /// A password field (secure event input) is focused: nothing is inserted.
        case secureField
        /// No Accessibility permission to post ⌘V: the text is left on the clipboard instead.
        case copiedOnly
    }

    static var secureInputOn: Bool { IsSecureEventInputEnabled() }

    /// How long the pasted text stays on the pasteboard before the old contents return: long
    /// enough for a slow app to read it.
    static let restoreDelay: Duration = .milliseconds(600)

    static func insert(_ text: String, pasteboard: NSPasteboard = .general) async -> Outcome {
        if secureInputOn { return .secureField }
        guard AXIsProcessTrusted() else {
            // Without permission the keystroke would go nowhere: leave the text for a manual paste.
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            return .copiedOnly
        }
        let loan = PasteboardLoan.lend(text: text, on: pasteboard)
        postCommandV()
        try? await Task.sleep(for: restoreDelay)
        loan.giveBack()
        return .inserted
    }

    /// ⌘V as a pair of synthetic key events.
    static func postCommandV() {
        let source = CGEventSource(stateID: .privateState)
        let v = CGKeyCode(kVK_ANSI_V)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: down) else { continue }
            event.flags = .maskCommand
            event.post(tap: .cghidEventTap)
        }
    }
}
