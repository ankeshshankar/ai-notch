import XCTest
@testable import ReviewCore

final class FollowGateTests: XCTestCase {
    private func card(_ id: String, _ sev: CommentSeverity = .shouldFix) -> SuggestedComment {
        SuggestedComment(id: id, severity: sev, path: "src/a.ts", line: 4, title: nil, body: "Guard this value \(id).")
    }

    private func previous(blocking: Int = 0, shouldFix: Int = 0, gate: String? = nil) -> ReviewRecord {
        var r = ReviewRecord(key: "w/r#1", head: "aaaaaaaaaaaa", phase: .done, auto: false, queuedAt: 1)
        r.verdict = .requestChanges
        r.findings = ReviewFindings(blocking: blocking, shouldFix: shouldFix, nits: 0)
        r.mergeGate = gate.flatMap { GateFile.parse(Data($0.utf8)) }
        return r
    }

    private func result(_ json: String) -> FollowUpResult { FollowUp.parse(Data(json.utf8))! }

    func testASkippedCardIsNotCountedUnclear() {
        var log = ChatLog()
        var skipped = card("c2"); skipped.include = false
        log.cards = [card("c1"), skipped]
        let note = log.applyFollowUp(result(#"{"verdict":"REQUEST CHANGES","comments":[{"id":"c1","status":"still_open"}]}"#), from: "a", to: "b", commits: 1, at: 1)
        XCTAssertEqual(note.unclear, 0, "a card on Skip the pass was not asked about is not unclear")
        XCTAssertNil(log.cards[1].status)
        XCTAssertEqual(note.stillOpen, 1)
        // A card that was asked about and not mentioned still is.
        var log2 = ChatLog(); log2.cards = [card("c1")]
        XCTAssertEqual(log2.applyFollowUp(result(#"{"verdict":"APPROVE"}"#), from: "a", to: "b", commits: 1, at: 1).unclear, 1)
    }

    func testAFixNeedsASecondReadInTheNewFormat() {
        var log = ChatLog(); log.cards = [card("c1"), card("c2")]
        let json = #"{"verdict":"APPROVE","gate":"READY","comments":[{"id":"c1","status":"fixed","confirmed":true},{"id":"c2","status":"fixed"}]}"#
        let note = log.applyFollowUp(result(json), from: "a", to: "b", commits: 1, at: 1)
        XCTAssertEqual(log.cards[0].status, .fixed)
        XCTAssertEqual(log.cards[1].status, .unclear, "fixed without the second read is not taken")
        XCTAssertEqual(note.fixed, 1)
        // An older answer (no gate) is taken as it was.
        var old = ChatLog(); old.cards = [card("c2")]
        _ = old.applyFollowUp(result(#"{"verdict":"APPROVE","comments":[{"id":"c2","status":"fixed"}]}"#), from: "a", to: "b", commits: 1, at: 1)
        XCTAssertEqual(old.cards[0].status, .fixed)
    }

    func testMissingCardsNeverApprove() {
        var log = ChatLog(); log.cards = [card("c1", .blocking)]
        XCTAssertFalse(FollowUp.missingCards(previous: previous(blocking: 1), log: log))
        XCTAssertTrue(FollowUp.missingCards(previous: previous(blocking: 1, shouldFix: 2), log: log))
        XCTAssertFalse(FollowUp.missingCards(previous: nil, log: log))
        let gate = FollowUp.finalGate(reported: GateFile.parse(Data(#"{"gate":"READY","ci":{"state":"green"}}"#.utf8)), previous: nil, open: ReviewFindings(), missingCards: true)
        XCTAssertEqual(gate?.gate, .needsLook)
        XCTAssertTrue(gate?.reasons.contains { $0.code == "cannot-verify" } == true)
        XCTAssertEqual(FollowUp.standingVerdict(.approve, findings: ReviewFindings(), gate: gate), .requestChanges)
    }

    func testFinalGateAddsOpenFindingsAndKeepsNoGateAsNoGate() {
        XCTAssertNil(FollowUp.finalGate(reported: nil, previous: nil, open: ReviewFindings(), missingCards: false), "nothing gated: today's rules")
        let ready = GateFile.parse(Data(#"{"gate":"READY","ci":{"state":"green"}}"#.utf8))
        let open = FollowUp.finalGate(reported: ready, previous: nil, open: ReviewFindings(blocking: 1, shouldFix: 2, nits: 0), missingCards: false)
        XCTAssertEqual(open?.gate, .notReady)
        XCTAssertEqual(open?.reasons.map(\.code), ["open-blocking", "open-should-fix"])
        XCTAssertEqual(FollowUp.finalGate(reported: ready, previous: nil, open: ReviewFindings(), missingCards: false)?.gate, .ready)
        // A gated review followed by an answer with no gate is not a pass.
        let prev = GateFile.parse(Data(#"{"gate":"READY"}"#.utf8))
        XCTAssertEqual(FollowUp.finalGate(reported: nil, previous: prev, open: ReviewFindings(), missingCards: false)?.gate, .needsLook)
        // The pass's gate, reasons and others come through followup.json.
        let r = result(#"{"verdict":"REQUEST CHANGES","gate":"NOT_READY","reasons":[{"code":"others-open","text":"A major comment is open"}],"othersOpen":[{"id":5,"author":"sam","severity":"major"},{"id":6,"author":"bot","severity":"minor","asks":false}]}"#)
        XCTAssertEqual(r.gate?.gate, .notReady)
        XCTAssertEqual(r.gate?.othersOpen.map(\.id), [5], "a comment that asks for nothing is not an open thread")
    }

    func testRestateVerdictKeepsTheReportedOne() {
        var log = ChatLog(); log.cards = [card("c1")]
        let note = log.applyFollowUp(result(#"{"verdict":"APPROVE","comments":[{"id":"c1","status":"fixed"}]}"#), from: "a", to: "b", commits: 1, at: 1)
        XCTAssertEqual(note.verdict, .approve)
        log.restateVerdict(.requestChanges, note: note.id)
        XCTAssertEqual(log.followUps.last?.verdict, .requestChanges)
        XCTAssertEqual(log.followUps.last?.reported, .approve)
    }

    func testInputCarriesOthersAndThePreviousGate() throws {
        let gate = GateFile.parse(Data(#"{"gate":"NEEDS_LOOK","reasons":[{"code":"ci-none"}],"ci":{"state":"none"}}"#.utf8))
        let data = FollowUp.inputJSON(previousHead: "aaa", newHead: "bbb", previous: previous(), log: ChatLog(), existing: [],
                                      othersOpen: [ExistingComment(id: 77, author: "sam", path: "a.ts", line: 2, text: "Why?")], previousGate: gate, mergesSkipped: 2)
        let o = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((o["othersOpen"] as? [[String: Any]])?.first?["id"] as? Int, 77)
        XCTAssertEqual((o["previousGate"] as? [String: Any])?["gate"] as? String, "NEEDS_LOOK")
        XCTAssertEqual(o["mergeCommitsSkipped"] as? Int, 2)
        let comments = [RawComment(id: 1, author: "me", authorUUID: "u1", text: "mine"), RawComment(id: 2, author: "sam", authorUUID: "u2", text: "open"),
                        RawComment(id: 3, author: "sam", authorUUID: "u2", text: "done", resolved: true), RawComment(id: 4, parentID: 2, author: "sam", authorUUID: "u2", text: "reply"),
                        RawComment(id: 5, author: "app", authorUUID: "u1", text: "posted")]
        XCTAssertEqual(OtherThreads.open(comments, mine: [5], me: "u1").map(\.id), [2])
    }

    func testPromptNamesEveryPartAndTheGate() {
        let p = FollowUp.prompt(scratch: "/s", previousHead: "aaaaaaaaaaaaa", newHead: "bbbbbbbbbbbbb", diffParts: DiffSplit.names(count: 3), mergesSkipped: 1)
        XCTAssertTrue(p.contains("followup-1.diff, followup-2.diff, followup-3.diff") && p.contains("none is cut"))
        XCTAssertTrue(p.contains("merge commit that brought the target branch in is left out"))
        XCTAssertTrue(p.contains("second time") && p.contains("\"gate\"") && p.contains("cannot-verify"))
        XCTAssertTrue(FollowUp.prompt(scratch: "/s", previousHead: "a", newHead: "b").contains("followup.diff"))
    }

    func testADiffOverTheLimitIsSplitNeverCut() {
        var diff = ""
        for i in 0..<30 { diff += "diff --git a/f\(i).txt b/f\(i).txt\n" + String(repeating: "+line of text\n", count: 100) }
        let data = Data(diff.utf8)
        let parts = DiffSplit.parts(data, limit: 10_000)
        XCTAssertGreaterThan(parts.count, 1)
        XCTAssertTrue(parts.allSatisfy { $0.count <= 10_000 })
        XCTAssertEqual(parts.reduce(Data(), +), data, "every byte is in some part")
        XCTAssertTrue(parts.allSatisfy { String(decoding: $0, as: UTF8.self).hasPrefix("diff --git ") }, "split at file boundaries")
        // One huge file is split by lines.
        let huge = Data(("diff --git a/x b/x\n" + String(repeating: "+a long added line\n", count: 2000)).utf8)
        let hp = DiffSplit.parts(huge, limit: 5_000)
        XCTAssertTrue(hp.count > 1 && hp.allSatisfy { $0.count <= 5_000 } && hp.reduce(Data(), +) == huge)
        XCTAssertEqual(DiffSplit.parts(Data("small".utf8)).count, 1)
        XCTAssertEqual(DiffSplit.names(count: 1), ["followup.diff"])
        XCTAssertEqual(DiffSplit.names(count: 2), ["followup-1.diff", "followup-2.diff"])
    }

    func testAgentEffortIsPassedThrough() throws {
        let file = "---\nname: lens\ndescription: d\nmodel: claude-opus-5-5\neffort: high\ntools: Read\n---\nbody"
        let bad = "---\nname: other\ndescription: d\neffort: loud\n---\nbody"
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(ReviewAgents.json(files: [file, bad]).utf8)) as? [String: [String: Any]])
        XCTAssertEqual(json["lens"]?["effort"] as? String, "high")
        XCTAssertNil(json["other"]?["effort"], "an unknown value is dropped, not sent")
        XCTAssertTrue(ReviewCommand.arguments(prNumber: 1, scratch: "/s", skill: "S", agentsJSON: "{}", hookCommand: nil, skillName: "pr-review", branch: nil).joined(separator: " ").contains("GATE and VERDICT lines"))
    }
}
