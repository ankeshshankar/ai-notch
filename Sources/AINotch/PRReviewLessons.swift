import Foundation
import ReviewCore

/// Lessons the review learns, waiting for the reviewer: `lessons-proposed.json` in the reviews folder. Only an
/// approved entry is appended to the skill's `lessons.md`, here, by the app; nothing is appended by itself.
@MainActor
final class LessonsStore: ObservableObject {
    static let shared = LessonsStore()

    @Published private(set) var pending: [LessonProposal] = []

    private init() { pending = load().pending }

    /// The proposals file: always beside the reviews (a dev run gets its own folder).
    nonisolated static var proposedURL: URL { PRReviewStore.baseURL.appendingPathComponent("lessons-proposed.json") }

    /// The skill's `lessons.md`. A dev run never touches the real one (CLAUDE_NOTCH_LESSONS or its scratch folder).
    nonisolated static func lessonsURL(skill: String = ReviewNames.load().skill) -> URL {
        if let path = ProcessInfo.processInfo.environment["CLAUDE_NOTCH_LESSONS"], !path.isEmpty { return URL(fileURLWithPath: path) }
        if PRReviewStore.isDevRun { return PRReviewStore.devScratch.appendingPathComponent("lessons.md") }
        return BitbucketConfig.home.appendingPathComponent(".claude/skills/\(skill)/lessons.md")
    }

    private func load() -> LessonsFile { LessonsFile.decode(try? Data(contentsOf: Self.proposedURL)) }

    private func save(_ file: LessonsFile) {
        try? FileManager.default.createDirectory(at: Self.proposedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = file.encoded() { try? data.write(to: Self.proposedURL, options: .atomic) }
        pending = file.pending
    }

    func reload() { pending = load().pending }

    func propose(_ proposals: [LessonProposal?]) {
        var file = load()
        var added = false
        for case let p? in proposals { added = file.add(p) || added }
        if added { save(file) }
    }

    func edit(_ id: String, text: String) {
        var file = load()
        file.edit(id, text: text)
        save(file)
    }

    func dismiss(_ id: String) {
        var file = load()
        file.mark(id, .dismissed)
        save(file)
    }

    /// Appends the (edited) entry to `lessons.md` and only then marks it approved. nil = done, else why not.
    @discardableResult
    func approve(_ id: String, skill: String = ReviewNames.load().skill) -> String? {
        var file = load()
        guard let proposal = file.proposals.first(where: { $0.id == id && $0.state == .pending }) else { return "Already handled" }
        let clean = LessonsMarkdown.cleanLine(proposal.text)
        guard clean.count >= 8 else { return "Write the lesson first" }
        let url = Self.lessonsURL(skill: skill)
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.deletingLastPathComponent().path) || PRReviewStore.isDevRun || ProcessInfo.processInfo.environment["CLAUDE_NOTCH_LESSONS"] != nil else {
            return "The \(skill) skill folder is missing (Setup, Pull requests)"
        }
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let before = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let after = LessonsMarkdown.append(before, repo: proposal.repo, kind: proposal.kind, text: clean)
        do { try after.write(to: url, atomically: true, encoding: .utf8) } catch { return "Could not write lessons.md" }
        file.mark(id, .approved)
        save(file)
        return nil
    }

    // MARK: Sources

    /// A card switched off by hand.
    func cardSwitchedOff(_ card: SuggestedComment, ref: PullRequestRef) {
        propose([LessonSources.card(card, repo: ref.repo, prKey: ref.key, at: Date().timeIntervalSince1970)])
    }

    /// Author replies read and judged a correct disagreement.
    func replies(_ analyses: [ReplyAnalysis], file: RepliesFile, ref: PullRequestRef) {
        let now = Date().timeIntervalSince1970
        propose(analyses.map { LessonSources.reply($0, thread: file.thread($0.commentID), repo: ref.repo, prKey: ref.key, at: now) })
    }

    /// After a full run: comments of other people that none of our cards cover.
    func others(ref: PullRequestRef, head: String) {
        let folder = PRReviewStore.folder(ref, head: head)
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("others.json")) else { return }
        let cards = (try? Data(contentsOf: folder.appendingPathComponent("comments.json"))).map { CommentParse.file($0) } ?? []
        propose(LessonSources.others(data, cards: cards, repo: ref.repo, prKey: ref.key, at: Date().timeIntervalSince1970))
    }
}
