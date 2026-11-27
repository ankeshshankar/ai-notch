import Foundation
import ReviewCore

/// Where the reply threads live: `replies.json` in the review's folder (the reply text, only
/// there), and one small file of seen reply ids per pull request beside the review folders.
enum ReplyFiles {
    static func url(_ folder: URL) -> URL { folder.appendingPathComponent("replies.json") }

    static func load(_ folder: URL) -> RepliesFile {
        guard let data = try? Data(contentsOf: url(folder)), let file = try? JSONDecoder().decode(RepliesFile.self, from: data) else { return RepliesFile() }
        return file
    }

    static func save(_ file: RepliesFile, folder: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard let data = try? encoder.encode(file) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: url(folder), options: .atomic)
    }

    /// Seen reply ids (numbers only, no text) of one pull request.
    static func seenURL(_ ref: PullRequestRef) -> URL {
        PRReviewStore.baseURL.appendingPathComponent("\(ref.repo)-\(ref.id)-replies-seen.json")
    }

    static func seen(_ ref: PullRequestRef) -> Set<Int> {
        guard let data = try? Data(contentsOf: seenURL(ref)), let ids = try? JSONDecoder().decode([Int].self, from: data) else { return [] }
        return Set(ids)
    }

    static func markSeen(_ ref: PullRequestRef, ids: Set<Int>) {
        let all = seen(ref).union(ids)
        guard let data = try? JSONEncoder().encode(all.sorted()) else { return }
        try? FileManager.default.createDirectory(at: PRReviewStore.baseURL, withIntermediateDirectories: true)
        try? data.write(to: seenURL(ref), options: .atomic)
    }

    /// The comments the app posted for a review: the cards' Bitbucket ids in `chat.json`.
    static func postedIDs(folder: URL) -> Set<Int> {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("chat.json")), let log = try? JSONDecoder().decode(ChatLog.self, from: data) else { return [] }
        return postedIDs(log)
    }

    static func postedIDs(_ log: ChatLog) -> Set<Int> { Set(log.cards.compactMap(\.postedID)) }

    /// Folds a fresh read of the pull request's comments into `replies.json`: the threads change, the
    /// AI's read and what was done about each thread stay.
    @discardableResult
    static func update(raw: [RawComment], ref: PullRequestRef, folder: URL, me: String?, posted: Set<Int>, now: Double = Date().timeIntervalSince1970) -> RepliesFile {
        var file = load(folder)
        let roots = ReplyThreads.roots(in: raw, postedIDs: posted.union(postedIDs(folder: folder)), me: me)
        file.update(threads: ReplyThreads.build(raw, roots: roots, me: me), at: now)
        let present = Set(raw.map(\.id))
        file.myRoots = roots.filter { present.contains($0) }.sorted()
        file.resolvedOnBitbucket = raw.filter(\.resolved).map(\.id).sorted()
        save(file, folder: folder)
        return file
    }
}

/// The read of the author's replies: a first pass on Haiku, then a second on Opus for every thread the first
/// called a disagreement; only the Opus read of those is kept. `pass` runs one headless pass (injected in checks).
enum ReplyReading {
    struct Result {
        var analyses: [ReplyAnalysis] = []
        var cost: Double = 0
        /// Disagreements read again on Opus.
        var reread = 0
        /// Comment ids the model answered for that are not threads of the file (kept out, counted).
        var skipped = 0
        var failure: String?
        var cancelled = false
    }

    typealias Pass = (_ input: Data, _ model: String) async -> PRReviewRunner.Outcome

    static func read(threads: [ReplyThread], head: String, pass: Pass) async -> Result {
        var result = Result()
        func run(_ list: [ReplyThread], model: String) async -> [ReplyAnalysis]? {
            switch await pass(ReplyRead.inputJSON(head: head, threads: list), model) {
            case .finished(let out):
                result.cost += out.costUSD ?? 0
                let parsed = ReplyBlocks.parse(out.text)
                result.skipped += parsed.skipped
                var items = parsed.analyses.filter { a in list.contains { $0.id == a.commentID } }
                for index in items.indices { items[index].model = model }
                return items
            case .failed(let why): result.failure = why
            case .cancelled: result.cancelled = true
            case .timedOut: result.failure = "timed out"
            }
            return nil
        }
        guard let first = await run(threads, model: ReviewModels.replies) else { return result }
        let disagreements = first.filter(\.isDisagreement)
        var kept = first.filter { !$0.isDisagreement }
        if !disagreements.isEmpty {
            let again = threads.filter { t in disagreements.contains { $0.commentID == t.id } }
            if let second = await run(again, model: ReviewModels.reread) {
                kept += second
                result.reread = again.count
            } else if result.failure == nil && !result.cancelled { result.failure = "re-read failed" }
            // A disagreement the second read did not give stays unread: it is never shown on the first read alone.
        }
        result.analyses = kept
        return result
    }
}
