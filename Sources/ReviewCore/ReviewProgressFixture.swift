import Foundation

/// Generic mid-run review folders for tests, the self-check and the window preview (dev only; no real names).
public enum ReviewProgressFixture {
    public enum Stage: String, Sendable { case gather, listed, halfDone, finalCheck, finished }

    /// 24 files in 3 chunks; security and correctness read every chunk, data, compat and tests one: 9 dispatches.
    public static let areas: [(String, [Int])] = [("security", [1, 2, 3]), ("correctness", [1, 2, 3]), ("data", [1]), ("compat", [2]), ("tests", [3])]

    public static func filePaths() -> [String] { (1...24).map { "src/area-\(($0 - 1) / 8 + 1)/file-\($0).ts" } }

    static func put(_ text: String, _ name: String, _ folder: URL) { try? text.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8) }

    static func ledgerJSON() -> String {
        let rows = filePaths().enumerated().map { index, path -> String in
            let chunk = index / 8 + 1
            let reviewers = areas.filter { $0.1.contains(chunk) }.map { "\"\($0.0)\"" }.joined(separator: ",")
            let tags = index < 6 ? "\"payments\"" : index < 9 ? "\"auth\"" : ""
            return #"{"path":"\#(path)","added":10,"removed":2,"tags":[\#(tags)],"chunk":\#(chunk),"reviewers":[\#(reviewers)],"read":false,"findings":[]}"#
        }
        return #"{"head":"aaaa","base":"bbbb","files":[\#(rows.joined(separator: ","))],"generatedSkipped":[]}"#
    }

    static func lensText(area: String, chunk: Int, findings: [String]) -> String {
        let paths = filePaths().enumerated().filter { $0.offset / 8 + 1 == chunk }.map(\.element)
        var text = "AREA: \(area)   CHUNK: \(chunk)/3   RANGE: bbbb..aaaa\nFILES:\n"
        for path in paths { text += "- \(path) — nothing found — checked: the call sites\n" }
        text += "FINDINGS:\n"
        for (i, severity) in findings.enumerated() { text += "- R\(i + 1) [\(severity)] \(paths[0]):\(10 + i) — a finding\n  fix: a fix\n" }
        text += "TRACE: none\n"
        return text
    }

    /// Writes the files a full review has by `stage` (pipeline green, three open comments from others).
    public static func writeFull(_ stage: Stage, to folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        put(#"{"title":"fixture"}"#, "pr.json", folder)
        put(#"{"state":"green"}"#, "ci.json", folder)
        put(#"[{"id":1,"asks":true,"resolved":false},{"id":2,"asks":true,"resolved":false},{"id":3,"asks":true},{"id":4,"asks":false}]"#, "others.json", folder)
        put("brief", "brief.md", folder)
        if stage == .gather { return }
        put(ledgerJSON(), "ledger.json", folder)
        if stage == .listed { return }
        let doneCount = stage == .halfDone ? 4 : 9
        var n = 0
        // The ledger lists dispatches by the first file that names them: chunk by chunk.
        for chunk in 1...3 {
            for (area, chunks) in areas where chunks.contains(chunk) {
                n += 1
                if n <= doneCount { put(lensText(area: area, chunk: chunk, findings: n == 1 ? ["BLOCKING", "NIT"] : n == 3 ? ["SHOULD-FIX"] : []), "lens-\(area)-\(chunk).md", folder) }
            }
        }
        if stage == .halfDone { return }
        put("F1 blocking\nGATE: NOT_READY\nVERDICT: REQUEST CHANGES", "review.md", folder)
        if stage == .finalCheck { return }
        put("[]", "drops.json", folder)
        put(#"[{"id":"c1","finding":"F1","severity":"blocking","path":"a","line":1,"body":"b"}]"#, "comments.json", folder)
        put(#"{"gate":"NOT_READY","reasons":[]}"#, "gate.json", folder)
    }

    public static func writeFollowUp(started: Bool, finished: Bool = false, to folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if started { put("{}", "followup-input.json", folder); put("diff", "followup.diff", folder) }
        if finished { put("{}", "followup.json", folder) }
    }

    public static func sessionJSON(title: String, startedAt: Double, updatedAt: Double, tool: String?, agentsRunning: Int) -> Data {
        var object: [String: Any] = ["sessionTitle": title, "startedAt": startedAt, "updatedAt": updatedAt, "toolCount": 12,
                                     "agents": (0..<agentsRunning).map { ["id": "a\($0)", "type": "lens", "startedAt": startedAt] as [String: Any] }]
        if let tool { object["current"] = ["id": "t", "name": tool, "since": updatedAt] as [String: Any] }
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }
}
