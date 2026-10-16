import Darwin
import Foundation

/// The machine guard's scanner: reads the process table and the memory off the main thread,
/// every 10 seconds (every 2 while the Machine panel is open, at once on a memory-pressure
/// event), and hands each scan to `publish` as a Sendable snapshot. It also closes rows: the
/// signals, `adb emu kill` and `simctl shutdown` all happen here.
actor MachineSource {
    typealias Publish = @Sendable (MachineSnapshot) -> Void

    private let publish: Publish
    private let uid = getuid()
    private let selfPid = getpid()
    private var interval: Double = 10
    private var loop: Task<Void, Never>?
    private var sleeper: Task<Void, Never>?
    private var pressure: DispatchSourceMemoryPressure?

    // Per process (pid + start time): read once.
    private var argsCache: [String: [String]] = [:]
    private var pathCache: [String: String] = [:]
    private var leaderCache: [String: Bool] = [:]
    // Per process: CPU time at the last scan. Per row: since when quiet, and the last minute.
    private var cpuSeen: [String: UInt64] = [:]
    private var lastScanAt: Double = 0
    private var quietSince: [String: Double] = [:]
    private var history: [String: [(at: Double, cpu: Double, wall: Double)]] = [:]
    private var deviceNames: [String: String] = [:]

    init(publish: @escaping Publish) {
        self.publish = publish
    }

    func start() {
        guard loop == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in
            Task { await self?.wake() }
        }
        source.resume()
        pressure = source
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                await self.pause()
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        sleeper?.cancel()
        pressure?.cancel()
        pressure = nil
        quietSince = [:]
        history = [:]
        cpuSeen = [:]
        lastScanAt = 0
    }

    /// 2 seconds while the Machine panel is open, else 10. A shorter pace starts at once.
    func setInterval(_ seconds: Double) {
        let shorter = seconds < interval
        interval = seconds
        if shorter { wake() }
    }

    /// Scan now (a pressure event, the panel opening, a close finishing).
    func wake() {
        sleeper?.cancel()
    }

    private func tick() {
        publish(scan(now: Date().timeIntervalSince1970))
    }

    private func pause() async {
        let wait = interval
        let task = Task<Void, Never> { _ = try? await Task.sleep(for: .seconds(wait)) }
        sleeper = task
        await task.value
        sleeper = nil
    }

    // MARK: Scanning

    /// The table with paths and session leaders filled in (own processes), and the arguments of
    /// those that could be dev processes. Arguments stay in memory, keyed by pid and start time.
    private func readTable() -> (table: [ProcEntry], args: [Int32: [String]])? {
        guard var table = ProcessList.table() else { return nil }
        var args: [Int32: [String]] = [:]
        var live: Set<String> = []
        for index in table.indices where table[index].uid == uid {
            let key = table[index].key
            live.insert(key)
            let pid = table[index].pid
            if let path = pathCache[key] {
                table[index].path = path
            } else {
                let path = ProcessList.path(of: pid)
                pathCache[key] = path
                table[index].path = path
            }
            if MachineRules.isShell(table[index].comm) {
                if let leads = leaderCache[key] {
                    table[index].sessionLeader = leads
                } else {
                    let leads = ProcessList.leadsSession(pid)
                    leaderCache[key] = leads
                    table[index].sessionLeader = leads
                }
            }
            if MachineRules.needsArgs(table[index]) {
                if let cached = argsCache[key] {
                    args[pid] = cached
                } else if let read = ProcessList.arguments(of: pid) {
                    argsCache[key] = read
                    args[pid] = read
                }
            }
        }
        // Forget processes that are gone.
        if pathCache.count > live.count + 64 {
            pathCache = pathCache.filter { live.contains($0.key) }
            leaderCache = leaderCache.filter { live.contains($0.key) }
            argsCache = argsCache.filter { live.contains($0.key) }
        }
        return (table, args)
    }

    private func config() -> MachineConfig {
        BuildsConfig.current?.machine ?? MachineConfig()
    }

    private func scan(now: Double) -> MachineSnapshot {
        var snapshot = MachineSnapshot()
        snapshot.scannedAt = now
        snapshot.memory = ProcessList.memory().map(MachineMemory.init)
        // Tests only: CLAUDE_NOTCH_MACHINE_TEST_FREE_MB=<n> stands in for the available memory
        // (the chip's colour, the slot and the notification without filling the memory).
        if let test = Self.testFreeMB, var memory = snapshot.memory {
            memory.availableTenths = min(memory.totalTenths, Int((Double(test) / 1024 * 10).rounded()))
            snapshot.memory = memory
        }
        guard let (table, args) = readTable() else { return snapshot }
        let config = config()
        let byPid = Dictionary(table.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        let drafts = MachineRules.rows(table: table, args: args, uid: uid, selfPid: selfPid, exclude: config.exclude)
        let wall = lastScanAt > 0 ? now - lastScanAt : 0
        var seen: [String: UInt64] = [:]
        var rows: [MachineRow] = []
        for draft in drafts {
            var footprint: UInt64 = 0
            var cpu: Double = 0
            for pid in draft.pids {
                guard let entry = byPid[pid], let usage = ProcessList.usage(of: pid) else { continue }
                footprint += usage.footprint
                let key = entry.key
                if let before = cpuSeen[key] {
                    cpu += Double(usage.cpuNanos >= before ? usage.cpuNanos - before : 0) / 1e9
                } else if lastScanAt > 0, entry.start > lastScanAt {
                    // Started since the last scan: all of its time is this interval's.
                    cpu += Double(usage.cpuNanos) / 1e9
                }
                seen[key] = usage.cpuNanos
            }
            let share: Double? = wall > 0 ? cpu / wall : nil
            var clients = 0
            var port = draft.match.argPort
            if draft.kind == .metro {
                let sockets = ProcessList.tcpSockets(of: draft.root.pid)
                let listening = Set(sockets.filter(\.listening).map(\.localPort))
                if let argPort = draft.match.argPort, listening.contains(argPort) { port = argPort } else { port = listening.min() ?? port }
                if let port { clients = sockets.filter { $0.established && $0.localPort == port }.count }
            }
            // Quiet: under the kind's CPU line (and, for Metro, no client) since the interval began.
            let id = draft.id
            if let share {
                if share < draft.kind.quietCPU && clients == 0 {
                    if quietSince[id] == nil { quietSince[id] = lastScanAt }
                } else {
                    quietSince[id] = nil
                }
            }
            var past = (history[id] ?? []).filter { now - $0.at <= 60 }
            if wall > 0 { past.append((now, cpu, wall)) }
            history[id] = past
            let pastWall = past.reduce(0) { $0 + $1.wall }
            let lastMinute = pastWall > 0 ? past.reduce(0) { $0 + $1.cpu } / pastWall : 0
            let state = MachineRules.state(kind: draft.kind, watch: draft.match.watch, clients: clients, orphan: draft.orphan,
                                           quietFor: quietSince[id].map { now - $0 } ?? 0, idleAfter: Double(config.idleMinutes) * 60)
            let plan = draft.kind.action == .close ? MachineRules.closePlan(for: draft, table: table, args: args, selfPid: selfPid) : nil
            var whyNot: String?
            switch draft.kind.action {
            case .none: whyNot = "Shown only"
            case .shutDown: whyNot = draft.match.udid == nil ? "Its device is not known" : nil
            case .close:
                if case .none(let why)? = plan { whyNot = why.capitalizedFirst }
            }
            rows.append(MachineRow(id: id, kind: draft.kind, title: title(draft, port: port), pid: draft.root.pid, start: draft.root.start,
                                   footprintMB: Self.roundMB(footprint), state: state, canClose: whyNot == nil, whyNot: whyNot,
                                   cpuLastMinute: (lastMinute * 100).rounded() / 100, processCount: draft.pids.count))
        }
        cpuSeen = seen
        lastScanAt = now
        let ids = Set(rows.map(\.id))
        quietSince = quietSince.filter { ids.contains($0.key) }
        history = history.filter { ids.contains($0.key) }
        snapshot.rows = rows.sorted { ($0.footprintMB, $1.id) > ($1.footprintMB, $0.id) }
        snapshot.ok = true
        return snapshot
    }

    private static let testFreeMB: Int? = ProcessInfo.processInfo.environment["CLAUDE_NOTCH_MACHINE_TEST_FREE_MB"].flatMap { Int($0) }

    /// 10 MB steps under a gigabyte, 100 MB steps above.
    static func roundMB(_ bytes: UInt64) -> Int {
        let mb = Double(bytes) / 1_048_576
        return mb < 1024 ? Int((mb / 10).rounded()) * 10 : Int((mb / 100).rounded()) * 100
    }

    private func title(_ draft: MachineRowDraft, port: Int?) -> String {
        switch draft.kind {
        case .metro: return port.map { "Metro :\($0)" } ?? "Metro"
        case .jest: return draft.match.isWorker ? "Jest worker" : draft.match.watch ? "Jest --watch" : "Jest"
        case .emulator: return draft.match.avd.map { "Emulator · \($0)" } ?? "Android emulator"
        case .simulator:
            guard let udid = draft.match.udid else { return "iOS Simulator" }
            if deviceNames[udid] == nil {
                let plist = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Developer/CoreSimulator/Devices/\(udid)/device.plist")
                let name = (NSDictionary(contentsOf: plist)?["name"] as? String) ?? ""
                deviceNames[udid] = name
            }
            return deviceNames[udid].flatMap { $0.isEmpty ? nil : "Simulator · \($0)" } ?? "iOS Simulator"
        default: return draft.kind.label
        }
    }

    // MARK: Closing

    /// Closes one row, found again by its root's pid and start time. SIGTERM (never SIGKILL
    /// first); after 5 seconds a process still there is `.stillRunning`, and only `force` (a
    /// second, confirmed click) sends SIGKILL. The emulator: `adb emu kill`, SIGTERM as the
    /// fallback. The Simulator: `simctl shutdown`, never a signal.
    func close(id: String, force: Bool) async -> MachineCloseOutcome {
        guard let (table, args) = readTable() else { return .failed("Could not read the processes") }
        let drafts = MachineRules.rows(table: table, args: args, uid: uid, selfPid: selfPid, exclude: config().exclude)
        guard let row = drafts.first(where: { $0.id == id }) else { return .gone }
        let freed = Self.roundMB(row.pids.reduce(UInt64(0)) { $0 + (ProcessList.usage(of: $1)?.footprint ?? 0) })
        let kind = row.kind.rawValue
        defer { wake() }
        switch row.kind.action {
        case .none:
            return .failed("Shown only")
        case .shutDown:
            guard !force, let udid = row.match.udid else { return .failed("Its device is not known") }
            _ = await Self.run("/usr/bin/xcrun", ["simctl", "shutdown", udid], timeout: 60)
            if await gone(row.root, within: 15) {
                noteBuildLog("machine: closed \(kind) pid \(row.root.pid), \(freed) MB freed")
                return .closed(freedMB: freed)
            }
            noteBuildLog("machine: \(kind) pid \(row.root.pid) still running after shutdown")
            return .failed("Still running after shutdown")
        case .close:
            break
        }
        if row.kind == .emulator, !force, let serial = emulatorSerial(row.root.pid), let adb = adbPath(table) {
            _ = await Self.run(adb, ["-s", serial, "emu", "kill"], timeout: 10)
            if await gone(row.root, within: 10) {
                noteBuildLog("machine: closed \(kind) pid \(row.root.pid), \(freed) MB freed")
                return .closed(freedMB: freed)
            }
        }
        // Planned again from a table read just now, and each pid's start time checked again
        // right before its signal: a pid reused by another process is never signalled.
        let signal = force ? SIGKILL : SIGTERM
        guard sendSignal(signal, rowId: id) else { return .failed("Not closed: it is protected or changed") }
        if await gone(row.root, within: force ? 2 : 5) {
            noteBuildLog("machine: \(force ? "force quit" : "closed") \(kind) pid \(row.root.pid), \(freed) MB freed")
            return .closed(freedMB: freed)
        }
        noteBuildLog("machine: \(kind) pid \(row.root.pid) still running \(force ? 2 : 5) s after \(force ? "SIGKILL" : "SIGTERM")")
        return .stillRunning
    }

    /// Sends `signal` to the row's close plan. False when the row is gone or cannot be closed.
    private func sendSignal(_ signal: Int32, rowId: String) -> Bool {
        guard let (table, args) = readTable() else { return false }
        let drafts = MachineRules.rows(table: table, args: args, uid: uid, selfPid: selfPid, exclude: config().exclude)
        guard let row = drafts.first(where: { $0.id == rowId }) else { return false }
        let starts = Dictionary(table.map { ($0.pid, $0.start) }, uniquingKeysWith: { a, _ in a })
        let plan = MachineRules.closePlan(for: row, table: table, args: args, selfPid: selfPid)
        if case .group(let pgid, let members) = plan {
            // The group must still be exactly the members checked, each the same process.
            let same = members.allSatisfy { pid in ProcessList.entry(pid).map { $0.start == starts[pid] && $0.pgid == pgid } ?? false }
            if same, killpg(pgid, signal) == 0 { return true }
        }
        if case .none = plan { return false }
        // The tree, root first; anything protected is left out (MachineRules.treePids).
        var sent = false
        for pid in MachineRules.treePids(of: row, table: table, args: args, selfPid: selfPid) {
            guard let now = ProcessList.entry(pid), now.start == starts[pid], now.uid == uid else { continue }
            if kill(pid, signal) == 0 { sent = true }
        }
        return sent
    }

    /// Whether the process (same pid, same start) is gone within `seconds`.
    private func gone(_ root: ProcEntry, within seconds: Double) async -> Bool {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until {
            if ProcessList.entry(root.pid)?.start != root.start { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return ProcessList.entry(root.pid)?.start != root.start
    }

    /// `emulator-<console port>`: the even port the emulator listens on, 5554 to 5682.
    private func emulatorSerial(_ pid: Int32) -> String? {
        let ports = ProcessList.tcpSockets(of: pid).filter { $0.listening && (5554...5682).contains($0.localPort) && $0.localPort % 2 == 0 }.map(\.localPort)
        return ports.min().map { "emulator-\($0)" }
    }

    /// The running adb server's own binary, else the SDK's or Homebrew's.
    private func adbPath(_ table: [ProcEntry]) -> String? {
        if let running = table.first(where: { $0.comm == "adb" && $0.uid == uid && !$0.path.isEmpty }) { return running.path }
        let candidates = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Android/sdk/platform-tools/adb").path,
                          "/opt/homebrew/bin/adb", "/usr/local/bin/adb"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Runs a tool with no input or output, up to `timeout` seconds; its exit status.
    static func run(_ path: String, _ arguments: [String], timeout: Double) async -> Int32? {
        await withCheckedContinuation { continuation in
            let once = Once()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { finished in
                if once.claim() { continuation.resume(returning: finished.terminationStatus) }
            }
            do {
                try process.run()
            } catch {
                if once.claim() { continuation.resume(returning: nil) }
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning { process.terminate() }
                if once.claim() { continuation.resume(returning: nil) }
            }
        }
    }

    // MARK: Dev

    /// `AINotch --machine-scan <s> <n>`: the CPU time of `n` scans in a row (thread time, ms each).
    func benchmark(_ count: Int) -> String {
        func threadCPU() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1000 + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1000
        }
        let started = Date()
        let cpu = threadCPU()
        for _ in 0..<count { _ = scan(now: Date().timeIntervalSince1970) }
        let used = threadCPU() - cpu
        let wall = Date().timeIntervalSince(started) * 1000
        return String(format: "%d scans: %.2f ms CPU and %.2f ms wall each", count, used / Double(count), wall / Double(count))
    }

    /// `AINotch --machine-scan`: two scans `seconds` apart, each row's kind, pid, footprint,
    /// state and close plan. Never the arguments.
    func debugLines() -> [String] {
        let snapshot = scan(now: Date().timeIntervalSince1970)
        var lines: [String] = []
        if let memory = snapshot.memory {
            lines.append(String(format: "memory: %.1f GB available of %.1f, %.1f GB compressed, pressure %@",
                                Double(memory.availableTenths) / 10, Double(memory.totalTenths) / 10, Double(memory.compressedTenths) / 10,
                                "\(memory.pressure)"))
        }
        guard let (table, args) = readTable() else { return lines + ["scan failed"] }
        let drafts = MachineRules.rows(table: table, args: args, uid: uid, selfPid: selfPid, exclude: config().exclude)
        for row in snapshot.rows {
            let plan = drafts.first { $0.id == row.id }.map { MachineRules.closePlan(for: $0, table: table, args: args, selfPid: selfPid) }
            let planText: String
            switch plan {
            case .group(let pgid, let members)?: planText = "group \(pgid) (\(members.count))"
            case .tree(let pids)?: planText = "tree (\(pids.count))"
            case .none(let why)?: planText = "none: \(why)"
            case nil: planText = "-"
            }
            lines.append("\(row.kind.rawValue) pid \(row.pid) \"\(row.title)\" \(row.footprintMB) MB \(row.state) cpu1m \(Int(row.cpuLastMinute * 100))% procs \(row.processCount) close: \(row.canClose ? planText : row.whyNot ?? "-")\(MachineRules.bulkSelection([row]).isEmpty ? "" : " [bulk]")")
        }
        return lines
    }
}

enum MachineCloseOutcome: Equatable, Sendable {
    case closed(freedMB: Int)
    /// Still there 5 seconds after SIGTERM: Force quit is offered.
    case stillRunning
    /// Gone before the click took effect, or another process now has its pid.
    case gone
    case failed(String)
}

/// Resumes a continuation once, whichever of its callers comes first.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
