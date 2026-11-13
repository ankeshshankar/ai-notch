import AppKit
import XCTest
@testable import DictationCore

final class PasteboardTests: XCTestCase {
    private func board() -> NSPasteboard { NSPasteboard(name: NSPasteboard.Name("notch.test.\(UUID().uuidString)")) }

    func testRestoresEveryItemAndType() throws {
        let pb = board(); defer { pb.releaseGlobally() }
        let a = NSPasteboardItem()
        a.setString("first", forType: .string)
        a.setData(Data("<b>first</b>".utf8), forType: .html)
        a.setData(Data([1, 2, 3]), forType: NSPasteboard.PasteboardType("com.example.custom"))
        let b = NSPasteboardItem()
        b.setString("second", forType: .string)
        pb.clearContents(); pb.writeObjects([a, b])

        let loan = PasteboardLoan.lend(text: "dictated text", on: pb)
        XCTAssertEqual(pb.string(forType: .string), "dictated text")
        XCTAssertEqual(pb.pasteboardItems?.count, 1)
        XCTAssertTrue(loan.giveBack())

        let items = try XCTUnwrap(pb.pasteboardItems)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].string(forType: .string), "first")
        XCTAssertEqual(items[0].data(forType: .html), Data("<b>first</b>".utf8))
        XCTAssertEqual(items[0].data(forType: NSPasteboard.PasteboardType("com.example.custom")), Data([1, 2, 3]))
        XCTAssertEqual(items[1].string(forType: .string), "second")
    }

    func testEmptyBoardIsLeftEmpty() {
        let pb = board(); defer { pb.releaseGlobally() }
        pb.clearContents()
        let loan = PasteboardLoan.lend(text: "x", on: pb)
        XCTAssertTrue(loan.giveBack())
        XCTAssertNil(pb.string(forType: .string))
    }

    func testSomethingCopiedMeanwhileIsNotOverwritten() {
        let pb = board(); defer { pb.releaseGlobally() }
        pb.clearContents(); pb.setString("old", forType: .string)
        let loan = PasteboardLoan.lend(text: "dictated", on: pb)
        pb.clearContents(); pb.setString("user copied this", forType: .string)
        XCTAssertFalse(loan.giveBack())
        XCTAssertEqual(pb.string(forType: .string), "user copied this")
    }

    func testTextIsMarkedTransientForClipboardManagers() {
        let pb = board(); defer { pb.releaseGlobally() }
        _ = PasteboardLoan.lend(text: "x", on: pb)
        XCTAssertTrue(pb.types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.TransientType")) ?? false)
    }
}
