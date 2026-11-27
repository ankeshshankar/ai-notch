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
}
