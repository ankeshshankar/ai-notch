import AppKit
import Combine
import ReviewCore
import SwiftUI

// The pull-request review window: the PRs I review on the left, the selected one on the right
// with its header and actions, the review's chat, the suggested comment cards and the composer.
// It opens from a row of the notch's PRs panel. Nothing is posted, approved or requested from
// here without a click and a confirm that says what will be sent.

@MainActor
final class PRListSource: ObservableObject {
    @Published var prs: [PullRequest] = []
}

@MainActor
final class PRReviewWindowModel: ObservableObject {
    enum Overlay: Equatable {
        case post
        case action(ReviewAction)
    }

    let store: PRReviewStore
    let list: PRListSource
    @Published var selected: String?
    @Published var overlay: Overlay?
    /// "3 new commits since the review", by pull request, once counted.
    @Published private(set) var behind: [String: String] = [:]
    private var sessions: [String: PRChatSession] = [:]

    init(store: PRReviewStore, list: PRListSource) {
        self.store = store
        self.list = list
    }

    var prs: [PullRequest] { list.prs }
    var current: PullRequest? { prs.first { $0.id == selected } ?? prs.first }

    func select(_ id: String) {
        guard selected != id else { return }
        selected = id
        overlay = nil
    }

    /// The chat of the review that counts for this pull request; none until a review finished.
    func session(for pr: PullRequest) -> PRChatSession? {
        guard let found = store.record(for: pr), found.record.phase == .done, let folder = store.folder(for: found.record) else { return nil }
        let key = pr.id + "@" + found.record.head
        if let session = sessions[key] { return session }
        let session = PRChatSession(ref: pr.ref, head: found.record.head, folder: folder)
        session.repoPath = { PRReviewStore.repoPath(pr.ref) }
        session.loadExisting()
        sessions[key] = session
        return session
    }

    /// Counts the commits since an outdated review, once.
    func loadBehind(_ pr: PullRequest) {
        guard let found = store.record(for: pr), found.outdated, let head = pr.head, behind[pr.id] == nil else { return }
        behind[pr.id] = "New commits since the review"
        let reviewed = found.record.head
        Task { @MainActor in
            guard let count = await PRReviewAPI.commitsSince(pr.ref, reviewed: reviewed, head: head) else { return }
            behind[pr.id] = count >= 100 ? "100+ new commits since the review" : "\(count) new commit\(count == 1 ? "" : "s") since the review"
        }
    }

    func forgetBehind(_ id: String) { behind[id] = nil }
}

@MainActor
final class PRReviewWindowController: NSObject, NSWindowDelegate {
    static let shared = PRReviewWindowController()
    weak var reviews: ReviewStore?
    /// A preview's window quits the app when it closes.
    var quitsOnClose = false
    private var window: NSWindow?
    private(set) var model: PRReviewWindowModel?
    private var cancellable: AnyCancellable?

    /// Opens the window on a pull request (or the first one I review).
    func show(_ id: String? = nil) {
        guard let reviews else { return }
        let model = self.model ?? makeModel(reviews)
        if let id { model.select(id) } else if model.selected == nil { model.selected = model.prs.first?.id }
        present(model)
    }

    /// A preview's window on its own fixtures.
    func show(model: PRReviewWindowModel) {
        self.model = model
        present(model)
    }

    private func makeModel(_ reviews: ReviewStore) -> PRReviewWindowModel {
        let list = PRListSource()
        list.prs = reviews.toReview.filter { PRReviewStore.supports($0) }
        cancellable = reviews.$toReview.sink { [weak list] prs in
            list?.prs = prs.filter { PRReviewStore.supports($0) }
        }
        let model = PRReviewWindowModel(store: reviews.autoReview, list: list)
        self.model = model
        return model
    }

    private func present(_ model: PRReviewWindowModel) {
        let window = self.window ?? makeWindow(model)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // No text field takes the focus (and selects its text) on open; the user clicks where to type.
        DispatchQueue.main.async { window.makeFirstResponder(nil) }
    }

    private func makeWindow(_ model: PRReviewWindowModel) -> NSWindow {
        let host = NSHostingController(rootView: PRReviewWindowView(model: model, store: model.store, list: model.list))
        host.sizingOptions = []
        let window = SetupNSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.collectionBehavior = [.fullScreenPrimary]
        window.title = "Pull request review"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 480, height: 420)
        window.delegate = self
        let screen = (NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let size = NSSize(width: min(1040, screen.width - 80), height: min(760, screen.height - 80))
        window.setContentSize(size)
        window.setFrameOrigin(NSPoint(x: (screen.midX - size.width / 2).rounded(), y: (screen.midY - size.height / 2).rounded()))
        window.setFrameAutosaveName("AINotchPRReview")
        self.window = window
        return window
    }

    /// The window's number and frame, for a preview's screenshots.
    var windowInfo: (number: Int, frame: NSRect)? { window.map { ($0.windowNumber, $0.frame) } }

    func resize(to size: NSSize) {
        guard let window else { return }
        window.setContentSize(size)
    }

    func windowWillClose(_ notification: Notification) {
        if quitsOnClose { NSApp.terminate(nil) }
        // The window's tree goes; the model (and any chat turn running) stays for the next opening.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, !window.isVisible, !window.isMiniaturized else { return }
            window.delegate = nil
            window.contentViewController = nil
            self.window = nil
        }
    }
}

// MARK: The window

struct PRReviewWindowView: View {
    @ObservedObject var model: PRReviewWindowModel
    @ObservedObject var store: PRReviewStore
    @ObservedObject var list: PRListSource

    /// Below this width the list of pull requests becomes a menu above the pane.
    static let compactWidth: CGFloat = 700

    var body: some View {
        GeometryReader { geo in
            let compact = geo.size.width < Self.compactWidth
            ZStack {
                Palette.surface.ignoresSafeArea()
                Group {
                    if list.prs.isEmpty {
                        emptyState
                    } else if compact {
                        VStack(spacing: 0) {
                            picker
                            Divider()
                            pane
                        }
                    } else {
                        HStack(spacing: 0) {
                            sidebar.frame(width: 250)
                            Divider()
                            pane
                        }
                    }
                }
                if let overlay = model.overlay, let pr = model.current {
                    PRReviewConfirm(model: model, store: store, pr: pr, overlay: overlay)
                }
            }
        }
        .frame(minWidth: 480, minHeight: 420)
        .onAppear { if model.selected == nil { model.selected = model.prs.first?.id } }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "checklist").font(Typo.figure()).foregroundStyle(Palette.ink3).decorative()
            Text("No pull requests to review").font(Typo.title(.medium)).foregroundStyle(Palette.ink2)
            Text("The ones you are asked to review show here, in repositories with a clone in builds.json.")
                .font(Typo.label()).foregroundStyle(Palette.ink3).multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var pane: some View {
        Group {
            if let pr = model.current {
                PRReviewDetail(model: model, store: store, pr: pr, session: model.session(for: pr))
                    .id(pr.id + "@" + (store.record(for: pr)?.record.head ?? "none") + ((store.record(for: pr)?.record.phase == .done) ? "done" : "wait"))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("To review · \(list.prs.count)").font(Typo.caption(.semibold)).foregroundStyle(Palette.ink3)
                .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 6)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(list.prs) { pr in
                        Button { model.select(pr.id) } label: { PRReviewSidebarRow(pr: pr, store: store, selected: pr.id == model.current?.id) }
                            .buttonStyle(.plain)
                            .ax("\(pr.ref.repo) #\(pr.ref.id)", value: pr.title, selected: pr.id == model.current?.id)
                    }
                }
                .padding(.horizontal, 8).padding(.bottom, 8)
            }
        }
        .background(Palette.panel)
    }

    private var picker: some View {
        Menu {
            ForEach(list.prs) { pr in
                Button("\(pr.ref.repo) #\(pr.ref.id) · \(pr.title)") { model.select(pr.id) }
            }
        } label: {
            HStack(spacing: 6) {
                if let pr = model.current {
                    Text("\(pr.ref.repo) #\(pr.ref.id)").font(Typo.label(.semibold)).foregroundStyle(Palette.ink2).fixedSize()
                    Text(pr.title).font(Typo.body(.medium)).foregroundStyle(Palette.ink).lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 0)
                Text("\(list.prs.count) to review").font(Typo.label()).foregroundStyle(Palette.ink3).fixedSize()
                Image(systemName: "chevron.up.chevron.down").font(Typo.micro(.bold)).foregroundStyle(Palette.ink3).decorative()
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .background(Palette.panel)
    }
}

extension PullRequest {
    /// Every reviewer with where they stand, for the header avatars and the sidebar count.
    var reviewerRows: [ReviewerRow] {
        reviewers.map { ReviewerRow(name: $0.person.name, state: $0.review == .approved ? .approved : $0.review == .changesRequested ? .changesRequested : .notYet) }
    }
}

/// A round initial with the reviewer's name and state, in the header.
struct PRReviewReviewerChip: View {
    var row: ReviewerRow

    private var color: Color {
        switch row.state {
        case .approved: return Palette.done
        case .changesRequested: return Palette.waiting
        case .notYet: return Palette.ink3
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(row.initial).font(Typo.micro(.bold)).foregroundStyle(Palette.onDone)
                .frame(width: 16, height: 16).background(Circle().fill(color)).decorative()
            Text(row.name).font(Typo.label()).foregroundStyle(Palette.ink2).lineLimit(1)
            Text(row.state.label).font(Typo.label(.medium)).foregroundStyle(color).lineLimit(1)
        }
        .fixedSize()
        .ax("Reviewer \(row.name)", value: row.state.label)
    }
}

/// The review's state in a few words, for the sidebar.
enum PRReviewBadge {
    static func short(_ record: ReviewRecord?, outdated: Bool) -> (text: String, color: Color, symbol: String) {
        guard let record else { return ("Not reviewed", Palette.ink3, "circle.dashed") }
        let older = outdated ? " · older" : ""
        switch record.phase {
        case .queued: return ("Queued", Palette.ink3, "clock")
        case .reviewing: return ("Reviewing", Palette.claude, "ellipsis")
        case .cancelled: return ("Cancelled", Palette.ink3, "slash.circle")
        case .failed: return ("Failed", Palette.failed, "exclamationmark.triangle")
        case .done:
            let approve = record.verdict == .approve
            return ((approve ? "Approve" : "Changes") + older, approve ? Palette.done : Palette.waiting, approve ? "checkmark.seal" : "xmark.seal")
        }
    }

    static func pipeline(_ pr: PullRequest) -> (text: String, color: Color) {
        guard let state = pr.build?.state else { return ("No pipeline", Palette.ink3) }
        switch state {
        case .succeeded: return ("Pipeline passed", Palette.done)
        case .failed: return ("Pipeline failed", Palette.failed)
        case .canceled: return ("Pipeline stopped", Palette.ink3)
        case .queued, .running, .paused: return ("Pipeline running", Palette.waiting)
        }
    }
}

private struct PRReviewSidebarRow: View {
    var pr: PullRequest
    @ObservedObject var store: PRReviewStore
    var selected: Bool

    var body: some View {
        let found = store.record(for: pr)
        let badge = PRReviewBadge.short(found?.record, outdated: found?.outdated ?? false)
        let pipeline = PRReviewBadge.pipeline(pr)
        let reviewers = ReviewerSummary(pr.reviewerRows)
        VStack(alignment: .leading, spacing: 3) {
            Text("\(pr.ref.repo) #\(pr.ref.id)").font(Typo.label(.semibold)).foregroundStyle(Palette.ink2).lineLimit(1).truncationMode(.tail)
            Text(pr.title).font(Typo.body(.medium)).foregroundStyle(Palette.ink).lineLimit(2).multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                HStack(spacing: 3) {
                    Image(systemName: badge.symbol).font(Typo.micro(.bold)).decorative()
                    Text(badge.text).font(Typo.label(.medium)).lineLimit(1)
                }
                .foregroundStyle(badge.color)
                Text(pipeline.text).font(Typo.label()).foregroundStyle(pipeline.color).lineLimit(1)
            }
            if !reviewers.text.isEmpty {
                HStack(spacing: 4) {
                    Text(reviewers.text).font(Typo.label()).foregroundStyle(Palette.ink3).lineLimit(1)
                    if reviewers.hasChanges {
                        Image(systemName: "xmark.circle.fill").font(Typo.micro(.bold)).foregroundStyle(Palette.waiting)
                            .help("A reviewer asked for changes").decorative()
                    }
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? Palette.card : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(selected ? Palette.bitbucket.opacity(0.6) : Color.clear, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: The selected pull request

struct PRReviewPill: View {
    var title: String
    var symbol: String? = nil
    var prominent = false
    var destructive = false
    var enabled = true
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol).font(Typo.micro(.bold)).decorative() }
                Text(title).font(Typo.label(.medium)).lineLimit(1).fixedSize()
            }
            .foregroundStyle(prominent ? Palette.onDone : destructive ? Palette.waiting : Palette.ink2)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill(prominent ? Palette.done : Palette.chip))
            .opacity(enabled ? 1 : 0.45)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .ax(title)
    }
}

struct PRReviewDetail: View {
    @ObservedObject var model: PRReviewWindowModel
    @ObservedObject var store: PRReviewStore
    var pr: PullRequest
    var session: PRChatSession?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let session {
                PRReviewTimeline(model: model, store: store, pr: pr, session: session)
            } else {
                status
            }
        }
        .onAppear {
            store.refreshWriteToken()
            model.loadBehind(pr)
        }
        .onChange(of: pr.head) { model.forgetBehind(pr.id); model.loadBehind(pr) }
    }

    /// No finished review yet: what is going on, in the chat's place.
    private var status: some View {
        let found = store.record(for: pr)
        let record = found?.record
        return VStack(spacing: 8) {
            Spacer(minLength: 0)
            switch record?.phase {
            case nil:
                Text("Not reviewed yet").font(Typo.title(.medium)).foregroundStyle(Palette.ink2)
                Text("Review now starts a read-only review of the latest commit. The result, its suggested comments and a chat about it show here.")
                    .font(Typo.label()).foregroundStyle(Palette.ink3).multilineTextAlignment(.center)
            case .queued?, .reviewing?:
                ProgressView().controlSize(.small)
                Text(record?.phase == .queued ? "Review queued" : "Reviewing…").font(Typo.title(.medium)).foregroundStyle(Palette.ink2)
                Text("It runs on its own and can take several minutes.").font(Typo.label()).foregroundStyle(Palette.ink3)
            case .failed?:
                Text("The review failed").font(Typo.title(.medium)).foregroundStyle(Palette.failed)
                Text(record?.error ?? "It did not finish.").font(Typo.label()).foregroundStyle(Palette.ink3).multilineTextAlignment(.center)
            default:
                Text("The review was cancelled").font(Typo.title(.medium)).foregroundStyle(Palette.ink2)
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        let id = pr.id
        let found = store.record(for: pr)
        let record = found?.record
        let active = record?.isActive == true
        let pipeline = PRReviewBadge.pipeline(pr)
        return VStack(alignment: .leading, spacing: 6) {
            Text(pr.title).font(Typo.title(.semibold)).foregroundStyle(Palette.ink)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            PRReviewFlow(spacing: 10, rowSpacing: 3) {
                Text("\(pr.ref.repo) #\(pr.ref.id)").font(Typo.label(.semibold)).foregroundStyle(Palette.ink2)
                Text(pr.author.name).font(Typo.label()).foregroundStyle(Palette.ink2)
                Text("\(pr.source ?? "—") → \(pr.destination ?? "—")").font(Typo.label(mono: true)).foregroundStyle(Palette.ink3).lineLimit(1).truncationMode(.middle)
                Text(pipeline.text).font(Typo.label(.medium)).foregroundStyle(pipeline.color)
                if let head = pr.head { Text(String(head.prefix(7))).font(Typo.label(mono: true)).foregroundStyle(Palette.ink3).help("Head commit") }
                if let found { PRReviewChip(pr: pr, store: store).fixedSize(horizontal: false, vertical: true).id(found.record.phase) }
            }
            let reviewerRows = pr.reviewerRows
            if !reviewerRows.isEmpty {
                PRReviewFlow(spacing: 10, rowSpacing: 3) {
                    ForEach(Array(reviewerRows.enumerated()), id: \.offset) { _, row in PRReviewReviewerChip(row: row) }
                }
            }
            if let text = model.behind[id], found?.outdated == true {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.2.circlepath").font(Typo.micro(.bold)).decorative()
                    Text(text + ". Re-review to cover them.").font(Typo.label(.medium)).fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(Palette.waiting)
            }
            if let denied = record?.denied, !denied.isEmpty {
                Text("Limited: the review was refused \(denied.joined(separator: ", ")) and could not read everything, so Approve is off.")
                    .font(Typo.label()).foregroundStyle(Palette.waiting).fixedSize(horizontal: false, vertical: true)
            }
            actions(id: id, found: found, active: active)
            if let line = statusLine(found: found) {
                Text(line.text).font(Typo.label(.medium)).foregroundStyle(line.color).fixedSize(horizontal: false, vertical: true)
                    .onTapGesture { store.clearNotice(id) }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.panel)
    }

    private func actions(id: String, found: (record: ReviewRecord, outdated: Bool)?, active: Bool) -> some View {
        let report = found.flatMap { store.reportURL($0.record) }
        let approve = store.gate(.approve, for: pr)
        let changes = store.gate(.requestChanges, for: pr)
        return PRReviewFlow(spacing: 6, rowSpacing: 6) {
            if active {
                PRReviewPill(title: "Cancel review", symbol: "xmark") { store.cancel(pr) }
            } else {
                PRReviewPill(title: found == nil ? "Review now" : "Re-review", symbol: "arrow.clockwise") { store.reviewNow(pr) }
            }
            if let report { PRReviewPill(title: "View report", symbol: "doc.text") { NSWorkspace.shared.open(report) } }
            PRReviewPill(title: "Open on Bitbucket", symbol: "arrow.up.right.square") { SafeLink.open(pr.url, for: .bitbucket) }
            PRReviewPill(title: "Request changes", destructive: true, enabled: changes.isAllowed && store.acting[id] == nil) { model.overlay = .action(.requestChanges) }
                .help(changes.isAllowed ? "Asks the author for changes, after a confirm." : "Off: \(Self.reason(changes))")
            PRReviewPill(title: "Approve", symbol: "checkmark", prominent: true, enabled: approve.isAllowed && store.acting[id] == nil) { model.overlay = .action(.approve) }
                .help(approve.isAllowed ? "Approves the pull request, after a confirm." : "Off: \(Self.reason(approve))")
        }
    }

    /// The one line under the actions: a click's progress or result, else why the main action is off.
    private func statusLine(found: (record: ReviewRecord, outdated: Bool)?) -> (text: String, color: Color)? {
        let id = pr.id
        if let acting = store.acting[id] { return (acting, Palette.ink2) }
        if let notice = store.notices[id] { return (notice, notice.hasPrefix("Not") || notice.hasPrefix("Needs") ? Palette.waiting : Palette.done) }
        guard let record = found?.record, record.phase == .done, let verdict = record.verdict else { return nil }
        let gate = store.gate(verdict == .approve ? .approve : .requestChanges, for: pr)
        if case .blocked(let why) = gate { return ((verdict == .approve ? "Approve is off: " : "Request changes is off: ") + why, Palette.ink3) }
        return nil
    }

    static func reason(_ gate: ReviewGate) -> String {
        if case .blocked(let why) = gate { return why }
        return ""
    }
}

// MARK: Confirms

/// The second click: what is about to be sent, listed, over a dimmed window. Nothing leaves
/// without "Confirm".
struct PRReviewConfirm: View {
    @ObservedObject var model: PRReviewWindowModel
    @ObservedObject var store: PRReviewStore
    var pr: PullRequest
    var overlay: PRReviewWindowModel.Overlay

    var body: some View {
        ZStack {
            Color.black.opacity(0.4).ignoresSafeArea().onTapGesture { model.overlay = nil }
            VStack(alignment: .leading, spacing: 10) {
                switch overlay {
                case .post: postBody
                case .action(let action): actionBody(action)
                }
            }
            .padding(16)
            .frame(maxWidth: 480)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.surface))
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.card))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.ink3.opacity(0.35), lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
            .padding(20)
        }
        .transition(.opacity)
    }

    private var found: (record: ReviewRecord, outdated: Bool)? { store.record(for: pr) }

    @ViewBuilder private var postBody: some View {
        if let session = model.session(for: pr) {
            let pending = PostPlan.pending(session.cards)
            Text("Post \(pending.count) comment\(pending.count == 1 ? "" : "s") on #\(pr.ref.id)?").font(Typo.title(.semibold)).foregroundStyle(Palette.ink)
            Text("They are posted under your own Bitbucket account, inline where there is a file and line.").font(Typo.label()).foregroundStyle(Palette.ink3)
                .fixedSize(horizontal: false, vertical: true)
            if found?.outdated == true {
                Label("The pull request has new commits since the review: line numbers may be off.", systemImage: "exclamationmark.triangle")
                    .font(Typo.label(.medium)).foregroundStyle(Palette.waiting).fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(pending) { card in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                PRReviewSeverityChip(severity: card.severity)
                                Text(card.location ?? "General comment").font(Typo.label(mono: true)).foregroundStyle(Palette.ink2).lineLimit(1).truncationMode(.middle)
                            }
                            Text(card.body).font(Typo.label()).foregroundStyle(Palette.ink).lineLimit(4).fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.subcard))
                    }
                }
            }
            .frame(maxHeight: 260)
            buttons(confirm: "Post \(pending.count) comment\(pending.count == 1 ? "" : "s")", enabled: !pending.isEmpty && !session.posting) {
                model.overlay = nil
                Task { await session.postPending() }
            }
        }
    }

    @ViewBuilder private func actionBody(_ action: ReviewAction) -> some View {
        let approve = action == .approve
        let record = found?.record
        Text(approve ? "Approve #\(pr.ref.id)?" : "Request changes on #\(pr.ref.id)?").font(Typo.title(.semibold)).foregroundStyle(Palette.ink)
        VStack(alignment: .leading, spacing: 3) {
            Text(pr.title).font(Typo.body(.medium)).foregroundStyle(Palette.ink).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Text("Verdict \(record?.verdict?.rawValue ?? "none") · \(record?.findings?.text ?? "") · \(PRReviewBadge.pipeline(pr).text.lowercased()) · commit \(String(pr.head?.prefix(7) ?? "—"))")
                .font(Typo.label()).foregroundStyle(Palette.ink3).fixedSize(horizontal: false, vertical: true)
        }
        Text(approve ? "This approves the pull request on Bitbucket as you." : "This marks the pull request as needing changes on Bitbucket, as you. Post the comments you want the author to see first.")
            .font(Typo.label()).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true)
        buttons(confirm: approve ? "Approve" : "Request changes", enabled: store.acting[pr.id] == nil) {
            model.overlay = nil
            store.perform(action, on: pr)
        }
    }

    private func buttons(confirm: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            PRReviewPill(title: "Cancel") { model.overlay = nil }
            PRReviewPill(title: confirm, prominent: true, enabled: enabled, action: action)
        }
    }
}
