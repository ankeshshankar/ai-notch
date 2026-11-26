import ReviewCore
import SwiftUI

/// The replies under one of my comments: who said what and when, a "new" marker for the unseen
/// ones, the AI's read of the thread (a verdict and one line), an editable reply draft and the
/// four buttons. Every button opens the window's confirm first; nothing is sent from here.
struct PRReplyThreadView: View {
    var thread: ReplyThread
    @ObservedObject var session: PRChatSession
    @ObservedObject var model: PRReviewWindowModel
    /// The thread's own comment is shown above it (a comment of mine that is not a card).
    var showsRoot = false
    @State private var expanded: Set<Int> = []
    @State private var draft = ""

    private static let longText = 280

    var body: some View {
        let file = session.replies
        let attention = file.needsAttention(thread)
        let analysis = file.analysis(thread)
        let newCount = thread.replies.filter { session.newReplyIDs.contains($0.id) }.count
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "arrowshape.turn.up.left").font(Typo.micro(.bold)).foregroundStyle(Palette.ink3).decorative()
                Text(ReplySeen.label(thread.replies.count)).font(Typo.label(.semibold)).foregroundStyle(Palette.ink2)
                if newCount > 0 {
                    Text("\(newCount) new").font(Typo.caption(.semibold)).foregroundStyle(Palette.claude)
                        .padding(.horizontal, 5).padding(.vertical, 1).background(Capsule().fill(Palette.claudeHue.opacity(0.16)))
                }
                if file.resolved.contains(thread.id) {
                    Label("Resolved", systemImage: "checkmark.bubble.fill").font(Typo.label(.semibold)).foregroundStyle(Palette.done).labelStyle(.titleAndIcon)
                } else if !attention, thread.replies.last?.byMe == true {
                    Text("You replied").font(Typo.label()).foregroundStyle(Palette.ink3)
                } else if !attention, file.kept[thread.id] != nil {
                    Text("Kept open").font(Typo.label()).foregroundStyle(Palette.ink3)
                }
                Spacer(minLength: 0)
            }
            if showsRoot {
                Text((thread.location.map { $0 + " · " } ?? "") + thread.text.replacingOccurrences(of: "\n", with: " "))
                    .font(Typo.label()).foregroundStyle(Palette.ink3).lineLimit(2).truncationMode(.tail)
            }
            ForEach(thread.replies) { reply in replyRow(reply) }
            if let analysis { read(analysis) }
            if attention { actions(analysis) }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.subcard))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(newCount > 0 ? Palette.claude.opacity(0.5) : Color.clear, lineWidth: 1))
        .onAppear { draft = session.replyDraft(thread.id) }
        .onChange(of: session.replies.analyses[thread.id]?.draft) { if draft.isEmpty || session.replyDrafts[thread.id] == nil { draft = session.replyDraft(thread.id) } }
    }

    private func replyRow(_ reply: ThreadReply) -> some View {
        let long = reply.text.count > Self.longText
        let open = expanded.contains(reply.id)
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(reply.byMe ? "You" : reply.author).font(Typo.label(.semibold)).foregroundStyle(reply.byMe ? Palette.ink3 : Palette.ink2)
                if let when = Self.when(reply.createdOn) { Text(when).font(Typo.label()).foregroundStyle(Palette.ink3) }
                if session.newReplyIDs.contains(reply.id) {
                    Circle().fill(Palette.claude).frame(width: 6, height: 6).decorative()
                }
            }
            Text(reply.text).font(Typo.body()).foregroundStyle(Palette.ink2)
                .lineLimit(long && !open ? 4 : nil).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            if long {
                Button { if open { expanded.remove(reply.id) } else { expanded.insert(reply.id) } } label: {
                    Text(open ? "Show less" : "Show more").font(Typo.label(.medium)).foregroundStyle(Palette.bitbucket)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, reply.byMe ? 14 : 0)
    }

    private func read(_ analysis: ReplyAnalysis) -> some View {
        let color: Color = {
            switch analysis.verdict {
            case .fixed: return Palette.done
            case .explained: return Palette.bitbucket
            case .notFixed: return Palette.waiting
            case .question: return Palette.claude
            }
        }()
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(analysis.verdict.label).font(Typo.caption(.semibold)).foregroundStyle(color)
                .padding(.horizontal, 5).padding(.vertical, 1).background(Capsule().fill(color.opacity(0.16)))
            Text(analysis.reason).font(Typo.label()).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true)
        }
        .ax("Read of the thread: \(analysis.verdict.label)", value: analysis.reason)
    }

    @ViewBuilder private func actions(_ analysis: ReplyAnalysis?) -> some View {
        let problems = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : ReplyPayload.problems(draft)
        let canReply = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && problems.isEmpty
        TextField("Reply", text: $draft, axis: .vertical)
            .textFieldStyle(.plain).font(Typo.body()).foregroundStyle(Palette.ink).lineLimit(1...8)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Palette.inset))
            .onChange(of: draft) { if draft != session.replyDraft(thread.id) { session.setReplyDraft(thread.id, draft) } }
            .ax("Reply text", value: draft)
        if !problems.isEmpty {
            Label("Reword before sending: \(problems.joined(separator: ", ")).", systemImage: "exclamationmark.triangle")
                .font(Typo.label(.medium)).foregroundStyle(Palette.failed).fixedSize(horizontal: false, vertical: true)
        }
        PRReviewFlow(spacing: 6) {
            PRReviewPill(title: "Resolve", symbol: "checkmark.bubble", enabled: !session.posting) { model.overlay = .thread(.resolve, thread.id) }
                .help("Marks the thread resolved on Bitbucket, after a confirm.")
            PRReviewPill(title: "Reply", symbol: "arrowshape.turn.up.left", enabled: canReply && !session.posting) { model.overlay = .thread(.reply, thread.id) }
            PRReviewPill(title: "Reply + Resolve", symbol: "checkmark.bubble", enabled: canReply && !session.posting) { model.overlay = .thread(.replyAndResolve, thread.id) }
            PRReviewPill(title: "Keep open", enabled: !session.posting) { Task { await session.perform(.keepOpen, root: thread.id) } }
                .help("Leaves the thread as it is until there is a newer reply.")
        }
    }

    /// "5m ago" from Bitbucket's ISO time.
    static func when(_ iso: String?) -> String? {
        guard let iso else { return nil }
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = plain.date(from: iso) ?? fractional.date(from: iso) else { return nil }
        return ago(Date().timeIntervalSince(date))
    }
}
