import XCTest
@testable import DictationCore

final class HotkeyTests: XCTestCase {
    func testFnFlagDetection() {
        let fnDown: UInt64 = 0x0080_0000 | 0x100
        XCTAssertEqual(DictationHotkey.fn.press(keyCode: 63, rawFlags: fnDown), true)
        XCTAssertEqual(DictationHotkey.fn.press(keyCode: 63, rawFlags: 0x100), false)
        XCTAssertEqual(DictationHotkey.fn.press(keyCode: 179, rawFlags: fnDown), true)
        // Another modifier's event is not Fn's, even with the Fn bit still set.
        XCTAssertNil(DictationHotkey.fn.press(keyCode: 56, rawFlags: fnDown))
    }

    func testRightHandModifiersTellHandsApart() {
        // Left Option down: the shared bit is set but not the right one.
        XCTAssertNil(DictationHotkey.rightOption.press(keyCode: 58, rawFlags: 0x0008_0000 | 0x20))
        XCTAssertEqual(DictationHotkey.rightOption.press(keyCode: 61, rawFlags: 0x0008_0000 | 0x40), true)
        // Right Option released while Left Option is still held.
        XCTAssertEqual(DictationHotkey.rightOption.press(keyCode: 61, rawFlags: 0x0008_0000 | 0x20), false)
        XCTAssertEqual(DictationHotkey.rightCommand.press(keyCode: 54, rawFlags: 0x0010_0000 | 0x10), true)
        XCTAssertEqual(DictationHotkey.rightCommand.press(keyCode: 54, rawFlags: 0), false)
    }

    func testGlobeClash() {
        XCTAssertTrue(GlobeKeySetting.clashes(usageType: nil))
        XCTAssertTrue(GlobeKeySetting.clashes(usageType: 2))
        XCTAssertFalse(GlobeKeySetting.clashes(usageType: 0))
    }

    func testHoldRecordsAndReleaseStops() {
        var g = HotkeyGesture()
        XCTAssertEqual(g.keyDown(at: 0), .start)
        XCTAssertTrue(g.isRecording)
        XCTAssertEqual(g.keyUp(at: 1.5), .stop)
        XCTAssertFalse(g.isRecording)
    }

    func testShortTapIsDiscarded() {
        var g = HotkeyGesture()
        XCTAssertEqual(g.keyDown(at: 0), .start)
        XCTAssertEqual(g.keyUp(at: 0.1), .cancel)
        XCTAssertFalse(g.isRecording)
    }

    func testDoubleTapIsHandsFreeAndATapStopsIt() {
        var g = HotkeyGesture()
        XCTAssertEqual(g.keyDown(at: 0), .start)
        XCTAssertEqual(g.keyUp(at: 0.1), .cancel)
        XCTAssertEqual(g.keyDown(at: 0.3), .start)
        XCTAssertNil(g.keyUp(at: 0.4))
        XCTAssertEqual(g.phase, .handsFree)
        XCTAssertTrue(g.isRecording)
        // Time passes; typing elsewhere changes nothing.
        XCTAssertNil(g.otherKeyDown())
        XCTAssertEqual(g.keyDown(at: 10), .stop)
        XCTAssertNil(g.keyUp(at: 10.1))
        XCTAssertEqual(g.phase, .idle)
    }

    func testSlowSecondTapIsJustANewHold() {
        var g = HotkeyGesture()
        _ = g.keyDown(at: 0); _ = g.keyUp(at: 0.1)
        XCTAssertEqual(g.keyDown(at: 2), .start)
        XCTAssertEqual(g.phase, .holding(since: 2))
        XCTAssertEqual(g.keyUp(at: 3), .stop)
    }

    func testEscapeCancelsHoldAndHandsFree() {
        var g = HotkeyGesture()
        _ = g.keyDown(at: 0)
        XCTAssertEqual(g.escape(), .cancel)
        XCTAssertNil(g.keyUp(at: 1))          // the release after the cancel does nothing
        XCTAssertFalse(g.isRecording)
        _ = g.keyDown(at: 5); _ = g.keyUp(at: 5.1); _ = g.keyDown(at: 5.3); _ = g.keyUp(at: 5.4)
        XCTAssertEqual(g.phase, .handsFree)
        XCTAssertEqual(g.escape(), .cancel)
        XCTAssertEqual(g.phase, .idle)
        XCTAssertNil(g.escape())
    }

    func testAnotherKeyDuringAHoldCancels() {
        var g = HotkeyGesture()
        _ = g.keyDown(at: 0)
        XCTAssertEqual(g.otherKeyDown(), .cancel)
        XCTAssertNil(g.keyUp(at: 0.2))
        XCTAssertEqual(g.phase, .idle)
        // …and that release was not a tap that arms a double tap.
        XCTAssertEqual(g.keyDown(at: 0.3), .start)
        XCTAssertEqual(g.phase, .holding(since: 0.3))
    }
}
