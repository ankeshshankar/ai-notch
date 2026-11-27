import Foundation

/// Generic live runs for tests, the self-check and the window preview (dev only; invented names throughout): a
/// review folder plus a main transcript and one session file per reviewer, in the shape Claude Code writes them.
public enum ReviewLiveFixture {
    public enum Spec: Sendable, Equatable {
        case waiting
        /// Working: has opened this many files.
        case working(reads: Int)
        /// Done, with the severities it reported.
        case done(findings: [String])
        /// Its session ended without a report.
        case failed
    }

    public struct Reviewer: Sendable {
        public var area: String
        public var chunk: Int
        public var spec: Spec
        /// The first pass failed to report (an old report may sit in the folder) and this is the run again.
        public var secondPass = false
        public init(area: String, chunk: Int, spec: Spec, secondPass: Bool = false) {
            self.area = area; self.chunk = chunk; self.spec = spec; self.secondPass = secondPass
        }
    }

    public struct Scenario: Sendable {
        public var files: Int
        public var chunks: Int
        public var reviewers: [Reviewer]
        /// Seconds since the newest step, at `now`.
        public var quietFor: Double = 3
        /// `gate.json` is written and the main session has finished: the run is closing.
        public var closing = false
        public var stage: ReviewProgressFixture.Stage = .halfDone
    }

    static let allAreas = ["correctness", "security", "data", "tests", "compat", "conventions"]

    /// A PR with 6 files: six reviewers, each reading all of them.
    public static func small(_ states: [Spec]) -> Scenario {
        Scenario(files: 6, chunks: 1, reviewers: zip(allAreas, states).map { Reviewer(area: $0, chunk: 1, spec: $1) })
    }

    /// A PR with 168 files in 6 chunks and 16 reviewers.
    public static func large(working: Int, done: Int) -> Scenario {
        let plan: [(String, [Int])] = [("correctness", [1, 2, 3, 4, 5, 6]), ("security", [1, 3, 5]), ("data", [2, 4]), ("tests", [3, 6]), ("compat", [1, 5]), ("conventions", [2])]
        var list: [Reviewer] = []
        for (area, chunks) in plan { for chunk in chunks { list.append(Reviewer(area: area, chunk: chunk, spec: .waiting)) } }
        // Some finished, some at work (spread over the areas), the rest wait.
        let doneAt = Array([0, 1, 6, 8, 9, 12].prefix(done)), workAt = Array([2, 3, 7, 10, 11, 4, 5, 13].prefix(working))
        for (n, i) in doneAt.enumerated() { list[i].spec = .done(findings: n == 0 ? ["SHOULD-FIX"] : n == 2 ? ["BLOCKING"] : n == 3 ? ["NIT", "NIT"] : []) }
        for (n, i) in workAt.enumerated() { list[i].spec = .working(reads: 5 + (n * 7) % 16) }
        return Scenario(files: 168, chunks: 6, reviewers: list)
    }

    public static func paths(_ count: Int, chunks: Int) -> [String] {
        let per = max(1, (count + chunks - 1) / chunks)
        return (0..<count).map { "src/module-\($0 / per + 1)/unit-\($0 + 1).ts" }
    }

    static func chunk(of index: Int, count: Int, chunks: Int) -> Int { index / max(1, (count + chunks - 1) / chunks) + 1 }

    static func ledger(_ s: Scenario) -> String {
        let all = paths(s.files, chunks: s.chunks)
        let rows = all.enumerated().map { index, path -> String in
            let chunk = chunk(of: index, count: s.files, chunks: s.chunks)
            let who = Array(NSOrderedSet(array: s.reviewers.filter { $0.chunk == chunk }.map(\.area))).compactMap { $0 as? String }.map { "\"\($0)\"" }.joined(separator: ",")
            return #"{"path":"\#(path)","added":10,"removed":2,"tags":[\#(index < 3 ? "\"payments\"" : "")],"chunk":\#(chunk),"reviewers":[\#(who)],"read":false,"findings":[]}"#
        }
        return #"{"head":"aaaa","base":"bbbb","files":[\#(rows.joined(separator: ","))],"generatedSkipped":[]}"#
    }

    static func lensText(_ r: Reviewer, _ s: Scenario, findings: [String]) -> String {
        let all = paths(s.files, chunks: s.chunks)
        let mine = all.enumerated().filter { chunk(of: $0.offset, count: s.files, chunks: s.chunks) == r.chunk }.map(\.element)
        var text = "AREA: \(r.area)   CHUNK: \(r.chunk)/\(s.chunks)   RANGE: bbbb..aaaa\nFILES:\n"
        for path in mine { text += "- \(path) — nothing found — checked: the call sites\n" }
        text += "FINDINGS:\n"
        for (i, severity) in findings.enumerated() { text += "- R\(i + 1) [\(severity)] \(mine[min(i * 2, mine.count - 1)]):\(10 + i) — a finding\n  fix: a fix\n" }
        return text + "TRACE: none\n"
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func line(_ type: String, at t: Double, content: Any, stop: String? = nil) -> String {
        var message: [String: Any] = ["role": type, "content": content]
        if let stop { message["stop_reason"] = stop }
        let object: [String: Any] = ["type": type, "timestamp": iso.string(from: Date(timeIntervalSince1970: t)), "message": message]
        return String(data: (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data(), encoding: .utf8) ?? ""
    }

    private static func tool(_ name: String, _ input: [String: Any], at t: Double) -> String {
        line("assistant", at: t, content: [["type": "tool_use", "id": "t\(Int(t * 10))", "name": name, "input": input]], stop: "tool_use")
    }

    /// Writes the folder, the main transcript and the reviewers' files; returns the transcript. Times run back from `now - quietFor`.
    @discardableResult
    public static func write(_ s: Scenario, folder: URL, transcriptDir: URL, now: Double) -> URL {
        let fm = FileManager.default
        try? fm.removeItem(at: folder)
        try? fm.removeItem(at: transcriptDir)
        ReviewProgressFixture.writeFull(.gather, to: folder)
        ReviewProgressFixture.put(ledger(s), "ledger.json", folder)
        let all = paths(s.files, chunks: s.chunks)
        let sub = transcriptDir.appendingPathComponent("session/subagents", isDirectory: true)
        try? fm.createDirectory(at: sub, withIntermediateDirectories: true)
        let end = now - s.quietFor
        var main: [String] = [line("user", at: end - 400, content: "Review the pull request.")]
        for (n, reviewer) in s.reviewers.enumerated() {
            let mine = all.enumerated().filter { chunk(of: $0.offset, count: s.files, chunks: s.chunks) == reviewer.chunk }.map(\.element)
            func session(pass: Int, spec: Spec, start: Double) {
                let name = LensReportName(area: reviewer.area, chunk: reviewer.chunk, pass: pass)
                var out = [line("user", at: start, content: "Review your files. REPORT: \(folder.path)/\(name.file) when done.")]
                let reads: Int
                switch spec { case .waiting: return; case .working(let r): reads = min(r, mine.count); case .done, .failed: reads = mine.count }
                for i in 0..<reads {
                    // Spread over the pass, so the activity graph has a steady beat up to the newest step.
                    let t = start + (end - 1 - start) * Double(i + 1) / Double(reads + 1)
                    out.append(tool(i % 4 == 3 ? "Grep" : "Read", ["file_path": "\(folder.path)/wt/\(mine[i])", "pattern": "x"], at: t))
                }
                switch spec {
                case .done(let findings):
                    out.append(tool("Write", ["file_path": "\(folder.path)/\(name.file)"], at: end - 1))
                    out.append(line("assistant", at: end - 0.5, content: [["type": "text", "text": "done"]], stop: "end_turn"))
                    ReviewProgressFixture.put(lensText(reviewer, s, findings: findings), name.file, folder)
                case .failed:
                    out.append(line("assistant", at: end - 0.5, content: [["type": "text", "text": "stopped"]], stop: "end_turn"))
                default: break
                }
                try? (out.joined(separator: "\n") + "\n").write(to: sub.appendingPathComponent("agent-\(reviewer.area)-\(reviewer.chunk)-\(pass).jsonl"), atomically: true, encoding: .utf8)
            }
            if reviewer.secondPass {
                // The first pass found no code and ended; an old report of it sits in the folder, and is not used.
                session(pass: 1, spec: .failed, start: end - 300)
                ReviewProgressFixture.put("AREA: \(reviewer.area)\nFILES:\nFINDINGS:\n", LensReportName(area: reviewer.area, chunk: reviewer.chunk).file, folder)
                session(pass: 2, spec: reviewer.spec, start: end - 200 + Double(n))
            } else {
                session(pass: 1, spec: reviewer.spec, start: end - 200 + Double(n))
            }
            main.append(tool("Agent", ["description": "Lens \(reviewer.area)"], at: end - 210 + Double(n)))
        }
        if s.stage == .finalCheck || s.closing {
            ReviewProgressFixture.put("F1 blocking\nGATE: NOT_READY\nVERDICT: REQUEST CHANGES", "review.md", folder)
        }
        if s.closing {
            ReviewProgressFixture.put("[]", "drops.json", folder)
            ReviewProgressFixture.put(#"[{"id":"c1","finding":"F1","severity":"blocking","path":"a","line":1,"body":"b"}]"#, "comments.json", folder)
            ReviewProgressFixture.put(#"{"gate":"NOT_READY","reasons":[]}"#, "gate.json", folder)
            main.append(tool("Write", ["file_path": "\(folder.path)/gate.json"], at: end - 2))
            main.append(line("assistant", at: end - 1, content: [["type": "text", "text": "done"]], stop: "end_turn"))
        } else {
            main.append(tool("Bash", ["command": "git -C x log"], at: end - 4))
        }
        let transcript = transcriptDir.appendingPathComponent("session.jsonl")
        try? (main.joined(separator: "\n") + "\n").write(to: transcript, atomically: true, encoding: .utf8)
        return transcript
    }

    /// The named scenarios of `--review-window-preview --progress <name>`; nil for a name that is not one.
    public static func named(_ name: String) -> Scenario? {
        let working = Spec.working(reads: 3)
        switch name {
        case "small": return small([.done(findings: ([])), .done(findings: (["SHOULD-FIX"])), .working(reads: 4), .working(reads: 2), .waiting, .waiting])
        case "large": return large(working: 5, done: 6)
        case "stalled":
            var s = small([working, working, .done(findings: ([])), working, .waiting, .waiting])
            s.quietFor = 130
            return s
        case "closing":
            var s = small([.done(findings: (["BLOCKING"])), .done(findings: (["SHOULD-FIX", "NIT"])), .done(findings: ([])), .done(findings: ([])), .done(findings: (["NIT"])), .done(findings: ([]))])
            s.closing = true
            s.quietFor = 40
            return s
        case "second":
            var s = small([.done(findings: (["SHOULD-FIX"])), .working(reads: 3), .done(findings: ([])), .working(reads: 5), .done(findings: (["NIT"])), .done(findings: ([]))])
            for i in s.reviewers.indices { s.reviewers[i].secondPass = true }
            return s
        case "tilefail": return small([.done(findings: ([])), .failed, .working(reads: 2), .done(findings: (["NIT"])), .waiting, .waiting])
        default: return nil
        }
    }
}
