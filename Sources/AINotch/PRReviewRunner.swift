import Foundation
import ReviewCore

/// One headless review: `claude -p` with the review skill's text in the repository's clone, through
/// the user's own Claude login (the subscription CLI; an API key in the environment is removed,
/// so it never bills the API). The Bitbucket READ token reaches the child through its
/// environment only (`BB_API_TOKEN`, what the skill's curl calls use): it is never in the
/// arguments, a file or a log.
///
/// Permissions: no user, project or local settings are loaded (the user's own allow rules would
/// widen the run), `--permission-mode dontAsk` plus the allow-list in `ReviewCommand`. Anything
/// outside it is refused on the spot, with no prompt (and `AI_NOTCH_NO_APPROVALS=1` keeps the
/// notch's own approval prompt out of it). A review that needed a refused tool is marked failed
/// and names the tool, rather than carrying on half blind.
final class PRReviewRunner: @unchecked Sendable {
    struct Job: Sendable {
        var ref: PullRequestRef
        var head: String
        var repoPath: String
        var dir: URL
        var token: String
        /// A follow-up on new commits (one focused pass) instead of the full multi-lens review.
        var followUp: FollowUpJob? = nil
        /// A branch with no pull request yet.
        var branch: BranchTarget? = nil
        /// A read of the author's replies (one fresh read-only pass in the review's folder, output kept apart from the review's).
        var replyRead: ReplyReadJob? = nil
    }

    struct ReplyReadJob: Sendable {
        var inputJSON: Data
    }

    /// What a follow-up pass is given: the commit the last review covered and the input file's content.
    struct FollowUpJob: Sendable {
        var baseHead: String
        var inputJSON: Data
        /// The input carries reply threads: the pass is asked to read them too.
        var readReplies = false
    }

    enum Outcome: Sendable {
        case finished(ReviewOutput)
        case failed(String)
        case cancelled
        case timedOut
    }

    static let timeout: Double = 30 * 60
    static var timeoutOverride: Double? { ProcessInfo.processInfo.environment["CLAUDE_NOTCH_REVIEW_TIMEOUT"].flatMap(Double.init) }

    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var timedOut = false

    func start(_ job: Job, done: @escaping @Sendable (Outcome) -> Void) {
        DispatchQueue.global(qos: .utility).async { [self] in done(run(job)) }
    }

    /// Dev only: the run, on this thread.
    func runSync(_ job: Job) -> Outcome { run(job) }

    func cancel() {
        lock.lock()
        cancelled = true
        let process = self.process
        lock.unlock()
        if let process, process.isRunning { stop(process) }
    }

    /// SIGTERM, then SIGKILL if it is still there 5 seconds later.
    private func stop(_ process: Process) {
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { if process.isRunning { kill(pid, SIGKILL) } }
    }

    /// One pass at a time per review folder and output file (a review or follow-up, a reply read): two runs writing
    /// the same `out.json` and `followup.json` would leave files of one run next to the verdict of the other.
    private static let busyLock = NSLock()
    nonisolated(unsafe) private static var busy: Set<String> = []

    static func claim(_ job: Job) -> String? {
        let key = job.dir.standardizedFileURL.path + (job.replyRead != nil ? "#reply" : "#run")
        busyLock.lock(); defer { busyLock.unlock() }
        return busy.insert(key).inserted ? key : nil
    }

    static func release(_ key: String) { busyLock.lock(); busy.remove(key); busyLock.unlock() }

    private func run(_ job: Job) -> Outcome {
        if PRReviewStore.isDevRun, PRReviewStore.isRealFolder(job.dir) { return .failed("a dev run never writes in the real review folders") }
        guard let slot = Self.claim(job) else { return .failed("a pass is already running for this commit") }
        defer { Self.release(slot) }
        return runClaimed(job)
    }

    private func runClaimed(_ job: Job) -> Outcome {
        guard let claude = UsageProbe.executable else { return .failed("claude is not installed") }
        let fm = FileManager.default
        try? fm.createDirectory(at: job.dir, withIntermediateDirectories: true)
        Self.installHelper()
        let prefix = job.replyRead != nil ? "reply-" : ""
        let out = job.dir.appendingPathComponent(prefix + "out.json"), err = job.dir.appendingPathComponent(prefix + "err.log")
        fm.createFile(atPath: out.path, contents: nil)
        fm.createFile(atPath: err.path, contents: nil)
        guard let outHandle = try? FileHandle(forWritingTo: out), let errHandle = try? FileHandle(forWritingTo: err) else {
            return .failed("cannot write in \(job.dir.path)")
        }
        defer { try? outHandle.close(); try? errHandle.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: claude)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let names = ReviewNames.load()
        var madeWorktree = false
        if let read = job.replyRead {
            do { try read.inputJSON.write(to: job.dir.appendingPathComponent("reply-input.json")) } catch { return .failed("cannot write in \(job.dir.path)") }
            madeWorktree = PRChatRunner.ensureWorktree(repo: job.repoPath, dir: job.dir, head: job.head)
            process.arguments = FollowUp.arguments(scratch: job.dir.path, hookCommand: Self.hookCommand(), prompt: ReplyRead.prompt(scratch: job.dir.path, head: job.head))
        } else if let followUp = job.followUp {
            switch Self.prepareFollowUp(job, followUp) {
            case .success(let prompt):
                process.arguments = FollowUp.arguments(scratch: job.dir.path, hookCommand: Self.hookCommand(), prompt: prompt)
            case .failure(let failure):
                return .failed(failure.message)
            }
        } else {
            guard let skill = try? String(contentsOfFile: home + "/.claude/skills/\(names.skill)/SKILL.md", encoding: .utf8) else {
                return .failed("the \(names.skill) skill is not installed (Setup, Pull requests)")
            }
            let agents = [names.lens, names.verifier].compactMap { try? String(contentsOfFile: home + "/.claude/agents/\($0).md", encoding: .utf8) }
            guard agents.count == 2 else { return .failed("the \(names.lens) or \(names.verifier) agent is missing (Setup, Pull requests)") }
            if job.branch != nil { _ = PRChatRunner.ensureWorktree(repo: job.repoPath, dir: job.dir, head: job.branch!.head) }
            process.arguments = ReviewCommand.arguments(prNumber: job.ref.id, scratch: job.dir.path, skill: skill, agentsJSON: ReviewAgents.json(files: agents), hookCommand: Self.hookCommand(), skillName: names.skill, branch: job.branch)
        }
        process.currentDirectoryURL = URL(fileURLWithPath: job.repoPath, isDirectory: true)
        process.environment = Self.environment(token: job.token, dir: job.dir.path, title: "PR review #\(job.ref.id) · \(job.ref.repo)")
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outHandle
        process.standardError = errHandle

        lock.lock()
        if cancelled { lock.unlock(); return .cancelled }
        do { try process.run() } catch { lock.unlock(); return .failed("could not start claude") }
        self.process = process
        lock.unlock()

        let limit = Self.timeoutOverride ?? Self.timeout
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self, process.isRunning else { return }
            self.lock.lock(); self.timedOut = true; self.lock.unlock()
            self.stop(process)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + limit, execute: watchdog)
        process.waitUntilExit()
        watchdog.cancel()
        if job.replyRead == nil || madeWorktree { Self.removeWorktree(repo: job.repoPath, dir: job.dir) }

        lock.lock()
        let wasCancelled = cancelled, wasTimedOut = timedOut
        lock.unlock()
        if wasCancelled { return .cancelled }
        if wasTimedOut { return .timedOut }
        let data = (try? Data(contentsOf: out)) ?? Data()
        guard let output = ReviewOutput.parse(data) else {
            return .failed(process.terminationStatus == 0 ? "claude's answer could not be read" : "claude stopped (exit \(process.terminationStatus))")
        }
        return .finished(output)
    }

    /// The follow-up's files in the review folder (input, diff of the new commits, the checkout at the new head)
    /// and its prompt. Reads git only; the diff is cut at 300 KB.
    private static func prepareFollowUp(_ job: Job, _ followUp: FollowUpJob) -> Result<String, FailText> {
        let repo = job.repoPath
        func git(_ args: [String], timeout: Double = 60) -> ProcessResult? { runProcess("/usr/bin/git", ["-C", repo] + args, timeout: timeout) }
        func has(_ sha: String) -> Bool { git(["cat-file", "-e", sha + "^{commit}"])?.status == 0 }
        if !has(followUp.baseHead) || !has(job.head) { _ = git(["fetch", "--quiet", "origin"], timeout: 180) }
        guard has(job.head) else { return .failure(FailText("the new commit is not in the local clone")) }
        let range = has(followUp.baseHead) ? "\(followUp.baseHead)..\(job.head)" : "\(job.head)~1..\(job.head)"
        var diff = git(["diff", "--no-color", "--stat", "-p", range], timeout: 120)?.output ?? Data()
        let cut = diff.count > 300_000
        if cut { diff = diff.prefix(300_000) }
        try? FileManager.default.removeItem(at: job.dir.appendingPathComponent("followup.json"))
        do {
            try diff.write(to: job.dir.appendingPathComponent("followup.diff"))
            try followUp.inputJSON.write(to: job.dir.appendingPathComponent("followup-input.json"))
        } catch { return .failure(FailText("cannot write in \(job.dir.path)")) }
        _ = PRChatRunner.ensureWorktree(repo: repo, dir: job.dir, head: job.head)
        return .success(FollowUp.prompt(scratch: job.dir.path, previousHead: followUp.baseHead, newHead: job.head, diffCut: cut, readReplies: followUp.readReplies))
    }

    struct FailText: Error { var message: String; init(_ message: String) { self.message = message } }

    /// The child's environment: ours without API keys, a PATH that finds git and curl, the
    /// read token, and the markers the hook looks for.
    /// The hook beside this app's executable (the installed one when run from a build folder).
    static func hookCommand() -> String? {
        let beside = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("ai-notch-hook").path
        let installed = NSHomeDirectory() + "/Applications/AINotch.app/Contents/MacOS/ai-notch-hook"
        return [beside, installed].compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func environment(token: String, dir: String = "", title: String = "PR review") -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for key in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN"] { env[key] = nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"].joined(separator: ":")
        env["BB_API_TOKEN"] = token
        env["AI_NOTCH_REVIEW_DIR"] = dir
        env["AI_NOTCH_NO_APPROVALS"] = "1"
        env["AI_NOTCH_REVIEW"] = "1"
        env["AI_NOTCH_REVIEW_TITLE"] = title
        return env
    }

    /// The GET-only Bitbucket helper the review (and its chat) reads the API with.
    static func installHelper() {
        let fm = FileManager.default
        let helper = URL(fileURLWithPath: ReviewCommand.bbGetPath(home: NSHomeDirectory()))
        try? fm.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? ReviewCommand.bbGetScript.write(to: helper, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
    }

    /// The skill's scratch worktree, when a stop or a crash left it behind.
    static func removeWorktree(repo: String, dir: URL) {
        let worktree = dir.appendingPathComponent("wt").path
        guard FileManager.default.fileExists(atPath: worktree) else { return }
        _ = runProcess("/usr/bin/git", ["-C", repo, "worktree", "remove", "--force", worktree], timeout: 30)
        _ = runProcess("/usr/bin/git", ["-C", repo, "worktree", "prune"], timeout: 30)
    }
}
