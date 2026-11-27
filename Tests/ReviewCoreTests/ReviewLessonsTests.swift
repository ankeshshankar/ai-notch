import XCTest
@testable import ReviewCore

final class ReviewLessonsTests: XCTestCase {
    func testAppendMakesTheSectionThenFillsTheKind() {
        var md = LessonsMarkdown.append("", repo: "api", kind: .noise, text: "Do not raise: naming of x.")
        XCTAssertTrue(md.hasPrefix("# Lessons"))
        XCTAssertTrue(md.contains("## api\n\n### Noise\n- Do not raise: naming of x.\n"), md)
        XCTAssertTrue(md.contains("### Missed") && md.contains("### Wrong"))
        md = LessonsMarkdown.append(md, repo: "api", kind: .noise, text: "Second noise.")
        md = LessonsMarkdown.append(md, repo: "api", kind: .wrong, text: "We were wrong once.")
        md = LessonsMarkdown.append(md, repo: "app", kind: .missed, text: "Must raise y.")
        let noise = md.range(of: "- Do not raise: naming of x.")!.lowerBound, second = md.range(of: "- Second noise.")!.lowerBound
        let missedApi = md.range(of: "### Missed")!.lowerBound
        XCTAssertTrue(noise < second && second < missedApi, "a second entry goes under the same kind")
        XCTAssertTrue(md.range(of: "- We were wrong once.")!.lowerBound > md.range(of: "### Wrong")!.lowerBound)
        XCTAssertTrue(md.contains("## app") && md.range(of: "- Must raise y.")!.lowerBound > md.range(of: "## app")!.lowerBound)
        XCTAssertEqual(md.components(separatedBy: "## api").count, 2, "one section per repo")
    }

    func testAnExistingFileKeepsEverythingElse() {
        let before = "# Lessons\n\nIntro text.\n\n## api\n\n### Noise\n- old noise\n\n## web\n\n### Wrong\n- keep me\n"
        let after = LessonsMarkdown.append(before, repo: "api", kind: .missed, text: "New missed.")
        XCTAssertTrue(after.contains("Intro text.") && after.contains("- old noise") && after.contains("- keep me"))
        XCTAssertTrue(after.range(of: "- New missed.")!.lowerBound < after.range(of: "## web")!.lowerBound, "added inside the api section")
        // A heading or a fence in an entry cannot break the structure.
        let tricky = LessonsMarkdown.append(before, repo: "web", kind: .wrong, text: "## fake heading\n```\nboom")
        XCTAssertFalse(tricky.contains("\n## fake"), tricky)
    }

    func testProposalsDedupeAndNothingIsWrittenByThem() {
        var file = LessonsFile()
        let p = LessonProposal(id: "card-k-F1", repo: "api", kind: .noise, text: "Do not raise: x", source: "card", prKey: "k", createdAt: 1)
        XCTAssertTrue(file.add(p))
        XCTAssertFalse(file.add(p), "same source, once")
        var again = p; again.id = "card-k2-F9"
        XCTAssertFalse(file.add(again), "the same entry already waits")
        file.mark(p.id, .dismissed)
        XCTAssertTrue(file.pending.isEmpty)
        XCTAssertFalse(file.add(p), "a dismissed source is not asked again")
        file.edit(p.id, text: "changed")
        XCTAssertEqual(LessonsFile.decode(file.encoded()), file)
    }

    func testSources() {
        var off = SuggestedComment(id: "c1", severity: .nit, path: "a.ts", line: 4, title: "Rename x", body: "Rename x to y.")
        off.finding = "F2"; off.include = false; off.includeTouched = true
        XCTAssertEqual(LessonSources.card(off, repo: "api", prKey: "k", at: 1)?.kind, .noise)
        XCTAssertEqual(LessonSources.card(off, repo: "api", prKey: "k", at: 1)?.id, "card-k-F2")
        var untouched = off; untouched.includeTouched = nil
        XCTAssertNil(LessonSources.card(untouched, repo: "api", prKey: "k", at: 1), "off by default is not the reviewer's call")
        var posted = off; posted.postedID = 5
        XCTAssertNil(LessonSources.card(posted, repo: "api", prKey: "k", at: 1))
        let good = ReplyAnalysis(commentID: 7, verdict: .explained, reason: "The helper does not exist.", disagrees: true, model: ReviewModels.full)
        let thread = ReplyThread(id: 7, text: "Use the helper.", replies: [])
        XCTAssertEqual(LessonSources.reply(good, thread: thread, repo: "api", prKey: "k", at: 1)?.kind, .wrong)
        XCTAssertNil(LessonSources.reply(ReplyAnalysis(commentID: 8, verdict: .fixed, reason: "ok"), thread: nil, repo: "api", prKey: "k", at: 1))
        let others = Data(#"[{"id":1,"path":"a.ts","line":5,"body":"covered by our card","resolved":false},{"id":2,"path":"z.ts","line":9,"body":"Missed null check.","resolved":false,"asks":true},{"id":3,"path":"z.ts","body":"summary","bot":true},{"id":4,"path":"y.ts","body":"done","resolved":true},{"id":5,"body":"general note","asks":false}]"#.utf8)
        let missed = LessonSources.others(others, cards: [off], repo: "api", prKey: "k", at: 1)
        XCTAssertEqual(missed.map(\.id), ["others-k-2"])
        XCTAssertEqual(missed.first?.kind, .missed)
    }
}
