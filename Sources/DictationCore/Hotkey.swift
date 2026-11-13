import Foundation

/// The key held to dictate. Fn is the default; the others are for a Mac where the 🌐 key's own
/// action (emoji picker, input source, system dictation) gets in the way.
public enum DictationHotkey: String, CaseIterable, Sendable {
    case fn, rightOption, rightCommand

    public var title: String {
        switch self {
        case .fn: return "Fn"
        case .rightOption: return "Right Option"
        case .rightCommand: return "Right Command"
        }
    }

    /// The virtual key codes a `flagsChanged` event for this key carries (the 🌐 key on newer
    /// keyboards reports 179 as well as 63).
    var keyCodes: Set<Int64> {
        switch self {
        case .fn: return [63, 179]
        case .rightOption: return [61]
        case .rightCommand: return [54]
        }
    }

    /// Whether this key is down in a `flagsChanged` event's raw flags: Fn's own flag, or the
    /// device-dependent bit of the right-hand modifier (the shared Option or Command bit stays
    /// set while the left one is held, so it cannot say which hand).
    func isDown(rawFlags: UInt64) -> Bool {
        switch self {
        case .fn: return rawFlags & 0x0080_0000 != 0          // NSEvent.ModifierFlags.function
        case .rightOption: return rawFlags & 0x0000_0040 != 0 // NX_DEVICERALTKEYMASK
        case .rightCommand: return rawFlags & 0x0000_0010 != 0 // NX_DEVICERCMDKEYMASK
        }
    }

    /// Reads one `flagsChanged` event: nil when it is another key's, else whether this one is down.
    public func press(keyCode: Int64, rawFlags: UInt64) -> Bool? {
        guard keyCodes.contains(keyCode) else { return nil }
        return isDown(rawFlags: rawFlags)
    }
}

/// Fn's own setting in System Settings › Keyboard › "Press 🌐 key to".
public enum GlobeKeySetting {
    /// `AppleFnUsageType`: 0 Do Nothing, 1 Change Input Source, 2 Show Emoji & Symbols, 3 Start
    /// Dictation. Unset means the system default, which is not "Do Nothing".
    public static func clashes(usageType: Int?) -> Bool { usageType != 0 }
}

/// The hold-to-talk and double-tap gestures, as a pure state machine fed key events with their
/// times. It answers with what to do; the app does it.
///
/// - Hold the key: recording starts at once; letting go after `holdMinimum` stops and transcribes.
/// - A press shorter than that is a tap: it is discarded, and a second press within `doubleTapWindow`
///   starts hands-free recording that the next tap (or Esc) stops.
/// - Esc while recording cancels; so does any other key pressed during a hold (the key was
///   being used as a modifier).
public struct HotkeyGesture: Sendable {
    public enum Action: Equatable, Sendable {
        case start, stop, cancel
    }

    public enum Phase: Equatable, Sendable {
        case idle
        /// Pressed and held; `since` is when.
        case holding(since: TimeInterval)
        /// The second press of a double tap, still down.
        case armingHandsFree
        case handsFree
        /// The key is still down after a stop or cancel: its release does nothing.
        case waitingForRelease
    }

    public var holdMinimum: TimeInterval = 0.3
    public var doubleTapWindow: TimeInterval = 0.45
    public private(set) var phase: Phase = .idle
    private var lastTap: TimeInterval?

    public init() {}

    public var isRecording: Bool {
        switch phase {
        case .holding, .armingHandsFree, .handsFree: return true
        case .idle, .waitingForRelease: return false
        }
    }

    public mutating func keyDown(at time: TimeInterval) -> Action? {
        switch phase {
        case .idle:
            if let last = lastTap, time - last <= doubleTapWindow {
                lastTap = nil
                phase = .armingHandsFree
            } else {
                phase = .holding(since: time)
            }
            return .start
        case .handsFree:
            phase = .waitingForRelease
            return .stop
        case .holding, .armingHandsFree, .waitingForRelease:
            return nil
        }
    }

    public mutating func keyUp(at time: TimeInterval) -> Action? {
        switch phase {
        case .holding(let since):
            if time - since >= holdMinimum {
                phase = .idle
                lastTap = nil
                return .stop
            }
            phase = .idle
            lastTap = time
            return .cancel
        case .armingHandsFree:
            phase = .handsFree
            return nil
        case .waitingForRelease:
            phase = .idle
            return nil
        case .idle, .handsFree:
            return nil
        }
    }

    /// Esc: cancels a recording (nothing is inserted).
    public mutating func escape() -> Action? {
        guard isRecording else { return nil }
        let down: Bool
        if case .handsFree = phase { down = false } else { down = true }
        phase = down ? .waitingForRelease : .idle
        lastTap = nil
        return .cancel
    }

    /// Another key pressed while the hotkey is down: it was a modifier for a shortcut, so the
    /// recording is dropped. In hands-free mode other keys are just typing.
    public mutating func otherKeyDown() -> Action? {
        switch phase {
        case .holding, .armingHandsFree:
            phase = .waitingForRelease
            lastTap = nil
            return .cancel
        default:
            return nil
        }
    }

    /// The recording ended on its own (the maximum length, an error): back to idle.
    public mutating func reset() {
        phase = .idle
        lastTap = nil
    }
}
