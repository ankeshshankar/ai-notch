import XCTest
@testable import ReviewCore

final class ReviewSidebarTests: XCTestCase {
    private func fields(_ number: Int? = 214, title: String = "Let users remove their profile photo", author: String = "Jane Doe",
                        source: String = "feature/WEB-142-remove-photo", repo: String = "web-app") -> SidebarFields {
        SidebarFields(number: number, title: title, author: author, source: source, repo: repo)
    }

    // MARK: Search

    func testNumberWithAndWithoutHash() {
        XCTAssertTrue(SidebarSearch.matches("214", fields()))
        XCTAssertTrue(SidebarSearch.matches("#214", fields()))
        XCTAssertTrue(SidebarSearch.matches("#21", fields()))
        XCTAssertFalse(SidebarSearch.matches("#14", fields()))
        XCTAssertFalse(SidebarSearch.matches("#215", fields()))
        XCTAssertTrue(SidebarSearch.matches("web-app#214", fields()))
        XCTAssertFalse(SidebarSearch.matches("api-service#214", fields()))
    }

    func testTitleAuthorBranchRepoAreCaseInsensitive() {
        XCTAssertTrue(SidebarSearch.matches("PROFILE PHOTO", fields()))
        XCTAssertTrue(SidebarSearch.matches("jane", fields()))
        XCTAssertTrue(SidebarSearch.matches("remove-photo", fields()))
        XCTAssertTrue(SidebarSearch.matches("WEB-APP", fields()))
        XCTAssertFalse(SidebarSearch.matches("invoice", fields()))
        XCTAssertFalse(SidebarSearch.matches("jane invoice", fields()))
        XCTAssertTrue(SidebarSearch.matches("", fields()))
        XCTAssertTrue(SidebarSearch.matches("  ", fields()))
        XCTAssertTrue(SidebarSearch.matches("jose", fields(author: "José Roe")))
    }

    func testTicketIDInBranchOrTitle() {
        XCTAssertEqual(SidebarSearch.ticketIDs(in: "feature/WEB-142-remove-photo"), ["WEB-142"])
        XCTAssertEqual(SidebarSearch.ticketIDs(in: "[API-7] Fix retry (and WEB-9)"), ["API-7", "WEB-9"])
        XCTAssertEqual(SidebarSearch.ticketIDs(in: "no ticket here, only text and v2"), [])
        XCTAssertTrue(SidebarSearch.matches("web-142", fields()))
        XCTAssertTrue(SidebarSearch.matches("WEB142", fields()))
        XCTAssertFalse(SidebarSearch.matches("web-143", fields()))
        XCTAssertTrue(SidebarSearch.matches("api-7", fields(title: "[API-7] Fix retry", source: "fix/retry")))
    }

    func testBranchReviewHasNoNumber() {
        let branch = fields(-1, title: "Branch feature/x", source: "feature/x")
        XCTAssertFalse(SidebarSearch.matches("#1", branch))
        XCTAssertTrue(SidebarSearch.matches("feature/x", branch))
    }

    // MARK: Groups

    func testGroupForEachStage() {
        let findings = ReviewFindings()
        XCTAssertEqual(SidebarGroup.of(stage: .ready(verdict: .approve, findings: findings, followUp: false, commits: nil), unseenReplies: 0), .needsYou)
        XCTAssertEqual(SidebarGroup.of(stage: .asked, unseenReplies: 0), .needsYou)
        XCTAssertEqual(SidebarGroup.of(stage: .newCommits(commits: 2), unseenReplies: 0), .needsYou)
        XCTAssertEqual(SidebarGroup.of(stage: .reviewing(followUp: false, since: nil), unseenReplies: 0), .reviewingNow)
        XCTAssertEqual(SidebarGroup.of(stage: .reviewing(followUp: true, since: 5), unseenReplies: 3), .reviewingNow)
        XCTAssertEqual(SidebarGroup.of(stage: .waitingAuthor, unseenReplies: 0), .waitingOnAuthor)
        XCTAssertEqual(SidebarGroup.of(stage: .posted, unseenReplies: 0), .waitingOnAuthor)
        XCTAssertEqual(SidebarGroup.of(stage: .draft, unseenReplies: 0), .waitingOnAuthor)
        XCTAssertEqual(SidebarGroup.of(stage: .approvedByMe, unseenReplies: 0), .approvedByYou)
    }

    func testReplyWaitingMovesFinishedOnesToNeedsYou() {
        XCTAssertEqual(SidebarGroup.of(stage: .waitingAuthor, unseenReplies: 1), .needsYou)
        XCTAssertEqual(SidebarGroup.of(stage: .approvedByMe, unseenReplies: 2), .needsYou)
    }

    func testNoStageFallsBackToNeedsYou() {
        XCTAssertEqual(SidebarGroup.of(stage: nil, unseenReplies: 0), .needsYou)
    }

    func testFinishedGroupsStartCollapsed() {
        XCTAssertEqual(SidebarGroup.allCases.filter(\.startsCollapsed), [.waitingOnAuthor, .approvedByYou])
    }

    func testStageFromTheLedgerReachesTheGroup() {
        var ledger = ReviewLedger()
        var record = ReviewRecord(key: "acme/web-app#1", head: "a1b2c3d4e5f6", phase: .reviewing, auto: true, queuedAt: 1)
        ledger.set(record)
        let running = PRStage.of(key: "acme/web-app#1", head: "a1b2c3d4e5f6", decision: .none, isDraft: false, ledger: ledger)
        XCTAssertEqual(SidebarGroup.of(stage: running, unseenReplies: 0), .reviewingNow)
        record.phase = .done
        record.verdict = .approve
        ledger.set(record)
        let approved = PRStage.of(key: "acme/web-app#1", head: "a1b2c3d4e5f6", decision: .approved, isDraft: false, ledger: ledger)
        XCTAssertEqual(SidebarGroup.of(stage: approved, unseenReplies: 0), .approvedByYou)
        let none = PRStage.of(key: "acme/web-app#9", head: "ffffffffffff", decision: .none, isDraft: false, ledger: ledger)
        XCTAssertEqual(SidebarGroup.of(stage: none, unseenReplies: 0), .needsYou)
    }

    // MARK: Pins and Recent

    func testPinOrderAddRemoveAndToggle() {
        var m = SidebarMemory()
        m.pin("a"); m.pin("b"); m.pin("a")
        XCTAssertEqual(m.pins, ["a", "b"])
        m.unpin("a")
        XCTAssertEqual(m.pins, ["b"])
        m.togglePin("c"); m.togglePin("b")
        XCTAssertEqual(m.pins, ["c"])
    }

    func testPinsDropWhenThePullRequestLeavesTheLists() {
        var m = SidebarMemory()
        m.pin("a"); m.pin("b"); m.noteOpened("a"); m.noteOpened("b")
        XCTAssertTrue(m.prune(keeping: ["b"]))
        XCTAssertEqual(m.pins, ["b"])
        XCTAssertEqual(m.recent, ["b"])
        XCTAssertFalse(m.prune(keeping: ["b"]))
    }

    func testRecentIsNewestFirstDeduplicatedAndCappedAtFive() {
        var m = SidebarMemory()
        for key in ["1", "2", "3", "4", "5", "6", "7"] { m.noteOpened(key) }
        XCTAssertEqual(m.recent, ["7", "6", "5", "4", "3"])
        m.noteOpened("5")
        XCTAssertEqual(m.recent, ["5", "7", "6", "4", "3"])
    }

    func testPersistenceRoundTrip() {
        let defaults = UserDefaults(suiteName: "notch-sidebar-test-\(UUID().uuidString)")!
        XCTAssertEqual(SidebarMemory.load(from: defaults), SidebarMemory())
        var m = SidebarMemory()
        m.pin("b"); m.pin("a"); m.noteOpened("x"); m.noteOpened("y")
        m.setCollapsed("waitingOnAuthor", false); m.setCollapsed("mine", true)
        m.save(to: defaults)
        XCTAssertEqual(SidebarMemory.load(from: defaults), m)
        XCTAssertEqual(SidebarMemory.load(from: defaults).pins, ["b", "a"])
        defaults.set(Data("not json".utf8), forKey: SidebarMemory.defaultsKey)
        XCTAssertEqual(SidebarMemory.load(from: defaults), SidebarMemory())
    }

    // MARK: Sections

    private func item(_ n: Int, _ group: SidebarGroup, title: String? = nil) -> SidebarItem {
        SidebarItem(key: "acme/web-app#\(n)", group: group, fields: SidebarFields(number: n, title: title ?? "Change \(n)", author: "Jane Doe", source: "feature/x\(n)", repo: "web-app"))
    }

    func testEmptyGroupsAreNotShownAndFinishedOnesStartFolded() {
        let layout = SidebarBuilder.build(toReview: [item(1, .needsYou), item(2, .waitingOnAuthor)], mine: [], memory: SidebarMemory(), query: "")
        XCTAssertEqual(layout.sections.map(\.id), ["needsYou", "waitingOnAuthor"])
        XCTAssertEqual(layout.sections[0].keys, ["acme/web-app#1"])
        XCTAssertTrue(layout.sections[1].collapsed)
        XCTAssertEqual(layout.sections[1].keys, [])
        XCTAssertEqual(layout.sections[1].total, 1)
        XCTAssertEqual(layout.navigable, ["acme/web-app#1"])
    }

    func testOrderInsideAGroupIsKeptAndRememberedFoldingWins() {
        var m = SidebarMemory()
        m.setCollapsed("waitingOnAuthor", false)
        m.setCollapsed("needsYou", true)
        let layout = SidebarBuilder.build(toReview: [item(3, .waitingOnAuthor), item(1, .waitingOnAuthor), item(2, .needsYou)], mine: [item(9, .needsYou)], memory: m, query: "")
        XCTAssertEqual(layout.sections.first { $0.id == "waitingOnAuthor" }?.keys, ["acme/web-app#3", "acme/web-app#1"])
        XCTAssertTrue(layout.sections.first { $0.id == "needsYou" }!.collapsed)
        XCTAssertEqual(layout.foldedSection(containing: "acme/web-app#2"), "needsYou")
        XCTAssertNil(layout.foldedSection(containing: "acme/web-app#3"))
        XCTAssertEqual(layout.sections.last?.id, "mine")
    }

    func testPinnedShowOnceAndStillCountInTheirGroup() {
        var m = SidebarMemory()
        m.pin("acme/web-app#2"); m.pin("acme/web-app#1")
        m.noteOpened("acme/web-app#1"); m.noteOpened("acme/web-app#3")
        let layout = SidebarBuilder.build(toReview: [item(1, .needsYou), item(2, .needsYou), item(3, .needsYou)], mine: [], memory: m, query: "")
        XCTAssertEqual(layout.sections.map(\.id), ["pinned", "recent", "needsYou"])
        XCTAssertEqual(layout.sections[0].keys, ["acme/web-app#2", "acme/web-app#1"])
        XCTAssertEqual(layout.sections[1].keys, ["acme/web-app#3"])
        let group = layout.sections[2]
        XCTAssertEqual(group.total, 3)
        XCTAssertEqual(group.pinnedAbove, 2)
        XCTAssertEqual(group.keys, ["acme/web-app#3"])
        XCTAssertEqual(layout.navigable, ["acme/web-app#2", "acme/web-app#1", "acme/web-app#3"])
    }

    func testSearchIsOneFlatListOverBothSections() {
        let layout = SidebarBuilder.build(toReview: [item(1, .needsYou, title: "Fix invoice"), item(2, .approvedByYou, title: "Invoice export")], mine: [item(3, .needsYou, title: "Invoice totals"), item(4, .needsYou)],
                                          memory: SidebarMemory(), query: "invoice")
        XCTAssertTrue(layout.searching)
        XCTAssertEqual(layout.sections.count, 1)
        XCTAssertEqual(layout.sections[0].keys, ["acme/web-app#1", "acme/web-app#2", "acme/web-app#3"])
        XCTAssertEqual(layout.matches, 3)
        XCTAssertEqual(layout.searched, 4)
    }

    func testSearchWithNoMatchHasNoSections() {
        let layout = SidebarBuilder.build(toReview: [item(1, .needsYou)], mine: [], memory: SidebarMemory(), query: "zzz")
        XCTAssertEqual(layout.matches, 0)
        XCTAssertTrue(layout.sections.isEmpty)
        XCTAssertTrue(layout.navigable.isEmpty)
    }

    func testArrowMoveStopsAtEnds() {
        let keys = ["a", "b", "c"]
        XCTAssertEqual(SidebarBuilder.move(from: nil, in: keys, by: 1), "a")
        XCTAssertEqual(SidebarBuilder.move(from: nil, in: keys, by: -1), "c")
        XCTAssertEqual(SidebarBuilder.move(from: "b", in: keys, by: 1), "c")
        XCTAssertEqual(SidebarBuilder.move(from: "c", in: keys, by: 1), "c")
        XCTAssertEqual(SidebarBuilder.move(from: "x", in: keys, by: 1), "a")
        XCTAssertNil(SidebarBuilder.move(from: "a", in: [], by: 1))
    }
}
