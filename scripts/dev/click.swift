import AppKit
// Usage: click <x> <y> [right]   (global top-left points). Puts the pointer back afterwards.
let a = CommandLine.arguments
if a.count == 2, a[1] == "info" {
    let s = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main!
    print(Int(s.frame.width), Int(s.frame.height), Int(s.safeAreaInsets.top)); exit(0)
}
let target = CGPoint(x: Double(a[1])!, y: Double(a[2])!)
let back = CGEvent(source: nil)!.location
let src = CGEventSource(stateID: .hidSystemState)
CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: target, mouseButton: .left)!.post(tap: .cghidEventTap)
usleep(350_000)
let right = a.count > 3 && a[3] == "right"
CGEvent(mouseEventSource: src, mouseType: right ? .rightMouseDown : .leftMouseDown, mouseCursorPosition: target, mouseButton: right ? .right : .left)!.post(tap: .cghidEventTap)
usleep(60_000)
CGEvent(mouseEventSource: src, mouseType: right ? .rightMouseUp : .leftMouseUp, mouseCursorPosition: target, mouseButton: right ? .right : .left)!.post(tap: .cghidEventTap)
usleep(150_000)
CGWarpMouseCursorPosition(back)
