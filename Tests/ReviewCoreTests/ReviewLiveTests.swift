import XCTest
@testable import ReviewCore

final class ReviewLiveTests: XCTestCase {
    private var dirs: [URL] = []
    override func tearDown() { dirs.forEach { try? FileManager.default.removeItem(at: $0) }; dirs = [] }

    private func tmp() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("live-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        dirs.append(url)
        return url
    }

    /// Writes a scenario and reads it back through the tracker, at the moment it was written for.
    private func run(_ s: ReviewLiveFixture.Scenario, now: Double = 1_800_000_000) -> (ReviewProgress, ReviewLive) {
        let folder = tmp().appendingPathComponent("review"), dir = tmp()
        let transcript = ReviewLiveFixture.write(s, folder: folder, transcriptDir: dir, now: now)
        let live = ReviewLiveTracker().update(transcript: transcript, now: now)
        return (ReviewProgress.read(folder: folder, kind: .full, activity: nil, live: live, now: now), live)
    }

    // MARK: mapping

    func testReportNamesParse() {
        XCTAssertEqual(LensReportName.parse("lens-security-3.md"), LensReportName(area: "security", chunk: 3))
        XCTAssertEqual(LensReportName.parse("lens-tests-12b.md"), LensReportName(area: "tests", chunk: 12, pass: 2))
        XCTAssertEqual(LensReportName.parse("lens-data-1c.md")?.pass, 3)
        XCTAssertNil(LensReportName.parse("review.md"))
        XCTAssertNil(LensReportName.parse("lens-data-x.md"))
        XCTAssertEqual(LensReportName(area: "compat", chunk: 2, pass: 2).file, "lens-compat-2b.md")
    }

    func testASubagentIsMappedByTheReportInItsPrompt() {
        let first = Data(#"{"type":"user","message":{"content":"Check it.\nREPORT: /Users/x y/reviews/a-1/lens-conventions-4b.md when done"}}"#.utf8)
        XCTAssertEqual(LensReportName.fromPrompt(first), LensReportName(area: "conventions", chunk: 4, pass: 2), "a path with a space still gives the file name")
        XCTAssertNil(LensReportName.fromPrompt(Data(#"{"type":"user","message":{"content":"Write review.md"}}"#.utf8)), "the final check has no lens report")
    }

    func testEveryReviewerOfAScenarioIsMapped() {
        let (_, live) = run(ReviewLiveFixture.large(working: 5, done: 6))
        XCTAssertEqual(live.agents.count, 11, "waiting reviewers have no session yet")
        XCTAssertTrue(live.agents.keys.contains(LivePassKey(area: "correctness", chunk: 1, pass: 1)))
    }

    // MARK: incremental reading

    func testATailReadsOnlyWholeLinesAndWhatWasAppended() throws {
        let url = tmp().appendingPathComponent("t.jsonl")
        try Data("one\ntwo\npart".utf8).write(to: url)
        var tail = JSONLTail()
        XCTAssertEqual(tail.readNew(url).map { String(decoding: $0, as: UTF8.self) }, ["one", "two"])
        XCTAssertEqual(tail.readNew(url), [], "nothing new")
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("ial\nlast\n".utf8)); try handle.close()
        XCTAssertEqual(tail.readNew(url).map { String(decoding: $0, as: UTF8.self) }, ["partial", "last"], "the held-back line is completed")
    }

    func testATailStartsOverWhenTheFileShrinks() throws {
        let url = tmp().appendingPathComponent("t.jsonl")
        try Data("aaaa\nbbbb\n".utf8).write(to: url)
        var tail = JSONLTail()
        _ = tail.readNew(url)
        try Data("c\n".utf8).write(to: url)
        XCTAssertEqual(tail.readNew(url).map { String(decoding: $0, as: UTF8.self) }, ["c"])
    }

    func testAMissingFileGivesNothing() {
        var tail = JSONLTail()
        XCTAssertEqual(tail.readNew(tmp().appendingPathComponent("none.jsonl")), [])
        XCTAssertFalse(ReviewLiveTracker().update(transcript: tmp().appendingPathComponent("none.jsonl"), now: 1).found)
    }

    func testOnlyToolNamesAndPathsAreKept() {
        let (_, live) = run(ReviewLiveFixture.small([.working(reads: 3), .waiting, .waiting, .waiting, .waiting, .waiting]))
        let agent = live.agents[LivePassKey(area: "correctness", chunk: 1, pass: 1)]
        XCTAssertEqual(agent?.reads.count, 3)
        XCTAssertEqual(agent?.doing?.hasPrefix("reading ") ?? false, true)
        XCTAssertFalse(String(describing: live).contains("Review your files"), "no prompt text is kept")
    }

    // MARK: file map

    func testFilesGoFromUnreadToReadingToReported() {
        let (p, _) = run(ReviewLiveFixture.small([.done(findings: ["SHOULD-FIX"]), .working(reads: 4), .waiting, .waiting, .waiting, .waiting]))
        XCTAssertEqual(p.fileMap.count, 6)
        let byPath = Dictionary(uniqueKeysWithValues: p.fileMap.map { ($0.path, $0) })
        // correctness reported all six; security has opened the first four of them.
        XCTAssertTrue(p.fileMap.allSatisfy { $0.state == .reported })
        XCTAssertEqual(byPath["src/module-1/unit-1.ts"]?.severity, .shouldFix)
        XCTAssertTrue(byPath["src/module-1/unit-1.ts"]?.tooltip.contains("Checked by Correctness") ?? false)
        XCTAssertTrue(byPath["src/module-1/unit-1.ts"]?.tooltip.contains("Also opened by Security") ?? false)
        let (q, _) = run(ReviewLiveFixture.small([.working(reads: 2), .waiting, .waiting, .waiting, .waiting, .waiting]))
        XCTAssertEqual(q.fileMap.filter { $0.state == .reading }.count, 2)
        XCTAssertEqual(q.fileMap.filter { $0.state == .unread }.count, 4)
        XCTAssertTrue(q.fileMap.first { $0.state == .unread }?.tooltip.contains("Not read yet") ?? false)
    }

    func testTheWorstFindingColoursTheFile() {
        XCTAssertTrue(FindingSeverity.nit < .shouldFix && FindingSeverity.shouldFix < .blocking)
        XCTAssertEqual(FindingSeverity(tag: "PRE-EXISTING"), .preExisting)
        XCTAssertNil(FindingSeverity(tag: "MAYBE"))
    }

    func testTheMapHoldsAHundredAndSixtyEightFiles() {
        let (p, _) = run(ReviewLiveFixture.large(working: 3, done: 3))
        XCTAssertEqual(p.fileMap.count, 168)
        let grid = ReviewFileGrid.layout(width: 700, count: 168)
        XCTAssertLessThanOrEqual(grid.height, 96)
        XCTAssertGreaterThanOrEqual(grid.cell, 5)
        XCTAssertEqual(grid.index(x: 1, y: 1, count: 168), 0)
        XCTAssertNil(grid.index(x: grid.cell + 1, y: 1, count: 168), "a gap is no file")
        XCTAssertEqual(ReviewFileGrid.layout(width: 700, count: 6).cell, 18, "a small PR gets big squares")
    }

    // MARK: tiles

    func testTilesAreGroupedByAreaAndShowASecondPass() {
        var s = ReviewLiveFixture.small([.done(findings: []), .working(reads: 2), .waiting, .waiting, .waiting, .waiting])
        s.reviewers[1].secondPass = true
        let (p, _) = run(s)
        XCTAssertEqual(p.tiles.map(\.area), ["correctness", "security", "data", "tests", "compat", "conventions"])
        XCTAssertEqual(p.tiles[1].pass, 2)
        XCTAssertEqual(p.tiles[1].state, .running)
        XCTAssertEqual(p.tiles[0].state, .done)
        XCTAssertEqual(p.tiles[2].state, .waiting)
    }

    func testTheSecondPassReportSupersedesTheFirst() {
        var s = ReviewLiveFixture.small([.done(findings: ["NIT"]), .waiting, .waiting, .waiting, .waiting, .waiting])
        s.reviewers[0].secondPass = true
        let (p, _) = run(s)
        XCTAssertEqual(p.tiles[0].pass, 2)
        XCTAssertEqual(p.liveFindings.nits, 1, "the stale first report, empty here, adds nothing and is not counted twice")
    }

    func testAFailedReviewerShowsAsFailed() {
        var s = ReviewLiveFixture.small([.failed, .waiting, .waiting, .waiting, .waiting, .waiting])
        s.quietFor = 30
        let (p, _) = run(s)
        XCTAssertEqual(p.tiles[0].state, .failed, "its session ended and no report came")
        let (fresh, _) = run(ReviewLiveFixture.small([.failed, .waiting, .waiting, .waiting, .waiting, .waiting]))
        XCTAssertEqual(fresh.tiles[0].state, .running, "a moment of grace before a quiet end counts as failed")
    }

    // MARK: counters

    func testCountersAddUpTheReportedFindings() {
        let (p, _) = run(ReviewLiveFixture.small([.done(findings: ["BLOCKING", "SHOULD-FIX"]), .done(findings: ["NIT", "NIT", "PRE-EXISTING"]), .waiting, .waiting, .waiting, .waiting]))
        XCTAssertEqual(p.liveFindings, ReportedFindings(blocking: 1, shouldFix: 1, nits: 2, preExisting: 1))
    }

    // MARK: heartbeat and notices

    func testTheHeartbeatBucketsByFiveSeconds() {
        let beat = ReviewHeartbeat.make(steps: [100, 99, 94, 10, 0], now: 100)
        XCTAssertEqual(beat.counts.count, 60)
        XCTAssertEqual(beat.counts.last, 2, "100 and 99 are in the newest bucket")
        XCTAssertEqual(beat.counts[58], 1)
        XCTAssertEqual(beat.total, 5, "every step inside the five minutes is counted")
        XCTAssertEqual(ReviewHeartbeat.make(steps: [100, -400], now: 100).total, 1, "older than five minutes is left out")
        XCTAssertEqual(beat.peak, 2)
    }

    func testQuietAfterAMinute() {
        XCTAssertNil(ReviewNotice.decide(now: 159, lastStep: 100, since: nil, gateWritten: false, mainEnded: false))
        XCTAssertEqual(ReviewNotice.decide(now: 160, lastStep: 100, since: nil, gateWritten: false, mainEnded: false), .quiet(60))
        XCTAssertEqual(ReviewNotice.quiet(60).text, "No activity for 1m")
        XCTAssertEqual(ReviewNotice.quiet(130).text, "No activity for 2m")
        XCTAssertEqual(ReviewNotice.quiet(3700).text, "No activity for 1h 1m")
        XCTAssertEqual(ReviewNotice.decide(now: 300, lastStep: nil, since: 100, gateWritten: false, mainEnded: false), .quiet(200), "counted from the start when nothing has happened")
        XCTAssertNil(ReviewNotice.decide(now: 300, lastStep: nil, since: nil, gateWritten: false, mainEnded: false))
    }

    func testFinishedClosingNeedsTheGateAndAnEndedTurn() {
        XCTAssertEqual(ReviewNotice.decide(now: 500, lastStep: 499, since: 0, gateWritten: true, mainEnded: true), .closing)
        XCTAssertEqual(ReviewNotice.closing.text, "Finished, closing")
        XCTAssertNil(ReviewNotice.decide(now: 500, lastStep: 499, since: 0, gateWritten: true, mainEnded: false))
        XCTAssertNil(ReviewNotice.decide(now: 500, lastStep: 499, since: 0, gateWritten: false, mainEnded: true))
    }

    func testTheScenariosGiveTheirNotices() {
        var s = ReviewLiveFixture.named("stalled")!
        var (p, _) = run(s)
        if case .quiet(let seconds)? = p.notice(now: 1_800_000_000, since: nil) { XCTAssertTrue((130...135).contains(seconds)) } else { XCTFail("expected a quiet notice") }
        s = ReviewLiveFixture.named("closing")!
        (p, _) = run(s)
        XCTAssertEqual(p.notice(now: 1_800_000_000, since: 1_799_998_000), .closing)
        (p, _) = run(ReviewLiveFixture.named("small")!)
        XCTAssertNil(p.notice(now: 1_800_000_000, since: nil))
        XCTAssertNotNil(p.heartbeat(now: 1_800_000_000))
    }

    func testWithoutSessionFilesThereIsNoNoticeAndNoGraph() {
        let url = tmp()
        ReviewProgressFixture.writeFull(.halfDone, to: url)
        let p = ReviewProgress.read(folder: url, kind: .full)
        XCTAssertNil(p.notice(now: 1_800_000_000, since: nil), "no source, no claim that it is quiet")
        XCTAssertNil(p.heartbeat(now: 1_800_000_000))
        XCTAssertFalse(p.reviewers.isEmpty, "the folder alone still shows the reviewers")
    }

    func testTheNowLineNamesTheFile() {
        let (p, _) = run(ReviewLiveFixture.small([.working(reads: 3), .waiting, .waiting, .waiting, .waiting, .waiting]))
        XCTAssertTrue(p.tiles[0].doing?.hasPrefix("reading unit-") ?? false, "a working tile names the file it opened")
        XCTAssertEqual(p.doingNow, "Running git", "the main session's newer step wins the Now line")
    }
}
