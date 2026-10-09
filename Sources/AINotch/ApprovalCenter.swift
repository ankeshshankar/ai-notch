import Darwin
import Foundation
import NotchCore

/// Permission prompts waiting in the notch. The hook connects over `ApprovalSocket`, sends one
/// request and waits; the connection stays open until a click here answers it, the session shows it
/// was answered in the editor (then it is withdrawn), or the hook goes away (Claude Code answered
/// it, timed out or quit). Nothing is ever answered without a click.
@MainActor
final class ApprovalCenter: ObservableObject {
    struct Pending: Identifiable, Equatable {
        var request: ApprovalRequest
        /// When it showed up here: its buttons wait a moment before they take a click, so a prompt
        /// that replaces another under the pointer is never answered by a click meant for the old one.
        var shownAt: Double
        var id: String { request.id }
    }

    /// Oldest first.
    @Published private(set) var pending: [Pending] = []
    /// A click within this long of a prompt appearing does nothing.
    static let armDelay: Double = 0.6

    private var connections: [String: Int32] = [:]
    private var listener: Int32 = -1
    private let path: String

    init(preview: Bool) {
        path = ApprovalSocket.path(preview: preview)
    }

    func start() {
        guard let fd = ApprovalSocket.listen(at: path) else {
            FileHandle.standardError.write(Data("approvals: cannot listen at \(path)\n".utf8))
            return
        }
        listener = fd
        let thread = Thread { [weak self] in self?.acceptLoop(fd) }
        thread.name = "ai-notch.approvals"
        thread.start()
    }

    func stop() {
        for fd in connections.values { shutdown(fd, SHUT_RDWR) }
        connections = [:]
        if listener >= 0 { close(listener) }
        unlink(path)
    }

    func pending(for session: String) -> [Pending] {
        pending.filter { $0.request.session == session }
    }

    /// A click on one of the buttons. Only these answers exist; there is no "always".
    func answer(_ id: String, _ decision: ApprovalDecision, option: String? = nil) {
        guard decision != .withdraw, let item = pending.first(where: { $0.id == id }),
              Date().timeIntervalSince1970 - item.shownAt >= Self.armDelay,
              let fd = connections[id] else { return }
        if decision == .answer {
            guard let option, item.request.question?.options.contains(option) == true else { return }
        }
        ApprovalSocket.send(ApprovalReply(id: id, decision: decision, answer: decision == .answer ? option : nil), to: fd)
        log("\(item.request.tool) prompt answered from the notch: \(decision.rawValue)")
        drop(id)
    }

    /// Takes away the prompts the sessions show were answered somewhere else: the hook marks them
    /// answered on the session's next event in that thread; a session that left, was interrupted or
    /// started an approved command answered them too. `sessions` is what the panel shows.
    func reconcile(with sessions: [SessionState]) {
        for item in pending {
            let request = item.request
            guard let session = sessions.first(where: { $0.id == request.session }) else {
                withdraw(request.id, because: "session gone")
                continue
            }
            // The state file may be older than the request: only a newer one can say it was answered.
            guard session.updatedAt >= request.since else { continue }
            let stillAsked = session.pendingPermissions?.contains { $0.id == request.id } ?? false
            if !stillAsked {
                withdraw(request.id, because: "a later event in its thread")
            } else if session.phase != .waiting {
                withdraw(request.id, because: session.phase == .idle ? "turn interrupted" : "approved command started")
            }
        }
    }

    private func withdraw(_ id: String, because reason: String) {
        if let item = pending.first(where: { $0.id == id }) { log("\(item.request.tool) prompt withdrawn: \(reason)") }
        if let fd = connections[id] { ApprovalSocket.send(ApprovalReply(id: id, decision: .withdraw), to: fd) }
        drop(id)
    }

    /// One line in `~/.claude/notch/notch.log`: the tool and what happened, never its input.
    private func log(_ line: String) {
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

    /// Ends the connection: its thread sees the end of the stream and closes the descriptor, so a
    /// number is never reused while that thread still reads it.
    private func drop(_ id: String) {
        if let fd = connections.removeValue(forKey: id) { shutdown(fd, SHUT_RDWR) }
        pending.removeAll { $0.id == id }
    }

    private func add(_ request: ApprovalRequest, fd: Int32) {
        guard connections[request.id] == nil else {
            shutdown(fd, SHUT_RDWR)
            return
        }
        connections[request.id] = fd
        pending.append(Pending(request: request, shownAt: Date().timeIntervalSince1970))
    }

    /// The connection ended: the hook went away (Claude Code answered, timed out or quit), or we ended it.
    private func closed(_ id: String, fd: Int32) {
        guard connections[id] == fd else { return }
        if let item = pending.first(where: { $0.id == id }) { log("\(item.request.tool) prompt closed by its hook (answered in the editor, timed out, or the session quit)") }
        connections[id] = nil
        pending.removeAll { $0.id == id }
    }

    nonisolated private func acceptLoop(_ listener: Int32) {
        while true {
            let fd = accept(listener, nil, nil)
            if fd < 0 {
                if errno == EINTR || errno == ECONNABORTED { continue }
                return
            }
            var noSigPipe: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            // Only this user's processes; the socket's 0600 says so too.
            guard ApprovalSocket.peerIsMe(fd) else {
                close(fd)
                continue
            }
            let thread = Thread { [weak self] in self?.serve(fd) }
            thread.start()
        }
    }

    /// One hook: its request, then nothing until it closes.
    nonisolated private func serve(_ fd: Int32) {
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        guard let line = ApprovalSocket.readLine(from: fd),
              let request = try? JSONDecoder().decode(ApprovalRequest.self, from: line),
              !request.id.isEmpty, !request.session.isEmpty else {
            close(fd)
            return
        }
        var forever = timeval(tv_sec: 0, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &forever, socklen_t(MemoryLayout<timeval>.size))
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.add(request, fd: fd) }
        }
        // The hook sends nothing more: a read returns only when it closes (or we do).
        var byte: UInt8 = 0
        while true {
            let count = read(fd, &byte, 1)
            if count < 0, errno == EINTR { continue }
            if count <= 0 { break }
        }
        // Forgotten on the main thread first, closed after: no click can reach a reused number.
        DispatchQueue.main.sync { [weak self] in
            MainActor.assumeIsolated { self?.closed(request.id, fd: fd) }
        }
        close(fd)
    }
}
