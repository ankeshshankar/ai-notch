import XCTest
@testable import ReviewCore

final class ReviewRepliesTests: XCTestCase {
    private func page() -> Data {
        Data("""
        {"values":[
         {"id":301,"content":{"raw":"Check the owner."},"user":{"display_name":"Sam Poe","uuid":"u-me"},"inline":{"path":"src/a.ts","to":42},"created_on":"2026-11-20T10:00:00+00:00"},
         {"id":302,"parent":{"id":301},"content":{"raw":"Done in the next commit."},"user":{"display_name":"Alex Doe","uuid":"u-alex"},"created_on":"2026-11-20T11:00:00+00:00"},
         {"id":303,"parent":{"id":302},"content":{"raw":"Thanks, checking."},"user":{"display_name":"Sam Poe","uuid":"u-me"},"created_on":"2026-11-20T12:00:00+00:00"},
         {"id":304,"parent":{"id":303},"content":{"raw":"Why not a guard?"},"user":{"display_name":"Alex Doe","uuid":"u-alex"},"created_on":"2026-11-20T13:00:00+00:00"},
         {"id":305,"content":{"raw":"Unrelated"},"user":{"display_name":"Alex Doe","uuid":"u-alex"},"created_on":"2026-11-20T09:00:00+00:00"},
         {"id":306,"parent":{"id":305},"content":{"raw":"Reply to someone else"},"user":{"display_name":"Sam Poe","uuid":"u-me"},"created_on":"2026-11-20T09:30:00+00:00"},
         {"id":307,"parent":{"id":301},"deleted":true,"content":{"raw":"gone"},"user":{"display_name":"Alex Doe","uuid":"u-alex"}}
        ],"next":null}
        """.utf8)
    }

    func testThreadsFollowTheParentChain() throws {
        let comments = try XCTUnwrap(CommentPages.parse(page())).comments
        XCTAssertEqual(comments.count, 6)
        XCTAssertEqual(comments.first?.parentID, nil)
        XCTAssertEqual(comments[1].parentID, 301)
        let roots = ReplyThreads.roots(in: comments, postedIDs: [], me: "u-me")
        XCTAssertEqual(roots, [301], "a reply of mine under someone else is no root")
        let threads = ReplyThreads.build(comments, roots: roots, me: "u-me")
        XCTAssertEqual(threads.map(\.id), [301])
        XCTAssertEqual(threads[0].replies.map(\.id), [302, 303, 304])
        XCTAssertEqual(threads[0].replies.map(\.byMe), [false, true, false])
        XCTAssertEqual(threads[0].location, "src/a.ts:42")
        XCTAssertEqual(threads[0].lastTheirs?.id, 304)
    }

    func testPostedIDsAreRootsWithoutAUser() throws {
        let comments = try XCTUnwrap(CommentPages.parse(page())).comments
        let threads = ReplyThreads.build(comments, roots: ReplyThreads.roots(in: comments, postedIDs: [301], me: nil), me: nil)
        XCTAssertEqual(threads.map(\.id), [301])
        XCTAssertTrue(threads[0].replies.allSatisfy { !$0.byMe })
    }

    func testSeenCounting() throws {
        let comments = try XCTUnwrap(CommentPages.parse(page())).comments
        let threads = ReplyThreads.build(comments, roots: [301], me: "u-me")
        XCTAssertEqual(ReplySeen.unseen(threads, seen: []), 2, "my own reply never counts")
        XCTAssertEqual(ReplySeen.unseen(threads, seen: [302]), 1)
        XCTAssertEqual(ReplySeen.unseen(threads, seen: ReplySeen.allIDs(threads)), 0)
        XCTAssertEqual(ReplySeen.unseenIDs(threads, seen: [302]), [304])
        XCTAssertEqual(ReplySeen.label(1), "1 reply")
        XCTAssertEqual(ReplySeen.label(3), "3 replies")
        XCTAssertEqual(ReplySeen.label(0), "")
    }

    func testReplyBlocksParse() {
        let text = """
        Here is what I found.

        ```reply
        {"comment": 301, "verdict": "fixed", "reason": "Owner check at a.ts:44", "draft": "should be dropped"}
        ```
        ```reply {"comment":302,"verdict":"disagrees","reason":"Still cleared","draft":"Can we set the default instead?"}```
        ```reply
        [{"comment": 303, "verdict": "Question", "reason": "asks about the cache", "draft": "It is dropped on upload."}]
        ```
        ```reply
        {"comment": 304, "verdict": "maybe"}
        ```
        ```reply
        not json
        ```
        VERDICT: APPROVE
        """
        let parsed = ReplyBlocks.parse(text)
        XCTAssertEqual(parsed.analyses.map(\.commentID), [301, 302, 303])
        XCTAssertEqual(parsed.analyses.map(\.verdict), [.fixed, .notFixed, .question])
        XCTAssertNil(parsed.analyses[0].draft, "a plain fixed thread gets no draft")
        XCTAssertEqual(parsed.analyses[1].draft, "Can we set the default instead?")
        XCTAssertEqual(parsed.skipped, 2)
    }

    func testFileKeepsReadsUntilANewerReply() throws {
        let comments = try XCTUnwrap(CommentPages.parse(page())).comments
        var file = RepliesFile()
        file.update(threads: ReplyThreads.build(comments, roots: [301], me: "u-me"), at: 1)
        let thread = file.threads[0]
        XCTAssertTrue(file.needsAttention(thread))
        XCTAssertNil(file.analysis(thread))
        file.apply([ReplyAnalysis(commentID: 301, verdict: .question, reason: "asks why")])
        XCTAssertEqual(file.analysis(thread)?.upTo, 304)
        file.kept[301] = 304
        XCTAssertFalse(file.needsAttention(thread), "kept open until a newer reply")
        var newer = thread
        newer.replies.append(ThreadReply(id: 310, parentID: 304, author: "Alex Doe", byMe: false, text: "ping"))
        file.update(threads: [newer], at: 2)
        XCTAssertTrue(file.needsAttention(newer))
        XCTAssertNil(file.analysis(newer), "a newer reply makes the read stale")
        let again = try JSONDecoder().decode(RepliesFile.self, from: JSONEncoder().encode(file))
        XCTAssertEqual(again, file)
    }

    func testReplyPayloadAndWording() throws {
        let body = String(decoding: ReplyPayload.json(parent: 301, body: "Makes sense, thanks."), as: UTF8.self)
        XCTAssertEqual(body, #"{"content":{"raw":"Makes sense, thanks."},"parent":{"id":301}}"#)
        XCTAssertFalse(ReplyPayload.problems("  ").isEmpty)
        XCTAssertFalse(ReplyPayload.problems("Claude says this is fine.").isEmpty)
        XCTAssertTrue(ReplyPayload.problems("Makes sense, thanks.").isEmpty)
    }

    func testPromptsCarryThreadsAndAlert() throws {
        let comments = try XCTUnwrap(CommentPages.parse(page())).comments
        let threads = ReplyThreads.build(comments, roots: [301], me: "u-me")
        let digest = ReplyRead.digest(threads, analyses: [:])
        XCTAssertTrue(digest.contains("comment 301") && digest.contains("Why not a guard?"))
        XCTAssertTrue(ReviewChat.systemPrompt(cards: [], existing: [], head: nil, scratch: "/s", replies: digest).contains("Why not a guard?"))
        XCTAssertFalse(ReviewChat.systemPrompt(cards: [], existing: [], head: nil, scratch: "/s").contains("Replies from the author"))
        let input = String(decoding: ReplyRead.inputJSON(head: "abc", threads: threads), as: UTF8.self)
        XCTAssertTrue(input.contains("\"commentId\" : 301"))
        var record = ReviewRecord(key: "acme/web-app#7", head: "abc", phase: .done, auto: true, queuedAt: 1)
        record.verdict = .approve
        record.findings = ReviewFindings()
        XCTAssertFalse(ReviewWaiting.notificationText(id: 7, repo: "web-app", record: record).contains("repl"))
        XCTAssertTrue(ReviewWaiting.notificationText(id: 7, repo: "web-app", record: record, newReplies: 2).hasSuffix("2 new replies"))
        XCTAssertTrue(ReviewWaiting.notificationText(id: 7, repo: "web-app", record: record, newReplies: 1).hasSuffix("1 new reply"))
    }
}
