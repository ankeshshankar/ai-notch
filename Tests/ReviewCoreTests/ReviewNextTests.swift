import XCTest
@testable import ReviewCore

private func card(_ id: String, _ sev: CommentSeverity = .shouldFix, path: String? = "src/a.ts", line: Int? = 4, body: String = "Guard this value.") -> SuggestedComment {
    SuggestedComment(id: id, severity: sev, path: path, line: line, title: nil, body: body)
}

private func rec(_ key: String = "acme/web-app#7", head: String = "aaaaaaaaaaaa1", verdict: ReviewVerdict = .requestChanges,
                    findings: ReviewFindings = ReviewFindings(), at: Double = 100) -> ReviewRecord {
    var r = ReviewRecord(key: key, head: head, phase: .done, auto: false, queuedAt: at)
    r.verdict = verdict
    r.findings = findings
    r.finishedAt = at
    return r
}

final class ReviewerTests: XCTestCase {
    func testStateParsing() {
        XCTAssertEqual(ReviewerState.from(state: "approved", approved: false), .approved)
        XCTAssertEqual(ReviewerState.from(state: "changes_requested", approved: false), .changesRequested)
        XCTAssertEqual(ReviewerState.from(state: nil, approved: true), .approved)
        XCTAssertEqual(ReviewerState.from(state: nil, approved: false), .notYet)
    }

    func testRowsAndSummary() {
        let participants: [[String: Any]] = [
            ["role": "REVIEWER", "approved": true, "state": "approved", "user": ["uuid": "1", "display_name": "Jane Doe"]],
            ["role": "REVIEWER", "approved": false, "state": "changes_requested", "user": ["uuid": "2", "display_name": "Sam Roe"]],
            ["role": "PARTICIPANT", "approved": false, "user": ["uuid": "4", "display_name": "Not A Reviewer"]],
        ]
        let reviewers: [[String: Any]] = [["uuid": "3", "display_name": "Lee Poe"], ["uuid": "1", "display_name": "Jane Doe"]]
        let rows = Reviewers.parse(participants: participants, reviewers: reviewers)
        XCTAssertEqual(rows.map(\.name), ["Lee Poe", "Jane Doe", "Sam Roe"])
        XCTAssertEqual(rows.map(\.state), [.notYet, .approved, .changesRequested])
        XCTAssertEqual(rows[0].initial, "L")
        let summary = ReviewerSummary(rows)
        XCTAssertEqual(summary.text, "1/3 approved")
        XCTAssertTrue(summary.hasChanges)
        XCTAssertEqual(ReviewerSummary([]).text, "")
    }
}

final class FollowUpTests: XCTestCase {
    func testStatusBadges() {
        XCTAssertEqual(FollowUpStatus.parse("fixed").badge, "Fixed")
        XCTAssertEqual(FollowUpStatus.parse("Still open").badge, "Still open")
        XCTAssertEqual(FollowUpStatus.parse("still_open"), .stillOpen)
        XCTAssertEqual(FollowUpStatus.parse("???"), .unclear)
        XCTAssertEqual(FollowUpStatus.parse(nil).badge, "Unclear")
    }

    func testParseResult() {
        let json = """
        {"verdict": "REQUEST CHANGES", "summary": "One left.",
         "comments": [{"id": "c1", "status": "fixed", "reason": "guard added", "path": "src/a.ts", "line": 4},
                      {"commentId": 55, "status": "still_open", "reason": "same bug"}, {"status": "fixed"}],
         "new": [{"id": "f1", "severity": "blocking", "path": "src/b.ts", "line": 9, "body": "Close the handle.", "suggestion": "handle.close()"}]}
        """
        let r = FollowUp.parse(Data(json.utf8))
        XCTAssertEqual(r?.verdict, .requestChanges)
        XCTAssertEqual(r?.items.count, 2)
        XCTAssertEqual(r?.items[1].commentID, 55)
        XCTAssertEqual(r?.newCards.first?.suggestion, "handle.close()")
        XCTAssertNil(FollowUp.parse(Data("{\"verdict\": \"maybe\"}".utf8)))
        XCTAssertNil(FollowUp.parse(Data("junk".utf8)))
        XCTAssertEqual(FollowUp.parse(Data("{\"verdict\": \"approve\"}".utf8))?.verdict, .approve)
    }

    func testApplyMapsBadgesAndCounts() {
        var log = ChatLog()
        var posted = card("c2", .blocking)
        posted.postedID = 55
        log.cards = [card("c1"), posted, card("c3", .nit)]
        let result = FollowUpResult(verdict: .requestChanges, summary: "s",
                                    items: [FollowUpItem(cardID: "c1", commentID: nil, status: .fixed, reason: "done", path: nil, line: nil),
                                            FollowUpItem(cardID: nil, commentID: 55, status: .stillOpen, reason: "same", path: nil, line: nil)],
                                    newCards: [card("f1", .blocking, path: "src/n.ts", line: 2, body: "New problem.")])
        let note = log.applyFollowUp(result, from: "aaa", to: "bbb", commits: 2, at: 1)
        XCTAssertEqual(log.cards[0].status, .fixed)
        XCTAssertFalse(log.cards[0].include)
        XCTAssertEqual(log.cards[1].status, .stillOpen)
        XCTAssertNil(log.cards[2].status, "a nit on Skip the pass was not asked about is not unclear")
        XCTAssertEqual(log.cards.count, 4)
        XCTAssertEqual(note.title, "Follow-up on 2 new commits")
        XCTAssertEqual(note.counts, "1 fixed · 1 still open · 1 new")
        XCTAssertEqual(log.followUps.count, 1)
        // open findings: still-open blocking, unclear nit, new blocking.
        XCTAssertEqual(log.openFindings.blocking, 2)
        XCTAssertEqual(log.openFindings.nits, 1)
        XCTAssertEqual(log.openFindings.shouldFix, 0)
    }

    func testInputAndArgumentsAreReadOnly() {
        var log = ChatLog()
        var posted = card("c1", .blocking)
        posted.postedID = 9
        log.cards = [posted]
        let data = FollowUp.inputJSON(previousHead: "aaa", newHead: "bbb", previous: rec(), log: log,
                                      existing: [ExistingComment(id: 9, author: "Jane Doe", path: "src/a.ts", line: 4, text: "Guard this value.")])
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(object?["previousHead"] as? String, "aaa")
        XCTAssertEqual((object?["cards"] as? [[String: Any]])?.first?["bitbucketCommentId"] as? Int, 9)
        let args = FollowUp.arguments(scratch: "/tmp/s", hookCommand: nil, home: "/Users/x", prompt: "P")
        XCTAssertTrue(args.contains("dontAsk"))
        XCTAssertEqual(args[args.firstIndex(of: "--setting-sources")! + 1], "")
        XCTAssertEqual(args[args.firstIndex(of: "--disallowedTools")! + 1], ReviewCommand.deniedTools.joined(separator: ","))
        XCTAssertFalse(args.contains("--resume"))
    }

    func testPlanPicksFollowUpOnlyAfterAFinishedReview() {
        var ledger = ReviewLedger()
        XCTAssertEqual(ReviewPolicy.plan(key: "acme/web-app#7", head: "bbbbbbbbbbbb2", ledger: ledger), .full)
        ledger.set(rec())
        guard case .followUp(let base) = ReviewPolicy.plan(key: "acme/web-app#7", head: "bbbbbbbbbbbb2", ledger: ledger) else { return XCTFail("expected follow-up") }
        XCTAssertEqual(base.head, "aaaaaaaaaaaa1")
        XCTAssertEqual(ReviewPolicy.plan(key: "acme/web-app#7", head: "bbbbbbbbbbbb2", ledger: ledger, full: true), .full)
        // Same head: nothing to follow up.
        XCTAssertEqual(ReviewPolicy.plan(key: "acme/web-app#7", head: "aaaaaaaaaaaa1", ledger: ledger), .full)
    }

    func testOldChatLogStillDecodes() throws {
        let old = #"{"version":1,"cards":[],"messages":[],"seeded":false}"#
        _ = try? JSONDecoder().decode(ChatLog.self, from: Data(old.utf8))
        let log = ChatLog()
        let round = try JSONDecoder().decode(ChatLog.self, from: JSONEncoder().encode(log))
        XCTAssertEqual(round.followUps, [])
    }
}

final class CombinedActionTests: XCTestCase {
    func testPostAndRequestChangesFollowsPlainGate() {
        let r = rec(findings: ReviewFindings(blocking: 1, shouldFix: 0, nits: 0))
        let pending = [card("c1", .blocking)]
        XCTAssertEqual(ReviewGate.checkCombined(.postAndRequestChanges, pending: pending, record: r, currentHead: "aaaaaaaaaaaa1", pipeline: .green), .allowed)
        XCTAssertEqual(ReviewGate.checkCombined(.postAndRequestChanges, pending: [], record: r, currentHead: "aaaaaaaaaaaa1", pipeline: .green), .blocked("no comments switched on"))
        XCTAssertNotEqual(ReviewGate.checkCombined(.postAndRequestChanges, pending: pending, record: r, currentHead: "zzzzzzzzzzzz9", pipeline: .green), .allowed)
    }

    func testPostAndApproveRefusesBlockingCardAndRedPipeline() {
        let r = rec(verdict: .approve)
        XCTAssertEqual(ReviewGate.checkCombined(.postAndApprove, pending: [card("c1", .nit)], record: r, currentHead: "aaaaaaaaaaaa1", pipeline: .green), .allowed)
        XCTAssertNotEqual(ReviewGate.checkCombined(.postAndApprove, pending: [card("c1", .blocking)], record: r, currentHead: "aaaaaaaaaaaa1", pipeline: .green), .allowed)
        XCTAssertNotEqual(ReviewGate.checkCombined(.postAndApprove, pending: [card("c1", .nit)], record: r, currentHead: "aaaaaaaaaaaa1", pipeline: .notGreen), .allowed)
    }

    func testApproveWithCommentsWhenOnlyNitsRemain() {
        let nits = rec(verdict: .requestChanges, findings: ReviewFindings(blocking: 0, shouldFix: 0, nits: 2))
        let pending = [card("c1", .nit)]
        XCTAssertEqual(ReviewGate.checkCombined(.approveWithComments, pending: pending, record: nits, currentHead: "aaaaaaaaaaaa1", pipeline: .green), .allowed)
        XCTAssertNotEqual(ReviewGate.checkCombined(.approveWithComments, pending: pending, record: nits, currentHead: "aaaaaaaaaaaa1", pipeline: .unknown), .allowed)
        let blocking = rec(findings: ReviewFindings(blocking: 1, shouldFix: 0, nits: 0))
        XCTAssertNotEqual(ReviewGate.checkCombined(.approveWithComments, pending: pending, record: blocking, currentHead: "aaaaaaaaaaaa1", pipeline: .green), .allowed)
        let should = rec(findings: ReviewFindings(blocking: 0, shouldFix: 1, nits: 0))
        XCTAssertNotEqual(ReviewGate.checkCombined(.approveWithComments, pending: pending, record: should, currentHead: "aaaaaaaaaaaa1", pipeline: .green), .allowed)
        var own = nits
        own.own = true
        XCTAssertNotEqual(ReviewGate.checkCombined(.approveWithComments, pending: pending, record: own, currentHead: "aaaaaaaaaaaa1", pipeline: .green), .allowed)
    }

    func testOptionsAndTitles() {
        let nits = rec(findings: ReviewFindings(blocking: 0, shouldFix: 0, nits: 1))
        let options = ReviewGate.combinedOptions(pending: [card("c1", .nit)], record: nits, currentHead: "aaaaaaaaaaaa1", pipeline: .green)
        XCTAssertEqual(options.map { $0.action }, [CombinedAction.postAndRequestChanges, CombinedAction.approveWithComments])
        XCTAssertEqual(CombinedAction.postAndRequestChanges.title(count: 3), "Post 3 + Request changes")
        XCTAssertEqual(CombinedAction.postAndApprove.final, .approve)
        XCTAssertTrue(ReviewGate.combinedOptions(pending: [], record: nil, currentHead: nil, pipeline: .green).isEmpty)
    }

    func testOwnWorkIsNeverActionable() {
        var own = rec()
        own.own = true
        XCTAssertNotEqual(ReviewGate.check(.approve, record: own, currentHead: "aaaaaaaaaaaa1", pipeline: .green), .allowed)
        XCTAssertNotEqual(ReviewGate.check(.requestChanges, record: own, currentHead: "aaaaaaaaaaaa1", pipeline: .green), .allowed)
    }
}

final class PostingPayloadTests: XCTestCase {
    func testSuggestionBody() {
        var c = card("c1")
        c.suggestion = "const x = 1;"
        XCTAssertEqual(SuggestionPayload.body(for: c), "Guard this value.\n\n```suggestion\nconst x = 1;\n```")
        c.asSuggestion = false
        XCTAssertEqual(SuggestionPayload.body(for: c), "Guard this value.")
        c.asSuggestion = nil
        c.path = nil
        XCTAssertEqual(SuggestionPayload.body(for: c), "Guard this value.")
        c.path = "a.ts"
        c.suggestion = "a\n```\nb"
        XCTAssertTrue(SuggestionPayload.body(for: c).contains("````suggestion"))
    }

    func testCommentPayloadCarriesSuggestion() throws {
        var c = card("c1")
        c.suggestion = "y()"
        let json = try JSONSerialization.jsonObject(with: CommentPayload.json(for: c)) as? [String: Any]
        let raw = (json?["content"] as? [String: Any])?["raw"] as? String
        XCTAssertTrue(raw?.contains("```suggestion\ny()\n```") == true)
        XCTAssertEqual((json?["inline"] as? [String: Any])?["to"] as? Int, 4)
    }

    func testTaskPayload() throws {
        var c = card("c1", .blocking, body: "Close the handle. Otherwise it leaks.")
        XCTAssertEqual(TaskPayload.text(for: c), "Close the handle.")
        c.title = "Close handle"
        XCTAssertEqual(TaskPayload.text(for: c), "Close handle")
        XCTAssertTrue(c.wantsTask)
        c.addTask = false
        XCTAssertFalse(c.wantsTask)
        XCTAssertFalse(card("c2", .nit).wantsTask)
        let json = try JSONSerialization.jsonObject(with: TaskPayload.json(for: c, commentID: 77)) as? [String: Any]
        XCTAssertEqual((json?["content"] as? [String: Any])?["raw"] as? String, "Close handle")
        XCTAssertEqual((json?["comment"] as? [String: Any])?["id"] as? Int, 77)
        XCTAssertEqual(TaskPayload.endpoint(apiBase: "https://x/2.0", workspace: "acme", repo: "web-app", id: 7), "https://x/2.0/repositories/acme/web-app/pullrequests/7/tasks")
        XCTAssertLessThanOrEqual(TaskPayload.text(for: card("c3", body: String(repeating: "word ", count: 80))).count, 120)
        XCTAssertEqual(ResolvePayload.endpoint(apiBase: "https://x/2.0", workspace: "acme", repo: "web-app", id: 7, commentID: 9), "https://x/2.0/repositories/acme/web-app/pullrequests/7/comments/9/resolve")
    }
}

final class WaitingAndKeysTests: XCTestCase {
    func testWaitingCount() {
        var ledger = ReviewLedger()
        ledger.set(rec("acme/web-app#1", head: "aaaaaaaaaaaa1"))
        var posted = rec("acme/web-app#2", head: "bbbbbbbbbbbb1")
        posted.commentsPosted = 2
        ledger.set(posted)
        var own = rec("acme/web-app#3", head: "cccccccccccc1")
        own.own = true
        ledger.set(own)
        ledger.set(rec("acme/web-app#4", head: "dddddddddddd1"))
        var running = rec("acme/web-app#5", head: "eeeeeeeeeeee1")
        running.phase = .reviewing
        ledger.set(running)
        ledger.set(rec("acme/web-app#6", head: "ffffffffffff1"))
        let inputs = [
            WaitingInput(key: "acme/web-app#1", head: "aaaaaaaaaaaa1", decided: false, muted: false),
            WaitingInput(key: "acme/web-app#2", head: "bbbbbbbbbbbb1", decided: false, muted: false),
            WaitingInput(key: "acme/web-app#3", head: "cccccccccccc1", decided: false, muted: false),
            WaitingInput(key: "acme/web-app#4", head: "dddddddddddd1", decided: true, muted: false),
            WaitingInput(key: "acme/web-app#5", head: "eeeeeeeeeeee1", decided: false, muted: false),
            WaitingInput(key: "acme/web-app#6", head: "ffffffffffff1", decided: false, muted: true),
            WaitingInput(key: "acme/web-app#7", head: "111111111111", decided: false, muted: false),
        ]
        XCTAssertEqual(ReviewWaiting.keys(inputs, ledger: ledger), ["acme/web-app#1"])
    }

    func testNotificationText() {
        let r = rec(findings: ReviewFindings(blocking: 1, shouldFix: 0, nits: 0))
        XCTAssertTrue(ReviewWaiting.notificationText(id: 214, repo: "web-app", record: r).hasPrefix("#214 web-app · Request changes · 1 blocking"))
    }

    func testKeys() {
        XCTAssertEqual(ReviewKeys.action(key: "a", command: false, typing: false), .add)
        XCTAssertNil(ReviewKeys.action(key: "a", command: false, typing: true))
        XCTAssertEqual(ReviewKeys.action(key: "S", command: false, typing: false), .skip)
        XCTAssertEqual(ReviewKeys.action(key: "up", command: false, typing: false), .previousCard)
        XCTAssertEqual(ReviewKeys.action(key: "return", command: true, typing: true), .post)
        XCTAssertEqual(ReviewKeys.action(key: "r", command: true, typing: false), .reReview)
        XCTAssertEqual(ReviewKeys.action(key: "l", command: true, typing: true), .focusChat)
        XCTAssertNil(ReviewKeys.action(key: "x", command: true, typing: false))
        XCTAssertEqual(ReviewKeys.move(current: nil, ids: ["a", "b"], by: 1), "a")
        XCTAssertEqual(ReviewKeys.move(current: "a", ids: ["a", "b"], by: 1), "b")
        XCTAssertEqual(ReviewKeys.move(current: "b", ids: ["a", "b"], by: 1), "b")
        XCTAssertEqual(ReviewKeys.move(current: "a", ids: ["a", "b"], by: -1), "a")
        XCTAssertNil(ReviewKeys.move(current: nil, ids: [], by: 1))
    }

    func testBranchHelpers() {
        XCTAssertTrue(ReviewBranch.isValid("feature/x-1"))
        XCTAssertFalse(ReviewBranch.isValid("-rf"))
        XCTAssertFalse(ReviewBranch.isValid("a b"))
        XCTAssertFalse(ReviewBranch.isValid("a;b"))
        let id = ReviewBranch.pseudoID(repoKey: "acme/web-app", branch: "feature/x")
        XCTAssertLessThan(id, 0)
        XCTAssertEqual(id, ReviewBranch.pseudoID(repoKey: "acme/web-app", branch: "feature/x"))
        XCTAssertNotEqual(id, ReviewBranch.pseudoID(repoKey: "acme/web-app", branch: "feature/y"))
    }

    func testStages() {
        let key = "acme/web-app#7", h1 = "aaaaaaaaaaaa1", h2 = "bbbbbbbbbbbb2"
        func ledger(_ records: ReviewRecord...) -> ReviewLedger { var l = ReviewLedger(); records.forEach { l.set($0) }; return l }
        func record(_ head: String, _ phase: ReviewPhase, verdict: ReviewVerdict? = .approve, posted: String? = nil, base: String? = nil) -> ReviewRecord {
            var r = ReviewRecord(key: key, head: head, phase: phase, auto: true, queuedAt: 10)
            r.verdict = verdict; r.posted = posted; r.baseHead = base
            return r
        }
        func stage(_ head: String?, _ decision: MyDecision, _ l: ReviewLedger, draft: Bool = false) -> PRStage {
            PRStage.of(key: key, head: head, decision: decision, isDraft: draft, ledger: l)
        }
        XCTAssertEqual(stage(h1, .none, ReviewLedger()), .asked)
        XCTAssertTrue(stage(h1, .none, ReviewLedger()).needsMe)
        XCTAssertTrue(stage(h1, .none, ledger(record(h1, .done))).isReady)
        XCTAssertTrue(stage(h1, .none, ledger(record(h1, .reviewing, verdict: nil))).needsMe)
        XCTAssertFalse(stage(h1, .none, ledger(record(h1, .reviewing, verdict: nil))).isReady)
        // Posted from the review: no longer waits.
        XCTAssertEqual(stage(h1, .none, ledger(record(h1, .done, posted: "approved"))), .posted)
        var commented = record(h1, .done); commented.commentsPosted = 2
        XCTAssertFalse(stage(h1, .none, ledger(commented)).needsMe)
        XCTAssertFalse(stage(h1, .none, ReviewLedger(), draft: true).needsMe)
        // Decided, nothing new: does not count.
        XCTAssertEqual(stage(h1, .approved, ledger(record(h1, .done, posted: "approved"))), .approvedByMe)
        XCTAssertEqual(stage(h1, .changesRequested, ledger(record(h1, .done, verdict: .requestChanges, posted: "changes requested"))), .waitingAuthor)
        XCTAssertFalse(stage(h1, .approved, ReviewLedger()).needsMe)
        XCTAssertFalse(stage(h1, .changesRequested, ReviewLedger()).needsMe)
        // Decided, then a push: counts (new commits, a follow-up running, a follow-up done).
        let decided = record(h1, .done, verdict: .requestChanges, posted: "changes requested")
        XCTAssertEqual(stage(h2, .changesRequested, ledger(decided)), .newCommits(commits: nil))
        XCTAssertTrue(stage(h2, .approved, ledger(decided, record(h2, .reviewing, verdict: nil, base: h1))).needsMe)
        XCTAssertTrue(stage(h2, .changesRequested, ledger(decided, record(h2, .done, base: h1))).isReady)
        // A full re-review running after my decision does not make it wait on me.
        XCTAssertFalse(stage(h1, .approved, ledger(decided, record(h1, .reviewing, verdict: nil))).needsMe)
        // Order: ready, new commits, reviewing/asked, posted, waiting on the author, approved.
        let order = [PRStage.approvedByMe, .waitingAuthor, .asked, .newCommits(commits: nil), .posted,
                     .ready(verdict: .approve, findings: ReviewFindings(), followUp: false, commits: nil)].sorted { $0.order < $1.order }
        XCTAssertTrue(order.first?.isReady == true && order.last == .approvedByMe)
    }
}
