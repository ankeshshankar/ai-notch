import XCTest
@testable import ReviewCore

final class ReviewParseTests: XCTestCase {
    let approve = """
    PR #3403 Add thing — Arjun — feat/x → master — CI green
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
                                         updatedAt: now - age, now: now, ledger: ledger, autoOn: auto, repos: ReviewRepos(text: "r"))
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

final class ReviewReposTests: XCTestCase {
    func testAllowListGatesAutoQueueAndResume() {
        func queue(_ repos: ReviewRepos, key: String = "ws/api-service#7") -> Bool {
            ReviewPolicy.shouldAutoQueue(key: key, head: "abcdef123456", isDraft: false, iReview: true, myReviewDone: false,
                                         updatedAt: 0, now: 0, ledger: ReviewLedger(), autoOn: true, repos: repos)
        }
        XCTAssertFalse(queue(ReviewRepos()), "public default: empty list, no auto review")
        XCTAssertTrue(queue(ReviewRepos(text: "api-service, mobile-app")))
        XCTAssertTrue(queue(ReviewRepos(text: "WS/API-Service")), "workspace/repo, any case")
        XCTAssertFalse(queue(ReviewRepos(text: "api-service"), key: "ws/other#7"))
        XCTAssertFalse(queue(ReviewRepos(text: "other-ws/api-service")), "another workspace")
        var r = ReviewRecord(key: "ws/api-service#7", head: "abcdef123456", phase: .reviewing, auto: true, queuedAt: 1)
        var ledger = ReviewLedger(); ledger.set(r); ledger.settleAfterRestart(now: 2)
        r = ledger.record("ws/api-service#7", head: "abcdef123456")!
        func resume(_ repos: ReviewRepos) -> Bool {
            ReviewLedger.shouldResume(r, head: "abcdef123456", isDraft: false, iReview: true, myReviewDone: false, autoOn: true, repos: repos)
        }
        XCTAssertFalse(resume(ReviewRepos()))
        XCTAssertTrue(resume(ReviewRepos(text: "api-service")))
    }

    func testParseAndStore() {
        XCTAssertEqual(ReviewRepos(text: " a ,b;\nc,, ").entries, ["a", "b", "c"])
        let d = UserDefaults(suiteName: "review-repos-test")!
        d.removePersistentDomain(forName: "review-repos-test")
        XCTAssertEqual(ReviewRepos.load(d), ReviewRepos())
        ReviewRepos(text: "x, y").save(d)
        XCTAssertEqual(ReviewRepos.load(d).entries, ["x", "y"])
        d.removePersistentDomain(forName: "review-repos-test")
    }

    func testQueuedRecordsAreDroppedOnLaunch() {
        var ledger = ReviewLedger()
        ledger.set(ReviewRecord(key: "ws/other#1", head: "h1", phase: .queued, auto: true, queuedAt: 1))
        ledger.settleAfterRestart(now: 2)
        XCTAssertNil(ledger.record("ws/other#1", head: "h1"))
    }
}

final class ReviewResumeTests: XCTestCase {
    func interrupted(resumed: Bool? = nil) -> ReviewRecord {
        var r = ReviewRecord(key: "a#1", head: "abcdef123456", phase: .reviewing, auto: true, queuedAt: 1)
        var ledger = ReviewLedger()
        ledger.set(r)
        ledger.settleAfterRestart(now: 2)
        r = ledger.record("a#1", head: "abcdef123456")!
        r.resumed = resumed
        return r
    }

    func testInterruptedRunResumesOnceOnTheSameHead() {
        func go(_ r: ReviewRecord?, head: String? = "abcdef123456", draft: Bool = false, mine: Bool = false, auto: Bool = true) -> Bool {
            ReviewLedger.shouldResume(r, head: head, isDraft: draft, iReview: true, myReviewDone: mine, autoOn: auto, repos: ReviewRepos(entries: ["a"]))
        }
        XCTAssertEqual(interrupted().error, ReviewLedger.interruptedMessage)
        XCTAssertTrue(go(interrupted()))
        XCTAssertTrue(go(interrupted(), head: "abcdef1234567890"), "12 or 40 characters")
        XCTAssertFalse(go(interrupted(resumed: true)), "interrupted again: stays failed, no loop")
        XCTAssertFalse(go(interrupted(), head: "ffffffffffff"), "new commits: the normal flow handles it")
        XCTAssertFalse(go(interrupted(), auto: false))
        XCTAssertFalse(go(interrupted(), draft: true))
        XCTAssertFalse(go(interrupted(), mine: true))
        XCTAssertFalse(go(nil))
        var other = interrupted(); other.error = "no Bitbucket read token"
        XCTAssertFalse(go(other), "only an interruption")
        var done = interrupted(); done.phase = .done
        XCTAssertFalse(go(done))
    }

    func testResumedFlagRoundTrips() {
        let r = interrupted(resumed: true)
        XCTAssertEqual(try! JSONDecoder().decode(ReviewRecord.self, from: try! JSONEncoder().encode(r)).resumed, true)
        let old = #"{"key":"a#1","head":"h","phase":"failed","auto":true,"queuedAt":1}"#
        XCTAssertNil(try! JSONDecoder().decode(ReviewRecord.self, from: Data(old.utf8)).resumed, "old ledgers still read")
    }
}

final class ReviewToolsTests: XCTestCase {
    let scratch = "/Users/x/Library/Application Support/AINotch/reviews/r-1-abc"

    func testBranchListingAllowedMutationsDenied() {
        let tools = ReviewCommand.allowedTools(scratch: scratch)
        for form in ["-r", "-a", "--list", "--contains"] {
            XCTAssertTrue(tools.contains("Bash(git -C * branch \(form) *)"), form)
            XCTAssertTrue(tools.contains("Bash(git branch \(form):*)"), form)
        }
        for banned in ["-D", "-d", "-m", "-M", "-c", "-C"] {
            XCTAssertFalse(tools.contains { $0.hasPrefix("Bash(git branch \(banned)") || $0.hasPrefix("Bash(git -C * branch \(banned)") }, banned)
            XCTAssertTrue(ReviewCommand.deniedTools.contains("Bash(git -C * branch \(banned) *)"), banned)
            XCTAssertTrue(ReviewCommand.deniedTools.contains("Bash(git -C * branch * \(banned) *)"), "branch -r \(banned) x")
        }
        XCTAssertFalse(tools.contains("Bash(git branch:*)"), "bare branch (creates) is not allowed")
        let args = ReviewCommand.arguments(prNumber: 1, scratch: scratch, skill: "x", agentsJSON: "{}")
        XCTAssertTrue(ReviewCommand.deniedTools.contains("ScheduleWakeup"))
        XCTAssertTrue(ReviewCommand.deniedTools.contains("CronCreate"))
        XCTAssertEqual(args[args.firstIndex(of: "--disallowedTools")! + 1], ReviewCommand.deniedTools.joined(separator: ","))
    }

    func testScratchIsOutsideDotClaude() {
        let tools = ReviewCommand.allowedTools(scratch: scratch)
        XCTAssertTrue(tools.contains("Write(//Users/x/Library/Application Support/AINotch/reviews/r-1-abc/**)"))
        XCTAssertTrue(tools.contains("Edit(//Users/x/Library/Application Support/AINotch/reviews/r-1-abc/**)"))
    }

    func testPromptSaysToQuoteAndStayInside() {
        let p = ReviewCommand.prompt(prNumber: 3, scratch: scratch, skill: "body")
        XCTAssertTrue(p.contains("single quotes"))
        XCTAssertTrue(p.contains("(tabs)"))
        XCTAssertTrue(p.contains("Stay inside the worktree"))
    }

    func testBbgetHasNoSpaceInItsPathEvenWithASpacedScratch() {
        let args = ReviewCommand.arguments(prNumber: 1, scratch: scratch, skill: "x", agentsJSON: "{}", home: "/Users/x")
        let allowed = args[args.firstIndex(of: "--allowedTools")! + 1]
        XCTAssertTrue(allowed.contains("Bash(/Users/x/.claude/notch/bin/bbget *)"))
        XCTAssertFalse(allowed.contains("reviews/r-1-abc/bbget"))
        XCTAssertTrue(args[1].contains("/Users/x/.claude/notch/bin/bbget <url>"))
    }

    func testBbgetScriptRejectsFolders() throws {
        let dir = NSTemporaryDirectory() + "bbget-test"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let file = dir + "/bbget"
        try ReviewCommand.bbGetScript.write(toFile: file, atomically: true, encoding: .utf8)
        func status(_ args: [String]) -> Int32 {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = [file] + args
            p.environment = ["BB_API_TOKEN": "t", "AI_NOTCH_REVIEW_DIR": dir]
            p.standardError = FileHandle.nullDevice
            try? p.run(); p.waitUntilExit()
            return p.terminationStatus
        }
        XCTAssertEqual(status(["https://example.com/x"]), 2, "only the Bitbucket API")
        XCTAssertEqual(status(["https://api.bitbucket.org/2.0/user", "../x.json"]), 2, "no folder in the output name")
        XCTAssertEqual(status(["https://api.bitbucket.org/2.0/user", "/tmp/x.json"]), 2)
        XCTAssertEqual(status(["https://api.bitbucket.org/2.0/user", ".hidden"]), 2)
        try? FileManager.default.removeItem(atPath: dir)
    }

    func testNamesAreSettingsWithNeutralDefaults() {
        let defaults = UserDefaults(suiteName: "review-names-test")!
        defaults.removePersistentDomain(forName: "review-names-test")
        XCTAssertEqual(ReviewNames.load(defaults), ReviewNames(skill: "pr-review", lens: "pr-lens", verifier: "pr-verifier"))
        ReviewNames(skill: "my-review", lens: "my-lens", verifier: "my-check").save(defaults)
        XCTAssertEqual(ReviewNames.load(defaults).lens, "my-lens")
        XCTAssertEqual(ReviewNames(skill: "../x", lens: "a b", verifier: "").skill, "pr-review", "no path in a name")
        XCTAssertEqual(ReviewNames(skill: "ok", lens: "a b", verifier: "").lens, "pr-lens")
        let args = ReviewCommand.arguments(prNumber: 1, scratch: "/s", skill: "x", agentsJSON: "{}", home: "/h", skillName: "my-review")
        XCTAssertEqual(args[args.firstIndex(of: "--add-dir")! + 2], "/h/.claude/skills/my-review")
        defaults.removePersistentDomain(forName: "review-names-test")
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
        var limited = record()
        limited.denied = ["Bash"]
        XCTAssertFalse(ReviewGate.check(.approve, record: limited, currentHead: head, pipeline: .green).isAllowed, "a review that was refused a tool cannot approve")
        limited.verdict = .requestChanges
        XCTAssertTrue(ReviewGate.check(.requestChanges, record: limited, currentHead: head, pipeline: .green).isAllowed)
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
        XCTAssertTrue(tools.contains("Write(//s/r1/**)"))
        XCTAssertFalse(tools.contains("Write"), "no unscoped write")
        XCTAssertFalse(tools.contains("Bash"), "no blanket Bash")
        for banned in ["push", "commit", "checkout", "reset", "merge", "rebase", "clean", "stash", "-X POST"] {
            XCTAssertFalse(tools.contains { $0.contains("git \(banned):") || $0.contains("git -C * \(banned) ") || $0.contains(banned + " ") && banned == "-X POST" }, banned)
        }
        XCTAssertFalse(tools.contains { $0.hasPrefix("Bash(git -C *:") || $0 == "Bash(git -C *)" || $0 == "Bash(git -C * *)" }, "git -C never covers every subcommand")
        let args = ReviewCommand.arguments(prNumber: 42, scratch: "/s/r1", skill: "---\nname: x\n---\n\nSKILL BODY", agentsJSON: "{}")
        XCTAssertEqual(args.first, "-p")
        XCTAssertTrue(args[1].hasPrefix("SKILL BODY"))
        XCTAssertTrue(args[1].contains("PR number 42"))
        XCTAssertEqual(args[args.firstIndex(of: "--setting-sources")! + 1], "", "no user, project or local settings")
        XCTAssertEqual(args[args.firstIndex(of: "--permission-mode")! + 1], "dontAsk")
        XCTAssertEqual(args[args.firstIndex(of: "--output-format")! + 1], "json")
        let add = args.firstIndex(of: "--add-dir")!
        XCTAssertEqual(Array(args[(add + 1)...(add + 2)]), ["/s/r1", NSHomeDirectory() + "/.claude/skills/pr-review"])
        XCTAssertTrue(args[(add + 3)].hasPrefix("--"), "the variadic --add-dir ends before the next flag")
    }
}

final class ReviewHooksTests: XCTestCase {
    func testObserveOnlyHooks() throws {
        let args = ReviewCommand.arguments(prNumber: 42, scratch: "/s/r1", skill: "x", agentsJSON: "{}", hookCommand: "/h/ai-notch-hook")
        XCTAssertEqual(args[args.firstIndex(of: "--setting-sources")! + 1], "")
        let json = args[args.firstIndex(of: "--settings")! + 1]
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(Array(object.keys), ["hooks"], "hooks only, no permissions")
        let hooks = try XCTUnwrap(object["hooks"] as? [String: Any])
        for banned in ["PreToolUse", "PermissionRequest", "PermissionDenied"] { XCTAssertNil(hooks[banned], banned) }
        XCTAssertTrue(hooks.keys.contains("SubagentStart") && hooks.keys.contains("Stop") && hooks.keys.contains("SessionStart"))
        XCTAssertTrue(json.contains("/h/ai-notch-hook"))
        XCTAssertFalse(ReviewCommand.arguments(prNumber: 1, scratch: "/s", skill: "x", agentsJSON: "{}").contains("--settings"))
        XCTAssertEqual(args[args.firstIndex(of: "--permission-mode")! + 1], "dontAsk")
    }
}

final class ReviewAgentsTests: XCTestCase {
    func testFrontMatterAndJSON() {
        let file = "---\nname: lens\ndescription: One lens: of a PR\nmodel: claude-opus-5-5\ntools: Read, Grep, Bash\n---\n\nYou review.\n"
        let (meta, body) = ReviewAgents.parts(of: file)
        XCTAssertEqual(meta["description"], "One lens: of a PR")
        XCTAssertEqual(body, "You review.")
        let json = ReviewAgents.json(files: [file, "no front matter"])
        let object = try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: [String: Any]]
        XCTAssertEqual(Array(object.keys), ["lens"])
        XCTAssertEqual(object["lens"]?["tools"] as? [String], ["Read", "Grep", "Bash", "Write"])
        XCTAssertEqual(object["lens"]?["prompt"] as? String, "You review.")
        XCTAssertEqual(object["lens"]?["model"] as? String, "claude-opus-5-5")
    }
}

final class ReviewBitbucketReadTests: XCTestCase {
    func testTokenGoesThroughTheWrapperOnly() {
        let rules = ReviewCommand.allowedTools(scratch: "/s/r1")
        XCTAssertTrue(rules.contains("Bash(/s/r1/bbget *)"))
        XCTAssertFalse(rules.contains { $0.contains("curl") })
        XCTAssertTrue(ReviewCommand.bbGetScript.hasPrefix("#!/bin/sh"))
        XCTAssertTrue(ReviewCommand.bbGetScript.contains("https://api.bitbucket.org/2.0/*"))
        XCTAssertFalse(ReviewCommand.bbGetScript.contains("-X"))
        XCTAssertTrue(ReviewCommand.prompt(prNumber: 1, scratch: "/s/r1", skill: "x").contains("/s/r1/bbget"))
    }
}

final class ReviewSectionTests: XCTestCase {
    func testBulletsUnderBoldHeadings() {
        let report = "PR #1\n\n**BLOCKING**\nNone.\n\n**SHOULD-FIX**\n- a.ts:1 one\n  - sub point\n- b.ts:2 two\n\n**NIT**\n- c\n\n**CANNOT-VERIFY**\n- d\n\nLenses: 6 run\n\nVERDICT: REQUEST CHANGES"
        let parsed = ReviewParse.parse(report)
        XCTAssertEqual(parsed?.findings, ReviewFindings(blocking: 0, shouldFix: 2, nits: 1, cannotVerify: 1))
    }
}
