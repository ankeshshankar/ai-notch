import Foundation

/// One usage-limit window: how much of it is used and when it starts over.
public struct LimitWindow: Codable, Sendable, Equatable {
    /// 0–100.
    public var usedPercent: Double
    /// Epoch seconds.
    public var resetsAt: Double?
    /// The window's length, when the source says (Codex: 300 is five hours, 10080 a week).
    public var minutes: Int?

    public init(usedPercent: Double, resetsAt: Double?, minutes: Int?) {
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.minutes = minutes
    }
}

/// A tool's subscription limits as last reported.
public struct ToolLimits: Codable, Sendable, Equatable {
    public var fiveHour: LimitWindow?
    public var weekly: LimitWindow?
    /// `pro`, `max`, `prolite`…
    public var plan: String?
    /// When the numbers were read.
    public var at: Double
    /// Where from: `statusline`, `usage` (Claude Code's own usage request), `codex-log`.
    public var source: String

    public init(fiveHour: LimitWindow?, weekly: LimitWindow?, plan: String?, at: Double, source: String) {
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.plan = plan
        self.at = at
        self.source = source
    }
}

/// `~/.claude/notch/limits.json`: Claude Code's limits, written by the status-line wrapper (and by
/// the app when it asks Claude Code itself), read by the app.
public enum LimitsFile {
    public static var url: URL {
        NotchPaths.sessions.deletingLastPathComponent().appendingPathComponent("limits.json")
    }

    public static func load() -> ToolLimits? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ToolLimits.self, from: data)
    }

    public static func save(_ limits: ToolLimits) {
        guard let data = try? JSONEncoder.notch.encode(limits) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// The status line's `rate_limits`: `{five_hour: {used_percentage, resets_at}, seven_day: …}`.
    public static func fromStatusLine(_ rateLimits: [String: Any], at time: Double) -> ToolLimits? {
        func window(_ key: String, minutes: Int) -> LimitWindow? {
            guard let entry = rateLimits[key] as? [String: Any], let used = number(entry["used_percentage"]) else { return nil }
            return LimitWindow(usedPercent: used, resetsAt: number(entry["resets_at"]), minutes: minutes)
        }
        let five = window("five_hour", minutes: 300), week = window("seven_day", minutes: 10080)
        guard five != nil || week != nil else { return nil }
        return ToolLimits(fiveHour: five, weekly: week, plan: nil, at: time, source: "statusline")
    }

    public static func number(_ value: Any?) -> Double? {
        (value as? Double) ?? (value as? Int).map(Double.init) ?? (value as? NSNumber)?.doubleValue
    }
}
