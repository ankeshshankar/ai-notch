import Foundation
import ReviewCore

/// Dev self-checks of the second review cycle (`--review-selfcheck`): models, runs kept, cards rebuilt, the
/// checked report, the gate, the follow-up, lessons. Fixtures only; nothing real is read or sent.
extension PRReviewDev {
    static func output(_ text: String, cost: Double = 0.01) -> PRReviewRunner.Outcome {
        let object: [String: Any] = ["result": text, "is_error": false, "total_cost_usd": cost, "session_id": "s-fake"]
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return ReviewOutput.parse(data).map { .finished($0) } ?? .failed("fixture")
    }

    @MainActor
    static func selfCheckModels(scratch: URL, expect: (Bool, String) -> Void) async {
        let threads = [
            ReplyThread(id: 7, text: "Use the helper.", replies: [ThreadReply(id: 8, parentID: 7, author: "A", byMe: false, text: "It does not exist.")]),
            ReplyThread(id: 9, text: "Check null.", replies: [ThreadReply(id: 10, parentID: 9, author: "A", byMe: false, text: "Done.")]),
        ]
        var calls: [(model: String, ids: [Int])] = []
        let result = await ReplyReading.read(threads: threads, head: "h1") { input, model in
            let sent = ((try? JSONSerialization.jsonObject(with: input)) as? [String: Any])?["threads"] as? [[String: Any]] ?? []
            let ids = sent.compactMap { $0["commentId"] as? Int }
            calls.append((model, ids))
            if model == ReviewModels.replies {
                return output("```reply\n{\"comment\":7,\"verdict\":\"not_fixed\",\"reason\":\"first read\",\"disagrees\":true}\n```\n```reply\n{\"comment\":9,\"verdict\":\"fixed\",\"reason\":\"a.ts:3\"}\n```")
            }
            return output("```reply\n{\"comment\":7,\"verdict\":\"explained\",\"reason\":\"helper missing\",\"disagrees\":true}\n```")
        }
        expect(calls.map(\.model) == ["claude-haiku-5-5", "claude-opus-5-5"], "replies: Haiku first, then Opus: \(calls.map(\.model))")
        expect(calls.last?.ids == [7], "replies: only the disagreement goes to Opus")
        expect(result.analyses.first { $0.commentID == 7 }?.verdict == .explained && result.analyses.first { $0.commentID == 7 }?.model == "claude-opus-5-5", "replies: the Opus read of a disagreement replaces the first")
        expect(result.analyses.first { $0.commentID == 9 }?.model == "claude-haiku-5-5", "replies: a plain fix stays on Haiku")
        // A failed re-read never shows the first read of a disagreement.
        let failing = await ReplyReading.read(threads: threads, head: "h1") { _, model in
            model == ReviewModels.replies ? output("```reply\n{\"comment\":7,\"verdict\":\"explained\",\"reason\":\"x\"}\n```") : .failed("down")
        }
        expect(failing.analyses.isEmpty && failing.failure != nil, "replies: no Opus read, no disagreement shown")
        // Saved in replies.json under analyses.
        let ref = PullRequestRef(workspace: "acme", repo: "web-app", id: 31)
        let folder = PRReviewStore.folder(ref, head: "hhhhhhhhhhhh")
        var file = RepliesFile()
        file.update(threads: threads, at: 1)
        file.apply(result.analyses)
        ReplyFiles.save(file, folder: folder)
        let raw = (try? Data(contentsOf: folder.appendingPathComponent("replies.json"))).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        expect((raw?["analyses"] as? [String: Any])?.count == 2, "replies.json keeps the classification under analyses")
        expect(ReplyFiles.load(folder).analyses[7]?.isCorrectDisagreement == true, "the saved read reloads")
    }

    /// Runs kept, cards rebuilt, "not checked".
    @MainActor
    static func selfCheckRuns(expect: (Bool, String) -> Void) async {
        let ref = PullRequestRef(workspace: "acme", repo: "web-app", id: 32)
        let head = "rrrrrrrrrrrr"
        let folder = PRReviewStore.folder(ref, head: head)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func put(_ text: String, _ name: String) { try? text.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        put(#"{"result":"VERDICT: REQUEST CHANGES","session_id":"s1"}"#, "out.json")
        put("F1 blocking a.ts:3\nF2 should-fix b.ts:4\nGATE: NOT_READY\nVERDICT: REQUEST CHANGES", "review.md")
        put(#"[{"id":"c1","finding":"F1","severity":"blocking","path":"a.ts","line":3,"body":"First wording."},{"id":"c2","finding":"F2","severity":"should-fix","path":"b.ts","line":4,"body":"Second."},{"id":"c3","finding":"F6","severity":"should-fix","path":"c.ts","line":1,"body":"Not in the report."}]"#, "comments.json")
        ReviewRuns.finish(folder)
        let first = PRChatSession(ref: ref, head: head, folder: folder)
        expect(first.cards.map(\.id) == ["c1", "c2", "c3"], "runs: cards seeded from the first run")
        expect(first.card("c3")?.unchecked == true && first.card("c3")?.include == false, "checked report: a card whose finding review.md lacks is not checked and off")
        first.setBody("c2", "My own words for the second.")
        first.setInclude("c1", false)
        // A second run of the same head, with a different comments.json.
        ReviewRuns.begin(folder)
        expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("review.md").path), "runs: the top level is cleared for the new run")
        put(#"{"result":"VERDICT: REQUEST CHANGES","session_id":"s2"}"#, "out.json")
        put("F1 blocking a.ts:3\nF2 should-fix b.ts:4\nF3 nit d.ts:8\nGATE: NOT_READY\nVERDICT: REQUEST CHANGES", "review.md")
        put(#"[{"id":"c1","finding":"F1","severity":"blocking","path":"a.ts","line":3,"body":"New wording."},{"id":"c2","finding":"F2","severity":"should-fix","path":"b.ts","line":4,"body":"New second."},{"id":"c3","finding":"F3","severity":"nit","path":"d.ts","line":8,"body":"A nit."}]"#, "comments.json")
        ReviewRuns.finish(folder)
        PRReviewStore.rebuildCards(ref, head: head)
        expect(ReviewRuns.numbers(folder) == [1, 2], "runs: both runs are kept: \(ReviewRuns.numbers(folder))")
        let second = PRChatSession(ref: ref, head: head, folder: folder)
        expect(second.card("c1")?.include == false, "rebuild: a card switched off stays off")
        expect(second.card("c2")?.body == "My own words for the second.", "rebuild: edited text stays")
        expect(second.cards.contains { $0.finding == "F3" && $0.badge == "new" } && !second.cards.contains { $0.finding == "F6" }, "rebuild: the new finding is a new card, the stale unposted one is gone")
        // A posted card stays as posted, with its Bitbucket id, even when the new run words it differently.
        var log = second.log
        if let i = log.cards.firstIndex(where: { $0.id == "c1" }) { log.cards[i].postedID = 4242; log.cards[i].include = true }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try? encoder.encode(log).write(to: folder.appendingPathComponent("chat.json"), options: .atomic)
        ReviewRuns.begin(folder)
        put(#"{"result":"x"}"#, "out.json")
        put("F1 blocking a.ts:3\nVERDICT: REQUEST CHANGES", "review.md")
        put(#"[{"id":"c1","finding":"F1","severity":"blocking","path":"a.ts","line":3,"body":"Third wording."}]"#, "comments.json")
        ReviewRuns.finish(folder)
        PRReviewStore.rebuildCards(ref, head: head)
        let third = PRChatSession(ref: ref, head: head, folder: folder)
        expect(third.card("c1")?.postedID == 4242 && third.card("c1")?.body == "New wording.", "rebuild: a posted card keeps its Bitbucket id and sent text")
        expect(ReviewRuns.numbers(folder) == [1, 2, 3], "runs: three runs kept")
        // An old folder: cards with no finding id and no review.md open as they were.
        let oldRef = PullRequestRef(workspace: "acme", repo: "web-app", id: 33)
        let oldFolder = PRReviewStore.folder(oldRef, head: "oooooooooooo")
        try? FileManager.default.createDirectory(at: oldFolder, withIntermediateDirectories: true)
        try? Data(#"[{"id":"c1","severity":"blocking","path":"a.ts","line":3,"body":"Old card."}]"#.utf8).write(to: oldFolder.appendingPathComponent("comments.json"))
        let old = PRChatSession(ref: oldRef, head: "oooooooooooo", folder: oldFolder)
        expect(old.cards.count == 1 && old.cards[0].unchecked == nil && old.cards[0].include, "old folder: opens with no badge")
    }

    /// The merge gate: read at settle, the three outcomes, every reason code, Approve only on READY, the override's lines.
    @MainActor
    static func selfCheckGate(expect: (Bool, String) -> Void) async {
        let ref = PullRequestRef(workspace: "acme", repo: "web-app", id: 34)
        let head = "gggggggggggg"
        let folder = PRReviewStore.folder(ref, head: head)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func settled(_ gate: String?) -> ReviewRecord {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent("gate.json"))
            if let gate { try? gate.write(to: folder.appendingPathComponent("gate.json"), atomically: true, encoding: .utf8) }
            let run = ReviewRecord(key: ref.key, head: head, phase: .reviewing, auto: false, queuedAt: 0)
            return PRReviewStore.settle(run, ref: ref, outcome: output("F1 x\nGATE: READY\nVERDICT: APPROVE"))
        }
        let ready = settled(#"{"gate":"READY","ci":{"state":"green","head":"gggggggggggg"},"coverage":{"files":4,"read":4,"unread":[]}}"#)
        let look = settled(#"{"gate":"NEEDS_LOOK","reasons":[{"code":"unread-files","text":"1 file not read"}],"coverage":{"files":4,"read":3,"unread":["a.ts"]},"ci":{"state":"green"}}"#)
        let not = settled(#"{"gate":"NOT_READY","reasons":[{"code":"open-blocking","text":"1 blocking finding open","refs":["F1"]}],"ci":{"state":"green"}}"#)
        let none = settled(nil)
        expect(ready.mergeGate?.gate == .ready && look.mergeGate?.gate == .needsLook && not.mergeGate?.gate == .notReady, "gate: settle reads all three outcomes")
        expect(none.mergeGate == nil, "gate: no gate.json, no gate")
        func approve(_ r: ReviewRecord) -> Bool {
            ReviewGate.check(.approve, record: r, currentHead: head, pipeline: .green).isAllowed
        }
        expect(approve(ready) && approve(none) && !approve(look) && !approve(not), "gate: Approve on READY or no gate only (VERDICT: APPROVE in all four)")
        // The window's words.
        expect(PRReviewBadge.short(ready, outdated: false).text == "Ready" && PRReviewBadge.short(look, outdated: false).text == "Needs look"
               && PRReviewBadge.short(not, outdated: true).text == "Not ready · older" && PRReviewBadge.short(none, outdated: false).text == "Approve", "gate: sidebar badges")
        // Each code, one by one, maps to the outcome the contract names.
        var wrong: [String] = []
        for code in GateCode.all {
            let want: MergeGate = GateCode.notReady.contains(code) ? .notReady : GateCode.needsLook.contains(code) ? .needsLook : .ready
            // A code that needs a fact is given it (reason hygiene): a failed check, a risky item, a pre-existing finding.
            let facts = code == "pack-check-failed" ? #","packChecks":[{"id":"x","state":"fail","text":"t"}]"# : code == "cannot-verify-risky" ? #","cannotVerify":[{"path":"a","what":"w","risky":true}]"# : ""
            let refs = code == "pre-existing" ? #","refs":["F2"]"# : ""
            let file = GateFile.parse(Data("{\"gate\":\"READY\",\"reasons\":[{\"code\":\"\(code)\"\(refs)}],\"ci\":{\"state\":\"green\"}\(facts)}".utf8))
            if file?.gate != want { wrong.append(code) }
        }
        expect(wrong.isEmpty, "gate: every reason code follows the rule \(wrong)")
        // The override confirm lists the gate's reasons.
        var replies = RepliesFile()
        replies.myRoots = []
        replies.resolvedOnBitbucket = []
        let info = ReviewGate.checkOverride(cards: [], replies: replies, record: look, currentHead: head, pipeline: .green).info
        expect(info?.lines.contains("Merge gate: Needs your look.") == true && info?.lines.contains("Gate: 1 file not read") == true, "gate: Approve anyway lists the overridden reasons: \(info?.lines ?? [])")
        let infoNot = ReviewGate.checkOverride(cards: [], replies: replies, record: not, currentHead: head, pipeline: .green).info
        expect(infoNot?.lines.contains("Merge gate: Not ready.") == true && infoNot?.lines.contains("Gate: 1 blocking finding open") == true, "gate: Approve anyway on Not ready lists its reason: \(infoNot?.lines ?? [])")
        var own = not; own.own = true
        var refused = not; refused.denied = ["Bash"]
        expect(!ReviewGate.checkOverride(cards: [], replies: replies, record: own, currentHead: head, pipeline: .green).isAvailable
               && !ReviewGate.checkOverride(cards: [], replies: replies, record: refused, currentHead: head, pipeline: .green).isAvailable, "gate: override stays off for own work and a refused tool")
        var onCard = SuggestedComment(id: "c9", severity: .nit, title: "x", body: "y"); onCard.include = true
        expect(!ReviewGate.checkOverride(cards: [onCard], replies: replies, record: not, currentHead: head, pipeline: .green).isAvailable, "gate: override stays off while a card is switched on")
        expect(not.mergeGate?.offLine == "Approve is off: 1 blocking finding open" && look.mergeGate?.offLine == "Approve is off: 1 file not read", "gate: the off line names the first reason: \(not.mergeGate?.offLine ?? "")")
        let many = GateFile.parse(Data(#"{"gate":"NOT_READY","reasons":[{"code":"open-blocking","text":"2 blocking findings open"},{"code":"ci-red"},{"code":"unread-files"}]}"#.utf8))
        expect(many?.offLine == "Approve is off: 2 blocking findings open (+2 more)", "gate: the off line counts the rest: \(many?.offLine ?? "")")
        let plain = ReviewGate.checkOverride(cards: [], replies: replies, record: ready, currentHead: head, pipeline: .green)
        expect(!plain.isAvailable, "gate: no override when a plain approve is open")
        // The replay flag: pinned head, blind line, and the one-line summary read from a folder.
        let lines = ReplayPrompt.lines(head: "abc123def456", blind: true)
        let prompt = ReviewCommand.prompt(prNumber: 9, scratch: "/s", skill: "body", extra: lines)
        expect(prompt.contains("checked out at commit abc123def456") && prompt.contains("`others.json` as `[]`") && prompt.contains("do not look at commits after abc123def456"), "replay: the prompt pins the commit and keeps others out")
        expect(!ReviewCommand.prompt(prNumber: 9, scratch: "/s", skill: "body").contains("REPLAY") && !ReplayPrompt.lines(head: "a", blind: false).joined().contains("others.json"), "replay: a normal run's prompt is unchanged, not-blind adds no blind line")
        let sum = FileManager.default.temporaryDirectory.appendingPathComponent("replay-summary-\(getpid())", isDirectory: true)
        try? FileManager.default.createDirectory(at: sum, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sum) }
        try? "NIT a.ts:1 — x\nGATE: NEEDS_LOOK\nVERDICT: REQUEST CHANGES".write(to: sum.appendingPathComponent("review.md"), atomically: true, encoding: .utf8)
        try? #"{"gate":"NEEDS_LOOK"}"#.write(to: sum.appendingPathComponent("gate.json"), atomically: true, encoding: .utf8)
        try? #"{"files":[{"path":"a","read":true},{"path":"b","read":false}]}"#.write(to: sum.appendingPathComponent("ledger.json"), atomically: true, encoding: .utf8)
        try? "[{}]".write(to: sum.appendingPathComponent("drops.json"), atomically: true, encoding: .utf8)
        let line = summary(ReviewOutput(text: "", isError: false, costUSD: 1.5, durationSeconds: 60, denied: []), dir: sum, minutes: 2)
        expect(line.contains("gate NEEDS_LOOK; verdict REQUEST CHANGES; findings 1 nit; drops 1; files read 1/2; cost 1.50 USD; 2.0 min"), "replay: summary line: \(line)")
        let panel = ready.mergeGate.map { $0.filesLine ?? "" } ?? ""
        expect(panel == "Read all 4 files", "gate: files-read line: \(panel)")
    }

    /// The follow-up and the gate: missing cards never approve, a fix needs its second read, merges are skipped, a big
    /// diff is split.
    @MainActor
    static func selfCheckFollowGate(scratch: URL, expect: (Bool, String) -> Void) async {
        let ref = PullRequestRef(workspace: "acme", repo: "web-app", id: 35)
        let baseHead = "bbbbbbbbbbbb", newHead = "ffffffffffff"
        let baseFolder = PRReviewStore.folder(ref, head: baseHead)
        let folder = PRReviewStore.folder(ref, head: newHead)
        for dir in [baseFolder, folder] { try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        try? Data(#"[{"id":"c1","finding":"F1","severity":"blocking","path":"a.ts","line":3,"body":"One."},{"id":"c2","finding":"F2","severity":"should-fix","path":"b.ts","line":4,"body":"Two."}]"#.utf8).write(to: baseFolder.appendingPathComponent("comments.json"))
        func previous(blocking: Int, shouldFix: Int) -> ReviewRecord {
            var r = ReviewRecord(key: ref.key, head: baseHead, phase: .done, auto: false, queuedAt: 1)
            r.verdict = .requestChanges
            r.findings = ReviewFindings(blocking: blocking, shouldFix: shouldFix, nits: 0)
            r.mergeGate = GateFile.parse(Data(#"{"gate":"NOT_READY","reasons":[{"code":"open-blocking"}],"ci":{"state":"green"}}"#.utf8))
            return r
        }
        func settle(_ followup: String, prev: ReviewRecord) -> ReviewRecord {
            try? followup.write(to: folder.appendingPathComponent("followup.json"), atomically: true, encoding: .utf8)
            try? FileManager.default.removeItem(at: folder.appendingPathComponent("chat.json"))
            var run = ReviewRecord(key: ref.key, head: newHead, phase: .reviewing, auto: false, queuedAt: 2)
            run.baseHead = baseHead
            let out = output("All fixed.\nVERDICT: APPROVE")
            return PRReviewStore.settleFollowUp(PRReviewStore.settle(run, ref: ref, outcome: out), existing: run, ref: ref, outcome: out, previous: prev)
        }
        let allFixed = #"{"verdict":"APPROVE","summary":"s","gate":"READY","comments":[{"id":"c1","status":"fixed","confirmed":true,"reason":"a.ts:3"},{"id":"c2","status":"fixed","confirmed":true,"reason":"b.ts:4"}],"new":[]}"#
        // The earlier review counted 5 findings but only two cards exist: it cannot be checked.
        let missing = settle(allFixed, prev: previous(blocking: 3, shouldFix: 2))
        expect(missing.mergeGate?.gate == .needsLook && missing.mergeGate?.reasons.contains { $0.code == "cannot-verify" } == true, "follow-up: missing cards give NEEDS_LOOK with cannot-verify")
        expect(missing.verdict == .requestChanges, "follow-up: never APPROVE with missing cards")
        let whole = settle(allFixed, prev: previous(blocking: 1, shouldFix: 1))
        expect(whole.mergeGate?.gate == .ready && whole.verdict == .approve && whole.findings?.blocking == 0, "follow-up: all cards fixed and confirmed, READY, APPROVE")
        expect(ReviewGate.check(.approve, record: whole, currentHead: newHead, pipeline: .green).isAllowed, "follow-up: Approve open on READY")
        let unconfirmed = settle(#"{"verdict":"APPROVE","gate":"READY","comments":[{"id":"c1","status":"fixed","confirmed":true},{"id":"c2","status":"fixed"}]}"#, prev: previous(blocking: 1, shouldFix: 1))
        expect(unconfirmed.mergeGate?.gate == .notReady && unconfirmed.verdict == .requestChanges, "follow-up: a fix with no second read stays open, gate not ready")
        let others = settle(#"{"verdict":"REQUEST CHANGES","gate":"NOT_READY","reasons":[{"code":"others-open","text":"A major comment is open"}],"othersOpen":[{"id":9,"author":"sam","asks":true,"severity":"major"}],"comments":[{"id":"c1","status":"fixed","confirmed":true},{"id":"c2","status":"fixed","confirmed":true}]}"#, prev: previous(blocking: 1, shouldFix: 1))
        expect(others.mergeGate?.gate == .notReady && others.mergeGate?.othersLine == "1 unresolved comment from others (1 critical or major)", "follow-up: others' open threads are kept in the gate")
        expect(settle(allFixed.replacingOccurrences(of: ",\"gate\":\"READY\"", with: ""), prev: previous(blocking: 1, shouldFix: 1)).mergeGate?.gate == .needsLook, "follow-up: no gate written after a gated review is not a pass")

        // The diff: merge commits that brought the target in are left out; a big diff is split.
        // git and the diff preparation block, so they run off the main thread.
        let d = await Task.detached { followDiffCheck(scratch: scratch, ref: ref) }.value
        expect(d.diff.contains("own.txt") && !d.diff.contains("target-only.txt"), "follow-up diff: the target's merged-in work is not the author's")
        expect(d.prompt.contains("1 merge commit that brought the target branch in is left out"), "follow-up prompt: names the skipped merge")
        // A big change: split into parts, each under the limit, none cut.
        expect(d.files.count >= 2 && d.sizes.allSatisfy { $0 <= DiffSplit.limit } && d.sizes.reduce(0, +) > 800_000, "follow-up diff: split into \(d.files.count) parts, sizes \(d.sizes)")
        if let text = d.bigPrompt { expect(text.contains("followup-1.diff") && text.contains("none is cut"), "follow-up prompt: every part named") } else { expect(false, "big follow-up prepared") }
    }

    struct FollowDiffCheck: Sendable { var diff = "", prompt = "", files: [String] = [], sizes: [Int] = [], bigPrompt: String? }

    /// Builds a small repository (own work, a merge of the target, one big change) and prepares both follow-ups.
    nonisolated static func followDiffCheck(scratch: URL, ref: PullRequestRef) -> FollowDiffCheck {
        var out = FollowDiffCheck()
        let repo = scratch.appendingPathComponent("fu-repo", isDirectory: true)
        try? FileManager.default.removeItem(at: repo)
        try? FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        func git(_ args: [String]) -> String {
            let r = runProcess("/usr/bin/git", ["-C", repo.path, "-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false"] + args, timeout: 60)
            return String(data: r?.output ?? Data(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        func write(_ name: String, _ text: String) { try? text.write(to: repo.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        _ = git(["init", "-q", "-b", "main"]); write("base.txt", "base\n"); _ = git(["add", "."]); _ = git(["commit", "-q", "-m", "base"])
        let base = git(["rev-parse", "HEAD"])
        _ = git(["checkout", "-q", "-b", "feature"]); write("own.txt", "own change\n"); _ = git(["add", "."]); _ = git(["commit", "-q", "-m", "own"])
        _ = git(["checkout", "-q", "main"]); write("target-only.txt", "from the target\n"); _ = git(["add", "."]); _ = git(["commit", "-q", "-m", "target"])
        _ = git(["checkout", "-q", "feature"]); _ = git(["merge", "-q", "--no-edit", "main"])
        let head = git(["rev-parse", "HEAD"])
        let dir = scratch.appendingPathComponent("fu-dir", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let job = PRReviewRunner.Job(ref: ref, head: head, repoPath: repo.path, dir: dir, token: "x")
        if case .success(let text) = PRReviewRunner.prepareFollowUp(job, .init(baseHead: base, inputJSON: Data("{}".utf8))) { out.prompt = text }
        out.diff = (try? String(contentsOf: dir.appendingPathComponent("followup.diff"), encoding: .utf8)) ?? ""
        _ = git(["checkout", "-q", "-b", "big", base])
        for i in 0..<5 { write("big\(i).txt", String(repeating: "a line of added text\n", count: 9000)) }
        _ = git(["add", "."]); _ = git(["commit", "-q", "-m", "big"])
        let bigHead = git(["rev-parse", "HEAD"])
        let bigDir = scratch.appendingPathComponent("fu-big", isDirectory: true)
        try? FileManager.default.removeItem(at: bigDir)
        try? FileManager.default.createDirectory(at: bigDir, withIntermediateDirectories: true)
        let big = PRReviewRunner.prepareFollowUp(PRReviewRunner.Job(ref: ref, head: bigHead, repoPath: repo.path, dir: bigDir, token: "x"), .init(baseHead: base, inputJSON: Data("{}".utf8)))
        out.files = ((try? FileManager.default.contentsOfDirectory(atPath: bigDir.path)) ?? []).filter { $0.hasPrefix("followup-") && $0.hasSuffix(".diff") }.sorted()
        out.sizes = out.files.map { (try? Data(contentsOf: bigDir.appendingPathComponent($0)).count) ?? 0 }
        if case .success(let text) = big { out.bigPrompt = text }
        return out
    }

    /// Learning: proposals from the three sources, nothing written until an approval, the approval writes lessons.md.
    @MainActor
    static func selfCheckLessons(scratch: URL, expect: (Bool, String) -> Void) async {
        let lessonsFile = scratch.appendingPathComponent("lessons-check.md")
        try? FileManager.default.removeItem(at: lessonsFile)
        try? FileManager.default.removeItem(at: LessonsStore.proposedURL)
        setenv("CLAUDE_NOTCH_LESSONS", lessonsFile.path, 1)
        defer { unsetenv("CLAUDE_NOTCH_LESSONS") }
        let store = LessonsStore.shared
        store.reload()
        let ref = PullRequestRef(workspace: "acme", repo: "web-app", id: 36)
        let head = "llllllllllll"
        let folder = PRReviewStore.folder(ref, head: head)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func put(_ text: String, _ name: String) { try? text.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        put("F1 should-fix a.ts:3\nVERDICT: REQUEST CHANGES", "review.md")
        put(#"[{"id":"c1","finding":"F1","severity":"should-fix","path":"a.ts","line":3,"title":"Rename the flag","body":"Rename it."}]"#, "comments.json")
        put(#"[{"id":10,"author":"sam","bot":false,"path":"a.ts","line":4,"body":"covered by our card","resolved":false,"asks":true},{"id":11,"author":"sam","bot":false,"path":"z.ts","line":9,"body":"This misses a null check.","resolved":false,"asks":true},{"id":12,"author":"ci","bot":true,"body":"summary","resolved":false,"asks":false}]"#, "others.json")
        let session = PRChatSession(ref: ref, head: head, folder: folder)
        session.setInclude("c1", true)
        expect(store.pending.isEmpty, "lessons: switching a card on proposes nothing")
        session.setInclude("c1", false)
        expect(store.pending.count == 1 && store.pending[0].kind == .noise && store.pending[0].repo == "web-app", "lessons: a card switched off by hand is a Noise proposal")
        store.others(ref: ref, head: head)
        expect(store.pending.map(\.kind) == [.noise, .missed], "lessons: a comment no card covers is a Missed proposal, a covered one and a bot's are not: \(store.pending.map(\.kind))")
        var replies = RepliesFile()
        replies.update(threads: [ReplyThread(id: 7, text: "Use the helper.", replies: [])], at: 1)
        store.replies([ReplyAnalysis(commentID: 7, verdict: .explained, reason: "The helper does not exist.", disagrees: true, model: ReviewModels.full),
                       ReplyAnalysis(commentID: 8, verdict: .fixed, reason: "done")], file: replies, ref: ref)
        expect(store.pending.map(\.kind) == [.noise, .missed, .wrong], "lessons: a correct disagreement is a Wrong proposal, a plain fix is not")
        session.setInclude("c1", false)
        expect(store.pending.count == 3, "lessons: the same source does not propose twice")
        expect(!FileManager.default.fileExists(atPath: lessonsFile.path), "lessons: nothing is appended before an approval")
        let noise = store.pending[0], wrong = store.pending[2]
        store.edit(noise.id, text: "Do not raise: flag names. Why: the team keeps them as they are.")
        expect(store.approve(noise.id) == nil, "lessons: approve")
        let written = (try? String(contentsOf: lessonsFile, encoding: .utf8)) ?? ""
        expect(written.contains("## web-app") && written.contains("### Noise\n- Do not raise: flag names. Why: the team keeps them as they are."), "lessons: the approved entry is in lessons.md under its repo and kind: \(written)")
        expect(!written.contains("null check") && !written.contains("helper"), "lessons: only the approved entry is written")
        store.dismiss(wrong.id)
        expect(store.pending.map(\.kind) == [.missed], "lessons: approved and dismissed leave the list")
        let saved = LessonsFile.decode(try? Data(contentsOf: LessonsStore.proposedURL))
        expect(saved.proposals.filter { $0.state == .approved }.count == 1 && saved.proposals.filter { $0.state == .dismissed }.count == 1, "lessons: states saved in lessons-proposed.json")
        expect(store.approve(noise.id) != nil, "lessons: an entry is added once")
    }
}

extension PRReviewDev {
    /// Pre-existing findings: the gate (a full run and a follow-up), the card, the report word, the follow-ups list,
    /// the run the limit stopped and the agent count.
    @MainActor
    static func selfCheckPreExisting(scratch: URL, expect: (Bool, String) -> Void) async {
        let ref = PullRequestRef(workspace: "acme", repo: "web-app", id: 36)
        let head = "hhhhhhhhhhhh"
        let folder = PRReviewStore.folder(ref, head: head)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let comments = #"[{"id":"c1","finding":"F1","severity":"pre-existing","path":"a.ts","line":3,"title":"Old join","body":"This was already here before this PR."},{"id":"c2","finding":"F2","severity":"nit","path":"b.ts","line":4,"body":"Rename."}]"#
        try? Data(comments.utf8).write(to: folder.appendingPathComponent("comments.json"))
        let gateJSON = #"{"gate":"READY","reasons":[],"ci":{"state":"green"},"coverage":{"files":2,"read":2,"unread":[]},"followUps":[{"path":"c.ts","line":9,"title":"No cap on page size"},{"path":"d.ts","line":2,"title":"Unescaped regex"}]}"#
        try? Data(gateJSON.utf8).write(to: folder.appendingPathComponent("gate.json"))
        let run = ReviewRecord(key: ref.key, head: head, phase: .reviewing, auto: false, queuedAt: 0)
        let full = PRReviewStore.settle(run, ref: ref, outcome: output("PRE-EXISTING a.ts:3 — old join\nNIT b.ts:4 — x\nGATE: NEEDS_LOOK\nVERDICT: APPROVE"))
        expect(full.findings == ReviewFindings(nits: 1, preExisting: 1), "pre-existing: the report word is its own bucket \(String(describing: full.findings))")
        expect(full.mergeGate?.gate == .needsLook && full.mergeGate?.shownReasons.map(\.code) == ["pre-existing"], "pre-existing: a card gives NEEDS_LOOK, reason pre-existing")
        expect(!ReviewGate.check(.approve, record: full, currentHead: head, pipeline: .green).isAllowed, "pre-existing: Approve stays off on Needs your look")
        expect(full.mergeGate?.followUps.count == 2 && full.mergeGate?.followUpsTitle == "Follow-ups (2)", "pre-existing: follow-ups parsed from gate.json")
        // The cards in the window: its own label, on by default, a nit still off.
        let session = PRChatSession(ref: ref, head: head, folder: folder)
        expect(session.cards.first?.severity == .preExisting && session.cards.first?.include == true && session.cards.last?.include == false, "pre-existing: card on by default, nit off")
        // Without a card or finding the file's own claim is dropped; follow-ups alone leave READY.
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("comments.json"))
        try? Data(#"{"gate":"READY","reasons":[{"code":"pre-existing"},{"code":"pack-check-failed"},{"code":"cannot-verify-risky"}],"ci":{"state":"green"},"followUps":[{"path":"c.ts","title":"x"}]}"#.utf8).write(to: folder.appendingPathComponent("gate.json"))
        let bare = PRReviewStore.settle(run, ref: ref, outcome: output("F1 x\nGATE: READY\nVERDICT: APPROVE"))
        expect(bare.mergeGate?.gate == .ready && bare.mergeGate?.shownReasons.isEmpty == true && bare.mergeGate?.followUps.count == 1, "pre-existing: reasons without their fact are dropped, follow-ups never change the gate")

        // A follow-up: the still-open pre-existing card is `pre-existing`, never should-fix; fixed, it is gone.
        let base = "iiiiiiiiiiii", next = "jjjjjjjjjjjj"
        let baseFolder = PRReviewStore.folder(ref, head: base), nextFolder = PRReviewStore.folder(ref, head: next)
        for dir in [baseFolder, nextFolder] { try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        try? Data(#"[{"id":"c1","finding":"F1","severity":"pre-existing","path":"a.ts","line":3,"body":"Already here."}]"#.utf8).write(to: baseFolder.appendingPathComponent("comments.json"))
        var previous = ReviewRecord(key: ref.key, head: base, phase: .done, auto: false, queuedAt: 1)
        previous.verdict = .approve
        previous.findings = ReviewFindings(preExisting: 3)
        previous.mergeGate = GateFile.parse(Data(#"{"gate":"NEEDS_LOOK","reasons":[{"code":"pre-existing","refs":["F1"]}],"ci":{"state":"green"}}"#.utf8))
        func settle(_ followup: String) -> ReviewRecord {
            try? followup.write(to: nextFolder.appendingPathComponent("followup.json"), atomically: true, encoding: .utf8)
            try? FileManager.default.removeItem(at: nextFolder.appendingPathComponent("chat.json"))
            var r = ReviewRecord(key: ref.key, head: next, phase: .reviewing, auto: false, queuedAt: 2)
            r.baseHead = base
            let out = output("Still open.\nVERDICT: APPROVE")
            return PRReviewStore.settleFollowUp(PRReviewStore.settle(r, ref: ref, outcome: out), existing: r, ref: ref, outcome: out, previous: previous)
        }
        let open = settle(#"{"verdict":"REQUEST CHANGES","gate":"NOT_READY","reasons":[{"code":"open-should-fix","text":"1 should-fix finding open","refs":["c1"]}],"comments":[{"id":"c1","status":"still_open","reason":"a.ts:3"}],"new":[]}"#)
        expect(open.mergeGate?.gate == .needsLook && open.mergeGate?.shownReasons.map(\.code) == ["pre-existing"], "pre-existing: a still-open card is NEEDS_LOOK, reason pre-existing: \(open.mergeGate?.shownReasons.map(\.code) ?? [])")
        expect(open.findings == ReviewFindings(preExisting: 1), "pre-existing: open findings are their own bucket \(String(describing: open.findings))")
        let fixed = settle(#"{"verdict":"APPROVE","gate":"READY","comments":[{"id":"c1","status":"fixed","confirmed":true,"reason":"a.ts:3"}],"new":[]}"#)
        expect(fixed.mergeGate?.gate == .ready && fixed.verdict == .approve, "pre-existing: the card fixed and confirmed, READY")
        expect(FollowUp.prompt(scratch: "/s", previousHead: base, newHead: next).contains("never counts as open blocking or should-fix"), "pre-existing: the follow-up prompt says so")

        // The run the limit stopped keeps its state in out.json.
        let stop = scratch.appendingPathComponent("stopped", isDirectory: true)
        try? FileManager.default.removeItem(at: stop)
        try? FileManager.default.createDirectory(at: stop, withIntermediateDirectories: true)
        try? Data("# r".utf8).write(to: stop.appendingPathComponent("review.md"))
        try? Data("{}".utf8).write(to: stop.appendingPathComponent("gate.json"))
        FileManager.default.createFile(atPath: stop.appendingPathComponent("out.json").path, contents: nil)
        StoppedRun(files: StoppedRun.present(in: stop), elapsed: 5400, limit: 5400).record(in: stop.appendingPathComponent("out.json"))
        let recorded = (try? Data(contentsOf: stop.appendingPathComponent("out.json"))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        expect(recorded?["subtype"] as? String == "stopped_by_limit" && recorded?["filesPresent"] as? [String] == ["review.md", "gate.json"], "stopped: out.json records files present and the limit")

        // The agent count: replayed request lines and repeats are not calls.
        let call = #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Agent","input":{"subagent_type":"lens","model":"opus"}}]}}"#
        let blob = #"{"type":"api-request-blob","message":{"content":[{"type":"tool_use","id":"t1","name":"Agent","input":{"subagent_type":"lens","model":"opus"}}]}}"#
        let two = #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t2","name":"Agent","input":{"subagent_type":"verifier"}}]}}"#
        expect(countAgents(in: [call, blob, two, blob, call].joined(separator: "\n"), defaults: ["verifier": "fable"]) == "lens:opus x1, verifier:fable x1", "live: agent calls counted once by id, request blobs skipped")
    }
}

/// Live progress of a running review (`--review-selfcheck`): folder state to steps, the poller's life, the labels. Fixtures only.
extension PRReviewDev {
    @MainActor
    static func selfCheckProgress(expect: (Bool, String) -> Void) async {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ai-notch-progress-selfcheck-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let folder = root.appendingPathComponent("review", isDirectory: true), sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try? fm.createDirectory(at: sessions, withIntermediateDirectories: true)
        let title = "PR review #31 · web-app"
        let watch = ReviewProgressPoller.Watch(folder: folder, kind: .full, title: title, since: 1000)

        ReviewProgressFixture.writeFull(.gather, to: folder)
        var read = ReviewProgressPoller.compute(["k": watch], sessions: sessions)["k"]
        expect(read?.current?.id == "listing" && read?.steps.first?.fact?.hasPrefix("Pipeline green") == true, "progress: gather done, listing is next")

        ReviewProgressFixture.writeFull(.halfDone, to: folder)
        try? ReviewProgressFixture.sessionJSON(title: title, startedAt: 1000, updatedAt: 1100, tool: "Read", agentsRunning: 2).write(to: sessions.appendingPathComponent("s1.json"))
        try? ReviewProgressFixture.sessionJSON(title: "PR review #99 · web-app", startedAt: 1000, updatedAt: 1200, tool: "Bash", agentsRunning: 5).write(to: sessions.appendingPathComponent("s2.json"))
        read = ReviewProgressPoller.compute(["k": watch], sessions: sessions)["k"]
        expect(read?.reviewersDone == 4 && read?.reviewersTotal == 9 && read?.shortCount == "4/9", "progress: 4 of 9 reviewers from the lens files")
        expect(read?.reviewers.filter { $0.state == .running }.count == 2 && read?.activity?.tool == "Read", "progress: running count and tool come from this review's own session")
        expect(read?.filesReported == 16 && read?.filesTotal == 24, "progress: files reported once each")
        expect(read?.checked == false && (read?.liveFindings.total ?? 0) > 0 && !fm.fileExists(atPath: folder.appendingPathComponent("comments.json").path),
               "progress: findings before the final check are unchecked and there is no comments.json to make cards from")
        expect((try? Data(contentsOf: folder.appendingPathComponent("comments.json"))).map { CommentParse.file($0).count } == nil, "progress: a mid-run folder yields no cards")

        ReviewProgressFixture.writeFull(.finalCheck, to: folder)
        read = ReviewProgressPoller.compute(["k": watch], sessions: sessions)["k"]
        expect(read?.current?.id == "final" && read?.suffix(elapsed: 120) == "2m · Final check", "progress: final check, suffix names it")
        ReviewProgressFixture.writeFull(.finished, to: folder)
        read = ReviewProgressPoller.compute(["k": watch], sessions: sessions)["k"]
        expect(read?.checked == true && read?.current?.id == "result", "progress: cards exist only once comments.json is written")

        // The live visuals, through the poller: a transcript with one session file per reviewer, read off the main thread.
        let nowT = Date().timeIntervalSince1970
        let liveFolder = root.appendingPathComponent("live", isDirectory: true)
        let transcript = ReviewLiveFixture.write(ReviewLiveFixture.large(working: 5, done: 6), folder: liveFolder, transcriptDir: root.appendingPathComponent("t", isDirectory: true), now: nowT)
        try? ReviewProgressFixture.sessionJSON(title: title, startedAt: 1000, updatedAt: nowT, tool: "Read", agentsRunning: 5, transcript: transcript.path).write(to: sessions.appendingPathComponent("s3.json"))
        let liveWatch = ReviewProgressPoller.Watch(folder: liveFolder, kind: .full, title: title, since: 1000)
        let book = LiveTrackerBook()
        let liveRead: ReviewProgress? = await withCheckedContinuation { c in
            DispatchQueue.global(qos: .utility).async { c.resume(returning: ReviewProgressPoller.compute(["k": liveWatch], sessions: sessions, trackers: book, now: nowT)["k"]) }
        }
        expect(liveRead?.fileMap.count == 168 && liveRead?.reviewers.count == 16, "live: 168 files and 16 reviewer tiles")
        expect(liveRead?.fileMap.contains { $0.state == .reading } == true && liveRead?.fileMap.contains { $0.state == .reported } == true, "live: files are being read and reported")
        expect(liveRead?.reviewers.filter { $0.state == .running }.count == 5 && liveRead?.reviewers.filter { $0.state == .done }.count == 6, "live: 5 working, 6 done tiles")
        expect(liveRead?.heartbeat(now: nowT)?.total ?? 0 > 50 && liveRead?.notice(now: nowT, since: nil) == nil, "live: the graph has steps and a moving run has no notice")
        expect(liveRead?.notice(now: nowT + 120, since: nil) != nil, "live: two quiet minutes give a notice")
        let later = ReviewProgressPoller.compute(["k": liveWatch], sessions: sessions, trackers: book, now: nowT)["k"]
        expect(later?.heartbeat(now: nowT)?.total == liveRead?.heartbeat(now: nowT)?.total, "live: a second read adds no steps twice")
        let gone = ReviewProgressPoller.compute(["k": liveWatch], sessions: sessions, trackers: LiveTrackerBook(), now: nowT)["k"]
        try? fm.removeItem(at: transcript)
        let broken = ReviewProgressPoller.compute(["k": liveWatch], sessions: sessions, trackers: LiveTrackerBook(), now: nowT)["k"]
        expect(gone?.reviewers.count == 16 && broken?.reviewers.count == 16 && broken?.fileMap.count == 168, "live: without session files the folder alone still shows the tiles and the map")

        // A follow-up and a replies-only run have their own steps.
        let other = root.appendingPathComponent("follow", isDirectory: true)
        ReviewProgressFixture.writeFollowUp(started: true, to: other)
        let follow = ReviewProgress.read(folder: other, kind: .followUp)
        expect(follow.steps.count == 3 && follow.current?.id == "earlier", "progress: follow-up steps")
        expect(ReviewProgress.read(folder: other, kind: .replies).steps.count == 2, "progress: replies steps")

        // The badge and the chip carry a short suffix while reviewing, and nothing while queued.
        var record = ReviewRecord(key: "acme/web-app#31", head: "h", phase: .reviewing, auto: true, queuedAt: 1)
        record.startedAt = Date().timeIntervalSince1970 - 252
        let half = ReviewProgress.read(folder: { ReviewProgressFixture.writeFull(.halfDone, to: other); return other }(), kind: .full)
        expect(PRReviewChip.describe(record, outdated: false, progress: half).0 == "Reviewing · 4m · 4/9", "progress: chip text (\(PRReviewChip.describe(record, outdated: false, progress: half).0))")
        expect(PRReviewBadge.short(record, outdated: false, progress: half).text == "Reviewing · 4m · 4/9", "progress: sidebar text")
        expect(PRReviewChip.describe(record, outdated: false).0 == "Reviewing…", "progress: no folder facts yet, the plain text")
        record.phase = .queued
        expect(PRReviewChip.describe(record, outdated: false, progress: half).0 == "Review queued", "progress: queued stays as it was")

        // The poller runs only while something is watched, and counts its watchers.
        let poller = ReviewProgressPoller(sessions: sessions) { _ in }
        expect(!poller.isRunning, "poller: idle at first")
        poller.retain(key: "k", watch); poller.retain(key: "k", watch)
        expect(poller.isRunning && poller.watchedKeys == ["k"], "poller: runs while watched")
        poller.release(key: "k")
        expect(poller.isRunning, "poller: one watcher left")
        poller.release(key: "k")
        expect(!poller.isRunning && poller.watchedKeys.isEmpty, "poller: stops with the last watcher")
        poller.release(key: "k")
        expect(!poller.isRunning, "poller: an extra release changes nothing")
    }
}
