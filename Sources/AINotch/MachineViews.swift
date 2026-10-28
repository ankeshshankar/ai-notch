import SwiftUI

/// The footer's RAM chip: available memory in the pressure's colour, and the biggest idle dev
/// process. A click opens the Machine panel (and closes it again).
struct RamChip: View {
    @ObservedObject var machine: MachineStore
    @ObservedObject var feed: MachineFeed
    @ObservedObject var controller: NotchController

    var body: some View {
        let isOpen = controller.openPanel == NotchController.machinePanel
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                controller.openPanel = isOpen ? nil : NotchController.machinePanel
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "memorychip").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(isOpen ? Palette.onDone : Self.color(machine.level, known: machine.memory != nil))
                if let memory = machine.memory {
                    Text("\(MachineStore.gigabytes(tenths: memory.availableTenths)) free")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit()).foregroundStyle(isOpen ? Palette.onDone : Palette.ink2)
                } else {
                    Text("RAM —").font(.system(size: 10, weight: .semibold)).foregroundStyle(isOpen ? Palette.onDone : Palette.ink2)
                }
                if let note = machine.chipNote {
                    Text("· \(note)").font(.system(size: 10)).foregroundStyle(isOpen ? Palette.onDone : Palette.ink3)
                }
            }
            .lineLimit(1)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(isOpen ? Palette.done : Palette.chip))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    static func color(_ level: MachineStore.Level, known: Bool) -> Color {
        guard known else { return Palette.ink3 }
        switch level {
        case .normal: return Palette.done
        case .warning: return Palette.waiting
        case .critical: return Palette.failed
        }
    }
}

/// The Machine panel: the memory bar, a row per dev process with its footprint, state and
/// button, and "Close idle".
struct MachinePanel: View {
    @ObservedObject var machine: MachineStore
    @ObservedObject var feed: MachineFeed

    var body: some View {
        let snapshot = feed.snapshot
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Machine").font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.done)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Palette.doneHue.opacity(0.16)))
                InfoMark(text: Self.about(machine.config))
                ForEach(machine.warnings, id: \.self) { warning in
                    Text(warning).font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(warning == "Critical pressure" ? Palette.failed : Palette.waiting)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill((warning == "Critical pressure" ? Palette.failedHue : Palette.waitingHue).opacity(0.16)))
                        .fixedSize()
                }
                Spacer(minLength: 6)
                bulkButton
            }
            memoryLine
            if !snapshot.ok {
                Text("—").font(.system(size: 12)).foregroundStyle(Palette.ink3)
            } else if snapshot.rows.isEmpty {
                Text("No dev processes running").font(.system(size: 11)).foregroundStyle(Palette.ink3)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(snapshot.rows) { row in rowView(row) }
                }
            }
            if let note = machine.note {
                Text(note).font(.system(size: 10)).foregroundStyle(Palette.ink2)
            }
        }
        .padding(10)
        .panelCard()
    }

    @ViewBuilder private var memoryLine: some View {
        if let memory = machine.memory {
            let used = Double(memory.usedTenths) / Double(max(memory.totalTenths, 1))
            let compressed = Double(memory.compressedTenths) / Double(max(memory.totalTenths, 1))
            VStack(alignment: .leading, spacing: 4) {
                GeometryReader { proxy in
                    Capsule().fill(Palette.track)
                        .overlay(alignment: .leading) {
                            Capsule().fill(RamChip.color(machine.level, known: true).opacity(0.85))
                                .frame(width: max(3, proxy.size.width * min(1, used)))
                        }
                        .overlay(alignment: .leading) {
                            // The compressed share, striped over the start of the used part.
                            Capsule().fill(Palette.ink.opacity(0.18))
                                .frame(width: max(0, proxy.size.width * min(used, compressed)))
                        }
                }
                .frame(height: 7)
                HStack(spacing: 0) {
                    Text("\(MachineStore.gigabytes(tenths: memory.usedTenths)) of \(MachineStore.gigabytes(tenths: memory.totalTenths)) used")
                        .foregroundStyle(Palette.ink.opacity(0.85))
                    Text(" · \(MachineStore.gigabytes(tenths: memory.compressedTenths)) compressed · pressure \(Self.pressureName(memory.pressure))")
                        .foregroundStyle(Palette.ink3)
                }
                .font(.system(size: 10).monospacedDigit())
                .lineLimit(1)
            }
        } else {
            Text("Memory —").font(.system(size: 10)).foregroundStyle(Palette.ink3)
        }
    }

    private func rowView(_ row: MachineRow) -> some View {
        HStack(spacing: 8) {
            Image(systemName: row.kind.icon).font(.system(size: 10)).foregroundStyle(Palette.ink2).frame(width: 14)
            Text(row.title).font(.system(size: 11)).foregroundStyle(Palette.ink.opacity(0.88)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 6)
            Text(MachineStore.size(row.footprintMB)).font(.system(size: 10, weight: .semibold).monospacedDigit()).foregroundStyle(Palette.ink2)
                .frame(width: 54, alignment: .trailing)
            Text(MachineStore.stateText(row.state)).font(.system(size: 10)).lineLimit(1)
                .foregroundStyle(row.state == .inUse ? Palette.done : row.state.isIdle ? Palette.waiting : Palette.ink3)
                .frame(width: 62, alignment: .leading)
            actionButton(row).frame(minWidth: 70, alignment: .trailing)
        }
        .help("pid \(row.pid) · \(row.processCount == 1 ? "1 process" : "\(row.processCount) processes") · \(Int(row.cpuLastMinute * 100))% CPU over the last minute")
    }

    @ViewBuilder private func actionButton(_ row: MachineRow) -> some View {
        if !row.canClose {
            if row.kind.action != .none, let why = row.whyNot {
                Text("—").font(.system(size: 10)).foregroundStyle(Palette.ink3).help(why)
            } else {
                Color.clear.frame(width: 1, height: 1)
            }
        } else {
            let action = machine.actions[row.id]
            let urgent = action == .confirm || action == .confirmForce || action == .forceQuit
            Button { machine.tap(row) } label: {
                Text(label(row, action)).font(.system(size: 10, weight: .medium))
                    .foregroundStyle(urgent ? Palette.failed : Palette.ink2)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(urgent ? Palette.failedHue.opacity(0.16) : Palette.chip))
                    .contentShape(Capsule())
                    .fixedSize()
            }
            .buttonStyle(.plain)
            .disabled(action == .closing)
            .help(help(row, action))
        }
    }

    private func label(_ row: MachineRow, _ action: MachineStore.RowAction?) -> String {
        switch action {
        case .confirm?: return row.kind.action == .shutDown ? "Confirm shut down" : "Confirm close"
        case .closing?: return row.kind.action == .shutDown ? "Shutting down…" : "Closing…"
        case .forceQuit?: return "Force quit"
        case .confirmForce?: return "Confirm force quit"
        case .failed?: return "Not closed"
        case nil: return row.kind.action == .shutDown ? "Shut down" : "Close"
        }
    }

    private func help(_ row: MachineRow, _ action: MachineStore.RowAction?) -> String {
        switch action {
        case .forceQuit?, .confirmForce?: return "Still running 5 s after SIGTERM. Force quit sends SIGKILL after a second click."
        case .failed(let why)?: return why
        default:
            if row.kind == .simulator { return "xcrun simctl shutdown for this device; never a signal." }
            if row.kind == .emulator { return "adb emu kill, SIGTERM if that fails." }
            return row.state.isIdle ? "SIGTERM; Force quit is offered if it is still running 5 s later." : "Not idle: a second click confirms. SIGTERM, then Force quit if needed."
        }
    }

    @ViewBuilder private var bulkButton: some View {
        let rows = machine.idleRows
        if !rows.isEmpty {
            let total = rows.reduce(0) { $0 + $1.footprintMB }
            Button { machine.tapBulk() } label: {
                Text(machine.bulkArmed ? "Confirm close \(rows.count)" : "Close idle · \(rows.count) · \(MachineStore.size(total))")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(machine.bulkArmed ? Palette.failed : Palette.ink2)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(machine.bulkArmed ? Palette.failedHue.opacity(0.16) : Palette.chip))
                    .contentShape(Capsule())
                    .fixedSize()
            }
            .buttonStyle(.plain)
            .help("Closes idle Metro, Jest and Gradle/Kotlin daemons that used under 5% CPU in the last minute. Never the emulator or the Simulator. A second click confirms.")
        }
    }

    static func pressureName(_ pressure: MachineMemory.Pressure) -> String {
        switch pressure {
        case .normal: return "normal"
        case .warning: return "warning"
        case .critical: return "critical"
        }
    }

    static func about(_ config: MachineConfig) -> String {
        "Dev processes on this Mac and what they hold in memory (their physical footprint, children included). Free is the free, inactive and speculative memory, as vm_stat counts it; amber under \(config.warnBelowMB) MB or at the kernel's warning pressure, red under 2 GB or at critical. Idle: Metro with no client for \(config.idleMinutes) min at under 1% CPU (adb reverse counts as a client), Jest --watch quiet \(config.idleMinutes) min, Gradle and Kotlin daemons quiet 10 min, anything whose parent is gone at once. make verify and turbo are never idle. Close sends SIGTERM, Force quit (after 5 s, a second click) SIGKILL; the emulator closes with adb emu kill, the Simulator with simctl shutdown. Editors, terminals, shells, Claude Code, Codex and their tools are never touched. Scans every 10 s, every 2 s while this panel is open."
    }
}
