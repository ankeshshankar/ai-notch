import AppKit
import ReviewCore
import SwiftUI

/// Dev only, never the app's own paths. `--review-selfcheck` runs the review window's post, card
/// and chat-file logic against a dry run (nothing is sent). `--review-window-preview` opens the
/// window on fixtures in a temporary folder, for screenshots; it needs CLAUDE_NOTCH_REVIEWS and
/// CLAUDE_NOTCH_REVIEW_LEDGER to point at a scratch folder and AI_NOTCH_REVIEW_DRYRUN=1, and it
/// refuses to run without them.
enum PRReviewDev {
    static func runIfAsked(_ arguments: [String]) {
        if arguments.contains("--review-selfcheck") { exit(selfCheck()) }
        if let at = arguments.firstIndex(of: "--review-followup-live"), at + 5 < arguments.count {
            exit(liveFollowUp(repo: arguments[at + 1], base: arguments[at + 2], head: arguments[at + 3], input: arguments[at + 4], folder: arguments[at + 5]))
        }
        if let at = arguments.firstIndex(of: "--review-chat-live"), at + 3 < arguments.count {
            exit(liveChat(workspace: arguments[at + 1], folder: arguments[at + 2], message: arguments[at + 3], draft: arguments.contains("--draft")))
        }
    }

    /// `--review-followup-live <repo> <baseHead> <newHead> <input.json> <folder>`: one real follow-up pass
    /// (read-only, the user's Claude login) on a local clone; prints time, cost and the result file.
    static func liveFollowUp(repo: String, base: String, head: String, input: String, folder: String) -> Int32 {
        let dir = URL(fileURLWithPath: folder, isDirectory: true)
        let job = PRReviewRunner.Job(ref: PullRequestRef(workspace: "acme", repo: "web-app", id: 1), head: head, repoPath: repo, dir: dir, token: "",
                                     followUp: .init(baseHead: base, inputJSON: (try? Data(contentsOf: URL(fileURLWithPath: input))) ?? Data("{}".utf8)))
        let started = Date()
        let result = PRReviewRunner().runSync(job)
        print(String(format: "seconds %.0f", Date().timeIntervalSince(started)))
        switch result {
        case .finished(let out): print("cost \(out.costUSD.map { String(format: "%.2f", $0) } ?? "?") USD; followup.json: \(FileManager.default.fileExists(atPath: dir.appendingPathComponent("followup.json").path))"); return 0
        case .failed(let m): print("failed: \(m)"); return 1
        case .cancelled: print("cancelled"); return 1
        case .timedOut: print("timed out"); return 1
        }
    }

    // MARK: Self-check

    static func selfCheck() -> Int32 {
        var failures = 0, checks = 0
        func expect(_ ok: Bool, _ what: String) { checks += 1; if !ok { failures += 1; print("FAIL \(what)") } }
        // Nothing of the real ledger, reviews folder or Bitbucket is touched.
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("ai-notch-selfcheck-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        setenv("CLAUDE_NOTCH_REVIEWS", scratch.appendingPathComponent("reviews").path, 1)
        setenv("CLAUDE_NOTCH_REVIEW_LEDGER", scratch.appendingPathComponent("ledger.json").path, 1)
        setenv("CLAUDE_NOTCH_BITBUCKET_API", "http://127.0.0.1:9/2.0", 1)
        PRReviewAPI.forceDryRun = true
        PRReviewAPI.sent = []
        let ref = PullRequestRef(workspace: "acme", repo: "web-app", id: 7)
        let base = "\(BitbucketConfig.apiBase)/repositories/acme/web-app/pullrequests/7"

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ai-notch-review-selfcheck-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let comments = """
        [{"id":"c1","severity":"blocking","path":"src/a.ts","line":12,"title":"Null","body":"This can be null here, so removing the photo returns a 500. Set the default avatar instead."},
         {"id":"c2","severity":"should-fix","path":"src/b.ts","line":4,"title":"Test","body":"Please add a test for the empty list."},
         {"id":"c3","severity":"nit","path":"src/c.ts","line":9,"title":"Name","body":"Rename `x` to `count`."},
         {"id":"c4","severity":"should-fix","body":"Overall: please add a note to the changelog."},
         {"id":"c5","severity":"should-fix","path":"src/d.ts","line":2,"body":"Claude flagged this line."}]
        """
        try? Data(comments.utf8).write(to: folder.appendingPathComponent("comments.json"))
        try? Data(#"{"result":"VERDICT: REQUEST CHANGES","session_id":"sess-selfcheck"}"#.utf8).write(to: folder.appendingPathComponent("out.json"))
        try? Data("VERDICT: REQUEST CHANGES".utf8).write(to: folder.appendingPathComponent("report.md"))
        PRReviewAPI.fixtureComments = [ExistingComment(id: 1, author: "Jane Doe", path: "src/b.ts", line: 4, text: "needs a test")]

        // The raw request of one comment: inline, then general.
        var done = false
        Task { @MainActor in
            let inline = SuggestedComment(id: "x", severity: .shouldFix, path: "src/a.ts", line: 3, body: "Guard this.")
            let result = await PRReviewAPI.post(inline, to: ref)
            expect(result == .posted(900_001), "dry run answers posted")
            expect(PRReviewAPI.sent.last?.url == base + "/comments", "comments endpoint")
            expect(PRReviewAPI.sent.last?.method == "POST", "POST")
            expect(PRReviewAPI.sent.last?.body == #"{"content":{"raw":"Guard this."},"inline":{"path":"src/a.ts","to":3}}"#, "inline body: \(PRReviewAPI.sent.last?.body ?? "")")
            _ = await PRReviewAPI.post(SuggestedComment(id: "y", severity: .nit, body: "Overall fine."), to: ref)
            expect(PRReviewAPI.sent.last?.body == #"{"content":{"raw":"Overall fine."}}"#, "general body")
            PRReviewAPI.sent = []

            // The session: cards from comments.json, session id from out.json, defaults, duplicates.
            let session = PRChatSession(ref: ref, head: "abc123def456", folder: folder)
            expect(session.sessionID == "sess-selfcheck", "session id from out.json")
            expect(session.cards.map(\.id) == ["c1", "c2", "c3", "c4", "c5"], "cards seeded")
            expect(session.cards.map(\.include) == [true, true, false, true, true], "defaults by severity")
            session.loadExisting()
            try? await Task.sleep(nanoseconds: 100_000_000)
            expect(session.duplicate(of: session.card("c2")!)?.author == "Jane Doe", "duplicate on the same line")
            expect(session.duplicate(of: session.card("c1")!) == nil, "no duplicate elsewhere")

            // c5 is worded badly: posting refuses, and nothing is sent.
            await session.postPending()
            expect(PRReviewAPI.sent.isEmpty, "blocked wording sends nothing")
            session.setBody("c5", "Please check this line.")
            session.setInclude("c3", true)
            await session.postPending()
            // Five comments, and a task for the one blocking card.
            expect(PRReviewAPI.sent.count == 6, "five comments and a task sent: \(PRReviewAPI.sent.count)")
            expect(PRReviewAPI.sent.filter { $0.url == base + "/comments" }.count == 5 && PRReviewAPI.sent.filter { $0.url == base + "/tasks" }.count == 1, "five to the comments endpoint, one task")
            expect(PRReviewAPI.sent.contains { $0.body.contains("\"inline\"") == false && $0.body.contains("changelog") }, "the card with no file is general")
            expect(session.cards.allSatisfy(\.isPosted), "every card records its comment id")
            // Never twice.
            await session.postPending()
            expect(PRReviewAPI.sent.count == 6, "no second post")
            // And it survived on disk.
            let again = PRChatSession(ref: ref, head: "abc123def456", folder: folder)
            expect(again.cards.allSatisfy(\.isPosted), "posted ids persisted in chat.json")
            expect(PostPlan.pending(again.cards).isEmpty, "nothing pending after a restart")

            // Approve and request changes use the dry run too.
            PRReviewAPI.sent = []
            _ = await PRReviewAPI.send(.approve, to: ref)
            expect(PRReviewAPI.sent.last?.url == base + "/approve", "approve endpoint")
            await selfCheckNext(scratch: scratch, expect: expect)
            done = true
        }
        let limit = Date().addingTimeInterval(20)
        while !done, Date() < limit { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        expect(done, "async checks finished")
        PRReviewAPI.fixtureComments = nil
        print(failures == 0 ? "review selfcheck ok (\(checks) checks)" : "review selfcheck FAILED (\(failures) of \(checks))")
        return failures == 0 ? 0 : 1
    }

    /// The second round: suggestions and tasks, resolving, a follow-up's result, the combined actions. All dry runs.
    @MainActor
    static func selfCheckNext(scratch: URL, expect: (Bool, String) -> Void) async {
        let ref = PullRequestRef(workspace: "acme", repo: "web-app", id: 21)
        let base = "\(BitbucketConfig.apiBase)/repositories/acme/web-app/pullrequests/21"
        let headA = "aaaaaaaaaaaa1111", headB = "bbbbbbbbbbbb2222"
        let folderA = PRReviewStore.folder(ref, head: headA), folderB = PRReviewStore.folder(ref, head: headB)
        for folder in [folderA, folderB] { try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }

        // A finished review of A with three cards: one carries a code replacement.
        let chat = """
        {"version":1,"sessionID":"sess-full","seeded":true,"cards":[
         {"id":"c1","severity":"blocking","path":"src/a.ts","line":12,"title":"Null guard","body":"This can be null, so the call throws. Guard it.","include":true,"suggestion":"const name = user?.name ?? '';","postedID":501,"postedAt":1},
         {"id":"c2","severity":"should-fix","path":"src/b.ts","line":4,"body":"Please add a test for the empty list.","include":true,"postedID":502,"postedAt":1},
         {"id":"c3","severity":"nit","path":"src/c.ts","line":9,"body":"Rename x to count.","include":false}],"messages":[]}
        """
        try? Data(chat.utf8).write(to: folderA.appendingPathComponent("chat.json"))
        try? Data(#"{"result":"VERDICT: REQUEST CHANGES","session_id":"sess-full"}"#.utf8).write(to: folderA.appendingPathComponent("out.json"))
        var recordA = ReviewRecord(key: ref.key, head: headA, phase: .done, auto: true, queuedAt: 1)
        recordA.verdict = .requestChanges
        recordA.findings = ReviewFindings(blocking: 1, shouldFix: 1, nits: 1)
        recordA.finishedAt = 2
        recordA.sessionID = "sess-full"

        // The follow-up's input names what was posted and the new range.
        let log = FollowUp.baseLog(chatJSON: try? Data(contentsOf: folderA.appendingPathComponent("chat.json")), commentsJSON: nil, sessionID: "sess-full")
        let input = FollowUp.inputJSON(previousHead: headA, newHead: headB, previous: recordA, log: log, existing: [])
        let inputText = String(decoding: input, as: UTF8.self)
        expect(inputText.contains("\"bitbucketCommentId\" : 501") && inputText.contains(headB), "follow-up input has the posted ids and the new head")

        // The follow-up's answer, folded into the cards.
        try? Data(#"{"verdict":"REQUEST CHANGES","summary":"One left.","comments":[{"id":"c1","status":"fixed","reason":"guard added at a.ts:12"},{"id":"c2","status":"still_open","reason":"no test yet"}],"new":[{"id":"f1","severity":"should-fix","path":"src/d.ts","line":3,"body":"Close the handle here."}]}"#.utf8).write(to: folderB.appendingPathComponent("followup.json"))
        var recordB = ReviewRecord(key: ref.key, head: headB, phase: .reviewing, auto: false, queuedAt: 3)
        recordB.baseHead = headA
        recordB.commitCount = 2
        recordB.sessionID = "sess-full"
        let output = ReviewOutput.parse(Data(#"{"result":"Follow-up.\nVERDICT: REQUEST CHANGES","session_id":"sess-new","total_cost_usd":0.2}"#.utf8))
        let settled = PRReviewStore.settleFollowUp(PRReviewStore.settle(recordB, ref: ref, outcome: .finished(output!)), existing: recordB, ref: ref, outcome: .finished(output!))
        expect(settled.phase == .done && settled.verdict == .requestChanges, "follow-up settles done")
        expect(settled.sessionID == "sess-full", "the chat keeps the full review's session")
        expect(settled.findings == ReviewFindings(blocking: 0, shouldFix: 2, nits: 1), "open findings: \(String(describing: settled.findings))")
        let session = PRChatSession(ref: ref, head: headB, folder: folderB)
        expect(session.card("c1")?.status == .fixed && session.card("c2")?.status == .stillOpen, "badges on the cards")
        expect(session.cards.contains { $0.id == "f1" && $0.badge == "new" }, "new finding from the new commits")
        expect(session.log.followUps.first?.title == "Follow-up on 2 new commits", "timeline message")
        expect(session.resolvable.map(\.id) == ["c1"], "only the fixed posted thread can be resolved")

        // Resolve is one POST, only when asked.
        PRReviewAPI.sent = []
        await session.resolve("c2")
        expect(PRReviewAPI.sent.isEmpty, "a still-open thread is not resolved")
        await session.resolve("c1")
        expect(PRReviewAPI.sent.map(\.url) == [base + "/comments/501/resolve"], "resolve endpoint: \(PRReviewAPI.sent.map(\.url))")
        expect(PRReviewAPI.sent.first?.body == "" && session.card("c1")?.resolved == true, "resolve has no body and is remembered")

        // A suggestion and a task on a blocking card.
        PRReviewAPI.sent = []
        let folderD = PRReviewStore.folder(ref, head: "eeeeeeeeeeee5555")
        try? FileManager.default.createDirectory(at: folderD, withIntermediateDirectories: true)
        try? Data(#"{"version":1,"sessionID":"s","seeded":true,"cards":[{"id":"s1","severity":"blocking","path":"src/e.ts","line":8,"title":"Trim","body":"Trim the input before the lookup.","include":true,"suggestion":"const key = input.trim();"}],"messages":[]}"#.utf8).write(to: folderD.appendingPathComponent("chat.json"))
        let withSuggestion = PRChatSession(ref: ref, head: "eeeeeeeeeeee5555", folder: folderD)
        await withSuggestion.postPending()
        let sent = PRReviewAPI.sent
        expect(sent.count == 2, "a comment and its task: \(sent.count)")
        expect(sent.first?.body.contains("```suggestion\\nconst key = input.trim();\\n```") == true, "suggestion fence in the comment: \(sent.first?.body ?? "")")
        expect(sent.last?.url == base + "/tasks" && sent.last?.body.contains("\"comment\":{\"id\":") == true && sent.last?.body.contains("Trim") == true, "task linked to the comment: \(sent.last?.body ?? "")")
        expect(withSuggestion.card("s1")?.taskID != nil, "the task id is kept")
        PRReviewAPI.sent = []
        let off = PRChatSession(ref: ref, head: "eeeeeeeeeeee5555", folder: PRReviewStore.folder(ref, head: "ffffffffffff6666"))
        _ = off

        // The combined action: comments first, the decision last, one confirm's worth.
        let store = PRReviewStore()
        let head = "cccccccccccc3333"
        let folderC = PRReviewStore.folder(ref, head: head)
        try? FileManager.default.createDirectory(at: folderC, withIntermediateDirectories: true)
        try? Data(#"{"version":1,"sessionID":"s","seeded":true,"cards":[{"id":"k1","severity":"nit","path":"src/a.ts","line":2,"body":"Rename x to count.","include":true}],"messages":[]}"#.utf8).write(to: folderC.appendingPathComponent("chat.json"))
        var recordC = ReviewRecord(key: ref.key, head: head, phase: .done, auto: true, queuedAt: 5)
        recordC.verdict = .requestChanges
        recordC.findings = ReviewFindings(blocking: 0, shouldFix: 0, nits: 1)
        recordC.finishedAt = 6
        var ledger = store.ledger
        ledger.set(recordC)
        store.injectLedgerForCheck(ledger)
        let pr = PullRequest(ref: ref, title: "Rename", isDraft: false, author: PRPerson(uuid: nil, name: "Jane Doe"), source: "feature/x", destination: "main", role: .reviewing,
                             participants: [], myReview: .none, taskCount: 0, commentCount: 0, updatedOn: "", updatedAt: 0, url: nil,
                             build: PRBuild(state: .succeeded, key: "k", pipeline: nil, url: nil), head: head)
        let combined = PRChatSession(ref: ref, head: head, folder: folderC)
        combined.onPosted = { [weak store] count in store?.notePosted(key: ref.key, head: head, count: count) }
        let options = store.combinedOptions(for: pr, pending: PostPlan.pending(combined.cards))
        expect(options.map { $0.action } == [CombinedAction.postAndRequestChanges, CombinedAction.approveWithComments], "options with only nits left: \(options.map { $0.action })")
        PRReviewAPI.fixtureFresh = PRReviewAPI.Fresh(isOpen: true, head: head, pipeline: .green, alreadyApproved: false)
        PRReviewAPI.sent = []
        store.performCombined(.approveWithComments, on: pr, session: combined)
        for _ in 0..<100 where store.acting[ref.key] != nil || PRReviewAPI.sent.count < 2 { try? await Task.sleep(nanoseconds: 50_000_000) }
        expect(PRReviewAPI.sent.map(\.url) == [base + "/comments", base + "/approve"], "comment, then approve: \(PRReviewAPI.sent.map(\.url))")
        expect(store.ledger.record(ref.key, head: head)?.posted == "approved" && (store.ledger.record(ref.key, head: head)?.commentsPosted ?? 0) == 1, "record: approved with 1 comment posted")
        // A moved head stops everything before anything is sent.
        let head2 = "999999999999"
        let folder2 = PRReviewStore.folder(ref, head: head2)
        try? FileManager.default.createDirectory(at: folder2, withIntermediateDirectories: true)
        try? Data(#"{"version":1,"sessionID":"s","seeded":true,"cards":[{"id":"k1","severity":"nit","path":"src/a.ts","line":2,"body":"Rename x to count.","include":true}],"messages":[]}"#.utf8).write(to: folder2.appendingPathComponent("chat.json"))
        var record2 = recordC
        record2.head = head2
        var l2 = store.ledger
        l2.set(record2)
        store.injectLedgerForCheck(l2)
        var pr2 = pr
        pr2.head = head2
        PRReviewAPI.fixtureFresh = PRReviewAPI.Fresh(isOpen: true, head: "dddddddddddd4444", pipeline: .green, alreadyApproved: false)
        PRReviewAPI.sent = []
        store.performCombined(.postAndRequestChanges, on: pr2, session: PRChatSession(ref: ref, head: head2, folder: folder2))
        try? await Task.sleep(nanoseconds: 300_000_000)
        expect(PRReviewAPI.sent.isEmpty, "a moved head sends nothing: \(PRReviewAPI.sent.map(\.url))")
        PRReviewAPI.fixtureFresh = nil

        // Re-reviewing a pull request with an older finished review plans a follow-up on it.
        var other = ReviewRecord(key: "acme/web-app#33", head: headA, phase: .done, auto: true, queuedAt: 1)
        other.verdict = .approve
        other.sessionID = "sess-33"
        other.finishedAt = 2
        var l3 = store.ledger
        l3.set(other)
        store.injectLedgerForCheck(l3)
        let pr33 = PullRequest(ref: PullRequestRef(workspace: "acme", repo: "web-app", id: 33), title: "t", isDraft: false, author: PRPerson(uuid: nil, name: "Jane Doe"), source: "f", destination: "main",
                               role: .reviewing, participants: [], myReview: .none, taskCount: 0, commentCount: 0, updatedOn: "", updatedAt: 0, url: nil, head: headB)
        store.reviewNow(pr33)
        let queued = store.ledger.record("acme/web-app#33", head: headB)
        expect(queued?.baseHead == headA && queued?.sessionID == "sess-33", "re-review of a new head is a follow-up on the old one")
        store.reviewNow(pr33, full: true)
        expect(store.ledger.record("acme/web-app#33", head: headB)?.baseHead == nil, "Full re-review is a whole review")
    }

    /// One real turn on an existing review folder (`<ws>/<repo>#<id> <folder> <message>`); every post is a dry run.
    static func liveChat(workspace key: String, folder: String, message: String, draft: Bool) -> Int32 {
        PRReviewAPI.forceDryRun = true
        guard let hash = key.firstIndex(of: "#"), let slash = key.firstIndex(of: "/"), let id = Int(key[key.index(after: hash)...]) else { print("bad key"); return 2 }
        let ref = PullRequestRef(workspace: String(key[..<slash]), repo: String(key[key.index(after: slash)..<hash]), id: id)
        let url = URL(fileURLWithPath: folder, isDirectory: true)
        var finished = false
        Task { @MainActor in
            let session = PRChatSession(ref: ref, head: "live", folder: url)
            session.repoPath = { PRReviewStore.repoPath(ref) }
            print("session \(session.sessionID ?? "none"), cards \(session.cards.count), canChat \(session.canChat)")
            if draft { session.draftComments() } else { session.send(message) }
            if let n = session.notice { print("notice: \(n)") }
            while session.running { try? await Task.sleep(nanoseconds: 200_000_000) }
            print("after: notice \(session.notice ?? "-"), denied \(session.denied)")
            for m in session.log.messages.suffix(2) { print("[\(m.role.rawValue)\(m.isError ? " ERROR" : "")] \(m.text.prefix(600))") }
            print("cards now \(session.cards.count): \(session.cards.map { "\($0.id) \($0.severity.rawValue) \($0.path ?? "-"):\($0.line ?? 0)" })")
            finished = true
        }
        let limit = Date().addingTimeInterval(240)
        while !finished, Date() < limit { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        return finished ? 0 : 1
    }

    // MARK: Preview

    private struct Fixture {
        var ref: PullRequestRef
        var title: String
        var author: String
        var source: String
        var head: String
        var build: BuildState?
        var record: ReviewRecord?
    }

    private static func now() -> Double { Date().timeIntervalSince1970 }

    @MainActor
    static func preview(_ args: [String]) {
        let env = ProcessInfo.processInfo.environment
        guard let reviews = env["CLAUDE_NOTCH_REVIEWS"], !reviews.isEmpty, env["CLAUDE_NOTCH_REVIEW_LEDGER"] != nil, env["AI_NOTCH_REVIEW_DRYRUN"] == "1" else {
            FileHandle.standardError.write(Data("--review-window-preview needs CLAUDE_NOTCH_REVIEWS, CLAUDE_NOTCH_REVIEW_LEDGER and AI_NOTCH_REVIEW_DRYRUN=1\n".utf8))
            exit(2)
        }
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        let heads = ["a1b2c3d4e5f6", "b2c3d4e5f6a7", "c3d4e5f6a7b8", "d4e5f6a7b8c9"]

        func record(_ ref: PullRequestRef, head: String, verdict: ReviewVerdict, findings: ReviewFindings, denied: [String]? = nil) -> ReviewRecord {
            var r = ReviewRecord(key: ref.key, head: head, phase: .done, auto: true, queuedAt: now() - 900)
            r.verdict = verdict
            r.findings = findings
            r.finishedAt = now() - 600
            r.reportFile = "report.md"
            r.sessionID = "00000000-0000-4000-8000-00000000000\(ref.id % 10)"
            r.denied = denied
            return r
        }
        let web = { (id: Int) in PullRequestRef(workspace: "acme", repo: "web-app", id: id) }
        let fixtures: [Fixture] = [
            Fixture(ref: web(214), title: "Let users remove their profile photo", author: "Jane Doe", source: "feature/remove-photo", head: heads[0], build: .succeeded,
                    record: record(web(214), head: heads[0], verdict: .requestChanges, findings: ReviewFindings(blocking: 1, shouldFix: 1, nits: 1))),
            Fixture(ref: web(207), title: "Fix the off-by-one in the invoice list pagination", author: "John Roe", source: "fix/invoice-pagination", head: heads[1], build: .succeeded,
                    record: record(web(207), head: heads[1], verdict: .approve, findings: ReviewFindings(nits: 1))),
            Fixture(ref: web(199), title: "Move the settings screen to the new layout", author: "Jane Doe", source: "feature/settings-layout", head: heads[3], build: .running,
                    record: record(web(199), head: heads[2], verdict: .requestChanges, findings: ReviewFindings(shouldFix: 2))),
            Fixture(ref: PullRequestRef(workspace: "acme", repo: "api-service", id: 88), title: "Bump the retry backoff and add jitter", author: "Sam Poe", source: "chore/backoff", head: heads[2], build: nil,
                    record: nil),
        ]
        let followup = args.contains("--followup")
        let suggestion = args.contains("--suggestion")
        // The folders and the ledger, written before the store reads them.
        var ledger = ReviewLedger()
        for fixture in fixtures {
            guard var record = fixture.record else { continue }
            if followup, fixture.ref.id == 214 { record.baseHead = "9f8e7d6c5b4a"; record.commitCount = 2; record.commentsPosted = 2 }
            ledger.set(record)
            writeFolder(PRReviewStore.folder(fixture.ref, head: record.head), fixture: fixture.ref.id, record: record, followup: followup, suggestion: suggestion)
        }
        let ledgerData = (try? JSONEncoder().encode(ledger)) ?? Data()
        try? ledgerData.write(to: PRReviewStore.ledgerURL)
        PRReviewAPI.fixtureBehind = 3
        PRReviewAPI.fixtureComments = [
            ExistingComment(id: 11, author: "John Roe", path: "src/profile/photo.ts", line: 42, text: "Should this also clear the cached thumbnail?"),
            ExistingComment(id: 12, author: "Jane Doe", text: "Thanks for taking a look."),
        ]

        let store = PRReviewStore()
        let list = PRListSource()
        let jane = PRPerson(uuid: "u-jane", name: "Jane Doe"), john = PRPerson(uuid: "u-john", name: "John Roe"), sam = PRPerson(uuid: "u-sam", name: "Sam Poe")
        func people(_ id: Int) -> [PRParticipant] {
            switch id {
            case 214: return [PRParticipant(person: john, review: .approved, isReviewer: true), PRParticipant(person: sam, review: .changesRequested, isReviewer: true),
                              PRParticipant(person: jane, review: .none, isReviewer: true)]
            case 207: return [PRParticipant(person: john, review: .approved, isReviewer: true), PRParticipant(person: sam, review: .none, isReviewer: true)]
            default: return []
            }
        }
        func pr(_ f: Fixture, role: PRRole) -> PullRequest {
            PullRequest(ref: f.ref, title: f.title, isDraft: false, author: PRPerson(uuid: nil, name: f.author), source: f.source, destination: "main", role: role,
                        participants: people(f.ref.id), myReview: .none, taskCount: 0, commentCount: 2, updatedOn: "", updatedAt: now() - 3000,
                        url: URL(string: "https://bitbucket.org/acme/\(f.ref.repo)/pull-requests/\(f.ref.id)"),
                        build: f.build.map { PRBuild(state: $0, key: "fixture", pipeline: nil, url: nil) }, head: f.head)
        }
        list.prs = fixtures.map { pr($0, role: .reviewing) }
        list.mine = [Fixture(ref: PullRequestRef(workspace: "acme", repo: "web-app", id: 221), title: "Cache the avatar thumbnails", author: "You", source: "feature/avatar-cache",
                             head: "e5f6a7b8c9d0", build: .succeeded, record: nil)].map { pr($0, role: .mine) }
        let model = PRReviewWindowModel(store: store, list: list)
        let index = Int(value("--select") ?? "0") ?? 0
        model.selected = list.prs[min(max(index, 0), list.prs.count - 1)].id
        if value("--select") == "mine", let first = list.mine.first { model.selected = first.id }
        switch value("--overlay") {
        case "post": model.overlay = .post
        case "approve": model.overlay = .action(.approve)
        case "changes": model.overlay = .action(.requestChanges)
        case "combined": model.overlay = .combined(.postAndRequestChanges)
        case "keys": model.showKeys = true
        default: break
        }
        let controller = PRReviewWindowController.shared
        controller.quitsOnClose = true
        controller.show(model: model)
        if let size = value("--size")?.split(separator: "x").compactMap({ Double($0) }), size.count == 2 {
            controller.resize(to: NSSize(width: size[0], height: size[1]))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            guard let info = controller.windowInfo else { return }
            FileHandle.standardError.write(Data("review-window \(info.number) \(Int(info.frame.minX)) \(Int(info.frame.minY)) \(Int(info.frame.width)) \(Int(info.frame.height))\n".utf8))
        }
    }

    /// A finished follow-up: two posted comments (one fixed, one still open), one new finding.
    private static func followUpChat(_ record: ReviewRecord) -> String {
        """
        {"version":1,"sessionID":"\(record.sessionID ?? "")","seeded":true,
         "cards":[
          {"id":"c1","severity":"blocking","path":"src/profile/photo.service.ts","line":42,"title":"Delete by id","body":"This deletes whatever file id the client sends, with no owner check. Please only delete files under the user's own folder.","include":true,"postedID":301,"postedAt":1,"status":"fixed","statusReason":"The route now checks the owner before deleting (photo.service.ts:44)."},
          {"id":"c2","severity":"should-fix","path":"src/profile/photo.service.ts","line":77,"title":"Clearing the photo","body":"Clearing the field makes two older screens return a 500. Can we set the default avatar instead?","include":true,"postedID":302,"postedAt":1,"status":"still_open","statusReason":"The field is still cleared (photo.service.ts:79)."},
          {"id":"n-91c0de","severity":"nit","path":"src/profile/photo.service.ts","line":50,"title":"Log line","body":"Nit: this log line prints the file path; the id alone is enough.","include":true,"badge":"new"}
         ],
         "messages":[],
         "followUps":[{"id":"f1","fromHead":"9f8e7d6c5b4a","toHead":"\(record.head)","commits":2,"at":2,"verdict":"REQUEST CHANGES","summary":"The owner check is in. The photo is still cleared.","fixed":1,"stillOpen":1,"unclear":0,"newCards":1}]}
        """
    }

    private static func writeFolder(_ folder: URL, fixture id: Int, record: ReviewRecord, followup: Bool = false, suggestion: Bool = false) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func write(_ name: String, _ text: String) { try? Data(text.utf8).write(to: folder.appendingPathComponent(name)) }
        write("out.json", #"{"session_id":"\#(record.sessionID ?? "")","result":"x","is_error":false}"#)
        if record.verdict == .approve {
            write("report.md", """
            **Pull request #\(id): fix the off-by-one in the invoice list pagination, CI passed**

            This is good to merge. The page size is now applied once, the last page is no longer dropped, and the new test covers the empty list.

            **NIT**
            - `src/invoices/list.ts:31` — the page count helper could be inlined.

            VERDICT: APPROVE
            """)
            write("comments.json", #"[{"id":"c1","severity":"nit","path":"src/invoices/list.ts","line":31,"title":"Inline helper","body":"Small thing: `pageCount` has one caller, so it could be inlined."}]"#)
            return
        }
        write("report.md", """
        **Pull request #\(id): let users remove their profile photo, CI passed**

        This should not merge yet. Removing a photo leaves a field empty that two older screens read without a check, and the delete is not limited to the user's own files. The new tests cover the happy path only.

        **BLOCKING**
        - `src/profile/photo.service.ts:42-58` — **Any user can delete another user's file.**
          - The route takes a file id from the client and deletes it without checking the owner.
          - Fix: only delete files under the user's own folder.

        **SHOULD-FIX**
        - `src/profile/photo.service.ts:77` — **Clearing the photo breaks two older screens.**
          - They read the field without a null check and return a 500.
          - Fix: set the default avatar instead of clearing the field.

        **NIT**
        - `src/profile/photo.test.ts:12` — the test names repeat the file name.

        Tests were not run: the review worktree has no dependencies installed.

        VERDICT: REQUEST CHANGES
        """)
        write("comments.json", """
        [{"id":"c1","severity":"blocking","path":"src/profile/photo.service.ts","line":42,"title":"Delete by id","body":"This deletes whatever file id the client sends, with no owner check, so one user can delete another user's photo. Please only delete files under the user's own folder."},
         {"id":"c2","severity":"should-fix","path":"src/profile/photo.service.ts","line":77,"title":"Clearing the photo","body":"Clearing the field makes the profile and directory screens return a 500, since they read it without a null check. Can we set the default avatar instead?"},
         {"id":"c3","severity":"nit","path":"src/profile/photo.test.ts","line":12,"title":"Test names","body":"Nit: the test names repeat the file name, so they could be shorter."}]
        """)
        let chat = """
        {"version":1,"sessionID":"\(record.sessionID ?? "")","seeded":true,
         "cards":[
          {"id":"c1","severity":"blocking","path":"src/profile/photo.service.ts","line":42,"title":"Delete by id","body":"This deletes whatever file id the client sends, with no owner check, so one user can delete another user's photo. Please only delete files under the user's own folder.","include":true},
          {"id":"c2","severity":"should-fix","path":"src/profile/photo.service.ts","line":77,"title":"Clearing the photo","body":"Setting the default avatar instead of clearing the field would keep the profile and directory screens working, since they read it without a null check.","include":true,"badge":"revised"},
          {"id":"c3","severity":"nit","path":"src/profile/photo.test.ts","line":12,"title":"Test names","body":"Nit: the test names repeat the file name, so they could be shorter.","include":false},
          {"id":"n-4f2a1c","severity":"should-fix","path":"src/profile/photo.ts","line":42,"title":"Thumbnail cache","body":"Does removing the photo also need to clear the cached thumbnail? It looks like it is only dropped on the next upload.","include":true,"badge":"new"}
         ],
         "messages":[
          {"id":"m1","role":"user","text":"Make the second one softer, and draft a comment about the thumbnail cache.","at":1,"newCards":[],"revisedCards":[],"isError":false},
          {"id":"m2","role":"assistant","text":"Softened the second one into a question. I also drafted a note on the thumbnail cache: `removePhoto` clears the stored file but `getThumbnail` still serves the cached copy until the next upload (`photo.ts:42`).","at":2,"newCards":["n-4f2a1c"],"revisedCards":["c2"],"isError":false}
         ]}
        """
        write("chat.json", followup && id == 214 ? followUpChat(record) : suggestion && id == 214 ? chat.replacingOccurrences(of: #""title":"Clearing the photo","body":"Setting"#, with: #""title":"Clearing the photo","suggestion":"user.photo = DEFAULT_AVATAR;","body":"Setting"#) : chat)
    }
}
