import Foundation
import ReviewCore

/// One chat turn: `claude -p --resume <the review's session>` with the review's own read-only
/// tools, settings and folders (`ReviewChat.arguments`), the message on standard input, the
/// answer streamed as stream-json. The same login as the review (an API key in the environment
/// is removed), the Bitbucket READ token only through the environment, nothing posted: the chat
/// can read and say, and write only inside the review's folder.
///
/// Resume keeps the session id (no `--fork-session`): every turn continues the one session, so
/// the id stored after the review stays the one to resume. It is started in the repository's
/// clone, as the review was; the review's scratch worktree (`wt`) is recreated at the reviewed
/// commit when it is gone, and removed again after the turn if this turn made it.
final class PRChatRunner: @unchecked Sendable {
    struct Job: Sendable {
        var ref: PullRequestRef
        var head: String
        var repoPath: String
        var dir: URL
        var sessionID: String
        var prompt: String
        var system: String
        /// Read in the background: the Keychain lookup runs a child process.
        var token: @Sendable () -> String
    }

    enum Outcome: Sendable {
        case finished(ChatResult)
        case failed(String)
        case cancelled
        case timedOut
    }

    static let timeout: Double = 15 * 60

    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var timedOut = false
    private var buffer = Data()

    func start(_ job: Job, onEvent: @escaping @Sendable (ChatEvent) -> Void, done: @escaping @Sendable (Outcome) -> Void) {
        DispatchQueue.global(qos: .utility).async { [self] in done(run(job, onEvent: onEvent)) }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let process = self.process
        lock.unlock()
        if let process, process.isRunning {
            process.terminate()
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { if process.isRunning { kill(pid, SIGKILL) } }
        }
    }

    private func run(_ job: Job, onEvent: @escaping @Sendable (ChatEvent) -> Void) -> Outcome {
        guard let claude = UsageProbe.executable else { return .failed("claude is not installed") }
        let fm = FileManager.default
        try? fm.createDirectory(at: job.dir, withIntermediateDirectories: true)
        PRReviewRunner.installHelper()
        let home = fm.homeDirectoryForCurrentUser.path
        let names = ReviewNames.load()
        let agents = [names.lens, names.verifier].compactMap { try? String(contentsOfFile: home + "/.claude/agents/\($0).md", encoding: .utf8) }
        let agentsJSON = agents.count == 2 ? ReviewAgents.json(files: agents) : nil
        let madeWorktree = Self.ensureWorktree(repo: job.repoPath, dir: job.dir, head: job.head)
        defer { if madeWorktree { PRReviewRunner.removeWorktree(repo: job.repoPath, dir: job.dir) } }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: claude)
        process.arguments = ReviewChat.arguments(sessionID: job.sessionID, scratch: job.dir.path, systemPrompt: job.system, agentsJSON: agentsJSON,
                                                 hookCommand: PRReviewRunner.hookCommand(), skillName: names.skill)
        process.currentDirectoryURL = URL(fileURLWithPath: job.repoPath, isDirectory: true)
        process.environment = PRReviewRunner.environment(token: job.token(), dir: job.dir.path, title: "PR chat #\(job.ref.id) · \(job.ref.repo)")
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        let errURL = job.dir.appendingPathComponent("chat-err.log")
        fm.createFile(atPath: errURL.path, contents: nil)
        let errHandle = try? FileHandle(forWritingTo: errURL)
        process.standardError = errHandle ?? FileHandle.nullDevice
        defer { try? errHandle?.close() }

        var result: ChatResult?
        let resultLock = NSLock()
        func consume(_ data: Data) {
            lock.lock()
            buffer.append(data)
            var lines: [Data] = []
            while let newline = buffer.firstIndex(of: 0x0A) {
                lines.append(buffer.subdata(in: buffer.startIndex..<newline))
                buffer.removeSubrange(buffer.startIndex...newline)
            }
            lock.unlock()
            for line in lines {
                for event in ChatStream.events(line: String(decoding: line, as: UTF8.self)) {
                    if case .result(let value) = event { resultLock.lock(); result = value; resultLock.unlock() }
                    onEvent(event)
                }
            }
        }
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { consume(data) }
        }

        lock.lock()
        if cancelled { lock.unlock(); return .cancelled }
        do { try process.run() } catch { lock.unlock(); return .failed("could not start claude") }
        self.process = process
        lock.unlock()
        input.fileHandleForWriting.write(Data(job.prompt.utf8))
        try? input.fileHandleForWriting.close()

        let watchdog = DispatchWorkItem { [weak self] in
            guard let self, process.isRunning else { return }
            self.lock.lock(); self.timedOut = true; self.lock.unlock()
            process.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.timeout, execute: watchdog)
        process.waitUntilExit()
        watchdog.cancel()
        output.fileHandleForReading.readabilityHandler = nil
        if let rest = try? output.fileHandleForReading.readToEnd(), !rest.isEmpty { consume(rest + Data("\n".utf8)) }

        lock.lock()
        let wasCancelled = cancelled, wasTimedOut = timedOut
        lock.unlock()
        if wasCancelled { return .cancelled }
        if wasTimedOut { return .timedOut }
        resultLock.lock(); defer { resultLock.unlock() }
        guard let result else { return .failed(process.terminationStatus == 0 ? "claude's answer could not be read" : "claude stopped (exit \(process.terminationStatus))") }
        return .finished(result)
    }

    /// The review's `wt` at the reviewed commit, made when it is gone. True when this call made it.
    static func ensureWorktree(repo: String, dir: URL, head: String) -> Bool {
        let worktree = dir.appendingPathComponent("wt").path
        guard !FileManager.default.fileExists(atPath: worktree) else { return false }
        _ = runProcess("/usr/bin/git", ["-C", repo, "worktree", "prune"], timeout: 30)
        if let added = runProcess("/usr/bin/git", ["-C", repo, "worktree", "add", "--detach", worktree, head], timeout: 60), added.status == 0 { return true }
        // The commit may not be in the clone yet.
        _ = runProcess("/usr/bin/git", ["-C", repo, "fetch", "--quiet", "origin"], timeout: 120)
        if let added = runProcess("/usr/bin/git", ["-C", repo, "worktree", "add", "--detach", worktree, head], timeout: 60), added.status == 0 { return true }
        return false
    }
}

/// The chat, the cards and the posting of one pull request's review, on the main thread. Kept in
/// the review's folder as `chat.json`, so it survives a restart.
@MainActor
final class PRChatSession: ObservableObject {
    let ref: PullRequestRef
    let head: String
    let folder: URL

    @Published private(set) var log = ChatLog()
    @Published private(set) var reportText = ""
    @Published private(set) var existing: [ExistingComment] = []
    @Published private(set) var existingLoaded = false
    /// The reply so far, with comment blocks hidden.
    @Published private(set) var streaming = ""
    @Published private(set) var activity: String?
    @Published private(set) var running = false
    @Published private(set) var drafting = false
    @Published private(set) var posting = false
    @Published private(set) var notice: String?
    /// The review had its tools refused during a chat turn.
    @Published private(set) var denied: [String] = []

    private var rawStream = ""
    private var runner: PRChatRunner?
    private var stopped = false

    /// Where the repository is cloned (nil: the chat cannot run, the cards still work).
    var repoPath: () -> String? = { nil }
    var token: @Sendable () -> String = { KeychainItem.read(service: BitbucketConfig.tokenService)?.secret ?? "" }

    init(ref: PullRequestRef, head: String, folder: URL) {
        self.ref = ref
        self.head = head
        self.folder = folder
        load()
    }

    var cards: [SuggestedComment] { log.cards }
    var sessionID: String? { log.sessionID }
    var canChat: Bool { log.sessionID != nil }
    /// A finished review that has no `comments.json` yet: the cards can be drafted from its session.
    var needsDraft: Bool { !log.seeded && canChat && !reportText.isEmpty }

    // MARK: Files

    private var chatURL: URL { folder.appendingPathComponent("chat.json") }

    private func load() {
        if let data = try? Data(contentsOf: chatURL), let loaded = try? JSONDecoder().decode(ChatLog.self, from: data) { log = loaded }
        reportText = (try? String(contentsOfFile: folder.appendingPathComponent("report.md").path, encoding: .utf8)) ?? ""
        if log.sessionID == nil, let data = try? Data(contentsOf: folder.appendingPathComponent("out.json")),
           let id = ReviewOutput.parse(data)?.sessionID { log.sessionID = id }
        readComments()
        if log.messages.contains(where: { $0.isError && $0.text == Self.interruptedText }) == false,
           let last = log.messages.last, last.role == .user, !running {
            // A turn the notch quit in the middle of: say so, the question stays.
            log.messages.append(ChatMessage(role: .assistant, text: Self.interruptedText, at: Date().timeIntervalSince1970, isError: true))
        }
        save()
    }

    private static let interruptedText = "This turn was interrupted (the notch quit). Ask again."

    /// `comments.json`, once: the review's own findings as cards.
    private func readComments() {
        guard !log.seeded, let data = try? Data(contentsOf: folder.appendingPathComponent("comments.json")) else { return }
        log.seed(CommentParse.file(data))
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard let data = try? encoder.encode(log) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: chatURL, options: .atomic)
    }

    // MARK: Existing comments

    func loadExisting() {
        Task { @MainActor in
            if let comments = await PRReviewAPI.comments(ref) { existing = comments; existingLoaded = true }
        }
    }

    func duplicate(of card: SuggestedComment) -> ExistingComment? { CommentDedupe.duplicate(of: card, in: existing) }

    // MARK: Cards

    func setInclude(_ id: String, _ on: Bool) {
        guard let index = log.cards.firstIndex(where: { $0.id == id }), !log.cards[index].isPosted else { return }
        log.cards[index].include = on
        save()
    }

    func setBody(_ id: String, _ text: String) {
        guard let index = log.cards.firstIndex(where: { $0.id == id }), !log.cards[index].isPosted else { return }
        log.cards[index].body = text
        log.cards[index].badge = log.cards[index].badge == "new" ? "new" : nil
        save()
    }

    func card(_ id: String) -> SuggestedComment? { log.cards.first { $0.id == id } }

    // MARK: Posting

    /// Posts what `PostPlan.pending` lists, one at a time, recording each comment's id the moment
    /// it exists; stops at the first failure. Only ever called after the confirm.
    func postPending() async {
        guard !posting else { return }
        let blocked = PostPlan.blocked(log.cards)
        guard blocked.isEmpty else { notice = "Not posted: reword the flagged comments first"; return }
        posting = true
        notice = nil
        defer { posting = false }
        var count = 0
        for card in PostPlan.pending(log.cards) {
            switch await PRReviewAPI.post(card, to: ref) {
            case .posted(let id):
                if let index = log.cards.firstIndex(where: { $0.id == card.id }) {
                    log.cards[index].postedID = id
                    log.cards[index].postedAt = Date().timeIntervalSince1970
                    log.cards[index].badge = nil
                }
                count += 1
                save()
            case .failed(let why):
                notice = "Posted \(count), then stopped: \(why)"
                if count > 0 { loadExisting() }
                return
            }
        }
        notice = count == 1 ? "Posted 1 comment" : "Posted \(count) comments"
        loadExisting()
    }

    // MARK: Chat

    func send(_ text: String) {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, !running else { return }
        log.messages.append(ChatMessage(role: .user, text: message, at: Date().timeIntervalSince1970))
        save()
        turn(prompt: message, drafting: false)
    }

    /// "Draft comments": the resumed session writes `comments.json` for a review that predates it.
    func draftComments() {
        guard !running, canChat else { return }
        turn(prompt: ReviewChat.draftPrompt(scratch: folder.path), drafting: true)
    }

    func stop() {
        guard running else { return }
        stopped = true
        runner?.cancel()
    }

    private func turn(prompt: String, drafting: Bool) {
        guard let sessionID = log.sessionID else { notice = "No session to continue: use Re-review"; return }
        guard let repo = repoPath() else { notice = "No local clone of \(ref.repo) in the repositories list"; return }
        running = true
        self.drafting = drafting
        stopped = false
        notice = nil
        denied = []
        streaming = ""
        rawStream = ""
        activity = "Thinking…"
        let system = ReviewChat.systemPrompt(cards: log.cards, existing: existing, head: head, scratch: folder.path)
        let job = PRChatRunner.Job(ref: ref, head: head, repoPath: repo, dir: folder, sessionID: sessionID, prompt: drafting ? prompt : ReviewChat.turnPrompt(prompt), system: system, token: token)
        let runner = PRChatRunner()
        self.runner = runner
        runner.start(job, onEvent: { [weak self] event in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(event) } }
        }, done: { [weak self] outcome in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.finish(outcome, drafting: drafting) } }
        })
    }

    private func handle(_ event: ChatEvent) {
        switch event {
        case .session(let id): if log.sessionID != id { log.sessionID = id }
        case .textDelta(let text):
            rawStream += text
            streaming = CommentBlocks.parse(rawStream).prose
            activity = nil
        case .tool(let name): activity = name
        case .result: break
        }
    }

    private func finish(_ outcome: PRChatRunner.Outcome, drafting wasDrafting: Bool) {
        running = false
        drafting = false
        runner = nil
        activity = nil
        let now = Date().timeIntervalSince1970
        defer { streaming = ""; rawStream = ""; save() }
        switch outcome {
        case .cancelled:
            log.messages.append(ChatMessage(role: .assistant, text: "Stopped.", at: now, isError: true))
        case .timedOut:
            log.messages.append(ChatMessage(role: .assistant, text: "Stopped after \(Int(PRChatRunner.timeout / 60)) minutes.", at: now, isError: true))
        case .failed(let why):
            log.messages.append(ChatMessage(role: .assistant, text: "This turn failed: \(why)", at: now, isError: true))
        case .finished(let result):
            if let id = result.sessionID, id != log.sessionID { log.sessionID = id }
            denied = result.denied
            if wasDrafting {
                let before = log.cards.count
                if let data = try? Data(contentsOf: folder.appendingPathComponent("comments.json")) {
                    log.seed(CommentParse.file(data))
                    notice = log.cards.isEmpty ? "No comments to draft" : "Drafted \(log.cards.count) comment\(log.cards.count == 1 ? "" : "s")"
                } else {
                    notice = result.isError ? "Drafting failed: \(String(result.text.prefix(120)))" : "Drafting wrote no comments"
                    _ = before
                }
                return
            }
            let text = result.text.isEmpty ? rawStream : result.text
            let parsed = CommentBlocks.parse(text)
            let touched = log.apply(parsed.drafts)
            var prose = parsed.prose
            if prose.isEmpty { prose = touched.new.isEmpty && touched.revised.isEmpty ? "(no reply)" : "Done." }
            if parsed.skipped > 0 { notice = "\(parsed.skipped) proposed comment\(parsed.skipped == 1 ? "" : "s") could not be read" }
            log.messages.append(ChatMessage(role: .assistant, text: prose, at: now, newCards: touched.new, revisedCards: touched.revised, isError: result.isError))
            if !result.denied.isEmpty { notice = "A tool was refused: \(result.denied.joined(separator: ", "))" }
        }
    }
}
