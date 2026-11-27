import AppKit
import ReviewCore
import SwiftUI

/// Hand-off of my own pull request to the coding chat: reads the comments of other people (read only),
/// writes `<repo>-<pr>-fix.md` beside the review folders and puts one line that points at it on the
/// pasteboard. Nothing is posted anywhere.
@MainActor
final class PRHandoff: ObservableObject {
    let ref: PullRequestRef
    @Published private(set) var others = HandoffOthers()
    @Published private(set) var loaded = false
    /// The last read of Bitbucket failed: `others` is what the review saved (or what was read before).
    @Published private(set) var failed = false
    @Published private(set) var loading = false
    @Published private(set) var notice: String?
    var me: () -> String? = { nil }

    /// The line goes here; a check replaces it so it never touches the real pasteboard.
    nonisolated(unsafe) static var writePasteboard: (String) -> Void = { line in
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(line, forType: .string)
    }

    init(ref: PullRequestRef) { self.ref = ref }

    static func fileURL(_ ref: PullRequestRef) -> URL {
        PRReviewStore.baseURL.appendingPathComponent(ReviewHandoff.fileName(repo: ref.repo, number: ref.id))
    }

    /// The comments of others now (a read only GET); on a failure what the review saved in `others.json`, else what is held.
    private func read(fallback folder: URL?) async -> (others: HandoffOthers, failed: Bool) {
        // A branch review has no pull request, so nothing to read and nothing failed.
        guard ref.id > 0 else { return (HandoffOthers(), false) }
        if let raw = await PRReviewAPI.rawComments(ref) { return (HandoffComments.others(raw, me: me()), false) }
        if let folder, let data = try? Data(contentsOf: folder.appendingPathComponent("others.json")), let saved = HandoffComments.fromOthersFile(data) { return (saved, true) }
        return (loaded ? others : HandoffOthers(), true)
    }

    /// Reads when the pull request is opened and on Refresh.
    func load(folder: URL?) {
        guard !loading else { return }
        loading = true
        Task { @MainActor in
            defer { loading = false }
            let result = await read(fallback: folder)
            others = result.others
            failed = result.failed
            loaded = true
        }
    }

    /// Reads the comments again, writes the file, copies the line. `input` is built from what was read.
    func copy(folder: URL?, input: @escaping (HandoffOthers, Bool) -> HandoffInput) {
        guard !loading else { return }
        loading = true
        notice = nil
        Task { @MainActor in
            defer { loading = false }
            let result = await read(fallback: folder)
            others = result.others
            failed = result.failed
            loaded = true
            let content = input(result.others, result.failed)
            let url = Self.fileURL(ref)
            do {
                try FileManager.default.createDirectory(at: PRReviewStore.baseURL, withIntermediateDirectories: true)
                try Data(ReviewHandoff.markdown(content).utf8).write(to: url, options: .atomic)
            } catch {
                notice = "Not copied: the file could not be written"
                return
            }
            Self.writePasteboard(ReviewHandoff.prompt(path: url.path))
            notice = ReviewHandoff.notice(findings: ReviewHandoff.findings(content.cards).count, comments: content.others.open.count, refreshFailed: result.failed && ref.id > 0)
        }
    }

    /// Copy for the open pull request (the button and ⌘⇧C): the findings not done and the open comments of others.
    func copy(pr: PullRequest, store: PRReviewStore, session: PRChatSession?) {
        copy(folder: store.record(for: pr).flatMap { store.folder(for: $0.record) }) { others, failed in
            PRHandoff.input(pr: pr, store: store, session: session, others: others, failed: failed)
        }
    }

    /// What the file is built from, for the open pull request.
    static func input(pr: PullRequest, store: PRReviewStore, session: PRChatSession?, others: HandoffOthers, failed: Bool) -> HandoffInput {
        let found = store.record(for: pr)?.record
        let reviewed = found?.phase == .done ? found : nil
        var report: String?
        if let reviewed, let folder = store.folder(for: reviewed) {
            report = ["review.md", "report.md"].map { folder.appendingPathComponent($0) }.first { FileManager.default.fileExists(atPath: $0.path) }?.path
        }
        return HandoffInput(repo: pr.ref.repo, number: pr.ref.id, title: pr.title, source: pr.source, target: pr.destination,
                            reviewedHead: reviewed?.head, currentHead: pr.head, cards: reviewed == nil ? [] : session?.cards ?? [],
                            others: others, refreshFailed: failed && pr.ref.id > 0, reportPath: report)
    }
}

/// The "Copy for chat" pill and its notice.
struct PRCopyForChat: View {
    @ObservedObject var handoff: PRHandoff
    @ObservedObject var store: PRReviewStore
    var pr: PullRequest
    var session: PRChatSession?
    /// The cards on screen (for the enabled rule; a session is not observed here).
    var cards: [SuggestedComment]

    var body: some View {
        let enabled = ReviewHandoff.canCopy(cards: cards, others: handoff.others) && !handoff.loading
        HStack(spacing: 8) {
            PRReviewPill(title: handoff.loading ? "Copying…" : "Copy for chat", symbol: "doc.on.clipboard", enabled: enabled) { copy() }
                .help("Writes the findings still to fix and the open comments of others to one file, and copies one line that points at it. Paste it in the chat where you build this. ⌘⇧C")
            if let notice = handoff.notice {
                Text(notice).font(Typo.label()).foregroundStyle(notice.hasPrefix("Not") || notice.contains("could not") ? Palette.waiting : Palette.done).lineLimit(2)
            }
        }
    }

    func copy() {
        handoff.copy(pr: pr, store: store, session: session)
    }
}

/// "Comments from others": a compact read only list; nothing is posted, resolved or approved from it.
struct PROthersSection: View {
    @ObservedObject var handoff: PRHandoff
    var folder: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Comments from others").font(Typo.label(.semibold)).foregroundStyle(Palette.ink2)
                if handoff.loaded && !handoff.others.open.isEmpty { Text("\(handoff.others.open.count)").font(Typo.label()).foregroundStyle(Palette.ink3) }
                InfoMark(text: "Open comments on this pull request from other people and bots, with their replies. They go into the file Copy for chat writes. View only: nothing is posted or resolved from here.")
                Spacer(minLength: 0)
                PRReviewPill(title: handoff.loading ? "Reading…" : "Refresh", symbol: "arrow.clockwise", enabled: !handoff.loading) { handoff.load(folder: folder) }
            }
            if handoff.failed {
                Text("Comments could not be read from Bitbucket: showing what the review saved.").font(Typo.label()).foregroundStyle(Palette.waiting)
            }
            if !handoff.loaded {
                Text("Reading…").font(Typo.label()).foregroundStyle(Palette.ink3)
            } else if handoff.others.open.isEmpty {
                Text("No open comments from others").font(Typo.label()).foregroundStyle(Palette.ink3)
            } else {
                ForEach(handoff.others.open) { PROtherRow(comment: $0) }
            }
        }
    }
}

private struct PROtherRow: View {
    var comment: HandoffComment

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(comment.author).font(Typo.label(.semibold)).foregroundStyle(Palette.ink)
                if comment.isBot {
                    Text("bot").font(Typo.micro(.semibold)).foregroundStyle(Palette.ink2)
                        .padding(.horizontal, 5).padding(.vertical, 1).background(Capsule().fill(Palette.chip))
                }
                Text(comment.location).font(Typo.label(mono: true)).foregroundStyle(Palette.ink3).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                if !comment.replies.isEmpty {
                    Text("\(comment.replies.count) repl\(comment.replies.count == 1 ? "y" : "ies")").font(Typo.label()).foregroundStyle(Palette.ink3)
                }
            }
            Text(comment.text).font(Typo.label()).foregroundStyle(Palette.ink2).lineLimit(3).fixedSize(horizontal: false, vertical: true)
        }
        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.subcard))
        .ax("\(comment.author)\(comment.isBot ? ", bot" : ""), \(comment.location)", value: comment.text)
    }
}

/// An own pull request with no finished review: the comments of others and the copy, in the status page's place.
struct PROwnOthersPanel: View {
    @ObservedObject var handoff: PRHandoff
    @ObservedObject var store: PRReviewStore
    var pr: PullRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack(spacing: 8) {
                PRCopyForChat(handoff: handoff, store: store, pr: pr, session: nil, cards: [])
                Spacer(minLength: 0)
            }
            ScrollView { PROthersSection(handoff: handoff, folder: store.record(for: pr).flatMap { store.folder(for: $0.record) }).padding(.bottom, 4) }
                .frame(maxHeight: 240)
        }
        .padding(.horizontal, 14).padding(.bottom, 12)
        .background(copyShortcut)
        .onAppear { handoff.load(folder: store.record(for: pr).flatMap { store.folder(for: $0.record) }) }
    }

    private var copyShortcut: some View {
        Button("Copy for chat") { if ReviewHandoff.canCopy(cards: [], others: handoff.others) { handoff.copy(pr: pr, store: store, session: nil) } }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .opacity(0).frame(width: 0, height: 0).allowsHitTesting(false).accessibilityHidden(true)
    }
}
