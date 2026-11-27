import XCTest
@testable import ReviewCore

final class ReviewHandoffTests: XCTestCase {
    private func card(_ id: String, _ severity: CommentSeverity = .shouldFix, done: Bool? = nil, code: String? = nil) -> SuggestedComment {
        var c = SuggestedComment(id: id, severity: severity, path: "src/a.ts", line: 42, title: "Title \(id)", body: "Body of \(id).\nSecond line.", suggestion: code)
        c.done = done
        c.finding = "F\(id)"
        return c
    }

    private let raw: [RawComment] = [
        RawComment(id: 1, author: "Sam Poe", authorUUID: "u-me", path: "src/a.ts", line: 3, text: "my own"),
        RawComment(id: 2, author: "Alex Doe", authorUUID: "u-alex", path: "src/b.ts", line: 9, text: "Please guard this.\nSecond line.", createdOn: "2026-11-20T10:00:00Z"),
        RawComment(id: 5, parentID: 3, author: "Sam Poe", authorUUID: "u-me", text: "I will.", createdOn: "2026-11-20T12:00:00Z"),
        RawComment(id: 3, parentID: 2, author: "Alex Doe", authorUUID: "u-alex", text: "Thanks", createdOn: "2026-11-20T11:00:00Z"),
        RawComment(id: 4, author: "review-bot", authorUUID: "u-bot", text: "Summary of issues", createdOn: "2026-11-20T09:00:00Z", isBot: true),
        RawComment(id: 6, author: "Alex Doe", authorUUID: "u-alex", text: "old", resolved: true),
    ]

    func testOthersAreOpenTopLevelNotMine() {
        let result = HandoffComments.others(raw, me: "u-me")
        XCTAssertEqual(result.open.map(\.id), [2, 4], "mine and resolved are out, the bot is in")
        XCTAssertEqual(result.resolved, 1)
        XCTAssertTrue(result.open[1].isBot)
        XCTAssertEqual(result.open[0].replies.map(\.text), ["Thanks", "I will."], "replies in time order, a chain included")
        XCTAssertEqual(result.open[0].replies.map(\.byMe), [false, true])
    }

    func testUnknownMeKeepsEveryone() {
        XCTAssertEqual(HandoffComments.others(raw, me: nil).open.map(\.id), [1, 2, 4])
    }

    func testBotNames() {
        XCTAssertTrue(BotName.isBot(name: "review-bot", type: nil))
        XCTAssertTrue(BotName.isBot(name: "Some Bot", type: nil))
        XCTAssertTrue(BotName.isBot(name: "x", type: "app_user"))
        XCTAssertFalse(BotName.isBot(name: "Abbott", type: "user"))
        let page = Data(#"{"values":[{"id":1,"content":{"raw":"hi"},"user":{"display_name":"ci-bot","uuid":"u","type":"user"}}]}"#.utf8)
        XCTAssertEqual(CommentPages.parse(page)?.comments.first?.isBot, true)
        XCTAssertTrue(CommentPages.fields.contains("values.user.type"))
    }

    func testOthersFileFallback() throws {
        let data = Data(#"[{"id":10,"author":"sam","bot":false,"path":"a.ts","line":4,"body":"covered","resolved":false,"asks":true},{"id":12,"author":"ci","bot":true,"body":"summary","resolved":false},{"id":13,"author":"x","body":"gone","resolved":true}]"#.utf8)
        let result = try XCTUnwrap(HandoffComments.fromOthersFile(data))
        XCTAssertEqual(result.open.map(\.id), [10, 12])
        XCTAssertEqual(result.open[0].location, "a.ts:4")
        XCTAssertEqual(result.open[1].location, "general")
        XCTAssertTrue(result.open[1].isBot)
        XCTAssertEqual(result.resolved, 1)
        XCTAssertNil(HandoffComments.fromOthersFile(Data("nope".utf8)))
    }

    func testEnabledRule() {
        let one = HandoffComment(id: 1, author: "a", text: "t")
        XCTAssertFalse(ReviewHandoff.canCopy(cards: [], others: HandoffOthers()))
        XCTAssertFalse(ReviewHandoff.canCopy(cards: [card("1", done: true)], others: HandoffOthers(resolved: 2)))
        XCTAssertTrue(ReviewHandoff.canCopy(cards: [card("1")], others: HandoffOthers()))
        XCTAssertTrue(ReviewHandoff.canCopy(cards: [], others: HandoffOthers(open: [one])), "only other people's comments, no review")
        XCTAssertTrue(ReviewHandoff.canCopy(cards: [card("1", done: true)], others: HandoffOthers(open: [one])))
    }

    func testPromptKeepsTheQuotedPath() {
        let path = "/Users/x/Library/Application Support/AINotch/reviews/web-app-221-fix.md"
        let line = ReviewHandoff.prompt(path: path)
        XCTAssertTrue(line.hasPrefix("Read \"\(path)\" and fix what it lists"))
        XCTAssertFalse(line.contains("\n"))
        XCTAssertEqual(ReviewHandoff.fileName(repo: "web-app", number: 221), "web-app-221-fix.md")
    }

    func testNotice() {
        XCTAssertEqual(ReviewHandoff.notice(findings: 4, comments: 2, refreshFailed: false), "Copied · 4 findings, 2 comments")
        XCTAssertEqual(ReviewHandoff.notice(findings: 1, comments: 1, refreshFailed: false), "Copied · 1 finding, 1 comment")
        XCTAssertEqual(ReviewHandoff.notice(findings: 0, comments: 3, refreshFailed: true), "Copied · 3 comments · comments could not be refreshed")
    }

    func testHeadMoved() {
        XCTAssertFalse(ReviewHandoff.headMoved(reviewed: "abc123def456", current: "abc123def456789"))
        XCTAssertTrue(ReviewHandoff.headMoved(reviewed: "abc123def456", current: "fff123def456"))
        XCTAssertFalse(ReviewHandoff.headMoved(reviewed: nil, current: "abc"))
        XCTAssertFalse(ReviewHandoff.headMoved(reviewed: "abc", current: nil))
    }

    func testMarkdownKeepsTheTodoLeavesOutDoneAndShowsFullText() {
        let others = HandoffComments.others(raw, me: "u-me")
        let md = ReviewHandoff.markdown(HandoffInput(
            repo: "web-app", number: 221, title: "Cache the thumbnails", source: "feature/x", target: "main", reviewedHead: "aaa111", currentHead: "bbb222",
            cards: [card("1", .blocking, code: "user.photo = DEFAULT;"), card("2", done: true), card("3", .nit)],
            others: others, reportPath: "/r/web-app-221-aaa111/review.md"))
        XCTAssertTrue(md.contains("# Fix list: web-app #221"))
        XCTAssertTrue(md.contains("feature/x -> main") && md.contains("Review ran on commit: aaa111"))
        XCTAssertTrue(md.contains("the review is of an older commit"))
        XCTAssertTrue(md.contains("2 to fix, 1 already done (left out)"))
        XCTAssertTrue(md.contains("[Blocking] src/a.ts:42 (F1)") && md.contains("Body of 1.\nSecond line.") && md.contains("```\nuser.photo = DEFAULT;\n```"))
        XCTAssertFalse(md.contains("Body of 2."), "a ticked card is left out")
        XCTAssertTrue(md.contains("2 open, 1 resolved (left out)"))
        XCTAssertTrue(md.contains("Alex Doe · src/b.ts:9") && md.contains("review-bot (bot) · general"))
        XCTAssertTrue(md.contains("> Please guard this.\n> Second line.") && md.contains("- you:\n  > I will."))
        XCTAssertFalse(md.contains("my own"))
        XCTAssertTrue(md.hasSuffix("Full report with the evidence: \"/r/web-app-221-aaa111/review.md\"\n"))
    }

    func testMarkdownSameHeadFailedRefreshAndNoReview() {
        let same = ReviewHandoff.markdown(HandoffInput(repo: "r", number: 1, title: "t", reviewedHead: "aaa", currentHead: "aaa", cards: [card("1")], refreshFailed: true, reportPath: "/p/review.md"))
        XCTAssertFalse(same.contains("older commit"))
        XCTAssertTrue(same.contains("Comments could not be refreshed"))
        XCTAssertTrue(same.contains("None open."))
        let none = ReviewHandoff.markdown(HandoffInput(repo: "r", number: 1, title: "t", others: HandoffOthers(open: [HandoffComment(id: 1, author: "A", text: "x")])))
        XCTAssertTrue(none.contains("No review has been run") && none.contains("None: no review was run.") && none.contains("There is no full report yet"))
        let allDone = ReviewHandoff.markdown(HandoffInput(repo: "r", number: 1, title: "t", reviewedHead: "aaa", cards: [card("1", done: true)]))
        XCTAssertTrue(allDone.contains("None left to fix (1 already done)."))
    }

    func testNoAccountIdsOrEmailsInTheFile() {
        let comment = HandoffComment(id: 1, author: "Alex", text: "Ping @{557058:11111111-2222} and mail alex@example.com about it.",
                                     replies: [HandoffReply(author: "Sam", text: "cc @{999:abc}")])
        let md = ReviewHandoff.markdown(HandoffInput(repo: "r", number: 1, title: "t", others: HandoffOthers(open: [comment])))
        XCTAssertFalse(md.contains("557058") || md.contains("alex@example.com") || md.contains("999:abc"))
        XCTAssertTrue(md.contains("@someone") && md.contains("<email>"))
    }
}
