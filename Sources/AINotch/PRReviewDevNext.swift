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
}
