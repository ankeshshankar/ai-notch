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
        if let at = arguments.firstIndex(of: "--review-replies-live"), at + 4 < arguments.count {
            exit(liveReplies(repo: arguments[at + 1], head: arguments[at + 2], input: arguments[at + 3], folder: arguments[at + 4]))
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

    /// `--review-replies-live <repo> <head> <reply-input-threads.json> <folder>`: one real read pass over reply threads
    /// (read-only, the user's Claude login); prints time, cost and how many threads came back, never their text.
    static func liveReplies(repo: String, head: String, input: String, folder: String) -> Int32 {
        let dir = URL(fileURLWithPath: folder, isDirectory: true)
        let job = PRReviewRunner.Job(ref: PullRequestRef(workspace: "acme", repo: "web-app", id: 1), head: head, repoPath: repo, dir: dir, token: "",
                                     replyRead: .init(inputJSON: (try? Data(contentsOf: URL(fileURLWithPath: input))) ?? Data("{}".utf8)))
        let started = Date()
        let result = PRReviewRunner().runSync(job)
        print(String(format: "seconds %.0f", Date().timeIntervalSince(started)))
        switch result {
        case .finished(let out):
            let parsed = ReplyBlocks.parse(out.text)
            print("cost \(out.costUSD.map { String(format: "%.3f", $0) } ?? "?") USD; threads \(parsed.analyses.count), skipped \(parsed.skipped), denied \(out.denied)")
            for a in parsed.analyses { print("  \(a.commentID) \(a.verdict.rawValue) draft \(a.draft == nil ? "no" : "yes") wording \(a.draft.map { ReplyPayload.problems($0).isEmpty ? "ok" : "BAD" } ?? "-")") }
            return 0
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
            await selfCheckReplies(ref: ref, base: base, expect: expect)
            await selfCheckOverride(ref: ref, base: base, expect: expect)
            await selfCheckResolveAll(ref: ref, base: base, expect: expect)
            await selfCheckModels(scratch: scratch, expect: expect)
            await selfCheckRuns(expect: expect)
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

    /// Reply threads: by `parent.id`, unseen counting, the AI's read, and the reply request (dry run only).
    @MainActor
    private static func selfCheckReplies(ref: PullRequestRef, base: String, expect: (Bool, String) -> Void) async {
        let folder = PRReviewStore.folder(ref, head: "eeeeeeeeeeee5555")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? Data(#"{"version":1,"sessionID":"s","seeded":true,"cards":[{"id":"k1","severity":"should-fix","path":"src/a.ts","line":2,"body":"Guard this.","include":true,"postedID":301},{"id":"k2","severity":"nit","body":"Rename.","include":true,"postedID":309}],"messages":[]}"#.utf8).write(to: folder.appendingPathComponent("chat.json"))
        try? FileManager.default.removeItem(at: ReplyFiles.seenURL(ref))
        PRReviewAPI.fixtureRaw = [
            RawComment(id: 301, author: "Sam Poe", authorUUID: "u-me", path: "src/a.ts", line: 2, text: "Guard this.", createdOn: "2026-11-20T10:00:00+00:00"),
            RawComment(id: 302, parentID: 301, author: "Alex Doe", authorUUID: "u-alex", text: "Done in the next commit.", createdOn: "2026-11-20T11:00:00+00:00"),
            RawComment(id: 303, parentID: 302, author: "Alex Doe", authorUUID: "u-alex", text: "And the test is added.", createdOn: "2026-11-20T12:00:00+00:00"),
            RawComment(id: 309, author: "Sam Poe", authorUUID: "u-me", text: "Rename.", createdOn: "2026-11-20T10:30:00+00:00"),
            RawComment(id: 320, author: "Sam Poe", authorUUID: "u-me", text: "A note I wrote by hand.", createdOn: "2026-11-20T10:40:00+00:00"),
            RawComment(id: 321, parentID: 320, author: "Alex Doe", authorUUID: "u-alex", text: "Which note?", createdOn: "2026-11-20T10:50:00+00:00"),
        ]
        defer { PRReviewAPI.fixtureRaw = nil }
        let session = PRChatSession(ref: ref, head: "eeeeeeeeeeee5555", folder: folder)
        session.me = { "u-me" }
        var reported = -1
        session.onRepliesChanged = { reported = $0 }
        session.loadExisting()
        for _ in 0..<40 where session.replies.threads.isEmpty { try? await Task.sleep(nanoseconds: 50_000_000) }
        expect(session.replies.threads.map(\.id) == [301, 320], "threads by parent.id: \(session.replies.threads.map(\.id))")
        expect(session.replies.thread(301)?.replies.map(\.id) == [302, 303], "a reply to a reply stays in the thread")
        expect(session.thread(forCard: session.card("k1")!)?.id == 301 && session.thread(forCard: session.card("k2")!) == nil, "a card finds its own thread")
        expect(session.otherThreads.map(\.id) == [320], "my own comment outside the cards gets its thread")
        expect(session.newReplyIDs == [302, 303, 321] && reported == 3, "3 unseen: \(session.newReplyIDs) reported \(reported)")
        session.markRepliesSeen()
        expect(reported == 0 && ReplyFiles.seen(ref) == [302, 303, 321], "seen state stored per pull request")
        session.loadExisting()
        try? await Task.sleep(nanoseconds: 200_000_000)
        expect(session.newReplyIDs.isEmpty, "nothing new after they were seen")
        PRReviewAPI.fixtureRaw?.append(RawComment(id: 330, parentID: 301, author: "Alex Doe", authorUUID: "u-alex", text: "One more thing.", createdOn: "2026-11-21T10:00:00+00:00"))
        session.loadExisting()
        for _ in 0..<40 where session.newReplyIDs.isEmpty { try? await Task.sleep(nanoseconds: 50_000_000) }
        expect(session.newReplyIDs == [330], "a later reply is the only new one: \(session.newReplyIDs)")

        // The AI's read, parsed from fenced blocks and stored with the thread.
        var file = ReplyFiles.load(folder)
        file.apply(ReplyBlocks.parse("```reply\n{\"comment\":301,\"verdict\":\"explained\",\"reason\":\"holds\",\"draft\":\"Makes sense, thanks.\"}\n```").analyses)
        ReplyFiles.save(file, folder: folder)
        let again = PRChatSession(ref: ref, head: "eeeeeeeeeeee5555", folder: folder)
        expect(again.replies.analysis(again.replies.thread(301)!)?.verdict == .explained && again.replyDraft(301) == "Makes sense, thanks.", "read and draft survive a restart")

        // The reply request: one POST with the parent, nothing before the click, nothing for bad wording.
        PRReviewAPI.sent = []
        await again.perform(.keepOpen, root: 301)
        expect(PRReviewAPI.sent.isEmpty && !again.replies.needsAttention(again.replies.thread(301)!), "keep open sends nothing")
        again.setReplyDraft(320, "Claude says rename it.")
        await again.perform(.reply, root: 320)
        expect(PRReviewAPI.sent.isEmpty, "a reply that names the AI is not sent")
        again.setReplyDraft(320, "This is the note about the retry count.")
        await again.perform(.replyAndResolve, root: 320)
        expect(PRReviewAPI.sent.map(\.url) == [base + "/comments", base + "/comments/320/resolve"], "reply, then resolve: \(PRReviewAPI.sent.map(\.url))")
        expect(PRReviewAPI.sent.first?.body == #"{"content":{"raw":"This is the note about the retry count."},"parent":{"id":320}}"#, "reply body shape: \(PRReviewAPI.sent.first?.body ?? "")")
        expect(again.replies.resolved == [320] && again.replies.thread(320)?.replies.last?.byMe == true, "the thread shows my reply and is resolved")
        PRReviewAPI.sent = []
        await again.perform(.resolve, root: 301)
        expect(PRReviewAPI.sent.map(\.url) == [base + "/comments/301/resolve"] && again.card("k1")?.resolved == true, "resolve marks the card")
    }

    /// "Resolve N fixed": which threads count, the one confirm's list sent in order, 409, a partial failure, a thread that
    /// changed since the confirm, and the override gate turning on once every thread is resolved (all on a dry run).
    @MainActor
    private static func selfCheckResolveAll(ref: PullRequestRef, base: String, expect: (Bool, String) -> Void) async {
        func raw(resolved: Set<Int> = [68]) -> [RawComment] {
            var list: [RawComment] = (61...70).map {
                RawComment(id: $0, author: "Sam Poe", authorUUID: "u-me", path: "src/a.ts", line: $0 - 50, text: "Comment \($0)\nsecond line", createdOn: "2026-11-20T10:\($0 - 10):00Z", resolved: resolved.contains($0))
            }
            for parent in [64, 65, 66, 67, 69, 70] {
                list.append(RawComment(id: parent + 100, parentID: parent, author: "Alex Doe", authorUUID: "u-alex", text: "Reply to \(parent).", createdOn: "2026-11-21T10:00:00Z"))
            }
            return list
        }
        func cardsJSON(only: [Int]? = nil) -> String {
            let all: [(Int, String, String)] = [
                (61, "blocking", #","status":"fixed","statusReason":"guard added at a.ts:12""#),
                (62, "should-fix", #","status":"still_open","statusReason":"no test yet""#),
                (63, "nit", #","status":"unclear""#),
                (64, "should-fix", ""), (65, "should-fix", ""), (66, "blocking", ""), (67, "nit", ""),
                (68, "should-fix", #","status":"fixed","statusReason":"done""#),
                (69, "should-fix", #","status":"fixed","statusReason":"done""#),
            ]
            let cards = all.filter { only?.contains($0.0) ?? true }.map {
                #"{"id":"c\#($0.0)","severity":"\#($0.1)","path":"src/a.ts","line":\#($0.0 - 50),"title":"Title \#($0.0)","body":"Body \#($0.0)","include":true,"postedID":\#($0.0),"postedAt":1\#($0.2)}"#
            }
            return #"{"version":1,"sessionID":"s","seeded":true,"cards":[\#(cards.joined(separator: ","))],"messages":[]}"#
        }
        let reads = """
        ```reply
        {"comment":64,"verdict":"fixed","reason":"null check added at a.ts:14"}
        ```
        ```reply
        {"comment":65,"verdict":"explained","reason":"holds"}
        ```
        ```reply
        {"comment":66,"verdict":"disagrees","reason":"pushes back"}
        ```
        ```reply
        {"comment":67,"verdict":"question","reason":"asks why"}
        ```
        ```reply
        {"comment":69,"verdict":"not_fixed","reason":"still reads null"}
        ```
        ```reply
        {"comment":70,"verdict":"fixed","reason":"cache cleared at b.ts:47"}
        ```
        """
        let heads = ["f6f6f6f6f6f6", "f7f7f7f7f7f7", "f8f8f8f8f8f8", "f9f9f9f9f9f9"]
        func make(_ head: String, resolved: Set<Int> = [68], cards: String? = nil) async -> PRChatSession {
            let folder = PRReviewStore.folder(ref, head: head)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? Data((cards ?? cardsJSON()).utf8).write(to: folder.appendingPathComponent("chat.json"))
            PRReviewAPI.fixtureRaw = raw(resolved: resolved)
            let first = PRChatSession(ref: ref, head: head, folder: folder)
            first.me = { "u-me" }
            first.loadExisting()
            for _ in 0..<60 where first.replies.myRoots == nil { try? await Task.sleep(nanoseconds: 50_000_000) }
            var file = ReplyFiles.load(folder)
            file.apply(ReplyBlocks.parse(reads).analyses)
            ReplyFiles.save(file, folder: folder)
            let session = PRChatSession(ref: ref, head: head, folder: folder)
            session.me = { "u-me" }
            return session
        }
        defer { PRReviewAPI.fixtureRaw = nil; PRReviewAPI.fixtureResolveStatus = nil }

        // Which threads count.
        let session = await make(heads[0])
        let items = session.resolvableThreads(currentHead: heads[0])
        expect(items.map(\.id) == [61, 64, 70], "resolve all: counts fixed by follow-up (61), by reply read (64) and my own thread (70): \(items.map(\.id))")
        expect(items.first?.severity == .blocking && items.first?.location == "src/a.ts:11" && items.first?.title == "Title 61" && items.first?.why == "guard added at a.ts:12" && items.first?.source == .followUp,
               "resolve all: a follow-up item has severity, file:line, title and the follow-up's reason: \(String(describing: items.first))")
        expect(items[1].why == "Reply read: null check added at a.ts:14" && items[1].source == .replyRead && items[2].severity == nil && items[2].title == "Comment 70", "resolve all: reply-read items give the reply reason; a hand-written thread uses its first line")
        expect(![62, 63, 65, 66, 67].contains(where: items.map(\.id).contains), "resolve all: still open, unclear, explained, disagrees and question are left out")
        expect(!items.map(\.id).contains(68) && !items.map(\.id).contains(69), "resolve all: resolved on Bitbucket and a disagreeing read are left out")
        expect(session.resolvableThreads(currentHead: "0123456789ab").map(\.id) == [64, 70] && session.resolvableThreads(currentHead: nil).map(\.id) == [64, 70], "resolve all: a follow-up of another head does not count")

        // One confirm, sent in order; the comments are read again; the cards and threads show resolved.
        PRReviewAPI.sent = []
        let said = await session.resolveAllFixed(items, currentHead: heads[0])
        expect(PRReviewAPI.sent.map(\.url) == [61, 64, 70].map { base + "/comments/\($0)/resolve" } && PRReviewAPI.sent.allSatisfy { $0.body == "" }, "resolve all: three POSTs in order, no body: \(PRReviewAPI.sent.map(\.url))")
        expect(said == "Resolved 3 threads" && session.card("c61")?.resolved == true && session.card("c64")?.resolved == true && session.replies.resolved.sorted() == [61, 64, 70], "resolve all: remembered: \(said)")
        expect(session.resolvableThreads(currentHead: heads[0]).isEmpty && session.bulkFailures.isEmpty, "resolve all: nothing left to resolve")
        PRReviewAPI.sent = []
        _ = await session.resolveAllFixed(items, currentHead: heads[0])
        expect(PRReviewAPI.sent.isEmpty, "resolve all: a second click sends nothing")

        // 409 means already resolved: done, not a failure.
        let session409 = await make(heads[1])
        PRReviewAPI.fixtureResolveStatus = { $0 == 61 ? 409 : 204 }
        PRReviewAPI.sent = []
        let said409 = await session409.resolveAllFixed(session409.resolvableThreads(currentHead: heads[1]), currentHead: heads[1])
        expect(said409 == "Resolved 3 threads" && session409.bulkFailures.isEmpty && session409.card("c61")?.resolved == true, "resolve all: 409 counts as done: \(said409)")
        expect(ResolveAll.answer(status: 409) == .done && ResolveAll.answer(status: 200) == .done && ResolveAll.answer(status: 204) == .done && ResolveAll.answer(status: 500) == .failed("Bitbucket answered 500"), "resolve all: status mapping")

        // A failure on one does not stop the rest; it is listed with its reason and stays resolvable.
        let sessionFail = await make(heads[2])
        PRReviewAPI.fixtureResolveStatus = { $0 == 64 ? 500 : $0 == 70 ? 403 : 200 }
        PRReviewAPI.sent = []
        let saidFail = await sessionFail.resolveAllFixed(sessionFail.resolvableThreads(currentHead: heads[2]), currentHead: heads[2])
        expect(PRReviewAPI.sent.count == 3 && saidFail == "Not all resolved: 1 done, 2 failed", "resolve all: keeps going after a failure: \(saidFail), \(PRReviewAPI.sent.count) sent")
        expect(sessionFail.bulkFailures.map(\.why) == ["Bitbucket answered 500", "only a comment thread's first comment can be resolved"]
               && sessionFail.bulkFailures.first?.label == "src/a.ts:14 · Title 64", "resolve all: the failures say which and why: \(sessionFail.bulkFailures)")
        expect(sessionFail.card("c61")?.resolved == true && sessionFail.card("c64")?.resolved != true && sessionFail.resolvableThreads(currentHead: heads[2]).map(\.id) == [64, 70], "resolve all: the failed ones stay open")
        PRReviewAPI.fixtureResolveStatus = nil

        // A thread resolved on Bitbucket since the confirm is dropped, not sent.
        let sessionMoved = await make(heads[3])
        let shown = sessionMoved.resolvableThreads(currentHead: heads[3])
        PRReviewAPI.fixtureRaw = raw(resolved: [68, 64])
        PRReviewAPI.sent = []
        let saidMoved = await sessionMoved.resolveAllFixed(shown, currentHead: heads[3])
        expect(PRReviewAPI.sent.map(\.url) == [61, 70].map { base + "/comments/\($0)/resolve" } && saidMoved == "Resolved 2 threads; 1 skipped (changed since the confirm)", "resolve all: re-checked on fresh data: \(saidMoved)")
        PRReviewAPI.fixtureRaw = nil
        let none = await sessionMoved.resolveAllFixed(shown, currentHead: heads[3])
        expect(none == "Not resolved: could not read the comments", "resolve all: unreadable comments send nothing: \(none)")

        // The gate: every thread of mine is resolved by one click, so Approve anyway turns on at once.
        let gateHead = "a7a7a7a7a7a7"
        let gateRef = PullRequestRef(workspace: "acme", repo: "web-app", id: 8)
        let gateFolder = PRReviewStore.folder(gateRef, head: gateHead)
        try? FileManager.default.createDirectory(at: gateFolder, withIntermediateDirectories: true)
        let gateCards = #"{"version":1,"sessionID":"s","seeded":true,"cards":[{"id":"g1","severity":"blocking","path":"src/a.ts","line":3,"title":"One","body":"b","include":true,"postedID":61,"postedAt":1,"status":"fixed","statusReason":"done"},{"id":"g2","severity":"should-fix","path":"src/a.ts","line":9,"title":"Two","body":"b","include":true,"postedID":64,"postedAt":1},{"id":"g3","severity":"nit","body":"n","include":false}],"messages":[]}"#
        try? Data(gateCards.utf8).write(to: gateFolder.appendingPathComponent("chat.json"))
        PRReviewAPI.fixtureRaw = raw(resolved: []).filter { [61, 64, 164].contains($0.id) }
        let gateSession = PRChatSession(ref: gateRef, head: gateHead, folder: gateFolder)
        gateSession.me = { "u-me" }
        gateSession.loadExisting()
        for _ in 0..<60 where gateSession.replies.myRoots == nil { try? await Task.sleep(nanoseconds: 50_000_000) }
        var gateFile = ReplyFiles.load(gateFolder)
        gateFile.apply(ReplyBlocks.parse("```reply\n{\"comment\":64,\"verdict\":\"fixed\",\"reason\":\"done\"}\n```").analyses)
        ReplyFiles.save(gateFile, folder: gateFolder)
        let live = PRChatSession(ref: gateRef, head: gateHead, folder: gateFolder)
        live.me = { "u-me" }
        var record = ReviewRecord(key: gateRef.key, head: gateHead, phase: .done, auto: false, queuedAt: 1)
        record.verdict = .requestChanges
        record.findings = ReviewFindings(blocking: 1, shouldFix: 1)
        record.finishedAt = 2
        let store = PRReviewStore()
        var ledger = store.ledger
        ledger.set(record)
        store.injectLedgerForCheck(ledger)
        let pr = PullRequest(ref: gateRef, title: "t", isDraft: false, author: PRPerson(uuid: nil, name: "Jane Doe"), source: "f", destination: "main", role: .reviewing, participants: [],
                             myReview: .none, taskCount: 0, commentCount: 0, updatedOn: "", updatedAt: 0, url: nil, build: PRBuild(state: .succeeded, key: "k", pipeline: nil, url: nil), head: gateHead)
        expect(!store.overrideGate(for: pr, session: live).isAvailable && live.resolvableThreads(currentHead: gateHead).count == 2, "resolve all gate: two open threads, Approve anyway is off")
        PRReviewAPI.fixtureFresh = PRReviewAPI.Fresh(isOpen: true, head: gateHead, pipeline: .green, alreadyApproved: false)
        PRReviewAPI.sent = []
        store.resolveAllFixed(live.resolvableThreads(currentHead: gateHead), on: pr, session: live)
        for _ in 0..<80 where store.acting[gateRef.key] != nil || store.notices[gateRef.key] == nil { try? await Task.sleep(nanoseconds: 50_000_000) }
        expect(store.notices[gateRef.key] == "Resolved 2 threads" && PRReviewAPI.sent.count == 2, "resolve all gate: resolved: \(store.notices[gateRef.key] ?? "-")")
        expect(store.overrideGate(for: pr, session: live).isAvailable, "resolve all gate: Approve anyway is on at once, without a refresh: \(store.overrideGate(for: pr, session: live))")
        PRReviewAPI.fixtureFresh = nil
        PRReviewAPI.fixtureRaw = nil
    }

    /// "Approve anyway" (the gate, then the click on a dry run) and the one-result rule of a follow-up.
    @MainActor
    private static func selfCheckOverride(ref: PullRequestRef, base: String, expect: (Bool, String) -> Void) async {
        let head = "a1a1a1a1a1a1", other = "b2b2b2b2b2b2"
        var record = ReviewRecord(key: ref.key, head: head, phase: .done, auto: false, queuedAt: 1)
        record.verdict = .requestChanges
        record.findings = ReviewFindings(blocking: 1, shouldFix: 1, nits: 1)
        record.finishedAt = 2
        func card(_ id: String, _ severity: CommentSeverity, posted: Int? = nil, on: Bool = false, status: FollowUpStatus? = nil) -> SuggestedComment {
            var c = SuggestedComment(id: id, severity: severity, title: "Title \(id)", body: "Body \(id)", include: on, postedID: posted)
            c.status = status
            return c
        }
        func replies(roots: [Int], resolved: [Int]?) -> RepliesFile {
            var file = RepliesFile()
            file.fetchedAt = 1
            file.myRoots = roots
            file.resolvedOnBitbucket = resolved
            return file
        }
        func gate(_ cards: [SuggestedComment], _ file: RepliesFile, record: ReviewRecord? = record, head h: String? = head, pipeline: PipelineState = .green,
                  open: Bool = true, approved: Bool = false) -> OverrideGate {
            ReviewGate.checkOverride(cards: cards, replies: file, record: record, currentHead: h, pipeline: pipeline, isOpen: open, alreadyApproved: approved)
        }
        let posted = [card("c1", .blocking, posted: 11, status: .stillOpen), card("c2", .shouldFix, posted: 12, status: .fixed)]
        let skipped = [card("s1", .shouldFix, status: .unclear), card("s2", .nit)]
        let allResolved = replies(roots: [11, 12], resolved: [11, 12])
        let ok = gate(posted + skipped, allResolved)
        expect(ok.isAvailable, "override: all resolved and all skipped is allowed: \(ok)")
        let lines = ok.info?.lines ?? []
        expect(lines.first == "Verdict REQUEST CHANGES is overridden." && lines.contains("1 blocking finding skipped."), "override: the confirm says it: \(lines)")
        expect(lines.contains("Blocking, resolved by you: Title c1") && lines.contains("Should-fix, on Skip: Title s1") && lines.contains("1 nit on Skip."), "override: lists the items: \(lines)")
        expect(!gate(posted + [card("s1", .shouldFix, on: true)], allResolved).isAvailable, "override: one card switched on blocks")
        expect(!gate(posted + skipped, replies(roots: [11, 12], resolved: [11])).isAvailable, "override: one unresolved thread blocks")
        expect(gate(posted + skipped, replies(roots: [11, 12], resolved: [11])).info == nil, "override: the reason is given")
        var cardResolved = posted
        cardResolved[1].resolved = true
        expect(gate(cardResolved + skipped, replies(roots: [11, 12], resolved: [11])).isAvailable, "override: resolved from the notch counts")
        expect(!gate(posted + skipped, replies(roots: [11, 12, 40], resolved: [11, 12])).isAvailable, "override: my own hand-written thread counts too")
        expect(!gate(posted + skipped, replies(roots: [], resolved: nil)).isAvailable, "override: threads never read blocks")
        var refused = record; refused.denied = ["Bash"]
        var mine = record; mine.own = true
        expect(!gate(skipped, allResolved, record: refused).isAvailable && !gate(skipped, allResolved, record: mine).isAvailable, "override: refused tool and own work stay hard blocks")
        expect(!gate(skipped, allResolved, head: other).isAvailable && !gate(skipped, allResolved, pipeline: .notGreen).isAvailable
               && !gate(skipped, allResolved, open: false).isAvailable && !gate(skipped, allResolved, approved: true).isAvailable, "override: moved head, red pipeline, closed, approved block")
        var approveRecord = record; approveRecord.verdict = .approve; approveRecord.findings = ReviewFindings()
        expect(!gate(skipped, allResolved, record: approveRecord).isAvailable, "override: not offered when a plain approve is open")

        // The click, on a dry run: one approve and nothing else; a thread resolved on Bitbucket but unresolved now sends nothing.
        let store = PRReviewStore()
        let folder = PRReviewStore.folder(ref, head: head)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var chat = ChatLog(); chat.cards = posted + skipped
        let encoder = JSONEncoder()
        try? encoder.encode(chat).write(to: folder.appendingPathComponent("chat.json"))
        var ledger = store.ledger
        ledger.set(record)
        store.injectLedgerForCheck(ledger)
        let pr = PullRequest(ref: ref, title: "t", isDraft: false, author: PRPerson(uuid: nil, name: "Jane Doe"), source: "f", destination: "main", role: .reviewing, participants: [],
                             myReview: .none, taskCount: 0, commentCount: 0, updatedOn: "", updatedAt: 0, url: nil, build: PRBuild(state: .succeeded, key: "k", pipeline: nil, url: nil), head: head)
        let session = PRChatSession(ref: ref, head: head, folder: folder)
        session.me = { "u-me" }
        PRReviewAPI.fixtureFresh = PRReviewAPI.Fresh(isOpen: true, head: head, pipeline: .green, alreadyApproved: false)
        func raw(resolved: Set<Int>) -> [RawComment] {
            [11, 12].map { RawComment(id: $0, author: "Sam Poe", authorUUID: "u-me", text: "t\($0)", createdOn: "2026-11-20T10:0\($0 - 10):00Z", resolved: resolved.contains($0)) }
        }
        PRReviewAPI.fixtureRaw = raw(resolved: [11, 12])
        session.loadExisting()
        for _ in 0..<60 where session.replies.resolvedOnBitbucket == nil { try? await Task.sleep(nanoseconds: 50_000_000) }
        expect(store.overrideGate(for: pr, session: session).isAvailable, "override: on offer once the threads are read as resolved")
        // Thread 12 was reopened on Bitbucket since: the click reads again and sends nothing.
        PRReviewAPI.fixtureRaw = raw(resolved: [11])
        PRReviewAPI.sent = []
        store.performOverride(on: pr, session: session)
        for _ in 0..<60 where store.acting[ref.key] != nil || store.notices[ref.key] == nil { try? await Task.sleep(nanoseconds: 50_000_000) }
        expect(PRReviewAPI.sent.isEmpty && store.notices[ref.key]?.hasPrefix("Not sent") == true, "override click: an unresolved thread sends nothing: \(store.notices[ref.key] ?? "")")
        PRReviewAPI.fixtureRaw = raw(resolved: [11, 12])
        PRReviewAPI.sent = []
        store.performOverride(on: pr, session: session)
        for _ in 0..<60 where store.acting[ref.key] != nil || PRReviewAPI.sent.isEmpty { try? await Task.sleep(nanoseconds: 50_000_000) }
        expect(PRReviewAPI.sent.map(\.url) == [base + "/approve"], "override click: one approve: \(PRReviewAPI.sent.map(\.url)) \(store.notices[ref.key] ?? "-")")
        expect(store.ledger.record(ref.key, head: head)?.posted == "approved" && store.notices[ref.key] == "Approved anyway", "override click: recorded")
        PRReviewAPI.fixtureFresh = nil
        PRReviewAPI.fixtureRaw = nil

        // One result per follow-up: the pass says APPROVE, an open should-fix card is left: the record, the note and the window say REQUEST CHANGES.
        let headA = "c3c3c3c3c3c3", headB = "d4d4d4d4d4d4"
        let folderA = PRReviewStore.folder(ref, head: headA), folderB = PRReviewStore.folder(ref, head: headB)
        for f in [folderA, folderB] { try? FileManager.default.createDirectory(at: f, withIntermediateDirectories: true) }
        var logA = ChatLog(); logA.cards = [card("k1", .shouldFix, posted: 21), card("k2", .shouldFix, status: .unclear)]
        try? encoder.encode(logA).write(to: folderA.appendingPathComponent("chat.json"))
        try? Data(#"{"verdict":"APPROVE","summary":"All fixed.","comments":[{"id":"k1","status":"fixed","reason":"done"}],"new":[]}"#.utf8).write(to: folderB.appendingPathComponent("followup.json"))
        var run = ReviewRecord(key: ref.key, head: headB, phase: .reviewing, auto: false, queuedAt: 3)
        run.baseHead = headA
        let out = ReviewOutput.parse(Data(#"{"result":"Done.\nVERDICT: APPROVE","session_id":"s","total_cost_usd":0.1}"#.utf8))!
        let settled = PRReviewStore.settleFollowUp(PRReviewStore.settle(run, ref: ref, outcome: .finished(out)), existing: run, ref: ref, outcome: .finished(out))
        let shown = PRChatSession(ref: ref, head: headB, folder: folderB)
        let note = shown.log.followUps.first
        expect(settled.verdict == .requestChanges && note?.verdict == .requestChanges && note?.reported == .approve, "one result: record \(String(describing: settled.verdict)), note \(String(describing: note?.verdict))")
        expect(settled.findings == shown.log.openFindings, "one result: the record's findings are the cards' open ones")
        // A second pass on the same head starts from that head's own cards (what I posted stays posted).
        var mine2 = shown.log
        mine2.cards[0].resolved = true
        try? encoder.encode(mine2).write(to: folderB.appendingPathComponent("chat.json"))
        expect(PRReviewStore.cardsFolder(ref, base: headA, head: headB) == folderB && PRReviewStore.cardsFolder(ref, base: headA, head: "e5e5e5e5e5e5") == folderA, "a second pass reads the head's own cards")
        // One pass per folder at a time; a dev run never writes in the real folders.
        let job = PRReviewRunner.Job(ref: ref, head: headB, repoPath: "/tmp", dir: folderB, token: "")
        let slot = PRReviewRunner.claim(job)
        expect(slot != nil && PRReviewRunner.claim(job) == nil, "a second pass in the same folder is refused")
        if let slot { PRReviewRunner.release(slot) }
        expect(PRReviewRunner.claim(job) != nil, "the folder is free again")
        PRReviewRunner.release(job.dir.standardizedFileURL.path + "#run")
        expect(PRReviewStore.isDevRun && PRReviewStore.isRealFolder(PRReviewStore.realBaseURL.appendingPathComponent("x-1-abc")) && !PRReviewStore.isRealFolder(folderB), "real folders are told apart from scratch ones")
        expect(!PRReviewStore.ledgerURL.path.hasPrefix(NSHomeDirectory() + "/.claude/"), "the ledger of a check is not the real one")
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
        if args.contains("--replies") { replyFixtures(store: store, ref: web(214), head: heads[0]) }
        if args.contains("--resolve-all") { resolveAllFixtures(store: store, ref: web(214), head: heads[0]) }
        if args.contains("--override") { overrideFixtures(store: store, ref: web(214), head: heads[0], resolved: !args.contains("--unresolved")) }
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
        case "thread": model.overlay = .thread(.replyAndResolve, 302)
        case "override": model.overlay = .override
        case "resolveall": model.overlay = .resolveAll
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
            if let path = value("--snapshot"), let view = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil })?.contentView,
               let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                // The screen may be locked (no screen capture): draw the view into a PNG instead.
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            FileHandle.standardError.write(Data("review-window \(info.number) \(Int(info.frame.minX)) \(Int(info.frame.minY)) \(Int(info.frame.width)) \(Int(info.frame.height))\n".utf8))
        }
    }

    /// `--resolve-all`: three of my threads that count as fixed (a follow-up Fixed card, a reply read Fixed on a card, a comment I wrote by hand),
    /// one still open, one explained, one resolved on Bitbucket. Resolving is a dry run (nothing is sent).
    @MainActor private static func resolveAllFixtures(store: PRReviewStore, ref: PullRequestRef, head: String) {
        store.meUUID = { "u-me" }
        let chat = """
        {"version":1,"sessionID":"s","seeded":true,"cards":[
         {"id":"c1","severity":"blocking","path":"src/profile/photo.service.ts","line":42,"title":"Delete by id","body":"No owner check on the delete.","include":true,"postedID":301,"postedAt":1,"status":"fixed","statusReason":"The route now checks the owner before deleting (photo.service.ts:44)."},
         {"id":"c2","severity":"should-fix","path":"src/profile/photo.service.ts","line":77,"title":"Default avatar","body":"Set the default avatar instead of clearing.","include":true,"postedID":302,"postedAt":1,"status":"still_open","statusReason":"The field is still cleared (photo.service.ts:79)."},
         {"id":"c3","severity":"should-fix","path":"src/profile/photo.ts","line":9,"title":"Empty list test","body":"Add a test for the empty list.","include":true,"postedID":303,"postedAt":1},
         {"id":"c4","severity":"nit","path":"src/profile/photo.ts","line":14,"title":"Log line","body":"The log prints the file path.","include":true,"postedID":304,"postedAt":1},
         {"id":"c5","severity":"nit","body":"Rename x to count.","include":false}],"messages":[],
         "followUps":[{"id":"f1","fromHead":"9f8e7d6c5b4a","toHead":"\(head)","commits":2,"at":2,"verdict":"REQUEST CHANGES","summary":"The owner check is in.","fixed":1,"stillOpen":1,"unclear":0,"newCards":0}]}
        """
        try? Data(chat.utf8).write(to: PRReviewStore.folder(ref, head: head).appendingPathComponent("chat.json"))
        func mine(_ id: Int, _ line: Int, _ text: String, resolved: Bool = false) -> RawComment {
            RawComment(id: id, author: "Sam Poe", authorUUID: "u-me", path: "src/profile/photo.ts", line: line, text: text, createdOn: "2026-11-20T10:0\(id - 300):00Z", resolved: resolved)
        }
        func theirs(_ id: Int, _ parent: Int, _ text: String) -> RawComment {
            RawComment(id: id, parentID: parent, author: "Alex Doe", authorUUID: "u-alex", text: text, createdOn: "2026-11-21T10:0\(id - 400):00Z")
        }
        PRReviewAPI.fixtureRaw = [mine(301, 42, "No owner check on the delete."), mine(302, 77, "Set the default avatar."), mine(303, 9, "Add a test for the empty list."),
                                  mine(304, 14, "The log prints the file path.", resolved: true), mine(320, 42, "Should this also clear the cached thumbnail?"),
                                  theirs(402, 302, "The old screens go next sprint."), theirs(403, 303, "Added in the last commit."), theirs(405, 320, "Cleared in removePhoto now.")]
        let folder = PRReviewStore.folder(ref, head: head)
        var file = RepliesFile()
        let roots = ReplyThreads.roots(in: PRReviewAPI.fixtureRaw ?? [], postedIDs: [301, 302, 303, 304], me: "u-me")
        file.update(threads: ReplyThreads.build(PRReviewAPI.fixtureRaw ?? [], roots: roots, me: "u-me"), at: Date().timeIntervalSince1970)
        file.apply(ReplyBlocks.parse("""
        ```reply
        {"comment": 302, "verdict": "explained", "reason": "The screens ship in this release, so the null check is still needed."}
        ```
        ```reply
        {"comment": 303, "verdict": "fixed", "reason": "The empty-list test exists (photo.test.ts:31)."}
        ```
        ```reply
        {"comment": 320, "verdict": "fixed", "reason": "removePhoto clears the cache (photo.ts:47)."}
        ```
        """).analyses)
        ReplyFiles.save(file, folder: folder)
    }

    /// `--override`: two posted comments (threads resolved on Bitbucket unless `--unresolved`), a should-fix and a nit on Skip, a
    /// REQUEST CHANGES review with one blocking finding in its count: "Approve anyway" is on offer.
    @MainActor private static func overrideFixtures(store: PRReviewStore, ref: PullRequestRef, head: String, resolved: Bool) {
        store.meUUID = { "u-me" }
        let chat = """
        {"version":1,"sessionID":"s","seeded":true,"cards":[
         {"id":"c1","severity":"blocking","path":"src/profile/photo.service.ts","line":42,"title":"Delete by id","body":"No owner check on the delete.","include":true,"postedID":301,"postedAt":1,"status":"still_open"},
         {"id":"c2","severity":"should-fix","path":"src/profile/photo.service.ts","line":77,"title":"Default avatar","body":"Set the default avatar instead of clearing.","include":true,"postedID":302,"postedAt":1,"status":"fixed"},
         {"id":"c3","severity":"should-fix","path":"src/profile/photo.ts","line":9,"title":"Empty list test","body":"Add a test for the empty list.","include":false,"status":"unclear"},
         {"id":"c4","severity":"nit","body":"Rename x to count.","include":false}],"messages":[]}
        """
        try? Data(chat.utf8).write(to: PRReviewStore.folder(ref, head: head).appendingPathComponent("chat.json"))
        PRReviewAPI.fixtureRaw = [
            RawComment(id: 301, author: "Sam Poe", authorUUID: "u-me", path: "src/profile/photo.service.ts", line: 42, text: "No owner check on the delete.", createdOn: "2026-11-20T10:00:00Z", resolved: resolved),
            RawComment(id: 302, author: "Sam Poe", authorUUID: "u-me", path: "src/profile/photo.service.ts", line: 77, text: "Set the default avatar.", createdOn: "2026-11-20T10:05:00Z", resolved: true),
        ]
    }

    /// `--replies`: authors answered my two posted comments (one with a long reply), plus a comment I wrote by hand; the AI's
    /// read is stored for the first two. Needs `--followup` so the cards are posted (ids 301 and 302).
    @MainActor private static func replyFixtures(store: PRReviewStore, ref: PullRequestRef, head: String) {
        store.meUUID = { "u-me" }
        try? FileManager.default.removeItem(at: ReplyFiles.seenURL(ref))
        let long = "I looked at this again and I think the owner check belongs one level up, in the route, rather than in the service: the service is also called from the nightly cleanup job, which has no user. " +
            "Moving it means the job keeps working and the route still refuses other people's files. I added a test for the route, and one for the job, and I also renamed the helper so it is clear it is not user-scoped. " +
            "Let me know if you would rather keep it in the service with a flag."
        PRReviewAPI.fixtureRaw = [
            RawComment(id: 301, author: "Sam Poe", authorUUID: "u-me", path: "src/profile/photo.service.ts", line: 42, text: "This deletes whatever file id the client sends, with no owner check.", createdOn: "2026-11-20T10:00:00Z"),
            RawComment(id: 401, parentID: 301, author: "Alex Doe", authorUUID: "u-alex", text: long, createdOn: "2026-11-20T11:00:00Z"),
            RawComment(id: 302, author: "Sam Poe", authorUUID: "u-me", path: "src/profile/photo.service.ts", line: 77, text: "Can we set the default avatar instead of clearing the field?", createdOn: "2026-11-20T10:05:00Z"),
            RawComment(id: 402, parentID: 302, author: "Alex Doe", authorUUID: "u-alex", text: "The old screens are being removed next sprint, so I would leave this one.", createdOn: "2026-11-20T11:10:00Z"),
            RawComment(id: 403, parentID: 402, author: "Sam Poe", authorUUID: "u-me", text: "They ship in the current release though.", createdOn: "2026-11-20T11:20:00Z"),
            RawComment(id: 404, parentID: 403, author: "Alex Doe", authorUUID: "u-alex", text: "Right, is a null check in the two screens enough?", createdOn: "2026-11-20T11:30:00Z"),
            RawComment(id: 320, author: "Sam Poe", authorUUID: "u-me", path: "src/profile/photo.ts", line: 42, text: "Should this also clear the cached thumbnail?", createdOn: "2026-11-20T10:40:00Z"),
            RawComment(id: 405, parentID: 320, author: "Jane Doe", authorUUID: "u-jane", text: "Good catch, the cache is cleared in removePhoto now.", createdOn: "2026-11-20T12:00:00Z"),
        ]
        let folder = PRReviewStore.folder(ref, head: head)
        var file = RepliesFile()
        let roots = ReplyThreads.roots(in: PRReviewAPI.fixtureRaw ?? [], postedIDs: [301, 302], me: "u-me")
        file.update(threads: ReplyThreads.build(PRReviewAPI.fixtureRaw ?? [], roots: roots, me: "u-me"), at: Date().timeIntervalSince1970)
        file.apply(ReplyBlocks.parse("""
        ```reply
        {"comment": 301, "verdict": "explained", "reason": "The owner check is in the route (photo.route.ts:18) and the job is not user-scoped.", "draft": "Makes sense, thanks. The route check covers it."}
        ```
        ```reply
        {"comment": 302, "verdict": "question", "reason": "Asks whether a null check in the two screens is enough; it is not for the directory screen (directory.ts:61).", "draft": "A null check in the profile screen is fine, but the directory screen also sorts on the field (directory.ts:61), so it still needs the default avatar."}
        ```
        ```reply
        {"comment": 320, "verdict": "fixed", "reason": "removePhoto clears the cache (photo.ts:47)."}
        ```
        """).analyses)
        ReplyFiles.save(file, folder: folder)
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
