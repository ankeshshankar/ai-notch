import AppKit
import Darwin
import Foundation
import NotchCore
import SwiftUI

/// The commands running in the background: what agents started (Claude Code's Bash and Monitor
/// commands, a watched agent's shells) and what has been running a while in your terminals (dev
/// servers, watch builds). Each with its folder, time, CPU, memory and the ports it listens on,
/// and Stop (SIGTERM to it and everything under it, SIGKILL 4 s later for what is left).
/// Scanned off the main thread every 3 s while the panel is open, every 10 s otherwise.
@MainActor
final class CommandsStore: ObservableObject {
    static let shared = CommandsStore()

    struct Command: Identifiable, Equatable, Sendable {
        /// Pid and start: the process the row saw, never a later one with its number.
        var id: String
        var pid: Int32
        var start: Double
        var text: String
        /// The chat that started it, or the app it runs in for a terminal's own.
        var owner: String
        var sessionId: String?
        var fromAgent: Bool
        var cwd: String?
        var cpu: Double
        var memory: UInt64
        var ports: [Int]
    }

    @Published private(set) var commands: [Command] = []
    /// Stopping: SIGTERM sent, SIGKILL due.
    @Published private(set) var stopping: Set<String> = []

    private let scanner = CommandScanner()
    private var agents: [CommandScanner.Agent] = []
    private var timer: Timer?
    private var panelOpen = false
    private var lastScan: Double = 0

    static let enabledKey = "commands.watch"
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// The agents whose children are theirs: their pid, row and chat title.
    func setAgents(_ list: [CommandScanner.Agent]) { agents = list }

    func setPanelOpen(_ open: Bool) {
        panelOpen = open
        if open { lastScan = 0 }
    }

    private func tick() {
        let now = Date().timeIntervalSince1970
        guard now - lastScan >= (panelOpen ? 3 : 10) else { return }
        lastScan = now
        guard Self.isEnabled else {
            if !commands.isEmpty { commands = [] }
            return
        }
        let agents = self.agents
        let scanner = self.scanner
        DispatchQueue.global(qos: .utility).async {
            let found = scanner.scan(agents: agents)
            Task { @MainActor in
                if found != self.commands { self.commands = found }
                let live = Set(found.map(\.id))
                if !self.stopping.isSubset(of: live) { self.stopping = self.stopping.intersection(live) }
            }
        }
    }

    func stop(_ command: Command) {
        stopping.insert(command.id)
        let pid = command.pid, start = command.start
        DispatchQueue.global(qos: .userInitiated).async {
            let tree = CommandScanner.tree(of: pid, start: start)
            for target in tree { kill(target, SIGTERM) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 4) {
                for target in tree where ProcessList.entry(target) != nil { kill(target, SIGKILL) }
            }
        }
        lastScan = 0
    }

    func open(port: Int) {
        if let url = URL(string: "http://localhost:\(port)") { NSWorkspace.shared.open(url) }
    }

    /// The footer chip's count: the agents' commands, and your terminals' that use a port or the CPU.
    var count: Int { commands.count }
}

/// The scan itself, off the main thread. Arguments are read once per process.
final class CommandScanner: @unchecked Sendable {
    struct Agent: Sendable {
        var pid: Int32
        var sessionId: String
        var title: String
    }

    private let lock = NSLock()
    private var argCache: [String: [String]] = [:]
    private var samples: [String: (cpu: UInt64, at: Double)] = [:]
    /// Processes an agent's command started (the command and everything under it), by pid and
    /// start: one still running once its agent or its shell has gone stays listed, as left by it.
    private var started: [String: (text: String?, owner: String, session: String?)] = [:]

    static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "fish"]
    /// Interactive programs and agents in a terminal: what you use there, not what runs on its own.
    static let interactive: Set<String> = [
        "vim", "nvim", "vi", "nano", "emacs", "less", "more", "man", "top", "htop", "btop", "ssh", "mosh",
        "tmux", "screen", "login", "sudo", "su", "claude", "codex", "gemini", "aider", "goose", "amp",
        "cursor-agent", "copilot", "opencode", "qwen", "droid", "crush", "lazygit", "tig", "k9s", "ipython",
        "psql", "mysql", "sqlite3", "redis-cli", "watch", "tail", "ai-notch-hook",
    ]
    /// A terminal's command counts once it has run this long.
    static let terminalAge: Double = 60
    /// An agent's command counts once it has run this long (short calls come and go).
    static let agentAge: Double = 5

    func scan(agents: [Agent]) -> [CommandsStore.Command] {
        guard let table = ProcessList.table() else { return [] }
        let now = Date().timeIntervalSince1970
        let me = getuid()
        let byPid = Dictionary(table.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var children: [Int32: [Int32]] = [:]
        for entry in table { children[entry.ppid, default: []].append(entry.pid) }
        let agentByPid = Dictionary(agents.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })

        lock.lock()
        defer { lock.unlock() }
        var seen = Set<String>()
        func args(_ entry: ProcEntry) -> [String] {
            let key = "\(entry.pid)-\(entry.start)"
            seen.insert(key)
            if let cached = argCache[key] { return cached }
            let read = ProcessList.arguments(of: entry.pid) ?? []
            argCache[key] = read
            return read
        }
        func below(_ pid: Int32) -> [Int32] {
            var out: [Int32] = []
            var stack = children[pid] ?? []
            while let next = stack.popLast(), out.count < 300 {
                out.append(next)
                stack += children[next] ?? []
            }
            return out
        }

        var found: [(entry: ProcEntry, text: String, owner: String, session: String?, fromAgent: Bool)] = []
        // An agent's commands: the shells it runs them in (`zsh -c …`), straight under it.
        for agent in agents {
            for pid in children[agent.pid] ?? [] {
                guard let entry = byPid[pid], entry.uid == me, Self.shells.contains(entry.comm),
                      now - entry.start >= Self.agentAge else { continue }
                let argv = args(entry)
                guard let index = argv.firstIndex(where: { $0 == "-c" || $0 == "-lc" || $0 == "-cl" }) else { continue }
                let script = argv[(index + 1)...].drop { $0.hasPrefix("-") }.joined(separator: " ")
                let text = Self.command(from: script)
                if text.contains("ai-notch-hook") || text.isEmpty { continue }
                found.append((entry, text, agent.title, agent.sessionId, true))
                started["\(entry.pid)-\(entry.start)"] = (text, agent.title, agent.sessionId)
                for pid in below(entry.pid) {
                    guard let child = byPid[pid] else { continue }
                    let key = "\(child.pid)-\(child.start)"
                    if started[key] == nil { started[key] = (nil, agent.title, agent.sessionId) }
                }
            }
        }
        // Left running: what an agent's command started, now on its own (its agent or its shell
        // gone, so it hangs off launchd), listed under the agent that started it.
        let listed = Set(found.map { $0.entry.pid })
        for entry in table where entry.uid == me && entry.ppid == 1 && !listed.contains(entry.pid) {
            guard let origin = started["\(entry.pid)-\(entry.start)"] else { continue }
            let text = origin.text ?? args(entry).map(Self.shortArg).joined(separator: " ")
            found.append((entry, text.isEmpty ? entry.comm : text, origin.owner + " (ended)", origin.session, true))
        }
        let alive = Set(table.map { "\($0.pid)-\($0.start)" })
        started = started.filter { alive.contains($0.key) }
        // Your terminals' own: a process under an interactive shell (one without -c) that holds a
        // terminal, has run a minute, and is not an editor, a pager or an agent.
        for entry in table where entry.uid == me && entry.tty != nil {
            guard let parent = byPid[entry.ppid], Self.shells.contains(parent.comm),
                  !Self.shells.contains(entry.comm), !Self.interactive.contains(entry.comm),
                  now - entry.start >= Self.terminalAge, agentByPid[entry.pid] == nil else { continue }
            let parentArgs = args(parent)
            if parentArgs.dropFirst().contains(where: { $0.hasPrefix("-c") }) { continue }
            // Under an agent: already listed, or one of its own.
            var up = parent.ppid
            var underAgent = false
            for _ in 0..<12 where up > 1 {
                if agentByPid[up] != nil { underAgent = true; break }
                up = byPid[up]?.ppid ?? 0
            }
            if underAgent { continue }
            let argv = args(entry)
            // A bare REPL (node, python with nothing after) is yours to use, not a command.
            if argv.count <= 1, ["node", "python", "python3", "bun", "deno", "ruby", "irb"].contains(entry.comm) { continue }
            let text = argv.isEmpty ? entry.comm : argv.map(Self.shortArg).joined(separator: " ")
            found.append((entry, text, Self.hostName(of: entry, byPid: byPid), nil, false))
        }

        var out: [CommandsStore.Command] = []
        var live = Set<String>()
        for item in found {
            let entry = item.entry
            let key = "\(entry.pid)-\(entry.start)"
            live.insert(key)
            let tree = [entry.pid] + below(entry.pid)
            var cpuNanos: UInt64 = 0
            var memory: UInt64 = 0
            var ports = Set<Int>()
            for pid in tree {
                if let usage = ProcessList.usage(of: pid) {
                    cpuNanos &+= usage.cpuNanos
                    memory &+= usage.footprint
                }
                for socket in ProcessList.tcpSockets(of: pid) where socket.listening && socket.localPort > 0 { ports.insert(socket.localPort) }
            }
            var share = 0.0
            if let previous = samples[key], now > previous.at, cpuNanos >= previous.cpu {
                share = Double(cpuNanos - previous.cpu) / 1e9 / (now - previous.at)
            }
            samples[key] = (cpuNanos, now)
            out.append(.init(id: key, pid: entry.pid, start: entry.start, text: String(item.text.prefix(300)), owner: item.owner,
                             sessionId: item.session, fromAgent: item.fromAgent, cwd: ProcessList.cwd(of: entry.pid),
                             cpu: share, memory: memory, ports: ports.sorted()))
        }
        samples = samples.filter { live.contains($0.key) }
        argCache = argCache.filter { seen.contains($0.key) }
        // The agents' first, then by how long they have run.
        return out.sorted { ($0.fromAgent ? 0 : 1, $0.start) < ($1.fromAgent ? 0 : 1, $1.start) }
    }

    /// The command a shell was given, without Claude Code's wrapper (`source <snapshot> && …
    /// eval '<command>' < /dev/null && pwd -P >| <file>`).
    static func command(from script: String) -> String {
        var text = script
        if let start = text.range(of: "eval '") {
            var rest = String(text[start.upperBound...])
            for tail in ["' \\< /dev/null", "' < /dev/null", "' && pwd -P"] {
                if let end = rest.range(of: tail, options: .backwards) { rest = String(rest[..<end.lowerBound]); break }
            }
            if rest.hasSuffix("'") { rest.removeLast() }
            text = rest.replacingOccurrences(of: "'\\''", with: "'")
        }
        return text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ⏎ ")
    }

    /// Long paths in a command line shortened to their last two parts.
    static func shortArg(_ arg: String) -> String {
        guard arg.hasPrefix("/"), arg.count > 40 else { return arg }
        let parts = arg.split(separator: "/")
        return "…/" + parts.suffix(2).joined(separator: "/")
    }

    /// The app a terminal command runs in (Terminal, iTerm, an editor's terminal).
    static func hostName(of entry: ProcEntry, byPid: [Int32: ProcEntry]) -> String {
        var pid = entry.ppid
        for _ in 0..<16 where pid > 1 {
            let path = ProcessList.path(of: pid)
            if let range = path.range(of: ".app/Contents/") {
                return ((String(path[..<range.lowerBound]) as NSString).lastPathComponent)
            }
            pid = byPid[pid]?.ppid ?? 0
        }
        return "Terminal"
    }

    /// The process and everything under it, if it is still the one that was seen.
    static func tree(of pid: Int32, start: Double) -> [Int32] {
        guard let entry = ProcessList.entry(pid), entry.uid == getuid(), abs(entry.start - start) < 1,
              let table = ProcessList.table() else { return [] }
        var children: [Int32: [Int32]] = [:]
        for item in table { children[item.ppid, default: []].append(item.pid) }
        var out: [Int32] = []
        var stack = [pid]
        while let next = stack.popLast(), out.count < 300 {
            out.append(next)
            stack += children[next] ?? []
        }
        return out
    }
}

// MARK: Views

/// The footer's chip: a terminal mark and how many commands run in the background.
struct CommandsChip: View {
    @ObservedObject var commands: CommandsStore
    @ObservedObject var controller: NotchController

    var body: some View {
        let isOpen = controller.openPanel == NotchController.commandsPanel
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                controller.openPanel = isOpen ? nil : NotchController.commandsPanel
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "terminal").font(.system(size: 9, weight: .semibold))
                Text("\(commands.count)").font(.system(size: 10, weight: .semibold).monospacedDigit())
            }
            .foregroundStyle(isOpen ? Palette.onDone : Palette.ink2)
            .lineLimit(1)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(isOpen ? Palette.done : Palette.chip))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Commands running in the background: what agents started, and what has run a minute in your terminals")
    }
}

/// The Commands panel: a line per command, the agents' first, each with Stop (a second click
/// within 5 s confirms) and its ports.
struct CommandsPanel: View {
    @ObservedObject var commands: CommandsStore
    var now: Double
    @State private var confirming: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Commands").font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.ink2)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Palette.chip))
                Text(summary).font(.system(size: 10)).foregroundStyle(Palette.ink3)
                Spacer(minLength: 6)
                InfoMark(text: Self.about)
            }
            if commands.commands.isEmpty {
                Text("Nothing running in the background.").font(.system(size: 11)).foregroundStyle(Palette.ink3)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(commands.commands) { command in row(command) }
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.panel))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
    }

    private var summary: String {
        let fromAgents = commands.commands.filter(\.fromAgent).count
        let yours = commands.commands.count - fromAgents
        return [fromAgents > 0 ? "\(fromAgents) from agents" : nil, yours > 0 ? "\(yours) in your terminals" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private func row(_ command: CommandsStore.Command) -> some View {
        let isStopping = commands.stopping.contains(command.id)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: command.fromAgent ? "sparkles" : "terminal")
                .font(.system(size: 10)).frame(width: 14).padding(.top, 1)
                .foregroundStyle(command.fromAgent ? Palette.claude : Palette.ink3)
            VStack(alignment: .leading, spacing: 2) {
                Text(command.text).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Palette.ink.opacity(0.88))
                    .lineLimit(1).truncationMode(.tail)
                    .help(command.text)
                Text(meta(command, home: home)).font(.system(size: 10).monospacedDigit()).foregroundStyle(Palette.ink3)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 6)
            ForEach(command.ports.prefix(2), id: \.self) { port in
                small(":\(port)") { commands.open(port: port) }.help("Open http://localhost:\(port)")
            }
            if isStopping {
                Text("Stopping…").font(.system(size: 10)).foregroundStyle(Palette.ink3).padding(.top, 3)
            } else {
                small(confirming == command.id ? "Confirm stop" : "Stop", urgent: true) {
                    if confirming == command.id {
                        confirming = nil
                        commands.stop(command)
                    } else {
                        confirming = command.id
                        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { if confirming == command.id { confirming = nil } }
                    }
                }
            }
        }
    }

    private func meta(_ command: CommandsStore.Command, home: String) -> String {
        var parts = [command.owner, elapsed(now - command.start)]
        if command.cpu >= 0.01 { parts.append("\(Int((command.cpu * 100).rounded()))% CPU") }
        if command.memory > 0 { parts.append(ByteCountFormatter.string(fromByteCount: Int64(command.memory), countStyle: .memory)) }
        if let cwd = command.cwd { parts.append(cwd.replacingOccurrences(of: home, with: "~")) }
        return parts.joined(separator: " · ")
    }

    private func small(_ title: String, urgent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 10, weight: .medium))
                .foregroundStyle(urgent ? Palette.failed : Palette.ink2)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(urgent ? Palette.failedHue.opacity(0.16) : Palette.chip))
                .contentShape(Capsule())
                .fixedSize()
        }
        .buttonStyle(.plain)
    }

    static let about = "Commands an agent runs (Claude Code's background and long Bash commands, its monitors, a watched agent's shells) once they have run 5 seconds, and what has run a minute in your terminals, without editors, pagers, shells or agents. CPU, memory and ports count everything under the command. Stop sends SIGTERM to it and everything under it, then SIGKILL 4 s later to what is left; Claude Code sees its command end. Setup → Machine turns the list off."
}
