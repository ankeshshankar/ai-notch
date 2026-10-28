import AppKit
import SwiftUI

// What the status sources share on screen: the footer's strip of chips (Prod, the machine
// guard, the VPN), the static corner dot, and the order of the collapsed right
// wing's one slot.

/// The collapsed right wing shows one thing, the first that applies.
enum WingSlot: Equatable {
    case waiting(Int)
    /// A VPN connection that was up ended without Disconnect, not seen yet.
    case vpnDropped
    /// The machine guard: memory critical (pressure critical, or under 2 GB for 30 s).
    case memoryCritical
    case done
    /// A prod alert or incident not seen yet.
    case prodAlert
    /// A linked service's new version looks worse than the one before, not seen yet.
    case deployWorse
    /// A Datadog Watchdog story, not seen yet.
    case watchdog
    /// A build or run of mine failed, not seen yet.
    case buildFailure
    /// News on pull requests not seen yet (a review request, an approval, changes, comments, a
    /// failed build): how many rows have some.
    case pullRequestNews(Int)
    case subagents(Int)
    case building(Int)
    case none

    static func pick(waiting: Int, vpnDropped: Bool = false, memoryCritical: Bool = false, justDone: Bool, prodAlert: Bool, buildFailure: Bool,
                     pullRequestNews: Int = 0, deployWorse: Bool = false, watchdog: Bool = false, subagents: Int, building: Int) -> WingSlot {
        if waiting > 0 { return .waiting(waiting) }
        if vpnDropped { return .vpnDropped }
        if memoryCritical { return .memoryCritical }
        if justDone { return .done }
        if prodAlert { return .prodAlert }
        if deployWorse { return .deployWorse }
        if watchdog { return .watchdog }
        if buildFailure { return .buildFailure }
        if pullRequestNews > 0 { return .pullRequestNews(pullRequestNews) }
        if subagents > 0 { return .subagents(subagents) }
        if building > 0 { return .building(building) }
        return .none
    }
}

/// A static 5-point dot in the strip's top right corner: red while something in prod is open,
/// else amber while memory is low (the machine guard). No animation: it stays while the cause does.
struct CornerDot: View {
    var color: Color?

    var body: some View {
        if let color {
            Circle().fill(color)
                .frame(width: 5, height: 5)
                .padding(.top, 4).padding(.trailing, 7)
                .allowsHitTesting(false)
        }
    }
}

/// The notch with Prod's banner over it: alert-level Datadog news drops a compact banner for a few
/// seconds. Collapsed, the strip grows down around it (a black shape behind the strip's wings);
/// open (pinned or hovered), it sits over the top of the body. The pointer on it keeps it; it never
/// opens the notch by itself, and the panel never becomes key, so typing stays where it was.
struct ProdHeadsUpHost<Content: View>: View {
    @ObservedObject var prod: ProdStore
    @ObservedObject var controller: NotchController
    var content: Content
    @State private var cardHeight: CGFloat = 40
    static var cardWidth: CGFloat { 380 }

    var body: some View {
        let g = controller.geometry
        let expanded = controller.isExpanded
        ZStack(alignment: .top) {
            if prod.headsUp != nil, !expanded {
                NotchShape(radius: 16).fill(Color.black)
                    .frame(width: max(g.collapsedWidth(showsWings: controller.showsWings), Self.cardWidth + 2 * RootView.bezel),
                           height: g.notchHeight + cardHeight + 2 + RootView.bezel)
                    .transition(.opacity)
            }
            content
            if let alert = prod.headsUp {
                ProdHeadsUpCard(prod: prod, alert: alert)
                    .frame(width: expanded ? g.expandedWidth - 24 : Self.cardWidth)
                    .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { rect in
                        controller.headsUpRect = rect
                        if cardHeight != rect.height { cardHeight = rect.height }
                    }
                    .onDisappear { controller.headsUpRect = .zero }
                    .padding(.top, g.notchHeight + 2)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                    .id(alert.id)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: prod.headsUp?.id)
    }
}

/// The banner: the level's colour, what happened and where, Open and ✕. Right-click snoozes Prod.
private struct ProdHeadsUpCard: View {
    @ObservedObject var prod: ProdStore
    var alert: ProdHeadsUp

    var body: some View {
        HStack(spacing: 8) {
            Capsule().fill(Palette.failed).frame(width: 3, height: 26)
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(Palette.failed)
            VStack(alignment: .leading, spacing: 1) {
                Text(alert.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.ink).lineLimit(1)
                if !alert.subtitle.isEmpty {
                    Text(alert.subtitle).font(.system(size: 11)).foregroundStyle(Palette.ink2).lineLimit(1).truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { prod.openHeadsUp() }
            Button { prod.openHeadsUp() } label: {
                Text("Open").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.ink)
                    .padding(.horizontal, 9).padding(.vertical, 3)
                    .background(Capsule().fill(Palette.chip))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            Button { prod.dismissHeadsUp() } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Palette.ink3)
                    .frame(width: 18, height: 18).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 8).padding(.trailing, 6).padding(.vertical, 6)
        .floatingCard(radius: 11, wash: Palette.failedTint)
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Palette.failedEdge, lineWidth: 1))
        .contextMenu {
            Button("Snooze for 1 Hour") { prod.snooze() }
        }
    }
}

/// The footer's left side: one chip per status source that is set up.
struct StatusStrip: View {
    @ObservedObject var prod: ProdStore
    @ObservedObject var machine: MachineStore
    @ObservedObject var vpn: VPNStore
    var controller: NotchController
    @ObservedObject private var commands = CommandsStore.shared

    var body: some View {
        HStack(spacing: 8) {
            if prod.isOn { ProdChip(prod: prod, controller: controller, hover: controller.hover) }
            if machine.isOn { RamChip(machine: machine, feed: machine.feed, controller: controller) }
            if vpn.showsChip { VPNChip(vpn: vpn, controller: controller) }
            if commands.count > 0 || controller.openPanel == NotchController.commandsPanel {
                CommandsChip(commands: commands, controller: controller)
            }
        }
    }
}

/// Prod: a dot in the level's colour and the word; beside it the numbers while connected.
/// Hover lists what is open, a click opens it, right-click snoozes for an hour.
/// The footer sits below the header, whose hover cards (the PRs chip's) must stay over the footer's
/// Setup and Quit. Only while the Prod card is open, which grows up over the header, the footer
/// is lifted above it.
struct RaisedWhileProdCardOpen: ViewModifier {
    @ObservedObject var hover: HoverHub

    func body(content: Content) -> some View {
        content.zIndex(hover.hovered == ProdChip.zone || ProdChip.cardPinned ? 2 : 0)
    }
}

struct ProdChip: View {
    @ObservedObject var prod: ProdStore
    var controller: NotchController
    @ObservedObject var hover: HoverHub
    static let zone = "prod"
    static let cardPinned = CommandLine.arguments.contains("--preview") && CommandLine.arguments.contains("--prod-hover")
    /// The chip row's height: the hover card sits this far up, plus a gap.
    @State private var rowHeight: CGFloat = 17

    var body: some View {
        let snapshot = prod.snapshot
        let level = prod.level
        // `--preview --prod-hover`: the card stays open, for a screenshot.
        let isHovered = hover.hovered == Self.zone || ProdChip.cardPinned
        HStack(spacing: 6) {
            Button {
                if snapshot.access == .ok { controller.collapse() }
                prod.open()
            } label: {
                HStack(spacing: 4) {
                    Circle().fill(Self.color(level)).frame(width: 6, height: 6)
                    Text("Prod").font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.ink2)
                    if prod.isSnoozed {
                        Image(systemName: "moon.zzz.fill").font(.system(size: 8)).foregroundStyle(Palette.ink3)
                    }
                }
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Capsule().fill(Palette.chip))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { hover.zones[Self.zone] = $0 }
            .onDisappear { hover.zones[Self.zone] = nil }
            .contextMenu {
                if prod.isSnoozed {
                    Button("Unsnooze") { prod.unsnooze() }
                } else {
                    Button("Snooze for 1 Hour") { prod.snooze() }
                }
                if snapshot.access == .ok, let url = DatadogConfig.monitorsListURL(site: snapshot.site, query: snapshot.monitorQuery) {
                    Button("Open Monitors") { NSWorkspace.shared.open(url) }
                }
                Button("Setup…") { SetupWindowController.shared.show(focus: .prod) }
            }

            if level != .unknown, !snapshot.numbers.isEmpty {
                HStack(spacing: 6) {
                    ForEach(snapshot.numbers, id: \.label) { number in
                        Text("\(number.label) \(number.valueText)")
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(number.isOver ? Palette.waiting : Palette.ink3)
                    }
                }
                .lineLimit(1)
            }
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { if rowHeight != $0 { rowHeight = $0 } }
        // The list floats above the chip, over the rows, without moving the layout.
        .overlay(alignment: .bottomLeading) {
            if isHovered {
                VStack(spacing: 0) {
                    ProdCard(prod: prod)
                    Color.clear.frame(height: rowHeight + 6)
                }
                .fixedSize()
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }

    static func color(_ level: ProdStore.Level) -> Color {
        switch level {
        case .unknown: return Palette.ink3
        case .ok: return Palette.done
        case .warn: return Palette.waiting
        case .alert: return Palette.failed
        }
    }
}

/// What the chip's hover shows: the alerting monitors and incidents, else that all is well.
private struct ProdCard: View {
    @ObservedObject var prod: ProdStore
    private static let maxRows = 6

    var body: some View {
        let snapshot = prod.snapshot
        let level = prod.level
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle().fill(ProdChip.color(level)).frame(width: 6, height: 6)
                Text(headline).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.ink)
                Spacer(minLength: 8)
                if snapshot.monitorsAt > 0, prod.greyReason == nil {
                    Text(ago(prod.now - snapshot.monitorsAt)).font(.system(size: 10)).foregroundStyle(Palette.ink3)
                }
            }
            if let reason = detail {
                Text(reason).font(.system(size: 10)).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true)
            }
            // Only a live answer lists anything: grey shows why instead.
            let incidents = prod.greyReason == nil ? snapshot.incidents : []
            let monitors = prod.greyReason == nil ? snapshot.monitors : []
            ForEach(incidents.prefix(Self.maxRows), id: \.id) { incident in
                line(icon: "flame.fill", color: Palette.failed, text: ProdStore.incidentLine(incident))
            }
            let room = max(0, Self.maxRows - incidents.count)
            ForEach(monitors.prefix(room), id: \.id) { monitor in
                line(icon: monitor.status == "Alert" ? "exclamationmark.triangle.fill" : monitor.status == "Warn" ? "exclamationmark.circle.fill" : "questionmark.circle",
                     color: monitor.status == "Alert" ? Palette.failed : monitor.status == "Warn" ? Palette.waiting : Palette.ink3,
                     text: monitor.status == "Alert" ? monitor.name : "\(monitor.name) · \(monitor.status)")
            }
            let more = incidents.count + monitors.count - Self.maxRows
            if more > 0 { Text("+\(more) more").font(.system(size: 10)).foregroundStyle(Palette.ink3) }
            if snapshot.access == .ok, prod.greyReason == nil { DeployCardSections(prod: prod) }
            ForEach(notes, id: \.self) { note in
                Text(note).font(.system(size: 10)).foregroundStyle(Palette.ink3)
            }
            if prod.isSnoozed {
                Text("Snoozed until \(Self.clock.string(from: Date(timeIntervalSince1970: prod.snoozedUntil)))")
                    .font(.system(size: 10)).foregroundStyle(Palette.ink3)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(width: 300, alignment: .leading)
        .floatingCard(radius: 10)
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.track, lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }()

    private var headline: String {
        let snapshot = prod.snapshot
        if let grey = prod.greyReason { return "Prod · \(grey)" }
        switch prod.level {
        case .alert:
            let parts = [snapshot.alertCount > 0 ? "\(snapshot.alertCount) alerting" : nil,
                         snapshot.incidents.isEmpty ? nil : snapshot.incidents.count == 1 ? "1 incident" : "\(snapshot.incidents.count) incidents"]
            return "Prod · " + parts.compactMap { $0 }.joined(separator: " · ")
        case .warn:
            if snapshot.warnCount > 0 { return "Prod · \(snapshot.warnCount) warning" }
            return "Prod · " + snapshot.numbers.filter(\.isOver).map { "\($0.label) high" }.joined(separator: " · ")
        default:
            switch snapshot.monitorTotal {
            case 0: return "Prod · no monitors"
            case 1: return "Prod · 1 monitor OK"
            default: return "Prod · all \(snapshot.monitorTotal) monitors OK"
            }
        }
    }

    private var detail: String? {
        switch prod.snapshot.access {
        case .notConfigured: return "Add datadog to builds.json; Setup shows how."
        case .noKeys: return "Not signed in to Datadog. Click to sign in."
        case .signInAgain(let why): return why + " Click to sign in again."
        case .rejected(let why): return why
        case .ok: return prod.snapshot.problem.map { "\($0.text.capitalizedFirst): \($0.help)" }
        }
    }

    private var notes: [String] {
        let snapshot = prod.snapshot
        var notes: [String] = []
        if let note = snapshot.incidentsNote { notes.append("Incidents: \(note)") }
        if let note = snapshot.numbersNote { notes.append("Numbers: \(note)") }
        for number in snapshot.numbers where number.isOver {
            notes.append("\(number.label) \(number.valueText), over \(ProdNumber(label: "", value: number.amber, unit: number.unit).valueText)")
        }
        return notes
    }

    private func line(icon: String, color: Color, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 9)).foregroundStyle(color).frame(width: 12)
            Text(text).font(.system(size: 11)).foregroundStyle(Palette.ink).lineLimit(1).truncationMode(.tail)
        }
    }
}
