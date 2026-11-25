import AppKit
import NotchCore
import ReviewCore
import SwiftUI

// Pull requests on screen: one list, the PRs section with every open pull request, Mine | To
// review (plus the Board, in BoardViews). The PRs chip and its hover card open it, and a
// session's link jumps to its row. The data is ReviewStore's.

/// "2 mine · 1 to review · 3 quiet".
@MainActor
private func countsText(_ reviews: ReviewStore) -> String {
    var parts = ["\(reviews.mine.count) mine", "\(reviews.toReview.count) to review"]
    if reviews.quietCount > 0 { parts.append("\(reviews.quietCount) quiet") }
    return parts.joined(separator: " · ")
}

/// A row's state at a glance: review requested (and by whom), approvals x/y, changes requested,
/// new comments, the build as a dot, draft.
struct PRStatusGlyphs: View {
    var pr: PullRequest

    var body: some View {
        HStack(spacing: 8) {
            if pr.needs.contains(.reviewRequested) {
                glyph("hourglass", "Review" + (pr.requester.map { " · \($0.name)" } ?? ""), Palette.waiting)
                    .help("\(pr.requester?.name ?? "The author") asked for your review")
            }
            if pr.approvalsNeeded > 0 {
                glyph("checkmark", "\(pr.approvals)/\(pr.approvalsNeeded)", pr.approvals > 0 ? Palette.done : Palette.ink3)
                    .help("Approvals: \(pr.approvals) of \(pr.approvalsNeeded)")
            }
            if !pr.changesRequestedBy.isEmpty {
                glyph("xmark", pr.changesRequestedBy.count == 1 ? pr.changesRequestedBy[0] : "\(pr.changesRequestedBy.count)", Palette.waiting)
                    .help("Changes requested by " + pr.changesRequestedBy.joined(separator: ", "))
            }
            if pr.newComments > 0 {
                glyph("bubble.left.fill", "\(pr.newComments) new", Palette.bitbucket)
                    .help("\(pr.newComments) new comment\(pr.newComments == 1 ? "" : "s") since you last looked")
            }
            if let build = pr.build {
                HStack(spacing: 3) {
                    Circle().fill(Self.color(build.state)).frame(width: 6, height: 6)
                    if build.state == .failed {
                        Text("build failed").font(Typo.label(.medium)).foregroundStyle(Palette.failed)
                    }
                }
                .fixedSize()
                .help("Build: \(build.state.rawValue)")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Build \(build.state.rawValue)")
            }
            if pr.isDraft {
                Text("Draft").font(Typo.label(.medium)).foregroundStyle(Palette.ink3)
            }
        }
        .lineLimit(1)
    }

    private func glyph(_ icon: String, _ text: String, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(Typo.micro(.bold)).decorative()
            Text(text).font(Typo.label(.medium).monospacedDigit())
        }
        .foregroundStyle(color)
        .fixedSize()
    }

    static func color(_ state: BuildState) -> Color {
        switch state {
        case .failed: return Palette.failed
        case .running, .queued: return Palette.claude
        case .succeeded: return Palette.done
        default: return Palette.ink3
        }
    }
}

/// The rows' right-click menu: mute, mark seen, open.
struct PRMenu: View {
    var pr: PullRequest
    @ObservedObject var reviews: ReviewStore
    var open: () -> Void

    var body: some View {
        Button(reviews.isMuted(pr) ? "Unmute this PR" : "Mute this PR") { reviews.toggleMute(pr) }
        Button("Mark seen") { reviews.markRowSeen(pr) }
        if PRReviewStore.supports(pr) {
            Divider()
            Button("Open review window") { PRReviewWindowController.shared.show(pr.id) }
            let auto = reviews.autoReview
            let phase = auto.record(for: pr)?.record.phase
            if phase == .queued || phase == .reviewing {
                Button("Cancel review") { auto.cancel(pr) }
            } else {
                Button(phase == nil ? "Review now" : "Re-review") { auto.reviewNow(pr) }
            }
            if let found = auto.record(for: pr), let url = auto.reportURL(found.record) {
                Button("View report") { NSWorkspace.shared.open(url) }
            }
        }
        Divider()
        Button("Open on bitbucket.org", action: open)
    }
}

/// The footer's PRs chip: opens the PRs panel; hover shows the counts, or why nothing is read
/// (grey, never red).
struct PRsChip: View {
    @ObservedObject var reviews: ReviewStore
    @ObservedObject var controller: NotchController
    @ObservedObject var hover: HoverHub
    static let zone = "prs-chip"
    /// `--preview --prs-hover`: the card stays open, for a screenshot.
    static let cardPinned = CommandLine.arguments.contains("--preview") && CommandLine.arguments.contains("--prs-hover")
    @State private var chipHeight: CGFloat = 18

    var body: some View {
        let isOpen = controller.openPanel == NotchController.pullRequestsPanel
        let quiet = reviews.isQuietSetup
        let isHovered = hover.hovered == Self.zone || PRsChip.cardPinned
        Button {
            withAnimation(Motion.slide) {
                controller.openPanel = isOpen ? nil : NotchController.pullRequestsPanel
            }
        } label: {
            ViewThatFits(in: .horizontal) {
                label(full: true, isOpen: isOpen, quiet: quiet)
                label(full: false, isOpen: isOpen, quiet: quiet)
            }
            .foregroundStyle(isOpen ? Palette.onDone : quiet ? Palette.ink3 : Palette.ink2)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(isOpen ? Palette.done : Palette.chip))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .ax("Pull requests", value: quiet || reviews.attention.isEmpty ? "none need you" : "\(reviews.attention.count) need you", selected: isOpen)
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { frame in
            hover.zones[Self.zone] = frame
            if chipHeight != frame.height { chipHeight = frame.height }
        }
        .onDisappear { hover.zones[Self.zone] = nil }
        // The card floats above the chip, over the rows, without moving the layout.
        .overlay(alignment: .bottomLeading) {
            if isHovered {
                VStack(alignment: .leading, spacing: 0) {
                    PRsCard(reviews: reviews)
                    Color.clear.frame(width: 1, height: chipHeight + 6)
                }
                .fixedSize()
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .animation(Motion.ease(0.12), value: isHovered)
    }
}

extension PRsChip {
    /// Compact: the mark and how many need you. Full: and "PRs".
    fileprivate func label(full: Bool, isOpen: Bool, quiet: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.triangle.pull").font(Typo.caption(.semibold)).decorative()
            if full { Text("PRs").font(Typo.label(.semibold)) }
            if !quiet, !reviews.attention.isEmpty {
                Text("\(reviews.attention.count)").font(Typo.caption(.bold).monospacedDigit())
                    .foregroundStyle(isOpen ? Palette.done : Palette.onDone)
                    .padding(.horizontal, 4).padding(.vertical, 0.5)
                    .background(Capsule().fill(isOpen ? Palette.onDone : Palette.bitbucket))
            }
            if !quiet, reviews.waitingCount > 0 {
                Text("\(reviews.waitingCount)").font(Typo.caption(.bold).monospacedDigit())
                    .foregroundStyle(isOpen ? Palette.done : Palette.onDone)
                    .padding(.horizontal, 4).padding(.vertical, 0.5)
                    .background(Capsule().fill(isOpen ? Palette.onDone : Palette.done))
                    .help("Reviews done, waiting for your call")
            }
        }
        .lineLimit(1).fixedSize()
    }
}

/// What the PRs chip's hover shows.
private struct PRsCard: View {
    @ObservedObject var reviews: ReviewStore

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let status = reviews.status {
                Text("Pull requests · \(status.text)").font(Typo.body(.semibold)).foregroundStyle(Palette.ink2)
                Text(status.help).font(Typo.label()).foregroundStyle(Palette.ink3).fixedSize(horizontal: false, vertical: true)
                if !status.isSetup {
                    Text(reviews.updatedAt > 0 ? "Last read \(ago(Date().timeIntervalSince1970 - reviews.updatedAt))" : "Not read yet")
                        .font(Typo.label()).foregroundStyle(Palette.ink3)
                }
                if status.isSetup {
                    Text("Setup → Builds has the steps; a new token is picked up on Check Again or when the notch opens.")
                        .font(Typo.label()).foregroundStyle(Palette.ink3).fixedSize(horizontal: false, vertical: true)
                }
                if !reviews.requestSummary.isEmpty {
                    Text("Requests: \(reviews.requestSummary)").font(Typo.label()).foregroundStyle(Palette.ink3)
                }
            } else {
                Text("Pull requests · \(countsText(reviews))").font(Typo.body(.semibold)).foregroundStyle(Palette.ink)
                Text(reviews.attention.isEmpty ? "Nothing needs you now." : "\(reviews.attention.count) need\(reviews.attention.count == 1 ? "s" : "") you.")
                    .font(Typo.label()).foregroundStyle(Palette.ink2)
                if reviews.updatedAt > 0 {
                    Text("Read \(ago(Date().timeIntervalSince1970 - reviews.updatedAt)) · \(reviews.requestSummary)")
                        .font(Typo.label()).foregroundStyle(Palette.ink3).fixedSize(horizontal: false, vertical: true)
                }
                Text("Click for all of them.").font(Typo.label()).foregroundStyle(Palette.ink3)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(width: 290, alignment: .leading)
        .floatingCard(radius: 10)
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.track, lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
    }
}

/// The main view's right column: the pull requests that need you, as a short slice of the same
/// rows the PRs panel lists (one row component); the rest is behind "+N more", which opens the panel.
struct PullRequestsNeedYou: View {
    @ObservedObject var reviews: ReviewStore
    var controller: NotchController
    var now: Double
    var limit: Int
    /// Its own title line, when pipelines share the column.
    var header: Bool

    var body: some View {
        let shown = Array(reviews.attention.prefix(max(1, limit)))
        VStack(alignment: .leading, spacing: 8) {
            if header {
                HStack(spacing: 6) {
                    Text("Pull requests").font(Typo.title(.semibold)).foregroundStyle(Palette.ink)
                    Spacer(minLength: 4)
                    Text("\(reviews.attention.count) need\(reviews.attention.count == 1 ? "s" : "") you")
                        .font(Typo.label(.medium)).foregroundStyle(Palette.waiting).lineLimit(1)
                }
                .padding(.top, 4)
            }
            ForEach(shown) { pr in
                let open = {
                    guard let url = pr.url else { return }
                    controller.collapse()
                    SafeLink.open(url, for: .bitbucket)
                }
                Button {
                    if PRReviewStore.supports(pr) {
                        controller.collapse()
                        PRReviewWindowController.shared.show(pr.id)
                    } else {
                        open()
                    }
                } label: {
                    PRPanelRowView(pr: pr, now: now, isMuted: reviews.isMuted(pr), isDetailed: false, merge: nil, review: reviews.autoReview)
                        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(RowButtonStyle())
                .help(PRReviewStore.supports(pr) ? "Open the review window" : "Open on bitbucket.org")
                .contextMenu { PRMenu(pr: pr, reviews: reviews, open: open) }
            }
            if reviews.attention.count > shown.count {
                Button {
                    withAnimation(Motion.slide) { controller.openPanel = NotchController.pullRequestsPanel }
                } label: {
                    Text("+\(reviews.attention.count - shown.count) more").font(Typo.label()).foregroundStyle(Palette.ink3).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Every open pull request, Mine | To review, across the full width like Usage. A row opens on
/// the web (a pull request I review opens its review window); Details shows its branches, reviews, tasks and build, and reads its merge checks once.
struct PullRequestsPanel: View {
    @ObservedObject var reviews: ReviewStore
    @ObservedObject var controller: NotchController
    var now: Double
    var isWide: Bool
    @State private var detailId: String?
    @State private var merge: [String: MergeState] = [:]
    /// The row a session's link asked for: ringed for a moment.
    @State private var highlighted: String?

    enum MergeState: Equatable { case loading, loaded(PRMergeability), unknown }

    var body: some View {
        ScrollViewReader { proxy in
            content
                .onAppear { focus(proxy) }
                .onChange(of: controller.focusedPullRequest) { focus(proxy) }
        }
    }

    /// A session's link (or the Board's) asked for this pull request: open its details, scroll to it, ring it.
    private func focus(_ proxy: ScrollViewProxy) {
        guard let id = controller.focusedPullRequest else { return }
        controller.focusedPullRequest = nil
        guard let pr = (reviews.mine + reviews.toReview).first(where: { $0.id == id }) else { return }
        withAnimation(Motion.slide) { detailId = id; highlighted = id }
        if merge[id] == nil || merge[id] == .unknown { loadMerge(pr) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { withAnimation(Motion.slide) { proxy.scrollTo(id, anchor: .center) } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { if highlighted == id { withAnimation(Motion.ease(0.3)) { highlighted = nil } } }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Pull requests").font(Typo.label(.semibold)).foregroundStyle(Palette.bitbucket)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Palette.bitbucketHue.opacity(0.16)))
                InfoMark(text: about)
                if let status = reviews.status {
                    Text(status.text).font(Typo.label()).foregroundStyle(Palette.ink3).lineLimit(1)
                    InfoMark(text: status.help)
                } else if reviews.updatedAt > 0 {
                    Text("read \(ago(now - reviews.updatedAt))").font(Typo.label()).foregroundStyle(Palette.ink3)
                }
                Spacer()
                if reviews.status == nil, !reviews.attention.isEmpty {
                    Text("\(reviews.attention.count) need\(reviews.attention.count == 1 ? "s" : "") you")
                        .font(Typo.label(.medium)).foregroundStyle(Palette.waiting)
                }
            }
            if isWide {
                HStack(alignment: .top, spacing: 12) {
                    group("Mine", reviews.mine)
                    group("To review", reviews.toReview)
                }
            } else {
                group("Mine", reviews.mine)
                group("To review", reviews.toReview)
            }
        }
        .padding(10)
        .panelCard()
    }

    private var about: String {
        "Your open pull requests and the ones waiting for your review, in the repositories of bitbucket in \(BuildsConfig.displayPath). Mine every 2 minutes, review lists every 10 (20 while a pipeline of yours runs), details only for what changed, merge checks only when you open Details. \(reviews.requestSummary.isEmpty ? "" : reviews.requestSummary + ".") Right-click a row to mute it or mark it seen. Pull requests you review are reviewed automatically (Claude, read only); the verdict shows on the row; click it to open the review window, with the findings as comments to pick from, a chat about the review and Approve (only when it is safe, after a click and a confirm). Nothing is merged, and nothing is commented without your click and confirm."
    }

    private func group(_ title: String, _ prs: [PullRequest]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(title) · \(prs.count)").font(Typo.caption(.semibold)).foregroundStyle(Palette.ink3)
            if prs.isEmpty {
                Text(reviews.status == nil ? "None open" : "—").font(Typo.body()).foregroundStyle(Palette.ink3)
                    .padding(.vertical, 2)
            }
            ForEach(prs) { pr in row(pr) }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func row(_ pr: PullRequest) -> some View {
        let isOpen = detailId == pr.id
        let open = {
            guard let url = pr.url else { return }
            controller.collapse()
            SafeLink.open(url, for: .bitbucket)
        }
        // A pull request I review opens its review window; the others open on Bitbucket.
        let click = {
            if PRReviewStore.supports(pr) {
                controller.collapse()
                PRReviewWindowController.shared.show(pr.id)
            } else {
                open()
            }
        }
        return VStack(alignment: .leading, spacing: 4) {
        ZStack(alignment: .bottomTrailing) {
            Button(action: click) {
                PRPanelRowView(pr: pr, now: now, isMuted: reviews.isMuted(pr), isDetailed: isOpen, merge: merge[pr.id], review: reviews.autoReview)
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(RowButtonStyle())
            .help(PRReviewStore.supports(pr) ? "Open the review window" : "Open on bitbucket.org")
            .contextMenu { PRMenu(pr: pr, reviews: reviews, open: open) }

            Button {
                withAnimation(Motion.slide) { detailId = isOpen ? nil : pr.id }
                if !isOpen, merge[pr.id] == nil || merge[pr.id] == .unknown { loadMerge(pr) }
            } label: {
                HStack(spacing: 3) {
                    Text(isOpen ? "Less" : "Details").font(Typo.label(.medium))
                    Image(systemName: isOpen ? "chevron.up" : "chevron.down").font(Typo.micro(.bold)).decorative()
                }
                .foregroundStyle(Palette.ink2)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(Palette.chip))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(6)
            .ax(isOpen ? "Hide details" : "Show details", value: pr.title)
        }
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.bitbucket, lineWidth: highlighted == pr.id ? 2 : 0).allowsHitTesting(false))
        }
        .id(pr.id)
    }

    /// Merge checks, read once when Details opens (one request).
    private func loadMerge(_ pr: PullRequest) {
        merge[pr.id] = .loading
        let id = pr.id
        Task { @MainActor in
            let result = await reviews.mergeability(for: pr)
            merge[id] = result.map { .loaded($0) } ?? .unknown
        }
    }
}

/// A row of the PRs panel: repo #id and title, the glyphs and its age; with Details, the rest.
struct PRPanelRowView: View {
    var pr: PullRequest
    var now: Double
    var isMuted: Bool
    var isDetailed: Bool
    @Environment(\.notchGlass) private var glass
    var merge: PullRequestsPanel.MergeState?
    /// The automatic review's chip on a row I review.
    var review: PRReviewStore? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text("\(pr.ref.repo) #\(pr.ref.id)").font(Typo.label(.semibold)).foregroundStyle(Palette.ink2)
                    .lineLimit(1).fixedSize()
                Text(pr.title).font(Typo.subtitle(.medium)).foregroundStyle(Palette.ink)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
                if isMuted {
                    Image(systemName: "bell.slash").font(Typo.caption()).foregroundStyle(Palette.ink3).help("Muted").accessibilityLabel("Muted")
                }
            }
            HStack(spacing: 6) {
                PRStatusGlyphs(pr: pr).layoutPriority(1)
                if let review, PRReviewStore.supports(pr) { PRReviewChip(pr: pr, store: review) }
                if pr.updatedAt > 0 {
                    Text(ago(now - pr.updatedAt)).font(Typo.label()).foregroundStyle(Palette.ink3).lineLimit(1).fixedSize()
                        .layoutPriority(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.trailing, 64)
            if isDetailed {
                details
                Color.clear.frame(height: 16)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(pr.needsSomething && !isMuted ? glass.color(Palette.card) : glass.color(Palette.card).opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(glass.color(Palette.hairline), lineWidth: 1))
    }

    private var details: some View {
        var rows: [(String, String, Color)] = []
        if pr.source != nil || pr.destination != nil {
            rows.append(("Branch", "\(pr.source ?? "—") → \(pr.destination ?? "—")", Palette.ink2))
        }
        if pr.role == .reviewing { rows.append(("Author", pr.author.name, Palette.ink2)) }
        if !pr.participants.isEmpty {
            let reviews = pr.participants.map { p -> String in
                switch p.review {
                case .approved: return "\(p.person.name) ✓"
                case .changesRequested: return "\(p.person.name) ✕"
                case .none: return p.person.name
                }
            }
            rows.append(("Reviews", reviews.joined(separator: " · "), Palette.ink2))
        }
        rows.append(("Activity", "\(pr.taskCount) open task\(pr.taskCount == 1 ? "" : "s") · \(pr.commentCount) comment\(pr.commentCount == 1 ? "" : "s")" + (pr.newComments > 0 ? " (\(pr.newComments) new)" : ""), Palette.ink2))
        if let build = pr.build { rows.append(("Build", build.state.rawValue, build.state == .failed ? Palette.failed : Palette.ink2)) }
        switch merge {
        case .loading?: rows.append(("Merge", "checking…", Palette.ink3))
        case .loaded(let checks)?:
            if checks.checks.isEmpty {
                rows.append(("Merge", "no checks reported", Palette.ink3))
            } else if checks.canMerge {
                rows.append(("Merge", "can merge", Palette.done))
            } else {
                rows.append(("Merge", "blocked: " + checks.blocking.map { Self.checkName($0.name) }.joined(separator: ", "), Palette.waiting))
            }
        case .unknown?: rows.append(("Merge", "not known (no answer)", Palette.ink3))
        case nil: break
        }
        return VStack(alignment: .leading, spacing: 3) {
            ForEach(rows, id: \.0) { row in
                HStack(alignment: .top, spacing: 8) {
                    Text(row.0).font(Typo.label(.semibold)).foregroundStyle(Palette.ink3).frame(width: 52, alignment: .leading)
                    Text(row.1).font(Typo.label()).foregroundStyle(row.2).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Palette.inset))
        .padding(.top, 3)
    }

    /// "minimum_approvals" → "minimum approvals".
    static func checkName(_ name: String) -> String { name.replacingOccurrences(of: "_", with: " ") }
}

// MARK: A session's pull request

/// The line along a session row's bottom: "PR #123 · build failed", which jumps to its row in the PRs section,
/// and "Send to agent" when there is feedback to act on. Sending only reads the pull request and
/// hands text over; nothing is approved, merged or commented from here.
struct SessionPRLine: View {
    var controller: NotchController
    @ObservedObject var links: SessionPRStore
    var session: SessionState
    var pr: PullRequest

    var body: some View {
        let tone = PRLine.tone(pr)
        let color: Color = tone == .bad ? Palette.failed : tone == .attention ? Palette.waiting : tone == .good ? Palette.done : Palette.ink3
        HStack(spacing: 6) {
            Button {
                // Jumps to the pull request's row in the PRs section; the row opens it on the web.
                withAnimation(Motion.slide) {
                    controller.focusedPullRequest = pr.id
                    controller.openPanel = NotchController.pullRequestsPanel
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.pull").font(Typo.micro(.semibold)).decorative()
                    Text(PRLine.text(pr)).font(Typo.label(.medium)).lineLimit(1).truncationMode(.tail)
                }
                .foregroundStyle(color)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Capsule().fill(Palette.chip))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("\(pr.title). Shows it in the pull requests list.")
            .ax("Pull request \(pr.ref.id)", value: PRLine.text(pr), hint: "Shows it in the pull requests list")
            if let notice = links.notices[session.id] {
                Text(notice).font(Typo.label(.medium)).foregroundStyle(Palette.done).lineLimit(1).truncationMode(.tail)
            } else if !pr.feedbackKinds.isEmpty {
                Button { links.send(session) } label: {
                    HStack(spacing: 3) {
                        Image(systemName: links.sending.contains(session.id) ? "ellipsis" : "paperplane").font(Typo.micro(.semibold)).decorative()
                        Text("Send to agent").font(Typo.label(.medium)).lineLimit(1)
                    }
                    .foregroundStyle(Palette.ink2)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(Palette.chip))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(links.sending.contains(session.id))
                .help(session.phase != .idle && AgentControls.kind(of: session) == .hooked
                      ? "Reads the failed build's log and the new comments and hands them to Claude as a note for its next step."
                      : "Reads the failed build's log and the new comments and copies them as a short brief; the session's window comes forward to paste it into.")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
