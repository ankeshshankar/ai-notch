import Darwin
import Foundation

/// A permission prompt the hook hands to the app, so it can be answered from the notch as well as
/// in the editor. The editor's own prompt stays up the whole time: whichever is answered first counts.
public struct ApprovalRequest: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var session: String
    /// The subagent asking, nil for the main thread, and its type.
    public var agent: String?
    public var agentType: String?
    public var tool: String
    /// The MCP server, for an MCP tool.
    public var server: String?
    /// What it acts on: the command, the file, the URL…, one line.
    public var detail: String
    /// What "Allow for session" adds, as Claude Code itself suggested it, with the destination set
    /// to the session; empty when it suggested nothing (an ask rule matched, for one).
    public var sessionRules: [String]
    public var since: Double
    /// For AskUserQuestion: the one question and its options, answered by picking one.
    public var question: Question?
    /// The ask rule of your settings that covers this call (`Bash(git push *)`): then there is no
    /// "Allow for session", whatever Claude Code suggested.
    public var askRule: String?

    public struct Question: Codable, Sendable, Equatable {
        public var text: String
        public var header: String?
        public var options: [String]

        public init(text: String, header: String?, options: [String]) {
            self.text = text
            self.header = header
            self.options = options
        }
    }

    public init(id: String, session: String, agent: String?, agentType: String?, tool: String, server: String?,
                detail: String, sessionRules: [String], since: Double, question: Question? = nil, askRule: String? = nil) {
        self.askRule = askRule
        self.id = id
        self.session = session
        self.agent = agent
        self.agentType = agentType
        self.tool = tool
        self.server = server
        self.detail = detail
        self.sessionRules = sessionRules
        self.since = since
        self.question = question
    }
}

/// The app's answer. Only a click in the notch produces `allow` or `allowSession`; `withdraw`
/// (answered elsewhere) and a closed connection make the hook exit without a word.
public enum ApprovalDecision: String, Codable, Sendable {
    case allow, allowSession, deny, withdraw
    /// A question's option was picked: `ApprovalReply.answer`.
    case answer
}

public struct ApprovalReply: Codable, Sendable {
    public var id: String
    public var decision: ApprovalDecision
    /// The picked option's label, for `answer`.
    public var answer: String?

    public init(id: String, decision: ApprovalDecision, answer: String? = nil) {
        self.id = id
        self.decision = decision
        self.answer = answer
    }
}

/// A request the hook recorded in the session's state, so a later event can mark it answered.
public struct PendingPermission: Codable, Sendable, Equatable {
    public var id: String
    public var tool: String
    public var agent: String?
    public var since: Double

    public init(id: String, tool: String, agent: String?, since: Double) {
        self.id = id
        self.tool = tool
        self.agent = agent
        self.since = since
    }
}

/// The Unix domain socket between hook and app: `~/.claude/notch/approvals.sock`, 0600, and both
/// ends check that the other runs as this user.
public enum ApprovalSocket {
    /// `CLAUDE_NOTCH_SOCKET` points a dev run elsewhere; a preview uses its own so it never takes
    /// the installed app's.
    public static func path(preview: Bool = false) -> String {
        if let path = ProcessInfo.processInfo.environment["CLAUDE_NOTCH_SOCKET"], !path.isEmpty { return path }
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/notch").path
        return dir + (preview ? "/approvals-preview.sock" : "/approvals.sock")
    }

    /// The largest line either side reads.
    public static let maxLine = 256 * 1024

    private static func address(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (index, byte) in bytes.enumerated() { raw[index] = byte }
            raw[bytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return addr
    }

    /// Whether the process at the other end of `fd` runs as this user.
    public static func peerIsMe(_ fd: Int32) -> Bool {
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 && uid == getuid()
    }

    /// The hook's side: a connection to the app, or nil when there is no app to ask (no socket,
    /// a socket that is not this user's alone, nobody listening, or not this user at the other end).
    public static func connect(to path: String) -> Int32? {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid(),
              info.st_mode & 0o077 == 0, var addr = address(path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0, peerIsMe(fd) else {
            close(fd)
            return nil
        }
        return fd
    }

    /// The app's side: a listening socket at `path`, readable and writable by this user only.
    public static func listen(at path: String) -> Int32? {
        guard var addr = address(path) else { return nil }
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        // Created 0600 from the start, not chmod-ed after: no moment when another user could connect.
        let mask = umask(0o177)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        umask(mask)
        guard bound == 0, chmod(path, 0o600) == 0, Darwin.listen(fd, 16) == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    /// Writes one JSON line; false if the other end is gone.
    @discardableResult
    public static func send<T: Encodable>(_ value: T, to fd: Int32) -> Bool {
        guard var data = try? JSONEncoder().encode(value) else { return false }
        data.append(0x0A)
        return data.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written <= 0 {
                    if written < 0, errno == EINTR { continue }
                    return false
                }
                offset += written
            }
            return true
        }
    }

    /// Reads one line (without its newline); nil at end of stream, on error, or past `maxLine`.
    /// Each side sends a single line, so nothing after the newline is kept.
    public static func readLine(from fd: Int32) -> Data? {
        var line = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while line.count <= maxLine {
            let count = read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return nil }
            if let newline = buffer[0..<count].firstIndex(of: 0x0A) {
                line.append(contentsOf: buffer[0..<newline])
                return line
            }
            line.append(contentsOf: buffer[0..<count])
        }
        return nil
    }
}
