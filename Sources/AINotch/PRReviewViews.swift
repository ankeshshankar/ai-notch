import AppKit
import ReviewCore
import SwiftUI

// The automatic review on screen: a chip with its state and verdict (in the row's glyph line),
// and under a reviewing row in the PRs panel one line of actions: View report, Review now /
// Re-review / Cancel, and Approve / Request changes when the gate allows. Both buttons ask for
// a second click; nothing is sent to Bitbucket without it.

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
                    "Claude's verdict on the commit \(record.head.prefix(7)). View report has the findings and the drafted comments; nothing was posted."
                    + ((record.denied ?? []).isEmpty ? "" : " The review was refused \(record.denied!.joined(separator: ", ")) and could not read everything, so Approve is off."))
        }
    }
}

/// The actions under a row I review (the PRs panel).
struct PRReviewBar: View {
    var pr: PullRequest
    @ObservedObject var store: PRReviewStore
    /// The action waiting for its second click, until it times out.
    @State private var confirming: ReviewAction?
    @State private var confirmTimer: DispatchWorkItem?

    var body: some View {
        let found = store.record(for: pr)
        let phase = found?.record.phase
        let active = phase == .queued || phase == .reviewing
        let id = pr.ref.key
        Group {
            if let acting = store.acting[id] {
                Text(acting).font(Typo.label(.medium)).foregroundStyle(Palette.ink2)
                    .lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
            } else if let confirming {
                let question = Text(confirming == .approve ? "Approve #\(pr.ref.id)?" : "Request changes on #\(pr.ref.id)?")
                    .font(Typo.label(.semibold)).foregroundStyle(Palette.ink)
                let buttons = HStack(spacing: 6) {
                    pill(confirming == .approve ? "Confirm approve" : "Confirm request", prominent: true) {
                        cancelConfirm()
                        store.perform(confirming, on: pr)
                    }
                    pill("Cancel") { cancelConfirm() }
                }
                // One line when it fits, else the question over the buttons.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) { question.lineLimit(1).fixedSize(); Spacer(minLength: 0); buttons }
                    VStack(alignment: .trailing, spacing: 4) {
                        question.lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
                        buttons
                    }
                }
            } else {
                let notice = store.notices[id].map { text in
                    Text(text).font(Typo.label(.medium)).foregroundStyle(text.hasPrefix("Not") || text.hasPrefix("Needs") ? Palette.waiting : Palette.done)
                        .lineLimit(1).truncationMode(.tail)
                        .onTapGesture { store.clearNotice(id) }
                }
                let report: URL? = found.flatMap { store.reportURL($0.record) }
                let viewReport = report.map { url in pill("View report") { NSWorkspace.shared.open(url) } }
                let others = HStack(spacing: 6) {
                    if active {
                        pill("Cancel review") { store.cancel(pr) }
                    } else {
                        pill(found == nil ? "Review now" : "Re-review") { store.reviewNow(pr) }
                    }
                    if store.gate(.requestChanges, for: pr).isAllowed {
                        pill("Request changes") { ask(.requestChanges) }
                    }
                    if store.gate(.approve, for: pr).isAllowed {
                        pill("Approve", prominent: true) { ask(.approve) }
                    }
                }
                // Pills keep their full labels: on one line when they fit, else the notice and
                // View report on the first line and the actions, right-aligned, on the second.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        notice.fixedSize()
                        Spacer(minLength: 0)
                        viewReport
                        others
                    }
                    VStack(alignment: .trailing, spacing: 4) {
                        if notice != nil || viewReport != nil {
                            HStack(spacing: 6) {
                                notice
                                Spacer(minLength: 0)
                                viewReport
                            }
                        }
                        others
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .onAppear { store.refreshWriteToken() }
    }

    private func ask(_ action: ReviewAction) {
        confirming = action
        let work = DispatchWorkItem { confirming = nil }
        confirmTimer?.cancel()
        confirmTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
    }

    private func cancelConfirm() {
        confirmTimer?.cancel()
        confirming = nil
    }

    private func pill(_ title: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(Typo.label(.medium)).lineLimit(1).fixedSize()
                .foregroundStyle(prominent ? Palette.onDone : Palette.ink2)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(prominent ? Palette.done : Palette.chip))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .ax(title, value: pr.title)
    }
}
