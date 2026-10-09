import AppKit
import Foundation

// First-launch setup: points Claude Code's and Cursor's hooks at this copy of the app, adds the
// login item, and undoes the hooks again (Disconnect). Every edit merges into the user's file:
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

/// Just enough of the shell to read and write the hook commands.
enum Shell {
    /// Single-quoted, always.
    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

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
        Event(name: "PreToolUse", matcher: "*", timeout: 5),
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
        var hooks = root["hooks"] ?? .object([])
        guard hooks.members != nil else { throw SetupError(description: "settings.json's \"hooks\" isn't an object") }
        let command = hookCommand(hook)
        let plan = Dictionary(uniqueKeysWithValues: HookPlan.claude.map { ($0.name, $0) })

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
                        e["command"] = .string(([command] + words.dropFirst().map(Shell.quoteIfNeeded)).joined(separator: " "))
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
        for spec in HookPlan.claude where hooks[spec.name] == nil {
            hooks[spec.name] = .array([newGroup(spec, command: command)])
        }
        root["hooks"] = hooks

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

    static func disconnect(_ root: OrderedJSON) throws -> OrderedJSON {
        guard root.members != nil else { throw SetupError(description: "settings.json isn't a JSON object") }
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
        var paths = Set<String>()
        for member in root["hooks"]?.members ?? [] {
            for group in member.value.items ?? [] {
                for entry in group["hooks"]?.items ?? [] {
                    if let words = Shell.notchWords(entry["command"]?.stringValue) { paths.insert(words[0]) }
                }
            }
        }
        if let words = Shell.notchWords(root["statusLine"]?["command"]?.stringValue) { paths.insert(words[0]) }
        return paths
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

    /// Writes the required items. Nothing is written for a copy hooks must not point at.
    static func connect(_ location: AppLocation) -> Outcome {
        var outcome = Outcome()
        guard location.problem == nil else {
            outcome.errors["app"] = "Move the app to Applications first"
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
        return outcome
    }

    // MARK: Test CLI

    /// `AINotch --setup-cli status|apply|disconnect`: the window's logic, without the window.
    /// `CLAUDE_NOTCH_SETUP_HOME` points it at a copy of a home folder (tests); without it, it works
    /// on the real home (the Homebrew cask's uninstall runs `disconnect`, a no-op without hooks).
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
            if outcome.written.isEmpty { line("wrote", location.problem == nil ? "nothing (already as wanted)" : "nothing") }
            for w in outcome.written {
                line("wrote", SetupPaths.short(w.file) + (w.backup.map { " (backup \(SetupPaths.short($0)))" } ?? ""))
            }
            for (item, why) in outcome.errors.sorted(by: { $0.key < $1.key }) { line("error", "\(item): \(why)") }
        }
        line("home", SetupPaths.home.path + (SetupPaths.isTestHome ? " (test)" : ""))
        line("app", location.bundle.path)
        line("hook", location.hook.path)
        if let problem = location.problem { line("blocked", "\(problem)") }
        switch command {
        case "apply":
            let outcome = connect(location)
            report(outcome)
            if location.problem != nil { return 3 }
            if !outcome.errors.isEmpty { return 1 }
        case "disconnect":
            let outcome = disconnect()
            report(outcome)
            if !outcome.errors.isEmpty { return 1 }
        case "status": break
        default:
            FileHandle.standardError.write(Data("usage: AINotch --setup-cli status|apply|disconnect\n".utf8))
            return 2
        }
        line("claude", describe(claudeStatus(location)))
        line("cursor", hasCursor ? describe(cursorStatus(location)) : "no ~/.cursor")
        line("login", describe(loginStatus(location)))
        return 0
    }
}
