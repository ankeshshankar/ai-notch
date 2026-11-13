import XCTest
@testable import DictationCore

final class RuleCleanerTests: XCTestCase {
    func testTrimsCollapsesAndCapitalises() {
        XCTAssertEqual(RuleCleaner.clean("   hello    world  "), "Hello world")
        XCTAssertEqual(RuleCleaner.clean("hello.   this is   it"), "Hello. This is it")
    }

    func testDropsFillers() {
        XCTAssertEqual(RuleCleaner.clean("um I think uh we should go"), "I think we should go")
        XCTAssertEqual(RuleCleaner.clean("so, um, the plan is ready"), "So, the plan is ready")
        XCTAssertEqual(RuleCleaner.clean("Umm, okay"), "Okay")
        // A word that merely contains a filler stays.
        XCTAssertEqual(RuleCleaner.clean("the umbrella and the error"), "The umbrella and the error")
    }

    func testSpokenPunctuation() {
        XCTAssertEqual(RuleCleaner.clean("hello comma how are you question mark"), "Hello, how are you?")
        XCTAssertEqual(RuleCleaner.clean("this is done full stop next item"), "This is done. Next item")
        XCTAssertEqual(RuleCleaner.clean("first line new line second line"), "First line\nSecond line")
        XCTAssertEqual(RuleCleaner.clean("intro new paragraph body"), "Intro\n\nBody")
        XCTAssertEqual(RuleCleaner.clean("wow exclamation mark"), "Wow!")
        XCTAssertEqual(RuleCleaner.clean("items colon apples semicolon pears"), "Items: apples; pears")
    }

    func testPeriodIsAWordUnlessAtTheEnd() {
        XCTAssertEqual(RuleCleaner.clean("it was a period of growth"), "It was a period of growth")
        XCTAssertEqual(RuleCleaner.clean("that is all period"), "That is all.")
    }

    func testSpokenWordWithItsOwnMarkIsAbsorbed() {
        XCTAssertEqual(RuleCleaner.clean("hello comma, world"), "Hello, world")
    }

    func testSpacingAndPronoun() {
        XCTAssertEqual(RuleCleaner.clean("hello , world ."), "Hello, world.")
        XCTAssertEqual(RuleCleaner.clean("i think i'm right"), "I think I'm right")
        XCTAssertEqual(RuleCleaner.clean("version 3.5 is out"), "Version 3.5 is out")
    }

    func testHinglishStaysAndDevanagariGoesLatin() {
        XCTAssertEqual(RuleCleaner.clean("kal meeting hai, tum aa rahe ho?"), "Kal meeting hai, tum aa rahe ho?")
        let out = RuleCleaner.clean("नमस्ते दोस्त")
        XCTAssertFalse(LatinScript.containsDevanagari(out), out)
        XCTAssertTrue(out.lowercased().hasPrefix("namaste"), out)
        XCTAssertFalse(LatinScript.containsDevanagari(RuleCleaner.clean("मैं ठीक हूँ। and you?")))
    }

    func testEmptyStaysEmpty() {
        XCTAssertEqual(RuleCleaner.clean("   "), "")
        XCTAssertEqual(RuleCleaner.clean("um uh"), "")
    }
}
