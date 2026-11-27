import AppKit
import Foundation
import ReviewCore

// `--review-window-preview --long-list`: 28 pull requests to review across all four states, 2 mine, 2 pinned and a few
// opened lately, for the sidebar's grouping, search, pins and folding. Invented names only.
//   --search <text>   the search box filled in
//   --fold all|none   every group folded / every group open (the saved defaults otherwise)
//   --hover <number>  that row drawn as if the pointer were on it (shows the pin button)
//   --select <number> the open pull request (default: the first one that needs me)

extension PRReviewDev {
    /// A pull request's number the preview draws hovered.
    nonisolated(unsafe) static var hoverNumber: Int?

    private struct Row {
        var id: Int
        var repo: String
        var title: String
        var author: String
        var branch: String
        var state: State
        var build: BuildState? = .succeeded
        enum State { case notReviewed, ready, newCommits, replyWaiting, reviewing, queued, changes, posted, approved, draft }
    }

    private static let rows: [Row] = [
        // Needs you (11)
        Row(id: 301, repo: "web-app", title: "Let users remove their profile photo", author: "Jane Doe", branch: "feature/WEB-142-remove-photo", state: .ready),
        Row(id: 298, repo: "api-service", title: "[API-77] Bump the retry backoff and add jitter", author: "Sam Poe", branch: "chore/API-77-backoff", state: .notReviewed, build: nil),
        Row(id: 295, repo: "web-app", title: "Move the settings screen to the new layout", author: "Jane Doe", branch: "feature/settings-layout", state: .newCommits, build: .running),
        Row(id: 293, repo: "mobile-app", title: "Add haptic feedback to the pull to refresh", author: "Priya Rao", branch: "feature/MOB-31-haptics", state: .notReviewed),
        Row(id: 290, repo: "design-kit", title: "Tokens for the compact density", author: "Kim Lee", branch: "feature/density-tokens", state: .ready),
        Row(id: 288, repo: "api-service", title: "Return 404 instead of 500 for a missing invoice", author: "John Roe", branch: "fix/missing-invoice", state: .replyWaiting),
        Row(id: 285, repo: "web-app", title: "Fix the off-by-one in the invoice list pagination", author: "John Roe", branch: "fix/invoice-pagination", state: .ready),
        Row(id: 283, repo: "mobile-app", title: "Cache the avatar thumbnails on disk", author: "Alex Doe", branch: "feature/MOB-28-avatar-cache", state: .notReviewed, build: .failed),
        Row(id: 281, repo: "web-app", title: "Replace the date picker with the shared one", author: "Priya Rao", branch: "chore/shared-date-picker", state: .newCommits),
        Row(id: 279, repo: "api-service", title: "Add an index for the audit log lookup", author: "Sam Poe", branch: "perf/audit-index", state: .notReviewed, build: nil),
        Row(id: 276, repo: "design-kit", title: "Document the focus ring rules", author: "Kim Lee", branch: "docs/focus-ring", state: .notReviewed),
        // Reviewing now (3)
        Row(id: 274, repo: "web-app", title: "Split the checkout form into steps", author: "Alex Doe", branch: "feature/WEB-150-checkout-steps", state: .reviewing, build: .running),
        Row(id: 271, repo: "api-service", title: "Stream large exports instead of buffering", author: "John Roe", branch: "feature/API-81-stream-export", state: .reviewing),
        Row(id: 269, repo: "mobile-app", title: "Show the offline banner on every tab", author: "Jane Doe", branch: "feature/MOB-33-offline-banner", state: .queued),
        // Waiting on author (8)
        Row(id: 266, repo: "web-app", title: "Validate the phone number on the profile form", author: "Priya Rao", branch: "fix/WEB-139-phone-validation", state: .changes, build: .failed),
        Row(id: 263, repo: "api-service", title: "Rate limit the password reset endpoint", author: "Sam Poe", branch: "feature/API-70-reset-rate-limit", state: .changes),
        Row(id: 260, repo: "mobile-app", title: "Draft: rework the onboarding carousel", author: "Kim Lee", branch: "wip/onboarding", state: .draft, build: nil),
        Row(id: 258, repo: "web-app", title: "Show the error summary above the form", author: "Alex Doe", branch: "feature/error-summary", state: .posted),
        Row(id: 255, repo: "design-kit", title: "Add the segmented control", author: "Jane Doe", branch: "feature/segmented-control", state: .changes),
        Row(id: 252, repo: "api-service", title: "Move the mailer to a queue", author: "John Roe", branch: "refactor/mailer-queue", state: .posted),
        Row(id: 249, repo: "mobile-app", title: "Fix the keyboard covering the chat input", author: "Priya Rao", branch: "fix/MOB-25-keyboard", state: .changes),
        Row(id: 247, repo: "web-app", title: "Lazy load the reports charts", author: "Sam Poe", branch: "perf/lazy-charts", state: .changes),
        // Approved by you (6)
        Row(id: 244, repo: "web-app", title: "Update the footer links", author: "Kim Lee", branch: "chore/footer-links", state: .approved),
        Row(id: 241, repo: "api-service", title: "Log the request id on every error", author: "Sam Poe", branch: "chore/API-66-request-id", state: .approved),
        Row(id: 238, repo: "design-kit", title: "Fix the tooltip arrow in dark mode", author: "Jane Doe", branch: "fix/tooltip-arrow", state: .approved),
        Row(id: 235, repo: "mobile-app", title: "Bump the navigation library", author: "Alex Doe", branch: "chore/bump-navigation", state: .approved),
        Row(id: 232, repo: "web-app", title: "Remove the unused feature flags", author: "John Roe", branch: "chore/WEB-120-flags", state: .approved),
        Row(id: 229, repo: "api-service", title: "Document the pagination headers", author: "Priya Rao", branch: "docs/pagination-headers", state: .approved),
    ]

    private static let mineRows: [Row] = [
        Row(id: 310, repo: "web-app", title: "Cache the avatar thumbnails", author: "You", branch: "feature/avatar-cache", state: .notReviewed),
        Row(id: 307, repo: "api-service", title: "Add the invoice export endpoint", author: "You", branch: "feature/API-84-export", state: .notReviewed, build: .running),
    ]

    @MainActor
    static func previewLongList(_ args: [String]) {
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        let now = Date().timeIntervalSince1970
        func head(_ id: Int) -> String { String(format: "%012x", id * 7919 + 4096) }
        func oldHead(_ id: Int) -> String { String(format: "%012x", id * 104_729 + 8192) }
        func ref(_ row: Row) -> PullRequestRef { PullRequestRef(workspace: "acme", repo: row.repo, id: row.id) }

        func record(_ row: Row, phase: ReviewPhase, head: String, posted: String? = nil) -> ReviewRecord {
            var r = ReviewRecord(key: ref(row).key, head: head, phase: phase, auto: true, queuedAt: now - 1200)
            if phase == .done {
                r.verdict = posted == "approved" ? .approve : .requestChanges
                r.findings = ReviewFindings(blocking: posted == "approved" ? 0 : 1, shouldFix: 1, nits: 1)
                r.finishedAt = now - 900
                r.reportFile = "report.md"
                r.sessionID = "00000000-0000-4000-8000-000000000301"
                r.posted = posted
            }
            if phase == .reviewing { r.startedAt = now - 420 }
            return r
        }

        var ledger = ReviewLedger()
        var decisions: [String: PRReview] = [:]
        var replies: [String: Int] = [:]
        for row in rows {
            let key = ref(row).key
            switch row.state {
            case .notReviewed, .draft: break
            case .ready: ledger.set(record(row, phase: .done, head: head(row.id)))
            case .newCommits:
                ledger.set(record(row, phase: .done, head: oldHead(row.id), posted: "approved"))
                decisions[key] = .approved
            case .replyWaiting:
                ledger.set(record(row, phase: .done, head: head(row.id), posted: "changes requested"))
                decisions[key] = .changesRequested
                replies[key] = 2
            case .reviewing: ledger.set(record(row, phase: .reviewing, head: head(row.id)))
            case .queued: ledger.set(record(row, phase: .queued, head: head(row.id)))
            case .changes, .posted:
                ledger.set(record(row, phase: .done, head: head(row.id), posted: "changes requested"))
                if row.state == .changes { decisions[key] = .changesRequested }
            case .approved:
                ledger.set(record(row, phase: .done, head: head(row.id), posted: "approved"))
                decisions[key] = .approved
            }
        }
        // One review folder with a real chat, for the open pull request.
        if let first = rows.first, let r = ledger.record(ref(first).key, head: head(first.id)) {
            writeFolder(PRReviewStore.folder(ref(first), head: r.head), fixture: 214, record: r)
        }
        try? ((try? JSONEncoder().encode(ledger)) ?? Data()).write(to: PRReviewStore.ledgerURL)

        let store = PRReviewStore()
        store.injectLedgerForCheck(ledger)
        for (key, count) in replies { store.setUnseenReplies(key, count) }

        let people = ["Jane Doe", "John Roe", "Sam Poe"].map { PRPerson(uuid: "u-" + $0.prefix(4).lowercased(), name: $0) }
        func pr(_ row: Row, role: PRRole) -> PullRequest {
            let r = ref(row)
            let participants = [PRParticipant(person: people[0], review: row.id % 3 == 0 ? .approved : .none, isReviewer: true),
                                PRParticipant(person: people[1], review: .none, isReviewer: true)]
            return PullRequest(ref: r, title: row.title, isDraft: row.state == .draft, author: PRPerson(uuid: nil, name: row.author), source: row.branch, destination: "main", role: role,
                               participants: role == .reviewing ? participants : [], myReview: decisions[r.key] ?? .none, taskCount: 0, commentCount: 1, updatedOn: "", updatedAt: now - Double(row.id),
                               url: URL(string: "https://bitbucket.org/acme/\(row.repo)/pull-requests/\(row.id)"),
                               build: row.build.map { PRBuild(state: $0, key: "fixture", pipeline: nil, url: nil) }, head: head(row.id))
        }
        let list = PRListSource()
        list.prs = rows.map { pr($0, role: .reviewing) }
        list.mine = mineRows.map { pr($0, role: .mine) }

        // What the user would have done: two pins, three pull requests opened, and, for a folded view, every group folded.
        let defaults = previewDefaults()
        var memory = SidebarMemory()
        memory.pin(ref(rows[5]).key)
        memory.pin(ref(rows[13]).key)
        for id in [rows[7].id, rows[0].id, rows[19].id] { memory.noteOpened(PullRequestRef(workspace: "acme", repo: (rows + mineRows).first { $0.id == id }!.repo, id: id).key) }
        switch value("--fold") {
        case "all": for g in SidebarGroup.allCases { memory.setCollapsed(g.rawValue, true) }; memory.setCollapsed("mine", true)
        case "none": for g in SidebarGroup.allCases { memory.setCollapsed(g.rawValue, false) }
        default: break
        }
        memory.save(to: defaults)

        let model = PRReviewWindowModel(store: store, list: list, defaults: defaults)
        let wanted = value("--select").flatMap { Int($0) }
        let first = list.prs.first { $0.id == ref(rows[0]).key }
        model.selected = (list.prs + list.mine).first { $0.ref.id == wanted }?.id ?? first?.id
        if let text = value("--search") { model.query = text }
        hoverNumber = value("--hover").flatMap { Int($0) }
        presentPreview(model, args)
    }
}
