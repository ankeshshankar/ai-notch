import XCTest
@testable import ReviewCore

final class ReviewModelsTests: XCTestCase {
    private func value(after flag: String, in args: [String]) -> String? {
        args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
    }

    func testFullAndFollowUpRunsPassTheModel() {
        let full = ReviewCommand.arguments(prNumber: 5, scratch: "/tmp/s", skill: "x", agentsJSON: "{}")
        XCTAssertEqual(value(after: "--model", in: full), "claude-opus-5-5")
        let follow = FollowUp.arguments(scratch: "/tmp/s", hookCommand: nil, prompt: "p")
        XCTAssertEqual(value(after: "--model", in: follow), "claude-opus-5-5")
        let replies = FollowUp.arguments(scratch: "/tmp/s", hookCommand: nil, prompt: "p", model: ReviewModels.replies)
        XCTAssertEqual(value(after: "--model", in: replies), "claude-haiku-5-5")
    }

    func testAnalysisKeepsModelAndDisagreement() throws {
        var file = RepliesFile()
        file.update(threads: [ReplyThread(id: 7, text: "x", replies: [ThreadReply(id: 8, parentID: 7, author: "A", byMe: false, text: "no")])], at: 1)
        let parsed = ReplyBlocks.parse("```reply\n{\"comment\":7,\"verdict\":\"explained\",\"reason\":\"ok\",\"disagrees\":true}\n```")
        let unknown = file.apply(parsed.analyses + [ReplyAnalysis(commentID: 99, verdict: .fixed, reason: "")], model: ReviewModels.reread)
        XCTAssertEqual(unknown, [99])
        let saved = try JSONDecoder().decode(RepliesFile.self, from: JSONEncoder().encode(file))
        XCTAssertEqual(saved.analyses[7]?.model, "claude-opus-5-5")
        XCTAssertEqual(saved.analyses[7]?.disagrees, true)
        XCTAssertTrue(saved.analyses[7]?.isCorrectDisagreement ?? false)
        XCTAssertEqual(saved.analyses.count, 1)
    }

    func testUnreadToTryIsOncePerNewestReply() {
        var file = RepliesFile()
        let thread = ReplyThread(id: 7, text: "x", replies: [ThreadReply(id: 8, parentID: 7, author: "A", byMe: false, text: "no")])
        file.update(threads: [thread], at: 1)
        XCTAssertEqual(file.unreadToTry().map(\.id), [7])
        file.markTried([thread])
        XCTAssertTrue(file.unreadToTry().isEmpty)
    }
}
