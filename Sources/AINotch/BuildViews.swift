import AppKit
import SwiftUI

/// The Pipelines section under the agents: EAS builds and Bitbucket runs that are running,
/// waiting, finished in the last few minutes, or failed since you last looked; Mine or All.
/// Each row opens its run.
struct PipelinesSection: View {
    @ObservedObject var builds: BuildStore
    var now: Double
    /// Rows the shared budget leaves for this section.
    var limit: Int
    var controller: NotchController
    /// Which part to draw: all of it (one column), or in two columns its header (in the header
    /// row) and its rows (in the right column).
    var part: Part = .all
    enum Part { case all, header, rows }
    /// The row whose steps are open, and the one whose install QR is open; one at a time.
    @State private var detailId: String?
    @State private var qrId: String?

    var body: some View {
        switch part {
        case .all:
            VStack(alignment: .leading, spacing: 8) {
                header.padding(.top, 4)
                rowList
            }
        case .header: header
        case .rows: VStack(alignment: .leading, spacing: 8) { rowList }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Pipelines").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink)
            if builds.easOn, let eas = builds.health.eas {
                DegradedBadge(text: "EAS \(eas)", help: builds.health.easDetail ?? "status.expo.dev reports a problem with EAS Build.")
            }
            if builds.bitbucketOn, let bitbucket = builds.health.bitbucket {
                DegradedBadge(text: "Bitbucket \(bitbucket)", help: builds.health.bitbucketDetail ?? "bitbucket.status.atlassian.com reports a problem.")
            }
            Spacer(minLength: 4)
            summary
            ScopeSwitch(scope: builds.prefs.scope) { builds.setScope($0) }
            FilterMenu(builds: builds)
            InfoMark(text: aboutText)
        }
    }

    @ViewBuilder private var rowList: some View {
        let rows = builds.rows
        if rows.isEmpty {
            Text(emptyText).font(.system(size: 11)).foregroundStyle(Palette.ink3)
        }
        ForEach(rows.prefix(max(1, limit))) { row in
            BuildRowButton(row: row, now: now, isDetailed: detailId == row.id, showsQR: qrId == row.id, copy: builds.copying[row.id],
                           open: { url in
                               controller.collapse()
                               builds.open(url)
                           },
                           toggleDetails: {
                               withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { detailId = detailId == row.id ? nil : row.id }
                           },
                           toggleQR: {
                               withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { qrId = qrId == row.id ? nil : row.id }
                           },
                           copyFailure: { builds.copyFailure(row) },
                           togglePin: { builds.togglePin(row.id) },
                           mute: { builds.toggleMute(row.muteKey) },
                           onlyBranch: { builds.setBranch(row.branch) })
        }
        if rows.count > max(1, limit) {
            Text("+\(rows.count - max(1, limit)) more").font(.system(size: 11)).foregroundStyle(Palette.ink3)
        }
        notes
    }

    private var emptyText: String {
        var parts: [String] = []
        if builds.prefs.scope == .mine { parts.append("Nothing of yours now") } else { parts.append("Nothing now") }
        if builds.hiddenByScope > 0 { parts.append("\(builds.hiddenByScope) in All") }
        if builds.hiddenByFilter > 0 { parts.append("\(builds.hiddenByFilter) muted or filtered") }
        if let branch = builds.prefs.branch { parts.append("branch \(branch)") }
        return parts.joined(separator: " · ")
    }

    /// The request counts and what "Mine" means, for the header's ⓘ.
    private var aboutText: String {
        var lines: [String] = []
        let bb = builds.bitbucket
        lines.append("Bitbucket requests: \(bb.requests.summary); \(bb.notModified) answered 304 (unchanged). Cap 390 an hour; Bitbucket allows 1,000.")
        if let via = builds.eas.via {
            let time = builds.eas.callSeconds.map { String(format: ", %.1f s for the last list", $0) } ?? ""
            let fallback = builds.eas.fallback.map { " GraphQL failed (\($0)); the CLI stands in for 10 minutes." } ?? ""
            lines.append("EAS via \(via)\(time), \(builds.eas.callsLastHour) GraphQL calls in the last hour.\(fallback)")
        }
        let owner = bb.owner.map { "\($0.name ?? $0.uuid ?? "?") (found by \($0.how))" } ?? "not found yet"
        lines.append("Mine: Bitbucket runs created by \(owner) — the account that pushed, or clicked Run. EAS builds linked to one of those, or started from the CLI login \(builds.eas.cliUser ?? "?"), which may be a shared account, so that match is weak. Only Mine notifies; All is for looking.")
        lines.append("Right-click a row to pin it, mute its repository, or show only its branch.")
        return lines.joined(separator: "\n\n")
    }

    /// "1 running · 1 waiting · 1 failed"; while something runs, a click opens the newest run.
    @ViewBuilder private var summary: some View {
        let queued = builds.rows.filter { $0.state == .queued }.count
        let running = builds.activeCount - queued, failed = builds.failedCount, waiting = builds.waitingCount
        let text = [running > 0 ? "\(running) running" : nil, queued > 0 ? "\(queued) queued" : nil,
                    waiting > 0 ? "\(waiting) waiting" : nil, failed > 0 ? "\(failed) failed" : nil]
            .compactMap { $0 }.joined(separator: " · ")
        if let newest = builds.newestActive {
            Button {
                controller.collapse()
                builds.open(newest.url)
            } label: {
                HStack(spacing: 4) {
                    Spinner(size: 8)
                    Text(text).font(.system(size: 11)).foregroundStyle(Palette.ink2).lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open \(newest.title) on the web")
        } else if !text.isEmpty {
            Text(text).font(.system(size: 11)).foregroundStyle(Palette.ink2).lineLimit(1)
        }
    }

    /// A source that cannot fetch, quietly, and a token about to expire.
    @ViewBuilder private var notes: some View {
        let eas = builds.easOn ? builds.eas.status : nil
        let bitbucket = builds.bitbucketOn ? builds.bitbucket.status : nil
        let expiry = !builds.bitbucketOn ? nil : builds.bitbucket.tokenExpiresAt.flatMap { $0 - now < 14 * 86_400 ? $0 : nil }
        if eas != nil || bitbucket != nil || expiry != nil {
            HStack(spacing: 12) {
                if let eas { note("EAS", eas.text, help: eas.help) }
                if let bitbucket { note("Bitbucket", bitbucket.text, help: bitbucket.help) }
                if bitbucket == nil, let expiry {
                    let days = max(0, Int((expiry - now) / 86_400))
                    note("Bitbucket", days == 0 ? "token expires today" : "token expires in \(days)d",
                         help: "The API token in the Keychain (\(BitbucketConfig.tokenService)) expires soon (the date in its comment). Create a new one with read:repository, read:pipeline, read:pullrequest and read:user; Setup lists the steps.",
                         color: Palette.waiting)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func note(_ source: String, _ text: String, help: String, color: Color = Palette.ink3) -> some View {
        HStack(spacing: 4) {
            Text("\(source) · \(text)").font(.system(size: 10)).foregroundStyle(color).lineLimit(1)
            InfoMark(text: help)
        }
    }
}

/// "EAS degraded": a status page says the service is not operational.
private struct DegradedBadge: View {
    var text: String
    var help: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 8, weight: .bold))
            Text(text).font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(Palette.waiting)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule().fill(Palette.waitingHue.opacity(0.16)))
        .lineLimit(1).fixedSize()
        .help(help)
    }
}

/// Mine | All.
private struct ScopeSwitch: View {
    var scope: PipelinePrefs.Scope
    var set: (PipelinePrefs.Scope) -> Void

    var body: some View {
        HStack(spacing: 0) {
            segment("Mine", .mine)
            segment("All", .all)
        }
        .padding(2)
        .background(Capsule().fill(Palette.chip))
        .fixedSize()
    }

    private func segment(_ title: String, _ value: PipelinePrefs.Scope) -> some View {
        Button { set(value) } label: {
            Text(title).font(.system(size: 10, weight: .semibold))
                .foregroundStyle(scope == value ? Palette.onDone : Palette.ink2)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Capsule().fill(scope == value ? Palette.ink.opacity(0.85) : Color.clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(value == .mine ? "Your own runs and builds; only these notify." : "Everyone's, for looking.")
    }
}

/// Branch filter and muted repositories.
private struct FilterMenu: View {
    @ObservedObject var builds: BuildStore

    var body: some View {
        let active = builds.prefs.branch != nil || !builds.prefs.muted.isEmpty
        Menu {
            Section("Branch") {
                Button { builds.setBranch(nil) } label: { check("All branches", builds.prefs.branch == nil) }
                ForEach(builds.branches, id: \.self) { branch in
                    Button { builds.setBranch(branch) } label: { check(branch, builds.prefs.branch == branch) }
                }
            }
            Section("Show") {
                ForEach(builds.repos, id: \.key) { repo in
                    Button { builds.toggleMute(repo.key) } label: { check(repo.name, !builds.prefs.muted.contains(repo.key)) }
                }
            }
        } label: {
            Image(systemName: active ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                .font(.system(size: 12)).foregroundStyle(active ? Palette.claude : Palette.ink2)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Filter by branch, mute a repository")
    }

    @ViewBuilder private func check(_ title: String, _ on: Bool) -> some View {
        if on { Label(title, systemImage: "checkmark") } else { Text(title) }
    }
}

/// A row and the buttons in its corner, as siblings: the row opens the run, the link badge opens
/// the other source's run, Install shows a QR for the build page, Copy failure copies what
/// failed, Details shows a run's steps.
private struct BuildRowButton: View {
    var row: BuildRow
    var now: Double
    var isDetailed: Bool
    var showsQR: Bool
    var copy: BuildStore.CopyState?
    var open: (URL) -> Void
    var toggleDetails: () -> Void
    var toggleQR: () -> Void
    var copyFailure: () -> Void
    var togglePin: () -> Void
    var mute: () -> Void
    var onlyBranch: () -> Void

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Button { open(row.url) } label: {
                BuildRowView(row: row, now: now, isDetailed: isDetailed, showsQR: showsQR)
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(RowButtonStyle())
            .help("Open on \(row.source == .eas ? "expo.dev" : "bitbucket.org")")
            .contextMenu {
                Button(row.isPinned ? "Unpin" : "Pin (always show)", action: togglePin)
                Button("Mute \(row.muteName)", action: mute)
                if let branch = row.branch { Button("Only branch \(branch)", action: onlyBranch) }
                Divider()
                Button("Open on the web") { open(row.url) }
            }

            HStack(spacing: 6) {
                if row.isPinned {
                    capsule("Pinned", icon: "pin.fill", action: togglePin)
                        .help("Pinned: always shown. Click to unpin.")
                }
                ForEach(row.links, id: \.self) { link in
                    LinkBadge(link: link, source: row.source == .eas ? .bitbucket : .eas) { open(link.url) }
                }
                if row.installURL != nil {
                    capsule(showsQR ? "Hide QR" : "Install", icon: "qrcode", action: toggleQR)
                        .help("A QR code for the build's page on expo.dev, which installs it on a device signed in to the team.")
                }
                if let docs = row.docsURL {
                    capsule("Docs", icon: "book", action: { open(docs) })
                        .help("EAS's page about this error")
                }
                if row.state == .failed {
                    capsule(copyLabel, icon: copy == .copied ? "checkmark" : "doc.on.doc", action: copyFailure)
                        .disabled(copy == .working)
                    InfoMark(text: row.source == .eas
                             ? "Copy failure copies the platform, profile, version, commit, the error code and message (with EAS's docs link when there is one), the failing phase and its last 100 log lines (read fresh from EAS), with anything that looks like a secret masked."
                             : "Copy failure copies the repo, branch, commit, run, the failed step, its failed tests when the step published a test report, and its last 100 log lines, with anything that looks like a secret masked.")
                }
                if !row.steps.isEmpty {
                    capsule(isDetailed ? "Less" : "Details", icon: isDetailed ? "chevron.up" : "chevron.down", trailingIcon: true, action: toggleDetails)
                }
            }
            .padding(8)
        }
    }

    private var copyLabel: String {
        switch copy {
        case .working: return "Copying…"
        case .copied: return "Copied"
        case .failed: return "Not copied"
        case nil: return "Copy failure"
        }
    }

    /// The Details capsule's look, for each corner button.
    private func capsule(_ text: String, icon: String, trailingIcon: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if !trailingIcon { Image(systemName: icon).font(.system(size: 8, weight: .bold)) }
                Text(text).font(.system(size: 10, weight: .medium))
                if trailingIcon { Image(systemName: icon).font(.system(size: 8, weight: .bold)) }
            }
            .foregroundStyle(Palette.ink2)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(Palette.chip))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// A pipeline or build on the other side: its number or platform, dashed when only inferred.
private struct LinkBadge: View {
    var link: BuildLink
    var source: BuildRow.Source
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "link").font(.system(size: 8, weight: .bold))
                Text(link.label).font(.system(size: 10, weight: .semibold))
                if link.inferred { Text("inferred").font(.system(size: 9)).foregroundStyle(Palette.ink3) }
            }
            .foregroundStyle(source == .bitbucket ? Palette.bitbucket : Palette.ink)
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(Capsule().fill((source == .bitbucket ? Palette.bitbucketHue : Palette.ink).opacity(0.10)))
            .overlay(Capsule().strokeBorder(style: StrokeStyle(lineWidth: 1, dash: link.inferred ? [2, 2] : []))
                .foregroundStyle((source == .bitbucket ? Palette.bitbucketHue : Palette.ink).opacity(link.inferred ? 0.5 : 0)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(link.inferred
              ? "Inferred: the same commit, started during that run. Opens it on the web."
              : source == .bitbucket ? "The Bitbucket run that started this build. Opens it on the web." : "A build this run started. Opens it on expo.dev.")
    }
}

struct BuildRowView: View {
    var row: BuildRow
    var now: Double
    var isDetailed: Bool
    var showsQR = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            SourceMark(source: row.source, platform: row.platform)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(row.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink)
                        .lineLimit(1).truncationMode(.tail)
                    if !row.isMine {
                        Image(systemName: "person.2").font(.system(size: 9)).foregroundStyle(Palette.ink3)
                            .help("Someone else's")
                    }
                    Spacer(minLength: 4)
                    StatusChip(kind: chip, now: now).fixedSize()
                        .help(chipHelp)
                }
                HStack(spacing: 6) {
                    SourceTag(source: row.source)
                    ForEach(row.chips, id: \.self) { chip in
                        Text(chip).font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.ink.opacity(0.75))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Palette.chip))
                            .lineLimit(1).truncationMode(.middle)
                    }
                    if let finished = row.finishedAt {
                        Text(ago(now - finished)).font(.system(size: 10)).foregroundStyle(Palette.ink3).lineLimit(1).fixedSize()
                    }
                }
                if row.wait == nil, let progress = row.progress, let detail = row.detail {
                    // Where it is, then the commit, on one line.
                    (Text(progress).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.claude)
                        + Text("  ·  " + detail).font(.system(size: 11)).foregroundStyle(Palette.ink2))
                        .lineLimit(1).truncationMode(.tail)
                        .help(detail)
                } else if let detail = row.detail {
                    Text(detail).font(.system(size: 11)).foregroundStyle(Palette.ink2).lineLimit(1).truncationMode(.tail)
                }
                if let wait = row.wait {
                    Label(wait.detail, systemImage: wait.label.contains("lock") ? "lock" : "hand.tap")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.waiting)
                        .lineLimit(1).truncationMode(.tail)
                } else if let progress = row.progress, row.detail == nil {
                    // With a commit, it shares the commit's line above.
                    Text(progress).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.claude)
                        .lineLimit(1).truncationMode(.tail)
                }
                if let line = row.logLine {
                    Text(line).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.ink3)
                        .lineLimit(1).truncationMode(.tail)
                }
                if let failure = row.failure {
                    Label(failure, systemImage: "xmark.octagon.fill")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.failed)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                if showsQR, let url = row.installURL { qr(url) }
                if isDetailed { steps }
                // Room for the corner's buttons.
                if hasCorner { Color.clear.frame(height: 14) }
            }
        }
        .rowCard(tint: row.isUnseen ? Palette.failedTint : Palette.card,
                 edge: row.state == .failed ? Palette.failedEdge : Palette.hairline)
    }

    private var hasCorner: Bool {
        !row.links.isEmpty || row.state == .failed || !row.steps.isEmpty || row.installURL != nil || row.isPinned || row.docsURL != nil
    }

    private var chip: StatusChip.Kind {
        switch row.state {
        case .queued: return .queued
        case .running: return .running(since: row.startedAt)
        case .paused:
            let age = row.isStale ? ago(now - row.startedAt).replacingOccurrences(of: " ago", with: "") : nil
            if case .deploymentLock = row.wait { return .held(age: age) }
            return .paused(age: age)
        case .failed: return .failed
        case .succeeded: return .passed
        case .canceled: return .canceled
        }
    }

    private var chipHelp: String {
        switch row.state {
        case .paused: return (row.wait?.detail ?? "Paused") + (row.isStale ? ". Nothing has moved for over two hours; it is checked every 15 minutes." : ".")
        case .queued, .running: return "Since it was queued"
        default: return "Finished \(ago(now - (row.finishedAt ?? now)))"
        }
    }

    /// The build page as a QR code, for a phone.
    private func qr(_ url: URL) -> some View {
        HStack(alignment: .center, spacing: 10) {
            if let image = QRCode.image(for: url, size: 92) {
                Image(nsImage: image).interpolation(.none).resizable().frame(width: 92, height: 92)
                    .padding(5).background(RoundedRectangle(cornerRadius: 6).fill(Color.white))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("Scan to install").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.ink)
                Text("Opens the build's page on expo.dev").font(.system(size: 10)).foregroundStyle(Palette.ink2)
                if let expires = row.expiresAt {
                    Text("Expires in \(max(0, Int((expires - now) / 86_400)))d").font(.system(size: 10)).foregroundStyle(Palette.ink3)
                }
            }
        }
        .padding(.top, 2)
    }

    /// A run's steps, nested like a session's subagents.
    private var steps: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(row.steps) { step in
                StepLine(step: step, now: now)
            }
        }
        .padding(.top, 2)
    }
}

private struct StepLine: View {
    var step: PipelineStep
    var now: Double

    var body: some View {
        HStack(spacing: 7) {
            icon.frame(width: 12, height: 12)
            Text(step.name).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.ink.opacity(step.state.isActive ? 0.92 : 0.65)).lineLimit(1)
            Spacer(minLength: 4)
            Text(clock).font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(step.state == .running ? Palette.claude : step.state == .failed ? Palette.failed : step.waitsForClick || step.isHalted ? Palette.waiting : Palette.ink3)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.subcard.opacity(step.state.isActive ? 1 : 0.5)))
    }

    private var clock: String {
        if step.notRun { return "not run" }
        if step.waitsForClick { return "manual" }
        if step.isHalted { return "locked" }
        guard let started = step.startedAt else { return step.state == .queued ? "waiting" : "" }
        return elapsed((step.completedAt ?? now) - started)
    }

    @ViewBuilder private var icon: some View {
        if step.notRun {
            Image(systemName: "minus.circle").resizable().foregroundStyle(Palette.ink3)
        } else if step.waitsForClick {
            Image(systemName: "hand.tap.fill").resizable().scaledToFit().foregroundStyle(Palette.waiting)
        } else if step.isHalted {
            Image(systemName: "lock.fill").resizable().scaledToFit().foregroundStyle(Palette.waiting)
        } else {
            switch step.state {
            case .running: Spinner(size: 10)
            case .queued: Image(systemName: "circle.dashed").resizable().foregroundStyle(Palette.ink3)
            case .paused: Image(systemName: "pause.circle.fill").resizable().foregroundStyle(Palette.waiting)
            case .succeeded: Image(systemName: "checkmark.circle.fill").resizable().foregroundStyle(Palette.done)
            case .failed: Image(systemName: "xmark.circle.fill").resizable().foregroundStyle(Palette.failed)
            case .canceled: Image(systemName: "stop.circle.fill").resizable().foregroundStyle(Palette.ink3)
            }
        }
    }
}

/// Which service ran it: EAS's mark (with the platform as a corner badge) or Bitbucket's.
struct SourceMark: View {
    var source: BuildRow.Source
    var platform: String?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                switch source {
                case .eas:
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(white: 0.09))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
                        .overlay(ExpoGlyph().fill(Color.white).padding(6))
                case .bitbucket:
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(LinearGradient(colors: [Color(red: 0.0, green: 0.32, blue: 0.80), Palette.bitbucketHue], startPoint: .bottomLeading, endPoint: .topTrailing))
                        .overlay(BucketGlyph().fill(Color.white, style: FillStyle(eoFill: true)).padding(5))
                }
            }
            .frame(width: 24, height: 24)

            if let platform, source == .eas {
                Group {
                    if platform == "ios" {
                        Image(systemName: "apple.logo").resizable().scaledToFit().padding(2.5).foregroundStyle(Palette.ink)
                    } else {
                        Image(systemName: "a.circle.fill").resizable().scaledToFit().foregroundStyle(Color(red: 0.24, green: 0.73, blue: 0.40))
                    }
                }
                .frame(width: 12, height: 12)
                .background(Circle().fill(Palette.badgeRing).frame(width: 15, height: 15))
                .offset(x: 4, y: 4)
                .help(platform == "ios" ? "iOS" : "Android")
            }
        }
        .frame(width: 26, height: 26)
    }
}

/// "EAS Build" or "Bitbucket" in the source's hue.
private struct SourceTag: View {
    var source: BuildRow.Source

    var body: some View {
        Text(source == .eas ? "EAS Build" : "Bitbucket")
            .font(.system(size: 10, weight: .semibold)).foregroundStyle(source == .eas ? Palette.ink.opacity(0.8) : Palette.bitbucket)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill((source == .eas ? Palette.ink : Palette.bitbucketHue).opacity(source == .eas ? 0.08 : 0.16)))
            .lineLimit(1).fixedSize()
    }
}

/// Expo's chevron, simplified: a caret over a short bar.
private struct ExpoGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width, h = rect.height
        path.move(to: CGPoint(x: rect.minX + w * 0.5, y: rect.minY + h * 0.08))
        path.addLine(to: CGPoint(x: rect.minX + w * 0.98, y: rect.minY + h * 0.86))
        path.addLine(to: CGPoint(x: rect.minX + w * 0.78, y: rect.minY + h * 0.86))
        path.addLine(to: CGPoint(x: rect.minX + w * 0.5, y: rect.minY + h * 0.40))
        path.addLine(to: CGPoint(x: rect.minX + w * 0.22, y: rect.minY + h * 0.86))
        path.addLine(to: CGPoint(x: rect.minX + w * 0.02, y: rect.minY + h * 0.86))
        path.closeSubpath()
        return path
    }
}

/// Bitbucket's bucket, simplified: a tapered pail with a notch.
private struct BucketGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width, h = rect.height
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + h * 0.08))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + h * 0.08))
        path.addLine(to: CGPoint(x: rect.minX + w * 0.84, y: rect.maxY - h * 0.06))
        path.addLine(to: CGPoint(x: rect.minX + w * 0.16, y: rect.maxY - h * 0.06))
        path.closeSubpath()
        // The notch, cut out (even-odd).
        path.move(to: CGPoint(x: rect.minX + w * 0.36, y: rect.minY + h * 0.36))
        path.addLine(to: CGPoint(x: rect.minX + w * 0.64, y: rect.minY + h * 0.36))
        path.addLine(to: CGPoint(x: rect.minX + w * 0.59, y: rect.minY + h * 0.66))
        path.addLine(to: CGPoint(x: rect.minX + w * 0.41, y: rect.minY + h * 0.66))
        path.closeSubpath()
        return path
    }
}
