import Foundation

// A session's context window: how full it is, read from its transcript. No hook carries it. The
// transcript's format is Claude Code's own and undocumented, so every read here is defensive: a
// missing or odd field gives nil (the row shows nothing), never a guess.

/// How the Claude Code process was told to compact, read from its environment by the hook (the
/// app cannot read another process's environment). Only the variables Claude Code documents.
public struct AutoCompactEnv: Codable, Sendable, Equatable {
    /// `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE`: compact at this percent of the window (1-100).
    public var pct: Int?
    /// `CLAUDE_CODE_AUTO_COMPACT_WINDOW`: the window compaction is sized against, in tokens.
    public var window: Int?
    /// `CLAUDE_CODE_DISABLE_1M_CONTEXT=1`: never the 1M window.
    public var no1M: Bool?

    public init(pct: Int? = nil, window: Int? = nil, no1M: Bool? = nil) {
        self.pct = pct
        self.window = window
        self.no1M = no1M
    }

    /// Nil when none of them is set.
    public static func read(_ env: [String: String]) -> AutoCompactEnv? {
        let pct = env["CLAUDE_AUTOCOMPACT_PCT_OVERRIDE"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }.flatMap { (1...100).contains($0) ? $0 : nil }
        let window = env["CLAUDE_CODE_AUTO_COMPACT_WINDOW"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }.flatMap { $0 >= 10_000 ? $0 : nil }
        let no1M = ["1", "true"].contains(env["CLAUDE_CODE_DISABLE_1M_CONTEXT"]?.lowercased() ?? "") ? true : nil
        guard pct != nil || window != nil || no1M != nil else { return nil }
        return AutoCompactEnv(pct: pct, window: window, no1M: no1M)
    }
}

public enum ContextLevel: Int, Sendable, Comparable {
    case normal, warn, strong

    public static func < (a: ContextLevel, b: ContextLevel) -> Bool { a.rawValue < b.rawValue }
}

public enum ContextUse {
    public static let standardWindow = 200_000
    public static let wideWindow = 1_000_000
    /// Claude Code compacts a native 1M window at about this many tokens (the rest is its output and summary reserve).
    public static let wideCompactAt = 967_000
    /// A level starts at this share of the compaction point.
    public static let warnShare = 0.80
    public static let strongShare = 0.92

    /// Whether the model has the 1M window without the `[1m]` suffix: Fable, Sonnet 5 and later,
    /// Haiku 5.5 and later, Opus 4.7 and later.
    public static func isNativeWide(_ model: String) -> Bool {
        let words = modelName(model).split(separator: " ").map(String.init)
        guard let family = words.first?.lowercased() else { return false }
        if family == "fable" { return true }
        let version = (words.count > 1 ? words[1] : "").split(separator: ".").compactMap { Int($0) }
        guard let major = version.first else { return false }
        let minor = version.count > 1 ? version[1] : 0
        switch family {
        case "sonnet": return major >= 5
        case "haiku": return major > 5 || (major == 5 && minor >= 5)
        case "opus": return major > 4 || (major == 4 && minor >= 7)
        default: return false
        }
    }

    /// The window in tokens. 200K unless the model has 1M (natively, or with `[1m]`) and it is not
    /// switched off; and 1M whenever the tokens seen already exceed 200K, whatever the id says.
    public static func window(model: String?, observed: Int, env: AutoCompactEnv? = nil) -> Int {
        if observed > standardWindow { return wideWindow }
        guard env?.no1M != true, let model else { return standardWindow }
        if model.lowercased().contains("[1m]") || isNativeWide(model) { return wideWindow }
        return standardWindow
    }

    /// Where auto-compact starts: 967K on a native 1M window, the limit otherwise; an environment
    /// override can only bring it earlier.
    public static func compactPoint(window: Int, env: AutoCompactEnv? = nil) -> Int {
        var point = window >= wideWindow ? wideCompactAt : window
        if let size = env?.window, size > 0 { point = min(point, size) }
        if let pct = env?.pct, (1...100).contains(pct) { point = min(point, window * pct / 100) }
        return max(point, 1)
    }

    public static func level(tokens: Int, point: Int) -> ContextLevel {
        guard point > 0 else { return .normal }
        let share = Double(tokens) / Double(point)
        return share >= strongShare ? .strong : share >= warnShare ? .warn : .normal
    }

    /// Whole percent of the window used (not of the compaction point), at most 999.
    public static func percent(tokens: Int, window: Int) -> Int {
        guard window > 0 else { return 0 }
        return min(999, Int((Double(tokens) / Double(window) * 100).rounded()))
    }

    /// One alert per crossing of the strong level: fires when it is reached while not alerted,
    /// and re-arms once the session is back under the warn level (a compaction does that).
    public static func alertStep(level: ContextLevel, alerted: Bool) -> (fire: Bool, alerted: Bool) {
        if level == .strong { return (!alerted, true) }
        if level == .normal { return (false, false) }
        return (false, alerted)
    }

    // MARK: Reading the transcript

    public struct Reading: Equatable, Sendable {
        public var tokens: Int
        /// When the entry was written (seconds since 1970), if it said.
        public var at: Double?

        /// Nil for a reading written before the last compaction (`compactedAt`, from PostCompact):
        /// that context is gone.
        public func valid(after compactedAt: Double?) -> Reading? {
            if let compactedAt, let at, at < compactedAt - 1 { return nil }
            return self
        }
    }

    /// The context in use at the end of a transcript, from `tail` (its last lines): the newest
    /// main-thread reply's input + cache-creation + cache-read tokens, or, when a compaction
    /// came after it, the tokens that compaction says it left. Nil when neither is there or a
    /// field is odd. Sidechain (subagent) lines are skipped.
    public static func reading(inTail tail: String) -> Reading? {
        for line in tail.split(separator: "\n").reversed() {
            guard line.hasPrefix("{"), let data = line.data(using: .utf8),
                  let entry = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            if entry["isSidechain"] as? Bool == true { continue }
            let at = (entry["timestamp"] as? String).flatMap(isoTime)
            let type = entry["type"] as? String
            if type == "system", entry["subtype"] as? String == "compact_boundary" {
                // Nothing newer than the compaction has replied yet.
                guard let meta = entry["compactMetadata"] as? [String: Any], let after = integer(meta["postTokens"]), after >= 0 else { return nil }
                return Reading(tokens: after, at: at)
            }
            guard type == "assistant", let message = entry["message"] as? [String: Any] else { continue }
            if let model = message["model"] as? String, model.hasPrefix("<") { continue }
            // The newest reply says nothing usable: nothing is better than an older reply's number.
            guard let usage = message["usage"] as? [String: Any] else { return nil }
            let parts = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"].map { usage[$0] }
            // A missing cache field is a zero, but a field of the wrong kind means the format changed.
            if parts.contains(where: { $0 != nil && integer($0) == nil }) { return nil }
            guard usage["input_tokens"] != nil else { return nil }
            let tokens = parts.compactMap(integer).reduce(0, +)
            guard tokens > 0 else { return nil }
            return Reading(tokens: tokens, at: at)
        }
        return nil
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        return double >= 0 && double < 1e12 && double == double.rounded() ? Int(double) : nil
    }

    private static func isoTime(_ text: String) -> Double? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return (formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text))?.timeIntervalSince1970
    }
}

/// Why a turn ended on an API error, in plain words (Claude Code's `StopFailure` `error` field).
public enum FailureReason {
    public static func text(_ code: String?) -> String {
        switch code?.lowercased() {
        case "rate_limit": return "Rate limited"
        case "overloaded": return "Overloaded"
        case "authentication_failed", "oauth_org_not_allowed", "cloud_credential_error": return "Sign-in failed"
        case "billing_error", "account_on_hold": return "Billing problem"
        case "server_error": return "Server error"
        case "max_output_tokens": return "Output limit hit"
        default: return "Failed"
        }
    }
}
