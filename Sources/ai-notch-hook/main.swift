import Darwin
import Foundation
import NotchCore

// Claude Code runs this on every hook event (the event's JSON on stdin) and folds the event
// into the session's state file. It always exits 0 and prints nothing, so it can never block or
// change what the session does: a failure only means the notch misses one update. The one
// exception is a permission prompt you answer by clicking in the notch: then it prints that
// answer (see the end of this file). Without a click it prints nothing, as before.
// Cursor's own agent runs it too (`ai-notch-hook cursor`, from ~/.cursor/hooks.json), on
// the events that act on nothing it answers; see the Cursor section below.

// `ai-notch-hook --probe`: the app's setup runs this to learn whether macOS lets the hook run at
// all (a quarantined helper hangs in exec). It reads nothing, writes nothing, prints nothing.
if CommandLine.arguments.dropFirst().first == "--probe" { exit(0) }

let now = Date().timeIntervalSince1970
let maxAgents = 20
/// Ended subagents stay listed this long.
let agentLinger: Double = 180

let isCursor = CommandLine.arguments.dropFirst().first == "cursor"

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
    let args = ["/bin/sh", "-c", rest].map { strdup($0) } + [nil]
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

if CommandLine.arguments.dropFirst().first == "statusline" { runStatusLine() }

guard let data = try? FileHandle.standardInput.readToEnd(),
      let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      let name = event["hook_event_name"] as? String
else { exit(0) }

// Cursor names a chat by its conversation; Claude Code by its session.
let rawId = (isCursor ? event["conversation_id"] : event["session_id"]) as? String ?? ""
guard !rawId.isEmpty else { exit(0) }
let sessionId = isCursor ? "cursor-\(rawId)" : rawId

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
} else {
    if state.pid == nil { state.pid = claudePid() }
    if state.appBundleId == nil { state.appBundleId = env["__CFBundleIdentifier"] }
    if state.entrypoint == nil { state.entrypoint = env["CLAUDE_CODE_ENTRYPOINT"] }
}
// A rename: every event carries the name as it is now.
if let title = string("session_title") { state.sessionTitle = oneLine(title, max: 120) }

let agentId = string("agent_id")
let tool = string("tool_name")
let toolUseId = string("tool_use_id") ?? UUID().uuidString
if agentId == nil, let path = string("transcript_path") { state.transcriptPath = path }

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

func wait(for reason: String) {
    state.phase = .waiting
    state.waitingFor = reason
    state.waitingSince = now
    state.waitingTool = tool
    state.waitingAgent = agentId
}

func clearWait() {
    state.waitingFor = nil
    state.waitingSince = nil
    state.waitingTool = nil
    state.waitingAgent = nil
}

/// Ends the wait when the tool it was on finishes, in the same thread; other work does not.
func resumeWork() {
    guard state.phase == .waiting, state.waitingTool == nil || (state.waitingTool == tool && state.waitingAgent == agentId) else { return }
    state.phase = .working
    clearWait()
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
    state.phase = .working
    clearWait()
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
    if agentId == nil, tool == "AskUserQuestion" {
        wait(for: "your answer")
    } else if agentId == nil, tool == "ExitPlanMode" {
        wait(for: "plan approval")
    } else if state.phase != .waiting {
        state.phase = .working
    }

case "PermissionRequest":
    // A question or a plan raises a permission request too, but it is not yes-or-no.
    if agentId == nil, tool == "AskUserQuestion" {
        wait(for: "your answer")
        // One question with plain options can be answered from the notch too; anything more
        // (several questions, several picks) only in the editor.
        let input = event["tool_input"] as? [String: Any] ?? [:]
        let questions = input["questions"] as? [[String: Any]] ?? []
        if questions.count == 1, let first = questions.first, first["multiSelect"] as? Bool != true,
           let text = first["question"] as? String,
           case let labels = (first["options"] as? [[String: Any]] ?? []).compactMap({ $0["label"] as? String }), labels.count >= 2 {
            let id = UUID().uuidString
            let request = ApprovalRequest(id: id, session: sessionId, agent: nil, agentType: nil, tool: "AskUserQuestion", server: nil,
                                          detail: oneLine(text, max: 300), sessionRules: [], since: now,
                                          question: .init(text: text, header: first["header"] as? String, options: labels))
            approval = (request, [])
            state.pendingPermissions = (state.pendingPermissions ?? []) + [PendingPermission(id: id, tool: "AskUserQuestion", agent: nil, since: now)]
        }
        break
    }
    if agentId == nil, tool == "ExitPlanMode" {
        wait(for: "plan approval")
        break
    }
    let what = tool.map { mcpServer(of: $0).map { server in "\(server) MCP" } ?? $0 } ?? "a tool"
    let agentType = agentIndex(agentId).map { state.agents[$0].type }
    wait(for: "permission: \(what)\(agentType.map { " (\($0))" } ?? "")")
    if let tool, tool != "AskUserQuestion", tool != "ExitPlanMode" {
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
            sessionRules: suggestions.labels, since: now, askRule: askRule
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
    if let index = agentIndex(agentId) { state.agents[index].end(.done, at: now) }

case "Stop":
    resolvePending { $0.agent == nil }
    state.phase = .idle
    clearWait()
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

// Subagents that left take their prompts with them.
if let pending = state.pendingPermissions {
    let live = Set(state.runningAgents.map(\.id))
    state.pendingPermissions = pending.filter { $0.agent == nil || live.contains($0.agent!) }
}

if let encoded = try? JSONEncoder.notch.encode(state) {
    try? encoded.write(to: file, options: .atomic)
}
flock(lockFd, LOCK_UN)

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
switch reply!.decision {
case .allow:
    decision = ["behavior": "allow"]
case .allowSession:
    decision = ["behavior": "allow"]
    if !approval.updates.isEmpty { decision["updatedPermissions"] = approval.updates }
case .deny:
    decision = ["behavior": "deny", "message": "The user denied this from AI Notch. Do not retry it; ask the user how to proceed if it matters."]
case .answer:
    // Only one of the options it offered, for the question it asked; anything else says nothing.
    guard let question = approval.request.question, let picked = reply!.answer, question.options.contains(picked) else { exit(0) }
    var input = event["tool_input"] as? [String: Any] ?? [:]
    input["answers"] = [question.text: picked]
    decision = ["behavior": "allow", "updatedInput": input]
case .withdraw:
    exit(0)
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
            if after.phase == .waiting, after.waitingSince == now {
                after.phase = .working
                after.waitingFor = nil
                after.waitingSince = nil
                after.waitingTool = nil
                after.waitingAgent = nil
            }
            after.updatedAt = Date().timeIntervalSince1970
            if let encoded = try? JSONEncoder.notch.encode(after) { try? encoded.write(to: file, options: .atomic) }
        }
        flock(lockFd, LOCK_UN)
        break
    }
    usleep(5_000)
}
exit(0)
