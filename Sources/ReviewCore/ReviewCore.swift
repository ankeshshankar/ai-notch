import Foundation

// The pure parts of the automatic pull-request review: reading a verdict out of the report,
// the persisted ledger that dedupes runs by pull request and commit, the gate in front of the
// Approve button, and the headless command's arguments. No AppKit, no network, no process:
// everything here is unit-tested (`swift test`).

public enum ReviewVerdict: String, Codable, Sendable, Equatable {
    case approve = "APPROVE"
    case requestChanges = "REQUEST CHANGES"
}

public struct ReviewFindings: Codable, Sendable, Equatable {
    public var blocking = 0
    public var shouldFix = 0
    public var nits = 0
    public var cannotVerify = 0

    public init(blocking: Int = 0, shouldFix: Int = 0, nits: Int = 0, cannotVerify: Int = 0) {
        self.blocking = blocking
        self.shouldFix = shouldFix
        self.nits = nits
        self.cannotVerify = cannotVerify
    }

    /// "2 blocking · 1 should-fix"; "no findings" when all are zero.
    public var text: String {
        let parts = [(blocking, "blocking"), (shouldFix, "should-fix"), (nits, nits == 1 ? "nit" : "nits"), (cannotVerify, "unverified")]
            .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
        return parts.isEmpty ? "no findings" : parts.joined(separator: " · ")
    }
}

public struct ParsedReview: Equatable, Sendable {
    public var verdict: ReviewVerdict
    public var findings: ReviewFindings
}

public enum ReviewParse {
    /// The skill's report ends with `VERDICT: APPROVE | REQUEST CHANGES` and one line per
    /// finding (`BLOCKING file:line — …`, `SHOULD-FIX`, `NIT`, `CANNOT-VERIFY`). The last
    /// verdict line wins; a line naming both words (the template itself) is not a verdict.
    public static func parse(_ report: String) -> ParsedReview? {
        let lines = report.components(separatedBy: .newlines)
        var verdict: ReviewVerdict?
        var verdictIndex = 0
        for (index, raw) in lines.enumerated() {
            let line = strip(raw).uppercased()
            guard line.hasPrefix("VERDICT") else { continue }
            let rest = line.dropFirst("VERDICT".count).drop { $0 == ":" || $0 == " " || $0 == "-" || $0 == "—" }
            let approve = rest.hasPrefix("APPROVE"), changes = rest.hasPrefix("REQUEST CHANGES")
            let both = rest.contains("APPROVE") && rest.contains("REQUEST CHANGES")
            if both || approve == changes { continue }
            verdict = approve ? .approve : .requestChanges
            verdictIndex = index
        }
        guard let verdict else { return nil }
        // Findings are the lines around the verdict (the report lists them after it, and the
        // summary line before it may repeat them): count from the line after the verdict, and
        // fall back to the whole report when none follow.
        var findings = count(lines[(verdictIndex + 1)...])
        if findings == ReviewFindings() { findings = count(lines[...verdictIndex]) }
        return ParsedReview(verdict: verdict, findings: findings)
    }

    private static func count(_ lines: ArraySlice<String>) -> ReviewFindings {
        var findings = ReviewFindings()
        // A bold heading on its own line ("**SHOULD-FIX**") followed by top-level bullets: each
        // bullet is one finding, until a prose line or the next heading ("None." is no finding).
        var section: String?
        let headings = ["BLOCKING", "SHOULD-FIX", "NIT", "CANNOT-VERIFY"]
        for raw in lines {
            let line = strip(raw)
            let bare = line.uppercased().trimmingCharacters(in: CharacterSet(charactersIn: ": "))
            if headings.contains(bare) { section = bare; continue }
            if let current = section, !raw.trimmingCharacters(in: .whitespaces).isEmpty {
                let top = !raw.hasPrefix(" ") && !raw.hasPrefix("\t")
                let bullet = raw.hasPrefix("- ") || raw.hasPrefix("* ") || raw.range(of: #"^\d+[.)]\s"#, options: .regularExpression) != nil
                if top && bullet {
                    if !line.lowercased().hasPrefix("none") {
                        switch current {
                        case "BLOCKING": findings.blocking += 1
                        case "SHOULD-FIX": findings.shouldFix += 1
                        case "NIT": findings.nits += 1
                        default: findings.cannotVerify += 1
                        }
                    }
                    continue
                }
                if top { section = nil } else { continue }
            }
            func hit(_ keyword: String) -> Bool {
                let upper = line.uppercased()
                guard upper.hasPrefix(keyword) else { return false }
                let rest = upper.dropFirst(keyword.count)
                // The keyword stands alone as a word ("NITPICK" is prose).
                if let first = rest.first, first.isLetter || first.isNumber { return false }
                // "BLOCKING: none", "BLOCKING 0" and a bare heading are not findings.
                let tail = rest.drop { !$0.isLetter && !$0.isNumber }
                if tail.isEmpty || tail.hasPrefix("NONE") { return false }
                if tail.first == "0", tail.dropFirst().first.map({ !$0.isNumber }) ?? true { return false }
                return true
            }
            if hit("BLOCKING") { findings.blocking += 1 }
            else if hit("SHOULD-FIX") { findings.shouldFix += 1 }
            else if hit("NIT") { findings.nits += 1 }
            else if hit("CANNOT-VERIFY") { findings.cannotVerify += 1 }
        }
        return findings
    }

    /// A line without list marks, bold and backticks: "- **BLOCKING** a.ts:3" → "BLOCKING a.ts:3".
    static func strip(_ raw: String) -> String {
        var line = raw.trimmingCharacters(in: .whitespaces)
        while let first = line.first, "-*•>#_`| ".contains(first) { line.removeFirst() }
        line = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        // Numbered lists: "1. BLOCKING …".
        if let range = line.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) { line.removeSubrange(range) }
        return line
    }
}

// MARK: The result of `claude -p --output-format json`

public struct ReviewOutput: Equatable, Sendable {
    public var text: String
    public var isError: Bool
    public var costUSD: Double?
    public var durationSeconds: Double?
    /// The tools Claude Code refused (not in the allowed list): a review that needed one failed.
    public var denied: [String]
    /// The session to resume for the chat (the id stays the same across `--resume`).
    public var sessionID: String? = nil

    public static func parse(_ data: Data) -> ReviewOutput? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let denials = (object["permission_denials"] as? [[String: Any]] ?? []).compactMap { $0["tool_name"] as? String }
        var seen = Set<String>()
        let names = denials.filter { seen.insert($0).inserted }
        return ReviewOutput(text: object["result"] as? String ?? "", isError: object["is_error"] as? Bool ?? false,
                            costUSD: (object["total_cost_usd"] as? NSNumber)?.doubleValue,
                            durationSeconds: (object["duration_ms"] as? NSNumber).map { $0.doubleValue / 1000 },
                            denied: names, sessionID: object["session_id"] as? String)
    }
}

// MARK: Ledger

public enum ReviewPhase: String, Codable, Sendable {
    case queued, reviewing, done, failed, cancelled
}

public struct ReviewRecord: Codable, Sendable, Equatable {
    public var key: String
    public var head: String
    public var phase: ReviewPhase
    public var auto: Bool
    public var verdict: ReviewVerdict?
    public var findings: ReviewFindings?
    /// The report's file name inside the reviews folder.
    public var reportFile: String?
    public var error: String?
    public var queuedAt: Double
    public var startedAt: Double?
    public var finishedAt: Double?
    public var costUSD: Double?
    /// What I sent to Bitbucket for this run, after a click and a confirm: "approved" or "changes requested".
    public var posted: String?
    /// Tools the run asked for and was refused: its verdict stands, but it was partly blind, so Approve stays off.
    public var denied: [String]?
    /// This run is the one automatic retry of an interrupted run: if it is interrupted too, it stays failed.
    public var resumed: Bool?
    /// The Claude Code session of the run, which the review window's chat continues.
    public var sessionID: String?
    /// A follow-up review: the commit the previous review covered (nil for a full review).
    public var baseHead: String?
    /// New commits a follow-up covers.
    public var commitCount: Int?
    /// A review of my own pull request or branch: for me only, nothing is posted or approved.
    public var own: Bool?
    /// A branch review (no pull request yet): the branch and what it is compared with.
    public var branch: String?
    public var target: String?
    /// Comments I posted from this run's cards (the review no longer waits for my call).
    public var commentsPosted: Int?
    /// The "review finished" notification was sent.
    public var notified: Bool?

    public init(key: String, head: String, phase: ReviewPhase, auto: Bool, queuedAt: Double) {
        self.key = key
        self.head = head
        self.phase = phase
        self.auto = auto
        self.queuedAt = queuedAt
    }

    public var isActive: Bool { phase == .queued || phase == .reviewing }
    public var isFollowUp: Bool { baseHead != nil }
}

/// Every run, keyed by "<pull request>@<commit, 12 characters>": a pull request is reviewed
/// once per commit, whatever the notch does on restart.
public struct ReviewLedger: Codable, Sendable, Equatable {
    public var version = 1
    public var records: [String: ReviewRecord] = [:]

    public init() {}

    public static func recordKey(_ key: String, head: String) -> String { key + "@" + String(head.prefix(12)) }

    public func record(_ key: String, head: String) -> ReviewRecord? { records[Self.recordKey(key, head: head)] }

    /// The newest record of a pull request, any commit.
    public func latest(_ key: String) -> ReviewRecord? {
        records.values.filter { $0.key == key }.max { ($0.finishedAt ?? $0.queuedAt) < ($1.finishedAt ?? $1.queuedAt) }
    }

    public mutating func set(_ record: ReviewRecord) { records[Self.recordKey(record.key, head: record.head)] = record }

    /// After a restart nothing is running: what was reviewing failed, what was queued is dropped
    /// (the next poll queues it again if it still needs a review).
    public mutating func settleAfterRestart(now: Double) {
        for (id, var record) in records {
            switch record.phase {
            case .reviewing:
                record.phase = .failed
                record.error = Self.interruptedMessage
                record.finishedAt = now
                records[id] = record
            case .queued:
                records[id] = nil
            default: break
            }
        }
    }

    public static let interruptedMessage = "interrupted (the notch quit)"

    /// Whether an interrupted run (the notch quit mid-review) is started again: once only, for
    /// the same head, with auto review on, on a pull request I review that is still open (the
    /// poll lists it), not a draft and not reviewed by me.
    public static func shouldResume(_ record: ReviewRecord?, head: String?, isDraft: Bool, iReview: Bool, myReviewDone: Bool, autoOn: Bool, repos: ReviewRepos = ReviewRepos()) -> Bool {
        guard autoOn, let record, repos.allows(key: record.key), iReview, !isDraft, !myReviewDone, record.phase == .failed else { return false }
        guard record.error == interruptedMessage, record.resumed != true else { return false }
        return ReviewGate.sameCommit(record.head, head)
    }

    /// Closed pull requests and old records go (30 days after the last news).
    public mutating func prune(openKeys: Set<String>, now: Double) {
        records = records.filter { _, record in
            record.isActive || openKeys.contains(record.key) || now - (record.finishedAt ?? record.queuedAt) < 30 * 86_400
        }
    }
}

/// What a review of a new head is: a full one, or a follow-up on a finished review of an older commit.
public enum ReviewPlan: Equatable, Sendable {
    case full
    case followUp(base: ReviewRecord)
}

public enum ReviewPolicy {
    /// A pull request with a finished review of another commit gets a follow-up (its diff, its
    /// findings and comments); `full` forces a whole review. A branch review follows up on its own branch only.
    public static func plan(key: String, head: String, ledger: ReviewLedger, full: Bool = false) -> ReviewPlan {
        if full { return .full }
        let bases = ledger.records.values.filter {
            $0.key == key && $0.phase == .done && $0.verdict != nil && !ReviewGate.sameCommit($0.head, head)
        }
        guard let base = bases.max(by: { ($0.finishedAt ?? $0.queuedAt) < ($1.finishedAt ?? $1.queuedAt) }) else { return .full }
        return .followUp(base: base)
    }

    /// Pull requests older than this (last update) are not queued on their own.
    public static let autoMaxAge: Double = 7 * 86_400

    /// Whether the poll should queue a review by itself: only a pull request I review, not a
    /// draft, that I have not reviewed myself, with a known head, recently active, and never
    /// run for this commit (a failed or cancelled run is started again by hand only).
    public static func shouldAutoQueue(key: String, head: String?, isDraft: Bool, iReview: Bool, myReviewDone: Bool,
                                       updatedAt: Double, now: Double, ledger: ReviewLedger, autoOn: Bool, repos: ReviewRepos = ReviewRepos()) -> Bool {
        guard autoOn, repos.allows(key: key), iReview, !isDraft, !myReviewDone, let head, !head.isEmpty else { return false }
        guard updatedAt == 0 || now - updatedAt < autoMaxAge else { return false }
        return ledger.record(key, head: head) == nil
    }
}

// MARK: Approve gate

public enum PipelineState: Sendable, Equatable { case green, notGreen, unknown }

public enum ReviewAction: Sendable { case approve, requestChanges }

public enum ReviewGate: Equatable, Sendable {
    case allowed
    case blocked(String)

    public var isAllowed: Bool { self == .allowed }

    /// Two commit hashes of the same commit (the API gives 12 or 40 characters).
    public static func sameCommit(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b, a.count >= 7, b.count >= 7 else { return false }
        return a.hasPrefix(b) || b.hasPrefix(a)
    }

    /// Approve: the verdict is APPROVE with no blocking finding, the reviewed commit is the
    /// pull request's head now, its pipeline is green, it is open and I have not approved it.
    /// Request changes: the verdict is REQUEST CHANGES for the head now.
    /// Evaluated again on fresh data right before the call; the button is only a view of it.
    public static func check(_ action: ReviewAction, record: ReviewRecord?, currentHead: String?, pipeline: PipelineState,
                             isOpen: Bool = true, alreadyApproved: Bool = false) -> ReviewGate {
        guard let record, record.phase == .done, let verdict = record.verdict else { return .blocked("no finished review") }
        if record.own == true { return .blocked("your own work") }
        if action == .approve, !(record.denied ?? []).isEmpty { return .blocked("the review was refused a tool") }
        guard isOpen else { return .blocked("pull request is not open") }
        guard sameCommit(record.head, currentHead) else { return .blocked("new commits since the review") }
        switch action {
        case .approve:
            guard verdict == .approve else { return .blocked("verdict is not APPROVE") }
            guard (record.findings?.blocking ?? 0) == 0 else { return .blocked("blocking findings") }
            guard pipeline == .green else { return .blocked(pipeline == .unknown ? "pipeline state unknown" : "pipeline is not green") }
            guard !alreadyApproved else { return .blocked("already approved") }
            return .allowed
        case .requestChanges:
            guard verdict == .requestChanges else { return .blocked("verdict is not REQUEST CHANGES") }
            return .allowed
        }
    }
}

// MARK: The headless command

/// The model ids of the review cycle (the contract names them): Opus for the review, the follow-up and the re-read
/// of a disagreement, Haiku for the first read of the author's replies.
public enum ReviewModels {
    public static let full = "claude-opus-5-5"
    public static let replies = "claude-haiku-5-5"
    public static let reread = full
}

public enum ReviewCommand {
    /// Everything the review may do, and nothing else (`--permission-mode dontAsk` refuses the
    /// rest without asking). Reads: files, search, read-only git, the Bitbucket API with GET
    /// flags only, plain file tools. Writes: only the review's own scratch folder, and the
    /// scratch worktree git adds and removes. No push, commit, checkout, reset, merge, rebase,
    /// no `curl` of its own (see `bbGetScript`), no editing of the code under review.
    public static func allowedTools(scratch: String, bbget: String? = nil) -> [String] {
        let gitRead = ["log", "diff", "show", "merge-base", "rev-parse", "status", "ls-files", "ls-tree", "cat-file", "grep",
                       "blame", "branch --show-current", "branch -r", "branch -a", "branch --list", "branch --contains", "remote get-url", "shortlog", "describe", "name-rev", "for-each-ref"]
        // `//path` is an absolute path in a permission rule (a single `/` is relative to the project).
        var tools = ["Read", "Grep", "Glob", "Agent", "TodoWrite",
                     "Write(/\(scratch)/**)", "Edit(/\(scratch)/**)"]
        // `git -C <dir> <sub> …` needs the wildcard form (`*` mid-pattern); `:*` only ends a prefix.
        for sub in gitRead {
            tools.append("Bash(git \(sub):*)")
            tools.append("Bash(git -C * \(sub) *)")
            tools.append("Bash(git -C * \(sub))")
        }
        tools += ["Bash(git fetch:*)", "Bash(git -C * fetch *)",
                  "Bash(git worktree add:*)", "Bash(git -C * worktree add *)",
                  "Bash(git worktree remove:*)", "Bash(git -C * worktree remove *)",
                  "Bash(git worktree list:*)", "Bash(git worktree prune:*)", "Bash(cd:*)",
                  "Bash(\(bbget ?? scratch + "/bbget") *)",
                  "Bash(mkdir -p \(scratch)/*)", "Bash(mkdir -p \(scratch))"]
        for tool in ["ls", "wc", "head", "tail", "cat", "rg", "grep", "jq", "sort", "uniq", "cut", "tr", "sed -n", "awk", "diff", "stat", "date", "pwd", "echo", "basename", "dirname"] {
            tools.append("Bash(\(tool):*)")
        }
        return tools
    }

    /// Forms of `git branch` that change something; a deny rule beats the allowed listing forms
    /// (`branch -r -d x` would otherwise match `branch -r *`).
    public static let deniedTools: [String] = {
        let flags = ["-d", "-D", "-m", "-M", "-c", "-C", "-f", "-u", "--delete", "--move", "--copy", "--force", "--set-upstream-to*", "--unset-upstream*",
                     "--edit-description*", "--track*", "--no-track*"]
        return flags.flatMap { ["Bash(git branch \($0):*)", "Bash(git branch * \($0) *)", "Bash(git branch * \($0))",
                                         "Bash(git -C * branch \($0) *)", "Bash(git -C * branch \($0))", "Bash(git -C * branch * \($0) *)", "Bash(git -C * branch * \($0))"] }
    }()

    /// Where the helper lives: a path with no space (a permission rule for a command cannot match
    /// a quoted path with spaces, and the scratch folder is under "Application Support"), outside
    /// the scratch folder; it is the same file for every run.
    public static func bbGetPath(home: String) -> String { home + "/.claude/notch/bin/bbget" }

    /// A permission rule refuses `$VAR` in a command, so the Bitbucket token cannot be put on a
    /// `curl` line. This wrapper, written into the review's scratch folder, reads it from the
    /// environment itself (the token is never in the file), does GET only and only against the
    /// Bitbucket API.
    public static let bbGetScript = """
    #!/bin/sh
    case "$1" in
      https://api.bitbucket.org/2.0/*) ;;
      *) echo "bbget: only https://api.bitbucket.org/2.0/ urls" >&2; exit 2 ;;
    esac
    [ -n "$BB_API_TOKEN" ] || { echo "bbget: no token" >&2; exit 2; }
    if [ -n "$2" ]; then
      # A bare file name: saved in the review's scratch folder, never anywhere else.
      case "$2" in
        */*|.*) echo "bbget: the output is a plain file name" >&2; exit 2 ;;
      esac
      [ -d "$AI_NOTCH_REVIEW_DIR" ] || { echo "bbget: no scratch folder" >&2; exit 2; }
      exec curl -s -H "Authorization: Bearer $BB_API_TOKEN" -o "$AI_NOTCH_REVIEW_DIR/$2" "$1"
    fi
    exec curl -s -H "Authorization: Bearer $BB_API_TOKEN" "$1"

    """

    /// The prompt: the skill's own text (read from its file at run time), its input, and the
    /// limits of a headless run. The skill is passed as text, not by name, because the run loads
    /// no user settings (see `arguments`) and with them goes user-level skill discovery.
    public static func prompt(prNumber: Int, scratch: String, skill: String, bbget: String? = nil, branch: BranchTarget? = nil) -> String {
        let input = branch.map { b in
            "INPUT: no pull request exists yet. Review the branch `\(b.branch)` at commit \(b.head) against `\(b.target)`: the changes are `git diff \(b.target)...\(b.head)` (use `git merge-base` and the commit log of that range). Skip every step that reads the pull request, its description, its comments, its tasks or its pipeline from Bitbucket; there is no CI line. The checkout is the commit above."
        } ?? "INPUT: PR number \(prNumber)."
        return """
        \(ReviewAgents.body(of: skill))

        ---
        \(input)
        Headless run started by AI Notch. Bitbucket: `curl` and `$BB_API_TOKEN` are not available here; read the Bitbucket API (GET only) with `\(bbget ?? scratch + "/bbget") <url> [file-name]`, which sends the token itself; with a plain file name (no folder) the response is saved in \(scratch) under that name, to Read. Run every shell command with literal paths and values: no shell variables (`$X`), assignments, command substitution, loops or `&&` chains, because the run refuses them; take a value (a sha, a branch name) from a command's output and write it into the next command. Read several files with one Read call each, not a loop. Give each subagent the same instructions. Stay inside the worktree and \(scratch): do not `ls`, `cat` or search any other folder (no parent folders, no sibling repositories). Put any path that has special characters, such as ( ) [ ] { } spaces or `*`, in single quotes, for example `git -C <worktree> diff <a> <b> -- 'apps/app/(tabs)/index.tsx'`. Use \(scratch) as the scratch folder. Review only: do not post, comment, approve, request changes, commit, push or edit anything in the repository, and do not ask questions. Finish with the report from step 4, ending in the VERDICT line.

        \(ReviewChat.commentsInstruction(scratch: scratch))
        """
    }

    /// Folders outside the repository the review reads or writes: its scratch folder and the skill's files.
    public static func extraDirectories(scratch: String, home: String, skill: String = ReviewNames.defaultSkill) -> [String] {
        [scratch, home + "/.claude/skills/" + skill]
    }

    /// The notch's hook on the events that only report (the notch folds them into the session's
    /// row); `--settings` adds nothing else, so the review's permissions stay the allow-list. Not
    /// included, because the hook can answer them: PreToolUse (pause, notes, context) and
    /// PermissionRequest (an approval). The hook prints nothing on any of these events.
    public static let observedEvents = ["SessionStart", "UserPromptSubmit", "PostToolUse", "PostToolUseFailure",
                                        "SubagentStart", "SubagentStop", "Stop", "StopFailure", "SessionEnd"]

    public static func observeHooksJSON(command: String) -> String {
        var hooks: [String: Any] = [:]
        for event in observedEvents {
            hooks[event] = [["hooks": [["type": "command", "command": command, "timeout": 5]]]]
        }
        let data = (try? JSONSerialization.data(withJSONObject: ["hooks": hooks], options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// `--setting-sources ""` loads none of the user's, project's or local settings: the user's
    /// own allow rules (git commit, checkout, MCP writes, Edit on skill files) must not widen a
    /// review that reads other people's code. `--agents` supplies the lens and verifier
    /// subagents, which user-level discovery would otherwise have provided.
    public static func arguments(prNumber: Int, scratch: String, skill: String, agentsJSON: String, hookCommand: String? = nil, home: String = NSHomeDirectory(), skillName: String = ReviewNames.defaultSkill, branch: BranchTarget? = nil) -> [String] {
        let bbget = bbGetPath(home: home)
        return ["-p", prompt(prNumber: prNumber, scratch: scratch, skill: skill, bbget: bbget, branch: branch),
         "--model", ReviewModels.full,
         "--setting-sources", ""] + (hookCommand.map { ["--settings", observeHooksJSON(command: $0)] } ?? []) + [
         "--agents", agentsJSON,
         "--add-dir"] + extraDirectories(scratch: scratch, home: home, skill: skillName) + [
         "--output-format", "json",
         "--permission-mode", "dontAsk",
         "--allowedTools", allowedTools(scratch: scratch, bbget: bbget).joined(separator: ","),
         "--disallowedTools", deniedTools.joined(separator: ",")]
    }
}

public enum ReviewAgents {
    /// A markdown file split into its `key: value` front matter and its body.
    public static func parts(of file: String) -> (meta: [String: String], body: String) {
        let lines = file.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---", let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            return ([:], file)
        }
        var meta: [String: String] = [:]
        for line in lines[1..<end] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            meta[line[..<colon].trimmingCharacters(in: .whitespaces)] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return (meta, lines[(end + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public static func body(of file: String) -> String { parts(of: file).body }

    /// `--agents` JSON from agent files: {name: {description, prompt, tools, model}}.
    public static func json(files: [String]) -> String {
        var agents: [String: [String: Any]] = [:]
        for file in files {
            let (meta, body) = parts(of: file)
            guard let name = meta["name"], !body.isEmpty else { continue }
            var agent: [String: Any] = ["description": meta["description"] ?? name, "prompt": body]
            // Reports are written with the Write tool (allowed only inside the review's folder),
            // since a shell redirect or heredoc is not on the allow-list.
            if let tools = meta["tools"] {
                var list = tools.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                if !list.contains("Write") { list.append("Write") }
                agent["tools"] = list
            }
            if let model = meta["model"] { agent["model"] = model }
            agents[name] = agent
        }
        let data = (try? JSONSerialization.data(withJSONObject: agents, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}


/// The names of the review skill and its two subagents, in the user's own Claude setup
/// (`~/.claude/skills/<skill>/SKILL.md`, `~/.claude/agents/<lens>.md` and `<verifier>.md`). Kept
/// in this app's local preferences, never in the repository.
public struct ReviewNames: Equatable, Sendable {
    public static let defaultSkill = "pr-review"
    public static let defaultLens = "pr-lens"
    public static let defaultVerifier = "pr-verifier"
    public static let skillKey = "review.skillName", lensKey = "review.lensName", verifierKey = "review.verifierName"

    public var skill: String
    public var lens: String
    public var verifier: String

    public init(skill: String = defaultSkill, lens: String = defaultLens, verifier: String = defaultVerifier) {
        self.skill = Self.clean(skill, fallback: Self.defaultSkill)
        self.lens = Self.clean(lens, fallback: Self.defaultLens)
        self.verifier = Self.clean(verifier, fallback: Self.defaultVerifier)
    }

    /// A file-safe name: letters, digits, `-`, `_`, `.`; anything else (a path, spaces) falls back to the default.
    public static func clean(_ raw: String, fallback: String) -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let ok = !name.isEmpty && !name.hasPrefix(".") && name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0) }
        return ok ? name : fallback
    }

    public static func load(_ defaults: UserDefaults = .standard) -> ReviewNames {
        ReviewNames(skill: defaults.string(forKey: skillKey) ?? defaultSkill, lens: defaults.string(forKey: lensKey) ?? defaultLens,
                    verifier: defaults.string(forKey: verifierKey) ?? defaultVerifier)
    }

    public func save(_ defaults: UserDefaults = .standard) {
        defaults.set(skill, forKey: Self.skillKey)
        defaults.set(lens, forKey: Self.lensKey)
        defaults.set(verifier, forKey: Self.verifierKey)
    }
}


/// The repositories reviewed automatically: a local setting, empty by default (no automatic
/// review until the user picks some). "Review now" is not limited by it. An entry is a repository
/// name (`api-service`) or `workspace/name`; matching ignores case.
public struct ReviewRepos: Equatable, Sendable {
    public static let key = "review.autoRepos"
    public var entries: [String]

    public init(entries: [String] = []) { self.entries = entries }

    /// "a, b" or one per line.
    public init(text: String) {
        entries = text.split(whereSeparator: { ",;\n".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    public var text: String { entries.joined(separator: ", ") }

    /// `key` is "<workspace>/<repo>#<id>" (or "<workspace>/<repo>").
    public func allows(key: String) -> Bool {
        let repo = key.split(separator: "#", maxSplits: 1).first.map(String.init) ?? key
        let name = repo.split(separator: "/").last.map(String.init) ?? repo
        return entries.contains { $0.caseInsensitiveCompare(repo) == .orderedSame || $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    public static func load(_ defaults: UserDefaults = .standard) -> ReviewRepos { ReviewRepos(text: defaults.string(forKey: key) ?? "") }
    public func save(_ defaults: UserDefaults = .standard) { defaults.set(text, forKey: Self.key) }
}
