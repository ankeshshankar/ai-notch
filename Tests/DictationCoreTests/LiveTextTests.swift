import XCTest
@testable import DictationCore

final class LiveTextTests: XCTestCase {
    func testSeparator() {
        XCTAssertEqual(LiveText.separator(after: "", before: "hello"), "")
        XCTAssertEqual(LiveText.separator(after: "Hello", before: "world"), " ")
        XCTAssertEqual(LiveText.separator(after: "Hello\n", before: "world"), "")
        XCTAssertEqual(LiveText.separator(after: "Hello ", before: "world"), "")
        XCTAssertEqual(LiveText.separator(after: "Hello", before: ", world"), "")
        XCTAssertEqual(LiveText.separator(after: "Hello", before: "\nworld"), "")
    }

    func testStartsSentence() {
        XCTAssertTrue(LiveText.startsSentence(after: ""))
        XCTAssertTrue(LiveText.startsSentence(after: "Done."))
        XCTAssertTrue(LiveText.startsSentence(after: "Done? "))
        XCTAssertTrue(LiveText.startsSentence(after: "Done\n"))
        XCTAssertFalse(LiveText.startsSentence(after: "Done and"))
        XCTAssertFalse(LiveText.startsSentence(after: "Done,"))
    }

    func testPhraseKeepsMidSentenceLowercase() {
        XCTAssertEqual(LiveText.phrase("hello there", typedSoFar: ""), "Hello there")
        // Mid-sentence: no new capital, no full stop added, one space between phrases.
        XCTAssertEqual(LiveText.phrase("and then we left", typedSoFar: "Hello there"), " and then we left")
        // After a sentence mark: capital again.
        XCTAssertEqual(LiveText.phrase("next item", typedSoFar: "Hello there."), " Next item")
        XCTAssertEqual(LiveText.phrase("next item", typedSoFar: "Hello there.\n"), "Next item")
    }

    func testPhraseRulesAndPronoun() {
        XCTAssertEqual(LiveText.phrase("um so i think", typedSoFar: "Well"), " so I think")
        XCTAssertEqual(LiveText.phrase("question mark", typedSoFar: "Are you sure"), "?")
        XCTAssertEqual(LiveText.phrase("  um  ", typedSoFar: "Well"), "")
        XCTAssertEqual(LiveText.phrase("", typedSoFar: "Well"), "")
    }

    func testPhraseKeepsSpokenBreaksAndMarks() {
        XCTAssertEqual(LiveText.phrase("new line", typedSoFar: "Hello there."), "\n")
        XCTAssertEqual(LiveText.phrase("new paragraph", typedSoFar: "Hello"), "\n\n")
        XCTAssertEqual(LiveText.phrase("comma", typedSoFar: "Hello"), ",")
        XCTAssertEqual(LiveText.phrase("buy apples new line", typedSoFar: ""), "Buy apples\n")
        XCTAssertEqual(LiveText.phrase("then we left", typedSoFar: "Buy apples\n"), "Then we left")
    }

    func testPhraseTransliteratesDevanagari() {
        let out = LiveText.phrase("मैं ठीक हूँ", typedSoFar: "")
        XCTAssertFalse(LatinScript.containsDevanagari(out))
        XCTAssertFalse(out.isEmpty)
    }

    func testChunks() {
        XCTAssertEqual(LiveText.chunks("", size: 4), [])
        XCTAssertEqual(LiveText.chunks("abcdefghij", size: 4), ["abcd", "efgh", "ij"])
        XCTAssertEqual(LiveText.chunks("abcdefghij", size: 4).joined(), "abcdefghij")
        // Never inside a character: an emoji is two UTF-16 units, a flag four.
        let text = "ab😀cd🇮🇳ef"
        let parts = LiveText.chunks(text, size: 3)
        XCTAssertEqual(parts.joined(), text)
        XCTAssertTrue(parts.contains("😀") || parts.contains { $0.contains("😀") })
        for p in parts { XCTAssertTrue(p.utf16.count <= 4) }
        XCTAssertEqual(LiveText.chunks("🇮🇳", size: 2), ["🇮🇳"])
    }

    func testCaptionShortFits() {
        let c = LiveText.caption(final: "Hello there", volatile: "how are", limit: 40)
        XCTAssertEqual(c, LiveText.Caption(final: "Hello there", volatile: "how are", cut: false))
    }

    func testCaptionCutsFromLeftAtWord() {
        let c = LiveText.caption(final: "one two three four", volatile: "five six", limit: 18)
        XCTAssertTrue(c.cut)
        XCTAssertEqual(c.volatile, "five six")
        XCTAssertTrue("four three".contains(c.final.split(separator: " ").first ?? "x") || c.final == "four")
        XCTAssertTrue(c.final.count + c.volatile.count + 1 <= 18)
        XCTAssertFalse(c.final.hasPrefix("hree"))
    }

    func testCaptionVolatileOnlyAndEmpty() {
        XCTAssertTrue(LiveText.caption(final: "", volatile: "", limit: 10).isEmpty)
        let c = LiveText.caption(final: "", volatile: "alpha beta gamma delta", limit: 12)
        XCTAssertEqual(c.final, "")
        XCTAssertEqual(c.volatile, "gamma delta")
        XCTAssertTrue(c.cut)
    }

    func testCaptionWholeVolatileLongerThanLimitKeepsNewest() {
        let c = LiveText.caption(final: "old words", volatile: "a very long volatile tail here", limit: 10)
        XCTAssertEqual(c.final, "")
        XCTAssertTrue(c.volatile.hasSuffix("here"))
        XCTAssertTrue(c.volatile.count <= 10)
    }
}
