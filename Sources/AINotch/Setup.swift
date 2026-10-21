import AppKit
import Foundation

// First-launch setup: points Claude Code's hooks at this copy of the app (and Cursor's, Codex's
// and Gemini CLI's where their folder exists), adds the login item, and undoes the hooks again
// (Disconnect). Every edit merges into the user's file:
// only AI Notch's hook entries are added, moved to this copy or removed; everything else keeps
// its place and its bytes. A file is backed up (`<file>.bak-setup-<time>`) before each write, and
// written atomically; a file setup would not change is not touched at all.

/// Where setup reads and writes. `CLAUDE_NOTCH_SETUP_HOME` is for tests only: it points setup at
/// a copy of a home folder instead of the real one.
enum SetupPaths {
    static var home: URL {
        if let dir = ProcessInfo.processInfo.environment["CLAUDE_NOTCH_SETUP_HOME"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
    static var isTestHome: Bool { !(ProcessInfo.processInfo.environment["CLAUDE_NOTCH_SETUP_HOME"] ?? "").isEmpty }
    static var claudeSettings: URL { home.appendingPathComponent(".claude/settings.json") }
    static var cursorDir: URL { home.appendingPathComponent(".cursor", isDirectory: true) }
    static var cursorHooks: URL { cursorDir.appendingPathComponent("hooks.json") }
    static var codexDir: URL { home.appendingPathComponent(".codex", isDirectory: true) }
    static var codexHooks: URL { codexDir.appendingPathComponent("hooks.json") }
    static var geminiDir: URL { home.appendingPathComponent(".gemini", isDirectory: true) }
    static var geminiSettings: URL { geminiDir.appendingPathComponent("settings.json") }
    static let agentLabel = "info.ankeshshiv.notch"
    static var launchAgent: URL { home.appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist") }

    /// `~/…` for a path under the home folder, for display.
    static func short(_ url: URL) -> String {
        let path = url.path, root = home.path
        return path.hasPrefix(root + "/") ? "~" + path.dropFirst(root.count) : path
    }
}

/// This copy of the app: where it runs from, its hook, and whether hooks may point at it.
struct AppLocation {
    enum Problem: Equatable {
        /// Opened from the mounted disk image.
        case diskImage
        /// Gatekeeper runs a quarantined copy from a random read-only folder.
        case translocated
        case missingHook
    }

    var bundle: URL
    var executable: URL
    var hook: URL
    var problem: Problem?

    static func current() -> AppLocation {
        let executable = real(Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
        let hook = executable.deletingLastPathComponent().appendingPathComponent(Shell.hookName)
        let bundle = real(Bundle.main.bundleURL)
        var problem: Problem?
        if bundle.path.contains("/AppTranslocation/") {
            problem = .translocated
        } else if bundle.path.hasPrefix("/Volumes/") {
            problem = .diskImage
        } else if !FileManager.default.isExecutableFile(atPath: hook.path) {
            problem = .missingHook
        }
        return AppLocation(bundle: bundle, executable: executable, hook: hook, problem: problem)
    }

    /// The path with every symlink resolved, as `realpath(3)` gives it (`/private/tmp`, not `/tmp`).
    private static func real(_ url: URL) -> URL {
        guard let resolved = realpath(url.path, nil) else { return url.standardizedFileURL }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }
}

/// Whether macOS lets the hook run. Claude Code and Cursor execute `Contents/MacOS/ai-notch-hook`
/// directly, and a copy downloaded without notarization keeps the helper quarantined even after
/// Open Anyway approves the app: its exec then hangs until the hook's timeout (30 minutes on
/// PermissionRequest). Setup runs `ai-notch-hook --probe` (exits at once, touches nothing) with a
/// hard timeout and connects nothing unless it ran. The app never removes the quarantine itself.
enum HookProbe {
    enum Result: Equatable {
        case runs(seconds: Double)
        case blocked(Why)

        var runs: Bool { if case .runs = self { true } else { false } }
    }

    enum Why: Equatable {
        /// No exit within the timeout (the process is killed later, at `killAfter`).
        case timedOut(Double)
        case exited(Int32)
        case signaled(Int32)
        case couldNotStart(String)
    }

    /// How long a caller waits for the probe's answer: no exit by then counts as blocked.
    static let timeout: Double = 3
    /// When a probe still running is killed. Not at `timeout`: Gatekeeper takes 7–10 s to judge
    /// a quarantined helper, and a probe killed before it decides leaves the helper undecided,
    /// so every later probe is judged again from the start and cut off again, even after the
    /// quarantine is removed (measured: four 3-s probes in a row failed after `xattr -dr`; with
    /// the verdict left to finish, the next probe ran in 0.08 s).
    static let killAfter: Double = 15

    /// One probe process: started at once, answered within `timeout`, killed at `killAfter`.
    final class Run: @unchecked Sendable {
        private let lock = NSLock()
        private let finished = DispatchSemaphore(value: 0)
        private let process = Process()
        private let start = Date()
        private var launchError: String?
        private var done = false

        init(_ hook: URL) {
            process.executableURL = hook
            process.arguments = ["--probe"]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { [self] _ in markDone() }
            // The spawn on a thread of its own: even an exec that stalls inside the spawn cannot
            // hold the caller past `timeout`.
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                do {
                    try process.run()
                } catch {
                    lock.lock(); launchError = error.localizedDescription; lock.unlock()
                    markDone()
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + HookProbe.killAfter) { [self] in
                    if isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
        }

        private func markDone() {
            lock.lock()
            let first = !done
            done = true
            lock.unlock()
            process.terminationHandler = nil
            if first { finished.signal() }
        }

        var isRunning: Bool {
            lock.lock(); defer { lock.unlock() }
            return !done
        }

        /// Waits up to `seconds` (blocking: off the main thread) for the probe's answer.
        func result(within seconds: Double = HookProbe.timeout) -> Result {
            if finished.wait(timeout: .now() + seconds) == .success { finished.signal() } else {
                return .blocked(.timedOut(HookProbe.timeout))
            }
            lock.lock()
            let launchError = launchError
            lock.unlock()
            if let launchError { return .blocked(.couldNotStart(launchError)) }
            switch (process.terminationReason, process.terminationStatus) {
            case (.exit, 0): return .runs(seconds: Date().timeIntervalSince(start))
            case (.exit, let code): return .blocked(.exited(code))
            case (_, let signal): return .blocked(.signaled(signal))
            }
        }

        /// Before the process exits (the CLI): a probe still running is waited for until
        /// `killAfter`, then killed, so none outlives it.
        func finish() {
            guard isRunning else { return }
            let left = HookProbe.killAfter - Date().timeIntervalSince(start)
            if finished.wait(timeout: .now() + max(0, left)) == .success { finished.signal(); return }
            lock.lock(); let running = !done; lock.unlock()
            if running, process.processIdentifier > 0 { kill(process.processIdentifier, SIGKILL) }
        }
    }

    /// One probe, answered within `timeout`.
    static func run(_ hook: URL) -> (Result, Run) {
        let probe = Run(hook)
        return (probe.result(), probe)
    }

    /// The file's `com.apple.quarantine` value (`flags;time;agent;id`), if it has one. Read for
    /// the message only.
    static func quarantine(_ url: URL) -> String? {
        let name = "com.apple.quarantine"
        let size = getxattr(url.path, name, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard getxattr(url.path, name, &buffer, size, 0, 0) == size else { return nil }
        return String(decoding: buffer, as: UTF8.self).trimmingCharacters(in: .controlCharacters)
    }

    /// The one command that frees this copy, for the window and the CLI.
    static func unquarantineCommand(_ bundle: URL) -> String {
        "xattr -dr com.apple.quarantine " + Shell.doubleQuote(bundle.path)
    }

    static func describe(_ why: Why) -> String {
        switch why {
        case .timedOut(let s): "no answer in \(Int(s)) s"
        case .exited(let code): "exited with code \(code)"
        case .signaled(let signal): "stopped by signal \(signal)"
        case .couldNotStart(let why): "could not start: \(why)"
        }
    }
}

/// Just enough of the shell to read and write the hook commands.
enum Shell {
    /// Single-quoted, always.
    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Double-quoted, for a command shown to be pasted into Terminal (reads like the usual
    /// `"/Applications/…"`).
    static func doubleQuote(_ s: String) -> String {
        var out = "\""
        for c in s {
            if "\"\\$`".contains(c) { out.append("\\") }
            out.append(c)
        }
        return out + "\""
    }

    /// Bare when nothing in it is special to the shell (the usual `/Applications/…` path), so the
    /// command reads as it always has; else single-quoted.
    static func quoteIfNeeded(_ s: String) -> String {
        let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-")
        return !s.isEmpty && s.unicodeScalars.allSatisfy { plain.contains($0) } ? s : quote(s)
    }

    /// The words `sh` would split a command into (quotes and backslashes, no expansions); nil
    /// for an unbalanced quote.
    static func words(_ command: String) -> [String]? {
        var words: [String] = []
        var word = ""
        var inWord = false
        var chars = Array(command)[...]
        while let c = chars.popFirst() {
            switch c {
            case " ", "\t", "\n":
                if inWord { words.append(word); word = ""; inWord = false }
            case "'":
                inWord = true
                guard let end = chars.firstIndex(of: "'") else { return nil }
                word += String(chars[chars.startIndex..<end])
                chars = chars[(end + 1)...]
            case "\"":
                inWord = true
                var closed = false
                while let d = chars.popFirst() {
                    if d == "\"" { closed = true; break }
                    if d == "\\", let next = chars.first, "\"\\$`".contains(next) { word.append(chars.removeFirst()); continue }
                    word.append(d)
                }
                if !closed { return nil }
            case "\\":
                inWord = true
                if let next = chars.popFirst() { word.append(next) }
            default:
                inWord = true
                word.append(c)
            }
        }
        if inWord { words.append(word) }
        return words
    }

    /// The hook's file name in this app.
    static let hookName = "ai-notch-hook"
    /// Every name the hook has had: entries naming any of them, at any path, are ours to move or
    /// remove (`claude-notch-hook` is the name before the 0.2 release).
    static let hookNames: Set<String> = [hookName, "claude-notch-hook"]

    /// The words of a notch hook command (the program first), or nil for any other command.
    static func notchWords(_ command: String?) -> [String]? {
        guard let command, let words = words(command), let first = words.first,
              hookNames.contains((first as NSString).lastPathComponent) else { return nil }
        return words
    }
}

/// What the hooks should be. The Claude Code events and their order match the hand-written
/// setup this replaces; PermissionRequest waits up to 30 minutes for a click in the notch.
enum HookPlan {
    struct Event {
        var name: String
        var matcher: String? = nil
        var timeout: Int
    }

    static let claude: [Event] = [
        Event(name: "SessionStart", timeout: 5),
        Event(name: "SessionEnd", timeout: 5),
        Event(name: "UserPromptSubmit", timeout: 5),
        Event(name: "Stop", timeout: 5),
        Event(name: "SubagentStart", timeout: 5),
        Event(name: "SubagentStop", timeout: 5),
        // Long enough for a pause from the notch to hold the next call (the hook answers at once otherwise).
        Event(name: "PreToolUse", matcher: "*", timeout: 1800),
        Event(name: "PostToolUse", matcher: "*", timeout: 5),
        Event(name: "PostToolUseFailure", matcher: "*", timeout: 5),
        Event(name: "PermissionRequest", matcher: "*", timeout: 1800),
        Event(name: "PermissionDenied", matcher: "*", timeout: 5),
        Event(name: "Notification", matcher: "permission_prompt|elicitation_dialog|idle_prompt", timeout: 5),
        Event(name: "PostModelSwitch", timeout: 5),
    ]

    /// Cursor's events that act on nothing the hook answers. Its permission hooks (preToolUse,
    /// subagentStart, before*Execution, beforeReadFile) are never hooked: an answer there can
    /// block or allow an action.
    static let cursor = ["sessionStart", "sessionEnd", "beforeSubmitPrompt", "postToolUse",
                         "postToolUseFailure", "afterMCPExecution", "subagentStop", "stop"]
    static let cursorTimeout = 5

    /// Codex (`~/.codex/hooks.json`): Claude Code's event names, timeouts in seconds (SessionEnd and
    /// Interrupt take at most 3). Its PermissionRequest only marks the session waiting: the
    /// prompt is answered in Codex.
    static let codex: [Event] = [
        Event(name: "SessionStart", timeout: 5),
        Event(name: "SessionEnd", timeout: 3),
        Event(name: "UserPromptSubmit", timeout: 5),
        Event(name: "Stop", timeout: 5),
        Event(name: "Interrupt", timeout: 3),
        Event(name: "SubagentStart", timeout: 5),
        Event(name: "SubagentStop", timeout: 5),
        Event(name: "PreToolUse", timeout: 5),
        Event(name: "PostToolUse", timeout: 5),
        Event(name: "PermissionRequest", timeout: 5),
    ]

    /// Gemini CLI (`~/.gemini/settings.json`): its turn, its tools and its notifications,
    /// timeouts in milliseconds. Not its model hooks, which run on every request.
    static let gemini: [Event] = [
        Event(name: "SessionStart", timeout: 5000),
        Event(name: "SessionEnd", timeout: 5000),
        Event(name: "BeforeAgent", timeout: 5000),
        Event(name: "AfterAgent", timeout: 5000),
        Event(name: "BeforeTool", timeout: 5000),
        Event(name: "AfterTool", timeout: 5000),
        Event(name: "Notification", timeout: 5000),
    ]
}

struct SetupError: Error, CustomStringConvertible {
    var description: String
}

/// The edits to `~/.claude/settings.json`, as pure functions of its contents.
enum ClaudeSettingsEdit {
    static func hookCommand(_ hook: String) -> String { Shell.quoteIfNeeded(hook) }

    static func statusLineCommand(_ hook: String, wrapping inner: String) -> String {
        Shell.quoteIfNeeded(hook) + " statusline" + (inner.isEmpty ? "" : " " + Shell.quote(inner))
    }

    /// The user's own status line command inside a wrapped one (what the hook runs: its
    /// arguments after `statusline`, joined by spaces), or nil when it is not wrapped.
    static func unwrapped(_ command: String) -> String? {
        guard let words = Shell.notchWords(command), words.count >= 2, words[1] == "statusline" else { return nil }
        return words.dropFirst(2).joined(separator: " ")
    }

    static func connect(_ root: OrderedJSON, hook: String) throws -> OrderedJSON {
        guard root.members != nil else { throw SetupError(description: "settings.json isn't a JSON object") }
        var root = root
        let hooks = root["hooks"] ?? .object([])
        guard hooks.members != nil else { throw SetupError(description: "settings.json's \"hooks\" isn't an object") }
        let command = hookCommand(hook)
        root["hooks"] = GroupedHooks.connect(hooks, plan: HookPlan.claude, program: command, command: command)

        // The status line: the user's command, run by the hook after it notes the plan limits.
        if var line = root["statusLine"], line.members != nil {
            if let current = line["command"]?.stringValue {
                line["command"] = .string(statusLineCommand(hook, wrapping: unwrapped(current) ?? current))
                root["statusLine"] = line
            }
        } else if root["statusLine"] == nil {
            root["statusLine"] = .object([
                .init(key: "type", value: .string("command")),
                .init(key: "command", value: .string(statusLineCommand(hook, wrapping: ""))),
            ])
        }
        return root
    }

    static func disconnect(_ root: OrderedJSON) throws -> OrderedJSON {
        guard root.members != nil else { throw SetupError(description: "settings.json isn't a JSON object") }
        var root = GroupedHooks.disconnect(root)
        if var line = root["statusLine"], let current = line["command"]?.stringValue, let inner = unwrapped(current) {
            if inner.isEmpty {
                // A status line setup added: it goes. One with settings of its own keeps them.
                let own = (line.members ?? []).filter { $0.key != "type" && $0.key != "command" }
                if own.isEmpty { root["statusLine"] = nil } else { line["command"] = nil; root["statusLine"] = line }
            } else {
                line["command"] = .string(inner)
                root["statusLine"] = line
            }
        }
        return root
    }

    /// The hook paths the file's notch hook entries and status line point at.
    static func pointsAt(_ root: OrderedJSON) -> Set<String> {
        var paths = GroupedHooks.pointsAt(root)
        if let words = Shell.notchWords(root["statusLine"]?["command"]?.stringValue) { paths.insert(words[0]) }
        return paths
    }
}

/// Hooks laid out as Claude Code lays them out (event → matcher groups → handlers), which Codex's
/// hooks.json and Gemini CLI's settings.json share. Only AI Notch's entries are added, moved to
/// this copy or removed; every other entry, group and key keeps its place.
enum GroupedHooks {
    /// `command` on each planned event. An entry of ours on an event outside the plan keeps its
    /// own arguments, with `program` (the hook's path, quoted) as its program.
    static func connect(_ hooks: OrderedJSON, plan events: [HookPlan.Event], program: String, command: String) -> OrderedJSON {
        var hooks = hooks
        let plan = Dictionary(uniqueKeysWithValues: events.map { ($0.name, $0) })

        for member in hooks.members ?? [] {
            guard let groups = member.value.items else { continue }
            let spec = plan[member.key]
            var found = false
            var newGroups: [OrderedJSON] = []
            for group in groups {
                guard let entries = group["hooks"]?.items else { newGroups.append(group); continue }
                var kept: [OrderedJSON] = []
                var hadOurs = false
                for entry in entries {
                    guard let words = Shell.notchWords(entry["command"]?.stringValue) else { kept.append(entry); continue }
                    hadOurs = true
                    if let spec {
                        // One entry per planned event: the first is moved to this copy, the rest go.
                        guard !found else { continue }
                        found = true
                        var e = entry
                        e["command"] = .string(command)
                        e["timeout"] = .int(spec.timeout)
                        kept.append(e)
                    } else {
                        // An event outside the plan keeps its entry, pointed at this copy.
                        var e = entry
                        e["command"] = .string(([program] + words.dropFirst().map(Shell.quoteIfNeeded)).joined(separator: " "))
                        kept.append(e)
                    }
                }
                if hadOurs && kept.isEmpty { continue }
                var g = group
                g["hooks"] = .array(kept)
                // A group holding only our entry takes the planned matcher.
                if hadOurs, let matcher = spec?.matcher, kept.count == 1, Shell.notchWords(kept[0]["command"]?.stringValue) != nil {
                    g.setFirst("matcher", .string(matcher))
                }
                newGroups.append(g)
            }
            if let spec, !found { newGroups.append(newGroup(spec, command: command)) }
            hooks[member.key] = .array(newGroups)
        }
        for spec in events where hooks[spec.name] == nil {
            hooks[spec.name] = .array([newGroup(spec, command: command)])
        }
        return hooks
    }

    private static func newGroup(_ spec: HookPlan.Event, command: String) -> OrderedJSON {
        var members: [OrderedJSON.Member] = []
        if let matcher = spec.matcher { members.append(.init(key: "matcher", value: .string(matcher))) }
        members.append(.init(key: "hooks", value: .array([.object([
            .init(key: "type", value: .string("command")),
            .init(key: "command", value: .string(command)),
            .init(key: "timeout", value: .int(spec.timeout)),
        ])])))
        return .object(members)
    }

    /// `root` without AI Notch's entries in its "hooks": an emptied group, event or "hooks" goes too.
    static func disconnect(_ root: OrderedJSON) -> OrderedJSON {
        var root = root
        if var hooks = root["hooks"], let events = hooks.members {
            var removedAny = false
            for member in events {
                guard let groups = member.value.items else { continue }
                var newGroups: [OrderedJSON] = []
                var removed = false
                for group in groups {
                    guard let entries = group["hooks"]?.items else { newGroups.append(group); continue }
                    let kept = entries.filter { Shell.notchWords($0["command"]?.stringValue) == nil }
                    if kept.count == entries.count { newGroups.append(group); continue }
                    removed = true
                    if kept.isEmpty { continue }
                    var g = group
                    g["hooks"] = .array(kept)
                    newGroups.append(g)
                }
                guard removed else { continue }
                removedAny = true
                hooks[member.key] = newGroups.isEmpty ? nil : .array(newGroups)
            }
            if removedAny { root["hooks"] = hooks.members?.isEmpty == true ? nil : hooks }
        }
        return root
    }

    /// The hook paths AI Notch's entries in `root["hooks"]` point at.
    static func pointsAt(_ root: OrderedJSON) -> Set<String> {
        var paths = Set<String>()
        for member in root["hooks"]?.members ?? [] {
            for group in member.value.items ?? [] {
                for entry in group["hooks"]?.items ?? [] {
                    if let words = Shell.notchWords(entry["command"]?.stringValue) { paths.insert(words[0]) }
                }
            }
        }
        return paths
    }
}

/// The edits to Codex's `~/.codex/hooks.json` (`ai-notch-hook codex`) and Gemini CLI's
/// `~/.gemini/settings.json` (`ai-notch-hook gemini`): their hooks, in Claude Code's layout.
struct GroupedHooksEdit {
    var file: String
    var mode: String
    var plan: [HookPlan.Event]

    static let codex = GroupedHooksEdit(file: "hooks.json", mode: "codex", plan: HookPlan.codex)
    static let gemini = GroupedHooksEdit(file: "settings.json", mode: "gemini", plan: HookPlan.gemini)
    static let empty: OrderedJSON = .object([.init(key: "hooks", value: .object([]))])

    func command(_ hook: String) -> String { Shell.quoteIfNeeded(hook) + " " + mode }

    func connect(_ root: OrderedJSON, hook: String) throws -> OrderedJSON {
        guard root.members != nil else { throw SetupError(description: "\(file) isn't a JSON object") }
        var root = root
        let hooks = root["hooks"] ?? .object([])
        guard hooks.members != nil else { throw SetupError(description: "\(file)'s \"hooks\" isn't an object") }
        root["hooks"] = GroupedHooks.connect(hooks, plan: plan, program: Shell.quoteIfNeeded(hook), command: command(hook))
        return root
    }

    func disconnect(_ root: OrderedJSON) throws -> OrderedJSON {
        guard root.members != nil else { throw SetupError(description: "\(file) isn't a JSON object") }
        return GroupedHooks.disconnect(root)
    }
}

/// The edits to `~/.cursor/hooks.json`.
enum CursorHooksEdit {
    static func command(_ hook: String) -> String { Shell.quoteIfNeeded(hook) + " cursor" }

    static let empty: OrderedJSON = .object([
        .init(key: "version", value: .int(1)),
        .init(key: "hooks", value: .object([])),
    ])

    static func connect(_ root: OrderedJSON, hook: String) throws -> OrderedJSON {
        guard root.members != nil else { throw SetupError(description: "hooks.json isn't a JSON object") }
        var root = root
        var hooks = root["hooks"] ?? .object([])
        guard hooks.members != nil else { throw SetupError(description: "hooks.json's \"hooks\" isn't an object") }
        let ours = command(hook)
        for member in hooks.members ?? [] {
            guard let entries = member.value.items else { continue }
            let planned = HookPlan.cursor.contains(member.key)
            var found = false
            var kept: [OrderedJSON] = []
            var hadOurs = false
            for entry in entries {
                guard Shell.notchWords(entry["command"]?.stringValue) != nil else { kept.append(entry); continue }
                hadOurs = true
                // Ours never stays on a permission event, nor twice on one event.
                guard planned, !found else { continue }
                found = true
                var e = entry
                e["command"] = .string(ours)
                e["timeout"] = .int(HookPlan.cursorTimeout)
                kept.append(e)
            }
            if planned && !found { kept.append(newEntry(ours)) }
            hooks[member.key] = hadOurs && kept.isEmpty ? nil : .array(kept)
        }
        for name in HookPlan.cursor where hooks[name] == nil {
            hooks[name] = .array([newEntry(ours)])
        }
        root["hooks"] = hooks
        return root
    }

    private static func newEntry(_ command: String) -> OrderedJSON {
        .object([
            .init(key: "command", value: .string(command)),
            .init(key: "timeout", value: .int(HookPlan.cursorTimeout)),
        ])
    }

    static func disconnect(_ root: OrderedJSON) throws -> OrderedJSON {
        guard root.members != nil else { throw SetupError(description: "hooks.json isn't a JSON object") }
        var root = root
        guard var hooks = root["hooks"], let events = hooks.members else { return root }
        for member in events {
            guard let entries = member.value.items else { continue }
            let kept = entries.filter { Shell.notchWords($0["command"]?.stringValue) == nil }
            guard kept.count != entries.count else { continue }
            hooks[member.key] = kept.isEmpty ? nil : .array(kept)
        }
        root["hooks"] = hooks
        return root
    }

    static func pointsAt(_ root: OrderedJSON) -> Set<String> {
        var paths = Set<String>()
        for member in root["hooks"]?.members ?? [] {
            for entry in member.value.items ?? [] {
                if let words = Shell.notchWords(entry["command"]?.stringValue) { paths.insert(words[0]) }
            }
        }
        return paths
    }
}

/// Reading, backing up and writing one settings file.
enum SettingsFile {
    struct Written {
        var file: URL
        var backup: URL?
    }

    static func read(_ url: URL) throws -> (data: Data, json: OrderedJSON)? {
        let target = url.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: target.path) else { return nil }
        let data = try Data(contentsOf: target)
        do {
            return (data, try OrderedJSON.parse(data))
        } catch {
            throw SetupError(description: "\(url.lastPathComponent) isn't valid JSON, so it was left alone")
        }
    }

    /// Applies `transform`; writes only when the bytes change. `missing` is the contents to start
    /// from when there is no file (nil: leave a missing file missing).
    static func edit(_ url: URL, missing: OrderedJSON?, _ transform: (OrderedJSON) throws -> OrderedJSON) throws -> Written? {
        let target = url.resolvingSymlinksInPath()
        // A file that changes between our read and our write (Claude Code saving it) is read again.
        for _ in 0..<3 {
            let current = try read(url)
            guard let start = current?.json ?? missing else { return nil }
            let edited = try transform(start)
            // Nothing to change: the file stays as it is, even when it is formatted another way
            // than setup writes (so Disconnect on a Mac without the hooks touches nothing).
            if let current, edited == current.json { return nil }
            let trailing = current.map { $0.data.last == 0x0A } ?? true
            let bytes = Data((edited.serialized() + (trailing ? "\n" : "")).utf8)
            if bytes == current?.data { return nil }

            let again = FileManager.default.fileExists(atPath: target.path) ? try Data(contentsOf: target) : nil
            guard again == current?.data else { continue }

            var backup: URL?
            var permissions: Any?
            if let original = current?.data {
                backup = backupURL(for: target)
                try original.write(to: backup!, options: .withoutOverwriting)
                permissions = try? FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions]
            } else {
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            }
            try bytes.write(to: target, options: .atomic)
            if let permissions { try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path) }
            return Written(file: target, backup: backup)
        }
        throw SetupError(description: "\(url.lastPathComponent) kept changing; try again")
    }

    static func backupURL(for file: URL) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let base = file.path + ".bak-setup-" + formatter.string(from: Date())
        var candidate = base
        var n = 2
        while FileManager.default.fileExists(atPath: candidate) { candidate = "\(base)-\(n)"; n += 1 }
        return URL(fileURLWithPath: candidate)
    }
}

/// The login item: the same LaunchAgent `scripts/install.sh` writes (label
/// `info.ankeshshiv.notch`), pointed at this copy. It starts the app at login and restarts it
/// after a crash; Quit is a clean exit and keeps it quit. Setup only writes the file, so launchd
/// takes it from the next login and never starts a second copy beside this one.
enum LoginItem {
    static func plist(executable: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key><string>\(SetupPaths.agentLabel)</string>
          <key>ProgramArguments</key><array><string>\(xmlEscaped(executable))</string></array>
          <key>RunAtLoad</key><true/>
          <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
          <key>ProcessType</key><string>Interactive</string>
        </dict>
        </plist>

        """
    }

    private static func xmlEscaped(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    /// The program the agent starts, if there is one.
    static func program() -> String? {
        guard let data = try? Data(contentsOf: SetupPaths.launchAgent),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let args = plist["ProgramArguments"] as? [String] else { return nil }
        return args.first
    }

    static func install(executable: URL) throws -> SettingsFile.Written? {
        guard program() != executable.path else { return nil }
        let url = SetupPaths.launchAgent
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var backup: URL?
        if let old = try? Data(contentsOf: url) {
            backup = SettingsFile.backupURL(for: url)
            try old.write(to: backup!, options: .withoutOverwriting)
        }
        try Data(plist(executable: executable.path).utf8).write(to: url, options: .atomic)
        return SettingsFile.Written(file: url, backup: backup)
    }
}

/// One checklist item's state.
enum ItemStatus: Equatable {
    case done
    case notSetUp
    /// Set up, but for another copy of the app (the path it points at).
    case otherCopy(String)
    /// Some of it is there, not all.
    case incomplete
    case failed(String)

    var isDone: Bool { self == .done }
}

/// The required items' state and the edits, for the window and the test CLI.
enum Setup {
    static var hasCursor: Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: SetupPaths.cursorDir.path, isDirectory: &isDir) && isDir.boolValue
    }

    static var hasCodex: Bool { isFolder(SetupPaths.codexDir) }
    static var hasGemini: Bool { isFolder(SetupPaths.geminiDir) }

    private static func isFolder(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    static func codexStatus(_ location: AppLocation) -> ItemStatus {
        status(of: SetupPaths.codexHooks, hook: location.hook.path,
               connect: { try GroupedHooksEdit.codex.connect($0, hook: location.hook.path) }, pointsAt: GroupedHooks.pointsAt)
    }

    static func geminiStatus(_ location: AppLocation) -> ItemStatus {
        status(of: SetupPaths.geminiSettings, hook: location.hook.path,
               connect: { try GroupedHooksEdit.gemini.connect($0, hook: location.hook.path) }, pointsAt: GroupedHooks.pointsAt)
    }

    static func claudeStatus(_ location: AppLocation) -> ItemStatus {
        status(of: SetupPaths.claudeSettings, hook: location.hook.path,
               connect: { try ClaudeSettingsEdit.connect($0, hook: location.hook.path) }, pointsAt: ClaudeSettingsEdit.pointsAt)
    }

    static func cursorStatus(_ location: AppLocation) -> ItemStatus {
        status(of: SetupPaths.cursorHooks, hook: location.hook.path,
               connect: { try CursorHooksEdit.connect($0, hook: location.hook.path) }, pointsAt: CursorHooksEdit.pointsAt)
    }

    /// Done when setting up would change nothing.
    private static func status(of url: URL, hook: String, connect: (OrderedJSON) throws -> OrderedJSON,
                               pointsAt: (OrderedJSON) -> Set<String>) -> ItemStatus {
        do {
            guard let current = try SettingsFile.read(url) else { return .notSetUp }
            if try connect(current.json) == current.json { return .done }
            let paths = pointsAt(current.json)
            if paths.isEmpty { return .notSetUp }
            if let other = paths.first(where: { $0 != hook }) { return .otherCopy(other) }
            return .incomplete
        } catch {
            return .failed(String(describing: error))
        }
    }

    static func loginStatus(_ location: AppLocation) -> ItemStatus {
        guard let program = LoginItem.program() else { return .notSetUp }
        return program == location.executable.path ? .done : .otherCopy(program)
    }

    struct Outcome {
        var written: [SettingsFile.Written] = []
        var errors: [String: String] = [:]
    }

    /// Writes the required items. Nothing is written for a copy hooks must not point at, nor
    /// while its hook does not run (`probe`: a `HookProbe.run` of this copy's hook just before).
    static func connect(_ location: AppLocation, probe: HookProbe.Result) -> Outcome {
        var outcome = Outcome()
        guard location.problem == nil else {
            outcome.errors["app"] = "Move the app to Applications first"
            return outcome
        }
        guard probe.runs else {
            outcome.errors["hook"] = "macOS is blocking ai-notch-hook"
            return outcome
        }
        let hook = location.hook.path
        do {
            if let w = try SettingsFile.edit(SetupPaths.claudeSettings, missing: .object([]), { try ClaudeSettingsEdit.connect($0, hook: hook) }) { outcome.written.append(w) }
        } catch { outcome.errors["claude"] = String(describing: error) }
        if hasCursor {
            do {
                if let w = try SettingsFile.edit(SetupPaths.cursorHooks, missing: CursorHooksEdit.empty, { try CursorHooksEdit.connect($0, hook: hook) }) { outcome.written.append(w) }
            } catch { outcome.errors["cursor"] = String(describing: error) }
        }
        if hasCodex {
            do {
                if let w = try SettingsFile.edit(SetupPaths.codexHooks, missing: GroupedHooksEdit.empty, { try GroupedHooksEdit.codex.connect($0, hook: hook) }) { outcome.written.append(w) }
            } catch { outcome.errors["codex"] = String(describing: error) }
        }
        if hasGemini {
            do {
                if let w = try SettingsFile.edit(SetupPaths.geminiSettings, missing: .object([]), { try GroupedHooksEdit.gemini.connect($0, hook: hook) }) { outcome.written.append(w) }
            } catch { outcome.errors["gemini"] = String(describing: error) }
        }
        if OpenCodePlugin.hasOpenCode {
            do {
                if let w = try OpenCodePlugin.install(hook: hook) { outcome.written.append(w) }
            } catch { outcome.errors["opencode"] = String(describing: error) }
        }
        do {
            if let w = try LoginItem.install(executable: location.executable) { outcome.written.append(w) }
        } catch { outcome.errors["login"] = String(describing: error) }
        return outcome
    }

    /// Takes the hooks out again: only notch hook entries, and the status line goes back
    /// to the user's own command. Everything else, the login item included, stays.
    static func disconnect() -> Outcome {
        var outcome = Outcome()
        do {
            if let w = try SettingsFile.edit(SetupPaths.claudeSettings, missing: nil, ClaudeSettingsEdit.disconnect) { outcome.written.append(w) }
        } catch { outcome.errors["claude"] = String(describing: error) }
        do {
            if let w = try SettingsFile.edit(SetupPaths.cursorHooks, missing: nil, CursorHooksEdit.disconnect) { outcome.written.append(w) }
        } catch { outcome.errors["cursor"] = String(describing: error) }
        do {
            if let w = try SettingsFile.edit(SetupPaths.codexHooks, missing: nil, GroupedHooksEdit.codex.disconnect) { outcome.written.append(w) }
        } catch { outcome.errors["codex"] = String(describing: error) }
        do {
            if let w = try SettingsFile.edit(SetupPaths.geminiSettings, missing: nil, GroupedHooksEdit.gemini.disconnect) { outcome.written.append(w) }
        } catch { outcome.errors["gemini"] = String(describing: error) }
        do {
            if let w = try OpenCodePlugin.remove() { outcome.written.append(w) }
        } catch { outcome.errors["opencode"] = String(describing: error) }
        return outcome
    }

    // MARK: Test CLI

    /// `AINotch --setup-cli status|apply|disconnect`: the window's logic, without the window.
    /// `CLAUDE_NOTCH_SETUP_HOME` points it at a copy of a home folder (tests); without it, it works
    /// on the real home (the Homebrew cask's uninstall runs `disconnect`, a no-op without hooks).
    /// `status` and `apply` probe the hook first; `disconnect` never runs it, so it works while
    /// macOS blocks it. Exit codes: 0 done, 1 a file failed, 2 usage, 3 a copy hooks must not
    /// point at (disk image, translocated, no hook), 4 the hook is blocked (nothing written).
    static func runCLI(_ command: String) -> Int32 {
        let location = AppLocation.current()
        func line(_ name: String, _ value: String) { print(name.padding(toLength: 8, withPad: " ", startingAt: 0) + value) }
        func describe(_ s: ItemStatus) -> String {
            switch s {
            case .done: "done"
            case .notSetUp: "not set up"
            case .otherCopy(let path): "other copy: \(path)"
            case .incomplete: "incomplete"
            case .failed(let why): "failed: \(why)"
            }
        }
        func report(_ outcome: Outcome) {
            if outcome.written.isEmpty { line("wrote", outcome.errors.isEmpty ? "nothing (already as wanted)" : "nothing") }
            for w in outcome.written {
                line("wrote", SetupPaths.short(w.file) + (w.backup.map { " (backup \(SetupPaths.short($0)))" } ?? ""))
            }
            for (item, why) in outcome.errors.sorted(by: { $0.key < $1.key }) { line("error", "\(item): \(why)") }
        }
        line("home", SetupPaths.home.path + (SetupPaths.isTestHome ? " (test)" : ""))
        line("app", location.bundle.path)
        line("hook", location.hook.path)
        if let problem = location.problem { line("blocked", "\(problem)") }
        guard ["status", "apply", "disconnect"].contains(command) else {
            FileHandle.standardError.write(Data("usage: AINotch --setup-cli status|apply|disconnect\n".utf8))
            return 2
        }
        var probe = HookProbe.Result.blocked(.couldNotStart("not probed"))
        var probeRun: HookProbe.Run?
        // A probe still running when this returns is waited for (up to `killAfter`), then killed.
        defer { probeRun?.finish() }
        if command != "disconnect", location.problem == nil {
            (probe, probeRun) = HookProbe.run(location.hook)
            switch probe {
            case .runs(let seconds): line("probe", String(format: "hook runs (%.2f s)", seconds))
            case .blocked(let why):
                let mark = HookProbe.quarantine(location.hook).map { "quarantine \($0)" } ?? "no quarantine flag"
                line("probe", "hook blocked (\(HookProbe.describe(why)); \(mark))")
                line("fix", HookProbe.unquarantineCommand(location.bundle))
            }
        }
        switch command {
        case "apply":
            let outcome = connect(location, probe: probe)
            report(outcome)
            if location.problem != nil { return 3 }
            if !probe.runs { return 4 }
            if !outcome.errors.isEmpty { return 1 }
        case "disconnect":
            let outcome = disconnect()
            report(outcome)
            if !outcome.errors.isEmpty { return 1 }
        default: break
        }
        line("claude", describe(claudeStatus(location)))
        line("cursor", hasCursor ? describe(cursorStatus(location)) : "no ~/.cursor")
        line("codex", hasCodex ? describe(codexStatus(location)) : "no ~/.codex")
        line("gemini", hasGemini ? describe(geminiStatus(location)) : "no ~/.gemini")
        line("opencode", OpenCodePlugin.hasOpenCode ? describe(OpenCodePlugin.status(hook: location.hook.path)) : "no ~/.config/opencode")
        line("login", describe(loginStatus(location)))
        return 0
    }
}
