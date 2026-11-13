import AppKit
import CoreGraphics
import DictationCore

/// A listen-only event tap for the dictation key: `flagsChanged` (Fn and the modifiers) and
/// `keyDown` (Esc, and keys pressed along with the hotkey). It never changes or swallows an event.
/// Needs Input Monitoring; without it `install()` returns false and the controller tries again.
@MainActor
final class DictationKeyTap {
    enum Event { case hotkeyDown, hotkeyUp, escape, otherKey }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private(set) var hotkey: DictationHotkey = .fn
    private var hotkeyIsDown = false
    var handler: (Event) -> Void = { _ in }

    var isInstalled: Bool { tap != nil }

    func install(hotkey: DictationHotkey) -> Bool {
        self.hotkey = hotkey
        hotkeyIsDown = false
        guard tap == nil else { return true }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                           eventsOfInterest: CGEventMask(mask), callback: { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let tap = Unmanaged<DictationKeyTap>.fromOpaque(refcon).takeUnretainedValue()
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags.rawValue
            // The tap runs on the main run loop, so this is the main thread.
            MainActor.assumeIsolated { tap.receive(type: type, keyCode: keyCode, flags: flags) }
            return Unmanaged.passUnretained(event)
        }, userInfo: refcon) else { return false }
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = port
        source = runLoopSource
        return true
    }

    func uninstall() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        hotkeyIsDown = false
    }

    private func receive(type: CGEventType, keyCode: Int64, flags: UInt64) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .flagsChanged:
            guard let down = hotkey.press(keyCode: keyCode, rawFlags: flags), down != hotkeyIsDown else { return }
            hotkeyIsDown = down
            handler(down ? .hotkeyDown : .hotkeyUp)
        case .keyDown:
            handler(keyCode == 53 ? .escape : .otherKey)
        default:
            break
        }
    }
}
