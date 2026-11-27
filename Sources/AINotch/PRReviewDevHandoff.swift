import Foundation
import ReviewCore

/// Dev only: the hand-off to the coding chat (`--review-window-preview --select mine --own` / `--own-moved` /
/// `--own-comments`) and its lines in `--review-selfcheck`. Fixtures only; the pasteboard is never touched.
extension PRReviewDev {
    private static func fixtureComments() -> [RawComment] {
        [
            RawComment(id: 501, author: "Sam Poe", authorUUID: "u-me", path: "src/avatar.ts", line: 8, text: "Note to self: check the cache key.", createdOn: "2026-11-20T09:00:00Z"),
            RawComment(id: 502, author: "Alex Doe", authorUUID: "u-alex", path: "src/avatar.ts", line: 31, text: "Should the thumbnail be cleared when the photo is removed?\nIt looks like it is only dropped on the next upload.", createdOn: "2026-11-20T10:00:00Z"),
            RawComment(id: 503, parentID: 502, author: "Sam Poe", authorUUID: "u-me", text: "Good point, looking.", createdOn: "2026-11-20T10:30:00Z"),
            RawComment(id: 504, parentID: 502, author: "Alex Doe", authorUUID: "u-alex", text: "Thanks.", createdOn: "2026-11-20T10:45:00Z"),
            RawComment(id: 505, author: "review-bot", authorUUID: "u-bot", text: "2 possible issues: an unbounded cache and a missing await in the loader.", createdOn: "2026-11-20T09:30:00Z", isBot: true),
            RawComment(id: 506, author: "Jane Doe", authorUUID: "u-jane", path: "src/loader.ts", line: 12, text: "Resolved already.", createdOn: "2026-11-20T08:00:00Z", resolved: true),
        ]
    }

    /// A preview of my own pull request 221: `--own` a finished review on the current head, `--own-moved` one on an older
    /// head, `--own-comments` no review, only the comments of others. Returns the review's record to put in the ledger.
    static func ownFixtures(_ args: [String]) -> ReviewRecord? {
        guard args.contains("--own") || args.contains("--own-moved") || args.contains("--own-comments") else { return nil }
        PRReviewAPI.fixtureRaw = fixtureComments()
        guard !args.contains("--own-comments") else { return nil }
        let ref = PullRequestRef(workspace: "acme", repo: "web-app", id: 221)
        let head = args.contains("--own-moved") ? "9a8b7c6d5e4f" : "e5f6a7b8c9d0"
        var record = ReviewRecord(key: ref.key, head: head, phase: .done, auto: false, queuedAt: Date().timeIntervalSince1970 - 900)
        record.verdict = .requestChanges
        record.findings = ReviewFindings(blocking: 1, shouldFix: 1, nits: 1)
        record.finishedAt = Date().timeIntervalSince1970 - 600
        record.reportFile = "report.md"
        record.own = true
        let folder = PRReviewStore.folder(ref, head: head)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func write(_ name: String, _ text: String) { try? Data(text.utf8).write(to: folder.appendingPathComponent(name)) }
        let report = "**Pull request #221: cache the avatar thumbnails**\n\nThe cache has no size limit and one path skips the owner check.\n\nVERDICT: REQUEST CHANGES\n"
        write("report.md", report)
        write("review.md", report)
        write("chat.json", """
        {"version":1,"sessionID":"","seeded":true,"cards":[
         {"id":"c1","severity":"blocking","path":"src/avatar.ts","line":31,"title":"Unbounded cache","body":"The thumbnail cache grows without a limit, so a long session fills the memory. Cap it, for example at 200 entries, and drop the oldest first.","include":true,"suggestion":"const cache = new LruCache<string, Thumb>({ max: 200 });","finding":"F1"},
         {"id":"c2","severity":"should-fix","path":"src/loader.ts","line":12,"title":"Missing await","body":"The loader returns before the thumbnail is written, so the first read can miss it. Await the write.","include":true,"finding":"F2"},
         {"id":"c3","severity":"nit","path":"src/avatar.ts","line":5,"title":"Name","body":"Rename x to size.","include":false,"done":true,"finding":"F3"}],"messages":[]}
        """)
        return record
    }

    /// `--review-selfcheck`: the file, the line, the notice, the failed read and that nothing is sent.
    @MainActor
    static func selfCheckHandoff(scratch: URL, expect: (Bool, String) -> Void) async {
        let ref = PullRequestRef(workspace: "acme", repo: "web-app", id: 31)
        let folder = PRReviewStore.folder(ref, head: "aaaaaaaaaaaa")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? Data(#"[{"id":90,"author":"saved-bot","bot":true,"body":"saved by the review","resolved":false}]"#.utf8).write(to: folder.appendingPathComponent("others.json"))
        func card(_ id: String, done: Bool? = nil) -> SuggestedComment {
            var c = SuggestedComment(id: id, severity: .shouldFix, path: "src/a.ts", line: 3, title: "T\(id)", body: "Body \(id)")
            c.done = done
            return c
        }
        func input(_ others: HandoffOthers, _ failed: Bool) -> HandoffInput {
            HandoffInput(repo: ref.repo, number: ref.id, title: "A change", source: "feat/a", target: "main", reviewedHead: "aaaaaaaaaaaa", currentHead: "bbbbbbbbbbbb",
                         cards: [card("1"), card("2", done: true), card("3")], others: others, refreshFailed: failed, reportPath: folder.appendingPathComponent("review.md").path)
        }
        var copied: [String] = []
        let oldBoard = PRHandoff.writePasteboard
        PRHandoff.writePasteboard = { copied.append($0) }
        defer { PRHandoff.writePasteboard = oldBoard; PRReviewAPI.fixtureRaw = nil }
        let sentBefore = PRReviewAPI.sent.count

        PRReviewAPI.fixtureRaw = fixtureComments()
        let handoff = PRHandoff(ref: ref)
        handoff.me = { "u-me" }
        handoff.copy(folder: folder, input: input)
        for _ in 0..<100 where handoff.loading || handoff.notice == nil { try? await Task.sleep(nanoseconds: 20_000_000) }
        let url = PRHandoff.fileURL(ref)
        expect(url.lastPathComponent == "web-app-31-fix.md" && url.deletingLastPathComponent().path == PRReviewStore.baseURL.path, "handoff: the file is <repo>-<pr>-fix.md beside the review folders")
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        expect(copied == [ReviewHandoff.prompt(path: url.path)] && copied[0].contains("\"\(url.path)\""), "handoff: one quoted line on the pasteboard: \(copied)")
        expect(handoff.notice == "Copied · 2 findings, 2 comments", "handoff: notice \(handoff.notice ?? "nil")")
        expect(text.contains("review is of an older commit") && text.contains("Body 1") && text.contains("Body 3") && !text.contains("Body 2"), "handoff: moved head said, the ticked card left out")
        expect(text.contains("review-bot (bot)") && text.contains("Alex Doe · src/avatar.ts:31") && text.contains("- you:") && !text.contains("check the cache key"), "handoff: bot and person comments, replies, none of mine")
        expect(!text.contains("Resolved already.") && text.contains("1 resolved (left out)"), "handoff: resolved thread counted, not listed")
        expect(!text.contains("u-alex") && !text.contains("u-me"), "handoff: no account ids in the file")

        // A second copy overwrites the same file, so the pasted line never changes.
        handoff.copy(folder: folder, input: input)
        for _ in 0..<100 where handoff.loading { try? await Task.sleep(nanoseconds: 20_000_000) }
        expect(copied.count == 2 && copied[0] == copied[1], "handoff: the same line every copy")

        // Bitbucket cannot be read: the review's saved comments, said in the file and in the notice.
        PRReviewAPI.fixtureRaw = nil
        let oldComments = PRReviewAPI.fixtureComments
        PRReviewAPI.fixtureComments = []
        defer { PRReviewAPI.fixtureComments = oldComments }
        let offline = PRHandoff(ref: ref)
        offline.copy(folder: folder, input: input)
        for _ in 0..<100 where offline.loading || offline.notice == nil { try? await Task.sleep(nanoseconds: 20_000_000) }
        let after = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        expect(offline.notice == "Copied · 2 findings, 1 comment · comments could not be refreshed", "handoff: failed read notice \(offline.notice ?? "nil")")
        expect(after.contains("Comments could not be refreshed") && after.contains("saved-bot (bot)") && offline.failed, "handoff: failed read, the saved comments in the file and the flag set")
        expect(PRReviewAPI.sent.count == sentBefore, "handoff: nothing was posted")
        expect(!ReviewHandoff.canCopy(cards: [card("1", done: true)], others: HandoffOthers()) && ReviewHandoff.canCopy(cards: [], others: HandoffOthers(open: [HandoffComment(id: 1, author: "a", text: "t")])), "handoff: off with nothing left, on with only comments of others")
    }
}
