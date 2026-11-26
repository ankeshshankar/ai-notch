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
        save(file, folder: folder)
        return file
    }
}
