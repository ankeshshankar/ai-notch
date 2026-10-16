import Foundation

/// `AINotch --machine-selfcheck <fixtures.json>`: the machine guard's classifier and safety rules
/// against saved process tables (scripts/dev/machine-fixtures.json), and its idle, bulk and
/// config rules against a table of cases. Prints each check; exits 1 if any fails.
///
/// A fixture case: `processes` (ProcEntry fields plus `args`), and `expect`: `rows` (each a
/// `kind` and `root`, optionally `plan` "group"/"tree"/"none", `planPids`, `orphan`,
/// `editorChild`, `pids`), and `never`: pids no row may have as its root and no plan may signal.
enum MachineSelfCheck {
    private struct Fixtures: Decodable {
        var uid: UInt32
        var selfPid: Int32
        var cases: [Case]
    }

    private struct Case: Decodable {
        var name: String
        var processes: [Process]
        var expect: Expect
    }

    private struct Process: Decodable {
        var entry: ProcEntry
        var args: [String]?

        init(from decoder: Decoder) throws {
            entry = try ProcEntry(from: decoder)
            args = try decoder.container(keyedBy: Keys.self).decodeIfPresent([String].self, forKey: .args)
        }

        enum Keys: String, CodingKey { case args }
    }

    private struct Expect: Decodable {
        var rows: [Row]
        var never: [Int32]?
    }

    private struct Row: Decodable {
        var kind: MachineKind
        var root: Int32
        var plan: String?
        var planPids: [Int32]?
        var orphan: Bool?
        var editorChild: Bool?
        var pids: [Int32]?
        var watch: Bool?
    }

    private static var failures = 0
    private static var passes = 0

    private static func check(_ ok: Bool, _ what: String) {
        if ok { passes += 1 } else { failures += 1 }
        print("\(ok ? "PASS" : "FAIL") \(what)")
    }

    static func run(fixtures path: String) -> Int32 {
        guard let data = FileManager.default.contents(atPath: path) else {
            print("cannot read \(path)")
            return 2
        }
        let fixtures: Fixtures
        do {
            fixtures = try JSONDecoder().decode(Fixtures.self, from: data)
        } catch {
            print("cannot parse \(path): \(error)")
            return 2
        }
        for item in fixtures.cases { runCase(item, uid: fixtures.uid, selfPid: fixtures.selfPid) }
        ruleChecks()
        print("\(passes) passed, \(failures) failed")
        return failures == 0 ? 0 : 1
    }

    private static func runCase(_ item: Case, uid: UInt32, selfPid: Int32) {
        let table = item.processes.map(\.entry)
        var args: [Int32: [String]] = [:]
        for process in item.processes { if let a = process.args { args[process.entry.pid] = a } }
        let rows = MachineRules.rows(table: table, args: args, uid: uid, selfPid: selfPid)
        let found = Set(rows.map { "\($0.kind.rawValue):\($0.root.pid)" })
        let wanted = Set(item.expect.rows.map { "\($0.kind.rawValue):\($0.root)" })
        check(found == wanted, "\(item.name): rows \(found.sorted()) == \(wanted.sorted())")
        var signalled: Set<Int32> = []
        var offered: Set<Int32> = []
        for row in rows {
            let plan = MachineRules.closePlan(for: row, table: table, args: args, selfPid: selfPid)
            signalled.formUnion(plan.pids)
            if plan.pids.contains(row.root.pid) || (row.kind.action == .shutDown) { offered.insert(row.root.pid) }
            signalled.formUnion(MachineRules.treePids(of: row, table: table, args: args, selfPid: selfPid).filter { _ in row.kind.action == .close && !(plan.name == "none") })
            // Nothing a plan signals is ever protected or someone else's.
            let byPid = Dictionary(table.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
            let bad = plan.pids.filter { pid in byPid[pid].map { MachineRules.isProtected($0, args: args[pid], selfPid: selfPid) || $0.uid != uid } ?? true }
            check(bad.isEmpty, "\(item.name): \(row.kind.rawValue) \(row.root.pid) plan signals nothing protected\(bad.isEmpty ? "" : " (got \(bad))")")
            guard let want = item.expect.rows.first(where: { $0.root == row.root.pid && $0.kind == row.kind }) else { continue }
            if let name = want.plan { check(plan.name == name, "\(item.name): \(row.kind.rawValue) \(row.root.pid) plan \(plan.name) == \(name)") }
            if let pids = want.planPids { check(plan.pids.sorted() == pids.sorted(), "\(item.name): \(row.kind.rawValue) \(row.root.pid) plan pids \(plan.pids.sorted()) == \(pids.sorted())") }
            if let orphan = want.orphan { check(row.orphan == orphan, "\(item.name): \(row.kind.rawValue) \(row.root.pid) orphan \(row.orphan) == \(orphan)") }
            if let editor = want.editorChild { check(row.editorChild == editor, "\(item.name): \(row.kind.rawValue) \(row.root.pid) editorChild \(row.editorChild) == \(editor)") }
            if let pids = want.pids { check(row.pids.sorted() == pids.sorted(), "\(item.name): \(row.kind.rawValue) \(row.root.pid) pids \(row.pids.sorted()) == \(pids.sorted())") }
            if let watch = want.watch { check(row.match.watch == watch, "\(item.name): \(row.kind.rawValue) \(row.root.pid) watch \(row.match.watch) == \(watch)") }
        }
        for pid in item.expect.never ?? [] {
            // Shown is fine (adb, watchman, a Jest the editor started); offered a Close or signalled is not.
            // The Simulator's Shut down is simctl, never a signal: a device root listed here must not be offered.
            check(!offered.contains(pid) && !signalled.contains(pid), "\(item.name): pid \(pid) never offered a close or signalled")
        }
    }

    private static func ruleChecks() {
        let after = 900.0
        typealias S = MachineRowState
        let cases: [(MachineKind, Bool, Int, Bool, Double, S, String)] = [
            (.metro, false, 1, false, 3600, .inUse, "Metro with a client is in use, however quiet"),
            (.metro, false, 1, true, 0, .inUse, "Metro orphan with a client stays in use"),
            (.metro, false, 0, false, 899, .running, "Metro quiet 14m59s is running"),
            (.metro, false, 0, false, 900, .idle(minutes: 15), "Metro quiet 15m is idle"),
            (.metro, false, 0, true, 0, .idle(minutes: 0), "Metro orphan without a client is idle at once"),
            (.jest, false, 0, false, 7200, .running, "plain Jest is never idle"),
            (.jest, true, 0, false, 900, .idle(minutes: 15), "Jest --watch quiet 15m is idle"),
            (.jest, true, 0, false, 600, .running, "Jest --watch quiet 10m is running"),
            (.jest, false, 0, true, 0, .idle(minutes: 0), "orphan Jest worker is idle at once"),
            (.verify, false, 0, true, 9999, .running, "make verify is never idle, even orphaned"),
            (.turbo, false, 0, false, 9999, .running, "turbo is never idle"),
            (.gradle, false, 0, false, 599, .running, "Gradle quiet 9m59s is running"),
            (.gradle, false, 0, false, 600, .idle(minutes: 10), "Gradle quiet 10m is idle"),
            (.gradle, false, 0, true, 0, .running, "a Gradle daemon is not idle for being parentless"),
            (.kotlin, false, 0, false, 600, .idle(minutes: 10), "Kotlin daemon quiet 10m is idle"),
            (.emulator, false, 0, true, 9999, .running, "the emulator is never idle"),
            (.simulator, false, 0, false, 9999, .running, "the Simulator is never idle"),
        ]
        for (kind, watch, clients, orphan, quiet, want, what) in cases {
            check(MachineRules.state(kind: kind, watch: watch, clients: clients, orphan: orphan, quietFor: quiet, idleAfter: after) == want, what)
        }

        func row(_ kind: MachineKind, _ state: S, cpu: Double = 0, canClose: Bool = true) -> MachineRow {
            MachineRow(id: "\(kind.rawValue)-\(cpu)-\(canClose)", kind: kind, title: kind.label, pid: 1, start: 0, footprintMB: 100,
                       state: state, canClose: canClose, whyNot: nil, cpuLastMinute: cpu, processCount: 1)
        }
        let idle = S.idle(minutes: 20)
        let picked = MachineRules.bulkSelection([
            row(.metro, idle), row(.jest, idle), row(.gradle, idle), row(.kotlin, idle),
            row(.emulator, idle), row(.simulator, idle), row(.verify, idle), row(.turbo, idle), row(.adb, idle), row(.watchman, idle),
            row(.metro, .running), row(.jest, .inUse), row(.metro, idle, cpu: 0.06), row(.jest, idle, canClose: false),
        ]).map(\.id)
        check(picked == ["metro-0.0-true", "jest-0.0-true", "gradle-0.0-true", "kotlin-0.0-true"],
              "bulk takes idle Metro, Jest, Gradle, Kotlin only: never the emulator, the Simulator, verify, turbo, adb, watchman, a busy (>5% CPU) or unclosable row (got \(picked))")
        check(MachineRules.bulkSelection([row(.metro, idle, cpu: 0.05)]).count == 1, "bulk takes a row at exactly 5% CPU")

        let reading = MemoryReading(total: 24 << 30, available: 3 << 30, compressed: 8 << 30, pressureLevel: 2)
        let memory = MachineMemory(reading)
        check(memory.availableTenths == 30 && memory.totalTenths == 240 && memory.usedTenths == 210 && memory.pressure == .warning,
              "memory rounds to 0.1 GB; level 2 is warning")
        check(MachineMemory(MemoryReading(total: 1, available: 1, compressed: 0, pressureLevel: 4)).pressure == .critical, "level 4 is critical")
        check(MachineMemory(MemoryReading(total: 24 << 30, available: (98 << 30) / 10, compressed: 0, pressureLevel: 1))
              == MachineMemory(MemoryReading(total: 24 << 30, available: (98 << 30) / 10 + (20 << 20), compressed: 0, pressureLevel: 1)),
              "20 MB less used is the same snapshot (no publish)")
        check(MachineSource.roundMB(1_500 << 20) == 1500 && MachineSource.roundMB(523 << 20) == 520, "footprints round to 100 MB over 1 GB, 10 MB under")

        let parsed = BuildsConfig.parse(Data(#"{"machine":{"warnBelowMB":12000,"idleMinutes":5,"exclude":["watchman","nope"]}}"#.utf8))
        check(parsed?.machine?.warnBelowMB == 12000 && parsed?.machine?.idleMinutes == 5 && parsed?.machine?.exclude == [.watchman],
              "builds.json machine part parses")
        check(BuildsConfig.parse(Data(#"{"machine":{"idleMinutes":1,"warnBelowMB":true}}"#.utf8))?.machine == MachineConfig(warnBelowMB: 4096, idleMinutes: 1),
              "idleMinutes 1 is read as 1 (not taken for a boolean); warnBelowMB true is ignored")
        check(parsed?.problems.contains { $0.contains("nope") } == true, "an unknown exclude kind is reported")
        check(BuildsConfig.parse(Data("{}".utf8))?.machine == nil && MachineConfig().warnBelowMB == 4096 && MachineConfig().idleMinutes == 15,
              "no machine part: defaults 4096 MB, 15 min")
    }
}
