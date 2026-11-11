import AppKit
import NotchCore
import SwiftUI

// What the status sources share on screen: the footer's strip of chips (Prod, the machine
// guard, the VPN), the static corner dot, and the order of the collapsed right
// wing's one slot.

/// The collapsed right wing shows one thing, the first that applies.
enum WingSlot: Equatable {
    case waiting(Int)
    /// A Claude Code turn ended on an API error and nothing has been asked since: how many sessions.
    case sessionFailed(Int)
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
    case none

    static func pick(waiting: Int, sessionFailures: Int = 0, vpnDropped: Bool = false, memoryCritical: Bool = false, justDone: Bool, prodAlert: Bool, buildFailure: Bool,
                     pullRequestNews: Int = 0, deployWorse: Bool = false, watchdog: Bool = false, subagents: Int) -> WingSlot {
        if waiting > 0 { return .waiting(waiting) }
        if sessionFailures > 0 { return .sessionFailed(sessionFailures) }
        if vpnDropped { return .vpnDropped }
        if memoryCritical { return .memoryCritical }
        if justDone { return .done }
        if prodAlert { return .prodAlert }
        if deployWorse { return .deployWorse }
        if watchdog { return .watchdog }
        if buildFailure { return .buildFailure }
        if pullRequestNews > 0 { return .pullRequestNews(pullRequestNews) }
        if subagents > 0 { return .subagents(subagents) }
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
    /// The strip's width follows what the wings show.
    @ObservedObject var strip: StripModel
    var content: Content
    @State private var cardHeight: CGFloat = 40
    static var cardWidth: CGFloat { 380 }

    var body: some View {
        let g = controller.geometry
        let expanded = controller.isExpanded
        ZStack(alignment: .top) {
            if prod.headsUp != nil, !expanded {
                NotchShape(radius: 16).fill(Color.black)
                    .frame(width: max(controller.collapsedWidth, Self.cardWidth + 2 * RootView.bezel),
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
                    .transition(Motion.reduce ? .opacity : .opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                    .id(alert.id)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(Motion.spring(0.28, 0.86), value: prod.headsUp?.id)
    }
}

/// The banner: the level's colour, what happened and where, Open and ✕. Right-click snoozes Prod.
private struct ProdHeadsUpCard: View {
    @ObservedObject var prod: ProdStore
    var alert: ProdHeadsUp

    var body: some View {
        HStack(spacing: 8) {
            Capsule().fill(Palette.failed).frame(width: 3, height: 26)
            Image(systemName: "exclamationmark.triangle.fill").font(Typo.subtitle()).foregroundStyle(Palette.failed).decorative()
            VStack(alignment: .leading, spacing: 1) {
                Text(alert.title).font(Typo.subtitle(.semibold)).foregroundStyle(Palette.ink).lineLimit(1)
                if !alert.subtitle.isEmpty {
                    Text(alert.subtitle).font(Typo.body()).foregroundStyle(Palette.ink2).lineLimit(1).truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { prod.openHeadsUp() }
            .accessibilityHidden(true)
            Button { prod.openHeadsUp() } label: {
                Text("Open").font(Typo.body(.semibold)).foregroundStyle(Palette.ink)
                    .padding(.horizontal, 9).padding(.vertical, 3)
                    .background(Capsule().fill(Palette.chip))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .ax("Open in Datadog", value: alert.title)
            Button { prod.dismissHeadsUp() } label: {
                Image(systemName: "xmark").font(Typo.caption(.bold)).foregroundStyle(Palette.ink3)
                    .frame(width: 18, height: 18).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .ax("Dismiss the Prod alert")
            .help("Dismiss")
        }
        .padding(.leading, 8).padding(.trailing, 6).padding(.vertical, 6)
        .floatingCard(radius: 11, wash: Palette.failedTint)
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Palette.failedEdge, lineWidth: 1))
        .contextMenu {
            Button("Snooze for 1 Hour") { prod.snooze() }
        }
    }
}

/// One chip's slot in the row: which chip it is (nil: the menu) and how much it needs a look.
struct ChipSlotInfo {
    var chip: FooterChip?
    var tone: ChipTone = .calm
}

struct ChipSlot: LayoutValueKey {
    static let defaultValue = ChipSlotInfo(chip: nil)
}

/// The chips' row. Each chip is a `ViewThatFits` of its forms, widest first, so the widths come from
/// the views themselves: no proposal gives the full one, a hair less than a width the next one down. `ChipPicker.fit` decides from those measured widths and the room, and the row places
/// each chip with exactly the width of the form chosen; a chip that does not fit is put out of
/// sight (the menu lists it) and reported through `onFit`.
struct ChipRowLayout: Layout {
    var wide: Bool
    var spacing: CGFloat = 8
    var onFit: ([FooterChip]) -> Void

    struct Cache { var reported: [FooterChip]? }
    func makeCache(subviews: Subviews) -> Cache { Cache(reported: nil) }

    private func measure(_ subviews: Subviews) -> (chips: [ChipWidth], menu: Double, height: CGFloat) {
        var chips: [ChipWidth] = [], menu = 0.0, height: CGFloat = 0
        for subview in subviews {
            let info = subview[ChipSlot.self]
            let full = subview.sizeThatFits(.unspecified)
            height = max(height, full.height)
            guard let chip = info.chip else { menu = full.width; continue }
            // The forms narrow step by step: ask for a hair less than the last width until it stops shrinking.
            var steps = [Double(full.width)]
            for _ in 0..<5 {
                let next = Double(subview.sizeThatFits(ProposedViewSize(width: CGFloat(steps[steps.count - 1]) - 0.5, height: nil)).width)
                if next >= steps[steps.count - 1] - 0.5 { break }
                steps.append(next)
            }
            chips.append(ChipWidth(chip: chip, tone: info.tone, steps: steps))
        }
        return (chips, menu, height)
    }

    private func choice(_ proposal: ProposedViewSize, _ measured: (chips: [ChipWidth], menu: Double, height: CGFloat)) -> ChipChoice {
        ChipPicker.fit(measured.chips, available: Double(proposal.width ?? .infinity), spacing: Double(spacing), menu: measured.menu, wide: wide)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let measured = measure(subviews)
        let picked = choice(proposal, measured)
        return CGSize(width: CGFloat(ChipPicker.width(picked, measured.chips, spacing: Double(spacing), menu: measured.menu)), height: measured.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let measured = measure(subviews)
        let picked = choice(ProposedViewSize(width: bounds.width, height: nil), measured)
        var x = bounds.minX
        for subview in subviews {
            let info = subview[ChipSlot.self]
            let away = CGPoint(x: -20_000, y: bounds.midY)
            if let chip = info.chip {
                guard let step = picked.shown[chip], let item = measured.chips.first(where: { $0.chip == chip }) else {
                    subview.place(at: away, anchor: .leading, proposal: .zero)
                    continue
                }
                let width = CGFloat(item.width(at: step))
                subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: width + 0.5, height: nil))
                x += width + spacing
            } else if picked.hidden.isEmpty {
                subview.place(at: away, anchor: .leading, proposal: .zero)
            } else {
                subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: CGFloat(measured.menu), height: nil))
            }
        }
        if cache.reported != picked.hidden {
            cache.reported = picked.hidden
            let hidden = picked.hidden
            DispatchQueue.main.async { onFit(hidden) }
        }
    }
}

/// The footer's left side: every chip that is present, in one fixed order. A calm one is compact;
/// one that needs a look writes out its wording (see ChipPicker). Each opens its panel with one
/// click. When the row is short, the ones needing a look drop their secondary text first; only
/// with every chip compact do the last calm chips wait in a menu.
struct StatusStrip: View {
    @ObservedObject var prod: ProdStore
    @ObservedObject var machine: MachineStore
    @ObservedObject var vpn: VPNStore
    @ObservedObject var reviews: ReviewStore
    var limits: ToolLimits?
    var now: Double
    var controller: NotchController
    /// The two-column layout: more room, so chips write their words where they fit.
    var wide = false
    @ObservedObject private var commands = CommandsStore.shared
    @State private var hidden: [FooterChip] = []

    var body: some View {
        let limits = LimitsChip.displayed(limits)
        let five = current(limits?.fiveHour, now: now), week = current(limits?.weekly, now: now)
        let present = inputs(five: five, week: week).filter(\.present)
        let fixture = ChipFixture.facts
        ChipRowLayout(wide: wide, onFit: { next in if next != hidden { hidden = next } }) {
            ForEach(present, id: \.chip) { input in
                Group {
                    if let fixture {
                        FixtureChip(chip: input.chip, facts: fixture[input.chip] ?? ChipFacts(symbol: "circle", calmFull: "", calmCompact: "", ladder: [""]), tone: input.effectiveTone,
                                    isOpen: controller.openPanel == input.chip.panel)
                    } else {
                        chipView(input.chip, five: five, week: week)
                    }
                }
                .layoutValue(key: ChipSlot.self, value: ChipSlotInfo(chip: input.chip, tone: input.effectiveTone))
                .accessibilityHidden(hidden.contains(input.chip))
            }
            MoreChipsMenu(hidden: hidden, needing: hidden.filter { chip in present.first { $0.chip == chip }.map { $0.effectiveTone > .calm } ?? false },
                          summaries: Dictionary(uniqueKeysWithValues: hidden.map { ($0, summary($0, five: five, week: week)) }), controller: controller)
                .layoutValue(key: ChipSlot.self, value: ChipSlotInfo(chip: nil))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func chipView(_ chip: FooterChip, five: LimitWindow?, week: LimitWindow?) -> some View {
        switch chip {
        case .prod: ProdChip(prod: prod, controller: controller, hover: controller.hover)
        case .ram: RamChip(machine: machine, feed: machine.feed, controller: controller)
        case .vpn: VPNChip(vpn: vpn, controller: controller)
        case .commands: CommandsChip(commands: commands, controller: controller)
        case .prs: PRsChip(reviews: reviews, controller: controller, hover: controller.hover)
        case .limit: LimitsChip(limits: LimitsChip.displayed(limits), now: now, controller: controller)
        }
    }

    private func inputs(five: LimitWindow?, week: LimitWindow?) -> [ChipInput] {
        if let fixture = ChipFixture.inputs { return fixture }
        let prodTone: ChipTone = prod.level == .alert ? .alert : prod.level == .warn ? .warning : .calm
        let machineTone: ChipTone = machine.level == .critical ? .alert : machine.level == .warning ? .warning : .calm
        let vpnTone: ChipTone = vpn.level == .problem ? (vpn.helper == .notRunning ? .warning : .alert) : vpn.level == .busy ? .news : .calm
        return [
            ChipInput(chip: .prod, present: prod.isOn, tone: prodTone, snoozed: prod.isSnoozed),
            ChipInput(chip: .vpn, present: vpn.showsChip, tone: vpnTone),
            ChipInput(chip: .ram, present: machine.isOn, tone: machineTone),
            ChipInput(chip: .limit, present: five != nil || week != nil, tone: ChipPicker.limitTone(five: five, week: week)),
            ChipInput(chip: .prs, present: reviews.isOn, tone: reviews.unseenCount > 0 ? .news : .calm),
            ChipInput(chip: .commands, present: commands.count > 0 || controller.openPanel == NotchController.commandsPanel, tone: .calm),
        ]
    }

    /// What a hidden chip would have said, one line, for the menu.
    private func summary(_ chip: FooterChip, five: LimitWindow?, week: LimitWindow?) -> String {
        switch chip {
        case .prod:
            let word = prod.snapshot.access != .ok ? "not connected" : prod.level == .alert ? "alerting" : prod.level == .warn ? "warning" : prod.level == .ok ? "OK" : "no answer yet"
            return "Prod · \(word)" + (prod.isSnoozed ? " · snoozed" : "")
        case .vpn: return "VPN · \(vpn.chipText)"
        case .ram:
            guard let memory = machine.memory else { return "RAM · no reading" }
            return "RAM · \(MachineStore.gigabytes(tenths: memory.availableTenths)) free" + (machine.level == .normal ? "" : machine.level == .critical ? " · critical" : " · low")
        case .limit:
            return "Limits · " + [five.map { "5h \(Int($0.usedPercent.rounded()))%" }, week.map { "wk \(Int($0.usedPercent.rounded()))%" }].compactMap { $0 }.joined(separator: " · ")
        case .prs:
            let count = reviews.attention.count
            return "Pull requests · " + (count == 0 ? "none need you" : "\(count) need\(count == 1 ? "s" : "") you") + (reviews.unseenCount > 0 ? " · news" : "")
        case .commands: return "Commands · \(commands.count) running"
        }
    }
}

/// A chip's wordings for the dev fixtures: calm (wide, then compact) and, when it needs a look, the
/// ladder widest first. One capsule in the common look.
struct ChipFacts: Equatable {
    var symbol: String
    var calmFull: String
    var calmCompact: String
    var ladder: [String]
}

struct FixtureChip: View {
    var chip: FooterChip
    var facts: ChipFacts
    var tone: ChipTone
    var isOpen: Bool

    var body: some View {
        let color: Color = tone == .alert ? Palette.failed : tone == .warning ? Palette.waiting : tone == .news ? Palette.bitbucket : Palette.ink2
        let forms = tone == .calm ? [facts.calmFull, facts.calmCompact] : facts.ladder
        Button {} label: {
            ViewThatFits(in: .horizontal) {
                ForEach(forms.indices, id: \.self) { label(forms[$0], color) }
            }
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(isOpen ? Palette.done : Palette.chip))
        }
        .buttonStyle(.plain)
    }

    private func label(_ text: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: facts.symbol).font(Typo.caption(.semibold)).foregroundStyle(color)
            if !text.isEmpty { Text(text).font(Typo.label(.semibold).monospacedDigit()).foregroundStyle(Palette.ink2) }
        }
        .lineLimit(1).fixedSize()
    }
}

/// Dev previews: `--preview --chips-fixture calm|one|three|six` draws the footer from made-up chips,
/// to look at the row for each case (six: every chip that can need a look does). Never in the app.
enum ChipFixture {
    static var mode: String? {
        let arguments = CommandLine.arguments
        guard arguments.contains("--preview"), let index = arguments.firstIndex(of: "--chips-fixture"), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    static var inputs: [ChipInput]? {
        guard let mode else { return nil }
        let tones: [FooterChip: ChipTone]
        switch mode {
        case "one": tones = [.ram: .alert]
        case "three": tones = [.prod: .alert, .vpn: .warning, .prs: .news]
        case "six": tones = [.prod: .alert, .vpn: .alert, .ram: .alert, .limit: .warning, .prs: .news]
        default: tones = [:]
        }
        return FooterChip.order.map { ChipInput(chip: $0, present: true, tone: tones[$0] ?? .calm) }
    }

    static var facts: [FooterChip: ChipFacts]? {
        guard mode != nil else { return nil }
        return [
            .prod: ChipFacts(symbol: "circle.fill", calmFull: "Prod", calmCompact: "Prod", ladder: ["Prod 2 alerting · p95 210ms", "Prod 2 alerting", "Prod 2"]),
            .vpn: ChipFacts(symbol: "lock.shield", calmFull: "VPN off", calmCompact: "", ladder: ["Connecting", ""]),
            .ram: ChipFacts(symbol: "memorychip", calmFull: "9.8 GB free", calmCompact: "62%", ladder: ["1.2 GB free · Metro idle 22m", "1.2 GB free", "91%"]),
            .limit: ChipFacts(symbol: "gauge", calmFull: "5h 42% wk 18%", calmCompact: "42%", ladder: ["5h 72% wk 18%", "72%"]),
            .prs: ChipFacts(symbol: "arrow.triangle.pull", calmFull: "PRs", calmCompact: "", ladder: ["PRs 3", "3"]),
            .commands: ChipFacts(symbol: "terminal", calmFull: "2", calmCompact: "2", ladder: ["2"]),
        ]
    }
}

/// The menu after the chips, only when the row cannot hold them all: the hidden ones, each opening
/// its section. "+n" counts those that need a look.
struct MoreChipsMenu: View {
    var hidden: [FooterChip]
    var needing: [FooterChip]
    var summaries: [FooterChip: String]
    var controller: NotchController

    var body: some View {
        let text = needing.isEmpty ? nil : "+\(needing.count)"
        let names = needing.map { summaries[$0] ?? $0.rawValue }
        let label = text.map { "\($0) more need a look: " + names.joined(separator: "; ") } ?? "More status: " + hidden.compactMap { summaries[$0] }.joined(separator: "; ")
        Menu {
            ForEach(hidden, id: \.self) { chip in
                Button {
                    withAnimation(Motion.slide) {
                        controller.openPanel = controller.openPanel == chip.panel ? nil : chip.panel
                    }
                } label: {
                    Text((controller.openPanel == chip.panel ? "✓ " : "") + (summaries[chip] ?? chip.rawValue))
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "ellipsis").font(Typo.caption(.bold)).decorative()
                if let text { Text(text).font(Typo.label(.semibold).monospacedDigit()) }
            }
            .foregroundStyle(text == nil ? Palette.ink3 : Palette.ink2)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(Palette.chip))
            .contentShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(label)
        .accessibilityLabel(text == nil ? "More status" : "More status, \(text ?? "")")
        .accessibilityValue(names.isEmpty ? hidden.compactMap { summaries[$0] }.joined(separator: "; ") : names.joined(separator: "; "))
        .opacity(hidden.isEmpty ? 0 : 1)
        .allowsHitTesting(!hidden.isEmpty)
        .accessibilityHidden(hidden.isEmpty)
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
        content.zIndex(hover.hovered == ProdChip.zone || ProdChip.cardPinned || hover.hovered == PRsChip.zone || PRsChip.cardPinned ? 2 : 0)
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
        let isOpen = controller.openPanel == NotchController.prodPanel
        HStack(spacing: 6) {
            Button {
                withAnimation(Motion.slide) {
                    controller.openPanel = isOpen ? nil : NotchController.prodPanel
                }
            } label: {
                ViewThatFits(in: .horizontal) {
                    label(.full, level: level, snapshot: snapshot, isOpen: isOpen)
                    label(.words, level: level, snapshot: snapshot, isOpen: isOpen)
                    label(.count, level: level, snapshot: snapshot, isOpen: isOpen)
                    label(.calm, level: level, snapshot: snapshot, isOpen: isOpen)
                }
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Capsule().fill(isOpen ? Palette.done : Palette.chip))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .ax("Prod", value: snapshot.access == .ok ? "\(level)" + (prod.isSnoozed ? ", snoozed" : "") : "not connected", selected: isOpen)
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { hover.zones[Self.zone] = $0 }
            .onDisappear { hover.zones[Self.zone] = nil }
            .contextMenu {
                if prod.isSnoozed {
                    Button("Unsnooze") { prod.unsnooze() }
                } else {
                    Button("Snooze for 1 Hour") { prod.snooze() }
                }
                if snapshot.access == .ok, let url = DatadogConfig.monitorsListURL(site: snapshot.site, query: snapshot.monitorQuery) {
                    Button("Open Monitors") { SafeLink.open(url, for: .datadog) }
                }
                Button("Setup…") { SetupWindowController.shared.show(focus: .prod) }
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
        .animation(Motion.ease(0.12), value: isHovered)
    }

    /// The chip's forms, widest first: the words and the numbers over their line, the words, the
    /// count alone ("Prod 2"), the dot and "Prod" (what a calm chip is). A form that says no more
    /// than the next one is the same width, so the row skips it.
    private enum Form { case full, words, count, calm }

    /// The number a "Prod 2" says: the alerting monitors (else the incidents), or the warnings.
    static func count(level: ProdStore.Level, snapshot: ProdSnapshot) -> Int? {
        switch level {
        case .alert: return snapshot.alertCount > 0 ? snapshot.alertCount : snapshot.incidents.isEmpty ? nil : snapshot.incidents.count
        case .warn: return snapshot.warnCount > 0 ? snapshot.warnCount : nil
        default: return nil
        }
    }

    /// The tone is carried by the dot and the words; an open chip is the standard selected look
    /// (green fill, its own ink), the tone only in the dot, so nothing coloured sits on the fill.
    private func label(_ form: Form, level: ProdStore.Level, snapshot: ProdSnapshot, isOpen: Bool) -> some View {
        let tone: Color = level == .alert ? Palette.failed : Palette.waiting
        let ink: Color = isOpen ? Palette.onDone : Palette.ink2
        return HStack(spacing: 4) {
            Circle().fill(Self.color(level)).frame(width: 6, height: 6).decorative()
            Text("Prod").font(Typo.label(.semibold)).foregroundStyle(ink)
            if prod.isSnoozed {
                Image(systemName: "moon.zzz.fill").font(Typo.micro()).foregroundStyle(isOpen ? Palette.onDone : Palette.ink3).decorative()
            } else if form == .count, let count = Self.count(level: level, snapshot: snapshot) {
                Text("\(count)").font(Typo.label(.semibold).monospacedDigit()).foregroundStyle(isOpen ? Palette.onDone : tone)
            } else if form == .full || form == .words, let words = Self.words(level: level, snapshot: snapshot) {
                Text(words).font(Typo.label(.semibold)).foregroundStyle(isOpen ? Palette.onDone : tone)
            }
            // Only a number over its line: the others are in the panel's Performance.
            if form == .full, !prod.isSnoozed, level != .unknown {
                ForEach(snapshot.numbers.filter(\.isOver), id: \.label) { number in
                    Text("\(number.label) \(number.valueText)")
                        .font(Typo.label().monospacedDigit())
                        .foregroundStyle(isOpen ? Palette.onDone : Palette.waiting)
                }
            }
        }
        .lineLimit(1).fixedSize()
    }

    /// "2 alerting · 1 incident", "1 warning": nil when nothing needs a look.
    static func words(level: ProdStore.Level, snapshot: ProdSnapshot) -> String? {
        switch level {
        case .alert:
            let parts = [snapshot.alertCount > 0 ? "\(snapshot.alertCount) alerting" : nil,
                         snapshot.incidents.isEmpty ? nil : snapshot.incidents.count == 1 ? "1 incident" : "\(snapshot.incidents.count) incidents"]
            return parts.compactMap { $0 }.joined(separator: " · ")
        case .warn:
            return snapshot.warnCount > 0 ? "\(snapshot.warnCount) warning" : nil
        default: return nil
        }
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

/// The hover card's frame, or none in the Prod section.
private struct CardFrame: ViewModifier {
    var inPanel: Bool

    func body(content: Content) -> some View {
        if inPanel {
            content.frame(maxWidth: .infinity, alignment: .leading)
        } else {
            content
                .padding(.horizontal, 10).padding(.vertical, 8)
                .frame(width: 300, alignment: .leading)
                .floatingCard(radius: 10)
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.track, lineWidth: 1))
                .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
        }
    }
}

/// What the chip's hover shows: the alerting monitors and incidents, else that all is well.
private struct ProdCard: View {
    @ObservedObject var prod: ProdStore
    /// In the Prod section: no floating card around it.
    var inPanel = false
    private static let maxRows = 6

    var body: some View {
        let snapshot = prod.snapshot
        let level = prod.level
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle().fill(ProdChip.color(level)).frame(width: 6, height: 6)
                Text(headline).font(Typo.body(.semibold)).foregroundStyle(Palette.ink)
                Spacer(minLength: 8)
                if snapshot.monitorsAt > 0, prod.greyReason == nil {
                    Text(ago(prod.now - snapshot.monitorsAt)).font(Typo.label()).foregroundStyle(Palette.ink3)
                }
            }
            if let reason = detail {
                Text(reason).font(Typo.label()).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true)
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
            if more > 0 { Text("+\(more) more").font(Typo.label()).foregroundStyle(Palette.ink3) }
            if snapshot.access == .ok, prod.greyReason == nil { DeployCardSections(prod: prod) }
            ForEach(notes, id: \.self) { note in
                Text(note).font(Typo.label()).foregroundStyle(Palette.ink3)
            }
            if prod.isSnoozed {
                Text("Snoozed until \(Self.clock.string(from: Date(timeIntervalSince1970: prod.snoozedUntil)))")
                    .font(Typo.label()).foregroundStyle(Palette.ink3)
            }
        }
        .modifier(CardFrame(inPanel: inPanel))
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
            Image(systemName: icon).font(Typo.caption()).foregroundStyle(color).frame(width: 12).decorative()
            Text(text).font(Typo.body()).foregroundStyle(Palette.ink).lineLimit(1).truncationMode(.tail)
        }
    }
}
