import XCTest
@testable import ReviewCore

final class MergeGateTests: XCTestCase {
    private func gate(_ json: String) -> GateFile? { GateFile.parse(Data(json.utf8)) }

    private let full = """
    {"gate":"NOT_READY","pack":"backend","reasons":[{"code":"open-blocking","text":"2 blocking findings open","refs":["F1","F4"]}],
     "ci":{"state":"green","head":"abcdef123456","covers":"unit tests only"},"coverage":{"files":40,"read":38,"unread":["a.ts","b.ts"]},
     "othersOpen":[{"id":123,"author":"sam","severity":"critical"}],"cannotVerify":[{"path":"m.ts","what":"rollback","risky":true}],
     "packChecks":[{"id":"x","state":"pass","text":"fine"}],"nitsNotShown":4,"risk":["auth"],"deepCheck":true}
    """

    func testParsesEveryField() throws {
        let g = try XCTUnwrap(gate(full))
        XCTAssertEqual(g.stated, .notReady)
        XCTAssertEqual(g.reasons.first?.refs, ["F1", "F4"])
        XCTAssertEqual(g.ci?.covers, "unit tests only")
        XCTAssertEqual(g.coverage?.unread, ["a.ts", "b.ts"])
        XCTAssertEqual(g.othersOpen.first?.isHard, true)
        XCTAssertEqual(g.nitsNotShown, 4)
        XCTAssertTrue(g.deepCheck)
        XCTAssertEqual(g.filesLine, "Read 38 of 40 files, 2 not read")
        XCTAssertEqual(g.nitsLine, "4 more nits found, not shown")
        XCTAssertEqual(g.pipelineLine, "Pipeline green for abcdef1: unit tests only")
    }

    func testNoGateKeyIsNoGate() {
        XCTAssertNil(gate("{}"))
        XCTAssertNil(GateFile.parse(Data("nope".utf8)))
    }

    func testEveryReasonCodeFollowsTheRule() {
        for code in GateCode.notReady { XCTAssertEqual(GateRule.decide(codes: [code]), .notReady, code) }
        for code in GateCode.needsLook { XCTAssertEqual(GateRule.decide(codes: [code]), .needsLook, code) }
        XCTAssertEqual(GateRule.decide(codes: ["cannot-verify"]), .ready, "plain cannot-verify is listed, not blocking")
        XCTAssertEqual(GateRule.decide(codes: []), .ready)
        XCTAssertEqual(GateRule.decide(codes: ["unread-files", "open-blocking"]), .notReady, "not ready beats needs look")
        XCTAssertEqual(GateRule.decide(codes: [], softOthers: true), .needsLook)
        XCTAssertEqual(Set(GateCode.all), GateCode.notReady.union(GateCode.needsLook).union(["cannot-verify"]))
    }

    func testAMildFileIsNeverTrustedOverItsFacts() throws {
        // Says READY, but a pipeline is red, files are unread, and a major comment is open.
        let ready = try XCTUnwrap(gate(#"{"gate":"READY","ci":{"state":"red"},"coverage":{"files":3,"read":2,"unread":["z"]}}"#))
        XCTAssertEqual(ready.gate, .notReady)
        XCTAssertTrue(ready.shownReasons.map(\.code).contains("ci-red") && ready.shownReasons.map(\.code).contains("unread-files"))
        let look = try XCTUnwrap(gate(#"{"gate":"READY","ci":{"state":"running"}}"#))
        XCTAssertEqual(look.gate, .needsLook)
        let others = try XCTUnwrap(gate(#"{"gate":"READY","ci":{"state":"green"},"othersOpen":[{"id":1,"author":"a","severity":"minor"}]}"#))
        XCTAssertEqual(others.gate, .needsLook)
        let major = try XCTUnwrap(gate(#"{"gate":"READY","othersOpen":[{"id":1,"author":"a","severity":"major"}],"ci":{"state":"green"}}"#))
        XCTAssertEqual(major.gate, .notReady)
        let generic = try XCTUnwrap(gate(#"{"gate":"READY","pack":"generic","ci":{"state":"green"}}"#))
        XCTAssertEqual(generic.gate, .needsLook)
        let pack = try XCTUnwrap(gate(#"{"gate":"READY","ci":{"state":"green"},"packChecks":[{"id":"p","state":"fail","text":"t"}]}"#))
        XCTAssertEqual(pack.gate, .notReady)
        let risky = try XCTUnwrap(gate(#"{"gate":"READY","ci":{"state":"green"},"cannotVerify":[{"path":"a","what":"w","risky":true}]}"#))
        XCTAssertEqual(risky.gate, .needsLook)
        let safe = try XCTUnwrap(gate(#"{"gate":"READY","ci":{"state":"green"},"cannotVerify":[{"path":"a","what":"w","risky":false}]}"#))
        XCTAssertEqual(safe.gate, .ready)
        // An unknown outcome word is never a pass.
        XCTAssertEqual(gate(#"{"gate":"MAYBE"}"#)?.gate, .needsLook)
    }

    private func record(_ json: String?, verdict: ReviewVerdict = .approve) -> ReviewRecord {
        var r = ReviewRecord(key: "w/r/1", head: "abcdef123456", phase: .done, auto: false, queuedAt: 0)
        r.verdict = verdict
        r.findings = ReviewFindings()
        r.mergeGate = json.flatMap(gate)
        return r
    }

    func testApproveOnlyOnReady() {
        func check(_ r: ReviewRecord) -> ReviewGate {
            ReviewGate.check(.approve, record: r, currentHead: "abcdef123456", pipeline: .green)
        }
        XCTAssertTrue(check(record(#"{"gate":"READY","ci":{"state":"green"}}"#)).isAllowed)
        XCTAssertTrue(check(record(nil)).isAllowed, "no gate.json: today's behaviour")
        for g in ["NOT_READY", "NEEDS_LOOK"] {
            let result = check(record("{\"gate\":\"\(g)\",\"reasons\":[{\"code\":\"ci-none\"}]}"))
            XCTAssertFalse(result.isAllowed, g)
        }
        if case .blocked(let why) = check(record(#"{"gate":"NEEDS_LOOK","reasons":[{"code":"ci-none"}]}"#)) {
            XCTAssertEqual(why, "needs your look: no pipeline result for this commit")
        }
        // Request changes is unaffected by the gate.
        let changes = ReviewGate.check(.requestChanges, record: record(#"{"gate":"NOT_READY"}"#, verdict: .requestChanges), currentHead: "abcdef123456", pipeline: .green)
        XCTAssertTrue(changes.isAllowed)
    }

    func testOverrideListsTheGateReasons() {
        let r = record(#"{"gate":"NEEDS_LOOK","reasons":[{"code":"unread-files","text":"2 files not read"},{"code":"generic-pack"}]}"#)
        let open = ReviewGate.checkOverride(cards: [], replies: RepliesFile(), record: r, currentHead: "abcdef123456", pipeline: .green)
        // Threads not read yet, so it is unavailable; with a read file it lists the gate.
        var file = RepliesFile()
        file.myRoots = []
        file.resolvedOnBitbucket = []
        let ok = ReviewGate.checkOverride(cards: [], replies: file, record: r, currentHead: "abcdef123456", pipeline: .green)
        _ = open
        let lines = ok.info?.lines ?? []
        XCTAssertTrue(lines.contains("Merge gate: Needs your look."), "\(lines)")
        XCTAssertTrue(lines.contains("Gate: 2 files not read") && lines.contains("Gate: No checklist for this repo"), "\(lines)")
    }
}
