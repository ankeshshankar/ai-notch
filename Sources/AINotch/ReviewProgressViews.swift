import ReviewCore
import SwiftUI

// The live review view: a pipeline strip, one tile per reviewer, a map of the changed files, an activity graph and
// counters for the findings. Every moving part follows real work: a ring pulses only while a reviewer's session
// is open, a square fills when a session opens that file, and the graph is the tool calls of the run. Frozen
// means nothing happened, and after a minute the view says so in words. Reduce Motion turns the pulses into
// still marks. Colour is never the only sign: every colour has a mark or a word beside it.

enum ReviewTone {
    static func severity(_ s: FindingSeverity) -> Color {
        switch s {
        case .blocking: return Palette.failed
        case .shouldFix: return Palette.waiting
        case .preExisting: return Palette.mcp
        case .nit: return Palette.ink3
        }
    }

    static func symbol(_ s: FindingSeverity) -> String {
        switch s {
        case .blocking: return "xmark.octagon.fill"
        case .shouldFix: return "exclamationmark.triangle.fill"
        case .preExisting: return "clock.arrow.circlepath"
        case .nit: return "circle.dotted"
        }
    }
}

struct ReviewProgressPanel: View {
    var progress: ReviewProgress
    /// When the run began; nil when unknown.
    var since: Double?
    /// The run ended without a result (failed, stopped, timed out): the step it reached is marked.
    var stopped: Bool = false
    var compact = false
    /// Dev replay of a finished run: the moment it is read at.
    var fixedNow: Double? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PipelineStrip(steps: progress.steps, stopped: stopped)
            if !progress.reviewers.isEmpty, progress.steps.first(where: { $0.id == "reviewers" })?.state != .pending {
                ReviewerTiles(rows: progress.tiles, stopped: stopped)
            }
            if !progress.fileMap.isEmpty { FileMapView(cells: progress.fileMap, reported: progress.filesReported, stopped: stopped) }
            if !stopped { liveBlock }
            else if let step = progress.current {
                Text("Stopped at: \(step.title)" + (step.id == "reviewers" ? " · \(progress.reviewersDone) of \(progress.reviewersTotal) reviewers done" : ""))
                    .font(Typo.label(.medium)).foregroundStyle(Palette.failed)
            }
            if progress.reviewersTotal > 0 { FindingCounters(findings: progress.liveFindings, checked: progress.checked) }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.panel))
    }

    /// The parts that depend on the clock: the "Now" line, the notice and the graph. One tick a second.
    private var liveBlock: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = fixedNow ?? context.date.timeIntervalSince1970
            let notice = progress.notice(now: now, since: since)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("Now").font(Typo.label(.semibold)).foregroundStyle(Palette.ink3)
                    Text(notice == .closing ? "Every step is done; waiting for the run to close" + (since.map { " · " + ReviewProgress.clock(now - $0) } ?? "")
                         : progress.nowLine(elapsed: since.map { now - $0 })).font(Typo.label()).foregroundStyle(Palette.ink2).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let beat = progress.heartbeat(now: now) { HeartbeatGraph(beat: beat, notice: notice) }
                else if let notice { NoticeLine(notice: notice) }
            }
        }
    }
}

// MARK: Pipeline strip

struct PipelineStrip: View {
    var steps: [ReviewStepRow]
    var stopped: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                    column(step, index: index)
                }
            }
            if let detail { Text(detail).font(Typo.label()).foregroundStyle(Palette.ink3).lineLimit(2).fixedSize(horizontal: false, vertical: true) }
        }
    }

    /// The running step's detail; the newest finished step's when it has none yet.
    private var detail: String? {
        if let step = steps.first(where: { $0.state == .current }), let fact = step.fact { return "\(step.title): \(fact)" }
        if let step = steps.last(where: { $0.state == .done && $0.fact != nil }), let fact = step.fact { return "\(step.title): \(fact)" }
        return nil
    }

    private func column(_ step: ReviewStepRow, index: Int) -> some View {
        let reached = step.state != .pending
        let tone: Color = step.state == .done ? Palette.done : stopped ? Palette.failed : Palette.claude
        return VStack(spacing: 4) {
            ZStack {
                HStack(spacing: 0) {
                    Rectangle().fill(reached ? Palette.done.opacity(0.7) : Palette.ink3.opacity(0.3)).frame(height: 2).opacity(index == 0 ? 0 : 1)
                    Rectangle().fill(step.state == .done ? Palette.done.opacity(0.7) : Palette.ink3.opacity(0.3)).frame(height: 2).opacity(index == steps.count - 1 ? 0 : 1)
                }
                dot(step, tone: tone)
            }
            .frame(height: 20)
            Text(step.title).font(Typo.label(step.state == .current ? .semibold : .medium))
                .foregroundStyle(step.state == .pending ? Palette.ink3 : Palette.ink).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .help(step.title + ": " + (step.fact ?? (step.state == .pending ? "not started" : step.state == .current ? "in progress" : "done")))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(step.title)
        .accessibilityValue((step.state == .done ? "Done" : step.state == .current ? (stopped ? "Stopped" : "In progress") : "Not started") + (step.fact.map { ". \($0)" } ?? ""))
    }

    @ViewBuilder private func dot(_ step: ReviewStepRow, tone: Color) -> some View {
        switch step.state {
        case .done:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 15)).foregroundStyle(tone).background(Circle().fill(Palette.panel))
        case .current:
            ZStack {
                if stopped {
                    Image(systemName: "exclamationmark.circle.fill").font(.system(size: 15)).foregroundStyle(tone)
                } else {
                    Circle().fill(Palette.panel).frame(width: 18, height: 18)
                    LoopLayer(kind: .ring(lineWidth: 2), color: Palette.claudeNS, animated: !Motion.reduce).frame(width: 18, height: 18)
                    Circle().fill(tone).frame(width: 8, height: 8)
                }
            }
        case .pending:
            Circle().strokeBorder(Palette.ink3.opacity(0.6), lineWidth: 1.5).background(Circle().fill(Palette.panel)).frame(width: 11, height: 11)
        }
    }
}

// MARK: Reviewer tiles

struct ReviewerTiles: View {
    var rows: [ReviewerRowInfo]
    var stopped: Bool

    var body: some View {
        let compact = rows.count > 9
        LazyVGrid(columns: [GridItem(.adaptive(minimum: compact ? 124 : 150), spacing: 6, alignment: .top)], alignment: .leading, spacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in ReviewerTile(row: row, stopped: stopped, compact: compact) }
        }
    }
}

struct ReviewerTile: View {
    var row: ReviewerRowInfo
    var stopped: Bool
    var compact: Bool

    private var working: Bool { row.state == .running && !stopped }

    private var detail: String {
        let second = row.pass > 1 ? "Second pass" : nil
        let text: String
        switch row.state {
        case .waiting: text = "Waiting"
        case .running: text = stopped ? "Stopped" : row.doing.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "Working"
        case .done: text = (row.findings?.total ?? 0) == 0 ? "No findings" : "\(row.findings!.total) finding\(row.findings!.total == 1 ? "" : "s")"
        case .failed: text = "No report"
        }
        switch row.state {
        case .waiting: return second.map { "\($0), waiting" } ?? text
        case .running: return second.map { "\($0): \(text.prefix(1).lowercased() + text.dropFirst())" } ?? text
        case .done: return second.map { "\($0): \(text.prefix(1).lowercased() + text.dropFirst())" } ?? text
        case .failed: return second.map { "\($0): \(text.lowercased())" } ?? text
        }
    }

    private var tooltip: String {
        var lines = [row.title + (row.pass > 1 ? " (second pass)" : "")]
        switch row.state {
        case .waiting: lines.append("Waiting to start")
        case .running: lines.append(row.doing.map { "Working: \($0)" } ?? "Working"); lines.append("\(row.filesRead) of \(row.filesGiven) files opened")
        case .done: lines.append("\(row.filesReported ?? 0) of \(row.filesGiven) files reported · \(row.findings?.text ?? "none")")
        case .failed: lines.append("The reviewer stopped without writing its report")
        }
        return lines.joined(separator: "\n")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            indicator.frame(width: 14, height: 14).padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.shortTitle).font(Typo.label(.semibold)).foregroundStyle(row.state == .waiting ? Palette.ink3 : Palette.ink).lineLimit(1)
                Text(detail).font(Typo.label()).foregroundStyle(row.state == .failed ? Palette.failed : working ? Palette.ink2 : Palette.ink3)
                    .lineLimit(compact ? 1 : 2).truncationMode(.middle).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 7).padding(.vertical, 5)
        .frame(maxWidth: .infinity, minHeight: compact ? 34 : 40, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Palette.card.opacity(row.state == .waiting ? 0.5 : 1)))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(border, lineWidth: working ? 1 : 0.5))
        .opacity(row.state == .waiting ? 0.6 : 1)
        .help(tooltip)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.title + (row.pass > 1 ? ", second pass" : ""))
        .accessibilityValue(detail)
    }

    private var border: Color {
        switch row.state {
        case .running: return stopped ? Palette.ink3.opacity(0.4) : Palette.claude.opacity(0.7)
        case .done: return Palette.done.opacity(0.45)
        case .failed: return Palette.failed.opacity(0.7)
        case .waiting: return Palette.ink3.opacity(0.3)
        }
    }

    @ViewBuilder private var indicator: some View {
        switch row.state {
        case .waiting: Circle().strokeBorder(Palette.ink3.opacity(0.6), lineWidth: 1.2).frame(width: 9, height: 9).frame(width: 14, height: 14)
        case .running:
            ZStack {
                LoopLayer(kind: .ring(lineWidth: 1.8), color: stopped ? NSColor.secondaryLabelColor : Palette.claudeNS, animated: working && !Motion.reduce)
                Circle().fill(stopped ? Palette.ink3 : Palette.claude).frame(width: 4, height: 4)
            }
        case .done: Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(Palette.done)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(Palette.failed)
        }
    }
}

// MARK: File map

struct FileMapView: View {
    var cells: [ReviewFileCell]
    var reported: Int
    var stopped: Bool
    @State private var width: Double = 0
    @State private var hovered: Int?

    private var grid: ReviewFileGrid { ReviewFileGrid.layout(width: width, count: cells.count) }
    private var reading: Int { cells.filter { $0.state == .reading }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(reported) of \(cells.count) files").font(Typo.label(.semibold)).foregroundStyle(Palette.ink2)
                Text(reading > 0 && !stopped ? "checked, \(reading) being read" : "checked").font(Typo.label()).foregroundStyle(Palette.ink3)
                InfoMark(text: "One square per changed file. It fills when a reviewer opens the file, turns solid when a reviewer's report lists it, and takes a colour when a finding lands on it. Hover a square for the path and who read it.")
                Spacer(minLength: 0)
            }
            canvas
            Text(hovered.map { cells[$0].tooltip.replacingOccurrences(of: "\n", with: " · ") } ?? legendHint)
                .font(Typo.label()).foregroundStyle(Palette.ink3).lineLimit(2).truncationMode(.middle)
                .frame(maxWidth: .infinity, minHeight: 24, alignment: .topLeading)
            legend
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("File map")
        .accessibilityValue("\(reported) of \(cells.count) files checked, \(reading) being read")
    }

    private var legendHint: String { "Hover a square for its path and who read it." }

    private var canvas: some View {
        let g = grid
        return Canvas { context, _ in
            for (i, cell) in cells.enumerated() {
                let x = Double(i % max(g.columns, 1)) * (g.cell + g.gap), y = Double(i / max(g.columns, 1)) * (g.cell + g.gap)
                let rect = CGRect(x: x, y: y, width: g.cell, height: g.cell)
                let path = Path(roundedRect: rect, cornerRadius: min(3, g.cell / 4))
                context.fill(path, with: .color(fill(cell)))
                if cell.state == .reading { context.stroke(path, with: .color(Palette.claude), lineWidth: 1) }
                if let severity = cell.severity, g.cell >= 9 {
                    // A mark inside as well as the colour: bars for blocking, a dot for should-fix, nothing for the rest.
                    let c = CGPoint(x: rect.midX, y: rect.midY)
                    if severity == .blocking { context.fill(Path(CGRect(x: c.x - g.cell * 0.28, y: c.y - 1, width: g.cell * 0.56, height: 2)), with: .color(.white)) }
                    else if severity == .shouldFix { context.fill(Path(ellipseIn: CGRect(x: c.x - 1.5, y: c.y - 1.5, width: 3, height: 3)), with: .color(.white)) }
                }
            }
        }
        .frame(height: g.height)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: Double.self) { Double($0.size.width) } action: { width = $0 }
        .onContinuousHover { phase in
            switch phase {
            case .active(let point): hovered = grid.index(x: point.x, y: point.y, count: cells.count)
            case .ended: hovered = nil
            }
        }
        .help(hovered.map { cells[$0].tooltip } ?? "")
    }

    private func fill(_ cell: ReviewFileCell) -> Color {
        if let severity = cell.severity { return ReviewTone.severity(severity) }
        switch cell.state {
        case .unread: return Palette.ink3.opacity(0.22)
        case .reading: return Palette.claude.opacity(0.35)
        case .reported: return Palette.done.opacity(0.85)
        }
    }

    private var legend: some View {
        let present = FindingSeverity.allCases.reversed().filter { s in cells.contains { $0.severity == s } }
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 6, alignment: .leading)], alignment: .leading, spacing: 2) {
            swatch(Palette.ink3.opacity(0.22), "Not read")
            swatch(Palette.claude.opacity(0.35), "Being read")
            swatch(Palette.done.opacity(0.85), "Checked")
            ForEach(present, id: \.self) { swatch(ReviewTone.severity($0), $0.words.prefix(1).uppercased() + $0.words.dropFirst()) }
        }
    }

    private func swatch(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text(text).font(Typo.label()).foregroundStyle(Palette.ink3).lineLimit(1)
        }
    }
}

// MARK: Heartbeat

struct HeartbeatGraph: View {
    var beat: ReviewHeartbeat
    var notice: ReviewNotice?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text("Activity").font(Typo.label(.semibold)).foregroundStyle(Palette.ink3)
                Text("\(beat.total) step\(beat.total == 1 ? "" : "s") in the last 5 minutes").font(Typo.label()).foregroundStyle(Palette.ink3)
                InfoMark(text: "Each bar is five seconds of tool calls by the main session and every reviewer; the right edge is now. A flat line for a minute or more means nothing is happening.")
                Spacer(minLength: 0)
                if let notice { NoticeLine(notice: notice) }
            }
            Canvas { context, size in
                let n = beat.counts.count
                guard n > 0 else { return }
                let step = size.width / Double(n)
                let peak = Double(max(beat.peak, 1))
                // A baseline, so a flat line reads as flat and not as missing.
                context.fill(Path(CGRect(x: 0, y: size.height - 1, width: size.width, height: 1)), with: .color(Palette.ink3.opacity(0.35)))
                for (i, count) in beat.counts.enumerated() where count > 0 {
                    let h = max(2, (size.height - 2) * Double(count) / peak)
                    let rect = CGRect(x: Double(i) * step + 0.5, y: size.height - 1 - h, width: max(1, step - 1), height: h)
                    context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(Palette.claude.opacity(0.35 + 0.65 * Double(i) / Double(n))))
                }
            }
            .frame(height: 26)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Activity over the last 5 minutes")
            .accessibilityValue(notice?.text ?? "\(beat.total) steps")
        }
    }
}

struct NoticeLine: View {
    var notice: ReviewNotice

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: notice == .closing ? "checkmark.seal" : "pause.circle").font(Typo.label(.semibold)).decorative()
            Text(notice.text).font(Typo.label(.semibold))
        }
        .foregroundStyle(notice == .closing ? Palette.done : Palette.waiting)
    }
}

// MARK: Finding counters

struct FindingCounters: View {
    var findings: ReportedFindings
    var checked: Bool

    private var rows: [(FindingSeverity, Int, String)] {
        [(.blocking, findings.blocking, "blocking"), (.shouldFix, findings.shouldFix, "should fix"),
         (.preExisting, findings.preExisting, "was already there"), (.nit, findings.nits, "nit")]
    }

    var body: some View {
        HStack(spacing: 5) {
            ForEach(rows, id: \.0) { severity, count, word in chip(severity, count, word) }
            if !checked && findings.total > 0 {
                Text("not yet checked").font(Typo.label(.medium)).foregroundStyle(Palette.waiting)
                InfoMark(text: "What the reviewers wrote so far. The final check re-opens each one in the code and drops what it cannot confirm; only what it keeps becomes a comment.")
            }
            Spacer(minLength: 0)
        }
    }

    private func chip(_ severity: FindingSeverity, _ count: Int, _ word: String) -> some View {
        let tone = count > 0 ? ReviewTone.severity(severity) : Palette.ink3
        return HStack(spacing: 3) {
            Image(systemName: ReviewTone.symbol(severity)).font(.system(size: 9)).decorative()
            Text("\(count)").font(Typo.label(.semibold)).contentTransition(.numericText())
            Text(word).font(Typo.label())
        }
        .foregroundStyle(tone)
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(Capsule().fill(tone.opacity(count > 0 ? 0.14 : 0.07)))
        .opacity(count > 0 ? 1 : 0.7)
        .animation(Motion.reduce ? nil : .snappy(duration: 0.25), value: count)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(count) \(word)")
    }
}
