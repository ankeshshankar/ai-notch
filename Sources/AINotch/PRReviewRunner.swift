import Foundation
import ReviewCore

/// One headless review: `claude -p "/homes-pr-review <n>"` in the repository's clone, through
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

    private func run(_ job: Job) -> Outcome {
        guard let claude = UsageProbe.executable else { return .failed("claude is not installed") }
        let fm = FileManager.default
        try? fm.createDirectory(at: job.dir, withIntermediateDirectories: true)
        let out = job.dir.appendingPathComponent("out.json"), err = job.dir.appendingPathComponent("err.log")
        fm.createFile(atPath: out.path, contents: nil)
        fm.createFile(atPath: err.path, contents: nil)
        guard let outHandle = try? FileHandle(forWritingTo: out), let errHandle = try? FileHandle(forWritingTo: err) else {
            return .failed("cannot write in \(job.dir.path)")
        }
        defer { try? outHandle.close(); try? errHandle.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: claude)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard let skill = try? String(contentsOfFile: home + "/.claude/skills/homes-pr-review/SKILL.md", encoding: .utf8) else {
            return .failed("the homes-pr-review skill is not installed")
        }
        let agents = ["homes-pr-lens", "homes-pr-verifier"].compactMap { try? String(contentsOfFile: home + "/.claude/agents/\($0).md", encoding: .utf8) }
        guard agents.count == 2 else { return .failed("the homes-pr-lens or homes-pr-verifier agent is missing") }
        process.arguments = ReviewCommand.arguments(prNumber: job.ref.id, scratch: job.dir.path, skill: skill, agentsJSON: ReviewAgents.json(files: agents))
        process.currentDirectoryURL = URL(fileURLWithPath: job.repoPath, isDirectory: true)
        process.environment = Self.environment(token: job.token)
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
        Self.removeWorktree(repo: job.repoPath, dir: job.dir)

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

    /// The child's environment: ours without API keys, a PATH that finds git and curl, the
    /// read token, and the markers the hook looks for.
    static func environment(token: String) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for key in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN"] { env[key] = nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"].joined(separator: ":")
        env["BB_API_TOKEN"] = token
        env["AI_NOTCH_NO_APPROVALS"] = "1"
        env["AI_NOTCH_REVIEW"] = "1"
        return env
    }

    /// The skill's scratch worktree, when a stop or a crash left it behind.
    private static func removeWorktree(repo: String, dir: URL) {
        let worktree = dir.appendingPathComponent("wt").path
        guard FileManager.default.fileExists(atPath: worktree) else { return }
        _ = runProcess("/usr/bin/git", ["-C", repo, "worktree", "remove", "--force", worktree], timeout: 30)
        _ = runProcess("/usr/bin/git", ["-C", repo, "worktree", "prune"], timeout: 30)
    }
}
