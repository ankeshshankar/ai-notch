import AppKit
import ReviewCore
import SwiftUI

// The automatic review on screen: a chip with its state and verdict (in the row's glyph line of the
// PRs panel and in the review window's header). Everything else is in the review window
// (PRReviewWindow.swift): the actions, the chat, the comment cards, the confirms.

struct PRReviewChip: View {
    var pr: PullRequest
    @ObservedObject var store: PRReviewStore
    @ObservedObject private var progress = ReviewProgressCenter.shared

    var body: some View {
        if let found = store.record(for: pr) {
            let (text, color, help) = Self.describe(found.record, outdated: found.outdated, progress: found.record.phase == .reviewing ? progress.progress[found.record.key] : nil)
            HStack(spacing: 3) {
                Image(systemName: Self.symbol(found.record)).font(Typo.micro(.bold)).decorative()
                Text(text).font(Typo.label(.medium)).lineLimit(1).truncationMode(.tail)
            }
            .foregroundStyle(color)
            .help(help)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Review: \(text)")
        }
    }

    static func symbol(_ record: ReviewRecord) -> String {
        switch record.phase {
        case .queued: return "clock"
        case .reviewing: return "ellipsis"
        case .failed: return "exclamationmark.triangle"
        case .cancelled: return "slash.circle"
        case .done: return record.verdict == .approve ? "checkmark.seal" : "xmark.seal"
        }
    }

    static func describe(_ record: ReviewRecord, outdated: Bool, progress: ReviewProgress? = nil) -> (String, Color, String) {
        let older = outdated ? " · older commit" : ""
        switch record.phase {
        case .queued: return ("Review queued", Palette.ink3, "Waits for the review in progress; one runs at a time.")
        case .reviewing:
            let now = Date().timeIntervalSince1970
            let suffix = progress.map { $0.suffix(elapsed: max(0, now - (record.startedAt ?? record.queuedAt))) } ?? ""
            let tail = suffix.isEmpty ? "…" : " · " + suffix
            return record.baseHead != nil ? ("Follow-up" + tail, Palette.claude, "Claude is checking the new commits against the earlier findings (headless, read only).")
                                          : ("Reviewing" + tail, Palette.claude, "Claude is reviewing this pull request (headless, read only).")
        case .cancelled: return ("Review cancelled", Palette.ink3, "Cancelled. Use Review now to start it again.")
        case .failed: return ("Review failed", Palette.failed, record.error ?? "The review did not finish.")
        case .done:
            let verdict = record.verdict ?? .requestChanges
            let posted = record.posted.map { " · \($0)" } ?? ""
            let limited = (record.denied ?? []).isEmpty ? "" : " · limited"
            let text = (record.baseHead != nil ? "FOLLOW-UP " : "") + (verdict == .approve ? "APPROVE" : "REQUEST CHANGES") + " · " + (record.findings?.text ?? "") + limited + older + posted
            return (text, verdict == .approve ? Palette.done : Palette.waiting,
                    "Claude's verdict on the commit \(record.head.prefix(7)). Open it for the findings, the suggested comments and a chat; nothing was posted."
                    + ((record.denied ?? []).isEmpty ? "" : " The review was refused \(record.denied!.joined(separator: ", ")) and could not read everything, so Approve is off."))
        }
    }
}
