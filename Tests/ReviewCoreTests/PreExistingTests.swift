import XCTest
@testable import ReviewCore

final class PreExistingTests: XCTestCase {
    private func gate(_ json: String) -> GateFile { GateFile.parse(Data(json.utf8))! }

    // MARK: 1. the reason code and its hygiene

    func testPreExistingCodeIsListedAndNeedsLook() {
        XCTAssertTrue(GateCode.all.contains("pre-existing"))
        XCTAssertTrue(GateCode.needsLook.contains("pre-existing"))
        XCTAssertFalse(GateCode.notReady.contains("pre-existing"))
        XCTAssertEqual(GateCode.label("pre-existing"), "Problems that were there before this PR")
        XCTAssertEqual(GateRule.decide(codes: ["pre-existing"]), .needsLook)
        XCTAssertEqual(GateRule.decide(codes: ["pre-existing", "open-blocking"]), .notReady)
    }

    func testPackCheckFailedNeedsAFailedCheck() {
        let bare = gate(#"{"gate":"READY","reasons":[{"code":"pack-check-failed","refs":["x"]}],"packChecks":[{"id":"x","state":"pass","text":"t"}],"ci":{"state":"green"}}"#)
        XCTAssertEqual(bare.gate, .ready)
        XCTAssertTrue(bare.shownReasons.isEmpty)
        let backed = gate(#"{"gate":"READY","reasons":[{"code":"pack-check-failed","refs":["x"]}],"packChecks":[{"id":"x","state":"fail","text":"t"}],"ci":{"state":"green"}}"#)
        XCTAssertEqual(backed.gate, .notReady)
        // A failed check with no reason listed is added from the fact.
        let derived = gate(#"{"gate":"READY","reasons":[],"packChecks":[{"id":"x","state":"fail","text":"t"}],"ci":{"state":"green"}}"#)
        XCTAssertEqual(derived.gate, .notReady)
    }

    func testCannotVerifyRiskyNeedsARiskyItem() {
        let bare = gate(#"{"gate":"READY","reasons":[{"code":"cannot-verify-risky"}],"cannotVerify":[{"path":"a","what":"w","risky":false}],"ci":{"state":"green"}}"#)
        XCTAssertEqual(bare.gate, .ready)
        let backed = gate(#"{"gate":"READY","reasons":[{"code":"cannot-verify-risky"}],"cannotVerify":[{"path":"a","what":"w","risky":true}],"ci":{"state":"green"}}"#)
        XCTAssertEqual(backed.gate, .needsLook)
    }

    func testPreExistingNeedsACardOrFindingAndNeverBlocks() {
        let bare = gate(#"{"gate":"READY","reasons":[{"code":"pre-existing"}],"ci":{"state":"green"}}"#)
        XCTAssertEqual(bare.gate, .ready, "a pre-existing reason with nothing behind it is not a reason")
        XCTAssertTrue(bare.shownReasons.isEmpty)
        let named = gate(#"{"gate":"NEEDS_LOOK","reasons":[{"code":"pre-existing","refs":["F2"]}],"ci":{"state":"green"}}"#)
        XCTAssertEqual(named.gate, .needsLook)
        var fromCards = gate(#"{"gate":"READY","reasons":[],"ci":{"state":"green"}}"#)
        fromCards.hasPreExisting = true
        XCTAssertEqual(fromCards.gate, .needsLook)
        XCTAssertEqual(fromCards.shownReasons.map(\.code), ["pre-existing"])
    }

    func testSettleReadsThePreExistingFactFromCardsAndFindings() throws {
        let data = Data(#"{"gate":"READY","reasons":[],"ci":{"state":"green"}}"#.utf8)
        let cards = Data(#"[{"id":"c1","finding":"F1","severity":"pre-existing","path":"a.ts","line":3,"body":"This was already here."}]"#.utf8)
        XCTAssertEqual(GateFile.settle(gateJSON: data, findings: ReviewFindings(), commentsJSON: cards)?.gate, .needsLook)
        XCTAssertEqual(GateFile.settle(gateJSON: data, findings: ReviewFindings(preExisting: 1), commentsJSON: nil)?.gate, .needsLook)
        XCTAssertEqual(GateFile.settle(gateJSON: data, findings: ReviewFindings(), commentsJSON: nil)?.gate, .ready)
    }

    // MARK: 2. card severity

    func testCardSeverityPreExisting() {
        XCTAssertEqual(CommentSeverity.parse("pre-existing"), .preExisting)
        XCTAssertEqual(CommentSeverity.parse("PRE_EXISTING"), .preExisting)
        XCTAssertEqual(CommentSeverity.preExisting.rawValue, "pre-existing")
        XCTAssertEqual(CommentSeverity.preExisting.label, "Was already there")
        XCTAssertTrue(CommentSeverity.preExisting.addByDefault)
        XCTAssertTrue(CommentSeverity.blocking.addByDefault && CommentSeverity.shouldFix.addByDefault)
        XCTAssertFalse(CommentSeverity.nit.addByDefault)
        let cards = CommentParse.file(Data(#"[{"id":"c1","severity":"pre-existing","path":"a.ts","line":3,"body":"Predates this PR."}]"#.utf8))
        XCTAssertEqual(cards.first?.severity, .preExisting)
        XCTAssertEqual(cards.first?.include, true)
    }

    func testPreExistingCardsAreNeverBlockingOrShouldFixTotals() {
        var log = ChatLog()
        log.cards = [SuggestedComment(id: "c1", severity: .preExisting, path: "a.ts", line: 1, title: nil, body: "b"),
                     SuggestedComment(id: "c2", severity: .shouldFix, path: "a.ts", line: 2, title: nil, body: "b")]
        let open = log.openFindings
        XCTAssertEqual(open.preExisting, 1)
        XCTAssertEqual(open.shouldFix, 1)
        XCTAssertEqual(open.blocking, 0)
        XCTAssertEqual(ReviewFindings(preExisting: 2).text, "2 pre-existing")
        XCTAssertEqual(FollowUp.standingVerdict(.approve, findings: ReviewFindings(preExisting: 3)), .approve, "pre-existing alone never turns APPROVE into REQUEST CHANGES")
    }

    // MARK: 3. the report word

    func testReportWordIsItsOwnBucket() {
        let report = """
        BLOCKING a.ts:1 — x
        PRE-EXISTING b.ts:2 — was already in the base
        NIT c.ts:3 — y
        GATE: NEEDS_LOOK
        VERDICT: REQUEST CHANGES
        """
        let parsed = ReviewParse.parse(report)
        XCTAssertEqual(parsed?.findings, ReviewFindings(blocking: 1, nits: 1, preExisting: 1))
        let headed = ReviewParse.parse("**PRE-EXISTING**\n- b.ts:2 one\n- d.ts:4 two\n\nVERDICT: APPROVE\n")
        XCTAssertEqual(headed?.findings, ReviewFindings(preExisting: 2))
        XCTAssertEqual(ReviewParse.parse("PRE-EXISTING: none\nVERDICT: APPROVE\n")?.findings, ReviewFindings())
    }

    func testOldSavedFindingsAndGatesStillDecode() throws {
        let findings = try JSONDecoder().decode(ReviewFindings.self, from: Data(#"{"blocking":1,"shouldFix":0,"nits":2,"cannotVerify":0}"#.utf8))
        XCTAssertEqual(findings, ReviewFindings(blocking: 1, nits: 2))
        let file = gate(#"{"gate":"READY","reasons":[]}"#)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(file)) as? [String: Any])
        object.removeValue(forKey: "followUps"); object.removeValue(forKey: "hasPreExisting")
        let old = try JSONDecoder().decode(GateFile.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(old, file)
    }

    // MARK: 4. follow-ups

    func testFollowUpsAreInformationOnly() {
        let file = gate(#"{"gate":"READY","reasons":[],"ci":{"state":"green"},"followUps":[{"path":"src/b.ts","line":127,"title":"unescaped regex"},{"path":"src/c.ts","title":"no line"},{"path":"x"}]}"#)
        XCTAssertEqual(file.followUps.count, 2, "an entry with no title is dropped")
        XCTAssertEqual(file.followUps[0].location, "src/b.ts:127")
        XCTAssertEqual(file.followUps[1].location, "src/c.ts")
        XCTAssertEqual(file.followUpsTitle, "Follow-ups (2)")
        XCTAssertEqual(file.gate, .ready, "follow-ups never change the gate")
        XCTAssertTrue(file.shownReasons.isEmpty)
        XCTAssertNil(gate(#"{"gate":"READY","reasons":[]}"#).followUpsTitle)
        XCTAssertNil(gate(#"{"gate":"READY","reasons":[],"followUps":[]}"#).followUpsTitle)
    }

    // MARK: 5. follow-up runs

    private func pre(_ id: String) -> SuggestedComment { SuggestedComment(id: id, severity: .preExisting, path: "a.ts", line: 1, title: nil, body: "b") }

    func testOpenPreExistingCardGivesTheReasonNotShouldFix() {
        let reported = GateFile.parse(Data(#"{"gate":"NOT_READY","reasons":[{"code":"open-should-fix","text":"1 should-fix finding open","refs":["c1"]}],"ci":{"state":"green"}}"#.utf8))
        let out = FollowUp.finalGate(reported: reported, previous: nil, open: ReviewFindings(preExisting: 1), missingCards: false, preExistingIDs: ["c1"])
        XCTAssertEqual(out?.gate, .needsLook)
        XCTAssertEqual(out?.shownReasons.map(\.code), ["pre-existing"])
        XCTAssertEqual(out?.shownReasons.first?.refs, ["c1"])
        // With no remap from the pass, the app still adds the reason from the open card.
        let ready = GateFile.parse(Data(#"{"gate":"READY","ci":{"state":"green"}}"#.utf8))
        let added = FollowUp.finalGate(reported: ready, previous: nil, open: ReviewFindings(preExisting: 2), missingCards: false)
        XCTAssertEqual(added?.gate, .needsLook)
        XCTAssertEqual(added?.shownReasons.map(\.code), ["pre-existing"])
        // A real should-fix next to it still makes it NOT_READY.
        let both = FollowUp.finalGate(reported: ready, previous: nil, open: ReviewFindings(shouldFix: 1, preExisting: 1), missingCards: false)
        XCTAssertEqual(both?.gate, .notReady)
        // Fixed: the reason goes away.
        let fixed = FollowUp.finalGate(reported: GateFile.parse(Data(#"{"gate":"NEEDS_LOOK","reasons":[{"code":"pre-existing","refs":["c1"]}],"ci":{"state":"green"}}"#.utf8)),
                                       previous: nil, open: ReviewFindings(), missingCards: false)
        XCTAssertEqual(fixed?.gate, .ready)
    }

    func testMissingCardsIgnoresPreExistingFindings() {
        var previous = ReviewRecord(key: "w/r#1", head: "aaaaaaaaaaaa", phase: .done, auto: false, queuedAt: 1)
        previous.findings = ReviewFindings(blocking: 1, preExisting: 3)
        var log = ChatLog()
        log.cards = [SuggestedComment(id: "c1", severity: .blocking, path: "a.ts", line: 1, title: nil, body: "b")]
        XCTAssertFalse(FollowUp.missingCards(previous: previous, log: log), "three pre-existing findings with no card do not count")
        log.cards = [pre("c9")]
        XCTAssertTrue(FollowUp.missingCards(previous: previous, log: log), "a pre-existing card does not stand in for a blocking one")
    }

    func testFollowUpPromptSaysSo() {
        let prompt = FollowUp.prompt(scratch: "/s", previousHead: "aaaaaaaaaaaa", newHead: "bbbbbbbbbbbb")
        XCTAssertTrue(prompt.contains("severity \"pre-existing\"") && prompt.contains("never counts as open blocking or should-fix"))
        XCTAssertTrue(prompt.contains("NEEDS_LOOK at most"))
        XCTAssertTrue(prompt.contains("pre-existing findings do not count here"))
        let draft = ReviewChat.draftPrompt(scratch: "/s")
        XCTAssertTrue(draft.contains("PRE-EXISTING") && draft.contains("\"pre-existing\""))
    }

    // MARK: the run the limit stopped

    func testStoppedRunIsRecordedInOutJSON() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("stopped-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("# r".utf8).write(to: dir.appendingPathComponent("review.md"))
        try Data("{}".utf8).write(to: dir.appendingPathComponent("gate.json"))
        try Data().write(to: dir.appendingPathComponent("comments.json"))
        XCTAssertEqual(StoppedRun.present(in: dir), ["review.md", "gate.json"], "an empty file is not there")
        let stopped = StoppedRun(files: StoppedRun.present(in: dir), elapsed: 5401.4, limit: 5400)
        XCTAssertEqual(stopped.text, "stopped after 90 minutes (review.md, gate.json were written first)")
        let out = dir.appendingPathComponent("out.json")
        try Data().write(to: out)
        stopped.record(in: out)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: out)) as? [String: Any])
        XCTAssertEqual(object["subtype"] as? String, "stopped_by_limit")
        XCTAssertEqual(object["filesPresent"] as? [String], ["review.md", "gate.json"])
        XCTAssertEqual(object["elapsed_seconds"] as? Int, 5401)
        XCTAssertEqual(object["limit_seconds"] as? Int, 5400)
        // A result claude did print is never replaced.
        try Data(#"{"type":"result"}"#.utf8).write(to: out)
        stopped.record(in: out)
        XCTAssertEqual(try String(contentsOf: out, encoding: .utf8), #"{"type":"result"}"#)
    }
}
