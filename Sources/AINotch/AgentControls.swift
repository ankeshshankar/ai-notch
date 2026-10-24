import AppKit
import Darwin
import Foundation
import NotchCore

/// Stop, pause and notes for running agents. A Claude Code session is asked through its control
/// file (`SessionControl`): its hook stops it before the next step, holds the next step while
/// paused, or hands Claude a note with it. An agent the hooks do not cover (a watched process)
/// is paused and resumed with SIGSTOP and SIGCONT on its process tree, and quit with SIGTERM.
@MainActor
final class AgentControls: ObservableObject {
    static let shared = AgentControls()

    /// What is asked of each Claude Code session, as its control file says.
    @Published private(set) var asked: [String: SessionControl] = [:]
    /// Watched agents (by row id) whose processes are stopped with SIGSTOP.
    @Published private(set) var frozen: Set<String> = []

    /// Sessions (by id) whose last stop, pause or note did not go through, for a few seconds.
    @Published private(set) var troubled: Set<String> = []
    static let troubleText = "Couldn't reach the session, try again"

    private func flagTrouble(_ id: String) {
        troubled.insert(id)
        Self.log("control: could not reach the session")
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            self?.troubled.remove(id)
        }
    }

    /// Which rows take which controls.
    enum Kind { case hooked, process, none }

    static func kind(of session: SessionState) -> Kind {
        if session.id.hasPrefix("watch-"), session.pid != nil { return .process }
        if session.kind == .claude { return .hooked }
        return .none
    }

    /// Re-reads the control files of these sessions (the hook clears them as it acts).
    func refresh(_ sessions: [SessionState]) {
        var next: [String: SessionControl] = [:]
        for session in sessions where Self.kind(of: session) == .hooked {
            if let control = SessionControl.read(session.id), !control.isEmpty { next[session.id] = control }
        }
        if next != asked { asked = next }
        let live = Set(sessions.map(\.id))
        if !frozen.isSubset(of: live) { frozen = frozen.intersection(live) }
    }

    func isPaused(_ session: SessionState) -> Bool {
        asked[session.id]?.pause == true || frozen.contains(session.id)
    }

    func isStopping(_ session: SessionState) -> Bool { asked[session.id]?.stop == true }

    func hasNote(_ session: SessionState) -> Bool { !(asked[session.id]?.note ?? "").isEmpty }

    // MARK: Actions

    func stop(_ session: SessionState) {
        switch Self.kind(of: session) {
        case .hooked:
            update(session) { $0.stop = true; $0.pause = nil }
            Self.log("control: stop")
        case .process:
            signalTree(session, SIGCONT)
            signalTree(session, SIGTERM)
            frozen.remove(session.id)
            Self.log("control: quit watched agent")
        case .none:
            break
        }
    }

    func togglePause(_ session: SessionState) {
        let pause = !isPaused(session)
        switch Self.kind(of: session) {
        case .hooked:
            update(session) { $0.pause = pause ? true : nil }
        case .process:
            signalTree(session, pause ? SIGSTOP : SIGCONT)
            if pause { frozen.insert(session.id) } else { frozen.remove(session.id) }
        case .none:
            break
        }
        Self.log(pause ? "control: pause" : "control: resume")
    }

    /// Asks for a note in a small window (the notch never takes typing); Claude gets it with its
    /// next step.
    func askNote(_ session: SessionState, title: String) {
        guard Self.kind(of: session) == .hooked else { return }
        let alert = NSAlert()
        alert.messageText = "A note for \(title)"
        alert.informativeText = "Claude gets it with its next step, without stopping. It is not saved anywhere else."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 54))
        field.placeholderString = "Use pnpm, not npm"
        field.stringValue = asked[session.id]?.note ?? ""
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        alert.accessoryView = field
        alert.addButton(withTitle: "Send")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let note = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        update(session) { $0.note = note.isEmpty ? nil : String(note.prefix(SessionControl.noteLimit)) }
        Self.log("control: note")
    }

    /// Queues a pull request's brief for the session (its row's "Send to agent"): Claude gets it,
    /// quoted as feedback from other people, with its next step. Kept apart from your own note
    /// and replacing an earlier brief. Written under the session's lock; false when the lock
    /// stayed taken (the caller then copies the brief instead).
    func queueFeedback(_ session: SessionState, pullRequest: Int, _ text: String) -> Bool {
        guard Self.kind(of: session) == .hooked else { return false }
        let ok = SessionControl.update(session.id) {
            $0.feedback = String(text.prefix(SessionControl.feedbackLimit))
            $0.feedbackPR = pullRequest
            $0.feedbackAt = Date().timeIntervalSince1970
        }
        if ok { asked[session.id] = SessionControl.read(session.id); Self.log("control: pull-request feedback queued") }
        return ok
    }

    /// Whether a pull request's brief is still waiting for the session's next step.
    func hasFeedback(_ session: SessionState) -> Bool { !(asked[session.id]?.feedback ?? "").isEmpty }

    /// Takes the waiting brief back out (the session went idle before it was handed over) and
    /// clears it from the control file.
    func takeFeedback(_ session: SessionState) -> String? {
        var text: String?
        let ok = SessionControl.update(session.id) {
            text = $0.feedback
            $0.feedback = nil
            $0.feedbackPR = nil
            $0.feedbackAt = nil
        }
        asked[session.id] = SessionControl.read(session.id)
        if ok { Self.log("control: pull-request feedback taken back") }
        return (text ?? "").isEmpty ? nil : text
    }

    /// One line in `~/.claude/notch/notch.log`: what was asked, never a note's text.
    private static func log(_ line: String) {
        let url = NotchPaths.sessions.deletingLastPathComponent().appendingPathComponent("notch.log")
        let entry = Data("\(ISO8601DateFormatter().string(from: Date())) \(line)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(entry)
            try? handle.close()
        } else {
            try? entry.write(to: url)
        }
    }

    private func update(_ session: SessionState, _ change: (inout SessionControl) -> Void) {
        // The wait for the session's lock is at most 0.3 s. When it stays taken nothing was
        // changed: the row says so instead of silently losing the stop or note.
        if !SessionControl.update(session.id, change) { flagTrouble(session.id) }
        let control = SessionControl.read(session.id)
        asked[session.id] = (control?.isEmpty ?? true) ? nil : control
    }

    /// The watched agent and every process under it, if it is still the process the row saw.
    private func signalTree(_ session: SessionState, _ signal: Int32) {
        guard let pid = session.pid, let entry = ProcessList.entry(pid), entry.uid == getuid(),
              abs(entry.start - session.startedAt) < 1, let table = ProcessList.table() else { return }
        var children: [Int32: [Int32]] = [:]
        for item in table { children[item.ppid, default: []].append(item.pid) }
        var tree: [Int32] = []
        var stack = [pid]
        while let next = stack.popLast(), tree.count < 300 {
            tree.append(next)
            stack += children[next] ?? []
        }
        // Children first on a stop, so none runs on without its parent for a moment.
        for target in signal == SIGCONT ? tree : tree.reversed() { kill(target, signal) }
    }
}
