import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A Unix stream socket, the few calls the helper and the app need: listen, accept, connect,
/// and one line out, one line back.
public enum UnixSocket {
    public enum Failure: Error, CustomStringConvertible {
        case system(String, Int32)
        case pathTooLong
        case tooLarge
        case closed

        public var description: String {
            switch self {
            case .system(let call, let code): return "\(call): \(String(cString: strerror(code)))"
            case .pathTooLong: return "socket path too long"
            case .tooLarge: return "message too large"
            case .closed: return "connection closed"
            }
        }

        /// Nothing listens there (no helper, or it is not running).
        public var isNotRunning: Bool {
            if case .system(_, let code) = self { return code == ENOENT || code == ECONNREFUSED }
            return false
        }
    }

    private static func address(_ path: String) throws -> (sockaddr_un, socklen_t) {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { throw Failure.pathTooLong }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        #if canImport(Darwin)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        #endif
        return (addr, socklen_t(MemoryLayout<sockaddr_un>.size))
    }

    private static func stream() throws -> Int32 {
        #if canImport(Darwin)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #else
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard fd >= 0 else { throw Failure.system("socket", errno) }
        #if canImport(Darwin)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        #endif
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        return fd
    }

    /// Listens at `path` (an old socket file there is removed first) with `mode`.
    public static func listen(_ path: String, mode: mode_t) throws -> Int32 {
        let fd = try stream()
        unlink(path)
        var (addr, len) = try address(path)
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) } }
        guard bound == 0 else { let e = errno; close(fd); throw Failure.system("bind", e) }
        guard chmod(path, mode) == 0 else { let e = errno; close(fd); throw Failure.system("chmod", e) }
        guard systemListen(fd, 16) == 0 else { let e = errno; close(fd); throw Failure.system("listen", e) }
        return fd
    }

    public static func connect(_ path: String) throws -> Int32 {
        let fd = try stream()
        var (addr, len) = try address(path)
        let done = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { systemConnect(fd, $0, len) }
        }
        guard done == 0 else { let e = errno; close(fd); throw Failure.system("connect", e) }
        return fd
    }

    /// The uid of the process at the other end.
    public static func peerUID(_ fd: Int32) -> uid_t? {
        #if canImport(Darwin)
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 ? uid : nil
        #else
        // Linux, for testing the helper there: SO_PEERCRED (17) gives pid, uid, gid.
        var cred = [Int32](repeating: 0, count: 3)
        var len = socklen_t(12)
        return getsockopt(fd, SOL_SOCKET, 17, &cred, &len) == 0 ? uid_t(bitPattern: cred[1]) : nil
        #endif
    }

    public static func setTimeout(_ fd: Int32, seconds: Int) {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    public static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard var p = raw.baseAddress else { return }
            var left = raw.count
            while left > 0 {
                #if canImport(Darwin)
                let n = write(fd, p, left)
                #else
                let n = send(fd, p, left, Int32(MSG_NOSIGNAL))
                #endif
                if n < 0 {
                    if errno == EINTR { continue }
                    throw Failure.system("write", errno)
                }
                p += n
                left -= n
            }
        }
    }

    /// Reads up to the first newline (not included), at most `limit` bytes.
    public static func readLine(_ fd: Int32, limit: Int) throws -> Data {
        var out = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n < 0 {
                if errno == EINTR { continue }
                throw Failure.system("read", errno)
            }
            if n == 0 { if out.isEmpty { throw Failure.closed } else { return out } }
            if let nl = buffer[0..<n].firstIndex(of: 0x0A) {
                out.append(contentsOf: buffer[0..<nl])
                return out
            }
            out.append(contentsOf: buffer[0..<n])
            if out.count > limit { throw Failure.tooLarge }
        }
    }

    /// One request and its reply, for the app: connect, send, read, close.
    public static func exchange(_ path: String, _ request: Data, timeout: Int, limit: Int = 4 * 1024 * 1024) throws -> Data {
        let fd = try connect(path)
        defer { close(fd) }
        setTimeout(fd, seconds: timeout)
        try writeAll(fd, request)
        return try readLine(fd, limit: limit)
    }
}

// `listen` and `connect` are also UnixSocket's own names; these reach the system's.
@inline(__always) private func systemListen(_ fd: Int32, _ backlog: Int32) -> Int32 { listen(fd, backlog) }
@inline(__always) private func systemConnect(_ fd: Int32, _ addr: UnsafePointer<sockaddr>, _ len: socklen_t) -> Int32 { connect(fd, addr, len) }
