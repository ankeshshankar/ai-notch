import Foundation

// The machine guard's model and rules: which processes are dev processes, how they group into
// rows, when one is idle, and how one may be closed. Pure functions over a process table, so the
// self-check (`AINotch --machine-selfcheck <fixtures.json>`) runs them on saved tables.

/// A kind of dev process the guard knows. Nothing else is ever shown or touched.
enum MachineKind: String, Codable, Sendable, CaseIterable {
    case metro, jest, verify, turbo, emulator, simulator, simulatorApp, gradle, kotlin, adb, watchman

    var label: String {
        switch self {
        case .metro: return "Metro"
        case .jest: return "Jest"
        case .verify: return "make verify"
        case .turbo: return "turbo"
        case .emulator: return "Android emulator"
        case .simulator: return "iOS Simulator"
        case .simulatorApp: return "Simulator app"
        case .gradle: return "Gradle daemon"
        case .kotlin: return "Kotlin daemon"
        case .adb: return "adb server"
        case .watchman: return "watchman"
        }
    }

    var icon: String {
        switch self {
        case .metro: return "shippingbox.fill"
        case .jest: return "checklist"
        case .verify, .turbo: return "hammer.fill"
        case .emulator: return "candybarphone"
        case .simulator, .simulatorApp: return "iphone"
        case .gradle, .kotlin: return "cup.and.saucer.fill"
        case .adb: return "cable.connector"
        case .watchman: return "eye"
        }
    }

    /// What the row's button does: a signal (Close), `simctl shutdown`, or nothing.
    enum Action: Sendable { case close, shutDown, none }

    var action: Action {
        switch self {
        case .metro, .jest, .verify, .turbo, .gradle, .kotlin, .emulator: return .close
        case .simulator: return .shutDown
        case .simulatorApp, .adb, .watchman: return .none
        }
    }

    /// Closed by "Close idle". The emulator and the Simulator only by their own row.
    var inBulk: Bool { self == .metro || self == .jest || self == .gradle || self == .kotlin }

    /// Below this share of one core, a process counts as quiet.
    var quietCPU: Double { self == .gradle || self == .kotlin ? 0.005 : 0.01 }
}

/// What a process is, from its name, path and arguments.
struct MachineMatch: Equatable, Sendable {
    var kind: MachineKind
    /// A Jest worker (jest-worker's processChild.js), not the runner.
    var isWorker = false
    /// Jest in watch mode.
    var watch = false
    var avd: String?
    var udid: String?
    /// `--port N` from the arguments, when the socket cannot be read.
    var argPort: Int?
}

/// A row before it is measured: the root process and everything it accounts for.
struct MachineRowDraft: Equatable, Sendable {
    var kind: MachineKind
    var root: ProcEntry
    var match: MachineMatch
    /// The root first, then its descendants (folded rows included): the footprint's sum.
    var pids: [Int32]
    /// Parent gone (re-parented to launchd) and no live process left on its terminal.
    var orphan: Bool
    /// Started directly by an editor (VS Code, Cursor, Xcode): shown, never closed.
    var editorChild: Bool

    var id: String { root.key }
}

/// How a row would be closed: its whole process group (only when the group is the dev process and
/// its wrappers, nothing else), its process tree, or not at all.
enum ClosePlan: Equatable, Sendable {
    case group(pgid: Int32, members: [Int32])
    case tree([Int32])
    case none(String)

    var pids: [Int32] {
        switch self {
        case .group(_, let members): return members
        case .tree(let pids): return pids
        case .none: return []
        }
    }

    var name: String {
        switch self {
        case .group: return "group"
        case .tree: return "tree"
        case .none: return "none"
        }
    }
}

/// A row's state on screen.
enum MachineRowState: Equatable, Sendable {
    case idle(minutes: Int)
    /// Metro with a client connected.
    case inUse
    case running

    var isIdle: Bool { if case .idle = self { return true } else { return false } }
}

enum MachineRules {
    // MARK: Classifying

    /// Names worth reading the arguments of. Everything else is skipped without a look.
    static func needsArgs(_ entry: ProcEntry) -> Bool {
        let comm = entry.comm
        return comm.hasPrefix("node") || comm == "java" || isMake(comm) || comm == "turbo"
            || comm.hasPrefix("qemu-system") || comm == "launchd_sim" || comm == "adb" || comm == "pnpm"
    }

    static func classify(_ entry: ProcEntry, args: [String]?) -> MachineMatch? {
        let comm = entry.comm
        let args = args ?? []
        let rest = Array(args.dropFirst())
        if comm == "watchman" { return MachineMatch(kind: .watchman) }
        if comm == "Simulator", entry.path.contains("/Simulator.app/") { return MachineMatch(kind: .simulatorApp) }
        if comm == "launchd_sim" { return MachineMatch(kind: .simulator, udid: deviceUDID(in: args) ?? deviceUDID(in: [entry.path])) }
        if comm == "adb" {
            return rest.contains("fork-server") || rest.contains("server") ? MachineMatch(kind: .adb) : nil
        }
        if comm.hasPrefix("qemu-system") {
            guard let index = args.firstIndex(of: "-avd") else { return nil }
            return MachineMatch(kind: .emulator, avd: index + 1 < args.count ? args[index + 1] : nil)
        }
        if comm == "java" {
            if args.contains(where: { $0.hasSuffix("GradleDaemon") }) { return MachineMatch(kind: .gradle) }
            if args.contains(where: { $0.hasSuffix("KotlinCompileDaemon") }) { return MachineMatch(kind: .kotlin) }
            return nil
        }
        if isMake(comm) {
            return rest.contains("verify") ? MachineMatch(kind: .verify) : nil
        }
        if comm == "turbo" { return MachineMatch(kind: .turbo) }
        guard comm.hasPrefix("node") else { return nil }
        // Node: only by what it runs, never by the name alone.
        if args.contains(where: { $0.contains("jest-worker/") && $0.hasSuffix("processChild.js") }) {
            return MachineMatch(kind: .jest, isWorker: true)
        }
        if args.contains(where: isJestScript) {
            return MachineMatch(kind: .jest, watch: args.contains { $0 == "--watch" || $0 == "--watchAll" || $0.hasPrefix("--watch=") || $0.hasPrefix("--watchAll=") })
        }
        if let index = args.firstIndex(where: isMetroScript), args[(index + 1)...].contains(where: { $0 == "start" || $0 == "serve" }) {
            return MachineMatch(kind: .metro, argPort: port(in: args))
        }
        if args.dropFirst().prefix(2).contains(where: { $0.hasSuffix("/turbo") || $0.contains("turbo/bin/turbo") || $0 == "turbo" }) {
            return MachineMatch(kind: .turbo)
        }
        return nil
    }

    /// make by any of its names: Xcode's `/usr/bin/make` execs `gnumake`, Homebrew's is `gmake`.
    static func isMake(_ comm: String) -> Bool { comm == "make" || comm == "gmake" || comm == "gnumake" }

    private static func isJestScript(_ arg: String) -> Bool {
        arg.hasSuffix("jest/bin/jest.js") || arg.hasSuffix("jest-cli/bin/jest.js") || arg.hasSuffix("node_modules/.bin/jest")
    }

    /// `expo start`, `@expo/cli … start`, `react-native start`, `metro serve`.
    private static func isMetroScript(_ arg: String) -> Bool {
        let name = (arg as NSString).lastPathComponent
        return arg.contains("@expo/cli") || name == "expo" || arg.hasSuffix("expo/bin/cli")
            || name == "react-native" || arg.hasSuffix("react-native/cli.js") || arg.hasSuffix("@react-native-community/cli/build/bin.js")
            || name == "metro" || arg.contains("/node_modules/metro/")
    }

    private static func port(in args: [String]) -> Int? {
        for (index, arg) in args.enumerated() {
            if arg.hasPrefix("--port=") { return Int(arg.dropFirst(7)) }
            if (arg == "--port" || arg == "-p"), index + 1 < args.count { return Int(args[index + 1]) }
        }
        return nil
    }

    /// The device folder's UUID in `…/CoreSimulator/Devices/<UDID>/…`.
    static func deviceUDID(in args: [String]) -> String? {
        for arg in args {
            guard let range = arg.range(of: "/Devices/") else { continue }
            let id = arg[range.upperBound...].prefix { $0 != "/" }
            if id.count == 36, UUID(uuidString: String(id)) != nil { return String(id) }
        }
        return nil
    }

    // MARK: What is never touched

    private static let editorApps = ["/Cursor.app/", "/Visual Studio Code.app/", "/Visual Studio Code - Insiders.app/", "/VSCodium.app/", "/Windsurf.app/"]
    private static let terminalApps = ["/Terminal.app/", "/iTerm.app/", "/iTerm2.app/", "/Warp.app/", "/Ghostty.app/", "/kitty.app/",
                                       "/Alacritty.app/", "/WezTerm.app/", "/Hyper.app/", "/Tabby.app/"]
    private static let protectedNames: Set<String> = ["claude", "codex", "cursor-agent", "AINotch", "ai-notch-hook", "claude-notch-hook",
                                                      "launchd", "login", "sshd", "sshd-session", "tmux", "screen", "Code Helper", "Cursor Helper"]
    private static let shells: Set<String> = ["zsh", "bash", "sh", "fish", "dash", "tcsh", "csh", "ksh", "nu"]

    static func isShell(_ comm: String) -> Bool { shells.contains(comm) }

    /// An editor's own process: VS Code, Cursor, Xcode (any copy of it) or one of their helpers.
    /// Not the command-line tools inside Xcode's `Contents/Developer` (make, clang, simctl,
    /// the Simulator app): `/usr/bin/make` runs Xcode's make, and `make verify` is a dev process.
    static func isEditor(_ entry: ProcEntry) -> Bool {
        let path = entry.path
        if editorApps.contains(where: path.contains) { return true }
        return path.range(of: #"/Xcode[^/]*\.app/Contents/(MacOS|SharedFrameworks|Frameworks|PlugIns|XPCServices|Applications)/"#,
                          options: .regularExpression) != nil
    }

    /// Never signalled, and a process group holding one is never signalled as a group: the
    /// editors and their helpers, Claude Code, Codex, Cursor's agent, the notch itself, terminals,
    /// login and terminal shells, launchd.
    static func isProtected(_ entry: ProcEntry, args: [String]?, selfPid: Int32) -> Bool {
        if entry.pid <= 1 || entry.pid == selfPid { return true }
        if isEditor(entry) || terminalApps.contains(where: entry.path.contains) { return true }
        let name = (entry.path as NSString).lastPathComponent
        if protectedNames.contains(entry.comm) || protectedNames.contains(name) || entry.comm.hasPrefix("Code Helper") || entry.comm.hasPrefix("Cursor Helper") {
            return true
        }
        if shells.contains(entry.comm), entry.sessionLeader { return true }
        // Claude Code, Codex or Cursor's agent run by node: by the script it runs.
        for arg in (args ?? []).prefix(3) {
            let base = (arg as NSString).lastPathComponent
            if ["claude", "codex", "cursor-agent"].contains(base) || arg.contains("@anthropic-ai/claude-code") || arg.contains("@openai/codex") {
                return true
            }
        }
        return false
    }

    /// make, pnpm, npx, npm or yarn: what starts a dev process and may lead its group.
    static func isWrapper(_ entry: ProcEntry, args: [String]?) -> Bool {
        if isMake(entry.comm) || ["pnpm", "npx", "npm", "yarn"].contains(entry.comm) { return true }
        guard entry.comm.hasPrefix("node") else { return false }
        return (args ?? []).dropFirst().prefix(2).contains { arg in
            let base = (arg as NSString).lastPathComponent
            return ["pnpm", "pnpm.cjs", "pnpm.js", "npx", "npx-cli.js", "npm", "npm-cli.js", "yarn", "yarn.js", "yarn.cjs"].contains(base)
        }
    }

    // MARK: Rows

    /// The table's dev processes as rows: a matching process whose ancestors match nothing is a
    /// row's root; a matching descendant (a Jest worker, a Jest run inside `make verify`) counts
    /// in its root's row. Only `uid`'s processes, minus excluded kinds.
    static func rows(table: [ProcEntry], args: [Int32: [String]], uid: UInt32, selfPid: Int32, exclude: Set<MachineKind> = []) -> [MachineRowDraft] {
        let byPid = Dictionary(table.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var children: [Int32: [Int32]] = [:]
        for entry in table where entry.pid != entry.ppid { children[entry.ppid, default: []].append(entry.pid) }
        var matches: [Int32: MachineMatch] = [:]
        for entry in table where entry.uid == uid {
            guard let match = classify(entry, args: args[entry.pid]), !exclude.contains(match.kind) else { continue }
            // A protected process is never a row that signals. The Simulator (shut down through
            // simctl, never a signal; its app lives inside Xcode.app) and display-only kinds show.
            if match.kind.action == .close, isProtected(entry, args: args[entry.pid], selfPid: selfPid) { continue }
            matches[entry.pid] = match
        }
        var drafts: [MachineRowDraft] = []
        for (pid, match) in matches {
            guard let entry = byPid[pid] else { continue }
            // Folded into a matching ancestor's row.
            if ancestors(of: entry, byPid: byPid).contains(where: { matches[$0.pid] != nil }) { continue }
            let pids = [pid] + descendants(of: pid, children: children)
            let parent = byPid[entry.ppid]
            drafts.append(MachineRowDraft(kind: match.kind, root: entry, match: match, pids: pids,
                                          orphan: entry.ppid == 1 && !hasLiveTTYOwner(entry, table: table, rowPids: Set(pids)),
                                          editorChild: parent.map(isEditor) ?? false))
        }
        return drafts.sorted { $0.root.start < $1.root.start }
    }

    static func ancestors(of entry: ProcEntry, byPid: [Int32: ProcEntry]) -> [ProcEntry] {
        var chain: [ProcEntry] = []
        var current = entry
        while current.ppid > 1, let parent = byPid[current.ppid], chain.count < 64, parent.pid != current.pid {
            chain.append(parent)
            current = parent
        }
        return chain
    }

    static func descendants(of pid: Int32, children: [Int32: [Int32]]) -> [Int32] {
        var out: [Int32] = []
        var queue = children[pid] ?? []
        var seen: Set<Int32> = [pid]
        while let next = queue.first, out.count < 4096 {
            queue.removeFirst()
            guard seen.insert(next).inserted else { continue }
            out.append(next)
            queue.append(contentsOf: children[next] ?? [])
        }
        return out
    }

    /// Another live process outside the row still has the row's terminal (its shell, say).
    private static func hasLiveTTYOwner(_ entry: ProcEntry, table: [ProcEntry], rowPids: Set<Int32>) -> Bool {
        guard let tty = entry.tty else { return false }
        return table.contains { $0.tty == tty && !rowPids.contains($0.pid) }
    }

    // MARK: Closing

    /// How `row` would be closed. A group only when its leader is the dev process itself or the
    /// make/pnpm/npx wrapper that started it, and every member is that wrapper chain or the dev
    /// process's own tree, none protected (an editor's group holds its MCP servers: never). Else
    /// the tree: the root and its descendants, leaving out anything protected.
    static func closePlan(for row: MachineRowDraft, table: [ProcEntry], args: [Int32: [String]], selfPid: Int32) -> ClosePlan {
        guard row.kind.action == .close else { return .none("not closed from here") }
        guard !row.editorChild else { return .none("started by the editor") }
        guard !isProtected(row.root, args: args[row.root.pid], selfPid: selfPid) else { return .none("protected") }
        let byPid = Dictionary(table.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        let tree = treePids(of: row, table: table, args: args, selfPid: selfPid)
        let pgid = row.root.pgid
        if pgid > 1, let leader = byPid[pgid], leader.uid == row.root.uid {
            let chain = ancestors(of: row.root, byPid: byPid)
            let leaderOK: Bool
            var allowed = Set(tree)
            if leader.pid == row.root.pid {
                leaderOK = true
            } else if let index = chain.firstIndex(where: { $0.pid == leader.pid }), isWrapper(leader, args: args[leader.pid]) {
                // The leader and whatever sits between it and the dev process (`sh -c`, a nested
                // wrapper), none of them protected.
                let between = chain.prefix(index + 1)
                leaderOK = between.allSatisfy { !isProtected($0, args: args[$0.pid], selfPid: selfPid) }
                allowed.formUnion(between.map(\.pid))
            } else {
                leaderOK = false
            }
            let members = table.filter { $0.pgid == pgid }
            if leaderOK, members.allSatisfy({ allowed.contains($0.pid) && !isProtected($0, args: args[$0.pid], selfPid: selfPid) }) {
                return .group(pgid: pgid, members: members.map(\.pid).sorted())
            }
        }
        return .tree(tree)
    }

    /// The root and its descendants, the user's own, nothing protected: what a tree close signals.
    static func treePids(of row: MachineRowDraft, table: [ProcEntry], args: [Int32: [String]], selfPid: Int32) -> [Int32] {
        let byPid = Dictionary(table.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var children: [Int32: [Int32]] = [:]
        for entry in table where entry.pid != entry.ppid { children[entry.ppid, default: []].append(entry.pid) }
        return [row.root.pid] + descendants(of: row.root.pid, children: children).filter { pid in
            guard let entry = byPid[pid] else { return false }
            return entry.uid == row.root.uid && !isProtected(entry, args: args[pid], selfPid: selfPid)
        }
    }

    // MARK: Idle

    /// A row's state. Metro: in use while a client is connected (adb reverse counts), idle after
    /// `idleAfter` seconds quiet. Jest: a `--watch` run idle after `idleAfter` quiet; a plain run
    /// never. Gradle and Kotlin daemons: idle after 10 minutes at about no CPU. `make verify`,
    /// turbo, the emulator and the Simulator: never idle. An orphan (parent gone, no terminal
    /// left) is idle at once, Metro with a client excepted.
    static func state(kind: MachineKind, watch: Bool, clients: Int, orphan: Bool, quietFor: Double, idleAfter: Double) -> MachineRowState {
        let minutes = Int(max(0, quietFor) / 60)
        switch kind {
        case .metro:
            if clients > 0 { return .inUse }
            if orphan || quietFor >= idleAfter { return .idle(minutes: minutes) }
            return .running
        case .jest:
            if orphan || (watch && quietFor >= idleAfter) { return .idle(minutes: minutes) }
            return .running
        case .gradle, .kotlin:
            return quietFor >= 600 ? .idle(minutes: minutes) : .running
        default:
            return .running
        }
    }

    /// What "Close idle" closes: idle rows of the bulk kinds that can be signalled and used at
    /// most 5% of a core over the last minute. Never the emulator or the Simulator.
    static func bulkSelection(_ rows: [MachineRow]) -> [MachineRow] {
        rows.filter { $0.kind.inBulk && $0.state.isIdle && $0.canClose && $0.cpuLastMinute <= 0.05 }
    }
}

/// A row as the panel shows it.
struct MachineRow: Equatable, Sendable, Identifiable {
    var id: String
    var kind: MachineKind
    var title: String
    var pid: Int32
    var start: Double
    /// Rounded for display (10 MB under a gigabyte, else 100 MB), so a scan publishes only a change.
    var footprintMB: Int
    var state: MachineRowState
    var canClose: Bool
    /// Why it cannot be closed, when it cannot.
    var whyNot: String?
    /// Share of one core over the last minute, rounded to whole percent.
    var cpuLastMinute: Double
    var processCount: Int
}

/// The memory line, rounded to 0.1 GB.
struct MachineMemory: Equatable, Sendable {
    enum Pressure: Int, Comparable, Sendable {
        case normal, warning, critical
        static func < (a: Pressure, b: Pressure) -> Bool { a.rawValue < b.rawValue }
    }
    var totalTenths: Int
    var availableTenths: Int
    var compressedTenths: Int
    var pressure: Pressure

    var usedTenths: Int { max(0, totalTenths - availableTenths) }
    var availableMB: Int { availableTenths * 1024 / 10 }

    init(totalTenths: Int, availableTenths: Int, compressedTenths: Int, pressure: Pressure) {
        self.totalTenths = totalTenths; self.availableTenths = availableTenths
        self.compressedTenths = compressedTenths; self.pressure = pressure
    }

    init(_ reading: MemoryReading) {
        func tenths(_ bytes: UInt64) -> Int { Int((Double(bytes) / 1_073_741_824 * 10).rounded()) }
        totalTenths = tenths(reading.total)
        availableTenths = tenths(reading.available)
        compressedTenths = tenths(reading.compressed)
        pressure = reading.pressureLevel >= 4 ? .critical : reading.pressureLevel >= 2 ? .warning : .normal
    }
}

/// What one scan found: the memory, the rows, and whether the scan worked at all.
struct MachineSnapshot: Equatable, Sendable {
    var ok = false
    var scannedAt: Double = 0
    var memory: MachineMemory?
    var rows: [MachineRow] = []
    /// Top-level `make verify` runs at once.
    var verifyCount: Int { rows.filter { $0.kind == .verify }.count }

    /// Equal on screen: everything but the scan time.
    static func == (a: MachineSnapshot, b: MachineSnapshot) -> Bool {
        a.ok == b.ok && a.memory == b.memory && a.rows == b.rows
    }
}

/// The optional `machine` part of builds.json; the guard works without it.
struct MachineConfig: Equatable, Sendable {
    /// Under this much available memory the chip and the corner dot turn amber (the dev
    /// scripts' wait-for-memory default).
    var warnBelowMB = 4096
    var idleMinutes = 15
    /// Kinds never shown or touched, by name (MachineKind's raw values: "metro", "gradle", …).
    var exclude: Set<MachineKind> = []

    /// A JSON number, not a boolean. (NSNumber 1 also passes `is Bool`, so `idleMinutes: 1` needs this.)
    static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? nil : number.doubleValue
        }
        return (value as? String).flatMap(Double.init)
    }

    static let example = """
    "machine": {
      "warnBelowMB": 4096,
      "idleMinutes": 15,
      "exclude": []
    }
    """
}
