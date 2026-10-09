import Darwin

/// The process table, read with sysctl.
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
}
