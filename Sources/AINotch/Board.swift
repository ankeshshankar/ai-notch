import Foundation
import NotchCore

// The Board: where every agent session and every pull request of mine stands, in four groups.
// It reads nothing of its own. It sorts what the session list, the session-to-PR links and the
// pull-request store already hold, so it adds no request to the Bitbucket budget.

/// The four groups, in the order they read: what needs you first, what can be merged last.
enum BoardColumn: Int, CaseIterable, Sendable {
    case needsYou, working, inReview, readyToMerge

    var title: String {
        switch self {
        case .needsYou: return "Needs you"
        case .working: return "Working"
        case .inReview: return "In review"
        case .readyToMerge: return "Ready to merge"
        }
    }

    /// What lands in it, for the ⓘ.
    var about: String {
        switch self {
        case .needsYou: return "Sessions waiting on a permission prompt or a question, and pull requests of yours with a failed build, a merge conflict, new comments, changes requested or a merge that cannot happen. A session on a pull request shows both on one card, under the more urgent of the two. Nothing is read for the Board: it sorts what the rows and the PRs panel already know."
        case .working: return "Sessions with a turn running."
        case .inReview: return "Your open pull requests waiting on reviewers: build passing or running, no conflict, not yet approved. Drafts with no session are left out."
        case .readyToMerge: return "Your pull requests whose merge checks all pass: approved, build passed, no conflict."
        }
    }
}

/// One card: a session (with its pull request when it has one), or a pull request no session is on.
struct BoardCard: Identifiable, Equatable, Sendable {
    var session: SessionState?
    var pr: PullRequest?

    var id: String { session.map { "s:" + $0.id } ?? "p:" + (pr?.id ?? "") }
}

struct Board: Equatable, Sendable {
    var columns: [BoardColumn: [BoardCard]] = [:]
    /// Sessions that are idle and on no pull request: a collapsed footer, not a column.
    var idle: [SessionState] = []

    func cards(_ column: BoardColumn) -> [BoardCard] { columns[column] ?? [] }
    var isEmpty: Bool { idle.isEmpty && columns.values.allSatisfy(\.isEmpty) }
}

enum BoardModel {
    /// Where one of my pull requests goes alone. Nil for a draft (not waiting on anyone, so it is
    /// left out unless a session is on it) and for one I only review.
    static func column(of pr: PullRequest) -> BoardColumn? {
        guard pr.role == .mine, !pr.isDraft else { return nil }
        if !pr.feedbackKinds.isEmpty || !pr.changesRequestedBy.isEmpty || pr.merge?.cannotMerge == true { return .needsYou }
        if pr.isReadyToMerge == true { return .readyToMerge }
        return .inReview
    }

    /// Where a session goes, given its pull request if it has one. Nil: idle with nothing to
    /// follow up, so the Idle footer. The more urgent of the two wins, except that a session
    /// still working keeps its card under Working while its pull request is only waiting or
    /// ready, since the agent may still change it.
    static func column(of session: SessionState, pr: PullRequest?) -> BoardColumn? {
        if session.phase == .waiting { return .needsYou }
        let prColumn = pr.flatMap(column(of:))
        if prColumn == .needsYou { return .needsYou }
        if session.phase == .working { return .working }
        return prColumn
    }

    /// Sorts everything. `links` is a session id's pull request; a pull request a session is on
    /// shows on that session's card, never twice.
    static func build(sessions: [SessionState], links: [String: PullRequest], mine: [PullRequest]) -> Board {
        var board = Board()
        func add(_ card: BoardCard, to column: BoardColumn) { board.columns[column, default: []].append(card) }
        for session in sessions {
            let pr = links[session.id]
            if let column = column(of: session, pr: pr) {
                add(BoardCard(session: session, pr: pr), to: column)
            } else {
                board.idle.append(session)
            }
        }
        let onSession = Set(links.values.map(\.id))
        for pr in mine where !onSession.contains(pr.id) {
            if let column = column(of: pr) { add(BoardCard(session: nil, pr: pr), to: column) }
        }
        // Inside a group, a session waiting on you comes before one that only has a pull request
        // to deal with, and sessions before pull requests; otherwise the lists' own order holds.
        for (column, cards) in board.columns {
            board.columns[column] = cards.enumerated().sorted { a, b in
                let ra = rank(a.element), rb = rank(b.element)
                return ra != rb ? ra < rb : a.offset < b.offset
            }.map(\.element)
        }
        return board
    }

    private static func rank(_ card: BoardCard) -> Int {
        guard let session = card.session else { return 2 }
        return session.phase == .waiting ? 0 : 1
    }

    /// The line under a session's name: what it is doing or waiting on.
    static func detail(_ session: SessionState, now: Double) -> String {
        switch session.phase {
        case .waiting: return "Waiting for \(session.waitingFor ?? "you")"
        case .working:
            guard let tool = session.current else { return "Thinking…" }
            return tool.server.map { "\($0) · \(tool.shortName)" } ?? tool.name
        case .idle: return session.finishedAt.map { "Done \(elapsed(now - $0)) ago" } ?? "Idle"
        }
    }
}
