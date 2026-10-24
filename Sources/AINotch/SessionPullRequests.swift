import AppKit
import Foundation
import NotchCore

// A session knows its pull request. Each live session's folder is asked for its git branch and
// Bitbucket remote (off the main thread, at most every 30 seconds), and matched to one of my open
// pull requests with the same repository and source branch. The session's row then shows a short
// line about it ("PR #123 · build failed") and, when there is feedback to act on, "Send to agent":
// a plain-text brief of the failed build, the new comments and the merge conflict. A Claude Code
// session with a turn running gets it as a note for its next step; any other agent gets it on the
// clipboard and the session's window comes forward. Nothing is ever typed into a terminal, and
// nothing is approved, merged or commented from here. The brief's logs and comment text are
// read only on the click. They are not kept: a brief for a Claude Code session waits in that
// session's control file (readable by you only) until Claude takes it at its next step, which
// clears it, or until the turn ends first, when it goes to the clipboard and is cleared. Claude
// is told the quoted text was written by other people or CI and is data, not instructions.

// MARK: What the brief needs

/// A comment's author, where it is, and its text, read on a click.
struct PRCommentText: Equatable, Sendable {
    var author: String
    /// File and line of an inline comment.
    var path: String?
    var line: Int?
    var text: String
}

/// What a click reads for the brief; parts that could not be read stay empty.
struct PRFeedbackData: Equatable, Sendable {
    var step: String?
    var log: [String]?
    var comments: [PRCommentText] = []
}

/// What there is to act on for a pull request of mine.
enum PRFeedbackKind: Equatable, Sendable {
    case buildFailed
    case mergeConflict
    case newComments(Int)
}

extension PullRequest {
    /// Feedback an agent can act on, in the order the brief and the line give it.
    var feedbackKinds: [PRFeedbackKind] {
        guard role == .mine else { return [] }
        var kinds: [PRFeedbackKind] = []
        if build?.state == .failed { kinds.append(.buildFailed) }
        if merge?.hasConflict == true { kinds.append(.mergeConflict) }
        if newComments > 0 { kinds.append(.newComments(newComments)) }
        return kinds
    }
}

extension PRParse {
    static let stepFields = "values.uuid,values.name,values.started_on,values.completed_on,values.state.name,values.state.result.name,values.state.stage.name,values.trigger.type"
    static let commentTextFields = "values.id,values.user.uuid,values.user.display_name,values.created_on,values.deleted,values.content.raw,values.inline.path,values.inline.to,values.inline.from"

    /// Whether a log answer starts mid-file: a 206 whose Content-Range does not begin at byte 0
    /// (a suffix range larger than the log returns all of it, from 0). A 206 that says nothing is
    /// taken as partial.
    static func isPartial(status: Int, contentRange: String?) -> Bool {
        guard status == 206 else { return false }
        guard let contentRange, let start = contentRange.split(separator: " ").last?.split(separator: "-").first.flatMap({ Int($0) }) else { return true }
        return start != 0
    }

    /// The uuid of build number `number` in a pipelines list.
    static func runUUID(_ page: [String: Any], number: Int) -> String? {
        (page["values"] as? [[String: Any]] ?? []).first { ($0["build_number"] as? Int) == number }?["uuid"] as? String
    }

    /// The last `lines` lines of a step's log without colour codes. A partial answer starts
    /// mid-line, so its first line is dropped.
    static func logTail(_ data: Data, ranged: Bool, lines count: Int) -> [String] {
        var lines = String(decoding: data, as: UTF8.self).split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(plainLogLine)
        if ranged, lines.count > 1 { lines.removeFirst() }
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        return Array(lines.suffix(count))
    }

    /// The newest `limit` comments by someone else, oldest first, with their text. A comment
    /// without text is left out.
    static func commentTexts(_ page: [String: Any], me: String?, limit: Int) -> [PRCommentText] {
        let found: [(Double, PRCommentText)] = (page["values"] as? [[String: Any]] ?? []).compactMap { item in
            guard item["deleted"] as? Bool != true, let created = buildTime(item["created_on"]) else { return nil }
            let user = item["user"] as? [String: Any]
            if let me, user?["uuid"] as? String == me { return nil }
            let raw = ((item["content"] as? [String: Any])?["raw"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { return nil }
            let inline = item["inline"] as? [String: Any]
            let line = (inline?["to"] as? Int) ?? (inline?["from"] as? Int)
            return (created, PRCommentText(author: user?["display_name"] as? String ?? "Someone", path: inline?["path"] as? String, line: line, text: raw))
        }
        return found.sorted { $0.0 > $1.0 }.prefix(limit).reversed().map(\.1)
    }
}

// MARK: The row's line and the brief

/// The compact line under a session's row: "PR #123 · build failed".
enum PRLine {
    enum Tone: Equatable { case bad, attention, good, quiet }

    static func text(_ pr: PullRequest) -> String {
        var parts: [String] = []
        for kind in pr.feedbackKinds {
            switch kind {
            case .buildFailed: parts.append("build failed")
            case .mergeConflict: parts.append("merge conflict")
            case .newComments(let count): parts.append("\(count) new comment\(count == 1 ? "" : "s")")
            }
        }
        if pr.role == .mine, pr.merge?.cannotMerge == true { parts.append("can't merge") }
        if parts.isEmpty {
            if !pr.changesRequestedBy.isEmpty {
                parts.append("changes requested")
            } else if pr.isReadyToMerge == true {
                parts.append(pr.approvals > 0 ? "approved, can merge" : "can merge")
            } else if pr.approvals > 0 {
                parts.append("approved")
            } else if pr.isDraft {
                parts.append("draft")
            } else if pr.build?.state.isRunning == true {
                parts.append("build running")
            } else {
                parts.append("open")
            }
        }
        return "PR #\(pr.ref.id) · " + parts.joined(separator: " · ")
    }

    static func tone(_ pr: PullRequest) -> Tone {
        let kinds = pr.feedbackKinds
        if kinds.contains(.buildFailed) || kinds.contains(.mergeConflict) { return .bad }
        if !kinds.isEmpty || !pr.changesRequestedBy.isEmpty || pr.merge?.cannotMerge == true { return .attention }
        if pr.isReadyToMerge == true || pr.approvals > 0 { return .good }
        return .quiet
    }
}

/// The plain-text brief "Send to agent" hands over.
enum PRBrief {
    /// Lines of the failed step's log, comments, and characters each may take.
    static let logLines = 40
    static let maxComments = 8
    static let lineLimit = 240
    static let commentLimit = 600

    static func compose(_ pr: PullRequest, feedback: PRFeedbackData) -> String {
        var out = ["Pull request #\(pr.ref.id) \"\(pr.title)\" (\(pr.ref.repoKey)) needs your attention."]
        if let url = pr.url { out.append(url.absoluteString) }
        for kind in pr.feedbackKinds {
            out.append("")
            switch kind {
            case .buildFailed:
                let name = pr.build?.name ?? pr.build?.pipeline.map { "Pipeline #\($0.number)" } ?? "the pull request's build"
                out.append("Build failed: \(name)\(feedback.step.map { ", step \"\($0)\"" } ?? "").")
                if let log = feedback.log, !log.isEmpty {
                    out.append("Last \(log.count) lines of the step's log:")
                    out += log.map { clip($0, lineLimit) }
                } else {
                    out.append("(The log could not be read." + (pr.build?.url.map { " See \($0.absoluteString)." } ?? "") + ")")
                }
            case .newComments(let count):
                if feedback.comments.isEmpty {
                    out.append("\(count) new comment\(count == 1 ? "" : "s"), whose text could not be read: see the pull request.")
                } else {
                    out.append("New comment\(feedback.comments.count == 1 ? "" : "s") to address:")
                    for comment in feedback.comments {
                        let place = comment.path.map { " on \($0)\(comment.line.map { ":\($0)" } ?? "")" } ?? ""
                        let text = comment.text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
                        out.append("- \(comment.author)\(place): \(clip(text, commentLimit))")
                    }
                }
            case .mergeConflict:
                let source = pr.source ?? "this branch", destination = pr.destination ?? "its destination"
                out.append("Merge conflict: branch \(source) conflicts with \(destination). Rebase it onto \(destination) (or merge \(destination) into it) and resolve the conflicts.")
            }
        }
        return Redact.mask(out.joined(separator: "\n"), keep: Set([pr.head].compactMap { $0 }))
    }

    private static func clip(_ text: String, _ limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }
}

/// How a brief reaches the agent.
enum PRDelivery: Equatable {
    /// Claude Code with a turn running: a note it gets at its next tool call.
    case note
    /// Any other agent: on the clipboard, and its window comes forward.
    case clipboard

    static func route(isClaudeCode: Bool, phase: Phase) -> PRDelivery {
        isClaudeCode && phase != .idle ? .note : .clipboard
    }

    static let sentNote = "Sent — Claude gets it at its next step"
    static let finishedFirst = "Claude finished first — brief copied"
    static let copied = "Copied — paste it to the agent"
}

// MARK: Folder to branch and remote

/// A session folder's Bitbucket repository ("workspace/repo") and checked-out branch.
struct SessionGit: Equatable, Sendable {
    var repo: String?
    var branch: String?
}

enum GitRemote {
    /// "workspace/repo" from a Bitbucket Cloud remote in any of its forms: `git@bitbucket.org:ws/repo.git`,
    /// `ssh://git@bitbucket.org/ws/repo.git`, `https://user@bitbucket.org/ws/repo.git` (an ssh
    /// alias host that names bitbucket counts too). Nil for any other host.
    static func repo(_ remote: String) -> String? {
        let text = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        let host: String, path: String
        if let range = text.range(of: "://") {
            let rest = text[range.upperBound...]
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            host = String(rest[..<slash]); path = String(rest[rest.index(after: slash)...])
        } else {
            guard let colon = text.firstIndex(of: ":") else { return nil }
            host = String(text[..<colon]); path = String(text[text.index(after: colon)...])
        }
        let name = host.split(separator: "@").last.map(String.init)?.split(separator: ":").first.map(String.init) ?? host
        guard name.lowercased().contains("bitbucket") else { return nil }
        var parts = path.split(separator: "/").map(String.init)
        if var last = parts.last, last.hasSuffix(".git") { last.removeLast(4); parts[parts.count - 1] = last }
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty }) else { return nil }
        return parts.joined(separator: "/")
    }

    /// The repository from `git config --get-regexp ^remote\..*\.url$` output: origin when it
    /// is on Bitbucket, else the first remote that is.
    static func repo(fromConfig output: String) -> String? {
        var found: [(name: String, repo: String)] = []
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[0].hasPrefix("remote."), parts[0].hasSuffix(".url"), let repo = repo(parts[1]) else { continue }
            found.append((String(parts[0].dropFirst(7).dropLast(4)), repo))
        }
        return (found.first { $0.name == "origin" } ?? found.first)?.repo
    }
}

/// Asks git, off the main thread, which branch and Bitbucket repository each folder is on. A
/// folder is asked again only after 30 seconds, so the 5-second tick is cheap; two short git
/// commands each, with a 3-second limit.
actor SessionGitSource {
    private var cache: [String: (git: SessionGit, at: Double)] = [:]
    static let ttl: Double = 30

    func resolve(_ folders: [String]) async -> [String: SessionGit] {
        let now = Date().timeIntervalSince1970
        var result: [String: SessionGit] = [:]
        for folder in folders {
            if let hit = cache[folder], now - hit.at < Self.ttl { result[folder] = hit.git; continue }
            let branch = await Self.git(folder, ["symbolic-ref", "--short", "-q", "HEAD"])?.trimmingCharacters(in: .whitespacesAndNewlines)
            let remotes = await Self.git(folder, ["config", "--get-regexp", #"^remote\..*\.url$"#])
            let git = SessionGit(repo: remotes.flatMap(GitRemote.repo(fromConfig:)), branch: branch?.isEmpty == false ? branch : nil)
            cache[folder] = (git, now)
            result[folder] = git
        }
        for key in cache.keys where !folders.contains(key) { cache[key] = nil }
        return result
    }

    private static func git(_ folder: String, _ arguments: [String]) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                process.arguments = ["-C", folder] + arguments
                process.environment = ["GIT_TERMINAL_PROMPT": "0", "GIT_OPTIONAL_LOCKS": "0", "HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin"]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                guard FileManager.default.fileExists(atPath: folder), (try? process.run()) != nil else { return continuation.resume(returning: nil) }
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) { if process.isRunning { process.terminate() } }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil)
            }
        }
    }
}

enum PRLink {
    /// My open pull request with the session's repository and branch as its source; the newest
    /// when there are several.
    static func match(_ git: SessionGit, in prs: [PullRequest]) -> PullRequest? {
        guard let repo = git.repo?.lowercased(), let branch = git.branch else { return nil }
        return prs.filter { $0.role == .mine && $0.source == branch && $0.ref.repoKey.lowercased() == repo }
            .max { $0.updatedAt < $1.updatedAt }
    }
}

// MARK: The store

/// Which session belongs to which of my pull requests, and "Send to agent". Fed with the live
/// sessions and my pull requests; asks git only while pull requests are on.
@MainActor
final class SessionPRStore: ObservableObject {
    /// The pull request of each session (by session id) that has one.
    @Published private(set) var linked: [String: PullRequest] = [:]
    /// A short confirmation on a session's line, for a few seconds.
    @Published private(set) var notices: [String: String] = [:]
    /// Sessions whose brief is being read.
    @Published private(set) var sending: Set<String> = []

    /// Pull requests are on (builds.json); off clears every link.
    var enabled = false {
        didSet { if enabled != oldValue { enabled ? refreshGit() : clear() } }
    }
    /// The keys of the pull requests linked to a live session: the source reads their merge
    /// checks first.
    var onWatched: ((Set<String>) -> Void)?
    /// Reads what the brief needs (the failed step's log, the new comments' text).
    var feedback: ((PullRequest, _ build: Bool, _ comments: Int) async -> PRFeedbackData)?

    private let source = SessionGitSource()
    private var sessions: [String: SessionState] = [:]
    private var gits: [String: SessionGit] = [:]
    private var mine: [PullRequest] = []
    private var refreshedAt: Double = 0
    private var refreshing = false
    private var watchedSent: Set<String> = []

    func setSessions(_ list: [SessionState]) {
        let before = Set(sessions.values.map(\.cwd))
        sessions = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        takeBackUndelivered()
        guard enabled else { return }
        if !Set(sessions.values.map(\.cwd)).isSubset(of: before) { refreshGit() } else { relink() }
    }

    func setMine(_ prs: [PullRequest]) {
        guard prs != mine else { return }
        mine = prs
        relink()
    }

    /// Every 5 seconds: git is asked again when the last answer is 30 seconds old.
    func tick() {
        guard enabled, Date().timeIntervalSince1970 - refreshedAt >= SessionGitSource.ttl else { return }
        refreshGit()
    }

    private func refreshGit() {
        guard enabled, !refreshing else { return }
        let folders = Array(Set(sessions.values.map(\.cwd).filter { !$0.isEmpty })).sorted()
        guard !folders.isEmpty else { return relink() }
        refreshing = true
        Task {
            let found = await source.resolve(folders)
            refreshing = false
            refreshedAt = Date().timeIntervalSince1970
            if found != gits { gits = found }
            relink()
        }
    }

    private func clear() {
        gits = [:]
        if !linked.isEmpty { linked = [:] }
        pushWatched([])
    }

    private func relink() {
        var next: [String: PullRequest] = [:]
        if enabled {
            for (id, session) in sessions {
                if let git = gits[session.cwd], let pr = PRLink.match(git, in: mine) { next[id] = pr }
            }
        }
        if next != linked { linked = next }
        pushWatched(Set(next.values.map(\.id)))
    }

    private func pushWatched(_ keys: Set<String>) {
        guard keys != watchedSent else { return }
        watchedSent = keys
        onWatched?(keys)
    }

    // MARK: Send to agent

    func send(_ session: SessionState) {
        guard let pr = linked[session.id], !sending.contains(session.id), let feedback else { return }
        let kinds = pr.feedbackKinds
        guard !kinds.isEmpty else { return }
        var wantBuild = false
        var comments = 0
        for kind in kinds {
            if case .newComments(let count) = kind { comments = count }
            if kind == .buildFailed { wantBuild = true }
        }
        sending.insert(session.id)
        Task {
            let data = await feedback(pr, wantBuild, comments)
            let text = PRBrief.compose(linked[session.id] ?? pr, feedback: data)
            sending.remove(session.id)
            deliver(text, pullRequest: pr.ref.id, to: sessions[session.id] ?? session)
        }
    }

    private func deliver(_ text: String, pullRequest: Int, to session: SessionState) {
        let route = PRDelivery.route(isClaudeCode: AgentControls.kind(of: session) == .hooked, phase: session.phase)
        switch route {
        case .note:
            if AgentControls.shared.queueFeedback(session, pullRequest: pullRequest, text) {
                show(PRDelivery.sentNote, for: session.id)
            } else {
                copyAndJump(text, to: session)
            }
        case .clipboard:
            copyAndJump(text, to: session)
        }
    }

    private func copyAndJump(_ text: String, to session: SessionState) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        Jump.to(session)
        show(PRDelivery.copied, for: session.id)
    }

    /// A brief queued for Claude's next step is not handed over if the turn ends first (the hook
    /// keeps it through the turn's end): it goes to the clipboard, and the row says so.
    private func takeBackUndelivered() {
        for session in sessions.values where session.phase == .idle && AgentControls.shared.hasFeedback(session) {
            guard let text = AgentControls.shared.takeFeedback(session) else { continue }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            show(PRDelivery.finishedFirst, for: session.id)
        }
    }

    private func show(_ text: String, for id: String) {
        notices[id] = text
        Task {
            try? await Task.sleep(for: .seconds(7))
            if notices[id] == text { notices[id] = nil }
        }
    }
}
