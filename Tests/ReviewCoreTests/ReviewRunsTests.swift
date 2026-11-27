import XCTest
@testable import ReviewCore

final class ReviewRunsTests: XCTestCase {
    private func temp() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("runs-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, _ name: String, in folder: URL) { try? text.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8) }
    private func read(_ name: String, in folder: URL) -> String? { try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8) }

    func testEachRunIsKeptAndTheTopLevelHoldsTheLatest() {
        let folder = temp(); defer { try? FileManager.default.removeItem(at: folder) }
        write("{\"result\":\"one\"}", "out.json", in: folder); write("review one", "review.md", in: folder); write("{}", "chat.json", in: folder)
        XCTAssertEqual(ReviewRuns.finish(folder), 1)
        // A second run on the same head: the first stays, the top level is cleared, then written again.
        ReviewRuns.begin(folder)
        XCTAssertNil(read("review.md", in: folder), "the old report is not read as the new run's")
        XCTAssertEqual(read("chat.json", in: folder), "{}", "the chat file stays")
        write("{\"result\":\"two\"}", "out.json", in: folder); write("review two", "review.md", in: folder)
        XCTAssertEqual(ReviewRuns.finish(folder), 2)
        XCTAssertEqual(ReviewRuns.numbers(folder), [1, 2])
        XCTAssertEqual(read("review.md", in: folder.appendingPathComponent("runs/1")), "review one")
        XCTAssertEqual(read("review.md", in: folder.appendingPathComponent("runs/2")), "review two")
        XCTAssertEqual(read("review.md", in: folder), "review two")
    }

    func testAFolderFromBeforeRunsIsSavedWhenTheNextRunStarts() {
        let folder = temp(); defer { try? FileManager.default.removeItem(at: folder) }
        write("{\"result\":\"old\"}", "out.json", in: folder); write("old report", "report.md", in: folder)
        ReviewRuns.begin(folder)
        XCTAssertEqual(ReviewRuns.numbers(folder), [1])
        XCTAssertEqual(read("report.md", in: folder.appendingPathComponent("runs/1")), "old report")
        // Begin on a folder already saved does not save it twice.
        write("{\"result\":\"old\"}", "out.json", in: folder)
        ReviewRuns.begin(folder)
        XCTAssertEqual(ReviewRuns.numbers(folder), [1])
    }

    private func card(_ id: String, _ finding: String?, _ path: String?, _ line: Int?, _ severity: CommentSeverity = .shouldFix, body: String = "text") -> SuggestedComment {
        var c = SuggestedComment(id: id, severity: severity, path: path, line: line, body: body)
        c.finding = finding
        return c
    }

    func testRebuildKeepsPostedEditedAndSwitchedCards() {
        var posted = card("c1", "F1", "a.ts", 3, .blocking, body: "posted text"); posted.postedID = 900; posted.taskID = 5
        var edited = card("c2", "F2", "b.ts", 4, body: "my words"); edited.bodyEdited = true
        var off = card("c3", "F3", "c.ts", 5); off.include = false; off.includeTouched = true
        var moved = card("c4", nil, "d.ts", 9, body: "old finding without id")  // matched by path and line
        moved.includeTouched = true; moved.include = false
        var gone = card("c5", "F9", "z.ts", 1); gone.postedID = 901  // posted, no longer in the new run
        let stale = card("c6", "F8", "y.ts", 2)  // unposted, not in the new run: dropped
        let fresh = [card("k1", "F1", "a.ts", 3, .blocking, body: "new wording"), card("k2", "F2", "b.ts", 4, body: "newer"), card("k3", "F3", "c.ts", 5),
                     card("k4", "F4", "d.ts", 9, body: "same place"), card("k5", "F5", "e.ts", 7, .nit)]
        let rebuilt = CardRebuild.merge(old: [posted, edited, off, moved, gone, stale], new: fresh)
        XCTAssertEqual(rebuilt.map(\.finding), ["F1", "F2", "F3", "F4", "F5", "F9"])
        XCTAssertEqual(rebuilt[0].postedID, 900); XCTAssertEqual(rebuilt[0].body, "posted text"); XCTAssertEqual(rebuilt[0].taskID, 5); XCTAssertEqual(rebuilt[0].id, "c1")
        XCTAssertEqual(rebuilt[1].body, "my words")
        XCTAssertFalse(rebuilt[2].include, "a card switched off stays off")
        XCTAssertFalse(rebuilt[3].include, "matched by path and line, switched off by hand")
        XCTAssertEqual(rebuilt[3].finding, "F4", "the finding id comes from the new run")
        XCTAssertEqual(rebuilt[4].badge, "new")
        XCTAssertEqual(rebuilt[5].postedID, 901); XCTAssertEqual(rebuilt[5].badge, "not in latest run")
        XCTAssertFalse(rebuilt.contains { $0.id == "c6" })
    }

    func testNotCheckedCardIsOffAndOldCardsStillOpen() {
        let report = "## F1 blocking a.ts:3\nGATE: READY\nVERDICT: APPROVE"
        let cards = [card("c1", "F1", "a.ts", 3, .blocking), card("c2", "F7", "b.ts", 4, .blocking), card("c3", nil, "c.ts", 1)]
        let marked = CardCheck.mark(cards, report: report)
        XCTAssertNil(marked[0].unchecked); XCTAssertTrue(marked[0].include)
        XCTAssertEqual(marked[1].unchecked, true); XCTAssertFalse(marked[1].include)
        XCTAssertNil(marked[2].unchecked, "a card with no finding id (an older folder) is left alone")
        XCTAssertEqual(CardCheck.mark(cards, report: nil), cards, "no report, nothing to check against")
        var log = ChatLog()
        log.seed(CommentParse.file(Data(#"[{"id":"c1","finding":"F7","severity":"blocking","path":"a.ts","line":1,"body":"x"}]"#.utf8)), report: report)
        XCTAssertEqual(log.cards.first?.unchecked, true)
        XCTAssertEqual(CommentParse.file(Data(#"[{"id":"c1","severity":"nit","body":"x"}]"#.utf8)).first?.finding, nil)
    }
}
