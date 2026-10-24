import Darwin
import Foundation

/// The process table, read with sysctl and libproc.
enum ProcessList {
    /// Whether `parent` has a child named one of `names` that started after `time` (epoch seconds).
    static func hasChild(of parent: pid_t, startedAfter time: Double, named names: Set<String>) -> Bool {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return false }
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 16)
        size = procs.count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return false }
        let count = size / MemoryLayout<kinfo_proc>.stride
        for index in 0..<count {
            let proc = procs[index]
            guard proc.kp_eproc.e_ppid == parent else { continue }
            let start = proc.kp_proc.p_un.__p_starttime
            let started = Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000
            guard started > time else { continue }
            var comm = proc.kp_proc.p_comm
            let name = withUnsafeBytes(of: &comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            if names.contains(name) { return true }
        }
        return false
    }

    // MARK: The machine guard's reads (MachineSource)

    /// Every process: its ids, owner, terminal, start time and name. No arguments: those are read
    /// one by one (`arguments(of:)`) for the few that could be dev processes.
    static func table() -> [ProcEntry]? {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard got > 0 else { return nil }
        var entries: [ProcEntry] = []
        entries.reserveCapacity(Int(got))
        for pid in pids.prefix(Int(got)) where pid > 0 {
            if let entry = entry(pid) { entries.append(entry) }
        }
        return entries
    }

    /// One process now, or nil once it has exited (or is a zombie). Also the re-check before a signal.
    static func entry(_ pid: pid_t) -> ProcEntry? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        // SZOMB: exited, waiting for its parent; nothing left to free or signal.
        guard info.pbi_status != 5 else { return nil }
        var name = info.pbi_name
        var comm = info.pbi_comm
        let long = withUnsafeBytes(of: &name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let short = withUnsafeBytes(of: &comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return ProcEntry(pid: Int32(info.pbi_pid), ppid: Int32(info.pbi_ppid), pgid: Int32(info.pbi_pgid), uid: info.pbi_uid,
                         tty: info.e_tdev == UInt32.max ? nil : Int32(bitPattern: info.e_tdev),
                         start: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000,
                         comm: long.isEmpty ? short : long, path: "")
    }

    /// Whether the process has exited but its parent has not collected it yet. True only when the
    /// kernel says so: a process that cannot be read (another user's) is not a zombie.
    static func isZombie(_ pid: pid_t) -> Bool {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return false }
        return info.kp_proc.p_stat == 5 // SZOMB
    }

    /// The executable's path, or "" when it cannot be read.
    static func path(of pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return "" }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// The process's current folder, or nil when it cannot be read (another user's process).
    static func cwd(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return path.isEmpty ? nil : path
    }

    /// Whether `pid` leads its session (a terminal's or a login's shell does).
    static func leadsSession(_ pid: pid_t) -> Bool { getsid(pid) == pid }

    private static let argMax: Int = {
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctl(&mib, 2, &value, &size, nil, 0) == 0 && value > 0 ? Int(value) : 1 << 20
    }()

    /// A process's argv (KERN_PROCARGS2), for telling dev processes apart. Never the environment
    /// that follows it, and never written anywhere: arguments may hold secrets.
    static func arguments(of pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = argMax
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        // The exec path, then the NULs that pad it.
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var args: [String] = []
        var start = index
        while index < size, args.count < Int(argc) {
            if buffer[index] == 0 {
                args.append(String(decoding: buffer[start..<index], as: UTF8.self))
                start = index + 1
            }
            index += 1
        }
        return args
    }

    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(max(info.numer, 1)), UInt64(max(info.denom, 1)))
    }()

    /// Physical footprint (what Activity Monitor calls Memory) and CPU time so far, in nanoseconds.
    static func usage(of pid: pid_t) -> ProcUsage? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard result == 0 else { return nil }
        // Mach absolute time units, not nanoseconds (125/3 on Apple silicon).
        let ticks = info.ri_user_time &+ info.ri_system_time
        return ProcUsage(footprint: info.ri_phys_footprint, cpuNanos: ticks / timebase.denom * timebase.numer + ticks % timebase.denom * timebase.numer / timebase.denom)
    }

    /// The process's TCP sockets: local port, and whether it listens or is connected.
    static func tcpSockets(of pid: pid_t) -> [TCPSocket] {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride + 16)
        let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
        guard got > 0 else { return [] }
        var sockets: [TCPSocket] = []
        for fd in fds.prefix(Int(got) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
                  info.psi.soi_kind == Int32(SOCKINFO_TCP) else { continue }
            let tcp = info.psi.soi_proto.pri_tcp
            let port = UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport))
            sockets.append(TCPSocket(localPort: Int(port), listening: tcp.tcpsi_state == Int32(TSI_S_LISTEN),
                                     established: tcp.tcpsi_state == Int32(TSI_S_ESTABLISHED)))
        }
        return sockets
    }

    /// The machine's memory now: total, available as `vm_stat` counts it (free + inactive +
    /// speculative pages, as the dev scripts' wait-for-memory check does), compressed, and the
    /// kernel's pressure level (1 normal, 2 warning, 4 critical).
    static func memory() -> MemoryReading? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        var total: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname("hw.memsize", &total, &size, nil, 0) == 0, total > 0 else { return nil }
        var level: Int32 = 0
        var levelSize = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &levelSize, nil, 0) != 0 { level = 1 }
        let page = UInt64(vm_kernel_page_size)
        let available = (UInt64(stats.free_count) + UInt64(stats.inactive_count) + UInt64(stats.speculative_count)) * page
        return MemoryReading(total: total, available: min(available, total), compressed: UInt64(stats.compressor_page_count) * page, pressureLevel: level)
    }
}

/// One process as the table reads it.
struct ProcEntry: Sendable, Equatable, Codable {
    var pid: Int32
    var ppid: Int32
    var pgid: Int32
    var uid: UInt32
    /// The controlling terminal's device; nil without one.
    var tty: Int32?
    /// Epoch seconds: with the pid, what makes it this process and not a later one with its number.
    var start: Double
    var comm: String
    /// The executable's path ("" when not read: only the user's own processes get one).
    var path: String
    /// Leads its session: a terminal's or a login's shell. Only looked up for shells.
    var sessionLeader: Bool = false

    enum CodingKeys: String, CodingKey { case pid, ppid, pgid, uid, tty, start, comm, path, sessionLeader }

    init(pid: Int32, ppid: Int32, pgid: Int32, uid: UInt32, tty: Int32?, start: Double, comm: String, path: String, sessionLeader: Bool = false) {
        self.pid = pid; self.ppid = ppid; self.pgid = pgid; self.uid = uid; self.tty = tty
        self.start = start; self.comm = comm; self.path = path; self.sessionLeader = sessionLeader
    }

    /// Saved tables (the self-check's fixtures) may leave out what does not matter to a case.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pid = try c.decode(Int32.self, forKey: .pid)
        ppid = try c.decodeIfPresent(Int32.self, forKey: .ppid) ?? 1
        pgid = try c.decodeIfPresent(Int32.self, forKey: .pgid) ?? pid
        uid = try c.decodeIfPresent(UInt32.self, forKey: .uid) ?? 501
        tty = try c.decodeIfPresent(Int32.self, forKey: .tty)
        start = try c.decodeIfPresent(Double.self, forKey: .start) ?? 1000
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        comm = try c.decodeIfPresent(String.self, forKey: .comm) ?? (path as NSString).lastPathComponent
        sessionLeader = try c.decodeIfPresent(Bool.self, forKey: .sessionLeader) ?? false
    }

    /// "pid:start", the same process across scans.
    var key: String { "\(pid):\(Int(start * 1000))" }
}

struct ProcUsage: Sendable, Equatable {
    var footprint: UInt64
    var cpuNanos: UInt64
}

struct TCPSocket: Sendable, Equatable {
    var localPort: Int
    var listening: Bool
    var established: Bool
}

struct MemoryReading: Sendable, Equatable {
    var total: UInt64
    var available: UInt64
    var compressed: UInt64
    var pressureLevel: Int32
}
