import Foundation

/// What a Claude Code session is doing, as its hooks last reported it.
public enum Phase: String, Codable, Sendable {
    /// A turn is running: the model is thinking or a tool is running.
    case working
    /// The session is blocked on you: a permission prompt, a question, a plan to approve.
    case waiting
    /// No turn is running.
    case idle
}

/// One tool call in flight.
public struct ToolNow: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    /// The MCP server, for an MCP tool.
    public var server: String?
    public var since: Double

    public init(id: String, name: String, server: String?, since: Double) {
        self.id = id
        self.name = name
        self.server = server
        self.since = since
    }

    /// The tool's own name, without the `mcp__<server>__` prefix.
    public var shortName: String {
        guard name.hasPrefix("mcp__"), let range = name.range(of: "__", range: name.index(name.startIndex, offsetBy: 5)..<name.endIndex) else {
            return name
        }
        return String(name[range.upperBound...])
    }
}

/// How a subagent ended.
public enum AgentOutcome: String, Codable, Sendable {
    case done, failed, stopped
}

/// One subagent of a session.
public struct AgentNow: Codable, Sendable, Equatable {
    public var id: String
    public var type: String
    /// What it was asked to do: the Agent call's `description`.
    public var description: String?
    public var model: String?
    public var isBackground: Bool?
    /// The Agent tool call that started it, which a task notification names.
    public var toolUseId: String?
    public var startedAt: Double
    public var endedAt: Double?
    public var outcome: AgentOutcome?
    public var current: ToolNow?
    /// The last tool it finished, shown once it is between tools or done.
    public var lastTool: ToolNow?
    public var toolCount: Int
    public var mcp: [String: Int]

    public init(id: String, type: String, startedAt: Double) {
        self.id = id
        self.type = type
        self.startedAt = startedAt
        self.toolCount = 0
        self.mcp = [:]
    }

    public var isRunning: Bool { endedAt == nil }

    public mutating func end(_ outcome: AgentOutcome, at time: Double) {
        guard endedAt == nil else { return }
        endedAt = time
        self.outcome = outcome
        if let current { lastTool = current }
        current = nil
    }
}

/// One item of Claude's to-do list (TodoWrite).
public struct TodoItem: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable {
        case pending, inProgress = "in_progress", completed
    }

    public var content: String
    public var status: Status
    /// What it says while doing it ("Running the tests").
    public var activeForm: String?

    public init(content: String, status: Status, activeForm: String?) {
        self.content = content
        self.status = status
        self.activeForm = activeForm
    }
}

/// An Agent call the main thread made whose subagent has not started yet.
public struct PendingAgent: Codable, Sendable, Equatable {
    public var toolUseId: String
    public var type: String
    public var description: String?
    public var model: String?
    public var isBackground: Bool
    public var since: Double

    public init(toolUseId: String, type: String, description: String?, model: String?, isBackground: Bool, since: Double) {
        self.toolUseId = toolUseId
        self.type = type
        self.description = description
        self.model = model
        self.isBackground = isBackground
        self.since = since
    }
}

/// The state file of one session: `~/.claude/notch/sessions/<id>.json`.
public struct SessionState: Codable, Sendable, Equatable {
    public var id: String
    public var cwd: String
    /// The first prompt you typed: the chat's name when nothing better names it.
    public var firstPrompt: String?
    /// The name you gave the chat, as Claude Code's hooks last sent it (`session_title`). The
    /// AI title and a rename made since are read from the transcript by the app.
    public var sessionTitle: String?
    /// The app the session runs in (`com.microsoft.VSCode`, `com.apple.Terminal`, ...).
    public var appBundleId: String?
    /// The terminal the agent runs in ("/dev/ttys004"), and its tmux pane ("%3") when in tmux:
    /// what a jump selects the right tab or pane by.
    public var tty: String?
    public var tmuxPane: String?
    /// How Claude Code was started (`cli`, `claude-vscode`, ...).
    public var entrypoint: String?
    /// The Claude Code process, to tell a live session from one that crashed.
    public var pid: Int32?
    public var phase: Phase
    /// What it is waiting for, while `phase` is `waiting`.
    public var waitingFor: String?
    /// When the current wait began.
    public var waitingSince: Double?
    /// The tool the wait is on, and the subagent running it (nil for the main thread):
    /// only that tool finishing ends the wait.
    public var waitingTool: String?
    public var waitingAgent: String?
    public var startedAt: Double
    public var updatedAt: Double
    public var turnStartedAt: Double?
    public var lastTurnSeconds: Double?
    public var finishedAt: Double?
    public var current: ToolNow?
    /// The last tool the main thread finished.
    public var lastTool: ToolNow?
    /// The model the session runs on, as the hooks last named it.
    public var model: String?
    public var agents: [AgentNow]
    public var toolCount: Int
    public var mcp: [String: Int]
    /// Background tasks still running when the last turn stopped.
    public var backgroundTasks: Int
    /// The session's transcript, where an interrupt (which raises no hook) is recorded.
    public var transcriptPath: String?
    public var pendingAgents: [PendingAgent]?
    /// Permission prompts handed to the app and not yet answered anywhere.
    public var pendingPermissions: [PendingPermission]?
    /// When the session's prompt cache goes cold, as the status line last said (terminal only).
    public var promptCacheExpiresAt: Double?
    /// Claude's to-do list, as its last TodoWrite set it.
    public var todos: [TodoItem]?
    /// When the session last pushed or deployed (git push, a deploy command), and what it ran.
    public var shippedAt: Double?
    public var shipped: String?

    public init(id: String, cwd: String, now: Double) {
        self.id = id
        self.cwd = cwd
        self.phase = .idle
        self.startedAt = now
        self.updatedAt = now
        self.agents = []
        self.toolCount = 0
        self.mcp = [:]
        self.backgroundTasks = 0
    }

    public var project: String { URL(fileURLWithPath: cwd).lastPathComponent }
    public var runningAgents: [AgentNow] { agents.filter(\.isRunning) }
    /// A chat of Cursor's own agent, not a Claude Code session.
    public var isCursorAgent: Bool { entrypoint == "cursor-agent" }
    /// Who runs the session (see AgentKind).
    public var kind: AgentKind { AgentKind(entrypoint: entrypoint) }
}

/// Who runs a session. Claude Code's own hooks leave `entrypoint` as Claude Code names it (`cli`,
/// `claude-vscode`, …); the other hooks write `cursor-agent`, `codex-agent` or `gemini-agent`; an
/// agent the notch only sees as a process, or one that reports itself (`ai-notch-hook report`),
/// `agent:<its name>`.
public enum AgentKind: Equatable, Sendable {
    case claude, cursor, codex, gemini
    /// Seen by the process watcher, or reported: its name.
    case other(String)

    public static let codexEntrypoint = "codex-agent"
    public static let geminiEntrypoint = "gemini-agent"
    public static let otherPrefix = "agent:"

    public init(entrypoint: String?) {
        switch entrypoint {
        case "cursor-agent": self = .cursor
        case AgentKind.codexEntrypoint: self = .codex
        case AgentKind.geminiEntrypoint: self = .gemini
        case let value? where value.hasPrefix(AgentKind.otherPrefix): self = .other(String(value.dropFirst(AgentKind.otherPrefix.count)))
        default: self = .claude
        }
    }

    public var name: String {
        switch self {
        case .claude: return "Claude Code"
        case .cursor: return "Cursor Agent"
        case .codex: return "Codex"
        case .gemini: return "Gemini CLI"
        case .other(let name): return name.isEmpty ? "Agent" : name
        }
    }
}

/// A model id as people say it: `claude-opus-5-5` is "Opus 5.5", `claude-haiku-4-5-20251001`
/// "Haiku 4.5", `claude-opus-4-8[1m]` "Opus 4.8 · 1M", Cursor's `claude-4.5-sonnet` "Sonnet 4.5".
public func modelName(_ id: String) -> String {
    var base = id.lowercased()
    var suffix = ""
    if let bracket = base.firstIndex(of: "[") {
        if base[bracket...].contains("1m") { suffix = " · 1M" }
        base = String(base[..<bracket])
    }
    let parts = base.split(separator: "-").map(String.init).filter { !($0.count == 8 && Int($0) != nil) }
    let families = ["opus", "sonnet", "haiku", "fable"]
    guard let index = parts.firstIndex(where: families.contains) else {
        return families.contains(base) ? base.capitalized + suffix : id
    }
    let isVersion: (String) -> Bool = { !$0.isEmpty && $0.allSatisfy { $0.isNumber || $0 == "." } }
    var version = parts[(index + 1)...].prefix(while: isVersion).joined(separator: ".")
    if version.isEmpty, index > 0, isVersion(parts[index - 1]) { version = parts[index - 1] }
    let family = parts[index].capitalized
    return (version.isEmpty ? family : "\(family) \(version)") + suffix
}

public enum NotchPaths {
    /// `CLAUDE_NOTCH_SESSIONS` points a dev run (a preview, a measurement) at a folder of its own.
    public static var sessions: URL {
        if let dir = ProcessInfo.processInfo.environment["CLAUDE_NOTCH_SESSIONS"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/notch/sessions", isDirectory: true)
    }

    public static func state(_ id: String) -> URL {
        sessions.appendingPathComponent("\(safe(id)).json")
    }

    public static func lock(_ id: String) -> URL {
        sessions.appendingPathComponent("\(safe(id)).lock")
    }

    /// What you asked of the session from the notch (stop, pause, a note); the hook acts on it.
    public static func control(_ id: String) -> URL {
        sessions.appendingPathComponent("\(safe(id)).control")
    }

    /// A session id as a file name: never a path.
    static func safe(_ id: String) -> String {
        String(id.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }.prefix(120))
    }
}

public extension JSONDecoder {
    static let notch = JSONDecoder()
}

public extension JSONEncoder {
    static let notch: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
}

/// What you asked of a Claude Code session from the notch, left beside its state for the hook:
/// stop it before its next step, hold its next step until you resume, or hand it a note with
/// its next step. The hook clears stop and the note when it acts on them; a turn's end clears all.
public struct SessionControl: Codable, Sendable, Equatable {
    public var stop: Bool?
    public var pause: Bool?
    public var note: String?
    public var at: Double

    public init(stop: Bool? = nil, pause: Bool? = nil, note: String? = nil, at: Double) {
        self.stop = stop
        self.pause = pause
        self.note = note
        self.at = at
    }

    public var isEmpty: Bool { stop != true && pause != true && (note ?? "").isEmpty }

    public static func read(_ id: String) -> SessionControl? {
        guard let data = try? Data(contentsOf: NotchPaths.control(id)) else { return nil }
        return try? JSONDecoder.notch.decode(SessionControl.self, from: data)
    }

    /// Written whole, or removed when nothing is asked.
    public static func write(_ control: SessionControl?, for id: String) {
        let url = NotchPaths.control(id)
        guard let control, !control.isEmpty, let data = try? JSONEncoder.notch.encode(control) else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try? data.write(to: url, options: .atomic)
    }
}
