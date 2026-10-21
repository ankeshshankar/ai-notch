import Foundation
import VPNCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// One line in the helper's log (launchd sends its stderr to VPNPaths.log). Never a password,
/// a response or a profile's content.
func note(_ line: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write(Data("\(stamp) vpnd: \(line)\n".utf8))
}

/// The helper: the control socket, the profiles, and at most one OpenVPN at a time. All state
/// lives on `queue`; the socket's reads and writes run on `io`.
final class Daemon: @unchecked Sendable {
    let queue = DispatchQueue(label: "vpnd")
    private let io = DispatchQueue(label: "vpnd.io", attributes: .concurrent)
    /// The user the helper was installed for: the only one (besides root) it answers.
    private let allowedUID: uid_t
    private var store = ProfileStore()
    private var session: Session?
    private var lastEnd: VPNEnd?
    /// The ended session's log, for "log" after a failure.
    private var lastLog: [String] = []
    /// Connect to another profile while one runs: started once the first has stopped.
    private var pendingConnect: String?
    private var promptSeq = 0
    private var sources: [Any] = []
    private var shuttingDown = false

    init(allowedUID: uid_t) {
        self.allowedUID = allowedUID
    }

    func serve() -> Never {
        signal(SIGPIPE, SIG_IGN)
        do {
            try Files.secureDir(VPNPaths.runDir, mode: 0o700)
            try Files.secureDir(VPNPaths.dataDir, mode: 0o700)
            try Files.secureDir(VPNPaths.profilesDir, mode: 0o700)
        } catch {
            note("cannot prepare folders: \(error)")
            exit(1)
        }
        store.load()
        let listener: Int32
        do {
            listener = try UnixSocket.listen(VPNPaths.controlSocket, mode: 0o666)
        } catch {
            note("cannot listen at \(VPNPaths.controlSocket): \(error)")
            exit(1)
        }
        // The handlers hold the daemon: it lives as long as the process.
        let accept = DispatchSource.makeReadSource(fileDescriptor: listener, queue: io)
        accept.setEventHandler { self.acceptOne(listener) }
        accept.resume()
        // Stopped by launchd (uninstall, update): OpenVPN is stopped first, so its routes and DNS
        // are taken back.
        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
        term.setEventHandler { self.shutdown() }
        term.resume()
        sources = [accept, term]
        note("version \(VPNBuild.version) serving user \(allowedUID), \(store.profiles.count) profile(s)")
        dispatchMain()
    }

    private func shutdown() {
        pendingConnect = nil
        shuttingDown = true
        guard let session else { exit(0) }
        session.stop()
        // At most 8 s for OpenVPN to take its routes and DNS back.
        queue.asyncAfter(deadline: .now() + 8) { exit(0) }
    }

    // MARK: The control socket

    private func acceptOne(_ listener: Int32) {
        let client = Darwin_or_Glibc_accept(listener)
        guard client >= 0 else { return }
        io.async {
            defer { close(client) }
            let uid = UnixSocket.peerUID(client)
            guard let uid, uid == 0 || uid == self.allowedUID else {
                note("refused a request from uid \(uid.map(String.init) ?? "?")")
                try? UnixSocket.writeAll(client, VPNWire.encode(VPNReply.fail("This VPN helper serves another user.")))
                return
            }
            UnixSocket.setTimeout(client, seconds: 5)
            let reply: VPNReply
            if let line = try? UnixSocket.readLine(client, limit: VPNWire.maxRequest),
               let request = VPNWire.decode(VPNRequest.self, line) {
                reply = self.queue.sync { self.handle(request) }
            } else {
                reply = .fail("The request could not be read.")
            }
            try? UnixSocket.writeAll(client, VPNWire.encode(reply))
        }
    }

    private func status() -> VPNStatus {
        VPNStatus(version: VPNBuild.version, engine: FileManager.default.isExecutableFile(atPath: VPNPaths.openvpn),
                  profiles: store.profiles, session: session?.info, lastEnd: lastEnd)
    }

    private func handle(_ request: VPNRequest) -> VPNReply {
        switch request.op {
        case .status:
            return VPNReply(ok: true, status: status())
        case .importProfile:
            guard let config = request.config else { return .fail("No profile was sent.") }
            switch OVPNProfile.check(Data(config.utf8)) {
            case .failure(let problem):
                return .fail(problem.description)
            case .success(let profile):
                do {
                    let info = try store.add(name: request.name ?? "VPN", profile: profile)
                    note("imported profile \(info.id) (\(profile.servers.count) server(s), \(profile.dropped.count) line(s) left out)")
                    return VPNReply(ok: true, status: status(), profile: info, dropped: profile.dropped)
                } catch {
                    return .fail("The profile could not be saved: \(error)")
                }
            }
        case .rename:
            guard let id = request.id, let name = request.name, store.rename(id, to: name) else { return .fail("No such profile.") }
            return VPNReply(ok: true, status: status())
        case .delete:
            guard let id = request.id else { return .fail("No profile named.") }
            if session?.profile.id == id { return .fail("Disconnect it first.") }
            guard store.delete(id) else { return .fail("No such profile.") }
            if lastEnd?.profileId == id { lastEnd = nil }
            note("deleted profile \(id)")
            return VPNReply(ok: true, status: status())
        case .connect:
            guard let id = request.id, let profile = store.profiles.first(where: { $0.id == id }) else { return .fail("No such profile.") }
            guard FileManager.default.isExecutableFile(atPath: VPNPaths.openvpn) else { return .fail("OpenVPN is not installed beside the helper.") }
            if let session {
                if session.profile.id == id, !session.isStopping { return VPNReply(ok: true, status: status()) }
                pendingConnect = id
                session.stop()
                return VPNReply(ok: true, status: status())
            }
            start(profile)
            return VPNReply(ok: true, status: status())
        case .disconnect:
            pendingConnect = nil
            session?.stop()
            return VPNReply(ok: true, status: status())
        case .answer:
            guard let session else { return .fail("Not connecting.") }
            if let why = session.answer(prompt: request.prompt ?? -1, username: request.username ?? "",
                                        password: request.password ?? "", response: request.response) {
                return .fail(why)
            }
            return VPNReply(ok: true, status: status())
        case .log:
            return VPNReply(ok: true, log: session?.log ?? lastLog)
        }
    }

    // MARK: The session

    private func start(_ profile: VPNProfileInfo) {
        lastEnd = nil
        let session = Session(profile: profile, config: store.path(profile.id), queue: queue) { [weak self] in
            guard let self else { return 0 }
            self.promptSeq += 1
            return self.promptSeq
        }
        session.onEnd = { [weak self] ended, status, signaled in self?.ended(ended, status: status, signaled: signaled) }
        self.session = session
        note("connecting \(profile.id)")
        if let why = session.start() {
            self.session = nil
            lastEnd = VPNEnd(profileId: profile.id, at: Date().timeIntervalSince1970, byUser: false, wasConnected: false, reason: why)
        }
    }

    private func ended(_ ended: Session, status: Int32, signaled: Bool) {
        guard session === ended else { return }
        let reason = ended.endReason(status: status, signaled: signaled)
        lastEnd = VPNEnd(profileId: ended.profile.id, at: Date().timeIntervalSince1970, byUser: ended.isStopping,
                         wasConnected: ended.wasConnected, reason: reason)
        lastLog = ended.log
        session = nil
        note("session \(ended.profile.id) ended (\(signaled ? "signal" : "status") \(status))\(reason.map { ": \($0)" } ?? "")")
        if shuttingDown { exit(0) }
        if let next = pendingConnect {
            pendingConnect = nil
            if let profile = store.profiles.first(where: { $0.id == next }) { start(profile) }
        }
    }
}

/// `accept` without the peer's address.
private func Darwin_or_Glibc_accept(_ fd: Int32) -> Int32 {
    let client = accept(fd, nil, nil)
    if client >= 0 { _ = fcntl(client, F_SETFD, FD_CLOEXEC) }
    return client
}

// MARK: Profiles

/// The imported profiles: each checked one as `<id>.ovpn` (0600) and the index beside them.
struct ProfileStore {
    private(set) var profiles: [VPNProfileInfo] = []

    func path(_ id: String) -> String { "\(VPNPaths.profilesDir)/\(id).ovpn" }

    mutating func load() {
        guard let data = FileManager.default.contents(atPath: VPNPaths.index),
              let list = try? JSONDecoder().decode([VPNProfileInfo].self, from: data) else { return }
        // Only entries whose file is there, with an id that is a UUID (it names a file).
        profiles = list.filter { UUID(uuidString: $0.id) != nil && FileManager.default.fileExists(atPath: path($0.id)) }
    }

    mutating func add(name: String, profile: OVPNProfile) throws -> VPNProfileInfo {
        let info = VPNProfileInfo(id: UUID().uuidString.lowercased(), name: Self.clean(name), servers: profile.servers,
                                  asksPassword: profile.asksPassword, importedAt: Date().timeIntervalSince1970)
        try Files.write(Data(profile.text.utf8), to: path(info.id), mode: 0o600)
        profiles.append(info)
        try save()
        return info
    }

    mutating func rename(_ id: String, to name: String) -> Bool {
        guard let i = profiles.firstIndex(where: { $0.id == id }) else { return false }
        profiles[i].name = Self.clean(name)
        try? save()
        return true
    }

    mutating func delete(_ id: String) -> Bool {
        guard let i = profiles.firstIndex(where: { $0.id == id }) else { return false }
        unlink(path(id))
        profiles.remove(at: i)
        try? save()
        return true
    }

    private func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try Files.write(try encoder.encode(profiles), to: VPNPaths.index, mode: 0o600)
    }

    /// A name for the list: one line, at most 60 characters.
    static func clean(_ name: String) -> String {
        let flat = name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let text = String(String.UnicodeScalarView(flat)).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? "VPN" : String(text.prefix(60))
    }
}

// MARK: Files as root

enum Files {
    struct Unsafe: Error, CustomStringConvertible {
        var description: String
    }

    /// A folder root owns, of `mode`; refused when the path is a link or another user's.
    static func secureDir(_ path: String, mode: mode_t) throws {
        var st = stat()
        if lstat(path, &st) != 0 {
            guard mkdir(path, mode) == 0 else { throw Unsafe(description: "mkdir \(path): \(String(cString: strerror(errno)))") }
            guard lstat(path, &st) == 0 else { throw Unsafe(description: "stat \(path)") }
        }
        guard (st.st_mode & S_IFMT) == S_IFDIR else { throw Unsafe(description: "\(path) is not a folder") }
        if geteuid() == 0, st.st_uid != 0 {
            guard chown(path, 0, 0) == 0 else { throw Unsafe(description: "\(path) is not root's") }
        }
        guard chmod(path, mode) == 0 else { throw Unsafe(description: "chmod \(path)") }
    }

    /// Written beside the target, then renamed over it: never a half-written file, never
    /// through a link someone left at the path.
    static func write(_ data: Data, to path: String, mode: mode_t) throws {
        let temp = path + ".tmp-\(getpid())"
        unlink(temp)
        let fd = open(temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode)
        guard fd >= 0 else { throw Unsafe(description: "open \(temp): \(String(cString: strerror(errno)))") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            unlink(temp)
            throw error
        }
        _ = chmod(temp, mode)
        guard rename(temp, path) == 0 else {
            let why = String(cString: strerror(errno))
            unlink(temp)
            throw Unsafe(description: "rename \(path): \(why)")
        }
    }
}
