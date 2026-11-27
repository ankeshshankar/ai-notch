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
            let file = GateFile.parse(Data("{\"gate\":\"READY\",\"reasons\":[{\"code\":\"\(code)\"}],\"ci\":{\"state\":\"green\"}}".utf8))
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
        let prompt = PRReviewRunner.prepareFollowUp(job, .init(baseHead: base, inputJSON: Data("{}".utf8)))
        let diff = (try? String(contentsOf: dir.appendingPathComponent("followup.diff"), encoding: .utf8)) ?? ""
        var promptText = ""
        if case .success(let text) = prompt { promptText = text }
        expect(diff.contains("own.txt") && !diff.contains("target-only.txt"), "follow-up diff: the target's merged-in work is not the author's")
        expect(promptText.contains("1 merge commit that brought the target branch in is left out"), "follow-up prompt: names the skipped merge")
        // A big change: split into parts, each under the limit, none cut.
        _ = git(["checkout", "-q", "-b", "big", base])
        for i in 0..<5 { write("big\(i).txt", String(repeating: "a line of added text\n", count: 9000)) }
        _ = git(["add", "."]); _ = git(["commit", "-q", "-m", "big"])
        let bigHead = git(["rev-parse", "HEAD"])
        let bigDir = scratch.appendingPathComponent("fu-big", isDirectory: true)
        try? FileManager.default.removeItem(at: bigDir)
        try? FileManager.default.createDirectory(at: bigDir, withIntermediateDirectories: true)
        let big = PRReviewRunner.prepareFollowUp(PRReviewRunner.Job(ref: ref, head: bigHead, repoPath: repo.path, dir: bigDir, token: "x"), .init(baseHead: base, inputJSON: Data("{}".utf8)))
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: bigDir.path)) ?? []).filter { $0.hasPrefix("followup-") && $0.hasSuffix(".diff") }.sorted()
        let sizes = files.map { (try? Data(contentsOf: bigDir.appendingPathComponent($0)).count) ?? 0 }
        expect(files.count >= 2 && sizes.allSatisfy { $0 <= DiffSplit.limit } && sizes.reduce(0, +) > 800_000, "follow-up diff: split into \(files.count) parts, sizes \(sizes)")
        if case .success(let text) = big { expect(text.contains("followup-1.diff") && text.contains("none is cut"), "follow-up prompt: every part named") } else { expect(false, "big follow-up prepared") }
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
