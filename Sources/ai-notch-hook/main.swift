import Darwin
import Foundation
import NotchCore

// Claude Code runs this on every hook event (the event's JSON on stdin) and folds the event
// into the session's state file. It always exits 0 and prints nothing, so it can never block or
// change what the session does: a failure only means the notch misses one update. The one
// exception is a permission prompt you answer by clicking in the notch: then it prints that
// answer (see the end of this file). Without a click it prints nothing, as before.
// Cursor's own agent runs it too (`ai-notch-hook cursor`, from ~/.cursor/hooks.json), on
// the events that act on nothing it answers; see the Cursor section below. So do Codex
// (`ai-notch-hook codex`, ~/.codex/hooks.json: Claude Code's event names, no answers from the
// notch) and Gemini CLI (`ai-notch-hook gemini`, ~/.gemini/settings.json; see its section).
// `ai-notch-hook report …` is for any other agent or script to report itself (see runReport).

// `ai-notch-hook --probe`: the app's setup runs this to learn whether macOS lets the hook run at
// all (a quarantined helper hangs in exec). It reads nothing, writes nothing, prints nothing.
if CommandLine.arguments.dropFirst().first == "--probe" { exit(0) }

let now = Date().timeIntervalSince1970
let maxAgents = 20
/// Ended subagents stay listed this long.
let agentLinger: Double = 180

let mode = CommandLine.arguments.dropFirst().first ?? ""
let isCursor = mode == "cursor"
let isCodex = mode == "codex"
let isGemini = mode == "gemini"
/// Claude Code itself (any other first argument is an older setup's and means Claude Code too).
let isClaude = !isCursor && !isCodex && !isGemini

/// The shells a hook command runs under, skipped when looking for the agent above it.
let shells: Set<String> = ["sh", "bash", "zsh", "dash", "fish", "env"]

/// The agent process above this hook: the first ancestor whose executable path names `needle`,
/// else the first one that is not a shell (Gemini CLI runs under node).
func agentPid(named needle: String) -> Int32? {
    var pid = getppid()
    var firstOther: Int32?
    for _ in 0..<8 where pid > 1 {
        var path = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &path, UInt32(path.count))
        let full = length > 0 ? String(cString: path) : ""
        if full.lowercased().contains(needle) { return pid }
        if firstOther == nil, !full.isEmpty, !shells.contains((full as NSString).lastPathComponent) { firstOther = pid }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { break }
        pid = info.kp_eproc.e_ppid
    }
    return firstOther
}

/// `ai-notch-hook report <start|working|waiting|idle|end> --agent <name> [--id <id>]
/// [--title <text>] [--detail <text>] [--cwd <folder>] [--pid <pid>]`: any agent, wrapper or
/// script reports itself, and shows as a row of its own. Without --id the row is the caller's
/// (its parent process); without --pid it leaves the notch after 30 minutes without a report.
/// Prints nothing, always exits 0, like the hook.
func runReport() -> Never {
    let args = Array(CommandLine.arguments.dropFirst(2))
    func value(_ flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1].isEmpty ? nil : args[i + 1]
    }
    let phaseWord = args.first ?? ""
    guard ["start", "working", "waiting", "idle", "end"].contains(phaseWord),
          let agent = value("--agent").map({ oneLine($0, max: 40) }) else {
        FileHandle.standardError.write(Data("usage: ai-notch-hook report <start|working|waiting|idle|end> --agent <name> [--id <id>] [--title <text>] [--detail <text>] [--cwd <folder>] [--pid <pid>]\n".utf8))
        exit(0)
    }
    let id = "report-" + (value("--id") ?? "\(agent)-\(getppid())")
    try? FileManager.default.createDirectory(at: NotchPaths.sessions, withIntermediateDirectories: true)
    if phaseWord == "end" {
        try? FileManager.default.removeItem(at: NotchPaths.state(id))
        try? FileManager.default.removeItem(at: NotchPaths.lock(id))
        exit(0)
    }
    let fd = open(NotchPaths.lock(id).path, O_CREAT | O_RDWR, 0o600)
    guard fd >= 0 else { exit(0) }
    var locked = false
    for _ in 0..<60 {
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { locked = true; break }
        usleep(5_000)
    }
    guard locked else { exit(0) }
    let file = NotchPaths.state(id)
    var state = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder.notch.decode(SessionState.self, from: $0) }
        ?? SessionState(id: id, cwd: value("--cwd") ?? FileManager.default.currentDirectoryPath, now: now)
    state.entrypoint = AgentKind.otherPrefix + agent
    state.updatedAt = now
    if let cwd = value("--cwd") { state.cwd = cwd }
    if let pid = value("--pid").flatMap({ Int32($0) }), pid > 1 { state.pid = pid }
    if state.appBundleId == nil { state.appBundleId = ProcessInfo.processInfo.environment["__CFBundleIdentifier"] }
    // A row needs a name to show (one with none is taken for a helper's run and hidden).
    state.sessionTitle = value("--title").map { oneLine($0, max: 120) } ?? state.sessionTitle ?? agent
    let detail = value("--detail").map { oneLine($0, max: 120) }
    switch phaseWord {
    case "working":
        if state.phase != .working { state.turnStartedAt = now }
        state.phase = .working
        state.finishedAt = nil
        state.waitingFor = nil
        state.waitingSince = nil
        if let detail { state.current = ToolNow(id: UUID().uuidString, name: detail, server: nil, since: now) }
    case "waiting":
        if state.phase != .waiting { state.waitingSince = now }
        state.phase = .waiting
        state.waitingFor = detail ?? "you"
    case "idle":
        if state.phase != .idle, let started = state.turnStartedAt { state.lastTurnSeconds = now - started }
        if state.phase != .idle { state.finishedAt = now }
        state.phase = .idle
        state.waitingFor = nil
        state.waitingSince = nil
        if let current = state.current { state.lastTool = current }
        state.current = nil
    default:
        state.phase = .idle
    }
    if let encoded = try? JSONEncoder.notch.encode(state) { try? encoded.write(to: file, options: .atomic) }
    flock(fd, LOCK_UN)
    exit(0)
}

/// `ai-notch-hook statusline '<your status line command>'`, as `statusLine.command`: notes the
/// limits and the prompt cache from the status line's input, then becomes your own command with
/// the same input, so what it prints, its exit code, its environment and folder are untouched.
/// Nothing of its own is ever printed, and with no command given it prints nothing.
func runStatusLine() -> Never {
    let input = (try? FileHandle.standardInput.readToEnd()) ?? Data()
    if let json = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] {
        if let rates = json["rate_limits"] as? [String: Any], var limits = LimitsFile.fromStatusLine(rates, at: now) {
            // The status line names no plan; keep the one Claude Code's usage request named.
            let saved = LimitsFile.load()
            limits.plan = saved?.plan
            // The status line runs every few seconds: rewrite on a change, else once a minute.
            if saved?.fiveHour != limits.fiveHour || saved?.weekly != limits.weekly || now - (saved?.at ?? 0) > 60 {
                try? FileManager.default.createDirectory(at: LimitsFile.url.deletingLastPathComponent(), withIntermediateDirectories: true)
                LimitsFile.save(limits)
            }
        }
        if let id = json["session_id"] as? String, !id.isEmpty,
           let cache = json["prompt_cache"] as? [String: Any], let expires = LimitsFile.number(cache["expires_at"]) {
            noteCache(session: id, expiresAt: expires)
        }
    }
    let rest = CommandLine.arguments.dropFirst(2).joined(separator: " ")
    guard !rest.isEmpty else { exit(0) }
    // The same bytes on stdin, from an unlinked temporary file, then exec: no pipe to fill.
    var template = Array((NSTemporaryDirectory() + "ai-notch-statusline.XXXXXX").utf8CString)
    let fd = mkstemp(&template)
    if fd >= 0 {
        unlink(String(cString: template))
        _ = input.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        lseek(fd, 0, SEEK_SET)
        dup2(fd, STDIN_FILENO)
        close(fd)
    }
    let words: [String] = ["/bin/sh", "-c", rest]
    let args: [UnsafeMutablePointer<CChar>?] = words.map { strdup($0) } + [nil]
    execv("/bin/sh", args)
    exit(0)
}

/// The prompt cache's end in the session's state, if the session is known and its lock is free.
func noteCache(session id: String, expiresAt: Double) {
    let file = NotchPaths.state(id)
    guard FileManager.default.fileExists(atPath: file.path) else { return }
    let fd = open(NotchPaths.lock(id).path, O_CREAT | O_RDWR, 0o600)
    guard fd >= 0 else { return }
    defer { close(fd) }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return }
    defer { flock(fd, LOCK_UN) }
    guard let data = try? Data(contentsOf: file), var state = try? JSONDecoder.notch.decode(SessionState.self, from: data),
          state.promptCacheExpiresAt != expiresAt else { return }
    state.promptCacheExpiresAt = expiresAt
    if let encoded = try? JSONEncoder.notch.encode(state) { try? encoded.write(to: file, options: .atomic) }
}

// `ai-notch-hook otel-headers`: Claude Code's otelHeadersHelper, when Setup sends its telemetry to
// Datadog. Prints the API key AI Notch keeps in ~/.claude/notch/datadog-otlp.key as the header.
if mode == "otel-headers" {
    let keyFile = NotchPaths.sessions.deletingLastPathComponent().appendingPathComponent("datadog-otlp.key")
    guard let raw = try? String(contentsOf: keyFile, encoding: .utf8) else { exit(1) }
    let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty, let json = try? JSONSerialization.data(withJSONObject: ["dd-api-key": key]) else { exit(1) }
    FileHandle.standardOutput.write(json + Data("\n".utf8))
    exit(0)
}

if mode == "statusline" { runStatusLine() }
if mode == "report" { runReport() }

// Gemini CLI reads a hook's output as JSON: an empty answer, once, whatever happens below.
if isGemini {
    FileHandle.standardOutput.write(Data("{}\n".utf8))
}

guard let data = try? FileHandle.standardInput.readToEnd(),
      let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      let name = event["hook_event_name"] as? String
else { exit(0) }

// Cursor names a chat by its conversation; the others by their session. Each but Claude Code's
// gets a prefix, so two tools' ids never meet.
let rawId = (isCursor ? event["conversation_id"] : event["session_id"]) as? String ?? ""
guard !rawId.isEmpty else { exit(0) }
let sessionId = (isCursor ? "cursor-" : isCodex ? "codex-" : isGemini ? "gemini-" : "") + rawId

/// Cursor's beforeSubmitPrompt reads a `continue` answer; say yes explicitly rather than nothing.
if isCursor, name == "beforeSubmitPrompt" { print("{\"continue\":true}") }

func string(_ key: String) -> String? {
    (event[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
}

/// The MCP server of a tool call: the hook's own provenance, else the `mcp__<server>__` prefix.
func mcpServer(of tool: String) -> String? {
    if let provenance = event["mcp_server"] as? [String: Any], let server = provenance["name"] as? String {
        return server
    }
    guard tool.hasPrefix("mcp__") else { return nil }
    let rest = tool.dropFirst(5)
    guard let end = rest.range(of: "__") else { return nil }
    return String(rest[..<end.lowerBound])
}

/// A process's controlling terminal, as /dev/ttys…; nil without one.
func terminal(of pid: Int32) -> String? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    let device = info.kp_eproc.e_tdev
    guard device != -1, let name = devname(device, S_IFCHR) else { return nil }
    let text = String(cString: name)
    return text.isEmpty || text == "??" ? nil : "/dev/" + text
}

/// The Claude Code process above this hook: the first ancestor whose executable path says claude.
func claudePid() -> Int32? {
    var pid = getppid()
    for _ in 0..<8 where pid > 1 {
        var path = [CChar](repeating: 0, count: 4096)
        if proc_pidpath(pid, &path, UInt32(path.count)) > 0,
           String(cString: path).lowercased().contains("claude") {
            return pid
        }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        pid = info.kp_eproc.e_ppid
    }
    return nil
}

func oneLine(_ text: String, max: Int) -> String {
    let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    return flat.count > max ? String(flat.prefix(max - 1)) + "…" : flat
}

try? FileManager.default.createDirectory(at: NotchPaths.sessions, withIntermediateDirectories: true)

if name == "SessionEnd" || (isCursor && name == "sessionEnd") {
    try? FileManager.default.removeItem(at: NotchPaths.state(sessionId))
    try? FileManager.default.removeItem(at: NotchPaths.lock(sessionId))
    exit(0)
}

// One writer at a time per session: parallel tool calls raise their hooks concurrently. A writer
// holds the lock for a few milliseconds; one stuck longer than ~300 ms costs this event, never
// the session's time.
let lockFd = open(NotchPaths.lock(sessionId).path, O_CREAT | O_RDWR, 0o600)
guard lockFd >= 0 else { exit(0) }
var isLocked = false
for _ in 0..<60 {
    if flock(lockFd, LOCK_EX | LOCK_NB) == 0 { isLocked = true; break }
    usleep(5_000)
}
guard isLocked else { close(lockFd); exit(0) }

let file = NotchPaths.state(sessionId)
let env = ProcessInfo.processInfo.environment
let cursorRoot = (event["workspace_roots"] as? [String])?.first ?? env["CURSOR_PROJECT_DIR"]
var state = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder.notch.decode(SessionState.self, from: $0) }
    ?? SessionState(id: sessionId, cwd: (isCursor ? cursorRoot : string("cwd")) ?? FileManager.default.currentDirectoryPath, now: now)

state.updatedAt = now
if isCursor {
    state.entrypoint = "cursor-agent"
    if let model = string("model") { state.model = model }
    if state.appBundleId == nil { state.appBundleId = env["__CFBundleIdentifier"] ?? "com.todesktop.230313mzl4w4u92" }
} else if isCodex || isGemini {
    state.entrypoint = isCodex ? AgentKind.codexEntrypoint : AgentKind.geminiEntrypoint
    if let model = string("model") { state.model = model }
    if state.pid == nil { state.pid = agentPid(named: isCodex ? "codex" : "gemini") }
    if state.appBundleId == nil { state.appBundleId = env["__CFBundleIdentifier"] }
} else {
    if state.pid == nil { state.pid = claudePid() }
    if state.appBundleId == nil { state.appBundleId = env["__CFBundleIdentifier"] }
    if state.entrypoint == nil { state.entrypoint = env["CLAUDE_CODE_ENTRYPOINT"] }
}
// The terminal it runs in, once: the agent's controlling terminal, and tmux's pane.
if state.tty == nil, let pid = state.pid { state.tty = terminal(of: pid) }
if state.tmuxPane == nil, env["TMUX"] != nil, let pane = env["TMUX_PANE"], !pane.isEmpty { state.tmuxPane = pane }
// A rename: every event carries the name as it is now.
if let title = string("session_title") { state.sessionTitle = oneLine(title, max: 120) }

let agentId = string("agent_id")
let tool = string("tool_name")
let toolUseId = string("tool_use_id") ?? UUID().uuidString
// Only Claude Code's transcripts are read (for interrupts and titles); the others' differ.
if isClaude, agentId == nil, let path = string("transcript_path") { state.transcriptPath = path }

func agentIndex(_ id: String?) -> Int? {
    guard let id else { return nil }
    return state.agents.firstIndex { $0.id == id }
}

/// The text between `<tag>` and `</tag>` in `text`.
func tagged(_ tag: String, in text: String) -> String? {
    guard let open = text.range(of: "<\(tag)>"), let close = text.range(of: "</\(tag)>", range: open.upperBound..<text.endIndex) else { return nil }
    return String(text[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Applies `change` to the subagent `agentId` names, or to the main thread when it names none.
func onLoop(_ change: (inout ToolNow?, inout Int, inout [String: Int]) -> Void) {
    if let agentId, let index = state.agents.firstIndex(where: { $0.id == agentId }) {
        var agent = state.agents[index]
        change(&agent.current, &agent.toolCount, &agent.mcp)
        state.agents[index] = agent
    } else {
        var (current, count, mcp) = (state.current, state.toolCount, state.mcp)
        change(&current, &count, &mcp)
        (state.current, state.toolCount, state.mcp) = (current, count, mcp)
    }
}

/// This thread (the main one, or the subagent the event names) is blocked on you. Each thread
/// keeps its own wait: another thread starting or answering one does not touch it.
func wait(for reason: String) {
    state.beginWait(reason, tool: tool, agent: agentId, at: now)
}

/// Every wait is over: a new session, an interrupt, another agent's turn boundary.
func clearWait() {
    state.clearWaits()
}

/// A turn began or ended: the main thread's waits are over; a background subagent's are not.
func clearMainWait() {
    state.endWaits { $0.agent == nil }
}

/// Ends the wait when the tool it was on finishes, in the same thread; other work does not.
/// A wait that names no tool (a notification's) ends with any tool finishing.
func resumeWork() {
    state.endWaits { $0.tool == nil || ($0.tool == tool && $0.agent == agentId) }
}

/// "your answer" for a question, with the subagent's type when one asks.
func questionReason() -> String {
    "your answer" + (agentIndex(agentId).map { " (\(state.agents[$0].type))" } ?? "")
}

/// Prompts handed to the app that an event shows were answered (in the editor, or by a tool that
/// went ahead): the app takes their buttons away. `thread` nil is the main thread.
func resolvePending(where answered: (PendingPermission) -> Bool) {
    guard let pending = state.pendingPermissions, !pending.isEmpty else { return }
    state.pendingPermissions = pending.filter { !answered($0) }
}

/// What a tool call acts on, in one line: the command, the file, the URL, the query.
func approvalDetail(tool: String, input: [String: Any]) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    func path(_ key: String) -> String? {
        (input[key] as? String).map { $0.hasPrefix(home) ? "~" + $0.dropFirst(home.count) : $0 }
    }
    switch tool {
    case "Bash": return oneLine(input["command"] as? String ?? "", max: 400)
    case "Edit", "MultiEdit", "Write", "Read": return path("file_path") ?? tool
    case "NotebookEdit": return path("notebook_path") ?? tool
    case "WebFetch": return input["url"] as? String ?? tool
    case "WebSearch": return input["query"] as? String ?? tool
    case "Glob", "Grep": return [input["pattern"] as? String, path("path")].compactMap { $0 }.joined(separator: " in ")
    default:
        let pairs = input.sorted { $0.key < $1.key }.prefix(3).map { key, value in "\(key): \(oneLine("\(value)", max: 60))" }
        return oneLine(pairs.joined(separator: " · "), max: 240)
    }
}

/// The push or deploy a shell command makes, as a short name: "git push", "vercel --prod"…
func shipCommand(_ command: String) -> String? {
    let patterns: [(String, String)] = [
        (#"\bgit\s+push\b"#, "git push"),
        (#"\b(vercel|netlify)\b.*--prod\b"#, "deploy"),
        (#"\b(fly|flyctl)\s+deploy\b"#, "fly deploy"),
        (#"\bkubectl\s+(apply|rollout|set\s+image)\b"#, "kubectl"),
        (#"\bhelm\s+(upgrade|install)\b"#, "helm"),
        (#"\bterraform\s+apply\b"#, "terraform apply"),
        (#"\beas\s+(submit|update)\b"#, "eas"),
        (#"\b(npm|pnpm|yarn|bun)\s+(run\s+)?deploy\b"#, "deploy"),
        (#"\bgh\s+(pr\s+merge|release\s+create)\b"#, "gh"),
        (#"\b(cap|serverless|sls|cdk)\s+deploy\b"#, "deploy"),
    ]
    for (pattern, name) in patterns where command.range(of: pattern, options: .regularExpression) != nil { return name }
    return nil
}

/// A few lines of what a call changes, for the approval card: an edit's old and new lines, the
/// start of a file it writes, the start of a plan. Indentation kept, each line cut at 160.
func changePreview(tool: String, input: [String: Any]) -> [ApprovalRequest.PreviewLine]? {
    func lines(_ text: Any?, _ max: Int, skipBlank: Bool = false) -> [String] {
        let all = ((text as? String) ?? "").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let kept = skipBlank ? all.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty } : all
        return kept.prefix(max).map { line in
            let trimmed = line.replacingOccurrences(of: "\t", with: "    ").replacingOccurrences(of: "\r", with: "")
            return trimmed.count > 160 ? String(trimmed.prefix(159)) + "…" : trimmed
        }
    }
    var out: [ApprovalRequest.PreviewLine] = []
    switch tool {
    case "Edit", "MultiEdit":
        let edit = tool == "MultiEdit" ? ((input["edits"] as? [[String: Any]])?.first ?? [:]) : input
        out += lines(edit["old_string"], 4).map { .init(.removed, $0) }
        out += lines(edit["new_string"], 4).map { .init(.added, $0) }
    case "Write":
        out += lines(input["content"], 6).map { .init(.added, $0) }
    case "ExitPlanMode":
        out += lines(input["plan"], 8, skipBlank: true).map { .init(.context, $0) }
    default:
        return nil
    }
    return out.isEmpty ? nil : out
}

/// The session-scoped part of Claude Code's own suggestions: rules it would add, directories it
/// would allow, accept-edits mode. Every one is rewritten to last for the session only; nothing is
/// ever written to a settings file.
func sessionSuggestions(_ raw: Any?) -> (updates: [[String: Any]], labels: [String]) {
    var updates: [[String: Any]] = []
    var labels: [String] = []
    for case var update as [String: Any] in (raw as? [Any]) ?? [] {
        switch update["type"] as? String {
        case "addRules":
            guard update["behavior"] as? String == "allow", let rules = update["rules"] as? [[String: Any]], !rules.isEmpty else { continue }
            labels += rules.map { rule in
                let name = rule["toolName"] as? String ?? "tool"
                return (rule["ruleContent"] as? String).map { "\(name)(\(oneLine($0, max: 120)))" } ?? name
            }
        case "addDirectories":
            guard let dirs = update["directories"] as? [String], !dirs.isEmpty else { continue }
            labels += dirs.map { "folder \($0)" }
        case "setMode":
            guard update["mode"] as? String == "acceptEdits" else { continue }
            labels.append("accept edits")
        default:
            continue
        }
        update["destination"] = "session"
        updates.append(update)
    }
    return (updates, labels)
}

/// The prompt to hand to the app once the state is written, if this event is one.
var approval: (request: ApprovalRequest, updates: [[String: Any]])?

// Cursor's agent: only events that act on nothing we answer (the permission hooks are left
// alone), so tools show once they finish and subagents once they stop.
if isCursor {
    switch name {
    case "sessionStart":
        state.phase = .idle
    case "beforeSubmitPrompt":
        state.phase = .working
        clearWait()
        state.turnStartedAt = now
        state.finishedAt = nil
        if let prompt = string("prompt"), !prompt.hasPrefix("<"), state.firstPrompt == nil {
            state.firstPrompt = oneLine(prompt, max: 120)
        }
    case "postToolUse", "postToolUseFailure":
        let name = tool ?? "tool"
        let ms = (event["duration"] as? Double) ?? 0
        let detail = (event["tool_input"] as? [String: Any])?["command"] as? String
        state.toolCount += 1
        state.lastTool = ToolNow(id: toolUseId, name: detail.map { "\(name) · \(oneLine($0, max: 40))" } ?? name,
                                 server: nil, since: now - ms / 1000)
        if state.phase == .idle { state.phase = .working }
    case "afterMCPExecution":
        if let server = string("mcp_server_name") {
            state.mcp[server, default: 0] += 1
            state.lastTool = ToolNow(id: toolUseId, name: "mcp__\(server)__\(tool ?? "tool")", server: server,
                                     since: now - ((event["duration"] as? Double) ?? 0) / 1000)
        }
    case "subagentStop":
        let ms = (event["duration_ms"] as? Double) ?? 0
        var agent = AgentNow(id: string("subagent_id") ?? UUID().uuidString, type: string("subagent_type") ?? "subagent", startedAt: now - ms / 1000)
        agent.description = (string("description") ?? string("task")).map { oneLine($0, max: 70) }
        agent.toolCount = (event["tool_call_count"] as? Int) ?? 0
        let status = string("status") ?? "completed"
        agent.end(status == "completed" ? .done : status == "error" ? .failed : .stopped, at: now)
        state.agents.append(agent)
    case "stop":
        state.phase = .idle
        clearWait()
        state.finishedAt = now
        if let started = state.turnStartedAt { state.lastTurnSeconds = now - started }
    default:
        break
    }
} else if isGemini {
    // Gemini CLI: its turn (BeforeAgent … AfterAgent), its tools, and the notification it raises
    // when a tool waits for your confirmation. Its other hooks (the model's) are not hooked.
    switch name {
    case "SessionStart":
        state.phase = .idle
        clearWait()
        state.current = nil
    case "BeforeAgent":
        state.phase = .working
        clearWait()
        state.turnStartedAt = now
        state.finishedAt = nil
        if let prompt = string("prompt"), state.firstPrompt == nil { state.firstPrompt = oneLine(prompt, max: 120) }
    case "BeforeTool":
        guard let tool else { break }
        let server = (event["mcp_context"] as? [String: Any])?["server_name"] as? String
        state.current = ToolNow(id: toolUseId, name: tool, server: server, since: now)
        state.toolCount += 1
        if let server { state.mcp[server, default: 0] += 1 }
        if state.phase != .waiting { state.phase = .working }
    case "AfterTool":
        if let current = state.current, current.name == tool {
            state.lastTool = current
            state.current = nil
        }
        if state.phase == .waiting {
            state.phase = .working
            clearWait()
        }
    case "Notification":
        if (string("notification_type") ?? "").lowercased().contains("permission") {
            wait(for: "permission: \(state.current?.name ?? "a tool")")
        }
    case "AfterAgent":
        state.phase = .idle
        clearWait()
        state.current = nil
        state.finishedAt = now
        if let started = state.turnStartedAt { state.lastTurnSeconds = now - started }
    default:
        break
    }
} else {
switch name {
case "SessionStart":
    state.pendingPermissions = nil
    state.phase = .idle
    clearWait()
    state.current = nil
    if let model = string("model") { state.model = model }

case "PostModelSwitch":
    if let model = string("to_model") { state.model = model }

case "UserPromptSubmit":
    // A new turn: the main thread's prompts are over (a background subagent's may not be).
    resolvePending { $0.agent == nil }
    clearMainWait()
    state.phase = .working
    state.turnStartedAt = now
    state.finishedAt = nil
    // A background agent that finished reports back as a task notification naming it.
    if let prompt = string("prompt"), prompt.contains("<task-notification>") {
        let status = tagged("status", in: prompt) ?? "completed"
        let outcome: AgentOutcome = status == "completed" ? .done : status == "failed" ? .failed : .stopped
        let taskId = tagged("task-id", in: prompt)
        let callId = tagged("tool-use-id", in: prompt)
        if let index = state.agents.firstIndex(where: { $0.id == taskId || ($0.toolUseId != nil && $0.toolUseId == callId) }) {
            state.agents[index].end(outcome, at: now)
        }
    }
    // Only what you typed names the session: task notifications and wake-ups arrive as prompts too.
    let isYours = ["user", nil].contains(string("source"))
    if isYours, let prompt = string("prompt"), !prompt.hasPrefix("<"), state.firstPrompt == nil {
        state.firstPrompt = oneLine(prompt, max: 120)
    }

case "PreToolUse":
    // A new call in a thread means its earlier prompt was answered.
    resolvePending { $0.agent == agentId }
    guard let tool else { break }
    let server = mcpServer(of: tool)
    onLoop { current, count, mcp in
        current = ToolNow(id: toolUseId, name: tool, server: server, since: now)
        count += 1
        if let server { mcp[server, default: 0] += 1 }
    }
    // An Agent call: remember what it asked for until its subagent starts.
    if agentId == nil, tool == "Agent" || tool == "Task" {
        let input = event["tool_input"] as? [String: Any] ?? [:]
        let pending = PendingAgent(
            toolUseId: toolUseId,
            type: (input["subagent_type"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "general-purpose",
            description: (input["description"] as? String).map { oneLine($0, max: 70) },
            model: input["model"] as? String,
            isBackground: input["run_in_background"] as? Bool ?? true,
            since: now
        )
        state.pendingAgents = ((state.pendingAgents ?? []) + [pending]).filter { now - $0.since < 600 }
    }
    // A push or a deploy: the notch watches Prod for a while after it.
    if tool == "Bash", let command = (event["tool_input"] as? [String: Any])?["command"] as? String,
       let shipped = shipCommand(command) {
        state.shippedAt = now
        state.shipped = shipped
    }
    // Claude's to-do list: each TodoWrite sets all of it.
    if isClaude, agentId == nil, tool == "TodoWrite",
       let items = (event["tool_input"] as? [String: Any])?["todos"] as? [[String: Any]] {
        state.todos = items.compactMap { item in
            guard let content = item["content"] as? String, let status = TodoItem.Status(rawValue: item["status"] as? String ?? "") else { return nil }
            return TodoItem(content: oneLine(content, max: 120), status: status, activeForm: (item["activeForm"] as? String).map { oneLine($0, max: 120) })
        }
    }
    if tool == "AskUserQuestion" {
        wait(for: questionReason())
    } else if agentId == nil, tool == "ExitPlanMode" {
        wait(for: "plan approval")
    } else if state.phase != .waiting {
        state.phase = .working
    }

case "PermissionRequest":
    // A question or a plan raises a permission request too, but it is not yes-or-no.
    // The main thread's or a subagent's: each is its own wait and its own prompt.
    if tool == "AskUserQuestion" {
        wait(for: questionReason())
        // Every question with 2 or more plain options can be answered from the notch, several
        // questions and several picks included; a typed answer ("Other") only in the editor.
        let input = event["tool_input"] as? [String: Any] ?? [:]
        if let questions = ApprovalRequest.Question.parse(toolInput: input) {
            let id = UUID().uuidString
            let agentType = agentIndex(agentId).map { state.agents[$0].type }
            let request = ApprovalRequest(id: id, session: sessionId, agent: agentId, agentType: agentType, tool: "AskUserQuestion", server: nil,
                                          detail: oneLine(questions.map(\.text).joined(separator: " · "), max: 300), sessionRules: [], since: now,
                                          questions: questions)
            approval = (request, [])
            state.pendingPermissions = (state.pendingPermissions ?? []) + [PendingPermission(id: id, tool: "AskUserQuestion", agent: agentId, since: now)]
        }
        break
    }
    if agentId == nil, tool == "ExitPlanMode" {
        wait(for: "plan approval")
        // The plan can be approved from the notch too (Claude Code's own suggestions, such as
        // accepting edits for the session, as the second button), or sent back to keep planning.
        if isClaude {
            let id = UUID().uuidString
            let input = event["tool_input"] as? [String: Any] ?? [:]
            let suggestions = sessionSuggestions(event["permission_suggestions"])
            let request = ApprovalRequest(id: id, session: sessionId, agent: nil, agentType: nil, tool: "ExitPlanMode", server: nil,
                                          detail: "", sessionRules: suggestions.labels, since: now,
                                          preview: changePreview(tool: "ExitPlanMode", input: input))
            approval = (request, suggestions.updates)
            state.pendingPermissions = (state.pendingPermissions ?? []) + [PendingPermission(id: id, tool: "ExitPlanMode", agent: nil, since: now)]
        }
        break
    }
    let what = tool.map { mcpServer(of: $0).map { server in "\(server) MCP" } ?? $0 } ?? "a tool"
    let agentType = agentIndex(agentId).map { state.agents[$0].type }
    wait(for: "permission: \(what)\(agentType.map { " (\($0))" } ?? "")")
    // Codex's prompts are answered in Codex: it takes no session rules, so the notch offers none.
    if isClaude, let tool, tool != "AskUserQuestion", tool != "ExitPlanMode" {
        let id = UUID().uuidString
        let server = mcpServer(of: tool)
        let input = event["tool_input"] as? [String: Any] ?? [:]
        // What your ask rules cover (rm, mv, git push…) you approve each time: no session rules,
        // whatever Claude Code suggested. The settings are read now, so an edit counts at once.
        let askRule = AskRules.match(tool: tool, input: input,
                                     rules: AskRules.load(projectDirs: [string("cwd"), state.cwd].compactMap { $0 }))
        let suggestions = askRule == nil ? sessionSuggestions(event["permission_suggestions"]) : (updates: [], labels: [])
        let request = ApprovalRequest(
            id: id, session: sessionId, agent: agentId, agentType: agentType, tool: tool, server: server,
            detail: approvalDetail(tool: tool, input: input),
            sessionRules: suggestions.labels, since: now, askRule: askRule,
            preview: changePreview(tool: tool, input: input)
        )
        approval = (request, suggestions.updates)
        state.pendingPermissions = (state.pendingPermissions ?? []) + [PendingPermission(id: id, tool: tool, agent: agentId, since: now)]
    }

case "PostToolUse", "PostToolUseFailure", "PermissionDenied":
    resolvePending { $0.agent == agentId && $0.tool == tool }
    if let index = agentIndex(agentId) {
        var agent = state.agents[index]
        if agent.current?.id == toolUseId || agent.current?.name == tool {
            agent.lastTool = agent.current
            agent.current = nil
        }
        state.agents[index] = agent
    } else {
        if state.current?.id == toolUseId || state.current?.name == tool {
            state.lastTool = state.current
            state.current = nil
        }
        // A foreground Agent call returns when its subagent is done; a background one returns at once.
        if tool == "Agent" || tool == "Task",
           let index = state.agents.firstIndex(where: { $0.toolUseId == toolUseId && $0.isBackground == false }) {
            state.agents[index].end(name == "PostToolUse" ? .done : .failed, at: now)
        }
    }
    resumeWork()

case "Notification":
    switch string("notification_type") {
    case "permission_prompt":
        if state.phase != .waiting { wait(for: "permission") }
    case "elicitation_dialog":
        wait(for: "your input")
    default:
        break
    }

case "SubagentStart":
    if let agentId, agentIndex(agentId) == nil {
        let type = string("agent_type") ?? "agent"
        var agent = AgentNow(id: agentId, type: type, startedAt: now)
        // Match the oldest Agent call of this type still waiting for its subagent.
        var pending = state.pendingAgents ?? []
        if let match = pending.firstIndex(where: { $0.type == type }) ?? (pending.isEmpty ? nil : 0) {
            let call = pending.remove(at: match)
            agent.description = call.description
            agent.model = call.model
            agent.isBackground = call.isBackground
            agent.toolUseId = call.toolUseId
        }
        state.pendingAgents = pending
        state.agents.append(agent)
    }

case "SubagentStop":
    resolvePending { $0.agent == agentId }
    state.endWaits { $0.agent == agentId }
    if let index = agentIndex(agentId) { state.agents[index].end(.done, at: now) }

case "Interrupt":
    // Codex: Esc. The turn is over, as at Stop.
    state.phase = .idle
    clearWait()
    state.current = nil
    state.finishedAt = now
    if let started = state.turnStartedAt { state.lastTurnSeconds = now - started }
    for index in state.agents.indices where state.agents[index].isRunning { state.agents[index].end(.stopped, at: now) }

case "Stop":
    resolvePending { $0.agent == nil }
    clearMainWait()
    state.phase = .idle
    state.current = nil
    state.finishedAt = now
    if let started = state.turnStartedAt { state.lastTurnSeconds = now - started }
    let tasks = event["background_tasks"] as? [[String: Any]] ?? []
    let live = tasks.filter { ["running", "pending"].contains($0["status"] as? String ?? "") }
    state.backgroundTasks = live.count
    // The turn is over: every subagent that is not a live background task has ended,
    // including ones an interrupt stopped (which raise no SubagentStop).
    let liveIds = Set(live.compactMap { $0["id"] as? String })
    var liveTypes = live.compactMap { $0["agent_type"] as? String }
    for index in state.agents.indices where state.agents[index].isRunning {
        let agent = state.agents[index]
        if liveIds.contains(agent.id) { continue }
        if let slot = liveTypes.firstIndex(of: agent.type), agent.isBackground != false {
            liveTypes.remove(at: slot)
            continue
        }
        state.agents[index].end(.stopped, at: now)
    }
    state.pendingAgents = []

default:
    break
}
}

// Old subagents leave; the newest stay.
state.agents.removeAll { agent in agent.endedAt.map { now - $0 > agentLinger } ?? false }
if state.agents.count > maxAgents { state.agents.removeFirst(state.agents.count - maxAgents) }

// Subagents that are not running take their prompts and waits with them, including one this file
// never saw start (or pruned above): its wait would otherwise outlive the turn with no prompt to answer.
let liveAgents = Set(state.runningAgents.map(\.id))
if let pending = state.pendingPermissions {
    state.pendingPermissions = pending.filter { $0.agent == nil || liveAgents.contains($0.agent!) }
}
state.endWaits { wait in wait.agent.map { !liveAgents.contains($0) } ?? false }
// Any thread still waiting keeps the session waiting, whatever else this event did to its phase.
if state.waits?.isEmpty == false { state.settleWaits() }

if let encoded = try? JSONEncoder.notch.encode(state) {
    try? encoded.write(to: file, options: .atomic)
}
flock(lockFd, LOCK_UN)

func applyControl() {
    guard var control = SessionControl.read(sessionId) else { return }
    // Paused: the next tool call waits until you resume or stop (at most the hook's 30 minutes).
    if name == "PreToolUse" {
        let until = now + 1780
        while control.pause == true, control.stop != true, Date().timeIntervalSince1970 < until {
            if getppid() == 1 { exit(0) }
            usleep(500_000)
            guard let next = SessionControl.read(sessionId) else { return }
            control = next
        }
    }
    if control.stop == true {
        // Only the stop (and pause and note) is given up; a pull request's feedback waits.
        SessionControl.update(sessionId) { $0.stop = nil; $0.pause = nil; $0.note = nil }
        let output: [String: Any] = ["continue": false, "stopReason": "Stopped from AI Notch."]
        if let json = try? JSONSerialization.data(withJSONObject: output) {
            FileHandle.standardOutput.write(json + Data("\n".utf8))
        }
        exit(0)
    }
    if name == "PreToolUse", !(control.note ?? "").isEmpty || !(control.feedback ?? "").isEmpty {
        // Taken under the session's lock, so a brief queued at the same moment is not lost; the
        // file is cleared as it is handed over.
        var note: String?
        var feedback: String?
        var feedbackPR: Int?
        let taken = SessionControl.update(sessionId) { current in
            note = current.note
            if let text = current.feedback, Date().timeIntervalSince1970 - (current.feedbackAt ?? 0) < SessionControl.feedbackLifetime {
                feedback = text
                feedbackPR = current.feedbackPR
            }
            current.note = nil
            current.feedback = nil
            current.feedbackPR = nil
            current.feedbackAt = nil
        }
        var parts: [String] = []
        if let note, !note.isEmpty { parts.append("A note from the user, sent from AI Notch while you work: \(SessionControl.cut(note, 2000))") }
        if let feedback { parts.append(SessionControl.feedbackContext(feedback, pullRequest: feedbackPR)) }
        if taken, !parts.isEmpty {
            let output: [String: Any] = ["hookSpecificOutput": [
                "hookEventName": "PreToolUse",
                "additionalContext": parts.joined(separator: "\n\n"),
            ]]
            if let json = try? JSONSerialization.data(withJSONObject: output) {
                FileHandle.standardOutput.write(json + Data("\n".utf8))
            }
            exit(0)
        }
    }
}

// Stop, pause or a note from the notch (Claude Code only). A turn's end clears what was asked;
// otherwise a stop or a note is acted on at the next tool call, a pause holds it.
if isClaude {
    if name == "SessionEnd" {
        SessionControl.write(nil, for: sessionId)
    } else if name == "Stop" {
        // A pull request's feedback outlives the turn (the app puts it on the clipboard if Claude
        // finished first); everything else asked is over.
        if SessionControl.read(sessionId) != nil {
            SessionControl.update(sessionId) { $0.stop = nil; $0.pause = nil; $0.note = nil }
        }
    } else if name == "PreToolUse" || name == "PostToolUse" || name == "PostToolUseFailure" {
        applyControl()
    }
}

guard let approval else { exit(0) }

// Ask the app, outside the lock: the wait can be long and other events of this session must not
// queue behind it. The editor's prompt is up meanwhile; whichever is answered first counts, and an
// answer here after one there changes nothing. No app, no answer, or "withdraw": no output at all.
guard let socket = ApprovalSocket.connect(to: ApprovalSocket.path()) else { exit(0) }
guard ApprovalSocket.send(approval.request, to: socket) else { exit(0) }
var reply: ApprovalReply?
while reply == nil {
    var poller = pollfd(fd: socket, events: Int16(POLLIN), revents: 0)
    let ready = poll(&poller, 1, 1000)
    // Claude Code stops its hooks when it exits; an orphan stops itself.
    if getppid() == 1 { exit(0) }
    if ready < 0, errno != EINTR { exit(0) }
    guard ready > 0 else { continue }
    guard let line = ApprovalSocket.readLine(from: socket),
          let decoded = try? JSONDecoder().decode(ApprovalReply.self, from: line),
          decoded.id == approval.request.id else { exit(0) }
    reply = decoded
}
close(socket)

var decision: [String: Any]
// A question takes only an answer: a plain Allow or Deny must never reach it.
if approval.request.tool == "AskUserQuestion", reply!.decision != .answer { exit(0) }
switch reply!.decision {
case .allow:
    decision = ["behavior": "allow"]
case .allowSession:
    decision = ["behavior": "allow"]
    if !approval.updates.isEmpty { decision["updatedPermissions"] = approval.updates }
case .deny:
    decision = ["behavior": "deny", "message": approval.request.tool == "ExitPlanMode"
        ? "The user did not approve this plan from AI Notch. Stay in plan mode and ask what to change."
        : "The user denied this from AI Notch. Do not retry it; ask the user how to proceed if it matters."]
case .answer:
    // Only options it offered, for the questions it asked, one set of picks per question;
    // anything else says nothing. Several picks of a multi-select question are joined with ", ".
    guard approval.request.tool == "AskUserQuestion" else { exit(0) }
    guard let picks = reply!.answers ?? reply!.answer.map({ [[$0]] }),
          let answers = ApprovalRequest.Question.answers(picks: picks, for: approval.request.allQuestions) else { exit(0) }
    var input = event["tool_input"] as? [String: Any] ?? [:]
    input["answers"] = answers
    decision = ["behavior": "allow", "updatedInput": input]
case .withdraw:
    exit(0)
}
// A plan is approved only with its input handed back.
if approval.request.tool == "ExitPlanMode", decision["behavior"] as? String == "allow", decision["updatedInput"] == nil {
    decision["updatedInput"] = event["tool_input"] as? [String: Any] ?? [:]
}
let output: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
guard let json = try? JSONSerialization.data(withJSONObject: output) else { exit(0) }
FileHandle.standardOutput.write(json)
FileHandle.standardOutput.write(Data("\n".utf8))

// The answer is in: the session works on. Best effort, under the same bounded lock.
for _ in 0..<60 {
    if flock(lockFd, LOCK_EX | LOCK_NB) == 0 {
        if let data = try? Data(contentsOf: file), var after = try? JSONDecoder.notch.decode(SessionState.self, from: data) {
            after.pendingPermissions = after.pendingPermissions?.filter { $0.id != approval.request.id }
            // Only this prompt's own wait ends; another thread's keeps the session waiting.
            after.endWaits { $0.since == now && $0.agent == approval.request.agent && $0.tool == approval.request.tool }
            after.updatedAt = Date().timeIntervalSince1970
            if let encoded = try? JSONEncoder.notch.encode(after) { try? encoded.write(to: file, options: .atomic) }
        }
        flock(lockFd, LOCK_UN)
        break
    }
    usleep(5_000)
}
exit(0)
