import Foundation
import NotchCore

// Dev side of the Board, never part of a normal run:
//   --board-selfcheck           feeds sample sessions and pull requests through the sorting and
//                               asserts which group each lands in. Exit 1 on a failure.
//   --preview --board           opens the preview with the Board panel open.
//   --preview --board --board-fixtures
//                               the Board shows BoardFixtures' pull requests, linked to the
//                               sessions named alpha to epsilon (made as ci-screenshots.sh makes
//                               alpha, beta and gamma), instead of the real ones.

enum BoardFixtures {
    static var isOn: Bool { CommandLine.arguments.contains("--board-fixtures") }

    static func person(_ name: String) -> PRPerson { PRPerson(uuid: "{\(name)}", name: name) }

    /// One of my pull requests; the arguments set what the board reads.
    static func pr(_ id: Int, _ title: String, draft: Bool = false, approved: Int = 0, changes: Bool = false, build: BuildState? = .succeeded,
                   conflict: Bool = false, comments: Int = 0, checks: Bool? = nil) -> PullRequest {
        var participants = [PRParticipant(person: person("Alice"), review: approved > 0 ? .approved : changes ? .changesRequested : .none, isReviewer: true)]
        if approved > 1 { participants.append(PRParticipant(person: person("Bob"), review: .approved, isReviewer: true)) }
        var pr = PullRequest(ref: PullRequestRef(workspace: "ws", repo: "app", id: id), title: title, isDraft: draft, author: person("Me"),
                             source: "feature/\(id)", destination: "main", role: .mine, participants: participants, myReview: .none,
                             taskCount: 0, commentCount: comments, updatedOn: "2026-10-20T10:00:00.000000+00:00", updatedAt: Double(1_000_000 - id),
                             url: URL(string: "https://bitbucket.org/ws/app/pull-requests/\(id)"))
        pr.build = build.map { PRBuild(state: $0, key: "k\(id)", pipeline: nil, url: nil) }
        pr.newComments = comments
        if let checks {
            // Merge checks read: the git check passes, or fails by conflict; an approval rule passes or blocks.
            var list = [PRMergeability.Check(name: "git", status: conflict ? "FAILED" : "PASSED", required: true, blocking: conflict, type: "git_mergeability_check", reason: conflict ? "conflicts" : "")]
            list.append(PRMergeability.Check(name: "minimum_approvals", status: checks ? "PASSED" : "FAILED", required: true, blocking: !checks, type: "approvals_check"))
            pr.merge = PRMergeability(checks: list, fetchedAt: 0)
        }
        return pr
    }

    static func session(_ id: String, _ phase: Phase, title: String? = nil) -> SessionState {
        var session = SessionState(id: id, cwd: "/work/\(id)", now: 1_000_000)
        session.phase = phase
        session.sessionTitle = title
        session.firstPrompt = title
        if phase == .waiting { session.waitingFor = "permission" }
        if phase == .working { session.turnStartedAt = 999_900 }
        if phase == .idle { session.finishedAt = 999_000 }
        return session
    }

    /// The preview's data. alpha works on a PR with a failed build, beta (idle) has a PR ready,
    /// gamma waits on a prompt while its PR is ready, delta works with no PR, epsilon is idle.
    static let links: [String: PullRequest] = [
        "alpha": pr(41, "Add a settings screen with dark mode", build: .failed, checks: false),
        "beta": pr(42, "Fix the flaky login test", approved: 1, checks: true),
        "gamma": pr(43, "Deploy the docs site", approved: 1, checks: true),
    ]
    static let mine: [PullRequest] = links.values.sorted { $0.ref.id < $1.ref.id } + [
        pr(44, "Move billing to the new API", conflict: true, checks: false),
        pr(45, "Cache the price list", build: .running, checks: false),
        pr(46, "Update the onboarding copy", approved: 1, checks: true),
        pr(47, "Try out the new router", draft: true, build: nil),
    ]
}

enum BoardDev {
    static func runIfAsked(_ arguments: [String]) {
        if arguments.contains("--board-selfcheck") { exit(selfCheck()) }
    }

    static func selfCheck() -> Int32 {
        var failures = 0
        var checks = 0
        func expect(_ condition: Bool, _ what: String) {
            checks += 1
            if !condition {
                failures += 1
                print("FAIL \(what)")
            }
        }
        typealias F = BoardFixtures
        let now = 1_000_000.0

        // A pull request alone.
        expect(BoardModel.column(of: F.pr(1, "a", approved: 1, checks: true)) == .readyToMerge, "pr: approved, build passed, checks pass is ready")
        expect(BoardModel.column(of: F.pr(2, "a", build: .failed)) == .needsYou, "pr: failed build needs you")
        expect(BoardModel.column(of: F.pr(3, "a", conflict: true, checks: false)) == .needsYou, "pr: merge conflict needs you")
        expect(BoardModel.column(of: F.pr(4, "a", comments: 2)) == .needsYou, "pr: new comments need you")
        expect(BoardModel.column(of: F.pr(5, "a", changes: true)) == .needsYou, "pr: changes requested needs you")
        expect(BoardModel.column(of: F.pr(6, "a")) == .inReview, "pr: passing build, nothing else, is in review")
        expect(BoardModel.column(of: F.pr(7, "a", build: .running)) == .inReview, "pr: running build is in review")
        expect(BoardModel.column(of: F.pr(8, "a", build: nil)) == .inReview, "pr: no build yet is in review")
        expect(BoardModel.column(of: F.pr(9, "a", checks: false)) == .inReview, "pr: not approved, checks blocking, is in review")
        expect(BoardModel.column(of: F.pr(10, "a", approved: 1, build: .running, checks: true)) == .inReview, "pr: approved but build running is in review")
        expect(BoardModel.column(of: F.pr(11, "a", approved: 1)) == .inReview, "pr: approved, merge checks not read yet, is in review")
        expect(BoardModel.column(of: F.pr(12, "a", draft: true, build: .failed)) == nil, "pr: a draft has no column")
        var reviewing = F.pr(13, "a")
        reviewing.role = .reviewing
        expect(BoardModel.column(of: reviewing) == nil, "pr: one I only review is not on the board")

        // A session alone, and with a pull request.
        expect(BoardModel.column(of: F.session("a", .waiting), pr: nil) == .needsYou, "session: waiting needs you")
        expect(BoardModel.column(of: F.session("a", .working), pr: nil) == .working, "session: working")
        expect(BoardModel.column(of: F.session("a", .idle), pr: nil) == nil, "session: idle with no PR is in the idle footer")
        let ready = F.pr(20, "ready", approved: 1, checks: true)
        expect(BoardModel.column(of: F.session("a", .waiting), pr: ready) == .needsYou, "session waiting, PR ready: needs you")
        expect(BoardModel.column(of: F.session("a", .idle), pr: ready) == .readyToMerge, "session idle, PR ready: ready to merge")
        expect(BoardModel.column(of: F.session("a", .working), pr: ready) == .working, "session working, PR ready: working")
        expect(BoardModel.column(of: F.session("a", .working), pr: F.pr(21, "x", build: .failed)) == .needsYou, "session working, PR build failed: needs you")
        expect(BoardModel.column(of: F.session("a", .idle), pr: F.pr(22, "x")) == .inReview, "session idle, PR in review: in review")
        expect(BoardModel.column(of: F.session("a", .idle), pr: F.pr(23, "x", draft: true)) == nil, "session idle, PR a draft: idle footer")
        expect(BoardModel.column(of: F.session("a", .working), pr: F.pr(24, "x", draft: true, build: .failed)) == .working, "session working, PR a draft: the draft's failed build is ignored")

        // A whole board: each pull request shows once, on its session when there is one.
        let sessions = [F.session("alpha", .working), F.session("beta", .idle), F.session("gamma", .waiting), F.session("delta", .working), F.session("epsilon", .idle)]
        let board = BoardModel.build(sessions: sessions, links: F.links, mine: F.mine)
        func ids(_ column: BoardColumn) -> [String] { board.cards(column).map(\.id) }
        expect(ids(.needsYou) == ["s:gamma", "s:alpha", "p:ws/app#44"], "board: needs you is gamma (waiting, PR ready), alpha (PR failed), then the conflicted PR: \(ids(.needsYou))")
        expect(ids(.working) == ["s:delta"], "board: working is delta: \(ids(.working))")
        expect(ids(.inReview) == ["p:ws/app#45"], "board: in review is the PR with no session: \(ids(.inReview))")
        expect(ids(.readyToMerge) == ["s:beta", "p:ws/app#46"], "board: ready is beta, then the PR with no session: \(ids(.readyToMerge))")
        expect(board.idle.map(\.id) == ["epsilon"], "board: idle footer is epsilon alone: \(board.idle.map(\.id))")
        let shown = BoardColumn.allCases.flatMap { board.cards($0) }
        expect(!shown.contains { $0.pr?.id == "ws/app#47" }, "board: the draft with no session is left out")
        expect(shown.filter { $0.pr?.id == "ws/app#42" }.count == 1, "board: a linked PR shows once")
        expect(shown.count + board.idle.count == 8, "board: five sessions and three PRs without a session, drafts left out: \(shown.count + board.idle.count)")
        expect(!board.isEmpty && Board().isEmpty, "board: emptiness")

        // Two sessions on one pull request: both cards, the pull request once more nowhere.
        let twin = BoardModel.build(sessions: [F.session("a", .idle), F.session("b", .idle)], links: ["a": ready, "b": ready], mine: [ready])
        expect(twin.cards(.readyToMerge).map(\.id) == ["s:a", "s:b"], "twin: two sessions on one PR are two cards and no PR card")

        // Nothing at all.
        expect(BoardModel.build(sessions: [], links: [:], mine: []).isEmpty, "empty: nothing in, nothing out")

        // The status line.
        expect(BoardModel.detail(F.session("a", .waiting), now: now) == "Waiting for permission", "detail: waiting")
        expect(BoardModel.detail(F.session("a", .working), now: now) == "Thinking…", "detail: working with no tool")
        expect(BoardModel.detail(F.session("a", .idle), now: now) == "Done 16m40s ago", "detail: idle after a turn")

        print(failures == 0 ? "board-selfcheck: \(checks)/\(checks) ok" : "board-selfcheck: \(failures) of \(checks) failed")
        return failures == 0 ? 0 : 1
    }
}
