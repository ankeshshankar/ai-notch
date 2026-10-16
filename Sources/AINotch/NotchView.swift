import AppKit
import NotchCore
import SwiftUI

/// One colour that resolves per appearance: the system's, live (or `--theme` in a preview).
private func adaptive(light: NSColor, dark: NSColor) -> Color {
    Color(nsColor: adaptiveNS(light: light, dark: dark))
}

private func adaptiveNS(light: NSColor, dark: NSColor) -> NSColor {
    NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
}

private func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}

private func gray(_ w: CGFloat, _ a: CGFloat = 1) -> NSColor { NSColor(white: w, alpha: a) }

/// The dropped-down body's colours by role, each with a light and a dark value.
enum Palette {
    // The accent hues as they read on black. Tints behind tags use them in both themes.
    static let claudeHue = Color(red: 0.85, green: 0.47, blue: 0.34)
    static let waitingHue = Color(red: 0.96, green: 0.65, blue: 0.14)
    static let doneHue = Color(red: 0.30, green: 0.76, blue: 0.54)
    static let mcpHue = Color(red: 0.56, green: 0.52, blue: 0.91)

    // Accents for text and marks, stepped darker on light for ≥ 4.5:1 on its cards.
    static let claudeNS = adaptiveNS(light: rgb(0.71, 0.33, 0.18), dark: rgb(0.85, 0.47, 0.34))
    static let claude = Color(nsColor: claudeNS)
    static let waiting = adaptive(light: rgb(0.60, 0.34, 0.0), dark: rgb(0.96, 0.65, 0.14))
    static let done = adaptive(light: rgb(0.11, 0.50, 0.31), dark: rgb(0.30, 0.76, 0.54))
    static let mcp = adaptive(light: rgb(0.36, 0.31, 0.79), dark: rgb(0.56, 0.52, 0.91))
    static let failedNS = adaptiveNS(light: rgb(0.78, 0.16, 0.14), dark: rgb(1.0, 0.23, 0.19, 0.82))
    static let failed = Color(nsColor: failedNS)
    static let failedHue = Color(red: 1.0, green: 0.27, blue: 0.23)
    /// Bitbucket's blue, for its source tag.
    static let bitbucketHue = Color(red: 0.15, green: 0.52, blue: 1.0)
    static let bitbucket = adaptive(light: rgb(0.0, 0.32, 0.80), dark: rgb(0.40, 0.66, 1.0))

    // Text.
    static let ink = adaptive(light: gray(0.0, 0.88), dark: gray(1.0))
    static let ink2 = adaptive(light: gray(0.0, 0.72), dark: gray(1.0, 0.62))
    static let ink3 = adaptive(light: gray(0.0, 0.58), dark: gray(1.0, 0.42))

    // Surfaces: the body, the cards on it, and what sits on the cards.
    static let surface = adaptive(light: gray(0.94), dark: gray(0.0))
    static let card = adaptive(light: gray(1.0), dark: gray(1.0, 0.07))
    static let panel = adaptive(light: gray(1.0), dark: gray(1.0, 0.05))
    static let cardHover = adaptive(light: gray(0.0, 0.035), dark: gray(1.0, 0.05))
    static let hairline = adaptive(light: gray(0.0, 0.07), dark: gray(1.0, 0.0))
    static let subcard = adaptive(light: gray(0.0, 0.04), dark: gray(1.0, 0.07))
    static let inset = adaptive(light: gray(0.0, 0.04), dark: gray(0.0, 0.25))
    static let chip = adaptive(light: gray(0.0, 0.06), dark: gray(1.0, 0.08))
    static let track = adaptive(light: gray(0.0, 0.07), dark: gray(1.0, 0.07))
    /// The cut-out ring around the host badge: the row's own fill, opaque.
    static let badgeRing = adaptive(light: gray(1.0), dark: gray(0.0))
    static let badgeRingWaiting = adaptive(light: rgb(1.0, 0.94, 0.82), dark: gray(0.0))

    // Selected controls: the range in use, an open panel.
    static let selected = adaptive(light: gray(0.0, 0.82), dark: gray(1.0, 0.85))
    static let onSelected = adaptive(light: gray(1.0), dark: gray(0.0))
    static let onDone = adaptive(light: gray(1.0), dark: gray(0.0))

    // A waiting row, and the greens of bars and the contribution grid.
    static let waitingTint = adaptive(light: rgb(1.0, 0.94, 0.82), dark: rgb(0.96, 0.65, 0.14, 0.16))
    /// The approval card on a waiting row: a step off the row's own tint.
    static let approvalCard = adaptive(light: gray(1.0, 0.75), dark: gray(0.0, 0.35))
    static let waitingEdge = adaptive(light: rgb(0.96, 0.65, 0.14, 0.45), dark: rgb(0.96, 0.65, 0.14, 0.0))
    /// A failed run the notch has not shown you yet, and the edge of any failed run.
    static let failedTint = adaptive(light: rgb(1.0, 0.93, 0.92), dark: rgb(1.0, 0.23, 0.19, 0.13))
    static let failedEdge = adaptive(light: rgb(0.86, 0.20, 0.16, 0.35), dark: rgb(1.0, 0.23, 0.19, 0.30))
    static let bar = adaptive(light: rgb(0.16, 0.62, 0.36), dark: rgb(0.30, 0.76, 0.54, 0.8))
    static let grid = adaptive(light: rgb(0.16, 0.62, 0.36), dark: rgb(0.30, 0.76, 0.54))
}

/// The top row sits on the black hardware notch in every theme, so it keeps light-on-black.
enum Strip {
    static let ink = Color.white
    static let ink2 = Color.white.opacity(0.62)
    static let ink3 = Color.white.opacity(0.42)
    static let claude = Palette.claudeHue
    static let claudeNS = rgb(0.85, 0.47, 0.34)
    static let waiting = Palette.waitingHue
    static let waitingNS = rgb(0.96, 0.65, 0.14)
    static let done = Palette.doneHue
    static let failed = Color(red: 1.0, green: 0.36, blue: 0.32)
}

func elapsed(_ seconds: Double) -> String {
    let s = max(0, Int(seconds))
    if s < 60 { return "\(s)s" }
    let m = s / 60
    if m < 60 { return "\(m)m\(String(format: "%02d", s % 60))s" }
    return "\(m / 60)h\(String(format: "%02d", m % 60))m"
}

/// The notch's outline: flush with the top edge, rounded below.
struct NotchShape: Shape {
    var radius: CGFloat
    var animatableData: CGFloat {
        get { radius }
        set { radius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        Path(UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius, style: .continuous).path(in: rect).cgPath)
    }
}

struct RootView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var builds: BuildStore
    @ObservedObject var prod: ProdStore
    @ObservedObject var machine: MachineStore
    @ObservedObject var reviews: ReviewStore
    @ObservedObject var controller: NotchController
    /// The black edge left around the body's card.
    static let bezel: CGFloat = 5

    var body: some View {
        let g = controller.geometry
        let wings = controller.showsWings
        let expanded = controller.isExpanded
        // Two columns when the agents and the right side (pipeline runs, or pull requests that
        // need something) both have rows to show and the screen has room; else one, so neither
        // side stands empty.
        let wide = g.canGoWide && !store.sessions.isEmpty && ((builds.showsSection && !builds.rows.isEmpty) || reviews.showsBlock)
        let width = wide ? g.wideWidth : g.expandedWidth
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if wings { LeftWing(store: store, builds: builds).frame(width: g.wing) }
                Color.clear.frame(width: g.notchWidth)
                if wings { RightWing(store: store, builds: builds, prod: prod, machine: machine, reviews: reviews).frame(width: g.wing) }
            }
            .frame(height: g.notchHeight)
            // Something in prod is open (red), else memory is low (amber): a still dot in the
            // strip's corner (on a wing, beside the hardware notch, where it shows).
            .overlay(alignment: .topTrailing) {
                CornerDot(color: !wings ? nil : prod.hasOpenAlert ? Strip.failed : machine.showsDot ? Strip.waiting : nil)
            }

            if expanded {
                // The body is a card set into the black shape: on light it hangs under the strip
                // inside a thin black bezel, on dark it is the black itself.
                SessionList(store: store, approvals: store.approvals, builds: builds, prod: prod, machine: machine, reviews: reviews, controller: controller,
                            isPinned: controller.isPinned, openPanel: controller.openPanel, isWide: wide, maxHeight: g.maxHeight - Self.bezel)
                    .background(
                        UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 22 - Self.bezel,
                                               bottomTrailingRadius: 22 - Self.bezel, topTrailingRadius: 12, style: .continuous)
                            .fill(Palette.surface)
                    )
                    .padding(.horizontal, Self.bezel)
                    .padding(.bottom, Self.bezel)
                    .frame(width: width)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.asymmetric(
                        insertion: .opacity.animation(.easeOut(duration: 0.14).delay(0.03)),
                        removal: .opacity.animation(.easeIn(duration: 0.08))
                    ))
            }
        }
        .frame(width: expanded ? width : g.collapsedWidth(showsWings: wings))
        // Black in every theme: it is the hardware notch, grown.
        .background(NotchShape(radius: expanded ? 22 : 11).fill(Color.black))
        .overlay(WaitingGlow(isOn: !store.waiting.isEmpty && !expanded, radius: 11))
        .clipShape(NotchShape(radius: expanded ? 22 : 11))
        .onGeometryChange(for: CGSize.self, of: { $0.size }) { size in
            controller.shapeSize = size
        }
        // The window is a fixed box; the shape hangs from its top centre.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: expanded)
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: wings)
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: wide)
    }
}

/// Sizes its one subview to its natural height up to `cap`, then gives it exactly `cap`: a
/// ScrollView inside hugs short content and scrolls long content, with no measuring pass.
private struct CappedHeight: Layout {
    var cap: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let natural = child.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? natural.width, height: min(natural.height, cap))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

/// A pulsing amber outline while a session waits on you.
private struct WaitingGlow: View {
    var isOn: Bool
    var radius: CGFloat

    var body: some View {
        if isOn {
            LoopLayer(kind: .glow(radius: radius, lineWidth: 0.75), color: Strip.waitingNS)
                .allowsHitTesting(false)
        }
    }
}

/// A small rotating arc: something is running.
struct Spinner: View {
    var color: NSColor = Palette.claudeNS
    var size: CGFloat = 11

    var body: some View {
        LoopLayer(kind: .spinner(lineWidth: 2), color: color)
            .frame(width: size, height: size)
    }
}

private struct LeftWing: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var builds: BuildStore

    var body: some View {
        HStack(spacing: 4) {
            // Working sessions and active builds or runs.
            let busy = store.working.count + builds.activeCount
            if busy > 0 || store.runningAgents > 0 {
                Spinner(color: Strip.claudeNS)
                if busy > 1 { Text("\(busy)").font(.system(size: 11, weight: .semibold)).foregroundStyle(Strip.ink) }
            } else {
                Image(systemName: "sparkle").font(.system(size: 10, weight: .semibold)).foregroundStyle(Strip.ink3)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct RightWing: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var builds: BuildStore
    @ObservedObject var prod: ProdStore
    @ObservedObject var machine: MachineStore
    @ObservedObject var reviews: ReviewStore

    var body: some View {
        // One slot, in WingSlot's order.
        let slot = WingSlot.pick(waiting: store.waiting.count, memoryCritical: machine.showsSlot, justDone: store.now - store.lastDoneAt < 4,
                                 prodAlert: prod.hasUnseenAlert, buildFailure: builds.hasUnseenFailure,
                                 pullRequestNews: reviews.unseenCount, subagents: store.runningAgents, building: builds.activeCount)
        HStack(spacing: 4) {
            switch slot {
            case .waiting(let count):
                LoopLayer(kind: .dot, color: Strip.waitingNS)
                    .frame(width: 7, height: 7)
                Text("\(count)").font(.system(size: 11, weight: .semibold)).foregroundStyle(Strip.waiting)
            case .done:
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Strip.done)
            case .prodAlert:
                // A monitor went to Alert, or an incident was declared, since the notch was last looked at.
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(Strip.failed)
            case .buildFailure:
                // A build or run failed since the notch was last opened.
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Strip.failed)
            case .subagents(let count):
                Image(systemName: "person.2.fill").font(.system(size: 9)).foregroundStyle(Strip.ink2)
                Text("\(count)").font(.system(size: 11, weight: .semibold)).foregroundStyle(Strip.ink2)
            case .building(let count):
                Image(systemName: "hammer.fill").font(.system(size: 9)).foregroundStyle(Strip.ink2)
                Text("\(count)").font(.system(size: 11, weight: .semibold)).foregroundStyle(Strip.ink2)
            case .memoryCritical:
                // Memory critical: static, no animation.
                Image(systemName: "memorychip.fill").font(.system(size: 10, weight: .semibold)).foregroundStyle(Strip.waiting)
            case .pullRequestNews(let count):
                // News on pull requests (a review request, an approval, changes, comments, a failed
                // build) since the notch was last looked at.
                Image(systemName: "arrow.triangle.pull").font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.bitbucketHue)
                Text("\(count)").font(.system(size: 11, weight: .semibold)).foregroundStyle(Strip.ink)
            case .none:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SessionList: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var approvals: ApprovalCenter
    @ObservedObject var builds: BuildStore
    @ObservedObject var prod: ProdStore
    @ObservedObject var machine: MachineStore
    @ObservedObject var reviews: ReviewStore
    var controller: NotchController
    /// Pinned open; passed by value so the header redraws when it changes.
    var isPinned: Bool
    /// Which of the full-width panels is open (Usage, Code or Machine, from the controller);
    /// by value for the same reason.
    var openPanel: String?
    /// Two columns, agents left and pipelines right, or one with the pipelines under the agents.
    var isWide: Bool
    /// The tallest the body may be; past it the rows scroll.
    var maxHeight: CGFloat
    /// Each approval card's height, which its row keeps free so the card sits inside it.
    @State private var cardHeights: [String: CGFloat] = [:]
    /// One column: six rows between agents and pipelines. Two columns: six each.
    private let maxRows = 6
    /// The session whose details are open; one at a time keeps the panel short.
    @State private var detailId: String?
    /// The header's and the footer's heights, for what is left to the rows.
    @State private var headerHeight: CGFloat = 22
    @State private var footerHeight: CGFloat = 13
    private static let padTop: CGFloat = 8, padBottom: CGFloat = 9, spacing: CGFloat = 8

    var body: some View {
        VStack(alignment: .leading, spacing: Self.spacing) {
            Group {
                if isWide {
                    HStack(alignment: .center, spacing: NotchGeometry.gutter) {
                        agentsHeader.frame(maxWidth: .infinity)
                        rightHeader.frame(maxWidth: .infinity)
                    }
                } else {
                    agentsHeader
                }
            }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { if headerHeight != $0 { headerHeight = $0 } }
            // Above the rows, so the PRs chip's hover card is drawn over them.
            .zIndex(1)

            // The rows, at their natural height up to what the cap leaves, then scrolling: in two
            // columns each on its own, under an open Usage or Code panel all together.
            let cap = max(120, maxHeight - Self.padTop - Self.padBottom - 2 * Self.spacing - headerHeight - footerHeight)
            if isWide && openPanel == nil {
                HStack(alignment: .top, spacing: NotchGeometry.gutter) {
                    scrolling(cap) { agentsColumn }
                    scrolling(cap) { pipelinesColumn }
                }
            } else {
                scrolling(cap) {
                    VStack(alignment: .leading, spacing: Self.spacing) {
                        if openPanel == "Usage" { UsagePanel(usage: store.usage, now: store.now, claudeLimits: store.claudeLimits) }
                        if openPanel == "Code" { CodePanel(lines: store.usage.lines, git: store.gitLines, now: store.now) }
                        if openPanel == NotchController.machinePanel, machine.isOn { MachinePanel(machine: machine, feed: machine.feed) }
                        if openPanel == NotchController.pullRequestsPanel, reviews.isOn {
                            PullRequestsPanel(reviews: reviews, controller: controller, now: store.now, isWide: isWide)
                        }
                        if isWide {
                            HStack(alignment: .top, spacing: NotchGeometry.gutter) {
                                agentsColumn
                                pipelinesColumn
                            }
                        } else {
                            // Six rows between agents and pipelines: agents first, pipelines at least two.
                            let pipelineRows = !builds.showsSection ? 0 : max(1, min(builds.rows.count, max(2, maxRows - store.sessions.count)))
                            sessionRows(limit: max(1, (detailId == nil ? maxRows : 3) - pipelineRows))
                            if builds.showsSection {
                                PipelinesSection(builds: builds, now: store.now, limit: pipelineRows, controller: controller, part: .all)
                            }
                            // Pull requests in one line; it opens the PRs panel.
                            if reviews.isOn, !reviews.mine.isEmpty || !reviews.toReview.isEmpty {
                                PullRequestsSummaryLine(reviews: reviews, controller: controller, isOpen: openPanel == NotchController.pullRequestsPanel)
                                    .padding(.top, builds.showsSection ? 0 : 4)
                            }
                        }
                    }
                }
            }

            HStack(spacing: 12) {
                // The status chips on the left (Prod, RAM), Setup and Quit on the right.
                StatusStrip(prod: prod, machine: machine, controller: controller)
                Spacer()
                Button("Setup") {
                    controller.collapse()
                    SetupWindowController.shared.show()
                }
                .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(Palette.ink3)
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(Palette.ink3)
            }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { if footerHeight != $0 { footerHeight = $0 } }
        }
        // With the bezel outside, the same 14 from the shape's edge as before.
        .padding(.horizontal, 14 - RootView.bezel)
        .padding(.top, Self.padTop)
        .padding(.bottom, Self.padBottom)
    }

    /// Content at its natural height up to `cap`, scrolling past it.
    private func scrolling(_ cap: CGFloat, @ViewBuilder _ content: () -> some View) -> some View {
        CappedHeight(cap: cap) {
            ScrollView(.vertical) { content() }
        }
    }

    /// Two columns: the agents on the left, six rows (three with one's details open).
    private var agentsColumn: some View {
        VStack(alignment: .leading, spacing: Self.spacing) { sessionRows(limit: detailId == nil ? maxRows : 3) }
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// Two columns: the pipelines on the right, six rows of their own, then the pull requests
    /// that need something.
    private var pipelinesColumn: some View {
        VStack(alignment: .leading, spacing: Self.spacing) {
            if builds.showsSection {
                PipelinesSection(builds: builds, now: store.now, limit: maxRows, controller: controller, part: .rows)
            }
            // With the PRs panel open above, its rows are there already.
            if reviews.showsBlock, openPanel != NotchController.pullRequestsPanel {
                PullRequestsBlock(reviews: reviews, controller: controller, limit: 4, header: builds.showsSection)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// Two columns: the right one's header. Pipelines' (with the PRs chip when pull requests are
    /// on), else the pull requests' own.
    @ViewBuilder private var rightHeader: some View {
        if builds.showsSection {
            HStack(spacing: 6) {
                PipelinesSection(builds: builds, now: store.now, limit: maxRows, controller: controller, part: .header)
                if reviews.isOn { PRsChip(reviews: reviews, controller: controller, hover: controller.hover) }
            }
        } else {
            PullRequestsHeader(reviews: reviews, controller: controller)
        }
    }

    private var agentsHeader: some View {
        HStack(spacing: 8) {
            Text("Agents").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink)
            Spacer()
            Text(summary).font(.system(size: 11)).foregroundStyle(Palette.ink2).lineLimit(1)
            LimitsChip(limits: store.claudeLimits, now: store.now)
            panelButton("Usage", icon: "chart.bar.fill")
            panelButton("Code", icon: "chevron.left.forwardslash.chevron.right")
            pinButton
        }
    }

    /// The sessions, at most `limit` of them, and how many more there are.
    @ViewBuilder private func sessionRows(limit: Int) -> some View {
        if store.sessions.isEmpty {
            Text("No open sessions")
                .font(.system(size: 12)).foregroundStyle(Palette.ink2)
                .padding(.vertical, 6)
        }
        ForEach(store.sessions.prefix(limit), id: \.id) { session in
            let isOpen = detailId == session.id
            let title = store.title(of: session)
            let asks = approvals.pending(for: session.id)
            let space = asks.isEmpty ? 0 : (cardHeights[session.id] ?? 0) + 8
            // Sibling buttons: the row jumps to the session, the card answers its prompt, the
            // corner toggles its details.
            ZStack(alignment: .bottomTrailing) {
                Button {
                    controller.collapse()
                    Jump.to(session)
                } label: {
                    SessionRow(session: session, title: title, now: store.now, agentActivity: store.agentActivity, agentModels: store.agentModels,
                               usage: store.usage.sessions[session.id], agentUsage: store.usage.agentShare[session.id], isDetailed: isOpen,
                               reserved: space, live: store.usage.live[session.id])
                        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(RowButtonStyle())

                VStack(alignment: .trailing, spacing: 8) {
                    if let first = asks.first {
                        ApprovalCard(center: approvals, item: first, chat: title, more: asks.count - 1)
                            .id(first.id)
                            .padding(.leading, 38)
                            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
                                if cardHeights[session.id] != height { cardHeights[session.id] = height }
                            }
                    }
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { detailId = isOpen ? nil : session.id }
                    } label: {
                        HStack(spacing: 3) {
                            Text(isOpen ? "Less" : "Details").font(.system(size: 10, weight: .medium))
                            Image(systemName: isOpen ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold))
                        }
                        .foregroundStyle(Palette.ink2)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(Palette.chip))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(8)
            }
        }
        if store.sessions.count > limit {
            Text("+\(store.sessions.count - limit) more").font(.system(size: 11)).foregroundStyle(Palette.ink3)
        }
    }

    private func panelButton(_ name: String, icon: String) -> some View {
        let isOpen = openPanel == name
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { controller.openPanel = isOpen ? nil : name }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 9, weight: .semibold))
                Text(name).font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(isOpen ? Palette.onDone : Palette.ink2)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(isOpen ? Palette.done : Palette.chip))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Keeps the notch open: the header's pin, filled while pinned.
    private var pinButton: some View {
        Button {
            controller.togglePin()
        } label: {
            Image(systemName: isPinned ? "pin.fill" : "pin")
                .font(.system(size: 9, weight: .semibold))
                .rotationEffect(.degrees(45))
                .foregroundStyle(isPinned ? Palette.onDone : Palette.ink2)
                .frame(width: 12, height: 12)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Capsule().fill(isPinned ? Palette.done : Palette.chip))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(isPinned
              ? "Pinned open: it stays open when the pointer leaves or you click a row. Click to unpin. Over a full-screen app it opens only on hover."
              : "Pin open: keep the notch open when the pointer leaves or you click a row. Clicks outside it still reach the app below.")
    }

    private var summary: String {
        var parts: [String] = []
        if !store.working.isEmpty { parts.append("\(store.working.count) working") }
        if !store.waiting.isEmpty { parts.append("\(store.waiting.count) waiting") }
        if store.runningAgents > 0 { parts.append(store.runningAgents == 1 ? "1 agent" : "\(store.runningAgents) agents") }
        // Beside the limits chip, two parts fit; the agents show in the rows anyway.
        let hasChip = current(store.claudeLimits?.fiveHour, now: store.now) != nil || current(store.claudeLimits?.weekly, now: store.now) != nil
        return parts.isEmpty ? "\(store.sessions.count) idle" : parts.prefix(hasChip ? 2 : 3).joined(separator: " · ")
    }
}

/// Claude Code's token use and its API-price cost, opened from the Usage button: a range, the
/// totals, and where it went (where Claude Code ran, which model).
private struct UsagePanel: View {
    var usage: UsageSnapshot
    var now: Double
    var claudeLimits: ToolLimits?
    @State private var range = 1

    private static let ranges = ["Today", "30 days", "Lifetime"]
    private static let since: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy"
        return formatter
    }()

    var body: some View {
        let sinceDay: String? = range == 0 ? UsageScanner.day(of: now) : range == 1 ? UsageScanner.day(of: now - 29 * 86_400) : nil
        let total = sinceDay.map { usage.total(sinceDay: $0) } ?? usage.allTime
        let parts = usage.breakdown(sinceDay: sinceDay)
        VStack(alignment: .leading, spacing: 8) {
            LimitsBlock(claude: claudeLimits, codex: usage.codexLimits, now: now)
            HStack(spacing: 6) {
                Text("All AI tools").font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.done)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Palette.doneHue.opacity(0.16)))
                Text("≈ API price").font(.system(size: 10)).foregroundStyle(Palette.ink3)
                InfoMark(text: usageNote)
                Spacer()
                ForEach(Self.ranges.indices, id: \.self) { index in
                    Button { range = index } label: {
                        Text(Self.ranges[index]).font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(range == index ? Palette.onSelected : Palette.ink2)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Capsule().fill(range == index ? Palette.selected : Palette.chip))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(compactTokens(total.total)).font(.system(size: 22, weight: .bold).monospacedDigit()).foregroundStyle(Palette.ink)
                Text("tokens").font(.system(size: 11)).foregroundStyle(Palette.ink3)
                Text(money(total.cost)).font(.system(size: 17, weight: .bold).monospacedDigit()).foregroundStyle(Palette.done)
                Spacer()
                if range == 2, let first = usage.earliestDay.flatMap(UsageScanner.date(of:)) {
                    Text("since \(Self.since.string(from: first))").font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.ink2)
                }
                if usage.isScanning { Text("counting…").font(.system(size: 10)).foregroundStyle(Palette.ink3) }
            }
            Text("in \(compactTokens(total.input)) · out \(compactTokens(total.output)) · cache write \(compactTokens(total.cacheWrite)) · cache read \(compactTokens(total.cacheRead))")
                .font(.system(size: 10).monospacedDigit()).foregroundStyle(Palette.ink3)
            breakdown("Tool", parts.bySource.map { (Self.sourceName($0.0), $0.1) }, total: total.cost)
            breakdown("Model", parts.byModel.map { (modelName($0.0), $0.1) }, total: total.cost)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.panel))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
    }

    private var usageNote: String {
        var note = "Claude Code's transcripts, Codex's session logs, Qwen Code's chats and OpenCode's database, each API request once (Claude's /stats counts a reply once per content block, about twice this). Claude at Anthropic's prices, others at LiteLLM's list (or the cost OpenCode recorded). Cursor's own agent reports no tokens. On a subscription this is the API-price value, not your bill."
        if range == 2 { note += " Lifetime starts at \(usage.earliestDay ?? "your oldest transcript")." }
        return note
    }

    static func sourceName(_ entrypoint: String) -> String {
        switch entrypoint {
        case "claude-vscode": return "Claude Code · editor"
        case "cli": return "Claude Code · terminal"
        case "sdk-ts", "sdk-py", "sdk-cli": return "Claude Code · Agent SDK"
        case "codex": return "Codex"
        case "opencode": return "OpenCode"
        case "qwen": return "Qwen Code"
        case "archived": return "Deleted transcripts"
        default: return entrypoint.capitalized
        }
    }

    /// Labelled rows with a bar for each one's share of the cost.
    private func breakdown(_ title: String, _ items: [(String, TokenTally)], total: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.ink3)
            ForEach(items.prefix(6), id: \.0) { name, tally in
                HStack(spacing: 8) {
                    Text(name).font(.system(size: 11)).foregroundStyle(Palette.ink.opacity(0.85)).lineLimit(1)
                        .frame(width: 190, alignment: .leading)
                    GeometryReader { proxy in
                        Capsule().fill(Palette.track)
                            .overlay(alignment: .leading) {
                                Capsule().fill(Palette.bar)
                                    .frame(width: max(3, proxy.size.width * (total > 0 ? tally.cost / total : 0)))
                            }
                    }
                    .frame(height: 6)
                    Text(compactTokens(tally.total)).font(.system(size: 10).monospacedDigit()).foregroundStyle(Palette.ink2)
                        .frame(width: 46, alignment: .trailing)
                    Text(money(tally.cost)).font(.system(size: 10, weight: .semibold).monospacedDigit()).foregroundStyle(Palette.done)
                        .frame(width: 58, alignment: .trailing)
                }
            }
        }
    }
}

/// Code Claude Code wrote: a contribution grid of lines added per day, the day under the pointer,
/// and each repository's lines beside what was committed to git there.
private struct CodePanel: View {
    var lines: [String: [String: LineTally]]
    var git: [String: [String: LineTally]]
    var now: Double
    @State private var hoveredDay: String?
    @Environment(\.hoverHub) private var hub

    private let weeks = 26
    private static let grid = "code-grid"
    private let cell: CGFloat = 11
    private let gap: CGFloat = 3

    private static let labelFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE d MMM"
        return formatter
    }()

    var body: some View {
        let days = gridDays()
        let perDay = days.map { inRepos(lines[$0]) }
        let most = perDay.map(\.added).max() ?? 0
        let monthStart = UsageScanner.day(of: now - 29 * 86_400)
        let month = total(since: monthStart)
        let lifetime = total(since: nil)
        let gitMonth = gitTotal(since: monthStart)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                EngineTag(isCursor: false)
                Text("lines per day").font(.system(size: 10)).foregroundStyle(Palette.ink3)
                InfoMark(text: "From the edits in Claude Code's transcripts, subagents included, by git repository; files outside a repository are left out. Git counts every commit in those repositories, on any branch, by anyone and any tool, once each, without lockfiles.")
                Spacer()
            }
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                figure("30 days", month, git: gitMonth)
                figure(lifetimeLabel, lifetime, git: nil)
            }
            // Weeks run left to right, Monday to Sunday top to bottom, today last.
            HStack(alignment: .top, spacing: gap) {
                ForEach(0..<weeks, id: \.self) { week in
                    VStack(spacing: gap) {
                        ForEach(0..<7, id: \.self) { weekday in
                            let index = week * 7 + weekday
                            if index < days.count {
                                let day = days[index]
                                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                                    .fill(shade(perDay[index].added, most: most))
                                    .overlay(RoundedRectangle(cornerRadius: 2.5).stroke(Palette.ink.opacity(day == hoveredDay ? 0.9 : day == days.last ? 0.45 : 0), lineWidth: 1))
                                    .frame(width: cell, height: cell)
                                    .onHover { inside in if inside, hub == nil { hoveredDay = day } }
                            } else {
                                Color.clear.frame(width: cell, height: cell)
                            }
                        }
                    }
                }
            }
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { frame in
                hub?.grids[Self.grid] = (frame, cell + gap)
            }
            .onDisappear { hub?.grids[Self.grid] = nil }
            .background {
                // In the notch the hub says which cell the pointer is over (onHover never fires there).
                if let hub {
                    GridHoverReader(hub: hub, grid: Self.grid) { cell in
                        let index = cell.column * 7 + cell.row
                        if cell.row < 7, index < days.count, hoveredDay != days[index] { hoveredDay = days[index] }
                    }
                }
            }
            dayLine(hoveredDay ?? days.last ?? "")
            repos(since: monthStart)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.panel))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
    }

    /// "Lifetime · since 8 Sep": the first day any edit is on record.
    private var lifetimeLabel: String {
        guard let first = lines.filter({ !$0.value.isEmpty }).keys.min(), let date = UsageScanner.date(of: first) else { return "Lifetime" }
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM"
        return "Lifetime · since \(formatter.string(from: date))"
    }

    /// The grid's days, oldest first: whole weeks from a Monday, ending today.
    private func gridDays() -> [String] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        let today = calendar.startOfDay(for: Date(timeIntervalSince1970: now))
        let weekday = (calendar.component(.weekday, from: today) + 5) % 7 // Monday 0 … Sunday 6
        guard let start = calendar.date(byAdding: .day, value: -(weeks - 1) * 7 - weekday, to: today) else { return [] }
        let count = (weeks - 1) * 7 + weekday + 1
        return (0..<count).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }.map { UsageScanner.day(of: $0.timeIntervalSince1970) }
    }

    private func inRepos(_ repos: [String: LineTally]?) -> LineTally {
        var sum = LineTally()
        for (repo, tally) in repos ?? [:] where !repo.isEmpty { sum.add(tally) }
        return sum
    }

    private func total(since day: String?) -> LineTally {
        var sum = LineTally()
        for (key, repos) in lines where day.map({ key >= $0 }) ?? true { sum.add(inRepos(repos)) }
        return sum
    }

    private func gitTotal(since day: String) -> LineTally {
        var sum = LineTally()
        for byDay in git.values { for (key, tally) in byDay where key >= day { sum.add(tally) } }
        return sum
    }

    /// One green, from the empty track to full, on a log scale so a quiet day still shows.
    private func shade(_ added: Int, most: Int) -> Color {
        guard added > 0, most > 0 else { return Palette.track }
        let level = log(Double(added) + 1) / log(Double(most) + 1)
        return Palette.grid.opacity(0.25 + 0.75 * level)
    }

    private func figure(_ label: String, _ tally: LineTally, git: LineTally?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.ink3)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("+\(compactTokens(tally.added))").font(.system(size: 16, weight: .bold).monospacedDigit()).foregroundStyle(Palette.done)
                Text("−\(compactTokens(tally.removed))").font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(Palette.failed)
                Text("\(compactTokens(tally.files)) edits").font(.system(size: 10)).foregroundStyle(Palette.ink3)
            }
            if let git, !git.isEmpty {
                Text("git +\(compactTokens(git.added)) −\(compactTokens(git.removed))")
                    .font(.system(size: 9).monospacedDigit()).foregroundStyle(Palette.ink3)
            }
        }
    }

    private func dayLine(_ day: String) -> some View {
        let repos = (lines[day] ?? [:]).filter { !$0.key.isEmpty }.sorted { $0.value.added > $1.value.added }
        let tally = inRepos(lines[day])
        var committed = LineTally()
        for byDay in git.values { if let t = byDay[day] { committed.add(t) } }
        let date = UsageScanner.date(of: day).map { Self.labelFormatter.string(from: $0) } ?? day
        let names = repos.prefix(3).map { ($0.key as NSString).lastPathComponent }.joined(separator: ", ")
        return HStack(spacing: 6) {
            Text(date).font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.ink.opacity(0.85))
            if tally.isEmpty {
                Text("No edits").font(.system(size: 10)).foregroundStyle(Palette.ink3)
            } else {
                Text("+\(tally.added) −\(tally.removed) · \(tally.files) edits · \(names)")
                    .font(.system(size: 10).monospacedDigit()).foregroundStyle(Palette.ink2).lineLimit(1)
            }
            Spacer(minLength: 4)
            if !committed.isEmpty {
                Text("git +\(compactTokens(committed.added)) −\(compactTokens(committed.removed))")
                    .font(.system(size: 10).monospacedDigit()).foregroundStyle(Palette.ink3).fixedSize()
            }
        }
    }

    /// The repositories Claude Code wrote the most in over 30 days, beside their git commits.
    private func repos(since day: String) -> some View {
        var byRepo: [String: LineTally] = [:]
        for (key, repos) in lines where key >= day {
            for (repo, tally) in repos where !repo.isEmpty { byRepo[repo, default: LineTally()].add(tally) }
        }
        let top = byRepo.sorted { $0.value.added > $1.value.added }.prefix(5)
        let most = top.first?.value.added ?? 1
        return VStack(alignment: .leading, spacing: 4) {
            Text("Repositories · 30 days").font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.ink3)
            ForEach(Array(top), id: \.key) { repo, tally in
                var committed = LineTally()
                let _ = git[repo].map { for (key, t) in $0 where key >= day { committed.add(t) } }
                HStack(spacing: 8) {
                    Text((repo as NSString).lastPathComponent).font(.system(size: 11)).foregroundStyle(Palette.ink.opacity(0.85)).lineLimit(1)
                        .frame(width: 150, alignment: .leading)
                    GeometryReader { proxy in
                        Capsule().fill(Palette.track).overlay(alignment: .leading) {
                            Capsule().fill(Palette.bar).frame(width: max(3, proxy.size.width * Double(tally.added) / Double(max(most, 1))))
                        }
                    }
                    .frame(height: 6)
                    Text("+\(compactTokens(tally.added)) −\(compactTokens(tally.removed))").font(.system(size: 10, weight: .semibold).monospacedDigit()).foregroundStyle(Palette.done)
                        .frame(width: 84, alignment: .trailing)
                    Text(committed.isEmpty ? "git —" : "git +\(compactTokens(committed.added))").font(.system(size: 10).monospacedDigit()).foregroundStyle(Palette.ink3)
                        .frame(width: 62, alignment: .trailing)
                }
            }
        }
    }
}

/// How full a limit is, as a colour: calm, then amber from 70%, red from 90%.
private func limitColor(_ percent: Double) -> Color {
    percent >= 90 ? Palette.failed : percent >= 70 ? Palette.waiting : Palette.done
}

/// "in 1h12m" within a day, else "Wed 21:30".
private func resetText(_ time: Double?, now: Double) -> String {
    guard let time else { return "" }
    if time <= now { return "reset" }
    if time - now < 86_400 { return "resets in \(elapsed(time - now))" }
    let formatter = DateFormatter()
    formatter.dateFormat = "EEE HH:mm"
    return "resets " + formatter.string(from: Date(timeIntervalSince1970: time))
}

/// A window whose reset has passed says nothing about now.
private func current(_ window: LimitWindow?, now: Double) -> LimitWindow? {
    guard let window, (window.resetsAt ?? .infinity) > now else { return nil }
    return window
}

/// The header's limits: Claude Code's five-hour and weekly use, in one chip.
private struct LimitsChip: View {
    var limits: ToolLimits?
    var now: Double

    var body: some View {
        let five = current(limits?.fiveHour, now: now), week = current(limits?.weekly, now: now)
        if five != nil || week != nil {
            HStack(spacing: 6) {
                if let five { part("5h", five) }
                if let week { part("wk", week) }
            }
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(Palette.chip))
            .fixedSize()
            .help(tooltip(five: five, week: week))
        }
    }

    private func part(_ label: String, _ window: LimitWindow) -> some View {
        HStack(spacing: 3) {
            Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.ink3)
            Text("\(Int(window.usedPercent.rounded()))%").font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(window.usedPercent >= 70 ? limitColor(window.usedPercent) : Palette.ink2)
        }
    }

    private func tooltip(five: LimitWindow?, week: LimitWindow?) -> String {
        var parts = ["Claude Code plan limits"]
        if let five { parts.append("5 hours: \(Int(five.usedPercent.rounded()))%, \(resetText(five.resetsAt, now: now))") }
        if let week { parts.append("week: \(Int(week.usedPercent.rounded()))%, \(resetText(week.resetsAt, now: now))") }
        if let limits { parts.append("as of \(elapsed(now - limits.at)) ago") }
        return parts.joined(separator: " · ")
    }
}

/// The Usage panel's limits: each tool's windows with a bar, the use and the reset.
private struct LimitsBlock: View {
    var claude: ToolLimits?
    var codex: ToolLimits?
    var now: Double

    var body: some View {
        let rows = self.rows
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Limits").font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.ink3)
                    InfoMark(text: "Claude Code: from the status line in a terminal, else asked of Claude Code itself (as its /usage does) every few minutes while it is in use. Codex: its newest session log. A window past its reset shows nothing until a new reading.")
                    Spacer()
                }
                ForEach(rows.indices, id: \.self) { index in
                    let row = rows[index]
                    HStack(spacing: 8) {
                        Text(row.tool).font(.system(size: 11, weight: row.tool.isEmpty ? .regular : .medium)).foregroundStyle(Palette.ink.opacity(0.85))
                            .lineLimit(1).frame(width: 78, alignment: .leading)
                        Text(row.name).font(.system(size: 10)).foregroundStyle(Palette.ink3).frame(width: 46, alignment: .leading)
                        GeometryReader { proxy in
                            Capsule().fill(Palette.track).overlay(alignment: .leading) {
                                Capsule().fill(limitColor(row.window.usedPercent))
                                    .frame(width: max(3, proxy.size.width * min(1, row.window.usedPercent / 100)))
                            }
                        }
                        .frame(height: 6)
                        Text("\(Int(row.window.usedPercent.rounded()))%").font(.system(size: 10, weight: .semibold).monospacedDigit())
                            .foregroundStyle(limitColor(row.window.usedPercent)).frame(width: 34, alignment: .trailing)
                        Text(row.note).font(.system(size: 10).monospacedDigit()).foregroundStyle(Palette.ink3)
                            .lineLimit(1).frame(width: 118, alignment: .leading)
                    }
                }
            }
        }
    }

    private struct Row { var tool: String; var name: String; var window: LimitWindow; var note: String }

    private var rows: [Row] {
        var rows: [Row] = []
        func add(_ tool: String, _ limits: ToolLimits?) {
            guard let limits else { return }
            let windows = [("5 hours", current(limits.fiveHour, now: now)), ("Week", current(limits.weekly, now: now))].filter { $0.1 != nil }
            // Readings older than a day are labelled with their age.
            let age = now - limits.at
            let stale = age > 86_400 ? " · \(age > 172_800 ? "\(Int(age / 86_400))d" : "\(Int(age / 3600))h") old" : ""
            let plan = limits.plan.map { " \($0.capitalized)" } ?? ""
            for (index, (name, window)) in windows.enumerated() {
                rows.append(Row(tool: index == 0 ? tool + plan : "", name: name, window: window!, note: resetText(window!.resetsAt, now: now) + stale))
            }
        }
        add("Claude", claude)
        add("Codex", codex)
        return rows
    }
}

/// Option buttons laid out in rows that wrap.
private struct FlowOptions<Item: View>: View {
    var options: [String]
    @ViewBuilder var item: (String) -> Item

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(options, id: \.self) { item($0) }
        }
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews) {
            for (index, x) in zip(row.items, row.xs) {
                subviews[index].place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + row.y), proposal: .unspecified)
            }
        }
    }

    private struct Row { var items: [Int] = []; var xs: [CGFloat] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> [Row] {
        var rows = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].items.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                let last = rows[rows.count - 1]
                rows.append(Row(y: last.y + last.height + spacing))
            }
            var row = rows[rows.count - 1]
            let x = row.items.isEmpty ? 0 : row.width + spacing
            row.items.append(index)
            row.xs.append(x)
            row.width = x + size.width
            row.height = max(row.height, size.height)
            rows[rows.count - 1] = row
        }
        return rows
    }
}

/// A small ⓘ whose explanation shows on hover, so the panels (and the setup window) carry no
/// paragraphs.
struct InfoMark: View {
    var text: String

    var body: some View {
        Image(systemName: "info.circle").font(.system(size: 10)).foregroundStyle(Palette.ink3).help(text)
    }
}

/// Who is doing the work: Claude's mark for a Claude Code session, Cursor's for Cursor's own
/// agent; the app it runs in rides as a small badge on the corner when that is another app.
private struct AgentIcon: View {
    var session: SessionState
    var host: NSImage?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if session.isCursorAgent, let host {
                    Image(nsImage: host).resizable()
                } else if let claude = AppInfo.of("com.anthropic.claudefordesktop")?.icon {
                    Image(nsImage: claude).resizable()
                } else {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Palette.claude)
                        .overlay(Image(systemName: "asterisk").font(.system(size: 12, weight: .bold)).foregroundStyle(.white))
                }
            }
            .frame(width: 24, height: 24)

            if !session.isCursorAgent {
                Group {
                    if let host {
                        Image(nsImage: host).resizable()
                    } else {
                        Image(systemName: "terminal.fill").resizable().scaledToFit().padding(2).foregroundStyle(.white)
                            .background(RoundedRectangle(cornerRadius: 3).fill(Color.gray))
                    }
                }
                .frame(width: 12, height: 12)
                .background(Circle().fill(session.phase == .waiting ? Palette.badgeRingWaiting : Palette.badgeRing).frame(width: 15, height: 15))
                .offset(x: 4, y: 4)
            }
        }
        .frame(width: 26, height: 26)
    }
}

/// "Claude Code" in Claude's colour, or "Cursor Agent" in Cursor's.
private struct EngineTag: View {
    var isCursor: Bool

    var body: some View {
        Text(isCursor ? "Cursor Agent" : "Claude Code")
            .font(.system(size: 10, weight: .semibold)).foregroundStyle(isCursor ? Palette.mcp : Palette.claude)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill((isCursor ? Palette.mcpHue : Palette.claudeHue).opacity(0.16)))
            .lineLimit(1)
            .fixedSize()
    }
}

/// A row's card: the fill and the hairline edge every row in the list shares.
struct RowCard: ViewModifier {
    var tint: Color = Palette.card
    var edge: Color = Palette.hairline

    func body(content: Content) -> some View {
        content
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(edge, lineWidth: 1))
    }
}

extension View {
    func rowCard(tint: Color = Palette.card, edge: Color = Palette.hairline) -> some View {
        modifier(RowCard(tint: tint, edge: edge))
    }
}

/// A row that lifts a little under the pointer and dips while pressed.
struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RowBody(label: configuration.label, isPressed: configuration.isPressed)
    }
}

/// In the notch the hover comes from the controller's pointer tick (HoverHub): onHover never fires
/// in its panel, which is never key. Elsewhere, onHover.
struct RowBody<Label: View>: View {
    var label: Label
    var isPressed: Bool
    @Environment(\.hoverHub) private var hub
    @State private var key = "row-" + UUID().uuidString
    @State private var isHovered = false

    var body: some View {
        if let hub {
            HoverZone(hub: hub, key: key) { styled($0) }
        } else {
            styled(isHovered).onHover { isHovered = $0 }
        }
    }

    private func styled(_ hovered: Bool) -> some View {
        label
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.cardHover).opacity(hovered && !isPressed ? 1 : 0).allowsHitTesting(false))
            .brightness(isPressed ? -0.04 : 0)
            .scaleEffect(isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: isPressed)
            .animation(.easeOut(duration: 0.12), value: hovered)
    }
}

/// Calls `onCell` when the pointer moves onto another cell of `grid`.
private struct GridHoverReader: View {
    @ObservedObject var hub: HoverHub
    let grid: String
    var onCell: (HoverHub.Cell) -> Void

    var body: some View {
        Color.clear
            .onChange(of: hub.cell) { _, cell in
                if let cell, cell.grid == grid { onCell(cell) }
            }
    }
}

/// A permission prompt answered from the notch: what the tool will do, and the three answers.
/// The editor shows the same prompt meanwhile; whichever is answered first counts.
private struct ApprovalCard: View {
    @ObservedObject var center: ApprovalCenter
    var item: ApprovalCenter.Pending
    /// The chat that asks, by its title.
    var chat: String
    var more: Int
    /// Off for a moment after the card appears: a click meant for the card before it is ignored.
    @State private var isArmed = false

    var body: some View {
        let request = item.request
        VStack(alignment: .leading, spacing: 7) {
            // Which chat asks: the row above may be scrolled past, or another chat's.
            HStack(spacing: 4) {
                Image(systemName: "bubble.left.fill").font(.system(size: 8))
                Text(chat).font(.system(size: 10, weight: .medium)).lineLimit(1).truncationMode(.tail)
            }
            .foregroundStyle(Palette.ink2)
            .help(chat)
            HStack(spacing: 6) {
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.ink).lineLimit(1)
                if let type = request.agentType {
                    Text(type).font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.ink2)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(Palette.chip)).lineLimit(1).fixedSize()
                }
                Spacer(minLength: 4)
                if more > 0 { Text("+\(more) more").font(.system(size: 10)).foregroundStyle(Palette.ink3) }
                InfoMark(text: note)
            }
            if let question = request.question {
                Text(question.text).font(.system(size: 11)).foregroundStyle(Palette.ink.opacity(0.85))
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            } else if !request.detail.isEmpty, request.detail != request.tool {
                Text(request.detail)
                    .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Palette.ink.opacity(0.8))
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 7).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Palette.inset))
            }
            if let question = request.question {
                // A question: each option is its answer.
                FlowOptions(options: question.options) { option in
                    Button { center.answer(item.id, .answer, option: option) } label: {
                        Text(option).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Palette.ink)
                            .lineLimit(1)
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(Capsule().fill(Palette.chip))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(!isArmed)
                    .opacity(isArmed ? 1 : 0.55)
                }
            } else {
            HStack(spacing: 6) {
                answer("Allow once", .allow, fill: Palette.done, ink: Palette.onDone)
                if !request.sessionRules.isEmpty, request.askRule == nil {
                    answer("Allow for session", .allowSession, fill: Palette.chip, ink: Palette.ink)
                        .help("Until this session ends: " + request.sessionRules.joined(separator: ", "))
                }
                Spacer(minLength: 4)
                answer("Deny", .deny, fill: Palette.chip, ink: Palette.failed)
            }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.approvalCard))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Palette.waitingEdge, lineWidth: 1))
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + ApprovalCenter.armDelay) { isArmed = true }
        }
    }

    private var title: String {
        let request = item.request
        if let question = request.question { return question.header ?? "Question" }
        if let server = request.server { return "\(server) · \(ToolNow(id: "", name: request.tool, server: server, since: 0).shortName)" }
        return request.tool
    }

    private var note: String {
        if item.request.question != nil {
            return "The editor shows this question too; whichever you answer first counts. Pick an option to answer; for anything else, answer in the editor."
        }
        let base = "The editor shows this prompt too; whichever you answer first counts. Allow once runs this call only."
        if let rule = item.request.askRule {
            return base + " Your ask rule \(rule) covers it, so it needs your approval every time: no Allow for session."
        }
        if item.request.sessionRules.isEmpty {
            return base + " Claude Code suggested no rule for it, so there is no Allow for session."
        }
        return base + " Allow for session adds what Claude Code suggested, until the session ends; nothing is saved to settings. There is no always-allow here."
    }

    private func answer(_ label: String, _ decision: ApprovalDecision, fill: Color, ink: Color) -> some View {
        Button {
            center.answer(item.id, decision)
        } label: {
            Text(label).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(ink)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Capsule().fill(fill))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!isArmed)
        .opacity(isArmed ? 1 : 0.55)
    }
}

private struct SessionRow: View {
    var session: SessionState
    /// The chat's name, as its editor lists it.
    var title: String
    var now: Double
    var agentActivity: [String: Double]
    var agentModels: [String: String] = [:]
    /// This session's tokens and cost, its subagents' included, and their share of it.
    var usage: TokenTally?
    var agentUsage: TokenTally?
    var isDetailed = false
    /// Room kept at the bottom for an approval card laid over the row.
    var reserved: CGFloat = 0
    /// Its recent spend and prompt cache.
    var live: LiveSpend?
    /// The Details button's width and gap, kept free at the end of the row's last line.
    static let cornerRoom: CGFloat = 70

    var body: some View {
        let app = AppInfo.of(session.appBundleId)
        HStack(alignment: .top, spacing: 10) {
            AgentIcon(session: session, host: app?.icon)

            VStack(alignment: .leading, spacing: 4) {
                // The chat's name, as its editor lists it.
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink)
                        .lineLimit(1).truncationMode(.tail)
                        .help(title)
                    Spacer(minLength: 4)
                    StatusChip(session: session, now: now).fixedSize()
                        .help("This turn: time since your last message")
                }
                // Under it: the project, who runs it and where, and on what model.
                HStack(spacing: 6) {
                    if title != session.project {
                        Text(session.project).font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.ink2).lineLimit(1)
                    }
                    EngineTag(isCursor: session.isCursorAgent)
                    if !session.isCursorAgent {
                        Text(app.map { "in \($0.name)" } ?? "in Terminal").font(.system(size: 10)).foregroundStyle(Palette.ink3).lineLimit(1)
                    }
                    if let model = session.model {
                        Text(modelName(model)).font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.ink.opacity(0.75))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Palette.chip))
                            .lineLimit(1).fixedSize()
                    }
                    pace
                }
                // With nothing under it, the last line leaves room on its right for the Details
                // button instead of a line of its own.
                let inline = reserved == 0 && !isDetailed && session.agents.isEmpty
                let mcpLine = !isDetailed && !session.mcp.isEmpty
                activity.padding(.trailing, inline && !mcpLine ? Self.cornerRoom : 0)
                if !session.agents.isEmpty { agents }
                if isDetailed {
                    details
                } else if mcpLine {
                    Text("MCP  " + top(session.mcp, 3))
                        .font(.system(size: 10)).foregroundStyle(Palette.ink3).lineLimit(1)
                        .padding(.trailing, inline ? Self.cornerRoom : 0)
                }
                // Room for the Details button in the corner, and the approval card above it.
                if !inline { Color.clear.frame(height: 14 + reserved) }
            }
        }
        .rowCard(tint: session.phase == .waiting ? Palette.waitingTint : Palette.card,
                 edge: session.phase == .waiting ? Palette.waitingEdge : Palette.hairline)
    }

    /// While it works, what it spends a minute; while idle, how long its prompt cache stays warm.
    @ViewBuilder private var pace: some View {
        if session.phase != .idle, let rate = live?.perMinute(now: now, since: session.turnStartedAt) {
            Text("\(money(rate))/min").font(.system(size: 10, weight: .medium).monospacedDigit()).foregroundStyle(Palette.ink3)
                .lineLimit(1).fixedSize()
                .help("This session's replies, subagents included, over the last 10 minutes (or this turn, if shorter), at API prices.")
        } else if session.phase == .idle, let cold = session.promptCacheExpiresAt ?? live?.coldAt, cold > now {
            Text("cache \(cold - now >= 60 ? "\(Int(((cold - now) / 60).rounded(.up)))m" : "\(Int(cold - now))s")").font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(cold - now < 300 ? Palette.waiting : Palette.ink3)
                .lineLimit(1).fixedSize()
                .help("The prompt cache stays warm \(elapsed(cold - now)) more, renewed by each reply. A prompt after that re-reads the whole context at the full input price.")
        }
    }

    @ViewBuilder private var activity: some View {
        switch session.phase {
        case .waiting:
            Label("Waiting for \(session.waitingFor ?? "you")", systemImage: "hand.raised.fill")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.waiting).lineLimit(1)
        case .working:
            if let tool = session.current {
                ToolLine(tool: tool, now: now)
            } else if let last = session.lastTool {
                Text("last ▸ \(label(last)) · \(elapsed(now - last.since)) ago")
                    .font(.system(size: 11)).foregroundStyle(Palette.ink2).lineLimit(1)
            } else {
                Text("Thinking…").font(.system(size: 11)).foregroundStyle(Palette.ink2)
            }
        case .idle:
            Text(idleText).font(.system(size: 11)).foregroundStyle(Palette.ink3).lineLimit(1)
        }
    }

    private var idleText: String {
        var parts: [String] = []
        if let done = session.finishedAt { parts.append("Done \(elapsed(now - done)) ago") } else { parts.append("Idle") }
        if let took = session.lastTurnSeconds { parts.append("took \(elapsed(took))") }
        if session.backgroundTasks > 0 { parts.append("\(session.backgroundTasks) in background") }
        return parts.joined(separator: " · ")
    }

    /// Running subagents first, then the ones that ended in the last few minutes.
    private var agents: some View {
        let ordered = session.runningAgents + session.agents.filter { !$0.isRunning }.sorted { ($0.endedAt ?? 0) > ($1.endedAt ?? 0) }
        let shown = ordered.prefix(isDetailed ? 12 : 4)
        return VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(shown), id: \.id) { agent in
                AgentLine(agent: agent, now: now, lastActivity: agentActivity[agent.id], model: agentModels[agent.id] ?? agent.model)
            }
            if ordered.count > shown.count {
                Text("+\(ordered.count - shown.count) more agents").font(.system(size: 10)).foregroundStyle(Palette.ink3)
            }
        }
        .padding(.top, 2)
    }

    private func top(_ counts: [String: Int], _ limit: Int) -> String {
        counts.sorted { $0.value > $1.value }.prefix(limit).map { "\($0.key) \($0.value)" }.joined(separator: " · ")
    }

    private func label(_ tool: ToolNow) -> String {
        tool.server.map { "\($0) · \(tool.shortName)" } ?? tool.name
    }

    /// Everything else the session's state knows, as label and value rows.
    private var details: some View {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var rows: [(String, String)] = [
            ("Folder", session.cwd.replacingOccurrences(of: home, with: "~")),
            ("Runs in", session.isCursorAgent ? "Cursor's own agent" : "Claude Code · \(AppInfo.of(session.appBundleId)?.name ?? session.entrypoint ?? "terminal")"),
            ("Model", session.model.map { "\(modelName($0)) · \($0)" } ?? "—"),
            ("Session", "started \(elapsed(now - session.startedAt)) ago · \(session.toolCount) tool calls"),
        ]
        if session.phase == .working, let turn = session.turnStartedAt {
            rows.append(("This turn", "running \(elapsed(now - turn))"))
        }
        if let usage, !usage.isEmpty {
            rows.append(("Tokens", "\(compactTokens(usage.total)) · in \(compactTokens(usage.input)) · out \(compactTokens(usage.output)) · cache write \(compactTokens(usage.cacheWrite)) · cache read \(compactTokens(usage.cacheRead))"))
            var cost = "≈\(money(usage.cost))"
            if let agentUsage, !agentUsage.isEmpty { cost += " · subagents \(money(agentUsage.cost))" }
            rows.append(("Cost", cost))
        } else if session.isCursorAgent {
            rows.append(("Tokens", "not reported by Cursor"))
        }
        if let took = session.lastTurnSeconds { rows.append(("Last turn", "took \(elapsed(took))")) }
        if let last = session.lastTool { rows.append(("Last tool", "\(label(last)) · \(elapsed(now - last.since)) ago")) }
        let finished = session.agents.filter { !$0.isRunning }
        if !session.agents.isEmpty {
            rows.append(("Agents", "\(session.runningAgents.count) running · \(finished.filter { $0.outcome == .done }.count) done · \(finished.filter { $0.outcome == .failed }.count) failed · \(finished.filter { $0.outcome == .stopped }.count) stopped"))
        }
        if !session.mcp.isEmpty { rows.append(("MCP", top(session.mcp, 12))) }
        if session.backgroundTasks > 0 { rows.append(("Background", "\(session.backgroundTasks) tasks running")) }
        return VStack(alignment: .leading, spacing: 3) {
            ForEach(rows, id: \.0) { row in
                HStack(alignment: .top, spacing: 8) {
                    Text(row.0).font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.ink3).frame(width: 62, alignment: .leading)
                    Text(row.1).font(.system(size: 10)).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.inset))
        .padding(.top, 2)
    }
}

/// One subagent: what it is doing or how it ended, with its own clock that stops when it does.
private struct AgentLine: View {
    var agent: AgentNow
    var now: Double
    var lastActivity: Double?
    var model: String?
    /// A running agent that has not written for this long is flagged as quiet.
    private let quietAfter: Double = 90

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            icon.frame(width: 12, height: 12).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(agent.type).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.ink.opacity(agent.isRunning ? 0.92 : 0.6))
                    if let description = agent.description {
                        Text(description).font(.system(size: 11)).foregroundStyle(Palette.ink2).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Text(elapsed((agent.endedAt ?? now) - agent.startedAt))
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(agent.isRunning ? Palette.claude : Palette.ink3)
                }
                Text(detail).font(.system(size: 10)).foregroundStyle(detailColor).lineLimit(1)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.subcard.opacity(agent.isRunning ? 1 : 0.5)))
    }

    @ViewBuilder private var icon: some View {
        switch agent.outcome {
        case nil: Spinner(size: 10)
        case .done: Image(systemName: "checkmark.circle.fill").resizable().foregroundStyle(Palette.done)
        case .failed: Image(systemName: "xmark.circle.fill").resizable().foregroundStyle(Palette.failed)
        case .stopped: Image(systemName: "stop.circle.fill").resizable().foregroundStyle(Palette.waiting)
        }
    }

    private var isQuiet: Bool {
        guard agent.isRunning, agent.current == nil, let lastActivity else { return false }
        return now - lastActivity > quietAfter
    }

    private var detail: String {
        var parts: [String] = []
        if let tool = agent.current {
            parts.append("▸ \(label(tool)) \(elapsed(now - tool.since))")
        } else if isQuiet, let lastActivity {
            parts.append("quiet for \(elapsed(now - lastActivity))")
        } else if agent.isRunning {
            parts.append("thinking…")
        } else {
            parts.append(agent.outcome == .failed ? "failed" : agent.outcome == .stopped ? "stopped" : "done")
        }
        parts.append(agent.toolCount == 1 ? "1 tool" : "\(agent.toolCount) tools")
        if !agent.mcp.isEmpty {
            parts.append(agent.mcp.sorted { $0.value > $1.value }.prefix(2).map { "\($0.key) \($0.value)" }.joined(separator: " "))
        }
        if agent.current == nil, let last = agent.lastTool { parts.append("last \(label(last))") }
        if let model { parts.append(modelName(model)) }
        if agent.isBackground == true { parts.append("background") }
        return parts.joined(separator: " · ")
    }

    private var detailColor: Color {
        if agent.outcome == .failed { return Palette.failed }
        if isQuiet { return Palette.waiting.opacity(0.9) }
        return Palette.ink3
    }

    private func label(_ tool: ToolNow) -> String {
        tool.server.map { "\($0) · \(tool.shortName)" } ?? tool.name
    }
}

private struct ToolLine: View {
    var tool: ToolNow
    var now: Double

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(tool.server == nil ? Palette.claude : Palette.mcp).frame(width: 6, height: 6)
            Text(tool.server.map { "\($0) · \(tool.shortName)" } ?? tool.name)
                .font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.ink.opacity(0.88)).lineLimit(1)
            Text(elapsed(now - tool.since)).font(.system(size: 11).monospacedDigit()).foregroundStyle(Palette.ink3)
        }
    }
}

/// A row's state at a glance: a session's phase, or a build's.
struct StatusChip: View {
    enum Kind: Equatable {
        case working(since: Double), waiting, idle
        case queued, running(since: Double), failed, passed, canceled
        /// Waiting at a manual step, or for a deployment lock; with how long when it is long.
        case paused(age: String?), held(age: String?)
    }

    var kind: Kind
    var now: Double

    init(kind: Kind, now: Double) {
        self.kind = kind
        self.now = now
    }

    init(session: SessionState, now: Double) {
        switch session.phase {
        case .working: kind = .working(since: session.turnStartedAt ?? session.updatedAt)
        case .waiting: kind = .waiting
        case .idle: kind = .idle
        }
        self.now = now
    }

    var body: some View {
        HStack(spacing: 5) {
            switch kind {
            case .working(let since), .running(let since):
                Spinner(size: 9)
                Text(elapsed(now - since))
                    .font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(Palette.claude)
            case .waiting:
                Text("Needs you").font(.system(size: 11, weight: .bold)).foregroundStyle(.black)
            case .idle:
                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Palette.done)
                Text("Idle").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.ink2)
            case .queued:
                Image(systemName: "clock").font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.ink2)
                Text("Queued").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.ink2)
            case .paused(let age), .held(let age):
                Image(systemName: kind == .paused(age: age) ? "pause.fill" : "lock.fill").font(.system(size: 8, weight: .bold)).foregroundStyle(Palette.waiting)
                Text((kind == .paused(age: age) ? "Paused" : "Waiting") + (age.map { " · \($0)" } ?? ""))
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.waiting)
            case .failed:
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Palette.failed)
                Text("Failed").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.failed)
            case .passed:
                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Palette.done)
                Text("Done").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.ink2)
            case .canceled:
                Image(systemName: "stop.fill").font(.system(size: 8, weight: .bold)).foregroundStyle(Palette.ink3)
                Text("Canceled").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.ink3)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(kind == .waiting ? Palette.waitingHue : kind == .failed ? Palette.failedHue.opacity(0.14) : Palette.chip))
    }
}
