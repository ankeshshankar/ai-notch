import SwiftUI

/// What the Prod hover card adds for deploys: each linked service's verdict on its new version, the
/// errors only the new version has, the recent deploys, and Watchdog's stories. Read-only text.
struct DeployCardSections: View {
    @ObservedObject var prod: ProdStore
    private static let maxStories = 3

    var body: some View {
        let snapshot = prod.snapshot
        let now = prod.now
        VStack(alignment: .leading, spacing: 6) {
            ForEach(snapshot.deploys, id: \.service) { report in
                DeployReportView(report: report, now: now)
            }
            if !snapshot.watchdog.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    header(icon: "eye.fill", color: Palette.waiting, text: snapshot.watchdog.count == 1 ? "Watchdog · 1 story" : "Watchdog · \(snapshot.watchdog.count) stories")
                    ForEach(snapshot.watchdog.prefix(Self.maxStories), id: \.id) { story in
                        Text([story.title, story.service.flatMap { name in story.title.localizedCaseInsensitiveContains(name) ? nil : name }, story.at > 0 ? ago(max(0, now - story.at)) : nil].compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 10)).foregroundStyle(Palette.ink2).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                    let more = snapshot.watchdog.count - Self.maxStories
                    if more > 0 { Text("+\(more) more").font(.system(size: 10)).foregroundStyle(Palette.ink3) }
                }
            }
            if let note = snapshot.deployNote {
                Text("Deploy checks: \(note)").font(.system(size: 10)).foregroundStyle(Palette.ink3).fixedSize(horizontal: false, vertical: true)
            }
            if let note = snapshot.watchdogNote {
                Text("Watchdog: \(note)").font(.system(size: 10)).foregroundStyle(Palette.ink3).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func header(icon: String, color: Color, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 9)).foregroundStyle(color).frame(width: 12)
            Text(text).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Palette.ink)
        }
    }
}

/// One service: its verdict, the new errors and its deploys.
private struct DeployReportView: View {
    var report: DeployReport
    var now: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "shippingbox.fill").font(.system(size: 9)).foregroundStyle(color).frame(width: 12)
                Text(title).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Palette.ink).lineLimit(1)
            }
            if let verdict = report.verdict {
                if verdict.comparesNumbers {
                    numbers(verdict)
                } else {
                    Text(verdict.line).font(.system(size: 10)).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true)
                }
            } else if let note = report.note {
                Text(note).font(.system(size: 10)).foregroundStyle(Palette.ink3).fixedSize(horizontal: false, vertical: true)
            }
            if !report.newErrors.isEmpty {
                Text(report.sincePushAt != nil ? "New since the push:" : "New on \(DeployVerdict.name(report.version ?? "")):")
                    .font(.system(size: 10)).foregroundStyle(Palette.ink3)
                ForEach(report.newErrors, id: \.line) { error in
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Image(systemName: "exclamationmark.circle.fill").font(.system(size: 8)).foregroundStyle(Palette.waiting).frame(width: 12)
                        Text(error.line).font(.system(size: 10)).foregroundStyle(Palette.ink).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if !report.deploys.isEmpty {
                Text("Deploys").font(.system(size: 10)).foregroundStyle(Palette.ink3)
                ForEach(report.deploys.prefix(3), id: \.at) { entry in
                    Text(report.deployLine(entry, now: now)).font(.system(size: 10)).foregroundStyle(Palette.ink2).padding(.leading, 18)
                }
            }
        }
    }

    /// One line: "errors 0.4→2.1% ▲ · p95 180→210ms ▲ · 129→127/min", only the worse parts red and the
    /// better ones green.
    private func numbers(_ verdict: DeployVerdict) -> some View {
        let parts = verdict.parts
        var text = Text("")
        for (index, part) in parts.enumerated() {
            if index > 0 { text = text + Text(" · ").foregroundStyle(Palette.ink3) }
            text = text + Text(part.text).foregroundStyle(part.tone == .bad ? Palette.failed : part.tone == .good ? Palette.done : Palette.ink2)
        }
        return text.font(.system(size: 10.5)).lineLimit(1).minimumScaleFactor(0.8)
    }

    private var color: Color {
        switch report.verdict?.state {
        case .worse: return Palette.failed
        case .better: return Palette.done
        default: return Palette.ink3
        }
    }

    /// "orders · v1.4.2 vs v1.4.1 · 12m ago", "orders · since push · 14m vs 14m before", or just
    /// "orders · v1.4.2, 12m ago" before there is anything to compare.
    private var title: String {
        if let verdict = report.verdict, verdict.comparesNumbers || verdict.sinceMinutes != nil {
            let since = report.sincePushAt == nil ? report.changedAt.map { " · \(ago(max(0, now - $0)))" } ?? "" : ""
            return "\(report.service) · \(verdict.headline)\(since)"
        }
        guard let version = report.version else { return report.service }
        guard let at = report.changedAt else { return "\(report.service) · \(DeployVerdict.name(version))" }
        return "\(report.service) · \(DeployVerdict.name(version)), \(ago(max(0, now - at)))"
    }
}
