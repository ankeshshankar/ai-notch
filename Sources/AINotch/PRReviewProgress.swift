import NotchCore
import ReviewCore
import SwiftUI

// The live view of a review that is running: its steps, one row per reviewer, and what it is doing now. Read from
// the review's folder (and the session file the notch's hook keeps) every two seconds on a utility queue; nothing
// is polled while no view shows it, and nothing here can post. What a reviewer wrote before the final check is
// labelled "not yet checked" and is never a card.

/// Polls the watched folders. One timer, on a utility queue, alive only while something is watched.
final class ReviewProgressPoller: @unchecked Sendable {
    struct Watch: Sendable {
        var folder: URL
        var kind: ReviewRunKind
        var title: String
        var since: Double
        var users = 1
    }

    static let interval: Double = 2

    private let lock = NSLock()
    private var watches: [String: Watch] = [:]
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "ai-notch.review-progress", qos: .utility)
    private let sessions: URL
    private let deliver: @Sendable ([String: ReviewProgress]) -> Void

    init(sessions: URL = NotchPaths.sessions, deliver: @escaping @Sendable ([String: ReviewProgress]) -> Void) {
        self.sessions = sessions
        self.deliver = deliver
    }

    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return timer != nil }
    var watchedKeys: Set<String> { lock.lock(); defer { lock.unlock() }; return Set(watches.keys) }

    func retain(key: String, _ watch: Watch) {
        lock.lock()
        if var existing = watches[key] { existing.users += 1; watches[key] = existing }
        else { watches[key] = watch }
        if timer == nil {
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: Self.interval, leeway: .milliseconds(300))
            t.setEventHandler { [weak self] in self?.tick() }
            timer = t
            t.resume()
        }
        lock.unlock()
    }

    func release(key: String) {
        lock.lock()
        if var existing = watches[key] {
            existing.users -= 1
            if existing.users <= 0 { watches[key] = nil } else { watches[key] = existing }
        }
        if watches.isEmpty { timer?.cancel(); timer = nil }
        lock.unlock()
    }

    /// One read of a folder that is not running any more (a failed or stopped run): what step it reached.
    func readOnce(key: String, _ watch: Watch) {
        queue.async { [deliver] in deliver([key: ReviewProgress.read(folder: watch.folder, kind: watch.kind)]) }
    }

    private func tick() {
        lock.lock(); let current = watches; lock.unlock()
        guard !current.isEmpty else { return }
        deliver(Self.compute(current, sessions: sessions))
    }

    /// Dev and tests: the same read, on this thread.
    static func compute(_ watches: [String: Watch], sessions: URL) -> [String: ReviewProgress] {
        let oldest = watches.values.map(\.since).min() ?? 0
        var files: [Data] = []
        let fm = FileManager.default
        for url in (try? fm.contentsOfDirectory(at: sessions, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] where url.pathExtension == "json" {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0
            guard modified >= oldest - 5, let data = try? Data(contentsOf: url) else { continue }
            files.append(data)
        }
        var out: [String: ReviewProgress] = [:]
        for (key, watch) in watches {
            let activity = ReviewActivity.parse(files, title: watch.title, since: watch.since)
            out[key] = ReviewProgress.read(folder: watch.folder, kind: watch.kind, activity: activity)
        }
        return out
    }
}

@MainActor
final class ReviewProgressCenter: ObservableObject {
    static let shared = ReviewProgressCenter()
    @Published private(set) var progress: [String: ReviewProgress] = [:]
    private var poller: ReviewProgressPoller!

    init() {
        poller = ReviewProgressPoller { [weak self] result in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.apply(result) } }
        }
    }

    var isPolling: Bool { poller.isRunning }
    var watchedKeys: Set<String> { poller.watchedKeys }

    private func apply(_ result: [String: ReviewProgress]) {
        var next = progress
        for (key, value) in result where next[key] != value { next[key] = value }
        if next != progress { progress = next }
    }

    func retain(key: String, folder: URL, kind: ReviewRunKind, title: String, since: Double) {
        if !poller.watchedKeys.contains(key) { progress[key] = nil }
        poller.retain(key: key, .init(folder: folder, kind: kind, title: title, since: since))
    }

    func release(key: String) { poller.release(key: key) }

    func readOnce(key: String, folder: URL, kind: ReviewRunKind) {
        poller.readOnce(key: key, .init(folder: folder, kind: kind, title: "", since: 0))
    }

    func forget(key: String) { progress[key] = nil }

    /// The run a record stands for, and where its files are.
    static func kind(_ record: ReviewRecord) -> ReviewRunKind { record.baseHead != nil ? .followUp : .full }
    static func title(_ record: ReviewRecord) -> String? {
        PullRequestRef(key: record.key).map { "PR review #\($0.id) · \($0.repo)" }
    }
}

/// Keeps a review's progress read while the view is on screen and the run is going; one read after it stopped.
struct ReviewProgressWatch: ViewModifier {
    var record: ReviewRecord?
    var folder: URL?
    /// Replies being read for this pull request (key and start), when no review is running.
    var replies: Double? = nil
    @State private var held: String?

    private var mode: (key: String, kind: ReviewRunKind, since: Double, live: Bool)? {
        if let record, record.phase == .reviewing { return (record.key, ReviewProgressCenter.kind(record), record.startedAt ?? record.queuedAt, true) }
        if let record, let replies, !record.isActive { return (record.key, .replies, replies, true) }
        if let record, record.phase == .failed || record.phase == .cancelled, record.startedAt != nil { return (record.key, ReviewProgressCenter.kind(record), 0, false) }
        return nil
    }

    func body(content: Content) -> some View {
        content
            .onAppear { sync() }
            .onChange(of: record?.phase) { sync() }
            .onChange(of: replies) { sync() }
            .onChange(of: record?.key) { sync() }
            .onDisappear { stop() }
    }

    private func stop() {
        if let key = held { ReviewProgressCenter.shared.release(key: key); held = nil }
    }

    private func sync() {
        stop()
        guard let record, let folder, let mode else { return }
        let center = ReviewProgressCenter.shared
        if mode.live {
            guard let title = ReviewProgressCenter.title(record) else { return }
            center.retain(key: mode.key, folder: folder, kind: mode.kind, title: title, since: mode.since)
            held = mode.key
        } else {
            center.readOnce(key: mode.key, folder: folder, kind: mode.kind)
        }
    }
}

extension View {
    func reviewProgress(record: ReviewRecord?, folder: URL?, replies: Double? = nil) -> some View {
        modifier(ReviewProgressWatch(record: record, folder: folder, replies: replies))
    }
}

struct ReviewProgressPanel: View {
    var progress: ReviewProgress
    /// When the run began; nil when unknown.
    var since: Double?
    /// The run ended without a result (failed, stopped, timed out): the step it reached is marked.
    var stopped: Bool = false
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(progress.steps, id: \.id) { step in
                    stepRow(step)
                    if step.id == "reviewers", !progress.reviewers.isEmpty, step.state != .pending { reviewerList }
                }
            }
            if !stopped { nowLine }
            else if let step = progress.current {
                Text("Stopped at: \(step.title)" + (step.id == "reviewers" ? " · \(progress.reviewersDone) of \(progress.reviewersTotal) reviewers done" : ""))
                    .font(Typo.label(.medium)).foregroundStyle(Palette.failed)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.panel))
    }

    private func stepRow(_ step: ReviewStepRow) -> some View {
        let current = step.state == .current
        let tone: Color = step.state == .done ? Palette.done : current ? (stopped ? Palette.failed : Palette.claude) : Palette.ink3
        let symbol = step.state == .done ? "checkmark.circle.fill" : current ? (stopped ? "exclamationmark.circle" : "ellipsis.circle") : "circle"
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).font(Typo.label(.semibold)).foregroundStyle(tone).frame(width: 16).decorative()
            Text(step.title).font(Typo.label(current ? .semibold : .medium)).foregroundStyle(step.state == .pending ? Palette.ink3 : Palette.ink)
            if let fact = step.fact {
                Text(fact).font(Typo.label()).foregroundStyle(Palette.ink3).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var reviewerList: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(progress.reviewers.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 6) {
                    Text(row.title).font(Typo.label()).foregroundStyle(row.state == .waiting ? Palette.ink3 : Palette.ink2)
                    Spacer(minLength: 6)
                    switch row.state {
                    case .waiting: Text("waiting").font(Typo.label()).foregroundStyle(Palette.ink3)
                    case .running: Text("running").font(Typo.label(.medium)).foregroundStyle(stopped ? Palette.ink3 : Palette.claude)
                    case .done:
                        Text("\(row.filesReported ?? 0) of \(row.filesGiven) files · \(row.findings?.text ?? "none")")
                            .font(Typo.label()).foregroundStyle(Palette.ink3).lineLimit(1)
                    }
                }
            }
            HStack(spacing: 4) {
                Text("\(progress.reviewersDone) of \(progress.reviewersTotal) reviewers done · \(progress.filesReported) of \(progress.filesTotal) files reported")
                    .font(Typo.label(.medium)).foregroundStyle(Palette.ink2)
                Spacer(minLength: 0)
            }
            .padding(.top, 2)
            if progress.liveFindings.total > 0 {
                HStack(spacing: 4) {
                    Text("Found so far: \(progress.liveFindings.text)").font(Typo.label()).foregroundStyle(Palette.ink3)
                    if !progress.checked {
                        Text("not yet checked").font(Typo.label(.medium)).foregroundStyle(Palette.waiting)
                        InfoMark(text: "What the reviewers wrote so far. The final check re-opens each one in the code and drops what it cannot confirm; only what it keeps becomes a comment.")
                    }
                }
            }
        }
        .padding(.leading, 24)
    }

    private var nowLine: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = since.map { context.date.timeIntervalSince1970 - $0 }
            HStack(spacing: 6) {
                Text("Now").font(Typo.label(.semibold)).foregroundStyle(Palette.ink3)
                Text(progress.nowLine(elapsed: elapsed)).font(Typo.label()).foregroundStyle(Palette.ink2).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
