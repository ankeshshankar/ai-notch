import Darwin
import Foundation
import NotchCore

/// Coding agents the hooks do not cover, found as processes: Aider, Goose, Amp, Factory's Droid,
/// Crush, GitHub Copilot CLI, OpenCode, Qwen Code and others, plus Codex and Gemini CLI where their
/// hooks are not set up, and any name builds.json adds (`"agents": {"watch": {…}}`). Each one
/// shows as a row: its folder, the app it runs in, and working or idle from its CPU (its own and
/// its children's), which is all a process says. Scanned every 3 seconds off the main thread; a
/// process a hook already reports (its pid, or one above or below it) is left to the hook.
final class AgentWatcher: @unchecked Sendable {
    /// Process names, and what to call them.
    static let known: [String: String] = [
        "aider": "Aider", "goose": "Goose", "amp": "Amp", "droid": "Factory Droid", "crush": "Crush",
        "copilot": "GitHub Copilot CLI", "opencode": "OpenCode", "qwen": "Qwen Code", "gemini": "Gemini CLI",
        "codex": "Codex", "cursor-agent": "Cursor CLI", "auggie": "Augment", "kiro-cli": "Kiro",
        "cline": "Cline", "kimi": "Kimi CLI", "plandex": "Plandex", "openhands": "OpenHands",
    ]

    /// Scripts run by these: the script's name (or its npm package) says which agent it is.
    private static let interpreters: Set<String> = ["node", "bun", "deno", "python", "python3", "ruby"]
    /// npm and pip packages whose script runs under an interpreter, and the name they map to.
    private static let packages: [String: String] = [
        "@google/gemini-cli": "gemini", "@openai/codex": "codex", "@qwen-code/qwen-code": "qwen",
        "@github/copilot": "copilot", "@sourcegraph/amp": "amp", "opencode-ai": "opencode",
        "@augmentcode/auggie": "auggie", "aider-chat": "aider", "@charmland/crush": "crush",
    ]
    /// Arguments that make it a server or a helper of an editor, not a session someone is using.
    private static let serverArgs: Set<String> = ["mcp", "mcp-server", "app-server", "serve", "server", "--acp", "--experimental-acp", "acp", "proto"]

    /// Agents seen working within this long count as working: a model streaming its answer
    /// barely uses the CPU between bursts.
    private static let workingHold: Double = 15
    /// CPU use (share of one core, children included) that counts as working.
    private static let workingCPU: Double = 0.03

    private let queue = DispatchQueue(label: "info.ankeshshiv.notch.agent-watcher", qos: .utility)
    private let lock = NSLock()
    private var latest: [SessionState] = []
    private var hooked: Set<Int32> = []
    private var timer: DispatchSourceTimer?
    /// Per watched process (pid and start): the last CPU sample, when it last looked busy, and
    /// when its current working or idle stretch began.
    private var samples: [String: (cpu: UInt64, at: Double)] = [:]
    private var lastBusy: [String: Double] = [:]
    private var since: [String: (phase: Phase, at: Double)] = [:]
    private var arguments: [String: [String]] = [:]

    static let enabledKey = "agents.watch"
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    /// The rows from the last scan.
    var sessions: [SessionState] {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    /// The pids the hooks report: those processes, and the ones above and below them, are skipped.
    func setHooked(_ pids: Set<Int32>) {
        lock.lock()
        hooked = pids
        lock.unlock()
    }

    func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 3, leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in self?.scan() }
        timer.resume()
        self.timer = timer
    }

    private func scan() {
        guard Self.isEnabled, let table = ProcessList.table() else {
            publish([])
            return
        }
        let now = Date().timeIntervalSince1970
        let config = BuildsConfig.current
        var names = Self.known
        for (process, title) in config?.watchAgents ?? [:] { names[process] = title }
        for process in config?.ignoreAgents ?? [] { names[process] = nil }
        lock.lock()
        let hooked = self.hooked
        lock.unlock()

        let me = getuid()
        let byPid = Dictionary(table.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var children: [Int32: [Int32]] = [:]
        for entry in table { children[entry.ppid, default: []].append(entry.pid) }
        func ancestors(_ pid: Int32) -> [Int32] {
            var out: [Int32] = []
            var current = byPid[pid]?.ppid ?? 0
            while current > 1, out.count < 24 {
                out.append(current)
                current = byPid[current]?.ppid ?? 0
            }
            return out
        }
        func descendants(_ pid: Int32) -> [Int32] {
            var out: [Int32] = []
            var stack = children[pid] ?? []
            while let next = stack.popLast(), out.count < 200 {
                out.append(next)
                stack += children[next] ?? []
            }
            return out
        }

        // Which processes are agents, and which agent.
        var matched: [Int32: String] = [:]
        var seenKeys = Set<String>()
        for entry in table where entry.uid == me {
            let key = "\(entry.pid)-\(entry.start)"
            seenKeys.insert(key)
            if let process = match(entry, key: key, names: names) { matched[entry.pid] = process }
        }
        arguments = arguments.filter { seenKeys.contains($0.key) }

        var rows: [SessionState] = []
        for (pid, process) in matched {
            let above = ancestors(pid)
            // The outermost process of an agent is its row (npm's wrapper over Codex's binary).
            if above.contains(where: { matched[$0] != nil }) { continue }
            let below = descendants(pid)
            if hooked.contains(pid) || above.contains(where: hooked.contains) || below.contains(where: hooked.contains) { continue }
            guard let entry = byPid[pid] else { continue }
            let key = "\(pid)-\(entry.start)"

            // CPU since the last scan, its children's included.
            let cpu = ([pid] + below).compactMap { ProcessList.usage(of: $0)?.cpuNanos }.reduce(0, &+)
            let previous = samples[key]
            samples[key] = (cpu, now)
            if let previous, now > previous.at, cpu >= previous.cpu {
                let share = Double(cpu - previous.cpu) / 1e9 / (now - previous.at)
                if share >= Self.workingCPU { lastBusy[key] = now }
            }
            let working = lastBusy[key].map { now - $0 < Self.workingHold } ?? false
            let phase: Phase = working ? .working : .idle
            if since[key]?.phase != phase { since[key] = (phase, now) }

            let name = names[process] ?? process
            var state = SessionState(id: "watch-\(pid)-\(Int(entry.start))", cwd: ProcessList.cwd(of: pid) ?? NSHomeDirectory(), now: now)
            state.entrypoint = AgentKind.otherPrefix + name
            state.pid = pid
            state.startedAt = entry.start
            state.phase = phase
            state.appBundleId = hostApp(above, byPid: byPid)
            if working {
                state.turnStartedAt = since[key]?.at
            } else if previous != nil, let busy = lastBusy[key] {
                state.finishedAt = busy
            }
            rows.append(state)
        }
        let live = Set(rows.compactMap { row in row.pid.flatMap { pid in byPid[pid].map { "\(pid)-\($0.start)" } } })
        samples = samples.filter { live.contains($0.key) }
        lastBusy = lastBusy.filter { live.contains($0.key) }
        since = since.filter { live.contains($0.key) }
        publish(rows.sorted { $0.startedAt < $1.startedAt })
    }

    private func publish(_ rows: [SessionState]) {
        lock.lock()
        latest = rows
        lock.unlock()
    }

    /// The agent a process is, by its name, or by its script's under node, bun, python…: the
    /// script's file name, or the npm or pip package it sits in.
    private func match(_ entry: ProcEntry, key: String, names: [String: String]) -> String? {
        let comm = entry.comm
        let isInterpreter = Self.interpreters.contains(comm) || comm.hasPrefix("python")
        guard names[comm] != nil || isInterpreter else { return nil }
        // Claude Code reports itself through its hooks.
        if comm == "claude" { return nil }
        let args: [String]
        if let cached = arguments[key] {
            args = cached
        } else {
            args = ProcessList.arguments(of: entry.pid) ?? []
            arguments[key] = args
        }
        if args.dropFirst().contains(where: Self.serverArgs.contains) { return nil }
        if names[comm] != nil, !isInterpreter { return comm }
        // node <script> …: the first argument that is not an option is the script.
        guard let script = args.dropFirst().first(where: { !$0.hasPrefix("-") }) else { return nil }
        let file = (script as NSString).lastPathComponent
        let base = (file as NSString).deletingPathExtension
        if names[file] != nil { return file }
        if names[base] != nil, base != "index", base != "main", base != "cli" { return base }
        for (package, process) in Self.packages where script.contains("/\(package)/") || script.contains("/\(package)-") {
            if names[process] != nil { return process }
        }
        return nil
    }

    /// The app the agent runs in: the first process above it that is an app's executable
    /// (Terminal, iTerm; VS Code's helpers lead to VS Code, the outermost app on their path).
    private func hostApp(_ above: [Int32], byPid: [Int32: ProcEntry]) -> String? {
        for pid in above {
            let path = ProcessList.path(of: pid)
            guard let range = path.range(of: ".app/Contents/") else { continue }
            if let id = Bundle(path: String(path[..<range.lowerBound]) + ".app")?.bundleIdentifier { return id }
        }
        return nil
    }
}
