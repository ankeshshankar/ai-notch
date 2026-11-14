import AppKit
import CoreGraphics
import DictationCore
import os

/// A listen-only event tap for the dictation key: `flagsChanged` (Fn and the modifiers) and
/// `keyDown` (Esc, and keys pressed along with the hotkey). It never changes or swallows an event.
/// Needs Input Monitoring. Without it macOS still hands out a tap, but a dead one (never enabled), so
/// `install()` counts a tap as installed only when access is granted and the tap is enabled; else it
/// returns false and the controller tries again.
@MainActor
final class DictationKeyTap {
    enum Event { case hotkeyDown, hotkeyUp, escape, otherKey }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private(set) var hotkey: DictationHotkey = .fn
    private var hotkeyIsDown = false
    private var loggedDenied = false
    var handler: (Event) -> Void = { _ in }

    var isInstalled: Bool { tap != nil }

    func install(hotkey: DictationHotkey) -> Bool {
        self.hotkey = hotkey
        if let tap {
            if CGEvent.tapIsEnabled(tap: tap) { return true }
            DictationLog.log.notice("tap present but disabled; recreating")
            uninstall()
        }
        hotkeyIsDown = false
        let granted = CGPreflightListenEventAccess()
        guard granted else {
            if !loggedDenied { DictationLog.log.notice("tap not installed: input monitoring not granted (preflight false)"); loggedDenied = true }
            return false
        }
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
        }, userInfo: refcon) else {
            DictationLog.log.error("tapCreate returned nil")
            return false
        }
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        guard CGEvent.tapIsEnabled(tap: port) else {
            // Created but dead: the grant has not taken effect for this process.
            DictationLog.log.notice("tap created but not enabled; discarding")
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            CFMachPortInvalidate(port)
            return false
        }
        tap = port
        source = runLoopSource
        loggedDenied = false
        DictationLog.log.info("tap installed and enabled")
        return true
    }

    func uninstall() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
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
