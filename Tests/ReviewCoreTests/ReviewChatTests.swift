import XCTest
@testable import ReviewCore

final class CommentBlockTests: XCTestCase {
    func testParsesFencedBlockAndStripsItFromProse() {
        let text = """
        Softer, as asked.

        ```comment
        {"path": "src/a.ts", "line": 12, "severity": "should-fix", "body": "Could this be null here? A guard would avoid the crash.", "replaces": "c2"}
        ```

        Anything else?
        """
        let parsed = CommentBlocks.parse(text)
        XCTAssertEqual(parsed.drafts.count, 1)
        XCTAssertEqual(parsed.drafts[0].replaces, "c2")
        XCTAssertEqual(parsed.drafts[0].comment.path, "src/a.ts")
        XCTAssertEqual(parsed.drafts[0].comment.line, 12)
        XCTAssertEqual(parsed.drafts[0].comment.severity, .shouldFix)
        XCTAssertEqual(parsed.prose, "Softer, as asked.\n\nAnything else?")
        XCTAssertEqual(parsed.skipped, 0)
    }

    func testToleratesJunkAndLooseShapes() {
        let text = """
        ```comment
        not json at all
        ```
        ```comment json
        [{"file": "b.ts:7", "severity": "NITPICK", "comment": "rename x"}, {"severity": "nit"}]
        ```
        ```comment {"body": "general note", "line": 3}```
        """
        let parsed = CommentBlocks.parse(text)
        XCTAssertEqual(parsed.drafts.count, 2)
        XCTAssertEqual(parsed.skipped, 2)
        XCTAssertEqual(parsed.drafts[0].comment.path, "b.ts")
        XCTAssertEqual(parsed.drafts[0].comment.line, 7)
        XCTAssertEqual(parsed.drafts[0].comment.severity, .nit)
        // No path: the line means nothing, so it is a general comment.
        XCTAssertNil(parsed.drafts[1].comment.path)
        XCTAssertNil(parsed.drafts[1].comment.line)
        XCTAssertEqual(parsed.drafts[1].comment.body, "general note")
    }

    func testUnfinishedBlockWhileStreamingShowsNothing() {
        let parsed = CommentBlocks.parse("Here:\n```comment\n{\"path\": \"a.ts\", \"bo")
        XCTAssertEqual(parsed.prose, "Here:")
        XCTAssertTrue(parsed.drafts.isEmpty)
    }

    func testCommentsFile() {
        let json = """
        {"comments": [
          {"id": "c1", "severity": "blocking", "path": "src/a.ts", "line": 4, "title": "Null", "body": "Guard this."},
          {"id": "c1", "severity": "should-fix", "path": "src/b.ts", "line": "9-12", "body": "Add a test."},
          {"severity": "weird", "body": "General."},
          {"id": "c4"}, 7
        ]}
        """
        let cards = CommentParse.file(Data(json.utf8))
        XCTAssertEqual(cards.count, 3)
        XCTAssertEqual(Set(cards.map(\.id)).count, 3)
        XCTAssertEqual(cards[1].line, 9)
        XCTAssertEqual(cards[2].severity, .shouldFix)
        XCTAssertTrue(CommentParse.file(Data("nonsense".utf8)).isEmpty)
    }
}

final class CommentPayloadTests: XCTestCase {
    private func object(_ data: Data) -> [String: Any] { (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:] }

    func testInlinePayload() {
        let data = CommentPayload.json(path: "src/a.ts", line: 12, body: "Guard this.")
        let json = object(data)
        XCTAssertEqual((json["content"] as? [String: Any])?["raw"] as? String, "Guard this.")
        let inline = json["inline"] as? [String: Any]
        XCTAssertEqual(inline?["path"] as? String, "src/a.ts")
        XCTAssertEqual(inline?["to"] as? Int, 12)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"content":{"raw":"Guard this."},"inline":{"path":"src\/a.ts","to":12}}"#.replacingOccurrences(of: "\\/", with: "/"))
    }

    func testGeneralCommentHasNoInline() {
        let json = object(CommentPayload.json(path: nil, line: nil, body: "Looks fine overall."))
        XCTAssertNil(json["inline"])
        XCTAssertNotNil(json["content"])
    }

    func testEndpointAndCreatedID() {
        XCTAssertEqual(CommentPayload.endpoint(apiBase: "https://api.bitbucket.org/2.0", workspace: "acme", repo: "web-app", id: 7),
                       "https://api.bitbucket.org/2.0/repositories/acme/web-app/pullrequests/7/comments")
        XCTAssertEqual(CommentPayload.createdID(Data(#"{"id": 991, "type": "pullrequest_comment"}"#.utf8)), 991)
        XCTAssertNil(CommentPayload.createdID(Data("x".utf8)))
    }

    func testLineLink() {
        XCTAssertEqual(BitbucketLinks.lineURL(prURL: "https://bitbucket.org/acme/web-app/pull-requests/7", path: "src/a b.ts", line: 12),
                       "https://bitbucket.org/acme/web-app/pull-requests/7/diff#Lsrc/a%20b.tsT12")
    }

    func testPostPlanSkipsPostedAndSkipped() {
        var posted = SuggestedComment(id: "c1", severity: .blocking, body: "a")
        posted.postedID = 5
        let cards = [posted, SuggestedComment(id: "c2", severity: .shouldFix, body: "b"), SuggestedComment(id: "c3", severity: .nit, body: "c")]
        XCTAssertEqual(PostPlan.pending(cards).map(\.id), ["c2"])
    }
}

final class CommentPolicyTests: XCTestCase {
    func testCleanCommentPasses() {
        XCTAssertTrue(CommentPolicy.isClean("This reads `photo` without a null check, so removing it returns a 500. Set the default avatar instead."))
        XCTAssertTrue(CommentPolicy.isClean("The S3 key should start with the project prefix."))
        XCTAssertTrue(CommentPolicy.isClean("Please update the review screen copy."))
    }

    func testLensCodes() {
        XCTAssertFalse(CommentPolicy.isClean("C3 [B] delete by id with no ownership check"))
        XCTAssertFalse(CommentPolicy.isClean("B3 v1 must behave as on master"))
        XCTAssertFalse(CommentPolicy.isClean("Missing guard here — security"))
        XCTAssertFalse(CommentPolicy.isClean("BLOCKING: missing guard"))
        XCTAssertFalse(CommentPolicy.isClean("Guard this [B]"))
    }

    func testAIMentions() {
        XCTAssertFalse(CommentPolicy.isClean("Claude found this in the null check"))
        XCTAssertFalse(CommentPolicy.isClean("The AI review flagged this line"))
        XCTAssertFalse(CommentPolicy.isClean("As the review noted, this leaks"))
        XCTAssertFalse(CommentPolicy.isClean("an automated bot said so"))
        XCTAssertTrue(CommentPolicy.isClean("Ordinary maintenance work, nothing to flag."))
    }

    func testPostPlanBlocksBadWording() {
        let cards = [SuggestedComment(id: "c1", severity: .blocking, body: "Claude says this is wrong"), SuggestedComment(id: "c2", severity: .blocking, body: "Guard the null.")]
        XCTAssertEqual(Array(PostPlan.blocked(cards).keys), ["c1"])
    }
}

final class CardTests: XCTestCase {
    func testDefaultsBySeverity() {
        XCTAssertTrue(SuggestedComment(id: "a", severity: .blocking, body: "x").include)
        XCTAssertTrue(SuggestedComment(id: "b", severity: .shouldFix, body: "x").include)
        XCTAssertFalse(SuggestedComment(id: "c", severity: .nit, body: "x").include)
        XCTAssertEqual(SuggestedComment(id: "d", severity: .nit, body: "x", include: true).include, true)
        XCTAssertTrue(SuggestedComment(id: "e", severity: .preExisting, body: "x").include)
        XCTAssertEqual(CommentSeverity.allCases.map(\.label), ["Blocking", "Should fix", "Was already there", "Nit"])
    }

    func testDedupeAgainstExistingComments() throws {
        let page = """
        {"values": [
          {"id": 1, "content": {"raw": "Please add a guard."}, "user": {"display_name": "Jane Doe"}, "inline": {"path": "src/a.ts", "to": 12}},
          {"id": 2, "deleted": true, "content": {"raw": "gone"}, "inline": {"path": "src/b.ts", "to": 3}},
          {"id": 3, "content": {"raw": "Overall fine"}, "user": {"display_name": "John Roe"}}
        ], "next": "https://api.example.test/next"}
        """
        let parsed = try XCTUnwrap(ExistingComments.parse(Data(page.utf8)))
        XCTAssertEqual(parsed.comments.map(\.id), [1, 3])
        XCTAssertEqual(parsed.next, "https://api.example.test/next")
        let same = SuggestedComment(id: "c1", severity: .shouldFix, path: "src/a.ts", line: 12, body: "Different words")
        let other = SuggestedComment(id: "c2", severity: .shouldFix, path: "src/a.ts", line: 40, body: "Another point")
        let general = SuggestedComment(id: "c3", severity: .nit, body: "overall fine!")
        let deleted = SuggestedComment(id: "c4", severity: .nit, path: "src/b.ts", line: 3, body: "something")
        XCTAssertEqual(CommentDedupe.duplicate(of: same, in: parsed.comments)?.id, 1)
        XCTAssertNil(CommentDedupe.duplicate(of: other, in: parsed.comments))
        XCTAssertEqual(CommentDedupe.duplicate(of: general, in: parsed.comments)?.id, 3)
        XCTAssertNil(CommentDedupe.duplicate(of: deleted, in: parsed.comments))
    }

    func testChatCardsReviseInPlaceOrAddNew() {
        var log = ChatLog()
        var posted = SuggestedComment(id: "c3", severity: .blocking, path: "a.ts", line: 1, body: "old posted")
        posted.postedID = 9
        log.seed([SuggestedComment(id: "c1", severity: .blocking, path: "a.ts", line: 2, body: "Harsh."), SuggestedComment(id: "c2", severity: .nit, body: "nit"), posted])
        log.cards[0].include = false
        let drafts = [
            CommentDraft(comment: SuggestedComment(id: "n1", severity: .shouldFix, path: "a.ts", line: 2, body: "Softer."), replaces: "c1"),
            CommentDraft(comment: SuggestedComment(id: "n2", severity: .nit, path: "b.ts", line: 5, body: "New one."), replaces: nil),
            CommentDraft(comment: SuggestedComment(id: "n3", severity: .blocking, path: "a.ts", line: 1, body: "Revised after posting."), replaces: "c3"),
        ]
        let touched = log.apply(drafts)
        XCTAssertEqual(touched.revised, ["c1"])
        XCTAssertEqual(touched.new, ["n2", "n3"])
        XCTAssertEqual(log.cards[0].body, "Softer.")
        XCTAssertEqual(log.cards[0].severity, .shouldFix)
        // The Add / Skip switch of a revised card stays where the user put it.
        XCTAssertFalse(log.cards[0].include)
        XCTAssertEqual(log.cards.count, 5)
        XCTAssertEqual(log.cards[2].body, "old posted")
        // The same proposal twice adds nothing.
        XCTAssertTrue(log.apply([drafts[1]]).new.isEmpty)
    }

    func testChatLogRoundTrip() throws {
        var log = ChatLog()
        log.sessionID = "abc"
        log.seed([SuggestedComment(id: "c1", severity: .nit, path: "a.ts", line: 1, body: "x")])
        log.messages = [ChatMessage(role: .user, text: "hi", at: 1)]
        let data = try JSONEncoder().encode(log)
        XCTAssertEqual(try JSONDecoder().decode(ChatLog.self, from: data), log)
    }
}

final class ChatCommandTests: XCTestCase {
    private let args = ReviewChat.arguments(sessionID: "sess-1", scratch: "/s/r1", systemPrompt: "SYS", agentsJSON: "{}", hookCommand: "/h/hook", home: "/home/u")

    private func value(after flag: String) -> String? {
        args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
    }

    func testResumesTheSameSessionWithoutForking() {
        XCTAssertEqual(value(after: "--resume"), "sess-1")
        XCTAssertFalse(args.contains("--fork-session"))
        XCTAssertFalse(args.contains("--continue"))
        XCTAssertEqual(args.first, "-p")
    }

    func testStreamsAndKeepsTheReviewsLimits() {
        XCTAssertEqual(value(after: "--output-format"), "stream-json")
        XCTAssertTrue(args.contains("--verbose"))
        XCTAssertTrue(args.contains("--include-partial-messages"))
        XCTAssertEqual(value(after: "--setting-sources"), "")
        XCTAssertEqual(value(after: "--permission-mode"), "dontAsk")
        XCTAssertEqual(value(after: "--append-system-prompt"), "SYS")
        // The very same allow and deny lists as the review itself.
        let review = ReviewCommand.arguments(prNumber: 1, scratch: "/s/r1", skill: "body", agentsJSON: "{}", hookCommand: "/h/hook", home: "/home/u")
        func list(_ flag: String, in a: [String]) -> String? { a.firstIndex(of: flag).map { a[$0 + 1] } }
        XCTAssertEqual(value(after: "--allowedTools"), list("--allowedTools", in: review))
        XCTAssertEqual(value(after: "--disallowedTools"), list("--disallowedTools", in: review))
        XCTAssertEqual(value(after: "--settings"), list("--settings", in: review))
        XCTAssertTrue(args.contains("/s/r1"))
        // Nothing of the message is on the command line, and no write outside the folder is allowed.
        let allowed = value(after: "--allowedTools") ?? ""
        XCTAssertTrue(allowed.contains("Write(//s/r1/**)") || allowed.contains("Write(/" + "/s/r1/**)"))
        XCTAssertFalse(allowed.contains("git commit"))
        XCTAssertFalse(allowed.contains("git push"))
    }

    func testSystemPromptHasTheBlockFormatCardsAndExistingComments() {
        let cards = [SuggestedComment(id: "c1", severity: .blocking, path: "a.ts", line: 3, body: "Guard this.")]
        let existing = [ExistingComment(id: 4, author: "Jane Doe", path: "b.ts", line: 8, text: "Typo")]
        let text = ReviewChat.systemPrompt(cards: cards, existing: existing, head: "0123456789abcdef", scratch: "/s/r1")
        XCTAssertTrue(text.contains("```comment"))
        XCTAssertTrue(text.contains("replaces"))
        XCTAssertTrue(ReviewChat.turnPrompt("Soften c2").hasPrefix("Soften c2"))
        XCTAssertTrue(ReviewChat.turnPrompt("x").contains("```comment"))
        XCTAssertTrue(text.contains("Never edit or rewrite comments.json"))
        XCTAssertTrue(text.contains("c1 [blocking] a.ts:3"))
        XCTAssertTrue(text.contains("b.ts:8 (Jane Doe): Typo"))
        XCTAssertTrue(text.contains("0123456789ab"))
        XCTAssertTrue(ReviewChat.commentsInstruction(scratch: "/s/r1").contains("/s/r1/comments.json"))
        XCTAssertTrue(ReviewCommand.prompt(prNumber: 3, scratch: "/s/r1", skill: "body").contains("comments.json"))
    }

    func testStreamEvents() {
        let init_ = #"{"type":"system","subtype":"init","session_id":"sess-1"}"#
        XCTAssertEqual(ChatStream.events(line: init_), [.session("sess-1")])
        let delta = #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hel"}}}"#
        XCTAssertEqual(ChatStream.events(line: delta), [.textDelta("Hel")])
        let tool = #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/x/y/profile.ts"}}]}}"#
        XCTAssertEqual(ChatStream.events(line: tool), [.tool("Read profile.ts")])
        let result = #"{"type":"result","subtype":"success","is_error":false,"result":"Done","session_id":"sess-1","total_cost_usd":0.5,"permission_denials":[{"tool_name":"Bash"},{"tool_name":"Bash"}]}"#
        XCTAssertEqual(ChatStream.events(line: result), [.result(ChatResult(text: "Done", isError: false, sessionID: "sess-1", costUSD: 0.5, denied: ["Bash"]))])
        XCTAssertTrue(ChatStream.events(line: "not json").isEmpty)
        XCTAssertTrue(ChatStream.events(line: #"{"type":"rate_limit_event"}"#).isEmpty)
    }

    func testReviewOutputCarriesTheSessionID() {
        let output = ReviewOutput.parse(Data(#"{"result":"r","is_error":false,"session_id":"abc"}"#.utf8))
        XCTAssertEqual(output?.sessionID, "abc")
    }
}
