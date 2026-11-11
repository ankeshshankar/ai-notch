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

/// A session folder's Bitbucket repository ("workspace/repo"), checked-out branch and where its
/// working tree stands (one `git status --porcelain=v2 --branch`).
struct SessionGit: Equatable, Sendable {
    var repo: String?
    var branch: String?
    /// HEAD's commit, in full; nil in a repository with no commit yet or when git said nothing.
    var head: String?
    /// The branch it tracks ("origin/feat/x"); nil when it has none.
    var upstream: String?
    /// Commits not pushed to the upstream, and commits it has that this branch lacks.
    var ahead = 0
    var behind = 0
    /// Files with a change not committed: modified, staged, conflicted or untracked.
    var changed = 0
    var isDetached = false
    /// Whether git answered at all: a folder that is no repository has nothing to show.
    var isRepo = false

    /// The upstream is unknown only for a named branch that tracks nothing.
    var hasNoUpstream: Bool { isRepo && branch != nil && upstream == nil }
}

/// What `git status --porcelain=v2 --branch` says.
enum GitStatusParse {
    static func parse(_ output: String) -> SessionGit {
        var git = SessionGit(isRepo: true)
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("# branch.oid ") {
                let oid = String(line.dropFirst(13))
                git.head = oid == "(initial)" ? nil : oid
            } else if line.hasPrefix("# branch.head ") {
                let name = String(line.dropFirst(14))
                if name == "(detached)" { git.isDetached = true } else { git.branch = name }
            } else if line.hasPrefix("# branch.upstream ") {
                git.upstream = String(line.dropFirst(18))
            } else if line.hasPrefix("# branch.ab ") {
                // "+2 -1"
                for part in line.dropFirst(12).split(separator: " ") {
                    guard let count = Int(part.dropFirst()) else { continue }
                    if part.hasPrefix("+") { git.ahead = count } else if part.hasPrefix("-") { git.behind = count }
                }
            } else if let first = line.first, "12u?".contains(first) {
                git.changed += 1
            }
        }
        return git
    }
}

/// The git marks on a session's row: `feat/x  ●3 ↑2`, and the full line for its details.
enum GitMarks {
    /// What the branch reads as: its name, or "HEAD abc1234" when detached.
    static func branchText(_ git: SessionGit) -> String? {
        guard git.isRepo else { return nil }
        if let branch = git.branch { return branch }
        return git.isDetached ? "HEAD " + String((git.head ?? "").prefix(7)) : nil
    }

    /// The compact marks after the branch: ●n uncommitted files, ↑n unpushed commits, "no upstream".
    static func marks(_ git: SessionGit) -> [String] {
        guard git.isRepo else { return [] }
        var out: [String] = []
        if git.changed > 0 { out.append("●\(git.changed)") }
        if git.ahead > 0 { out.append("↑\(git.ahead)") }
        if git.behind > 0 { out.append("↓\(git.behind)") }
        if git.hasNoUpstream { out.append("no upstream") }
        return out
    }

    /// The details table's line: "feat/x · 3 uncommitted files · 2 unpushed commits · tracks origin/feat/x".
    static func fullLine(_ git: SessionGit) -> String? {
        guard let branch = branchText(git) else { return nil }
        var parts = [branch]
        parts.append(git.changed == 0 ? "clean" : "\(git.changed) uncommitted file\(git.changed == 1 ? "" : "s")")
        if git.ahead > 0 { parts.append("\(git.ahead) unpushed commit\(git.ahead == 1 ? "" : "s")") }
        if git.behind > 0 { parts.append("\(git.behind) behind") }
        if let upstream = git.upstream { parts.append("tracks \(upstream)") } else if git.hasNoUpstream { parts.append("no upstream") }
        return parts.joined(separator: " · ")
    }
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

/// Asks git, off the main thread, which branch and Bitbucket repository each folder is on and how
/// its working tree stands. A folder is asked again only after 30 seconds, so the 5-second tick
/// is cheap; two short git commands each, with a 3-second limit.
actor SessionGitSource {
    private var cache: [String: (git: SessionGit, at: Double)] = [:]
    static let ttl: Double = 30

    func resolve(_ folders: [String]) async -> [String: SessionGit] {
        let now = Date().timeIntervalSince1970
        var result: [String: SessionGit] = [:]
        for folder in folders {
            if let hit = cache[folder], now - hit.at < Self.ttl { result[folder] = hit.git; continue }
            // One status call gives the branch, its upstream, ahead/behind and the changed files.
            let status = await Self.git(folder, ["status", "--porcelain=v2", "--branch"])
            let remotes = await Self.git(folder, ["config", "--get-regexp", #"^remote\..*\.url$"#])
            var git = status.map(GitStatusParse.parse) ?? SessionGit()
            git.repo = remotes.flatMap(GitRemote.repo(fromConfig:))
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

    /// Pull requests are on (builds.json); off clears every link. Git is asked either way: the
    /// row's branch, changes and CI mark need it too.
    var enabled = false {
        didSet { if enabled != oldValue { enabled ? relink() : clear() } }
    }
    /// Each session folder's git state, as last asked (at most every 30 s per folder).
    @Published private(set) var gits: [String: SessionGit] = [:]
    /// The keys of the pull requests linked to a live session: the source reads their merge
    /// checks first.
    var onWatched: ((Set<String>) -> Void)?
    /// Reads what the brief needs (the failed step's log, the new comments' text).
    var feedback: ((PullRequest, _ build: Bool, _ comments: Int) async -> PRFeedbackData)?

    private let source = SessionGitSource()
    private var sessions: [String: SessionState] = [:]
    private var mine: [PullRequest] = []
    private var refreshedAt: Double = 0
    private var refreshing = false
    private var watchedSent: Set<String> = []

    func setSessions(_ list: [SessionState]) {
        let before = Set(sessions.values.map(\.cwd))
        sessions = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        takeBackUndelivered()
        if !Set(sessions.values.map(\.cwd)).isSubset(of: before) { refreshGit() } else { relink() }
    }

    func setMine(_ prs: [PullRequest]) {
        guard prs != mine else { return }
        mine = prs
        relink()
    }

    /// Every 5 seconds: git is asked again when the last answer is 30 seconds old.
    func tick() {
        guard Date().timeIntervalSince1970 - refreshedAt >= SessionGitSource.ttl else { return }
        refreshGit()
    }

    private func refreshGit() {
        guard !refreshing else { return }
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
