import Foundation

/// What the widget draws, as the app writes it into the shared app-group container.
public struct WidgetSnapshot: Codable, Sendable {
    public var updatedAt: Double
    public var sessions: [Row]
    public var todayTokens: Int
    public var todayCost: Double

    public init(updatedAt: Double, sessions: [Row], todayTokens: Int, todayCost: Double) {
        self.updatedAt = updatedAt
        self.sessions = sessions
        self.todayTokens = todayTokens
        self.todayCost = todayCost
    }

    public struct Row: Codable, Identifiable, Sendable {
        public var id: String
        public var project: String
        /// The chat's name, as its editor lists it (nil from an older app: the project then).
        public var title: String?
        /// `working`, `waiting` or `idle`.
        public var phase: String
        /// What it is doing: the tool now, what it waits for, or how the last turn went.
        public var detail: String
        public var model: String?
        public var isCursor: Bool
        public var turnStartedAt: Double?
        public var agents: Int

        public init(id: String, project: String, title: String? = nil, phase: String, detail: String, model: String?, isCursor: Bool, turnStartedAt: Double?, agents: Int) {
            self.id = id
            self.project = project
            self.title = title
            self.phase = phase
            self.detail = detail
            self.model = model
            self.isCursor = isCursor
            self.turnStartedAt = turnStartedAt
            self.agents = agents
        }
    }

    /// The app group the app and the widget share (`<team id>.info.ankeshshiv.notch`), which a
    /// team-signed build writes into both Info.plists as `AINotchAppGroup`
    /// (`scripts/assemble-app.sh`). An ad-hoc build has none, and no widget: nil.
    public static var appGroup: String? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "AINotchAppGroup") as? String, !group.isEmpty else { return nil }
        return group
    }
    public static let fileName = "widget.json"

    public static var url: URL? {
        guard let appGroup else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?.appendingPathComponent(fileName)
    }

    public static func load() -> WidgetSnapshot? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    public static let sample = WidgetSnapshot(updatedAt: Date().timeIntervalSince1970, sessions: [
        Row(id: "a", project: "web-app", title: "Fix the login redirect loop", phase: "waiting", detail: "Waiting for permission: Bash", model: "Opus 5.5", isCursor: false, turnStartedAt: nil, agents: 0),
        Row(id: "b", project: "api-server", title: "Paginate the orders endpoint", phase: "working", detail: "github · search_code", model: "Opus 5.5", isCursor: false, turnStartedAt: Date().timeIntervalSince1970 - 95, agents: 2),
        Row(id: "c", project: "mobile-app", title: "Android build failure", phase: "idle", detail: "Done 3m ago · took 2m10s", model: "Sonnet 4.5", isCursor: true, turnStartedAt: nil, agents: 0),
    ], todayTokens: 516_000_000, todayCost: 243.12)
}
