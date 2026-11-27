import Foundation

// The follow-up's side of the merge gate: what it is given (other people's open threads, the previous gate), what
// the app adds to the pass's own answer (open findings, missing cards), the commits it skips (target merged in)
// and a diff split into parts instead of cut. No AppKit, no network.

extension GateFile {
    /// The contract's own shape, for `gate.json` as input to a later pass.
    public var contractJSON: [String: Any] {
        var o: [String: Any] = ["gate": gate.rawValue, "reasons": shownReasons.map { ["code": $0.code, "text": $0.text, "refs": $0.refs] as [String: Any] },
                                "othersOpen": othersOpen.map { ["id": $0.id, "author": $0.author, "severity": $0.severity] as [String: Any] },
                                "cannotVerify": cannotVerify.map { ["path": $0.path, "what": $0.what, "risky": $0.risky] as [String: Any] },
                                "packChecks": packChecks.map { ["id": $0.id, "state": $0.state, "text": $0.text] as [String: Any] },
                                "nitsNotShown": nitsNotShown, "risk": risk, "deepCheck": deepCheck]
        if let pack { o["pack"] = pack }
        if let ci { o["ci"] = ["state": ci.state, "head": ci.head ?? "", "covers": ci.covers ?? ""] as [String: Any] }
        if let coverage { o["coverage"] = ["files": coverage.files, "read": coverage.read, "unread": coverage.unread] as [String: Any] }
        return o
    }
}

extension FollowUp {
    /// The previous review counted open blocking or should-fix findings that the cards in the input do not cover
    /// (a card missing, or never made): the pass cannot check them, so it must not approve.
    public static func missingCards(previous: ReviewRecord?, log: ChatLog) -> Bool {
        guard let findings = previous?.findings else { return false }
        let cards = log.cards.filter { $0.status != .fixed && ($0.severity == .blocking || $0.severity == .shouldFix) }.count
        return findings.blocking + findings.shouldFix > cards
    }

    /// The gate a follow-up leaves. The pass's own gate (if any) gains what the app knows: open blocking and
    /// should-fix cards, cards that are missing (NEEDS_LOOK, `cannot-verify`), and a gate the pass forgot to write
    /// after a gated review (also NEEDS_LOOK). Nothing gated before and nothing wrong now: no gate, today's rules.
    public static func finalGate(reported: GateFile?, previous: GateFile?, open: ReviewFindings, missingCards: Bool) -> GateFile? {
        guard reported != nil || previous != nil || missingCards else { return nil }
        var gate = reported ?? GateFile(stated: .needsLook, pack: previous?.pack, reasons: [], ci: nil, coverage: nil, othersOpen: [], cannotVerify: [],
                                        packChecks: [], nitsNotShown: 0, risk: previous?.risk ?? [], deepCheck: false)
        func add(_ code: String, _ text: String) {
            if !gate.reasons.contains(where: { $0.code == code }) { gate.reasons.append(GateReason(code: code, text: text)) }
        }
        if reported == nil { add("cannot-verify", "The follow-up wrote no merge gate.") }
        if open.blocking > 0 { add("open-blocking", "\(open.blocking) blocking finding\(open.blocking == 1 ? "" : "s") open") }
        if open.shouldFix > 0 { add("open-should-fix", "\(open.shouldFix) should-fix finding\(open.shouldFix == 1 ? "" : "s") open") }
        if missingCards {
            add("cannot-verify", "Earlier blocking or should-fix findings have no card to check.")
            gate.stated = MergeGate.stricter(gate.stated, .needsLook)
        }
        gate.stated = MergeGate.stricter(gate.stated, GateRule.decide(gate))
        return gate
    }

    /// "APPROVE" stands only over a READY gate (the report's VERDICT line and the gate always agree).
    public static func standingVerdict(_ reported: ReviewVerdict, findings: ReviewFindings, gate: GateFile?) -> ReviewVerdict {
        let base = standingVerdict(reported, findings: findings)
        if let gate, gate.gate != .ready { return .requestChanges }
        return base
    }
}

extension ChatLog {
    /// Makes the last follow-up's verdict the one the gate allows (the pass's own is kept as `reported`).
    public mutating func restateVerdict(_ verdict: ReviewVerdict, note id: String) {
        guard let index = followUps.firstIndex(where: { $0.id == id }), followUps[index].verdict != verdict else { return }
        if followUps[index].reported == nil { followUps[index].reported = followUps[index].verdict }
        followUps[index].verdict = verdict
    }
}

public enum OtherThreads {
    /// Every unresolved top-level comment thread from someone other than me or the app's own comments, as the
    /// follow-up's input lists it (their words are data; `severity` is for the pass to judge).
    public static func open(_ comments: [RawComment], mine: Set<Int>, me: String?) -> [ExistingComment] {
        comments.filter { c in
            c.parentID == nil && !c.resolved && !mine.contains(c.id) && !(me != nil && c.authorUUID == me)
        }.map(\.existing)
    }
}

/// A diff over the size limit is read in parts, never cut.
public enum DiffSplit {
    public static let limit = 200_000

    /// Parts of at most `limit` bytes, split before a `diff --git` line (a file bigger than that is split by lines).
    public static func parts(_ diff: Data, limit: Int = DiffSplit.limit) -> [Data] {
        guard diff.count > limit, let text = String(data: diff, encoding: .utf8) else { return [diff] }
        var chunks: [String] = []
        var current = ""
        func flush() { if !current.isEmpty { chunks.append(current); current = "" } }
        func lines(_ t: String) -> [Substring] {
            var all = t.split(separator: "\n", omittingEmptySubsequences: false)
            if all.last?.isEmpty == true { all.removeLast() }
            return all
        }
        var files: [String] = []
        var file = ""
        for line in lines(text) {
            if line.hasPrefix("diff --git "), !file.isEmpty { files.append(file); file = "" }
            file += line + "\n"
        }
        if !file.isEmpty { files.append(file) }
        for piece in files {
            if piece.utf8.count > limit {
                flush()
                var part = ""
                for line in lines(piece) {
                    if part.utf8.count + line.utf8.count + 1 > limit, !part.isEmpty { chunks.append(part); part = "" }
                    part += line + "\n"
                }
                if !part.isEmpty { chunks.append(part) }
            } else {
                if current.utf8.count + piece.utf8.count > limit { flush() }
                current += piece
            }
        }
        flush()
        if !text.hasSuffix("\n"), let last = chunks.last { chunks[chunks.count - 1] = String(last.dropLast()) }
        return chunks.map { Data($0.utf8) }
    }

    /// The names the parts are written under: `followup.diff` for one, `followup-1.diff` … for several.
    public static func names(count: Int) -> [String] {
        count <= 1 ? ["followup.diff"] : (1...count).map { "followup-\($0).diff" }
    }
}
