import AppKit
import Foundation

/// The machine guard for the notch: the footer's RAM chip, the Machine panel, the collapsed
/// wing's memory slot, the amber corner dot and the memory-critical notification. Scanning and
/// closing happen in `MachineSource`, off the main thread; this takes its snapshots and publishes
/// only what changes on screen. A failed scan shows "—" and touches nothing else.
@MainActor
final class MachineStore: ObservableObject {
    enum Level: Int, Comparable {
        case normal, warning, critical
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    /// A row's button, beyond plain Close: waiting for the confirming click, closing, still
    /// running after SIGTERM (Force quit), Force quit waiting for its confirming click, or why
    /// it did not close.
    enum RowAction: Equatable {
        case confirm
        case closing
        case forceQuit
        case confirmForce
        case failed(String)
    }

    /// The last scan, in its own object: it changes with every 0.1 GB of free memory, so only
    /// the RAM chip and the Machine panel watch it, not the whole notch.
    let feed = MachineFeed()
    var snapshot: MachineSnapshot { feed.snapshot }
    /// normal, warning or critical: the chip's colour and the corner dot. Published only on change.
    @Published private(set) var level: Level = .normal
    /// Setup's switch: off, nothing is scanned and nothing shows.
    @Published private(set) var isOn: Bool
    @Published private(set) var notifyCritical: Bool
    @Published private(set) var actions: [String: RowAction] = [:]
    /// "Close idle" was clicked once: the next click closes.
    @Published private(set) var bulkArmed = false
    /// Under 2 GB available for 30 seconds, or the kernel's pressure critical: the wing's slot.
    @Published private(set) var criticalSlot = false
    @Published private(set) var config = MachineConfig()
    /// The last close's result, for a few seconds: "Closed 3 · 2.1 GB freed".
    @Published private(set) var note: String?

    static let criticalBelowMB = 2048
    static let criticalHold: Double = 30
    static let rearmAfter: Double = 600
    private static let enabledKey = "machine.enabled"
    private static let notifyKey = "machine.notifyCritical"

    private var source: MachineSource?
    private var panelOpen = false
    private var lowSince: Double?
    private var normalSince: Double?
    private var notifyArmed = true
    private var confirmWork: [String: DispatchWorkItem] = [:]
    private var bulkWork: DispatchWorkItem?
    private var noteWork: DispatchWorkItem?
    /// Opens the notch on the Machine panel (a notification's Open).
    var reveal: (() -> Void)?

    init() {
        let defaults = UserDefaults.standard
        isOn = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        notifyCritical = defaults.object(forKey: Self.notifyKey) as? Bool ?? true
    }

    func start() {
        Notifier.shared.onMachine = { [weak self] in self?.reveal?() }
        if isOn { startSource() }
    }

    private func startSource() {
        guard source == nil else { return }
        let source = MachineSource { [weak self] snapshot in
            Task { @MainActor in self?.take(snapshot) }
        }
        self.source = source
        let interval = panelOpen ? 2.0 : 10.0
        Task {
            await source.setInterval(interval)
            await source.start()
        }
    }

    func setEnabled(_ on: Bool) {
        guard on != isOn else { return }
        isOn = on
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        if on {
            startSource()
        } else {
            if let source { Task { await source.stop() } }
            source = nil
            feed.snapshot = MachineSnapshot()
            level = .normal
            criticalSlot = false
            lowSince = nil
            actions = [:]
            bulkArmed = false
        }
    }

    func setNotify(_ on: Bool) {
        notifyCritical = on
        UserDefaults.standard.set(on, forKey: Self.notifyKey)
    }

    /// The Machine panel shows: scan every 2 seconds; else every 10.
    func setPanelOpen(_ open: Bool) {
        guard open != panelOpen else { return }
        panelOpen = open
        if !open, bulkArmed { disarmBulk() }
        if let source { Task { await source.setInterval(open ? 2 : 10) } }
    }

    // MARK: What shows

    var memory: MachineMemory? { snapshot.ok ? snapshot.memory : nil }

    static func level(_ memory: MachineMemory?, warnBelowMB: Int) -> Level {
        guard let memory else { return .normal }
        if memory.pressure == .critical || memory.availableMB < criticalBelowMB { return .critical }
        if memory.pressure == .warning || memory.availableMB < warnBelowMB { return .warning }
        return .normal
    }

    /// The corner dot: memory in the warning range or worse.
    var showsDot: Bool { isOn && level >= .warning }
    var showsSlot: Bool { isOn && criticalSlot }

    /// The warning chips in the panel: low memory, parallel `make verify`, critical pressure.
    var warnings: [String] {
        guard isOn, let memory = snapshot.memory else { return [] }
        var list: [String] = []
        if memory.availableMB < config.warnBelowMB { list.append("Low memory") }
        if snapshot.verifyCount > 1 { list.append("\(snapshot.verifyCount) verifies in parallel") }
        if memory.pressure == .critical { list.append("Critical pressure") }
        return list
    }

    /// What "Close idle" would close now: not a row already closing or waiting on Force quit.
    var idleRows: [MachineRow] {
        MachineRules.bulkSelection(snapshot.rows).filter { row in
            switch actions[row.id] {
            case .closing?, .forceQuit?, .confirmForce?: return false
            default: return true
            }
        }
    }

    /// The chip's second part: the biggest idle row ("Metro idle 22m").
    var chipNote: String? {
        guard let row = snapshot.rows.filter({ $0.state.isIdle }).max(by: { $0.footprintMB < $1.footprintMB }) else {
            return snapshot.verifyCount > 1 ? "\(snapshot.verifyCount) verifies" : nil
        }
        return "\(Self.shortName(row)) \(Self.stateText(row.state))"
    }

    static func shortName(_ row: MachineRow) -> String {
        switch row.kind {
        case .gradle: return "Gradle"
        case .kotlin: return "Kotlin"
        case .emulator: return "Emulator"
        case .simulator: return "Simulator"
        default: return row.kind.label
        }
    }

    static func stateText(_ state: MachineRowState) -> String {
        switch state {
        case .idle(let minutes): return minutes > 0 ? "idle \(minutes)m" : "idle"
        case .inUse: return "in use"
        case .running: return "running"
        }
    }

    static func size(_ mb: Int) -> String {
        mb < 1024 ? "\(mb) MB" : String(format: "%.1f GB", Double(mb) / 1024)
    }

    static func gigabytes(tenths: Int) -> String { String(format: "%.1f GB", Double(tenths) / 10) }

    // MARK: Snapshots

    private func take(_ next: MachineSnapshot) {
        guard isOn else { return }
        let settings = BuildsConfig.current?.machine ?? MachineConfig()
        if settings != config { config = settings }
        if next != feed.snapshot { feed.snapshot = next }
        let nextLevel = Self.level(next.memory, warnBelowMB: settings.warnBelowMB)
        if nextLevel != level { level = nextLevel }
        // Rows gone: their buttons' states with them.
        let ids = Set(next.rows.map(\.id))
        if actions.keys.contains(where: { !ids.contains($0) }) { actions = actions.filter { ids.contains($0.key) } }

        let now = next.scannedAt
        guard let memory = next.memory else { return }
        let critical = memory.pressure == .critical || memory.availableMB < Self.criticalBelowMB
        lowSince = critical ? (lowSince ?? now) : nil
        let held = lowSince.map { now - $0 >= Self.criticalHold } ?? false
        let slot = memory.pressure == .critical || held
        if slot != criticalSlot { criticalSlot = slot }
        if held, notifyArmed {
            notifyArmed = false
            noteBuildLog("machine: memory critical for 30 s")
            if notifyCritical {
                let biggest = next.rows.max { $0.footprintMB < $1.footprintMB }
                let free = Self.gigabytes(tenths: memory.availableTenths) + " free"
                Notifier.shared.postMachine(title: "Memory critical",
                                            subtitle: biggest.map { "\(free) · \(Self.shortName($0)) \(Self.size($0.footprintMB))" } ?? free,
                                            body: "Open shows the Machine panel.")
            }
        }
        // Re-armed after 10 minutes back at normal.
        if level == .normal {
            normalSince = normalSince ?? now
            if !notifyArmed, let since = normalSince, now - since >= Self.rearmAfter { notifyArmed = true }
        } else {
            normalSince = nil
        }
    }

    // MARK: Actions

    /// A row's button. Idle: closes. Otherwise the first click asks for a second within 4 s.
    /// Still running after SIGTERM: Force quit, which also needs a second click.
    func tap(_ row: MachineRow) {
        guard row.canClose else { return }
        switch actions[row.id] {
        case .closing?:
            return
        case .forceQuit?:
            arm(row.id, .confirmForce)
        case .confirmForce?:
            run(row, force: true)
        case .confirm?:
            run(row, force: false)
        case .failed?, nil:
            if row.state.isIdle { run(row, force: false) } else { arm(row.id, .confirm) }
        }
    }

    private func arm(_ id: String, _ action: RowAction) {
        actions[id] = action
        confirmWork[id]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.actions[id] == action else { return }
                // A confirmation lapses; Force quit stays offered.
                self.actions[id] = action == .confirmForce ? .forceQuit : nil
            }
        }
        confirmWork[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    private func run(_ row: MachineRow, force: Bool) {
        guard let source else { return }
        confirmWork[row.id]?.cancel()
        actions[row.id] = .closing
        Task {
            let outcome = await source.close(id: row.id, force: force)
            self.finish(row.id, outcome)
        }
    }

    private func finish(_ id: String, _ outcome: MachineCloseOutcome) {
        switch outcome {
        case .closed, .gone: actions[id] = nil
        case .stillRunning: actions[id] = .forceQuit
        case .failed(let why): actions[id] = .failed(why)
        }
    }

    /// "Close idle": the first click arms it, the second (within 5 s) closes every idle row of
    /// the bulk kinds (never the emulator or the Simulator, nothing above 5% CPU in the last minute).
    func tapBulk() {
        let rows = idleRows
        guard !rows.isEmpty else { return }
        guard bulkArmed else {
            bulkArmed = true
            bulkWork?.cancel()
            let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.disarmBulk() } }
            bulkWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
            return
        }
        disarmBulk()
        guard let source else { return }
        for row in rows { actions[row.id] = .closing }
        Task {
            var closed = 0, freed = 0
            await withTaskGroup(of: (String, MachineCloseOutcome).self) { group in
                for row in rows {
                    group.addTask { (row.id, await source.close(id: row.id, force: false)) }
                }
                for await (id, outcome) in group {
                    if case .closed(let mb) = outcome { closed += 1; freed += mb }
                    self.finish(id, outcome)
                }
            }
            self.show(note: closed == 0 ? "Nothing closed" : "Closed \(closed) · \(Self.size(freed)) freed")
        }
    }

    private func disarmBulk() {
        bulkWork?.cancel()
        bulkWork = nil
        if bulkArmed { bulkArmed = false }
    }

    private func show(note text: String) {
        note = text
        noteWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.note = nil } }
        noteWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }
}

/// The machine guard's last scan, observed only by the views that show it.
@MainActor
final class MachineFeed: ObservableObject {
    @Published fileprivate(set) var snapshot = MachineSnapshot()
}
