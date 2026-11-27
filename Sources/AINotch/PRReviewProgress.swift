import NotchCore
import ReviewCore
import SwiftUI

// The live view of a review that is running: its steps, one row per reviewer, and what it is doing now. Read from
// the review's folder (and the session file the notch's hook keeps) every two seconds on a utility queue; nothing
// is polled while no view shows it, and nothing here can post. What a reviewer wrote before the final check is
// labelled "not yet checked" and is never a card.

/// The session-file readers of the runs being watched, one per run, so a poll reads only what was appended.
final class LiveTrackerBook: @unchecked Sendable {
    private let lock = NSLock()
    private var trackers: [String: ReviewLiveTracker] = [:]

    func tracker(for key: String) -> ReviewLiveTracker {
        lock.lock(); defer { lock.unlock() }
        if let found = trackers[key] { return found }
        let made = ReviewLiveTracker()
        trackers[key] = made
        return made
    }

    func drop(_ key: String) { lock.lock(); trackers[key] = nil; lock.unlock() }
}

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
    private let book = LiveTrackerBook()
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
            if existing.users <= 0 { watches[key] = nil; book.drop(key) } else { watches[key] = existing }
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
        deliver(Self.compute(current, sessions: sessions, trackers: book))
    }

    /// Dev and tests: the same read, on this thread.
    static func compute(_ watches: [String: Watch], sessions: URL, trackers: LiveTrackerBook = LiveTrackerBook(), now: Double = Date().timeIntervalSince1970) -> [String: ReviewProgress] {
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
            // The run's own files beside its transcript; anything unreadable leaves the folder-only view.
            let live = activity?.transcript.map { trackers.tracker(for: key).update(transcript: URL(fileURLWithPath: $0), now: now) }
            out[key] = ReviewProgress.read(folder: watch.folder, kind: watch.kind, activity: activity, live: live, now: now)
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
