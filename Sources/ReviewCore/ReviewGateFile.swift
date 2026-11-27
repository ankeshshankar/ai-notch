import Foundation

// The merge gate of a review (`gate.json`, and the `gate` + `reasons` of `followup.json`): READY, NOT_READY or
// NEEDS_LOOK, with the reasons, what the pipeline proves, how many files were read and what others left open.
// The app never trusts a lenient file: it recomputes the outcome from the facts in it and takes the stricter one.
// No AppKit, no network.

public enum MergeGate: String, Codable, Sendable, Equatable {
    case ready = "READY"
    case notReady = "NOT_READY"
    case needsLook = "NEEDS_LOOK"

    /// 0 best, 2 worst: the stricter of two outcomes wins.
    var rank: Int { self == .ready ? 0 : self == .needsLook ? 1 : 2 }

    public static func stricter(_ a: MergeGate, _ b: MergeGate) -> MergeGate { b.rank > a.rank ? b : a }

    /// The words on screen.
    public var title: String {
        switch self {
        case .ready: return "Ready to merge"
        case .notReady: return "Not ready"
        case .needsLook: return "Needs your look"
        }
    }

    public var shortTitle: String {
        switch self {
        case .ready: return "Ready"
        case .notReady: return "Not ready"
        case .needsLook: return "Needs look"
        }
    }

    public static func parse(_ text: String?) -> MergeGate? {
        guard let text else { return nil }
        let key = text.uppercased().replacingOccurrences(of: " ", with: "_")
        return MergeGate(rawValue: key)
    }
}

/// The closed list of reason codes, in plain words.
public enum GateCode {
    public static let notReady: Set<String> = ["open-blocking", "open-should-fix", "ci-red", "tests-missing", "pack-check-failed", "others-open"]
    public static let needsLook: Set<String> = ["unread-files", "ci-running", "ci-none", "cannot-verify-risky", "generic-pack", "pre-existing"]
    public static let all: [String] = ["open-blocking", "open-should-fix", "unread-files", "ci-red", "ci-running", "ci-none", "tests-missing",
                                       "pack-check-failed", "others-open", "cannot-verify-risky", "cannot-verify", "generic-pack", "pre-existing"]

    public static func label(_ code: String) -> String {
        switch code {
        case "open-blocking": return "Blocking findings are open"
        case "open-should-fix": return "Should-fix findings are open"
        case "unread-files": return "Some files were not read"
        case "ci-red": return "The pipeline failed"
        case "ci-running": return "The pipeline is still running"
        case "ci-none": return "No pipeline result for this commit"
        case "tests-missing": return "Changed behaviour has no tests"
        case "pack-check-failed": return "A repo check failed"
        case "others-open": return "Others have unresolved comments"
        case "cannot-verify-risky": return "A risky change could not be verified"
        case "cannot-verify": return "Something could not be verified"
        case "generic-pack": return "No checklist for this repo"
        case "pre-existing": return "Problems that were there before this PR"
        default: return code
        }
    }
}

public struct GateReason: Codable, Sendable, Equatable {
    public var code: String
    public var text: String
    public var refs: [String]
    public init(code: String, text: String = "", refs: [String] = []) {
        self.code = code
        self.text = text.isEmpty ? GateCode.label(code) : text
        self.refs = refs
    }
}

public struct GateCI: Codable, Sendable, Equatable {
    public var state: String
    public var head: String?
    public var covers: String?
}

public struct GateCoverage: Codable, Sendable, Equatable {
    public var files: Int
    public var read: Int
    public var unread: [String]
}

public struct GateOther: Codable, Sendable, Equatable {
    public var id: Int
    public var author: String
    public var severity: String
    public var isHard: Bool { severity == "critical" || severity == "major" }
}

public struct GateCannot: Codable, Sendable, Equatable {
    public var path: String
    public var what: String
    public var risky: Bool
}

public struct GatePackCheck: Codable, Sendable, Equatable {
    public var id: String
    public var state: String
    public var text: String
}

/// A real defect on a line the PR did not change: listed for later, never part of the gate.
public struct GateFollowUp: Codable, Sendable, Equatable {
    public var path: String
    public var line: Int?
    public var title: String
    public var location: String { line.map { "\(path):\($0)" } ?? path }
}

public struct GateFile: Codable, Sendable, Equatable {
    /// What the file says.
    public var stated: MergeGate
    public var pack: String?
    public var reasons: [GateReason]
    public var ci: GateCI?
    public var coverage: GateCoverage?
    public var othersOpen: [GateOther]
    public var cannotVerify: [GateCannot]
    public var packChecks: [GatePackCheck]
    public var nitsNotShown: Int
    public var risk: [String]
    public var deepCheck: Bool
    /// Information only (`gate.json.followUps`); never changes the gate.
    public var followUps: [GateFollowUp] = []
    /// True when a card or finding in the review is pre-existing (set by the app from the cards; the file's own
    /// `pre-existing` reason also counts).
    public var hasPreExisting: Bool = false

    public init(stated: MergeGate, pack: String?, reasons: [GateReason], ci: GateCI?, coverage: GateCoverage?, othersOpen: [GateOther],
                cannotVerify: [GateCannot], packChecks: [GatePackCheck], nitsNotShown: Int, risk: [String], deepCheck: Bool,
                followUps: [GateFollowUp] = [], hasPreExisting: Bool = false) {
        self.stated = stated; self.pack = pack; self.reasons = reasons; self.ci = ci; self.coverage = coverage
        self.othersOpen = othersOpen; self.cannotVerify = cannotVerify; self.packChecks = packChecks
        self.nitsNotShown = nitsNotShown; self.risk = risk; self.deepCheck = deepCheck
        self.followUps = followUps; self.hasPreExisting = hasPreExisting
    }

    private enum CodingKeys: String, CodingKey {
        case stated, pack, reasons, ci, coverage, othersOpen, cannotVerify, packChecks, nitsNotShown, risk, deepCheck, followUps, hasPreExisting
    }

    /// Records saved before follow-ups and the pre-existing bucket have neither key.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stated = try c.decode(MergeGate.self, forKey: .stated)
        pack = try c.decodeIfPresent(String.self, forKey: .pack)
        reasons = try c.decode([GateReason].self, forKey: .reasons)
        ci = try c.decodeIfPresent(GateCI.self, forKey: .ci)
        coverage = try c.decodeIfPresent(GateCoverage.self, forKey: .coverage)
        othersOpen = try c.decode([GateOther].self, forKey: .othersOpen)
        cannotVerify = try c.decode([GateCannot].self, forKey: .cannotVerify)
        packChecks = try c.decode([GatePackCheck].self, forKey: .packChecks)
        nitsNotShown = try c.decode(Int.self, forKey: .nitsNotShown)
        risk = try c.decode([String].self, forKey: .risk)
        deepCheck = try c.decode(Bool.self, forKey: .deepCheck)
        followUps = try c.decodeIfPresent([GateFollowUp].self, forKey: .followUps) ?? []
        hasPreExisting = try c.decodeIfPresent(Bool.self, forKey: .hasPreExisting) ?? false
    }

    /// What the facts in it say, never milder than what it states: this is the one the window and the gate use.
    public var gate: MergeGate { MergeGate.stricter(stated, GateRule.decide(self)) }

    /// The reasons shown: the file's own, plus any the facts add that it left out.
    public var shownReasons: [GateReason] {
        var out = reasons.filter { GateRule.isBacked($0.code, in: self) }
        for code in GateRule.derivedCodes(self) where !out.contains(where: { $0.code == code }) { out.append(GateReason(code: code)) }
        return out
    }

    /// Why Approve is off, in a few words: the gate and its first reason.
    public var blockText: String {
        let first = shownReasons.first?.text
        return gate.title.lowercased() + (first.map { ": " + $0.prefix(1).lowercased() + $0.dropFirst() } ?? "")
    }

    /// The line under the buttons when Approve is off: the first reason in plain words, "+N more" after it.
    public var offLine: String {
        let all = shownReasons
        guard let first = all.first else { return "Approve is off: " + gate.title.lowercased() }
        let more = all.count > 1 ? " (+\(all.count - 1) more)" : ""
        return "Approve is off: " + first.text.prefix(1).lowercased() + first.text.dropFirst() + more
    }

    public var unreadCount: Int { coverage.map { max($0.unread.count, $0.files - $0.read) } ?? 0 }

    /// "Read 38 of 40 files" (nil when the file has no coverage).
    public var filesLine: String? {
        guard let c = coverage else { return nil }
        let unread = unreadCount
        return unread == 0 ? "Read all \(c.files) file\(c.files == 1 ? "" : "s")" : "Read \(max(c.files - unread, 0)) of \(c.files) files, \(unread) not read"
    }

    public var pipelineLine: String? {
        guard let ci else { return nil }
        let word: String
        switch ci.state {
        case "green": word = "Pipeline green"
        case "red": word = "Pipeline red"
        case "running": word = "Pipeline running"
        default: word = "No pipeline result"
        }
        let head = ci.head.map { " for \(String($0.prefix(7)))" } ?? ""
        return word + head + ((ci.covers?.isEmpty == false) ? ": " + ci.covers! : "")
    }

    public var othersLine: String? {
        guard !othersOpen.isEmpty else { return nil }
        let hard = othersOpen.filter(\.isHard).count
        return "\(othersOpen.count) unresolved comment\(othersOpen.count == 1 ? "" : "s") from others" + (hard > 0 ? " (\(hard) critical or major)" : "")
    }

    public var followUpsTitle: String? { followUps.isEmpty ? nil : "Follow-ups (\(followUps.count))" }

    public var nitsLine: String? {
        nitsNotShown > 0 ? "\(nitsNotShown) more nit\(nitsNotShown == 1 ? "" : "s") found, not shown" : nil
    }

    public static func parse(_ data: Data) -> GateFile? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return parse(object, gateKey: "gate")
    }

    /// From a dictionary: `gate.json` (key "gate") or `followup.json` (key "gate" plus "reasons"; the rest is absent).
    public static func parse(_ object: [String: Any], gateKey: String) -> GateFile? {
        // An unreadable or unknown outcome is never a pass.
        guard let raw = object[gateKey] as? String else { return nil }
        let stated = MergeGate.parse(raw) ?? .needsLook
        func str(_ v: Any?) -> String? { (v as? String).flatMap { $0.isEmpty ? nil : $0 } }
        func int(_ v: Any?) -> Int? { (v as? Int) ?? (v as? Double).map(Int.init) ?? (v as? String).flatMap(Int.init) }
        let reasons = (object["reasons"] as? [Any] ?? []).compactMap { item -> GateReason? in
            if let code = item as? String { return GateReason(code: code) }
            guard let d = item as? [String: Any], let code = str(d["code"]) else { return nil }
            return GateReason(code: code, text: str(d["text"]) ?? "", refs: (d["refs"] as? [Any] ?? []).compactMap { str($0) })
        }
        let ci = (object["ci"] as? [String: Any]).map { GateCI(state: str($0["state"]) ?? "none", head: str($0["head"]), covers: str($0["covers"])) }
        let coverage = (object["coverage"] as? [String: Any]).map { d -> GateCoverage in
            let unread = (d["unread"] as? [Any] ?? []).compactMap { str($0) }
            let files = int(d["files"]) ?? 0
            return GateCoverage(files: files, read: int(d["read"]) ?? max(files - unread.count, 0), unread: unread)
        }
        let others = (object["othersOpen"] as? [Any] ?? []).compactMap { item -> GateOther? in
            // Only a comment that asks for something is an open thread; a bot's summary or status note is not.
            guard let d = item as? [String: Any], (d["asks"] as? Bool) != false else { return nil }
            return GateOther(id: int(d["id"]) ?? 0, author: str(d["author"]) ?? "", severity: str(d["severity"])?.lowercased() ?? "unknown")
        }
        let cannot = (object["cannotVerify"] as? [Any] ?? []).compactMap { item -> GateCannot? in
            guard let d = item as? [String: Any] else { return nil }
            return GateCannot(path: str(d["path"]) ?? "", what: str(d["what"]) ?? "", risky: (d["risky"] as? Bool) ?? false)
        }
        let checks = (object["packChecks"] as? [Any] ?? []).compactMap { item -> GatePackCheck? in
            guard let d = item as? [String: Any], let id = str(d["id"]) else { return nil }
            return GatePackCheck(id: id, state: str(d["state"]) ?? "na", text: str(d["text"]) ?? id)
        }
        let followUps = (object["followUps"] as? [Any] ?? []).compactMap { item -> GateFollowUp? in
            guard let d = item as? [String: Any], let title = str(d["title"]) else { return nil }
            return GateFollowUp(path: str(d["path"]) ?? "", line: int(d["line"]), title: title)
        }
        return GateFile(stated: stated, pack: str(object["pack"]), reasons: reasons, ci: ci, coverage: coverage, othersOpen: others, cannotVerify: cannot,
                        packChecks: checks, nitsNotShown: max(int(object["nitsNotShown"]) ?? 0, 0),
                        risk: (object["risk"] as? [Any] ?? []).compactMap { str($0) }, deepCheck: (object["deepCheck"] as? Bool) ?? false,
                        followUps: followUps)
    }
}

extension GateFile {
    /// A full run's `gate.json`, with the one fact the file alone does not carry: a pre-existing finding in the
    /// report or a pre-existing card in `comments.json` (the `pre-existing` reason then holds, NEEDS_LOOK at most).
    public static func settle(gateJSON: Data, findings: ReviewFindings, commentsJSON: Data?) -> GateFile? {
        guard var file = parse(gateJSON) else { return nil }
        let cards = commentsJSON.map { CommentParse.file($0) } ?? []
        file.hasPreExisting = findings.preExisting > 0 || cards.contains { $0.severity == .preExisting }
        return file
    }
}

/// The contract's rule, applied to the facts.
public enum GateRule {
    /// The codes the facts imply, whether or not the file lists them.
    public static func derivedCodes(_ file: GateFile) -> [String] {
        var out: [String] = []
        switch file.ci?.state {
        case "red": out.append("ci-red")
        case "running": out.append("ci-running")
        case "none": out.append("ci-none")
        default: break
        }
        if file.unreadCount > 0 { out.append("unread-files") }
        if file.packChecks.contains(where: { $0.state == "fail" }) { out.append("pack-check-failed") }
        if file.othersOpen.contains(where: \.isHard) { out.append("others-open") }
        if file.cannotVerify.contains(where: \.risky) { out.append("cannot-verify-risky") }
        if file.pack == "generic" { out.append("generic-pack") }
        if file.hasPreExisting { out.append("pre-existing") }
        return out
    }

    /// The reason codes the facts back up. A code the file lists without its fact is dropped from what is shown
    /// and from the outcome: `pack-check-failed` needs a pack check in state `fail`, `cannot-verify-risky` a
    /// `risky: true` item, `pre-existing` a pre-existing card or finding (the app's own count, or the file's
    /// `pre-existing` reason that names finding ids). A code that needs no further fact is kept as it is.
    public static func isBacked(_ code: String, in file: GateFile) -> Bool {
        switch code {
        case "pack-check-failed": return file.packChecks.contains { $0.state == "fail" }
        case "cannot-verify-risky": return file.cannotVerify.contains(where: \.risky)
        case "pre-existing": return file.hasPreExisting || (file.reasons.first { $0.code == code }?.refs.isEmpty == false)
        default: return true
        }
    }

    public static func decide(_ file: GateFile) -> MergeGate {
        let codes = Set(file.reasons.map(\.code).filter { isBacked($0, in: file) }).union(derivedCodes(file))
        return decide(codes: codes, softOthers: file.othersOpen.contains { !$0.isHard })
    }

    /// NOT_READY on any blocking code; NEEDS_LOOK on any looking code or an unresolved minor/unknown comment from
    /// someone else; READY otherwise (a plain `cannot-verify` is listed but does not block).
    public static func decide(codes: Set<String>, softOthers: Bool = false) -> MergeGate {
        if !codes.isDisjoint(with: GateCode.notReady) { return .notReady }
        if softOthers || !codes.isDisjoint(with: GateCode.needsLook) { return .needsLook }
        return .ready
    }
}
