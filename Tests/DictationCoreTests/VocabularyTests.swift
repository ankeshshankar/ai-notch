import XCTest
@testable import DictationCore

final class VocabularyTests: XCTestCase {
    func testParseSplitsLinesAndCommas() {
        XCTAssertEqual(DictationVocabulary.parse("Priya, Arjun\n  api-service ;\n\n"), ["Priya", "Arjun", "api-service"])
    }

    func testMergedOrderDedupeAndCap() {
        let m = DictationVocabulary.merged(dynamic: ["feat/x", "Figma"], user: ["figma", "Arjun"], builtIn: ["PR", "FIGMA", "Expo"])
        XCTAssertEqual(m, ["feat/x", "Figma", "Arjun", "PR", "Expo"])
        let many = (0..<500).map { "term\($0)" }
        XCTAssertEqual(DictationVocabulary.merged(user: many).count, DictationVocabulary.limit)
    }

    func testBranchHints() {
        XCTAssertEqual(DictationVocabulary.hints(fromName: "feat/dictation-quality"), ["feat/dictation-quality", "dictation", "quality"])
        XCTAssertTrue(DictationVocabulary.hints(fromName: "HEAD").isEmpty)
        XCTAssertTrue(DictationVocabulary.hints(fromName: "main").count == 1)
    }

    func testPromptCarriesVocabularyAndKeepsRules() {
        let p = CleanupPrompt.systemPrompt(style: .keepMyWords, context: .terminal, appName: "Ghostty", vocabulary: ["Bitbucket", "bad<tag>\nline"])
        XCTAssertTrue(p.contains("Bitbucket, badtagline"))
        XCTAssertTrue(p.contains("Never use Devanagari"))
        XCTAssertFalse(CleanupPrompt.systemPrompt(style: .keepMyWords, context: .chat, appName: nil).contains("technical terms"))
    }
}
