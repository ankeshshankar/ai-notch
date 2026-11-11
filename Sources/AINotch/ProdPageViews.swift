import SwiftUI

// The Prod page: opened by the Prod chip. Now (state, what is open), Performance (each health
// number with a sparkline over the range) and Timeline (what happened, newest first). Data is
// ProdPage.swift; what is read, and how often, ProdPageSource.swift. Nothing here animates.

struct ProdPanel: View {
    @ObservedObject var prod: ProdStore
    @ObservedObject private var page: ProdPageModel

    init(prod: ProdStore) {
        self.prod = prod
        page = prod.page
    }

    private var site: String { prod.snapshot.site }

    var body: some View {
        let range = page.range
        let connected = prod.snapshot.access == .ok
        VStack(alignment: .leading, spacing: 8) {
            header(range)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 10) {
                    nowSection
                    if connected { performance(range) }
                    timeline(range)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 300)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .panelCard()
        .onAppear { page.setOpen(true) }
        .onDisappear { page.setOpen(false) }
    }

    // MARK: Header

    private func header(_ range: ProdRange) -> some View {
        HStack(spacing: 6) {
            Text("Prod").font(Typo.label(.semibold)).foregroundStyle(Palette.ink2)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Capsule().fill(Palette.chip))
            HStack(spacing: 2) {
                ForEach(ProdRange.allCases, id: \.self) { option in
                    Button { page.setRange(option) } label: {
                        Text(option.label).font(Typo.label(.medium).monospacedDigit())
                            .foregroundStyle(option == range ? Palette.ink : Palette.ink3)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Capsule().fill(option == range ? Palette.chip : .clear))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Show \(option.words)")
                    .accessibilityLabel(option.label)
                    .accessibilityAddTraits(option == range ? [.isSelected, .isButton] : .isButton)
                }
            }
            InfoMark(text: "Alerts, incidents, deploys and Watchdog stories from Datadog (the monitor search's last trigger, monitor alert events, the incident search, deployment and Watchdog events), plus what this app saw itself: kept for 7 days, 300 entries, in ~/.claude/notch/prod-history.json. Read about every minute only while this page is open.")
            Spacer(minLength: 6)
            small("Datadog") { prod.open() }
            small(prod.isSnoozed ? "Unsnooze" : "Snooze 1 h") { prod.isSnoozed ? prod.unsnooze() : prod.snooze() }
            small("Setup") { SetupWindowController.shared.show(focus: .prod) }
        }
    }

    private func small(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(Typo.label(.medium)).foregroundStyle(Palette.ink2)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(Palette.chip))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: Now

    private var nowSection: some View {
        let snapshot = prod.snapshot
        let level = prod.level
        return VStack(alignment: .leading, spacing: 4) {
            sectionTitle("Now")
            HStack(spacing: 6) {
                Circle().fill(ProdChip.color(level)).frame(width: 7, height: 7)
                Text(headline).font(Typo.body(.semibold)).foregroundStyle(Palette.ink)
                Spacer(minLength: 8)
                if snapshot.monitorsAt > 0, prod.greyReason == nil {
                    Text(ago(prod.now - snapshot.monitorsAt)).font(Typo.label()).foregroundStyle(Palette.ink3)
                }
            }
            .accessibilityElement(children: .combine)
            if let problem = problemText { Text(problem).font(Typo.label()).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true) }
            if prod.greyReason == nil {
                ForEach(snapshot.incidents.prefix(4), id: \.id) { incident in
                    openLine(icon: "flame.fill", color: Palette.failed, text: ProdStore.incidentLine(incident), kind: "Incident",
                             url: DatadogConfig.incidentURL(site: site, incident: incident))
                }
                ForEach(snapshot.monitors.prefix(max(0, 6 - min(4, snapshot.incidents.count))), id: \.id) { monitor in
                    let alert = monitor.status == "Alert"
                    openLine(icon: alert ? "exclamationmark.triangle.fill" : monitor.status == "Warn" ? "exclamationmark.circle.fill" : "questionmark.circle",
                             color: alert ? Palette.failed : monitor.status == "Warn" ? Palette.waiting : Palette.ink3,
                             text: alert ? monitor.name : "\(monitor.name) · \(monitor.status)", kind: "Monitor \(monitor.status)",
                             url: DatadogConfig.monitorURL(site: site, id: monitor.id))
                }
            }
        }
    }

    private var headline: String {
        if let grey = prod.greyReason { return grey }
        let snapshot = prod.snapshot
        switch prod.level {
        case .alert, .warn:
            let words = ProdChip.words(level: prod.level, snapshot: snapshot)
            let numbers = snapshot.numbers.filter(\.isOver).map { "\($0.label) high" }
            return ([words].compactMap { $0 } + numbers).joined(separator: " · ")
        default:
            switch snapshot.monitorTotal {
            case 0: return "No monitors"
            case 1: return "1 monitor OK"
            default: return "All \(snapshot.monitorTotal) monitors OK"
            }
        }
    }

    /// What is wrong, in words, and what to do.
    private var problemText: String? {
        switch prod.snapshot.access {
        case .notConfigured: return "Prod is not set up. Add a datadog part to builds.json; Setup shows how."
        case .noKeys: return "Not signed in to Datadog. Open Setup and sign in."
        case .signInAgain(let why): return why + " Open Setup and sign in again."
        case .rejected(let why): return why
        case .ok: return prod.snapshot.problem.map { "\($0.text.capitalizedFirst): \($0.help)" }
        }
    }

    private func openLine(icon: String, color: Color, text: String, kind: String, url: URL?) -> some View {
        Button { SafeLink.open(url, for: .datadog) } label: {
            HStack(spacing: 6) {
                Image(systemName: icon).font(Typo.label()).foregroundStyle(color).frame(width: 14)
                Text(text).font(Typo.body()).foregroundStyle(Palette.ink).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open in Datadog")
        .accessibilityLabel("\(kind): \(text)")
        .accessibilityHint("Opens in Datadog")
    }

    // MARK: Performance

    private func performance(_ range: ProdRange) -> some View {
        let data = page.data
        let numbers = prod.snapshot.numbers
        let shown = data.range == range ? data.series : []
        return VStack(alignment: .leading, spacing: 4) {
            sectionTitle("Performance", note: "over \(range.words)")
            if numbers.isEmpty && shown.isEmpty {
                Text("No health numbers set up. Add health items to the datadog part of builds.json.").font(Typo.label()).foregroundStyle(Palette.ink3)
            } else if shown.isEmpty {
                if let note = data.notes["series"] { Text(note).font(Typo.label()).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true) }
                // Current values from the poll, while the series loads.
                ForEach(numbers, id: \.label) { number in
                    HStack(spacing: 8) {
                        Text(number.label).font(Typo.body()).foregroundStyle(Palette.ink2)
                        Text(number.valueText).font(Typo.body(.semibold).monospacedDigit()).foregroundStyle(number.isOver ? Palette.waiting : Palette.ink)
                        Spacer(minLength: 0)
                        if data.notes["series"] == nil { Text("Loading…").font(Typo.label()).foregroundStyle(Palette.ink3) }
                    }
                }
            } else {
                ForEach(shown, id: \.label) { series in seriesRow(series, current: numbers.first { $0.label == series.label }?.value) }
                if let note = data.notes["series"] { Text(note).font(Typo.label()).foregroundStyle(Palette.ink3) }
            }
        }
    }

    private func seriesRow(_ series: ProdSeries, current: Double?) -> some View {
        let value = series.last ?? current
        let level = series.level(value)
        let color: Color = level == .red ? Palette.failed : level == .amber ? Palette.waiting : Palette.ink
        return HStack(spacing: 8) {
            Text(series.label).font(Typo.body()).foregroundStyle(Palette.ink2).frame(width: 60, alignment: .leading).lineLimit(1)
            Text(series.text(value)).font(Typo.body(.semibold).monospacedDigit()).foregroundStyle(color).frame(width: 52, alignment: .trailing)
            if series.values.count >= 2 {
                Sparkline(values: series.spark(buckets: 60), amber: series.amber, color: level == .ok ? Palette.ink2 : color)
                    .frame(height: 20)
                    .accessibilityHidden(true)
                Text(extent(series)).font(Typo.label().monospacedDigit()).foregroundStyle(Palette.ink3).lineLimit(1)
                    .frame(width: 150, alignment: .trailing)
            } else {
                Text(series.note ?? "no data").font(Typo.label()).foregroundStyle(Palette.ink3).lineLimit(1)
                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(series.label) \(series.text(value))\(level == .ok ? "" : level == .red ? ", well over its line" : ", over its line")")
        .accessibilityValue(series.values.count >= 2 ? "lowest \(series.text(series.minimum)), highest \(series.text(series.maximum)), \(series.changeText ?? "")" : series.note ?? "")
    }

    private func extent(_ series: ProdSeries) -> String {
        let range = "\(series.text(series.minimum))–\(series.text(series.maximum))"
        return series.changeText.map { "\(range) · \($0)" } ?? range
    }

    // MARK: Timeline

    private func timeline(_ range: ProdRange) -> some View {
        let now = prod.now
        let entries = page.timeline(now: now, current: [])
        let data = page.data
        let connected = prod.snapshot.access == .ok
        let loading = connected && data.remoteAt == 0 && data.notes.isEmpty
        return VStack(alignment: .leading, spacing: 3) {
            sectionTitle("Timeline", note: "newest first")
            ForEach(["alerts", "events"], id: \.self) { part in
                if let note = data.notes[part] {
                    Text("\(part == "alerts" ? "Alerts" : "Watchdog and deploys"): \(note)").font(Typo.label()).foregroundStyle(Palette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if entries.isEmpty {
                Text(loading ? "Loading…" : connected ? "Nothing happened in \(range.words)." : "Nothing recorded in \(range.words). Connect Datadog to see its history.").font(Typo.label()).foregroundStyle(Palette.ink3)
            } else {
                ForEach(entries, id: \.id) { entry in row(entry, now: now) }
            }
        }
    }

    private func row(_ entry: ProdTimelineEntry, now: Double) -> some View {
        let style = Self.style(entry.kind)
        let time = ProdTimeline.timeText(entry.at, now: now)
        let url = entry.url(site: site, query: prod.snapshot.monitorQuery)
        return Button { SafeLink.open(url, for: .datadog) } label: {
            HStack(spacing: 6) {
                Text(time).font(Typo.label().monospacedDigit()).foregroundStyle(Palette.ink3).frame(width: 52, alignment: .leading)
                Image(systemName: style.icon).font(Typo.label()).foregroundStyle(style.color).frame(width: 14)
                Text(entry.title).font(Typo.body()).foregroundStyle(Palette.ink).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                if let detail = entry.detail { Text(detail).font(Typo.label()).foregroundStyle(Palette.ink3).lineLimit(1) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(url == nil ? time : "Open in Datadog")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(time), \(style.word): \(entry.title)")
        .accessibilityHint(url == nil ? "" : "Opens in Datadog")
    }

    static func style(_ kind: ProdTimelineEntry.Kind) -> (icon: String, color: Color, word: String) {
        switch kind {
        case .alert: return ("exclamationmark.triangle.fill", Palette.failed, "Alert")
        case .warn: return ("exclamationmark.circle.fill", Palette.waiting, "Warning")
        case .recovered: return ("checkmark.circle.fill", Palette.done, "Recovered")
        case .incidentOpened: return ("flame.fill", Palette.failed, "Incident opened")
        case .incidentResolved: return ("checkmark.seal.fill", Palette.done, "Incident resolved")
        case .deploy: return ("shippingbox.fill", Palette.ink2, "Deploy")
        case .watchdog: return ("eye.fill", Palette.mcp, "Watchdog")
        }
    }

    private func sectionTitle(_ title: String, note: String? = nil) -> some View {
        HStack(spacing: 6) {
            Text(title).font(Typo.label(.semibold)).foregroundStyle(Palette.ink2)
            if let note { Text(note).font(Typo.label()).foregroundStyle(Palette.ink3) }
        }
        .accessibilityAddTraits(.isHeader)
    }
}

/// A static line over the range: no animation, drawn once per change. A dashed line at the
/// number's amber threshold when it falls in the drawn span.
private struct Sparkline: View {
    var values: [Double]
    var amber: Double?
    var color: Color

    /// The drawn span: the values, widened to the threshold when that is near them.
    private var span: (low: Double, high: Double) {
        let low = values.min() ?? 0, high = values.max() ?? 1
        guard let amber, amber <= high * 1.5 else { return (low, high) }
        return (min(low, amber), max(high, amber))
    }

    private func point(_ index: Int, _ value: Double, _ size: CGSize) -> CGPoint {
        let span = span
        let height = max(span.high - span.low, 1e-9)
        return CGPoint(x: values.count > 1 ? size.width * Double(index) / Double(values.count - 1) : 0,
                       y: size.height - 2 - (size.height - 4) * (value - span.low) / height)
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                if let amber, amber >= span.low, amber <= span.high {
                    Path { path in
                        let y = point(0, amber, size).y
                        path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y))
                    }
                    .stroke(Palette.waiting.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                }
                Path { path in
                    for (index, value) in values.enumerated() {
                        index == 0 ? path.move(to: point(index, value, size)) : path.addLine(to: point(index, value, size))
                    }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                if let last = values.last {
                    Circle().fill(color).frame(width: 4, height: 4).position(point(values.count - 1, last, size))
                }
            }
        }
    }
}
