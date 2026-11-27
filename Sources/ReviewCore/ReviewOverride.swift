import Foundation

// "Approve anyway": the user's own call over a review that does not allow a plain approve. Only
// when every thread of mine is resolved and no card is switched on, nothing is left to say to
// the author. The hard blocks of the plain gate stay (a refused tool, my own work, a moved head,
// a pipeline that is not green, a closed or already approved pull request). No AppKit, no network.

public struct ApproveOverride: Equatable, Sendable {
    public var verdict: ReviewVerdict
    /// Open blocking / should-fix items left unposted (a card on Skip), by title.
    public var skippedBlocking: [String]
    public var skippedShouldFix: [String]
    public var skippedNits: Int
    /// Posted and resolved by me, but the review still counts them open (not marked fixed), by title.
    public var resolvedBlocking: [String]
    public var resolvedShouldFix: [String]
    /// What the review's own count says (the report may list more than the cards).
    public var findings: ReviewFindings
    /// The merge gate's outcome and reasons when the run wrote one: what the override goes against.
    public var gate: MergeGate? = nil
    public var gateReasons: [String] = []

    public var blockingCount: Int { max(findings.blocking, skippedBlocking.count + resolvedBlocking.count) }

    /// The lines the confirm shows: what is being overridden, nothing hidden.
    public var lines: [String] {
        var out = ["Verdict \(verdict.rawValue) is overridden."]
        if let gate, gate != .ready {
            out.append("Merge gate: \(gate.title).")
            for reason in gateReasons { out.append("Gate: \(reason)") }
        }
        if blockingCount > 0 { out.append("\(blockingCount) blocking finding\(blockingCount == 1 ? "" : "s") skipped.") }
        for title in skippedBlocking { out.append("Blocking, on Skip: \(title)") }
        for title in resolvedBlocking { out.append("Blocking, resolved by you: \(title)") }
        for title in skippedShouldFix { out.append("Should-fix, on Skip: \(title)") }
        for title in resolvedShouldFix { out.append("Should-fix, resolved by you: \(title)") }
        if skippedNits > 0 { out.append("\(skippedNits) nit\(skippedNits == 1 ? "" : "s") on Skip.") }
        return out
    }
}

public enum OverrideGate: Equatable, Sendable {
    case unavailable(String)
    case available(ApproveOverride)

    public var info: ApproveOverride? { if case .available(let info) = self { return info } else { return nil } }
    public var isAvailable: Bool { info != nil }
}

extension ReviewGate {
    /// "Approve anyway" is on offer when the plain approve is not: same pull request state rules, plus every
    /// thread of mine resolved (read from Bitbucket, or resolved here) and every unposted card on Skip.
    public static func checkOverride(cards: [SuggestedComment], replies: RepliesFile, record: ReviewRecord?, currentHead: String?, pipeline: PipelineState,
                                     isOpen: Bool = true, alreadyApproved: Bool = false) -> OverrideGate {
        guard let record, record.phase == .done, let verdict = record.verdict else { return .unavailable("no finished review") }
        if record.own == true { return .unavailable("your own work") }
        if !(record.denied ?? []).isEmpty { return .unavailable("the review was refused a tool") }
        guard isOpen else { return .unavailable("pull request is not open") }
        guard sameCommit(record.head, currentHead) else { return .unavailable("new commits since the review") }
        guard pipeline == .green else { return .unavailable(pipeline == .unknown ? "pipeline state unknown" : "pipeline is not green") }
        guard !alreadyApproved else { return .unavailable("already approved") }
        if check(.approve, record: record, currentHead: currentHead, pipeline: pipeline, isOpen: isOpen, alreadyApproved: alreadyApproved).isAllowed {
            return .unavailable("a plain approve is open")
        }
        guard let open = replies.openRoots(cards: cards) else { return .unavailable("threads not read yet") }
        guard open.isEmpty else { return .unavailable("\(open.count) of your thread\(open.count == 1 ? " is" : "s are") not resolved") }
        let on = cards.filter { !$0.isPosted && $0.include }.count
        guard on == 0 else { return .unavailable("\(on) card\(on == 1 ? " is" : "s are") switched on") }
        var info = ApproveOverride(verdict: verdict, skippedBlocking: [], skippedShouldFix: [], skippedNits: 0, resolvedBlocking: [], resolvedShouldFix: [],
                                   findings: record.findings ?? ReviewFindings())
        if let gate = record.mergeGate, gate.gate != .ready {
            info.gate = gate.gate
            info.gateReasons = gate.shownReasons.map(\.text)
        }
        for card in cards where card.status != .fixed {
            let name = (card.title?.isEmpty == false ? card.title : nil) ?? card.location ?? card.id
            switch (card.severity, card.isPosted) {
            case (.blocking, false): info.skippedBlocking.append(name)
            case (.blocking, true): info.resolvedBlocking.append(name)
            case (.shouldFix, false): info.skippedShouldFix.append(name)
            case (.shouldFix, true): info.resolvedShouldFix.append(name)
            case (.nit, false): info.skippedNits += 1
            case (.nit, true), (.preExisting, _): break
            }
        }
        return .available(info)
    }
}
