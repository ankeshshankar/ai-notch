import AppKit
import ReviewCore
import SwiftUI

// The review's conversation: Claude's review as the first message, the suggested comment cards,
// then the exchange, with a composer at the bottom and "Post N comments" above it.

/// Wraps its children onto new lines when they do not fit: the header never clips in a narrow window.
struct PRReviewFlow: Layout {
    var spacing: CGFloat = 8
    var rowSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height } + rowSpacing * CGFloat(max(rows.count - 1, 0))
        let width = proposal.width ?? rows.map(\.width).max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for (index, size) in zip(row.indices, row.sizes) {
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + rowSpacing
        }
    }

    private struct Row { var indices: [Int] = []; var sizes: [CGSize] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            var size = subviews[index].sizeThatFits(ProposedViewSize(width: width.isFinite ? width : nil, height: nil))
            if width.isFinite, size.width > width { size.width = width }
            let needed = (rows[rows.count - 1].indices.isEmpty ? 0 : spacing) + size.width
            if !rows[rows.count - 1].indices.isEmpty, rows[rows.count - 1].width + needed > width { rows.append(Row()) }
            var row = rows[rows.count - 1]
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            row.sizes.append(size)
            rows[rows.count - 1] = row
        }
        return rows
    }
}

struct PRReviewSeverityChip: View {
    var severity: CommentSeverity

    static func color(_ severity: CommentSeverity) -> Color {
        switch severity {
        case .blocking: return Palette.failed
        case .shouldFix: return Palette.waiting
        case .nit: return Palette.ink3
        }
    }

    var body: some View {
        Text(severity.label).font(Typo.label(.semibold)).foregroundStyle(Self.color(severity)).lineLimit(1).fixedSize()
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(Self.color(severity).opacity(0.14)))
    }
}

// MARK: Markdown

/// Markdown for the chat: headings, lists, code blocks, rules and inline marks (bold, italic,
/// code, links). Anything else shows as text.
struct PRMarkdownView: View {
    var text: String
    var font: Font = Typo.body()

    private enum Block: Identifiable {
        case paragraph(String), heading(String, Int), bullet(String, Int, String), code(String), rule
        var id: String {
            switch self {
            case .paragraph(let t): return "p" + t
            case .heading(let t, _): return "h" + t
            case .bullet(let t, let i, let m): return "b\(i)\(m)" + t
            case .code(let t): return "c" + t
            case .rule: return "r"
            }
        }
    }

    private var blocks: [(Int, Block)] { parse(text).enumerated().map { ($0.offset, $0.element) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(blocks, id: \.0) { _, block in
                switch block {
                case .paragraph(let t): inline(t)
                case .heading(let t, let level): inline(t).font(level <= 1 ? Typo.title(.semibold) : Typo.body(.semibold))
                case .bullet(let t, let indent, let marker):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(marker).font(font).foregroundStyle(Palette.ink3)
                        inline(t)
                    }
                    .padding(.leading, CGFloat(indent) * 14)
                case .code(let t):
                    Text(t).font(Typo.label(mono: true)).foregroundStyle(Palette.ink)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Palette.inset))
                case .rule: Divider()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inline(_ source: String) -> some View {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let attributed = (try? AttributedString(markdown: source, options: options)) ?? AttributedString(source)
        return Text(attributed).font(font).foregroundStyle(Palette.ink)
            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
    }

    private func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var code: [String]?
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
        }
        for raw in text.components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if code != nil {
                if trimmed.hasPrefix("```") { blocks.append(.code(code!.joined(separator: "\n"))); code = nil } else { code?.append(raw) }
                continue
            }
            if trimmed.hasPrefix("```") { flush(); code = []; continue }
            if trimmed.isEmpty { flush(); continue }
            if trimmed == "---" || trimmed == "***" { flush(); blocks.append(.rule); continue }
            if let hashes = trimmed.prefix(while: { $0 == "#" }) as Substring?, !hashes.isEmpty, hashes.count <= 6, trimmed.dropFirst(hashes.count).first == " " {
                flush(); blocks.append(.heading(String(trimmed.dropFirst(hashes.count + 1)), hashes.count)); continue
            }
            let indent = raw.prefix(while: { $0 == " " }).count / 2
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("• ") {
                flush(); blocks.append(.bullet(String(trimmed.dropFirst(2)), indent, "•")); continue
            }
            if let range = trimmed.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
                flush(); blocks.append(.bullet(String(trimmed[range.upperBound...]), indent, String(trimmed[..<range.upperBound]).trimmingCharacters(in: .whitespaces))); continue
            }
            paragraph.append(trimmed)
        }
        if let code { blocks.append(.code(code.joined(separator: "\n"))) }
        flush()
        return blocks
    }
}

// MARK: Cards

/// Add / Skip on a comment card: the side that is on is filled (Add green with a tick, Skip grey),
/// so the choice reads at a glance.
private struct AddSkipSwitch: View {
    var include: Bool
    var set: (Bool) -> Void

    var body: some View {
        HStack(spacing: 2) {
            side("Add", symbol: "checkmark", on: include, fill: Palette.done, ink: Palette.onDone) { set(true) }
            side("Skip", symbol: "xmark", on: !include, fill: Palette.ink3.opacity(0.35), ink: Palette.ink) { set(false) }
        }
        .padding(2)
        .background(Capsule().fill(Palette.chip))
        .fixedSize()
    }

    private func side(_ title: String, symbol: String, on: Bool, fill: Color, ink: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if on { Image(systemName: symbol).font(Typo.micro(.bold)).decorative() }
                Text(title).font(Typo.label(on ? .semibold : .medium))
            }
            .foregroundStyle(on ? ink : Palette.ink3)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(Capsule().fill(on ? fill : Color.clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// "Fixed" / "Still open" / "Unclear": what the follow-up found about a comment.
struct PRFollowUpBadge: View {
    var status: FollowUpStatus
    var reason: String?

    private var color: Color {
        switch status {
        case .fixed: return Palette.done
        case .stillOpen: return Palette.waiting
        case .unclear: return Palette.ink3
        }
    }

    var body: some View {
        Text(status.badge).font(Typo.caption(.semibold)).foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 1).background(Capsule().fill(color.opacity(0.16)))
            .help(reason ?? "")
            .ax("Follow-up: \(status.badge)", value: reason ?? "")
    }
}

/// A small on/off pill under a card: "Post as suggestion", "Also add a task".
private struct CardOption: View {
    var title: String
    var on: Bool
    var help: String
    var set: (Bool) -> Void

    var body: some View {
        Button { set(!on) } label: {
            HStack(spacing: 4) {
                Image(systemName: on ? "checkmark.square.fill" : "square").font(Typo.label()).foregroundStyle(on ? Palette.bitbucket : Palette.ink3).decorative()
                Text(title).font(Typo.label(.medium)).foregroundStyle(on ? Palette.ink : Palette.ink3)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .ax(title, value: on ? "on" : "off")
    }
}

struct PRCommentCard: View {
    var card: SuggestedComment
    @ObservedObject var session: PRChatSession
    var pr: PullRequest
    var own = false
    var focused = false
    @ObservedObject var model: PRReviewWindowModel
    @State private var draft = ""
    @State private var editing = false
    @FocusState private var textFocused: Bool

    var body: some View {
        let duplicate = session.duplicate(of: card)
        let problems = CommentPolicy.problems(in: card.body)
        let dimmed = !card.include && !card.isPosted && card.status != .fixed || (card.status == .fixed && !card.isPosted)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                PRReviewSeverityChip(severity: card.severity)
                if let location = card.location { locationLink(location) } else {
                    Text("General comment").font(Typo.label()).foregroundStyle(Palette.ink3)
                }
                if let status = card.status { PRFollowUpBadge(status: status, reason: card.statusReason) }
                if let badge = card.badge, !card.isPosted {
                    Text(badge).font(Typo.caption(.semibold)).foregroundStyle(Palette.claude)
                        .padding(.horizontal, 5).padding(.vertical, 1).background(Capsule().fill(Palette.claudeHue.opacity(0.16)))
                }
                Spacer(minLength: 0)
                if own {
                    CardOption(title: "Done", on: card.done == true, help: "Tick it off when you have fixed it.") { session.setDone(card.id, $0) }
                } else if card.isPosted {
                    if card.status == .fixed, card.resolved != true {
                        PRReviewPill(title: "Resolve", symbol: "checkmark.bubble", enabled: !session.posting) { model.overlay = .resolve(card.id) }
                            .help("Marks this comment thread resolved on Bitbucket, after a confirm.")
                    }
                    if card.resolved == true {
                        Label("Resolved", systemImage: "checkmark.bubble.fill").font(Typo.label(.semibold)).foregroundStyle(Palette.done).labelStyle(.titleAndIcon)
                    }
                    Label("Posted", systemImage: "checkmark.circle.fill").font(Typo.label(.semibold)).foregroundStyle(Palette.done).labelStyle(.titleAndIcon)
                } else {
                    AddSkipSwitch(include: card.include) { session.setInclude(card.id, $0) }
                        .ax("Add or skip this comment", value: card.include ? "Add" : "Skip")
                }
            }
            if let title = card.title, !title.isEmpty, !card.isPosted {
                Text(title).font(Typo.label(.semibold)).foregroundStyle(Palette.ink2).lineLimit(1).truncationMode(.tail)
            }
            if card.isPosted || own {
                Text(card.body).font(Typo.body()).foregroundStyle(card.done == true ? Palette.ink3 : Palette.ink2)
                    .strikethrough(card.done == true).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            } else {
                TextField("Comment", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain).font(Typo.body()).foregroundStyle(Palette.ink)
                    .lineLimit(1...12)
                    .focused($textFocused)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Palette.inset))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(textFocused ? Palette.bitbucket.opacity(0.7) : Color.clear, lineWidth: 1))
                    .onAppear { draft = card.body }
                    .onChange(of: draft) { if draft != card.body { session.setBody(card.id, draft) } }
                    .onChange(of: card.body) { if draft != card.body { draft = card.body } }
                    .ax("Comment text", value: card.body)
            }
            if let code = card.suggestion, !own {
                VStack(alignment: .leading, spacing: 4) {
                    Text(code).font(Typo.label(mono: true)).foregroundStyle(Palette.ink).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Palette.inset))
                    if !card.isPosted {
                        HStack(spacing: 10) {
                            if card.canSuggest {
                                CardOption(title: "Post as suggestion", on: card.asSuggestion ?? true,
                                           help: "Posts the code as a suggested change the author can apply with one click. Off: the code is left out of the comment.") { session.setSuggestionOn(card.id, $0) }
                            } else {
                                Text("Needs a file and line to post as a suggestion").font(Typo.label()).foregroundStyle(Palette.ink3)
                            }
                        }
                    }
                }
            }
            if !card.isPosted, !own, card.severity == .blocking {
                CardOption(title: "Also add a task", on: card.wantsTask,
                           help: "After the comment posts, adds a Bitbucket task linked to it, so the pull request cannot merge until it is done.") { session.setTask(card.id, $0) }
            }
            if card.isPosted, card.taskID != nil {
                Label("Task added", systemImage: "checklist").font(Typo.label()).foregroundStyle(Palette.ink3)
            }
            if !problems.isEmpty, !card.isPosted, !own {
                Label("Reword before posting: \(problems.joined(separator: ", ")).", systemImage: "exclamationmark.triangle")
                    .font(Typo.label(.medium)).foregroundStyle(Palette.failed).fixedSize(horizontal: false, vertical: true)
            }
            if let duplicate, !card.isPosted {
                Label("Already commented here by \(duplicate.author): “\(String(duplicate.text.replacingOccurrences(of: "\n", with: " ").prefix(80)))”", systemImage: "text.bubble")
                    .font(Typo.label()).foregroundStyle(Palette.waiting).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(focused ? Palette.bitbucket : card.isPosted ? Palette.done.opacity(0.4) : PRReviewSeverityChip.color(card.severity).opacity(card.include || own ? 0.45 : 0.15), lineWidth: focused ? 2 : 1))
        .opacity(dimmed && !own ? 0.62 : 1)
        .id("card-" + card.id)
        .onTapGesture { model.focusedCard = card.id }
    }

    private func locationLink(_ location: String) -> some View {
        Button {
            if let path = card.path, let base = pr.url?.absoluteString,
               let url = URL(string: BitbucketLinks.lineURL(prURL: base, path: path, line: card.line)) {
                SafeLink.open(url, for: .bitbucket)
            }
        } label: {
            Text(location).font(Typo.label(mono: true)).foregroundStyle(Palette.bitbucket).underline()
                .lineLimit(1).truncationMode(.middle)
        }
        .buttonStyle(.plain)
        .help("Open this line on Bitbucket")
        .ax("Open \(location) on Bitbucket")
    }
}

// MARK: The timeline

struct PRReviewTimeline: View {
    @ObservedObject var model: PRReviewWindowModel
    @ObservedObject var store: PRReviewStore
    var pr: PullRequest
    @ObservedObject var session: PRChatSession
    @State private var input = ""
    @State private var fullReport = false
    @State private var showExisting = false
    @FocusState private var listFocused: Bool
    @FocusState private var inputFocused: Bool

    private var own: Bool { pr.role == .mine || store.record(for: pr)?.record.own == true }

    /// The cards in the order they show, for the arrow keys.
    private var shownCards: [SuggestedComment] { session.cards.filter { c in !session.log.messages.contains { $0.newCards.contains(c.id) } } }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        reviewMessage
                        followUpNotes
                        if !own { repliesBar }
                        existingSection
                        cardsSection
                        ForEach(session.log.messages) { message in messageView(message) }
                        if session.running { streamingView }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onAppear { if !session.log.messages.isEmpty { DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) } } }
                .onChange(of: session.log.messages.count) { withAnimation(Motion.ease(0.2)) { proxy.scrollTo("bottom", anchor: .bottom) } }
                .onChange(of: session.streaming) { proxy.scrollTo("bottom", anchor: .bottom) }
                .focusable()
                .focused($listFocused)
                .focusEffectDisabled()
                .onKeyPress(phases: .down) { press in handle(press, proxy: proxy) }
            }
            Divider()
            footer
        }
        .background(shortcutButtons)
        .onAppear { DispatchQueue.main.async { listFocused = true }; if !own { session.loadExisting(maxAge: 30) } }
        .onChange(of: model.focusChat) { inputFocused = true }
    }

    // MARK: Keyboard

    private func handle(_ press: KeyPress, proxy: ScrollViewProxy) -> KeyPress.Result {
        guard !press.modifiers.contains(.command) else { return .ignored }
        let key: String
        switch press.key {
        case .upArrow: key = "up"
        case .downArrow: key = "down"
        default: key = press.characters
        }
        guard let action = ReviewKeys.action(key: key, command: false, typing: inputFocused) else { return .ignored }
        perform(action, proxy: proxy)
        return .handled
    }

    private func perform(_ action: ReviewKeyAction, proxy: ScrollViewProxy? = nil) {
        let ids = shownCards.map(\.id)
        switch action {
        case .previousCard, .nextCard:
            model.focusedCard = ReviewKeys.move(current: model.focusedCard, ids: ids, by: action == .nextCard ? 1 : -1)
            if let id = model.focusedCard { withAnimation(Motion.ease(0.15)) { proxy?.scrollTo("card-" + id, anchor: .center) } }
        case .add, .skip:
            if let id = model.focusedCard, !own { session.setInclude(id, action == .add) }
        case .post:
            if !own, !PostPlan.pending(session.cards).isEmpty, PostPlan.blocked(session.cards).isEmpty, !session.posting { model.overlay = .post }
        case .reReview:
            model.reReview(pr)
        case .focusChat:
            inputFocused = true
        }
    }

    /// ⌘↩, ⌘R and ⌘L work wherever the focus is (also in the text boxes).
    private var shortcutButtons: some View {
        ZStack {
            Button("Post") { perform(.post) }.keyboardShortcut(.return, modifiers: .command)
            Button("Re-review") { perform(.reReview) }.keyboardShortcut("r", modifiers: .command)
            Button("Chat") { perform(.focusChat) }.keyboardShortcut("l", modifiers: .command)
        }
        .opacity(0).frame(width: 0, height: 0).allowsHitTesting(false).accessibilityHidden(true)
    }

    // MARK: Messages

    private var reviewMessage: some View {
        let record = store.record(for: pr)?.record
        let lines = session.reportText.components(separatedBy: "\n")
        let long = lines.count > 14
        let shown = fullReport || !long ? session.reportText : lines.prefix(14).joined(separator: "\n")
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Claude").font(Typo.label(.semibold)).foregroundStyle(Palette.claude)
                Text(record?.baseHead != nil ? "follow-up on \(String((record?.head ?? "").prefix(7)))" : "review of \(String((record?.head ?? "").prefix(7)))").font(Typo.label()).foregroundStyle(Palette.ink3)
                if let verdict = record?.verdict {
                    Text(verdict.rawValue).font(Typo.label(.semibold)).foregroundStyle(verdict == .approve ? Palette.done : Palette.waiting)
                }
            }
            PRMarkdownView(text: shown)
            if long {
                Button(fullReport ? "Show less" : "Show the full review") { withAnimation(Motion.slide) { fullReport.toggle() } }
                    .buttonStyle(.plain).font(Typo.label(.medium)).foregroundStyle(Palette.bitbucket)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.panel))
    }

    /// "Follow-up on 3 new commits": what the quick pass over the new commits found.
    @ViewBuilder private var followUpNotes: some View {
        ForEach(session.log.followUps) { note in
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.2.circlepath").font(Typo.micro(.bold)).foregroundStyle(Palette.claude).decorative()
                    Text(note.title).font(Typo.label(.semibold)).foregroundStyle(Palette.claude)
                    Text("\(note.fromHead.prefix(7)) → \(note.toHead.prefix(7))").font(Typo.label(mono: true)).foregroundStyle(Palette.ink3)
                    Text(note.verdict.rawValue).font(Typo.label(.semibold)).foregroundStyle(note.verdict == .approve ? Palette.done : Palette.waiting)
                }
                Text(note.counts).font(Typo.label(.medium)).foregroundStyle(Palette.ink2)
                if !note.summary.isEmpty { Text(note.summary).font(Typo.body()).foregroundStyle(Palette.ink).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.panel))
        }
    }

    /// "Resolve N fixed": one button for every open thread of mine that is found fixed; the confirm lists them.
    @ViewBuilder private var resolveAllPill: some View {
        let count = session.resolvableThreads(currentHead: pr.head).count
        if count > 0 {
            PRReviewPill(title: "Resolve \(count) fixed", symbol: "checkmark.bubble", enabled: !session.posting && store.acting[pr.id] == nil) { model.overlay = .resolveAll }
                .help("Marks every open thread of yours that is found fixed (by the follow-up or the reply read) resolved on Bitbucket, after one confirm.")
        }
    }

    /// The threads the last bulk resolve could not resolve, and why.
    @ViewBuilder private var resolveFailures: some View {
        if !session.bulkFailures.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Label("Not resolved", systemImage: "exclamationmark.triangle").font(Typo.label(.semibold)).foregroundStyle(Palette.failed)
                    Spacer(minLength: 0)
                    PRReviewPill(title: "Dismiss") { session.clearBulkFailures() }
                }
                ForEach(Array(session.bulkFailures.enumerated()), id: \.offset) { _, failure in
                    Text("\(failure.label): \(failure.why)").font(Typo.label()).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.subcard))
            .ax("Threads not resolved", value: session.bulkFailures.map { "\($0.label): \($0.why)" }.joined(separator: "; "))
        }
    }

    /// Replies under my comments that are not cards, and the bar to refresh them and have them read.
    @ViewBuilder private var repliesBar: some View {
        let threads = session.replies.threads
        if !threads.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("Replies").font(Typo.label(.semibold)).foregroundStyle(Palette.ink2)
                    Text(session.newReplyIDs.isEmpty ? ReplySeen.label(threads.reduce(0) { $0 + $1.replies.count }) : "\(session.newReplyIDs.count) new").font(Typo.label()).foregroundStyle(Palette.ink3)
                    InfoMark(text: "What the authors answered under the comments you posted. Read replies has Claude check each thread against the code (read only) and draft an answer; nothing is posted or resolved until you click and confirm.")
                    if !own { resolveAllPill }
                    Spacer(minLength: 0)
                    if !session.unreadThreads.isEmpty {
                        PRReviewPill(title: session.readingReplies ? "Reading…" : "Read replies", symbol: "text.magnifyingglass", enabled: !session.readingReplies && !session.running) { session.readReplies() }
                    }
                    PRReviewPill(title: "Refresh", symbol: "arrow.clockwise") { session.loadExisting() }
                }
                ForEach(session.otherThreads) { thread in PRReplyThreadView(thread: thread, session: session, model: model, showsRoot: true) }
            }
        }
    }

    @ViewBuilder private var existingSection: some View {
        if !session.existing.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Button { withAnimation(Motion.slide) { showExisting.toggle() } } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showExisting ? "chevron.down" : "chevron.right").font(Typo.micro(.bold)).decorative()
                        Text("Already on the pull request · \(session.existing.count)").font(Typo.label(.semibold))
                    }
                    .foregroundStyle(Palette.ink3).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if showExisting {
                    ForEach(session.existing) { comment in
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(comment.author)" + (comment.path.map { " · \($0)" + (comment.line.map { ":\($0)" } ?? "") } ?? ""))
                                .font(Typo.label(.medium)).foregroundStyle(Palette.ink2).lineLimit(1).truncationMode(.middle)
                            Text(comment.text).font(Typo.label()).foregroundStyle(Palette.ink3).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.leading, 12)
                    }
                }
            }
        }
    }

    private var cardsSection: some View {
        let cards = session.cards
        let toAdd = PostPlan.pending(cards).count
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(own ? "To fix" : "Suggested comments").font(Typo.label(.semibold)).foregroundStyle(Palette.ink2)
                Text(cards.isEmpty ? "" : own ? "\(cards.filter { $0.done == true }.count) of \(cards.count) done" : "\(toAdd) to add · \(cards.count) total").font(Typo.label()).foregroundStyle(Palette.ink3)
                InfoMark(text: own ? "The findings as a checklist for you. Nothing here is posted anywhere." : "Pick the ones to post under your name: Add is on for blocking and should-fix findings, off for nits. Edit the text, or ask in the chat to draft or soften one. Nothing is posted until you confirm.")
                if !own { resolveAllPill }
                Spacer(minLength: 0)
                if session.needsDraft {
                    PRReviewPill(title: session.drafting ? "Drafting…" : "Draft comments", symbol: "text.badge.plus", enabled: !session.running) { session.draftComments() }
                }
            }
            if !own { resolveFailures }
            if cards.isEmpty {
                Text(session.needsDraft ? "This review has no comments drafted yet." : "No comments to post. Ask in the chat to draft one.")
                    .font(Typo.label()).foregroundStyle(Palette.ink3).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(shownCards) { card in
                VStack(alignment: .leading, spacing: 4) {
                    PRCommentCard(card: card, session: session, pr: pr, own: own, focused: model.focusedCard == card.id, model: model)
                    if !own, let thread = session.thread(forCard: card) {
                        PRReplyThreadView(thread: thread, session: session, model: model).padding(.leading, 14)
                    }
                }
            }
        }
    }

    @ViewBuilder private func messageView(_ message: ChatMessage) -> some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 40)
                Text(message.text).font(Typo.body()).foregroundStyle(Palette.ink).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.chip))
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Claude").font(Typo.label(.semibold)).foregroundStyle(Palette.claude)
                if message.isError {
                    Text(message.text).font(Typo.body()).foregroundStyle(Palette.waiting).fixedSize(horizontal: false, vertical: true)
                } else {
                    PRMarkdownView(text: message.text)
                }
                if !message.revisedCards.isEmpty {
                    Text("Revised \(message.revisedCards.count == 1 ? "a comment" : "\(message.revisedCards.count) comments") above.")
                        .font(Typo.label(.medium)).foregroundStyle(Palette.claude)
                }
                ForEach(message.newCards, id: \.self) { id in
                    if let card = session.card(id) { PRCommentCard(card: card, session: session, pr: pr, own: own, focused: model.focusedCard == card.id, model: model) }
                }
            }
        }
    }

    private var streamingView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Claude").font(Typo.label(.semibold)).foregroundStyle(Palette.claude)
                ProgressView().controlSize(.mini)
                if let activity = session.activity { Text(activity).font(Typo.label()).foregroundStyle(Palette.ink3).lineLimit(1).truncationMode(.middle) }
            }
            if !session.streaming.isEmpty { PRMarkdownView(text: session.streaming) }
        }
    }

    // MARK: Footer

    private var footer: some View {
        let pending = PostPlan.pending(session.cards)
        let blocked = PostPlan.blocked(session.cards)
        return VStack(alignment: .leading, spacing: 6) {
            if !session.cards.isEmpty, own {
                Text("For you only: nothing is posted from here.").font(Typo.label(.medium)).foregroundStyle(Palette.ink2)
            } else if !session.cards.isEmpty {
                HStack(spacing: 8) {
                    let posted = session.cards.filter(\.isPosted).count
                    Text(pending.isEmpty ? (posted > 0 ? "\(posted) posted" : "Nothing switched on") : "\(pending.count) switched on" + (posted > 0 ? " · \(posted) posted" : ""))
                        .font(Typo.label(.medium)).foregroundStyle(Palette.ink2)
                    if let notice = session.notice { Text(notice).font(Typo.label()).foregroundStyle(notice.hasPrefix("Posted") || notice.hasPrefix("Drafted") ? Palette.done : Palette.waiting).lineLimit(2) }
                    Spacer(minLength: 0)
                    PRReviewPill(title: session.posting ? "Posting…" : "Post \(pending.count) comment\(pending.count == 1 ? "" : "s")", symbol: "paperplane", prominent: true,
                                 enabled: !pending.isEmpty && blocked.isEmpty && !session.posting) { model.overlay = .post }
                        .help(blocked.isEmpty ? "Posts the switched-on comments after a confirm. ⌘↩" : "Reword the flagged comments first.")
                }
                let options = store.combinedOptions(for: pr, pending: pending)
                if !options.isEmpty {
                    PRReviewFlow(spacing: 6, rowSpacing: 6) {
                        ForEach(options, id: \.action) { option in
                            PRReviewPill(title: option.action.title(count: pending.count), symbol: option.action.final == .approve ? "checkmark" : nil,
                                         destructive: option.action.final == .requestChanges,
                                         enabled: option.gate.isAllowed && blocked.isEmpty && !session.posting && store.acting[pr.id] == nil) { model.overlay = .combined(option.action) }
                                .help(option.gate.isAllowed ? "Posts the comments, then \(option.action.final == .approve ? "approves" : "asks for changes"), after one confirm that lists both." : "Off: \(PRReviewDetail.reason(option.gate))")
                        }
                    }
                }
            } else if let notice = session.notice {
                Text(notice).font(Typo.label()).foregroundStyle(Palette.waiting)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(session.canChat ? "Ask about this pull request, or ask for a comment" : "No session to continue: use Re-review", text: $input, axis: .vertical)
                    .textFieldStyle(.plain).font(Typo.body()).lineLimit(1...6)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.inset))
                    .disabled(!session.canChat)
                    .focused($inputFocused)
                    .onSubmit(send)
                    .ax("Message")
                if session.running {
                    PRReviewPill(title: "Stop", symbol: "stop.fill") { session.stop() }
                } else {
                    PRReviewPill(title: "Send", symbol: "arrow.up", prominent: true, enabled: session.canChat && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, action: send)
                }
            }
            HStack(spacing: 6) {
                Text("Read only: the chat can read the code and say things; only you post.").font(Typo.caption()).foregroundStyle(Palette.ink3)
                Spacer(minLength: 0)
                Button { model.showKeys.toggle() } label: {
                    Label("Shortcuts", systemImage: "keyboard").font(Typo.caption(.medium)).foregroundStyle(Palette.ink3).labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $model.showKeys, arrowEdge: .top) { shortcutsHelp }
                .ax("Keyboard shortcuts")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Palette.panel)
    }

    private var shortcutsHelp: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Keyboard").font(Typo.label(.semibold)).foregroundStyle(Palette.ink2)
            ForEach(ReviewKeys.help, id: \.keys) { item in
                HStack(spacing: 10) {
                    Text(item.keys).font(Typo.label(.semibold, mono: true)).foregroundStyle(Palette.ink).frame(width: 36, alignment: .leading)
                    Text(item.what).font(Typo.label()).foregroundStyle(Palette.ink2)
                }
            }
            Text("A and S, and the arrows, work when no text box is being typed in.").font(Typo.caption()).foregroundStyle(Palette.ink3)
        }
        .padding(12)
        .frame(width: 330, alignment: .leading)
    }

    private func send() {
        guard session.canChat, !session.running else { return }
        let text = input
        input = ""
        session.send(text)
    }
}
