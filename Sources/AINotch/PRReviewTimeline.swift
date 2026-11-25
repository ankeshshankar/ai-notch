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

struct PRCommentCard: View {
    var card: SuggestedComment
    @ObservedObject var session: PRChatSession
    var pr: PullRequest
    @State private var draft = ""
    @State private var editing = false
    @FocusState private var focused: Bool

    var body: some View {
        let duplicate = session.duplicate(of: card)
        let problems = CommentPolicy.problems(in: card.body)
        let dimmed = !card.include && !card.isPosted
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                PRReviewSeverityChip(severity: card.severity)
                if let location = card.location { locationLink(location) } else {
                    Text("General comment").font(Typo.label()).foregroundStyle(Palette.ink3)
                }
                if let badge = card.badge, !card.isPosted {
                    Text(badge).font(Typo.caption(.semibold)).foregroundStyle(Palette.claude)
                        .padding(.horizontal, 5).padding(.vertical, 1).background(Capsule().fill(Palette.claudeHue.opacity(0.16)))
                }
                Spacer(minLength: 0)
                if card.isPosted {
                    Label("Posted", systemImage: "checkmark.circle.fill").font(Typo.label(.semibold)).foregroundStyle(Palette.done).labelStyle(.titleAndIcon)
                } else {
                    AddSkipSwitch(include: card.include) { session.setInclude(card.id, $0) }
                        .ax("Add or skip this comment", value: card.include ? "Add" : "Skip")
                }
            }
            if let title = card.title, !title.isEmpty, !card.isPosted {
                Text(title).font(Typo.label(.semibold)).foregroundStyle(Palette.ink2).lineLimit(1).truncationMode(.tail)
            }
            if card.isPosted {
                Text(card.body).font(Typo.body()).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            } else {
                TextField("Comment", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain).font(Typo.body()).foregroundStyle(Palette.ink)
                    .lineLimit(1...12)
                    .focused($focused)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Palette.inset))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(focused ? Palette.bitbucket.opacity(0.7) : Color.clear, lineWidth: 1))
                    .onAppear { draft = card.body }
                    .onChange(of: draft) { if draft != card.body { session.setBody(card.id, draft) } }
                    .onChange(of: card.body) { if draft != card.body { draft = card.body } }
                    .ax("Comment text", value: card.body)
            }
            if !problems.isEmpty, !card.isPosted {
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
            .strokeBorder(card.isPosted ? Palette.done.opacity(0.4) : PRReviewSeverityChip.color(card.severity).opacity(card.include ? 0.45 : 0.15), lineWidth: 1))
        .opacity(dimmed ? 0.62 : 1)
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

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        reviewMessage
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
            }
            Divider()
            footer
        }
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
                Text("review of \(String((record?.head ?? "").prefix(7)))").font(Typo.label()).foregroundStyle(Palette.ink3)
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
                Text("Suggested comments").font(Typo.label(.semibold)).foregroundStyle(Palette.ink2)
                Text(cards.isEmpty ? "" : "\(toAdd) to add · \(cards.count) total").font(Typo.label()).foregroundStyle(Palette.ink3)
                InfoMark(text: "Pick the ones to post under your name: Add is on for blocking and should-fix findings, off for nits. Edit the text, or ask in the chat to draft or soften one. Nothing is posted until you confirm.")
                Spacer(minLength: 0)
                if session.needsDraft {
                    PRReviewPill(title: session.drafting ? "Drafting…" : "Draft comments", symbol: "text.badge.plus", enabled: !session.running) { session.draftComments() }
                }
            }
            if cards.isEmpty {
                Text(session.needsDraft ? "This review has no comments drafted yet." : "No comments to post. Ask in the chat to draft one.")
                    .font(Typo.label()).foregroundStyle(Palette.ink3).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(cards.filter { c in !session.log.messages.contains { $0.newCards.contains(c.id) } }) { card in
                PRCommentCard(card: card, session: session, pr: pr)
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
                    if let card = session.card(id) { PRCommentCard(card: card, session: session, pr: pr) }
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
            if !session.cards.isEmpty {
                HStack(spacing: 8) {
                    let posted = session.cards.filter(\.isPosted).count
                    Text(pending.isEmpty ? (posted > 0 ? "\(posted) posted" : "Nothing switched on") : "\(pending.count) switched on" + (posted > 0 ? " · \(posted) posted" : ""))
                        .font(Typo.label(.medium)).foregroundStyle(Palette.ink2)
                    if let notice = session.notice { Text(notice).font(Typo.label()).foregroundStyle(notice.hasPrefix("Posted") || notice.hasPrefix("Drafted") ? Palette.done : Palette.waiting).lineLimit(2) }
                    Spacer(minLength: 0)
                    PRReviewPill(title: session.posting ? "Posting…" : "Post \(pending.count) comment\(pending.count == 1 ? "" : "s")", symbol: "paperplane", prominent: true,
                                 enabled: !pending.isEmpty && blocked.isEmpty && !session.posting) { model.overlay = .post }
                        .help(blocked.isEmpty ? "Posts the switched-on comments after a confirm." : "Reword the flagged comments first.")
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
                    .onSubmit(send)
                    .ax("Message")
                if session.running {
                    PRReviewPill(title: "Stop", symbol: "stop.fill") { session.stop() }
                } else {
                    PRReviewPill(title: "Send", symbol: "arrow.up", prominent: true, enabled: session.canChat && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, action: send)
                }
            }
            Text("Read only: the chat can read the code and say things; only you post.").font(Typo.caption()).foregroundStyle(Palette.ink3)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Palette.panel)
    }

    private func send() {
        guard session.canChat, !session.running else { return }
        let text = input
        input = ""
        session.send(text)
    }
}
