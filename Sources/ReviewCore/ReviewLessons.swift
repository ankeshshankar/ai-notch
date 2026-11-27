import Foundation

// Learning (the contract): the app proposes lessons from what the reviewer did, and only an entry the reviewer
// approves is appended to the skill's `lessons.md`, by the app itself, one section per repo, three kinds.
// Proposals wait in `lessons-proposed.json`. Nothing is appended automatically. No AppKit, no network.

public enum LessonKind: String, Codable, CaseIterable, Sendable, Equatable {
    /// Do not raise this again.
    case noise = "Noise"
    /// Must raise this: a person found it and we did not.
    case missed = "Missed"
    /// We were wrong, and why.
    case wrong = "Wrong"

    public var hint: String {
        switch self {
        case .noise: return "Do not raise"
        case .missed: return "Must raise"
        case .wrong: return "We were wrong"
        }
    }
}

public enum LessonState: String, Codable, Sendable, Equatable {
    case pending, approved, dismissed
}

public struct LessonProposal: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var repo: String
    public var kind: LessonKind
    /// The entry as it would be written; the reviewer edits it before approving.
    public var text: String
    /// Where it came from: a card switched off, an author reply, a comment of someone else.
    public var source: String
    public var prKey: String
    public var createdAt: Double
    public var state: LessonState

    public init(id: String, repo: String, kind: LessonKind, text: String, source: String, prKey: String, createdAt: Double, state: LessonState = .pending) {
        self.id = id
        self.repo = repo
        self.kind = kind
        self.text = text
        self.source = source
        self.prKey = prKey
        self.createdAt = createdAt
        self.state = state
    }

    public var sourceLabel: String {
        switch source {
        case "card": return "A card you switched off"
        case "reply": return "A reply you agreed with"
        case "others": return "A comment from someone else"
        default: return source
        }
    }
}

public struct LessonsFile: Codable, Sendable, Equatable {
    public var version = 1
    public var proposals: [LessonProposal] = []

    public init() {}

    public var pending: [LessonProposal] { proposals.filter { $0.state == .pending }.sorted { $0.createdAt < $1.createdAt } }

    /// Adds a proposal unless the same source already made one (any state) or the same entry waits already.
    @discardableResult
    public mutating func add(_ proposal: LessonProposal) -> Bool {
        if proposals.contains(where: { $0.id == proposal.id }) { return false }
        let norm = LessonsMarkdown.normalize(proposal.text)
        if proposals.contains(where: { $0.state != .dismissed && $0.repo == proposal.repo && $0.kind == proposal.kind && LessonsMarkdown.normalize($0.text) == norm }) { return false }
        proposals.append(proposal)
        return true
    }

    public mutating func edit(_ id: String, text: String) {
        if let i = proposals.firstIndex(where: { $0.id == id }) { proposals[i].text = text }
    }

    public mutating func mark(_ id: String, _ state: LessonState) {
        if let i = proposals.firstIndex(where: { $0.id == id }) { proposals[i].state = state }
    }

    public static func decode(_ data: Data?) -> LessonsFile {
        guard let data, let file = try? JSONDecoder().decode(LessonsFile.self, from: data) else { return LessonsFile() }
        return file
    }

    public func encoded() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try? encoder.encode(self)
    }
}

public enum LessonsMarkdown {
    public static func normalize(_ text: String) -> String {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
    }

    /// One line, no markdown headings or fences, so an entry can never break the file's structure.
    public static func cleanLine(_ text: String, limit: Int = 400) -> String {
        let flat = text.replacingOccurrences(of: "\r", with: " ").split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        var out = flat
        while out.hasPrefix("#") || out.hasPrefix("-") || out.hasPrefix("*") { out.removeFirst(); out = out.trimmingCharacters(in: .whitespaces) }
        out = out.replacingOccurrences(of: "```", with: "")
        return String(out.prefix(limit))
    }

    /// `lessons.md` with one bullet added under `## <repo>` / `### <kind>`; the section and the kind heading are
    /// made when they are missing, and nothing else in the file moves.
    public static func append(_ markdown: String, repo: String, kind: LessonKind, text: String) -> String {
        let entry = "- " + cleanLine(text)
        var lines = markdown.isEmpty ? ["# Lessons", ""] : markdown.components(separatedBy: "\n")
        let repoHeading = "## " + repo
        func isH2(_ l: String) -> Bool { l.hasPrefix("## ") }
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == repoHeading }) else {
            while let last = lines.last, last.isEmpty { lines.removeLast() }
            lines += ["", repoHeading, ""]
            for k in LessonKind.allCases { lines += ["### \(k.rawValue)", k == kind ? entry : "", ""] }
            while let last = lines.last, last.isEmpty { lines.removeLast() }
            return lines.joined(separator: "\n") + "\n"
        }
        let end = lines[(start + 1)...].firstIndex(where: isH2) ?? lines.count
        let kindHeading = "### " + kind.rawValue
        if let h = lines[start..<end].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == kindHeading }) {
            var at = lines[(h + 1)..<end].firstIndex(where: { $0.hasPrefix("### ") }) ?? end
            while at > h + 1, lines[at - 1].trimmingCharacters(in: .whitespaces).isEmpty { at -= 1 }
            lines.insert(entry, at: at)
            if at + 1 < lines.count, !lines[at + 1].isEmpty, !lines[at + 1].hasPrefix("- ") { lines.insert("", at: at + 1) }
        } else {
            var at = end
            while at > start + 1, lines[at - 1].trimmingCharacters(in: .whitespaces).isEmpty { at -= 1 }
            lines.insert(contentsOf: ["", kindHeading, entry], at: at)
        }
        let text = lines.joined(separator: "\n")
        return text.hasSuffix("\n") ? text : text + "\n"
    }
}

/// Where a proposal comes from: pure, from data the app already has.
public enum LessonSources {
    private static func first(_ text: String, _ n: Int) -> String { String(LessonsMarkdown.cleanLine(text, limit: 1000).prefix(n)) }

    /// A card the reviewer switched off (never one already posted): Noise. The reason is theirs to write in the entry.
    public static func card(_ card: SuggestedComment, repo: String, prKey: String, at: Double) -> LessonProposal? {
        guard !card.isPosted, card.include == false, card.includeTouched == true else { return nil }
        let what = (card.title?.isEmpty == false ? card.title! : first(card.body, 120))
        let place = card.path.map { " (\($0)\(card.line.map { ":\($0)" } ?? ""))" } ?? ""
        return LessonProposal(id: "card-\(prKey)-\(card.finding ?? card.id)", repo: repo, kind: .noise,
                              text: "Do not raise: \(what)\(place). Why: ", source: "card", prKey: prKey, createdAt: at)
    }

    /// An author reply judged a correct disagreement: Wrong, with the read's reason.
    public static func reply(_ analysis: ReplyAnalysis, thread: ReplyThread?, repo: String, prKey: String, at: Double) -> LessonProposal? {
        guard analysis.isCorrectDisagreement else { return nil }
        let what = thread.map { first($0.text, 120) } ?? "a comment"
        return LessonProposal(id: "reply-\(prKey)-\(analysis.commentID)", repo: repo, kind: .wrong,
                              text: "We were wrong about: \(what). \(first(analysis.reason, 220))", source: "reply", prKey: prKey, createdAt: at)
    }

    /// Comments of other people (`others.json`, unresolved, asking for something, not a bot) that match none of our
    /// cards by path and a line within 3: Missed.
    public static func others(_ data: Data, cards: [SuggestedComment], repo: String, prKey: String, at: Double) -> [LessonProposal] {
        guard let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        var out: [LessonProposal] = []
        for item in list {
            guard (item["resolved"] as? Bool) != true, (item["asks"] as? Bool) != false, (item["bot"] as? Bool) != true,
                  let id = (item["id"] as? Int) ?? (item["id"] as? Double).map(Int.init), let body = item["body"] as? String, !body.isEmpty else { continue }
            let path = item["path"] as? String
            let line = (item["line"] as? Int) ?? (item["line"] as? Double).map(Int.init)
            let covered = cards.contains { c in
                guard let path, c.path == path else { return false }
                guard let line, let cl = c.line else { return true }
                return abs(cl - line) <= 3
            }
            if covered { continue }
            let place = path.map { " (\($0)\(line.map { ":\($0)" } ?? ""))" } ?? ""
            out.append(LessonProposal(id: "others-\(prKey)-\(id)", repo: repo, kind: .missed, text: "Must raise: \(first(body, 220))\(place)", source: "others", prKey: prKey, createdAt: at))
        }
        return out
    }
}
