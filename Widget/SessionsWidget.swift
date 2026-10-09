import SwiftUI
import WidgetKit

/// The widget's colours for the system's appearance, as the app's light and dark tokens.
private struct Palette {
    var isDark: Bool
    init(_ scheme: ColorScheme) { isDark = scheme == .dark }

    /// Bright amber in both themes: the "needs you" chip, with black text.
    static let waitingHue = Color(red: 0.96, green: 0.65, blue: 0.14)

    var claude: Color { isDark ? Color(red: 0.85, green: 0.47, blue: 0.34) : Color(red: 0.71, green: 0.33, blue: 0.18) }
    var waiting: Color { isDark ? Self.waitingHue : Color(red: 0.60, green: 0.34, blue: 0.0) }
    var done: Color { isDark ? Color(red: 0.30, green: 0.76, blue: 0.54) : Color(red: 0.11, green: 0.50, blue: 0.31) }
    var ink: Color { isDark ? .white : .black.opacity(0.88) }
    var ink2: Color { isDark ? .white.opacity(0.62) : .black.opacity(0.72) }
    var ink3: Color { isDark ? .white.opacity(0.42) : .black.opacity(0.58) }
    var background: Color { isDark ? .black : .white }
    var card: Color { isDark ? .white.opacity(0.07) : .black.opacity(0.045) }
    var waitingTint: Color { isDark ? Self.waitingHue.opacity(0.16) : Color(red: 1.0, green: 0.94, blue: 0.82) }
}

private struct WidgetBackground: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View { Palette(scheme).background }
}

struct SessionsEntry: TimelineEntry {
    var date: Date
    var snapshot: WidgetSnapshot
}

/// One entry from the app's latest snapshot; the app asks for a reload when sessions change,
/// and the turn timers tick by themselves (`Text(_:style: .timer)`), so no reload is spent on them.
struct SessionsProvider: TimelineProvider {
    func placeholder(in context: Context) -> SessionsEntry { SessionsEntry(date: .now, snapshot: .sample) }

    func getSnapshot(in context: Context, completion: @escaping (SessionsEntry) -> Void) {
        completion(SessionsEntry(date: .now, snapshot: context.isPreview ? .sample : (WidgetSnapshot.load() ?? .sample)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SessionsEntry>) -> Void) {
        let entry = SessionsEntry(date: .now, snapshot: WidgetSnapshot.load() ?? WidgetSnapshot(updatedAt: 0, sessions: [], todayTokens: 0, todayCost: 0))
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(15 * 60))))
    }
}

struct SessionsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Sessions", provider: SessionsProvider()) { entry in
            SessionsView(entry: entry)
                .containerBackground(for: .widget) { WidgetBackground() }
        }
        .configurationDisplayName("Agents")
        .description("Your Claude Code and Cursor agent sessions: working, waiting for you, or done.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

private struct SessionsView: View {
    var entry: SessionsEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var scheme
    private var palette: Palette { Palette(scheme) }

    var body: some View {
        let sessions = entry.snapshot.sessions
        let working = sessions.filter { $0.phase == "working" }.count
        let waiting = sessions.filter { $0.phase == "waiting" }.count
        if family == .systemSmall {
            small(working: working, waiting: waiting)
                .widgetURL(link(sessions.first { $0.phase == "waiting" } ?? sessions.first))
        } else {
            VStack(alignment: .leading, spacing: 6) {
                header(working: working, waiting: waiting)
                if sessions.isEmpty {
                    Spacer()
                    Text("No open sessions").font(.system(size: 12)).foregroundStyle(palette.ink2)
                    Spacer()
                } else {
                    ForEach(sessions.prefix(family == .systemLarge ? 6 : 3)) { row in
                        Link(destination: link(row) ?? URL(string: "ainotch://")!) { RowView(row: row) }
                    }
                    Spacer(minLength: 0)
                }
                if family == .systemLarge, entry.snapshot.todayTokens > 0 {
                    Text("Today \(tokens(entry.snapshot.todayTokens)) tokens · ≈$\(String(format: "%.2f", entry.snapshot.todayCost)) · Claude Code")
                        .font(.system(size: 10).monospacedDigit()).foregroundStyle(palette.ink3)
                }
            }
        }
    }

    private func header(working: Int, waiting: Int) -> some View {
        HStack(spacing: 6) {
            Text("Agents").font(.system(size: 13, weight: .bold)).foregroundStyle(palette.ink)
            Spacer()
            if waiting > 0 {
                Text("\(waiting) need\(waiting == 1 ? "s" : "") you").font(.system(size: 10, weight: .bold)).foregroundStyle(.black)
                    .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(Palette.waitingHue))
            }
            if working > 0 {
                Text("\(working) working").font(.system(size: 10, weight: .semibold)).foregroundStyle(palette.claude)
            }
        }
    }

    private func small(working: Int, waiting: Int) -> some View {
        let first = entry.snapshot.sessions.first { $0.phase == "waiting" } ?? entry.snapshot.sessions.first
        return VStack(alignment: .leading, spacing: 4) {
            Text("Agents").font(.system(size: 12, weight: .bold)).foregroundStyle(palette.ink2)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(working)").font(.system(size: 34, weight: .bold).monospacedDigit()).foregroundStyle(palette.claude)
                Text("working").font(.system(size: 11)).foregroundStyle(palette.ink2)
            }
            if waiting > 0 {
                Text("\(waiting) need\(waiting == 1 ? "s" : "") you").font(.system(size: 12, weight: .bold)).foregroundStyle(palette.waiting)
            }
            Spacer(minLength: 0)
            if let first {
                Text(first.title ?? first.project).font(.system(size: 11, weight: .semibold)).foregroundStyle(palette.ink).lineLimit(1)
                Text(first.title == nil ? first.detail : "\(first.project) · \(first.detail)").font(.system(size: 10)).foregroundStyle(palette.ink3).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func link(_ row: WidgetSnapshot.Row?) -> URL? {
        guard let row else { return URL(string: "ainotch://open") }
        return URL(string: "ainotch://open?session=\(row.id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? row.id)")
    }

    private func tokens(_ n: Int) -> String {
        let value = Double(n)
        if value >= 1e9 { return String(format: "%.1fB", value / 1e9) }
        if value >= 1e6 { return String(format: "%.1fM", value / 1e6) }
        if value >= 1e3 { return String(format: "%.1fK", value / 1e3) }
        return "\(n)"
    }
}

private struct RowView: View {
    var row: WidgetSnapshot.Row
    @Environment(\.colorScheme) private var scheme
    private var palette: Palette { Palette(scheme) }

    var body: some View {
        let color = row.phase == "waiting" ? palette.waiting : row.phase == "working" ? palette.claude : palette.done
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                // The chat's name first; where it runs and what it does under it.
                HStack(spacing: 5) {
                    Text(row.title ?? row.project).font(.system(size: 12, weight: .semibold)).foregroundStyle(palette.ink).lineLimit(1)
                    Text(row.isCursor ? "Cursor" : (row.model ?? "Claude")).font(.system(size: 9, weight: .medium)).foregroundStyle(palette.ink3)
                        .lineLimit(1).fixedSize()
                }
                Text(row.title == nil ? row.detail : "\(row.project) · \(row.detail)").font(.system(size: 10))
                    .foregroundStyle(row.phase == "waiting" ? palette.waiting : palette.ink2).lineLimit(1)
            }
            Spacer(minLength: 4)
            if row.phase == "working", let started = row.turnStartedAt {
                Text(Date(timeIntervalSince1970: started), style: .timer)
                    .font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(palette.claude)
                    .multilineTextAlignment(.trailing).frame(width: 52, alignment: .trailing)
            } else if row.agents > 0 {
                Text("\(row.agents) agents").font(.system(size: 10)).foregroundStyle(palette.ink3)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(row.phase == "waiting" ? palette.waitingTint : palette.card))
    }
}

@main
struct AINotchWidgets: WidgetBundle {
    var body: some Widget { SessionsWidget() }
}
