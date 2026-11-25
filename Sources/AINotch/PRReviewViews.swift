import AppKit
import ReviewCore
import SwiftUI

// The automatic review on screen: a chip with its state and verdict (in the row's glyph line of the
// PRs panel and in the review window's header). Everything else is in the review window
// (PRReviewWindow.swift): the actions, the chat, the comment cards, the confirms.

struct PRReviewChip: View {
    var pr: PullRequest
    @ObservedObject var store: PRReviewStore

    var body: some View {
        if let found = store.record(for: pr) {
            let (text, color, help) = Self.describe(found.record, outdated: found.outdated)
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

    static func describe(_ record: ReviewRecord, outdated: Bool) -> (String, Color, String) {
        let older = outdated ? " · older commit" : ""
        switch record.phase {
        case .queued: return ("Review queued", Palette.ink3, "Waits for the review in progress; one runs at a time.")
        case .reviewing: return ("Reviewing…", Palette.claude, "Claude is reviewing this pull request (headless, read only).")
        case .cancelled: return ("Review cancelled", Palette.ink3, "Cancelled. Use Review now to start it again.")
        case .failed: return ("Review failed", Palette.failed, record.error ?? "The review did not finish.")
        case .done:
            let verdict = record.verdict ?? .requestChanges
            let posted = record.posted.map { " · \($0)" } ?? ""
            let limited = (record.denied ?? []).isEmpty ? "" : " · limited"
            let text = (verdict == .approve ? "APPROVE" : "REQUEST CHANGES") + " · " + (record.findings?.text ?? "") + limited + older + posted
            return (text, verdict == .approve ? Palette.done : Palette.waiting,
                    "Claude's verdict on the commit \(record.head.prefix(7)). Open it for the findings, the suggested comments and a chat; nothing was posted."
                    + ((record.denied ?? []).isEmpty ? "" : " The review was refused \(record.denied!.joined(separator: ", ")) and could not read everything, so Approve is off."))
        }
    }
}
