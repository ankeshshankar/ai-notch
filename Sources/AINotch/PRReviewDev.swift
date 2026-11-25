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
        if let at = arguments.firstIndex(of: "--review-chat-live"), at + 3 < arguments.count {
            exit(liveChat(workspace: arguments[at + 1], folder: arguments[at + 2], message: arguments[at + 3], draft: arguments.contains("--draft")))
        }
    }

    // MARK: Self-check

    static func selfCheck() -> Int32 {
        var failures = 0, checks = 0
        func expect(_ ok: Bool, _ what: String) { checks += 1; if !ok { failures += 1; print("FAIL \(what)") } }
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
            expect(PRReviewAPI.sent.count == 5, "five comments sent: \(PRReviewAPI.sent.count)")
            expect(PRReviewAPI.sent.allSatisfy { $0.url == base + "/comments" }, "all to the comments endpoint")
            expect(PRReviewAPI.sent.contains { $0.body.contains("\"inline\"") == false && $0.body.contains("changelog") }, "the card with no file is general")
            expect(session.cards.allSatisfy(\.isPosted), "every card records its comment id")
            // Never twice.
            await session.postPending()
            expect(PRReviewAPI.sent.count == 5, "no second post")
            // And it survived on disk.
            let again = PRChatSession(ref: ref, head: "abc123def456", folder: folder)
            expect(again.cards.allSatisfy(\.isPosted), "posted ids persisted in chat.json")
            expect(PostPlan.pending(again.cards).isEmpty, "nothing pending after a restart")

            // Approve and request changes use the dry run too.
            PRReviewAPI.sent = []
            _ = await PRReviewAPI.send(.approve, to: ref)
            expect(PRReviewAPI.sent.last?.url == base + "/approve", "approve endpoint")
            done = true
        }
        let limit = Date().addingTimeInterval(20)
        while !done, Date() < limit { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        expect(done, "async checks finished")
        PRReviewAPI.fixtureComments = nil
        print(failures == 0 ? "review selfcheck ok (\(checks) checks)" : "review selfcheck FAILED (\(failures) of \(checks))")
        return failures == 0 ? 0 : 1
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
        // The folders and the ledger, written before the store reads them.
        var ledger = ReviewLedger()
        for fixture in fixtures {
            guard let record = fixture.record else { continue }
            ledger.set(record)
            writeFolder(PRReviewStore.folder(fixture.ref, head: record.head), fixture: fixture.ref.id, record: record)
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
        list.prs = fixtures.map { f in
            PullRequest(ref: f.ref, title: f.title, isDraft: false, author: PRPerson(uuid: nil, name: f.author), source: f.source, destination: "main", role: .reviewing,
                        participants: [], myReview: .none, taskCount: 0, commentCount: 2, updatedOn: "", updatedAt: now() - 3000,
                        url: URL(string: "https://bitbucket.org/acme/\(f.ref.repo)/pull-requests/\(f.ref.id)"),
                        build: f.build.map { PRBuild(state: $0, key: "fixture", pipeline: nil, url: nil) }, head: f.head)
        }
        let model = PRReviewWindowModel(store: store, list: list)
        let index = Int(value("--select") ?? "0") ?? 0
        model.selected = list.prs[min(max(index, 0), list.prs.count - 1)].id
        switch value("--overlay") {
        case "post": model.overlay = .post
        case "approve": model.overlay = .action(.approve)
        case "changes": model.overlay = .action(.requestChanges)
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

    private static func writeFolder(_ folder: URL, fixture id: Int, record: ReviewRecord) {
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
        write("chat.json", chat)
    }
}
