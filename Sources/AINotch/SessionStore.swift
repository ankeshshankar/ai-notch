import AppKit
import Darwin
import NotchCore
import WidgetKit

/// The live sessions, read from the state files the hook writes, plus the alerts their changes raise.
@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [SessionState] = []
    @Published private(set) var now = Date().timeIntervalSince1970
    /// When a session last finished a turn, for the brief "done" flash.
    @Published private(set) var lastDoneAt: Double = 0
    /// When each running subagent last wrote to its transcript.
    @Published private(set) var agentActivity: [String: Double] = [:]
    /// The model each subagent's replies came from, read from its transcript.
    @Published private(set) var agentModels: [String: String] = [:]
    /// Tokens and cost from the transcripts: per session, per day.
    @Published private(set) var usage = UsageSnapshot()
    /// Lines committed per repository per day (repo root → day → lines), for comparison.
    @Published private(set) var gitLines: [String: [String: LineTally]] = [:]
    /// Claude Code's plan limits: from the status line (terminal sessions) or Claude Code's own
    /// usage request when that has said nothing lately.
    @Published private(set) var claudeLimits: ToolLimits?
    private var limitsMtime: Double = 0
    private var limitsCheckedAt: Double = 0
    private var probeStartedAt: Double = 0
    private var isProbing = false
    /// What each chat is called in its editor's list (by session id), read from its transcript.
    @Published private(set) var titles: [String: ChatTitles.Found] = [:]
    private let titleReader = ChatTitles()
    /// Agents without hooks, seen as processes.
    private let watcher = AgentWatcher()
    /// Permission prompts waiting for a click in the notch.
    let approvals = ApprovalCenter(preview: CommandLine.arguments.contains("--preview"))
    private var scanner: UsageScanner?
    private var git: GitStats?
    private var gitReadAt: Double = 0
    /// The widget's last snapshot, and when WidgetKit was last asked to reload (it has a daily budget).
    private var widgetRows: [WidgetSnapshot.Row] = []
    private var widgetReloadAt: Double = 0
    private var widgetReloadPending = false
    /// The widget's file in the app group; nil in an ad-hoc build (no app group, no widget).
    private lazy var widgetURL: URL? = WidgetSnapshot.url

    /// A session without a known process counts as gone after this long untouched.
    private let orphanAfter: Double = 3 * 3600
    /// A session whose process is gone stays until the check has failed this long on end, so one
    /// bad read of the process list never removes a live session, and until it has been quiet
    /// for `quietBeforeDrop`: a process still writing to its state file is not gone.
    private let goneAfter: Double = 1.5
    private let quietBeforeDrop: Double = 10
    /// When each session's process first failed its check (session id → time); forgotten once it passes.
    private var failingSince: [String: Double] = [:]
    /// A finished turn shorter than this plays no sound.
    private let soundAfterTurn: Double = 20
    private var phases: [String: Phase] = [:]
    /// What the end of each transcript says, cached by the file's modification time:
    /// the last interrupt, and the model of the last reply.
    private var tails: [String: (mtime: Double, interruptAt: Double?, model: String?)] = [:]
    private var timer: Timer?

    var working: [SessionState] { sessions.filter { $0.phase == .working } }
    var waiting: [SessionState] { sessions.filter { $0.phase == .waiting } }
    var runningAgents: Int { sessions.reduce(0) { $0 + $1.runningAgents.count } }

    /// A finished turn shorter than this sends no notification.
    private let notifyAfterTurn: Double = 60

    func start() {
        approvals.start()
        Notifier.shared.setUp()
        Notifier.shared.onOpen = { [weak self] id in
            if let session = self?.sessions.first(where: { $0.id == id }) { Jump.to(session) }
        }
        git = GitStats { [weak self] lines in
            Task { @MainActor in self?.gitLines = lines }
        }
        scanner = UsageScanner { [weak self] snapshot in
            Task { @MainActor in self?.took(snapshot) }
        }
        scanner?.start()
        watcher.start()
        reload()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    private func reload() {
        // The clocks show whole seconds: a new `now` redraws the panel, so once a second is enough.
        let time = Date().timeIntervalSince1970
        if time.rounded(.down) != now.rounded(.down) { now = time }
        let dir = NotchPaths.sessions
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var live: [SessionState] = []
        var seenIds = Set<String>()
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let state = try? JSONDecoder.notch.decode(SessionState.self, from: data) else { continue }
            // A session that never got a prompt is a helper run, not a conversation: not shown,
            // and its file goes once it is ten minutes old.
            let isEmpty = state.turnStartedAt == nil && state.toolCount == 0 && state.firstPrompt == nil && state.sessionTitle == nil && state.agents.isEmpty
            if isEmpty, now - state.startedAt < 600 { continue }
            seenIds.insert(state.id)
            if isGone(state, at: time) || isEmpty {
                try? FileManager.default.removeItem(at: file)
                try? FileManager.default.removeItem(at: NotchPaths.lock(state.id))
                try? FileManager.default.removeItem(at: NotchPaths.control(state.id))
                continue
            }
            var shown = settled(state)
            // The hooks first saw sessions that were already open when they were installed;
            // the transcript knows when each really began.
            if let first = usage.firstAt[shown.id], first < shown.startedAt { shown.startedAt = first }
            live.append(shown)
        }
        failingSince = failingSince.filter { seenIds.contains($0.key) }
        // Agents the hooks do not cover, seen as processes; one a hook reports is left to the hook.
        watcher.setHooked(Set(live.compactMap(\.pid)))
        live += watcher.sessions.filter { row in !live.contains { $0.pid != nil && $0.pid == row.pid } }
        live.sort(by: order)
        approvals.reconcile(with: live)
        alert(for: live)
        if live != sessions { sessions = live }
        KeepAwake.shared.update(working: live.contains { $0.phase == .working }, now: time)
        AgentControls.shared.refresh(sessions)
        CommandsStore.shared.setAgents(sessions.compactMap { session in
            session.pid.map { CommandScanner.Agent(pid: $0, sessionId: session.id, title: title(of: session)) }
        })
        titleReader.refresh(live) { [weak self] found in
            MainActor.assumeIsolated {
                guard let self, found != self.titles else { return }
                self.titles = found
            }
        }
        feedWidget(live)
        let activity = readAgentActivity(live)
        if activity != agentActivity { agentActivity = activity }
        let models = readAgentModels(live)
        if models != agentModels { agentModels = models }
        readLimits()
    }

    /// The limits file when it changed (every 2 s at most), then a probe if the numbers are old.
    private func readLimits() {
        guard now - limitsCheckedAt > 2 else { return }
        limitsCheckedAt = now
        let mtime = ((try? FileManager.default.attributesOfItem(atPath: LimitsFile.url.path)[.modificationDate]) as? Date)?.timeIntervalSince1970 ?? 0
        if mtime != limitsMtime {
            limitsMtime = mtime
            if var limits = LimitsFile.load(), limits.at >= (claudeLimits?.at ?? 0) {
                // The status line names no plan; the last probe did.
                if limits.plan == nil { limits.plan = claudeLimits?.plan }
                claudeLimits = limits
                LimitAlerts.shared.check(limits)
            }
        }
        askForLimits(soon: false)
    }

    /// The panel opened: numbers older than three minutes are refreshed.
    func panelOpened() { askForLimits(soon: true) }

    /// Asks Claude Code for its limits when they are stale: older than 3 minutes with the panel
    /// open, or 15 minutes while a Claude Code session is busy; never twice within 2 minutes.
    private func askForLimits(soon: Bool) {
        let age = now - (claudeLimits?.at ?? 0)
        let isBusy = sessions.contains { $0.kind == .claude && $0.phase != .idle }
        guard !isProbing, now - probeStartedAt > 120, age > (soon ? 180 : 900), soon || isBusy else { return }
        isProbing = true
        probeStartedAt = now
        UsageProbe.fetch { [weak self] limits in
            Task { @MainActor in
                guard let self else { return }
                self.isProbing = false
                guard var limits else { return }
                if limits.plan == nil { limits.plan = self.claudeLimits?.plan }
                self.claudeLimits = limits
                LimitsFile.save(limits)
                LimitAlerts.shared.check(limits)
                self.limitsMtime = ((try? FileManager.default.attributesOfItem(atPath: LimitsFile.url.path)[.modificationDate]) as? Date)?.timeIntervalSince1970 ?? 0
            }
        }
    }

    /// A new usage snapshot; every five minutes, the git history of the repos Claude Code wrote in.
    private func took(_ snapshot: UsageSnapshot) {
        usage = snapshot
        guard !snapshot.isScanning, now - gitReadAt > 300 else { return }
        gitReadAt = now
        let repos = Set(snapshot.lines.values.flatMap(\.keys)).filter { !$0.isEmpty }
        git?.refresh(Array(repos), days: 183)
    }

    /// A turn you interrupted raises no hook, so the session still says working; its transcript
    /// records the interrupt, and that ends the turn and its foreground work here.
    private func settled(_ original: SessionState) -> SessionState {
        var state = approved(original)
        // The last reply names its model; that covers a session that began before the hooks did.
        if let path = state.transcriptPath, let model = tail(path).model { state.model = model }
        guard state.phase != .idle, let path = state.transcriptPath, let at = tail(path).interruptAt,
              at >= (state.turnStartedAt ?? 0) - 1 else { return state }
        state.phase = .idle
        state.clearWaits()
        state.current = nil
        state.finishedAt = at
        if let started = state.turnStartedAt { state.lastTurnSeconds = at - started }
        for index in state.agents.indices where state.agents[index].isRunning && state.agents[index].isBackground != true {
            state.agents[index].end(.stopped, at: at)
        }
        return state
    }

    /// A permission prompt you approved raises no hook until the tool finishes; a shell command
    /// shows itself sooner, as a new shell under the Claude Code process started after the prompt.
    /// Only a shell counts: Claude Code also starts MCP servers and helpers (uv, node, ioreg) at
    /// any time, and those said nothing about the prompt.
    /// Not while a subagent runs: its own commands start shells too, and would read as approved.
    private func approved(_ state: SessionState) -> SessionState {
        guard state.phase == .waiting, state.waitingFor?.hasPrefix("permission") == true, state.waitingTool == "Bash",
              state.runningAgents.isEmpty, (state.waits?.count ?? 1) == 1,
              let pid = state.pid, let since = state.waitingSince,
              ProcessList.hasChild(of: pid, startedAfter: since + 0.3, named: ["zsh", "bash", "fish"]) else { return state }
        var state = state
        state.phase = .working
        state.clearWaits()
        return state
    }

    /// The end of a transcript: when its last exchange is "[Request interrupted by user…]", its
    /// time, and the model of its last reply.
    /// `isAgent`: a subagent's own transcript, where every line is a sidechain.
    private func tail(_ path: String, isAgent: Bool = false) -> (interruptAt: Double?, model: String?) {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        if let hit = tails[path], hit.mtime == mtime { return (hit.interruptAt, hit.model) }
        var found: Double?
        var model: String?
        var exchangeSeen = false
        if let handle = FileHandle(forReadingAtPath: path) {
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            try? handle.seek(toOffset: size > 65_536 ? size - 65_536 : 0)
            let tail = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
            for line in tail.split(separator: "\n").reversed() {
                guard let data = line.data(using: .utf8),
                      let entry = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let type = entry["type"] as? String, type == "user" || type == "assistant",
                      isAgent || entry["isSidechain"] as? Bool != true else { continue }
                if !exchangeSeen {
                    exchangeSeen = true
                    if type == "user", line.contains("[Request interrupted by user"), let stamp = entry["timestamp"] as? String {
                        found = Self.isoTime(stamp)
                    }
                }
                if type == "assistant", let message = entry["message"] as? [String: Any],
                   let name = message["model"] as? String, !name.hasPrefix("<") {
                    model = name
                    break
                }
            }
        }
        tails[path] = (mtime, found, model)
        return (found, model)
    }

    private static func isoTime(_ text: String) -> Double? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return (formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text))?.timeIntervalSince1970
    }

    /// Each running subagent's transcript, `<session>/subagents/agent-<id>.jsonl`, by when it last changed.
    private func readAgentActivity(_ live: [SessionState]) -> [String: Double] {
        var activity: [String: Double] = [:]
        for session in live {
            guard let path = session.transcriptPath else { continue }
            let folder = URL(fileURLWithPath: path).deletingPathExtension().appendingPathComponent("subagents")
            for agent in session.runningAgents {
                let file = folder.appendingPathComponent("agent-\(agent.id).jsonl").path
                if let date = try? FileManager.default.attributesOfItem(atPath: file)[.modificationDate] as? Date {
                    activity[agent.id] = date.timeIntervalSince1970
                }
            }
        }
        return activity
    }

    /// Each subagent's model, from the last reply in its own transcript.
    private func readAgentModels(_ live: [SessionState]) -> [String: String] {
        var models: [String: String] = [:]
        for session in live {
            guard let path = session.transcriptPath else { continue }
            let folder = URL(fileURLWithPath: path).deletingPathExtension().appendingPathComponent("subagents")
            for agent in session.agents {
                let file = folder.appendingPathComponent("agent-\(agent.id).jsonl").path
                if let model = tail(file, isAgent: true).model { models[agent.id] = model }
            }
        }
        return models
    }

    /// The chat's name as its editor lists it: your rename, else Claude Code's AI title (Cursor's
    /// own name for its chats), else the first prompt, else the project.
    func title(of session: SessionState) -> String {
        let found = titles[session.id]
        let prompt = session.firstPrompt.flatMap { $0.hasPrefix("<") ? nil : $0 }
        let named: String?
        switch session.kind {
        case .cursor: named = found?.cursor
        case .claude: named = found?.custom ?? session.sessionTitle ?? found?.ai
        default: named = session.sessionTitle
        }
        return named ?? prompt ?? session.project
    }

    /// The desktop widget's snapshot in the shared app group; a change asks WidgetKit to reload,
    /// at most every two minutes (the turn timers tick in the widget by themselves).
    private func feedWidget(_ live: [SessionState]) {
        guard let widgetURL else { return }
        let rows = live.prefix(8).map { session -> WidgetSnapshot.Row in
            let detail: String
            switch session.phase {
            case .waiting: detail = "Waiting for \(session.waitingFor ?? "you")"
            case .working: detail = session.current.map { $0.server.map { s in "\(s) · \(session.current?.shortName ?? "")" } ?? $0.name } ?? "Thinking…"
            case .idle: detail = session.finishedAt.map { "Done \(elapsed(now - $0)) ago" } ?? "Idle"
            }
            return WidgetSnapshot.Row(id: session.id, project: session.project, title: title(of: session), phase: session.phase.rawValue, detail: detail,
                                      model: session.model.map(modelName), isCursor: session.isCursorAgent,
                                      turnStartedAt: session.phase == .working ? session.turnStartedAt : nil, agents: session.runningAgents.count)
        }
        // Idle rows' "Done … ago" changes every second; compare what matters to the widget.
        let key: (WidgetSnapshot.Row) -> String = { "\($0.id)|\($0.title ?? "")|\($0.phase)|\($0.phase == "idle" ? "" : $0.detail)|\($0.agents)" }
        let changed = rows.map(key) != widgetRows.map(key)
        guard changed || widgetReloadPending else { return }
        widgetRows = Array(rows)
        if now - widgetReloadAt < 120 {
            widgetReloadPending = true
            return
        }
        let today = usage.total(sinceDay: UsageScanner.day(of: now))
        let snapshot = WidgetSnapshot(updatedAt: now, sessions: Array(rows), todayTokens: today.total, todayCost: today.cost)
        if let data = try? JSONEncoder().encode(snapshot) {
            try? FileManager.default.createDirectory(at: widgetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: widgetURL, options: .atomic)
            WidgetCenter.shared.reloadTimelines(ofKind: "Sessions")
        }
        widgetReloadAt = now
        widgetReloadPending = false
    }

    /// Opens a session the widget links to (`ainotch://open?session=<id>`).
    func open(_ url: URL) {
        guard let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "session" })?.value,
              let session = sessions.first(where: { $0.id == id }) else { return }
        Jump.to(session)
    }

    /// Notify only while the screen is locked: at the Mac, the notch's glow and sound say it.
    private func shouldNotify(_ session: SessionState) -> Bool {
        Notifier.shared.isScreenLocked
    }

    private func isGone(_ state: SessionState, at time: Double) -> Bool {
        if let pid = state.pid {
            guard processIsGone(pid, lastReport: state.updatedAt) else {
                failingSince[state.id] = nil
                return false
            }
            // Gone on two reads at least `goneAfter` apart, and quiet for a while: a hook that
            // just wrote the file is proof enough that its agent is still around.
            let first = failingSince[state.id] ?? time
            failingSince[state.id] = first
            return time - first >= goneAfter && time - state.updatedAt > quietBeforeDrop
        }
        // Cursor's chats name no process to watch, nor does an agent that reports itself without
        // --pid: one quiet for half an hour has left the notch.
        if state.kind != .claude { return now - state.updatedAt > 1800 }
        return now - state.updatedAt > orphanAfter
    }

    /// No such process (or an exited one nobody has collected), or a different one now holding
    /// its number: one that began after the
    /// session's last report cannot be the agent that made that report.
    private func processIsGone(_ pid: Int32, lastReport: Double) -> Bool {
        if kill(pid, 0) != 0 { return errno == ESRCH }
        // kill() still succeeds on a process that has exited but is not yet collected.
        if ProcessList.isZombie(pid) { return true }
        if let entry = ProcessList.entry(pid), entry.start > lastReport + 2 { return true }
        return false
    }

    /// Waiting first, then working, then the most recently active.
    private func order(_ a: SessionState, _ b: SessionState) -> Bool {
        func rank(_ s: SessionState) -> Int { s.phase == .waiting ? 0 : s.phase == .working ? 1 : 2 }
        return rank(a) != rank(b) ? rank(a) < rank(b) : a.updatedAt > b.updatedAt
    }

    private func alert(for live: [SessionState]) {
        // A watched agent's working or idle is read from its CPU: no sounds or notifications on it.
        for session in live where !session.id.hasPrefix("watch-") {
            let before = phases[session.id]
            defer { phases[session.id] = session.phase }
            guard let before, before != session.phase else { continue }
            if session.phase == .waiting {
                NSSound(named: "Ping")?.play()
                if shouldNotify(session) {
                    Notifier.shared.post(session: session.id, title: title(of: session), subtitle: "\(session.project) needs you",
                                         body: "Waiting for \(session.waitingFor ?? "you")")
                }
            } else if session.phase == .idle, before == .working {
                lastDoneAt = now
                let took = session.lastTurnSeconds ?? 0
                if took >= soundAfterTurn { NSSound(named: "Glass")?.play() }
                if took >= notifyAfterTurn, shouldNotify(session) {
                    Notifier.shared.post(session: session.id, title: title(of: session), subtitle: "\(session.project) finished",
                                         body: "Took \(elapsed(took))")
                }
            }
        }
        let ids = Set(live.map(\.id))
        phases = phases.filter { ids.contains($0.key) }
    }
}
