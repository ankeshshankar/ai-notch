import XCTest
@testable import ReviewCore

final class ReviewProgressTests: XCTestCase {
    private func folder(_ stage: ReviewProgressFixture.Stage?) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("progress-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        if let stage { ReviewProgressFixture.writeFull(stage, to: url) }
        return url
    }

    private func states(_ p: ReviewProgress) -> [ReviewStepState] { p.steps.map(\.state) }

    func testAnEmptyFolderIsAtTheFirstStep() {
        let url = folder(nil); defer { try? FileManager.default.removeItem(at: url) }
        let p = ReviewProgress.read(folder: url, kind: .full)
        XCTAssertEqual(states(p), [.current, .pending, .pending, .pending, .pending])
        XCTAssertTrue(p.reviewers.isEmpty)
        XCTAssertNil(p.shortCount)
    }

    func testGatherFactsAndListing() {
        let url = folder(.gather); defer { try? FileManager.default.removeItem(at: url) }
        var p = ReviewProgress.read(folder: url, kind: .full)
        XCTAssertEqual(states(p), [.done, .current, .pending, .pending, .pending])
        XCTAssertEqual(p.steps[0].fact, "Pipeline green · 3 open comments from others", "a comment that does not ask for a change is not counted")
        ReviewProgressFixture.writeFull(.listed, to: url)
        p = ReviewProgress.read(folder: url, kind: .full)
        XCTAssertEqual(states(p), [.done, .done, .current, .pending, .pending])
        XCTAssertEqual(p.steps[1].fact, "24 files, 3 chunks, risk: payments, auth")
        XCTAssertEqual(p.reviewersTotal, 9, "distinct area and chunk pairs")
        XCTAssertEqual(p.reviewersDone, 0)
        XCTAssertEqual(p.filesTotal, 24)
    }

    func testReviewersHalfDone() {
        let url = folder(.halfDone); defer { try? FileManager.default.removeItem(at: url) }
        let p = ReviewProgress.read(folder: url, kind: .full, activity: ReviewActivity(tool: "Read", agentsRunning: 3))
        XCTAssertEqual(states(p), [.done, .done, .current, .pending, .pending])
        XCTAssertEqual(p.reviewersDone, 4)
        XCTAssertEqual(p.reviewers.map(\.state), [.done, .done, .done, .done, .running, .running, .running, .waiting, .waiting], "running as many as the hook reports")
        XCTAssertEqual(p.reviewers[0].title, "Security 1 of 3")
        XCTAssertEqual(p.reviewers[0].filesReported, 8)
        XCTAssertEqual(p.reviewers[0].findings, ReportedFindings(blocking: 1, nits: 1))
        XCTAssertEqual(p.reviewers[3].findings?.text, "none")
        XCTAssertEqual(p.reviewers[2].findings?.text, "1 should-fix")
        XCTAssertEqual(p.liveFindings.blocking, 1)
        XCTAssertEqual(p.filesReported, 16, "chunks 1 and 2 are reported, each file once however many reviewers listed it")
        XCTAssertFalse(p.checked)
        XCTAssertEqual(p.shortCount, "4/9")
        XCTAssertEqual(p.suffix(elapsed: 260), "4m · 4/9")
    }

    func testWithoutHookEveryUnfinishedReviewerIsRunning() {
        let url = folder(.halfDone); defer { try? FileManager.default.removeItem(at: url) }
        let p = ReviewProgress.read(folder: url, kind: .full)
        XCTAssertEqual(p.reviewers.filter { $0.state == .running }.count, 5)
        XCTAssertEqual(p.reviewers.filter { $0.state == .waiting }.count, 0)
    }

    func testFinalCheckThenResult() {
        let url = folder(.finalCheck); defer { try? FileManager.default.removeItem(at: url) }
        var p = ReviewProgress.read(folder: url, kind: .full)
        XCTAssertEqual(states(p), [.done, .done, .done, .current, .pending])
        XCTAssertEqual(p.current?.title, "Final check")
        XCTAssertFalse(p.checked, "findings stay unchecked until comments.json is written")
        XCTAssertEqual(p.suffix(elapsed: 600), "10m · Final check")
        ReviewProgressFixture.writeFull(.finished, to: url)
        p = ReviewProgress.read(folder: url, kind: .full)
        XCTAssertEqual(states(p), [.done, .done, .done, .done, .current])
        XCTAssertTrue(p.checked)
        XCTAssertEqual(p.steps[3].fact, "1 comment, Not Ready")
    }

    func testAMissingLensFileKeepsTheStepOpen() {
        let url = folder(.finalCheck); defer { try? FileManager.default.removeItem(at: url) }
        try? FileManager.default.removeItem(at: url.appendingPathComponent("lens-data-1.md"))
        try? FileManager.default.removeItem(at: url.appendingPathComponent("review.md"))
        let p = ReviewProgress.read(folder: url, kind: .full)
        XCTAssertEqual(p.reviewersDone, 8)
        XCTAssertEqual(p.current?.id, "reviewers")
    }

    func testAUnitReviewHasNoChunkWords() {
        let url = folder(nil); defer { try? FileManager.default.removeItem(at: url) }
        try? #"{"files":[{"path":"a.ts","chunk":1,"tags":[],"reviewers":["security"]}]}"#.write(to: url.appendingPathComponent("ledger.json"), atomically: true, encoding: .utf8)
        let p = ReviewProgress.read(folder: url, kind: .full)
        XCTAssertEqual(p.reviewers.first?.title, "Security")
        XCTAssertEqual(p.steps[1].fact, "1 file")
    }

    func testFollowUpAndRepliesHaveTheirOwnSteps() {
        let url = folder(nil); defer { try? FileManager.default.removeItem(at: url) }
        var p = ReviewProgress.read(folder: url, kind: .followUp)
        XCTAssertEqual(p.steps.map(\.title), ["Reading the new commits", "Checking the earlier findings", "Result"])
        XCTAssertEqual(states(p), [.current, .pending, .pending])
        ReviewProgressFixture.writeFollowUp(started: true, to: url)
        p = ReviewProgress.read(folder: url, kind: .followUp)
        XCTAssertEqual(states(p), [.done, .current, .pending])
        ReviewProgressFixture.writeFollowUp(started: true, finished: true, to: url)
        XCTAssertEqual(states(ReviewProgress.read(folder: url, kind: .followUp)), [.done, .done, .current])
        try? #"{"threads":[{},{}]}"#.write(to: url.appendingPathComponent("reply-input.json"), atomically: true, encoding: .utf8)
        p = ReviewProgress.read(folder: url, kind: .replies)
        XCTAssertEqual(p.steps.map(\.title), ["Reading the replies", "Result"])
        XCTAssertEqual(p.current?.id, "replies")
        XCTAssertEqual(p.steps.first?.fact, nil, "a fact shows only once the step is done")
    }

    func testActivityFromSessionState() {
        let mine = ReviewProgressFixture.sessionJSON(title: "PR review #7 · web", startedAt: 1000, updatedAt: 1100, tool: "Grep", agentsRunning: 2)
        let other = ReviewProgressFixture.sessionJSON(title: "PR review #8 · web", startedAt: 1000, updatedAt: 1200, tool: "Read", agentsRunning: 0)
        let old = ReviewProgressFixture.sessionJSON(title: "PR review #7 · web", startedAt: 100, updatedAt: 1300, tool: "Read", agentsRunning: 0)
        let found = ReviewActivity.parse([mine, other, old, Data("junk".utf8)], title: "PR review #7 · web", since: 990)
        XCTAssertEqual(found?.tool, "Grep")
        XCTAssertEqual(found?.agentsRunning, 2)
        XCTAssertNil(ReviewActivity.parse([other], title: "PR review #7 · web", since: 990), "another review's session is not used")
        XCTAssertEqual(ReviewActivity.words("Grep"), "Searching the code")
        let p = ReviewProgress.read(folder: folder(.halfDone), kind: .full, activity: found)
        XCTAssertEqual(p.nowLine(elapsed: 252), "Searching the code · 2 reviewers at work · 4m 12s")
        XCTAssertEqual(ReviewProgress.read(folder: folder(.gather), kind: .full).nowLine(elapsed: 30), "Listing files · 30s", "no hook yet: the step's own words")
    }

    func testShortTimes() {
        XCTAssertEqual(ReviewProgress.short(45), "45s")
        XCTAssertEqual(ReviewProgress.short(300), "5m")
        XCTAssertEqual(ReviewProgress.short(3900), "1h 5m")
    }
}
