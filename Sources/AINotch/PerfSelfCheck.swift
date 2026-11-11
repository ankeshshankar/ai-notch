import Foundation

// `AINotch --perf-selfcheck`: the speed work's pure parts on made-up inputs: the shared process
// table (one read serves callers inside its age, a failed read is not kept), the ledger's write
// gap, the log's rotation. No UI, no network. Exits 1 on any failure.

enum PerfSelfCheck {
    static func runIfAsked(_ arguments: [String]) {
        guard arguments.contains("--perf-selfcheck") else { return }
        exit(run())
    }

    static func run() -> Int32 {
        var failures = 0, checks = 0
        func expect(_ condition: Bool, _ what: String) {
            checks += 1
            if !condition { failures += 1; print("FAIL \(what)") }
        }

        // The shared process table.
        ProcessList.resetShared()
        let entry = ProcEntry(pid: 1, ppid: 0, pgid: 1, uid: 0, tty: nil, start: 1, comm: "launchd", path: "")
        var reads = 0
        let reader: () -> [ProcEntry]? = { reads += 1; return [entry] }
        expect(ProcessList.sharedTable(maxAge: 2.5, now: 100, read: reader)?.count == 1 && reads == 1, "first call reads")
        expect(ProcessList.sharedTable(maxAge: 2.5, now: 101, read: reader) != nil && reads == 1, "a call inside the age shares the read")
        expect(ProcessList.sharedTable(maxAge: 1.5, now: 101.6, read: reader) != nil && reads == 2, "a stricter caller reads again")
        expect(ProcessList.sharedTable(maxAge: 2.5, now: 102.5, read: reader) != nil && reads == 2, "and its read serves the others")
        expect(ProcessList.sharedTable(maxAge: 2.5, now: 110, read: reader) != nil && reads == 3, "an old read is not reused")
        var failedReads = 0
        expect(ProcessList.sharedTable(maxAge: 0, now: 120, read: { failedReads += 1; return nil }) == nil && failedReads == 1, "a failed read says nil")
        expect(ProcessList.sharedTable(maxAge: 2.5, now: 120.5, read: reader) != nil && reads == 4, "a failed read is not kept")
        ProcessList.resetShared()

        // The ledger is written at most every gap while it changes, at once the first time.
        let t = Date(timeIntervalSince1970: 10_000)
        expect(!UsageScanner.shouldWrite(unsavedSince: nil, lastWrite: .distantPast, now: t), "nothing changed: no write")
        expect(UsageScanner.shouldWrite(unsavedSince: t, lastWrite: .distantPast, now: t), "first change: written at once")
        expect(!UsageScanner.shouldWrite(unsavedSince: t, lastWrite: t.addingTimeInterval(-30), now: t), "30 s after a write: held")
        expect(UsageScanner.shouldWrite(unsavedSince: t, lastWrite: t.addingTimeInterval(-UsageScanner.minWriteGap), now: t), "a full gap after a write: written")

        // The log rotates at its size, keeping one previous file.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ai-notch-log-\(getpid())", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let savedURL = NotchLog.url, savedMax = NotchLog.maxBytes
        NotchLog.url = dir.appendingPathComponent("notch.log")
        NotchLog.maxBytes = 400
        let previous = NotchLog.url.appendingPathExtension("1")
        for i in 0..<5 { NotchLog.append("line \(i) " + String(repeating: "x", count: 60)) }
        expect(!FileManager.default.fileExists(atPath: previous.path), "under the size: no rotation")
        for i in 5..<12 { NotchLog.append("line \(i) " + String(repeating: "x", count: 60)) }
        let current = (try? String(contentsOf: NotchLog.url, encoding: .utf8)) ?? ""
        let old = (try? String(contentsOf: previous, encoding: .utf8)) ?? ""
        expect(old.contains("line "), "rotated into .1")
        expect(current.contains("line 11") && !current.contains("line 0 "), "the new file starts fresh and keeps writing")
        for i in 12..<40 { NotchLog.append("line \(i) " + String(repeating: "x", count: 60)) }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()) ?? []
        expect(files == ["notch.log", "notch.log.1"], "only one previous file is kept")
        expect(!((try? String(contentsOf: previous, encoding: .utf8)) ?? "").contains("line 0 "), "the oldest lines are gone")
        NotchLog.url = savedURL
        NotchLog.maxBytes = savedMax
        try? FileManager.default.removeItem(at: dir)

        print("perf selfcheck: \(checks - failures)/\(checks)")
        return failures == 0 ? 0 : 1
    }
}
