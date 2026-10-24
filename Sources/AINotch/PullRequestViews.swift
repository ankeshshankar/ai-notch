import AppKit
import NotchCore
import SwiftUI

// Pull requests on screen: the rows that need something (two columns: under Pipelines on the
// right), the PRs chip and its hover card, the one-line summary (one column), and the PRs panel
// with every open pull request, Mine | To review. The data is ReviewStore's.

/// "2 mine · 1 to review · 3 quiet".
@MainActor
private func countsText(_ reviews: ReviewStore) -> String {
    var parts = ["\(reviews.mine.count) mine", "\(reviews.toReview.count) to review"]
    if reviews.quietCount > 0 { parts.append("\(reviews.quietCount) quiet") }
    return parts.joined(separator: " · ")
}

/// A pull request's mark: Bitbucket's blue with the pull-request arrows.
struct PullRequestMark: View {
    var size: CGFloat = 24

    var body: some View {
        RoundedRectangle(cornerRadius: size / 4, style: .continuous)
            .fill(LinearGradient(colors: [Color(red: 0.0, green: 0.32, blue: 0.80), Palette.bitbucketHue], startPoint: .bottomLeading, endPoint: .topTrailing))
            .overlay(Image(systemName: "arrow.triangle.pull").font(.system(size: size * 0.46, weight: .semibold)).foregroundStyle(.white))
            .frame(width: size, height: size)
    }
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
                        Text("build failed").font(.system(size: 10.5, weight: .medium)).foregroundStyle(Palette.failed)
                    }
                }
                .fixedSize()
                .help("Build: \(build.state.rawValue)")
            }
            if pr.isDraft {
                Text("Draft").font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.ink3)
            }
        }
        .lineLimit(1)
    }

    private func glyph(_ icon: String, _ text: String, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 8.5, weight: .bold))
            Text(text).font(.system(size: 10.5, weight: .medium).monospacedDigit())
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
private struct PRMenu: View {
    var pr: PullRequest
    @ObservedObject var reviews: ReviewStore
    var open: () -> Void

    var body: some View {
        Button(reviews.isMuted(pr) ? "Unmute this PR" : "Mute this PR") { reviews.toggleMute(pr) }
        Button("Mark seen") { reviews.markRowSeen(pr) }
        Divider()
        Button("Open on bitbucket.org", action: open)
    }
}

/// One pull request that needs something, inline: repo #id and the title on one line, the glyphs
/// under it. A click opens it on the web.
struct PRRowButton: View {
    var pr: PullRequest
    @ObservedObject var reviews: ReviewStore
    var controller: NotchController

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 10) {
                PullRequestMark()
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("\(pr.ref.repo) #\(pr.ref.id)").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.ink2)
                            .lineLimit(1).fixedSize()
                        Text(pr.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.ink)
                            .lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                    PRStatusGlyphs(pr: pr)
                }
            }
            .rowCard()
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(RowButtonStyle())
        .help("Open on bitbucket.org")
        .contextMenu { PRMenu(pr: pr, reviews: reviews, open: open) }
    }

    private func open() {
        guard let url = pr.url else { return }
        controller.collapse()
        NSWorkspace.shared.open(url)
    }
}

/// The rows that need something, most urgent first; `+N more` opens the panel. With `header`,
/// a small title and the counts above them (under Pipelines in the right column).
struct PullRequestsBlock: View {
    @ObservedObject var reviews: ReviewStore
    var controller: NotchController
    var limit: Int
    var header: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if header {
                HStack(spacing: 6) {
                    Text("Pull requests").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.ink)
                    Spacer(minLength: 4)
                    Text(countsText(reviews)).font(.system(size: 11)).foregroundStyle(Palette.ink2).lineLimit(1)
                }
                .padding(.top, 4)
            }
            ForEach(reviews.attention.prefix(max(1, limit))) { pr in
                PRRowButton(pr: pr, reviews: reviews, controller: controller)
            }
            if reviews.attention.count > max(1, limit) {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { controller.openPanel = NotchController.pullRequestsPanel }
                } label: {
                    Text("+\(reviews.attention.count - max(1, limit)) more").font(.system(size: 11)).foregroundStyle(Palette.ink3)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// The right column's header when it holds only pull requests: the title, the counts, the chip.
struct PullRequestsHeader: View {
    @ObservedObject var reviews: ReviewStore
    @ObservedObject var controller: NotchController

    var body: some View {
        HStack(spacing: 6) {
            Text("Pull requests").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink)
            Spacer(minLength: 4)
            Text(countsText(reviews)).font(.system(size: 11)).foregroundStyle(Palette.ink2).lineLimit(1)
            PRsChip(reviews: reviews, controller: controller, hover: controller.hover)
        }
    }
}

/// The header's PRs chip: opens the PRs panel; hover shows the counts, or why nothing is read
/// (grey, never red).
struct PRsChip: View {
    @ObservedObject var reviews: ReviewStore
    @ObservedObject var controller: NotchController
    @ObservedObject var hover: HoverHub
    private static let zone = "prs-chip"
    /// `--preview --prs-hover`: the card stays open, for a screenshot.
    static let cardPinned = CommandLine.arguments.contains("--preview") && CommandLine.arguments.contains("--prs-hover")
    @State private var chipHeight: CGFloat = 18

    var body: some View {
        let isOpen = controller.openPanel == NotchController.pullRequestsPanel
        let quiet = reviews.isQuietSetup
        let isHovered = hover.hovered == Self.zone || PRsChip.cardPinned
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                controller.openPanel = isOpen ? nil : NotchController.pullRequestsPanel
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.pull").font(.system(size: 9, weight: .semibold))
                Text("PRs").font(.system(size: 10, weight: .semibold))
                if !quiet, !reviews.attention.isEmpty {
                    Text("\(reviews.attention.count)").font(.system(size: 9.5, weight: .bold).monospacedDigit())
                        .foregroundStyle(isOpen ? Palette.done : Palette.onDone)
                        .padding(.horizontal, 4).padding(.vertical, 0.5)
                        .background(Capsule().fill(isOpen ? Palette.onDone : Palette.bitbucket))
                }
            }
            .foregroundStyle(isOpen ? Palette.onDone : quiet ? Palette.ink3 : Palette.ink2)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(isOpen ? Palette.done : Palette.chip))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { frame in
            hover.zones[Self.zone] = frame
            if chipHeight != frame.height { chipHeight = frame.height }
        }
        .onDisappear { hover.zones[Self.zone] = nil }
        // The card hangs under the chip, over the rows, without moving the layout.
        .overlay(alignment: .topTrailing) {
            if isHovered {
                VStack(alignment: .trailing, spacing: 0) {
                    Color.clear.frame(width: 1, height: chipHeight + 6)
                    PRsCard(reviews: reviews)
                }
                .fixedSize()
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}

/// What the PRs chip's hover shows.
private struct PRsCard: View {
    @ObservedObject var reviews: ReviewStore

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let status = reviews.status {
                Text("Pull requests · \(status.text)").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.ink2)
                Text(status.help).font(.system(size: 10)).foregroundStyle(Palette.ink3).fixedSize(horizontal: false, vertical: true)
                if status.isSetup {
                    Text("Setup → Builds has the steps; a new token is picked up on Check Again or when the notch opens.")
                        .font(.system(size: 10)).foregroundStyle(Palette.ink3).fixedSize(horizontal: false, vertical: true)
                }
                if !reviews.requestSummary.isEmpty {
                    Text("Requests: \(reviews.requestSummary)").font(.system(size: 10)).foregroundStyle(Palette.ink3)
                }
            } else {
                Text("Pull requests · \(countsText(reviews))").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.ink)
                Text(reviews.attention.isEmpty ? "Nothing needs you now." : "\(reviews.attention.count) need\(reviews.attention.count == 1 ? "s" : "") you.")
                    .font(.system(size: 10)).foregroundStyle(Palette.ink2)
                if reviews.updatedAt > 0 {
                    Text("Read \(ago(Date().timeIntervalSince1970 - reviews.updatedAt)) · \(reviews.requestSummary)")
                        .font(.system(size: 10)).foregroundStyle(Palette.ink3).fixedSize(horizontal: false, vertical: true)
                }
                Text("Click for all of them.").font(.system(size: 10)).foregroundStyle(Palette.ink3)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(width: 290, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.card))
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.track, lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
    }
}

/// One column: a line under Pipelines that opens the PRs panel.
struct PullRequestsSummaryLine: View {
    @ObservedObject var reviews: ReviewStore
    var controller: NotchController
    var isOpen: Bool

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                controller.openPanel = isOpen ? nil : NotchController.pullRequestsPanel
            }
        } label: {
            HStack(spacing: 8) {
                PullRequestMark(size: 18)
                Text("Pull requests").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.ink)
                if !reviews.attention.isEmpty {
                    Text("\(reviews.attention.count) need\(reviews.attention.count == 1 ? "s" : "") you")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.waiting).lineLimit(1).fixedSize()
                }
                Text(countsText(reviews)).font(.system(size: 11)).foregroundStyle(Palette.ink2).lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: isOpen ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Palette.ink3)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.card))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(RowButtonStyle())
    }
}

/// Every open pull request, Mine | To review, across the full width like Usage. A row opens on
/// the web; Details shows its branches, reviews, tasks and build, and reads its merge checks once.
struct PullRequestsPanel: View {
    @ObservedObject var reviews: ReviewStore
    var controller: NotchController
    var now: Double
    var isWide: Bool
    @State private var detailId: String?
    @State private var merge: [String: MergeState] = [:]

    enum MergeState: Equatable { case loading, loaded(PRMergeability), unknown }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Pull requests").font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.bitbucket)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Palette.bitbucketHue.opacity(0.16)))
                InfoMark(text: about)
                if let status = reviews.status {
                    Text(status.text).font(.system(size: 10)).foregroundStyle(Palette.ink3).lineLimit(1)
                    InfoMark(text: status.help)
                } else if reviews.updatedAt > 0 {
                    Text("read \(ago(now - reviews.updatedAt))").font(.system(size: 10)).foregroundStyle(Palette.ink3)
                }
                Spacer()
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
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.panel))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
    }

    private var about: String {
        "Your open pull requests and the ones waiting for your review, in the repositories of bitbucket in \(BuildsConfig.displayPath). Mine every 2 minutes, review lists every 10 (20 while a pipeline of yours runs), details only for what changed, merge checks only when you open Details. \(reviews.requestSummary.isEmpty ? "" : reviews.requestSummary + ".") Right-click a row to mute it or mark it seen. Read only: nothing is approved, merged or commented from here."
    }

    private func group(_ title: String, _ prs: [PullRequest]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(title) · \(prs.count)").font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.ink3)
            if prs.isEmpty {
                Text(reviews.status == nil ? "None open" : "—").font(.system(size: 11)).foregroundStyle(Palette.ink3)
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
            NSWorkspace.shared.open(url)
        }
        return ZStack(alignment: .bottomTrailing) {
            Button(action: open) {
                PRPanelRowView(pr: pr, now: now, isMuted: reviews.isMuted(pr), isDetailed: isOpen, merge: merge[pr.id])
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(RowButtonStyle())
            .help("Open on bitbucket.org")
            .contextMenu { PRMenu(pr: pr, reviews: reviews, open: open) }

            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { detailId = isOpen ? nil : pr.id }
                if !isOpen, merge[pr.id] == nil || merge[pr.id] == .unknown { loadMerge(pr) }
            } label: {
                HStack(spacing: 3) {
                    Text(isOpen ? "Less" : "Details").font(.system(size: 10, weight: .medium))
                    Image(systemName: isOpen ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold))
                }
                .foregroundStyle(Palette.ink2)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(Palette.chip))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(6)
        }
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
private struct PRPanelRowView: View {
    var pr: PullRequest
    var now: Double
    var isMuted: Bool
    var isDetailed: Bool
    var merge: PullRequestsPanel.MergeState?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text("\(pr.ref.repo) #\(pr.ref.id)").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Palette.ink2)
                    .lineLimit(1).fixedSize()
                Text(pr.title).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.ink)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
                if isMuted {
                    Image(systemName: "bell.slash").font(.system(size: 9)).foregroundStyle(Palette.ink3).help("Muted")
                }
            }
            HStack(spacing: 6) {
                PRStatusGlyphs(pr: pr)
                if pr.updatedAt > 0 {
                    Text(ago(now - pr.updatedAt)).font(.system(size: 10)).foregroundStyle(Palette.ink3).lineLimit(1).fixedSize()
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
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(pr.needsSomething && !isMuted ? Palette.card : Palette.card.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
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
                    Text(row.0).font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.ink3).frame(width: 52, alignment: .leading)
                    Text(row.1).font(.system(size: 10)).foregroundStyle(row.2).fixedSize(horizontal: false, vertical: true)
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

/// The line along a session row's bottom: "PR #123 · build failed", which opens the pull request,
/// and "Send to agent" when there is feedback to act on. Sending only reads the pull request and
/// hands text over; nothing is approved, merged or commented from here.
struct SessionPRLine: View {
    @ObservedObject var links: SessionPRStore
    var session: SessionState
    var pr: PullRequest

    var body: some View {
        let tone = PRLine.tone(pr)
        let color: Color = tone == .bad ? Palette.failed : tone == .attention ? Palette.waiting : tone == .good ? Palette.done : Palette.ink3
        HStack(spacing: 6) {
            Button {
                if let url = pr.url { NSWorkspace.shared.open(url) }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.pull").font(.system(size: 8, weight: .semibold))
                    Text(PRLine.text(pr)).font(.system(size: 10, weight: .medium)).lineLimit(1).truncationMode(.tail)
                }
                .foregroundStyle(color)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Capsule().fill(Palette.chip))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("\(pr.title). Opens the pull request in the browser.")
            if let notice = links.notices[session.id] {
                Text(notice).font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.done).lineLimit(1).truncationMode(.tail)
            } else if !pr.feedbackKinds.isEmpty {
                Button { links.send(session) } label: {
                    HStack(spacing: 3) {
                        Image(systemName: links.sending.contains(session.id) ? "ellipsis" : "paperplane").font(.system(size: 8, weight: .semibold))
                        Text("Send to agent").font(.system(size: 10, weight: .medium)).lineLimit(1)
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
