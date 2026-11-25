import XCTest
@testable import ReviewCore

final class ReviewParseTests: XCTestCase {
    let approve = """
    PR #3403 Add thing — Rudra — feat/x → master — CI green
    VERDICT: APPROVE
    BLOCKING  none
    SHOULD-FIX  src/a.ts:10 — rule — a thing
    NIT  src/b.ts:2 — naming
    NIT  src/c.ts:9 — naming
    CANNOT-VERIFY  device walk — no device
    Lenses: 3 run, 5 findings raised, 4 kept
    """

    func testApproveWithFindings() {
        let parsed = ReviewParse.parse(approve)
        XCTAssertEqual(parsed?.verdict, .approve)
        XCTAssertEqual(parsed?.findings, ReviewFindings(blocking: 0, shouldFix: 1, nits: 2, cannotVerify: 1))
        XCTAssertEqual(parsed?.findings.text, "1 should-fix · 2 nits · 1 unverified")
    }

    func testRequestChangesAndMarkdown() {
        let text = "Report\n\n**VERDICT: REQUEST CHANGES**\n\n- **BLOCKING** `a.ts:3` — breaks auth\n- BLOCKING b.ts:4 — x\n1. SHOULD-FIX c.ts:5 — y\n"
        let parsed = ReviewParse.parse(text)
        XCTAssertEqual(parsed?.verdict, .requestChanges)
        XCTAssertEqual(parsed?.findings.blocking, 2)
        XCTAssertEqual(parsed?.findings.shouldFix, 1)
    }

    func testTemplateLineIsNotAVerdictAndLastWins() {
        XCTAssertNil(ReviewParse.parse("VERDICT: APPROVE | REQUEST CHANGES"))
        XCTAssertNil(ReviewParse.parse("no verdict here"))
        XCTAssertEqual(ReviewParse.parse("VERDICT: APPROVE\nlater\nVERDICT: REQUEST CHANGES\nBLOCKING a:1 — x")?.verdict, .requestChanges)
    }

    func testNoneAndProseAreNotFindings() {
        let parsed = ReviewParse.parse("VERDICT: APPROVE\nBLOCKING: none\nSHOULD-FIX 0\nNITPICKING is fine\nNIT:")
        XCTAssertEqual(parsed?.findings, ReviewFindings())
        XCTAssertEqual(parsed?.findings.text, "no findings")
    }

    func testFindingsBeforeVerdictWhenNoneFollow() {
        let parsed = ReviewParse.parse("BLOCKING a.ts:1 — x\nVERDICT: REQUEST CHANGES")
        XCTAssertEqual(parsed?.findings.blocking, 1)
    }

    func testOutputJSON() {
        let json = #"{"type":"result","is_error":false,"result":"hi","total_cost_usd":1.25,"duration_ms":90000,"permission_denials":[{"tool_name":"Bash"},{"tool_name":"Bash"},{"tool_name":"Edit"}]}"#
        let out = ReviewOutput.parse(Data(json.utf8))
        XCTAssertEqual(out?.text, "hi")
        XCTAssertEqual(out?.costUSD, 1.25)
        XCTAssertEqual(out?.durationSeconds, 90)
        XCTAssertEqual(out?.denied, ["Bash", "Edit"])
        XCTAssertNil(ReviewOutput.parse(Data("not json".utf8)))
    }
}

final class ReviewLedgerTests: XCTestCase {
    let now = 1_000_000.0

    func testDedupeByPullRequestAndCommit() {
        var ledger = ReviewLedger()
        func should(_ head: String?, auto: Bool = true, draft: Bool = false, mine: Bool = false, age: Double = 100) -> Bool {
            ReviewPolicy.shouldAutoQueue(key: "ws/r#1", head: head, isDraft: draft, iReview: true, myReviewDone: mine,
                                         updatedAt: now - age, now: now, ledger: ledger, autoOn: auto)
        }
        XCTAssertTrue(should("aaaaaaaaaaaa"))
        ledger.set(ReviewRecord(key: "ws/r#1", head: "aaaaaaaaaaaa", phase: .done, auto: true, queuedAt: now))
        XCTAssertFalse(should("aaaaaaaaaaaa"), "same commit is not reviewed twice")
        XCTAssertFalse(should("aaaaaaaaaaaa1234567890"), "a 40-char hash of the same commit is the same record")
        XCTAssertTrue(should("bbbbbbbbbbbb"), "new commits are reviewed again")
        XCTAssertFalse(should("bbbbbbbbbbbb", auto: false))
        XCTAssertFalse(should("bbbbbbbbbbbb", draft: true))
        XCTAssertFalse(should("bbbbbbbbbbbb", mine: true))
        XCTAssertFalse(should(nil))
        XCTAssertFalse(should("bbbbbbbbbbbb", age: 8 * 86_400), "stale pull requests are left alone")
        ledger.set(ReviewRecord(key: "ws/r#1", head: "bbbbbbbbbbbb", phase: .failed, auto: true, queuedAt: now))
        XCTAssertFalse(should("bbbbbbbbbbbb"), "a failed run is not retried by itself")
    }

    func testRestartAndPrune() {
        var ledger = ReviewLedger()
        ledger.set(ReviewRecord(key: "a#1", head: "h1", phase: .reviewing, auto: true, queuedAt: now))
        ledger.set(ReviewRecord(key: "a#2", head: "h2", phase: .queued, auto: true, queuedAt: now))
        ledger.set(ReviewRecord(key: "a#3", head: "h3", phase: .done, auto: true, queuedAt: now - 40 * 86_400))
        ledger.settleAfterRestart(now: now)
        XCTAssertEqual(ledger.record("a#1", head: "h1")?.phase, .failed)
        XCTAssertNil(ledger.record("a#2", head: "h2"))
        ledger.prune(openKeys: [], now: now)
        XCTAssertNil(ledger.record("a#3", head: "h3"))
        XCTAssertNotNil(ledger.record("a#1", head: "h1"))
        // It round-trips through JSON.
        let data = try! JSONEncoder().encode(ledger)
        XCTAssertEqual(try! JSONDecoder().decode(ReviewLedger.self, from: data), ledger)
    }
}

final class ReviewGateTests: XCTestCase {
    func record(_ verdict: ReviewVerdict = .approve, blocking: Int = 0, phase: ReviewPhase = .done, head: String = "abcdef123456") -> ReviewRecord {
        var r = ReviewRecord(key: "ws/r#1", head: head, phase: phase, auto: true, queuedAt: 0)
        r.verdict = verdict
        r.findings = ReviewFindings(blocking: blocking)
        return r
    }

    func testApproveOnlyWhenEverythingHolds() {
        let head = "abcdef123456"
        XCTAssertEqual(ReviewGate.check(.approve, record: record(), currentHead: head, pipeline: .green), .allowed)
        XCTAssertEqual(ReviewGate.check(.approve, record: record(), currentHead: head + "7890", pipeline: .green), .allowed, "short vs long hash")
        XCTAssertFalse(ReviewGate.check(.approve, record: nil, currentHead: head, pipeline: .green).isAllowed)
        XCTAssertFalse(ReviewGate.check(.approve, record: record(phase: .failed), currentHead: head, pipeline: .green).isAllowed)
        XCTAssertFalse(ReviewGate.check(.approve, record: record(phase: .reviewing), currentHead: head, pipeline: .green).isAllowed)
        XCTAssertFalse(ReviewGate.check(.approve, record: record(.requestChanges), currentHead: head, pipeline: .green).isAllowed)
        XCTAssertFalse(ReviewGate.check(.approve, record: record(blocking: 1), currentHead: head, pipeline: .green).isAllowed)
        XCTAssertFalse(ReviewGate.check(.approve, record: record(), currentHead: "ffffffffffff", pipeline: .green).isAllowed, "new commits")
        XCTAssertFalse(ReviewGate.check(.approve, record: record(), currentHead: nil, pipeline: .green).isAllowed)
        XCTAssertFalse(ReviewGate.check(.approve, record: record(), currentHead: "abc", pipeline: .green).isAllowed, "too short to compare")
        XCTAssertFalse(ReviewGate.check(.approve, record: record(), currentHead: head, pipeline: .notGreen).isAllowed)
        XCTAssertFalse(ReviewGate.check(.approve, record: record(), currentHead: head, pipeline: .unknown).isAllowed)
        XCTAssertFalse(ReviewGate.check(.approve, record: record(), currentHead: head, pipeline: .green, isOpen: false).isAllowed)
        XCTAssertFalse(ReviewGate.check(.approve, record: record(), currentHead: head, pipeline: .green, alreadyApproved: true).isAllowed)
    }

    func testRequestChangesGate() {
        let head = "abcdef123456"
        XCTAssertTrue(ReviewGate.check(.requestChanges, record: record(.requestChanges), currentHead: head, pipeline: .notGreen).isAllowed)
        XCTAssertFalse(ReviewGate.check(.requestChanges, record: record(.approve), currentHead: head, pipeline: .green).isAllowed)
        XCTAssertFalse(ReviewGate.check(.requestChanges, record: record(.requestChanges), currentHead: "ffffffffffff", pipeline: .green).isAllowed)
    }
}

final class ReviewCommandTests: XCTestCase {
    func testReadOnlyAndScoped() {
        let tools = ReviewCommand.allowedTools(scratch: "/s/r1")
        XCTAssertTrue(tools.contains("Write(/s/r1/**)"))
        XCTAssertFalse(tools.contains("Write"), "no unscoped write")
        XCTAssertFalse(tools.contains("Bash"), "no blanket Bash")
        for banned in ["push", "commit", "checkout", "reset", "merge", "rebase", "clean", "stash", "-X POST"] {
            XCTAssertFalse(tools.contains { $0.contains("git \(banned):") || $0.contains("git -C * \(banned):") || $0.contains(banned + " ") && banned == "-X POST" }, banned)
        }
        XCTAssertFalse(tools.contains { $0.hasPrefix("Bash(git -C *:") }, "git -C never covers every subcommand")
        let args = ReviewCommand.arguments(prNumber: 42, scratch: "/s/r1")
        XCTAssertEqual(args.first, "-p")
        XCTAssertTrue(args[1].hasPrefix("/homes-pr-review 42"))
        XCTAssertEqual(args[args.firstIndex(of: "--permission-mode")! + 1], "dontAsk")
        XCTAssertEqual(args[args.firstIndex(of: "--output-format")! + 1], "json")
    }
}
