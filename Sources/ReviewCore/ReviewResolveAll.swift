import Foundation

// "Resolve N fixed": the threads of mine that can be resolved in one go. A thread counts when it is
// still open on Bitbucket and something says it is fixed: the latest follow-up on the current head
// (a card marked Fixed) or the reply read (a thread classified fixed). Nothing else counts, and a
// thread whose two reads disagree stays out. No AppKit, no network.

public struct ResolveItem: Equatable, Sendable, Identifiable {
    public enum Source: String, Sendable { case followUp, replyRead }

    /// The Bitbucket id of the thread's first comment.
    public var id: Int
    /// Nil for a comment I wrote by hand (not one of the cards).
    public var severity: CommentSeverity?
    public var location: String?
    public var title: String
    /// Why it counts as fixed: the follow-up's reason or the reply read's reason.
    public var why: String
    public var source: Source

    public init(id: Int, severity: CommentSeverity?, location: String?, title: String, why: String, source: Source) {
        self.id = id
        self.severity = severity
        self.location = location
        self.title = title
        self.why = why
        self.source = source
    }

    /// "src/a.ts:12 · Title", for a failure line.
    public var label: String { [location, title].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ") }
}

public enum ResolveAll {
    /// My threads that are open and fixed. `followUpIsCurrent`: the cards' follow-up statuses were read for the head the
    /// pull request is on now (a follow-up of an older head says nothing about this one).
    public static func items(cards: [SuggestedComment], replies: RepliesFile, followUpIsCurrent: Bool) -> [ResolveItem] {
        let cardsResolved = Set(cards.filter { $0.resolved == true }.compactMap(\.postedID))
        let done = Set(replies.resolvedOnBitbucket ?? []).union(replies.resolved).union(cardsResolved)
        let roots = replies.myRoots.map(Set.init)
        func open(_ id: Int) -> Bool { !done.contains(id) && (roots?.contains(id) ?? true) }
        func read(_ id: Int) -> ReplyAnalysis? { replies.thread(id).flatMap { replies.analysis($0) } }

        var out: [ResolveItem] = []
        var seen = Set<Int>()
        for card in cards {
            guard let id = card.postedID, open(id), seen.insert(id).inserted else { continue }
            let analysis = read(id)
            let title = (card.title?.isEmpty == false ? card.title : nil) ?? firstLine(card.body)
            func item(_ why: String, _ source: ResolveItem.Source) -> ResolveItem {
                ResolveItem(id: id, severity: card.severity, location: card.location, title: title, why: why, source: source)
            }
            switch (followUpIsCurrent ? card.status : nil, analysis?.verdict) {
            case (.fixed?, nil), (.fixed?, .fixed?):
                out.append(item(card.statusReason?.trimmedOrNil ?? "The follow-up found it fixed.", .followUp))
            case (nil, .fixed?):
                out.append(item(replyWhy(analysis), .replyRead))
            default: break
            }
        }
        let posted = Set(cards.compactMap(\.postedID))
        for thread in replies.threads where !posted.contains(thread.id) && open(thread.id) && seen.insert(thread.id).inserted {
            guard let analysis = read(thread.id), analysis.verdict == .fixed else { continue }
            out.append(ResolveItem(id: thread.id, severity: nil, location: thread.location, title: firstLine(thread.text), why: replyWhy(analysis), source: .replyRead))
        }
        return out
    }

    private static func replyWhy(_ analysis: ReplyAnalysis?) -> String {
        "Reply read: " + (analysis?.reason.trimmedOrNil ?? "the thread is classified fixed.")
    }

    /// The first non-empty line, at most 80 characters.
    public static func firstLine(_ text: String) -> String {
        let line = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        return line.count > 80 ? String(line.prefix(79)) + "…" : line
    }

    /// What a `…/resolve` answer means: 200, 201 and 204 resolved it, 409 means it already was (both are done); anything
    /// else is a failure with its reason.
    public enum Answer: Equatable, Sendable {
        case done
        case failed(String)
    }

    public static func answer(status: Int, scopeError: Bool = false) -> Answer {
        switch status {
        case 200, 201, 204, 409: return .done
        case 401: return .failed("the write token was rejected")
        case 403: return .failed(scopeError ? "the write token lacks the pullrequest:write scope" : "only a comment thread's first comment can be resolved")
        case 404: return .failed("not found")
        default: return .failed("Bitbucket answered \(status)")
        }
    }
}

private extension String {
    var trimmedOrNil: String? {
        let text = trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
