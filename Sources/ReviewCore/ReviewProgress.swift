import Foundation

// What a running review is doing, read from its folder. A full review fills the folder in a fixed order
// (`brief.md`, `ledger.json`, one `lens-<area>-<k>.md` per reviewer dispatch, then `review.md`, `comments.json`,
// `gate.json`); a follow-up and a reply read have fewer files. Nothing here starts, changes or posts anything: the
// folder is only read, and what a reviewer wrote before the final check is "not yet checked" and never a card.
// No AppKit, no network.

public enum ReviewRunKind: String, Sendable, Equatable {
    case full, followUp, replies
}

public enum ReviewStepState: String, Sendable, Equatable {
    case done, current, pending
}

public struct ReviewStepRow: Sendable, Equatable {
    public var id: String
    public var title: String
    public var state: ReviewStepState
    /// What the step found, once done ("168 files, 9 chunks, risk: payments, auth").
    public var fact: String?
}

public enum DispatchState: String, Sendable, Equatable {
    case waiting, running, done
    /// The reviewer's session ended and wrote no report (a later pass may be on its way).
    case failed
}

/// What one reviewer reported, by the words it used (BLOCKING, SHOULD-FIX, NIT, PRE-EXISTING).
public struct ReportedFindings: Sendable, Equatable {
    public var blocking = 0, shouldFix = 0, nits = 0, preExisting = 0
    public var total: Int { blocking + shouldFix + nits + preExisting }

    public init(blocking: Int = 0, shouldFix: Int = 0, nits: Int = 0, preExisting: Int = 0) {
        self.blocking = blocking; self.shouldFix = shouldFix; self.nits = nits; self.preExisting = preExisting
    }

    public static func + (a: Self, b: Self) -> Self {
        Self(blocking: a.blocking + b.blocking, shouldFix: a.shouldFix + b.shouldFix, nits: a.nits + b.nits, preExisting: a.preExisting + b.preExisting)
    }

    /// "1 blocking, 2 should-fix"; "none" when empty.
    public var text: String {
        let parts = [(blocking, "blocking"), (shouldFix, "should-fix"), (nits, "nit\(nits == 1 ? "" : "s")"), (preExisting, "pre-existing")]
            .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
        return parts.isEmpty ? "none" : parts.joined(separator: ", ")
    }
}

public struct ReviewerRowInfo: Sendable, Equatable {
    public var area: String
    public var chunk: Int
    /// The review's chunk count; 1 means there is no "2 of 3" to say.
    public var chunks: Int
    public var state: DispatchState
    /// Files this dispatch was given, and (when done) how many its report lists.
    public var filesGiven: Int
    public var filesReported: Int?
    public var findings: ReportedFindings?
    /// 1 for the first pass; 2 when the reviewer was run again (report `lens-<area>-<k>b.md`).
    public var pass = 1
    /// What its session is doing now ("reading cron.service.ts"); nil without a session file.
    public var doing: String?
    /// Files of the ledger its session has opened.
    public var filesRead = 0
    public var lastAt: Double = 0

    public var title: String {
        let name = area.prefix(1).uppercased() + area.dropFirst()
        return chunks > 1 ? "\(name) \(chunk) of \(chunks)" : name
    }

    /// "Security 2", "Tests": for a tile.
    public var shortTitle: String {
        let name = area.prefix(1).uppercased() + area.dropFirst()
        return chunks > 1 ? "\(name) \(chunk)" : name
    }
}

/// What the headless run is doing right now, from the session state the notch's hook keeps.
public struct ReviewActivity: Sendable, Equatable {
    public var tool: String?
    public var agentTool: String?
    public var agentsRunning: Int
    public var toolCount: Int
    public var updatedAt: Double
    /// The run's transcript, where its reviewers' own files are found beside it.
    public var transcript: String?

    public init(tool: String? = nil, agentTool: String? = nil, agentsRunning: Int = 0, toolCount: Int = 0, updatedAt: Double = 0, transcript: String? = nil) {
        self.tool = tool; self.agentTool = agentTool; self.agentsRunning = agentsRunning; self.toolCount = toolCount; self.updatedAt = updatedAt; self.transcript = transcript
    }

    /// A tool's name in plain words.
    public static func words(_ tool: String) -> String {
        let name = tool.hasPrefix("mcp__") ? (tool.components(separatedBy: "__").last ?? tool) : tool
        switch name {
        case "Read": return "Reading a file"
        case "Grep", "Glob": return "Searching the code"
        case "Bash": return "Running a command"
        case "Write": return "Writing a report"
        case "Agent", "Task": return "Starting a reviewer"
        default: return name
        }
    }

    /// The newest of the session files whose title is `title` and that began at or after `since`; nil when none.
    public static func parse(_ sessions: [Data], title: String, since: Double) -> ReviewActivity? {
        var best: ReviewActivity?
        for data in sessions {
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  object["sessionTitle"] as? String == title,
                  (object["startedAt"] as? Double ?? 0) >= since - 5 else { continue }
            let agents = object["agents"] as? [[String: Any]] ?? []
            let running = agents.filter { $0["endedAt"] == nil }
            let name = ((object["current"] as? [String: Any])?["name"] as? String)
                ?? running.compactMap { ($0["current"] as? [String: Any])?["name"] as? String }.first
                ?? ((object["lastTool"] as? [String: Any])?["name"] as? String)
            let found = ReviewActivity(tool: name, agentTool: running.compactMap { ($0["current"] as? [String: Any])?["name"] as? String }.first,
                                       agentsRunning: running.count, toolCount: object["toolCount"] as? Int ?? 0,
                                       updatedAt: object["updatedAt"] as? Double ?? 0,
                                       transcript: object["transcriptPath"] as? String)
            if best == nil || found.updatedAt > best!.updatedAt { best = found }
        }
        return best
    }
}

public struct ReviewProgress: Sendable, Equatable {
    public var kind: ReviewRunKind
    public var steps: [ReviewStepRow]
    public var reviewers: [ReviewerRowInfo]
    public var filesTotal: Int
    public var filesReported: Int
    /// Reviewer findings so far: not yet checked by the final check.
    public var liveFindings: ReportedFindings
    /// The final check wrote `comments.json`.
    public var checked: Bool
    public var activity: ReviewActivity?
    /// One cell per changed file, in the ledger's order.
    public var fileMap: [ReviewFileCell] = []
    /// The session files, when they could be read.
    public var live: ReviewLive?
    /// `gate.json` is in the folder.
    public var gateWritten = false

    public var reviewersDone: Int { reviewers.filter { $0.state == .done }.count }
    public var reviewersTotal: Int { reviewers.count }
    public var current: ReviewStepRow? { steps.first { $0.state == .current } }

    /// "4/9": reviewers done of all, once there are reviewers to count; else nil.
    public var shortCount: String? { reviewers.isEmpty ? nil : "\(reviewersDone)/\(reviewersTotal)" }

    /// The suffix for a badge or chip: "4m · 3/9" while reviewers run, "4m · Final check" otherwise.
    public func suffix(elapsed: Double?) -> String {
        var parts: [String] = []
        if let elapsed { parts.append(ReviewProgress.short(elapsed)) }
        if let count = shortCount, current?.id == "reviewers" { parts.append(count) }
        else if let step = current, step.id != "reading" { parts.append(step.title) }
        return parts.joined(separator: " · ")
    }

    public static func short(_ seconds: Double) -> String {
        let s = Int(max(0, seconds))
        return s < 90 ? "\(s)s" : s < 3600 ? "\(s / 60)m" : "\(s / 3600)h \(s % 3600 / 60)m"
    }

    // MARK: Reading the folder

    public static func read(folder: URL, kind: ReviewRunKind, activity: ReviewActivity? = nil, live: ReviewLive? = nil, now: Double = Date().timeIntervalSince1970) -> ReviewProgress {
        switch kind {
        case .full: return readFull(folder, activity, live, now)
        case .followUp: var p = readFollowUp(folder, activity); p.live = live; return p
        case .replies: var p = readReplies(folder, activity); p.live = live; return p
        }
    }

    private static func exists(_ folder: URL, _ name: String) -> Bool { FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) }
    private static func json(_ folder: URL, _ name: String) -> Any? {
        (try? Data(contentsOf: folder.appendingPathComponent(name))).flatMap { try? JSONSerialization.jsonObject(with: $0) }
    }

    /// Marks the first step that is not done as the current one.
    private static func ordered(_ rows: [(String, String, Bool, String?)]) -> [ReviewStepRow] {
        var seenCurrent = false
        return rows.map { id, title, done, fact in
            if done { return ReviewStepRow(id: id, title: title, state: .done, fact: fact) }
            defer { seenCurrent = true }
            return ReviewStepRow(id: id, title: title, state: seenCurrent ? .pending : .current, fact: nil)
        }
    }

    /// "Pipeline green · 3 open comments from others", from `ci.json` and `others.json`; nil before either is there.
    static func gatherFact(_ folder: URL) -> String? {
        var parts: [String] = []
        if let ci = json(folder, "ci.json") {
            var state: String?
            if let object = ci as? [String: Any] {
                state = (object["state"] as? String) ?? ((object["values"] as? [[String: Any]])?.first.flatMap(pipelineState))
            }
            let word = (state ?? "").lowercased()
            if ["success", "green", "passed"].contains(where: word.contains) { parts.append("Pipeline green") }
            else if ["fail", "error", "red", "stopped"].contains(where: word.contains) { parts.append("Pipeline red") }
            else if ["progress", "running", "pending"].contains(where: word.contains) { parts.append("Pipeline running") }
        }
        if let others = json(folder, "others.json") as? [[String: Any]] {
            let open = others.filter { ($0["asks"] as? Bool ?? false) && !($0["resolved"] as? Bool ?? false) }.count
            parts.append(open == 0 ? "no open comments from others" : "\(open) open comment\(open == 1 ? "" : "s") from others")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func pipelineState(_ value: [String: Any]) -> String? {
        if let s = value["state"] as? String { return s }
        if let object = value["state"] as? [String: Any] { return (object["result"] as? [String: Any])?["name"] as? String ?? object["name"] as? String }
        return nil
    }

    struct LedgerFile {
        var paths: Set<String> = []
        var ordered: [String] = []
        var chunks = 1
        var tags: [String] = []
        /// Distinct (area, chunk) dispatches, in the ledger's order of first mention.
        var dispatches: [(area: String, chunk: Int)] = []
        var given: [String: Int] = [:]
        var count: Int { paths.count }
    }

    static func ledger(_ folder: URL) -> LedgerFile? {
        guard let object = json(folder, "ledger.json") as? [String: Any], let files = object["files"] as? [[String: Any]], !files.isEmpty else { return nil }
        var out = LedgerFile()
        var tagCount: [String: Int] = [:]
        var seen = Set<String>()
        var chunkSet = Set<Int>()
        for file in files {
            guard let path = file["path"] as? String else { continue }
            if out.paths.insert(path).inserted { out.ordered.append(path) }
            let chunk = file["chunk"] as? Int ?? 1
            chunkSet.insert(chunk)
            for tag in file["tags"] as? [String] ?? [] { tagCount[tag, default: 0] += 1 }
            for area in file["reviewers"] as? [String] ?? [] {
                let key = "\(area)-\(chunk)"
                out.given[key, default: 0] += 1
                if seen.insert(key).inserted { out.dispatches.append((area, chunk)) }
            }
        }
        out.chunks = max(chunkSet.count, 1)
        out.tags = tagCount.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
        return out
    }

    struct LensReport {
        var paths: [String] = []
        var findings = ReportedFindings()
        /// The file each finding sits on, with its severity.
        var found: [(path: String, severity: FindingSeverity)] = []
    }

    /// A reviewer's report: the paths on its `FILES:` lines and the severity words on its `FINDINGS:` lines.
    static func lens(_ text: String) -> LensReport {
        var report = LensReport()
        var section = ""
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line == "FILES:" { section = "files"; continue }
            if line == "FINDINGS:" { section = "findings"; continue }
            if raw.range(of: #"^[A-Z][A-Z-]+:"#, options: .regularExpression) != nil { section = ""; continue }
            guard raw.hasPrefix("- ") else { continue }
            if section == "files" {
                let body = String(raw.dropFirst(2))
                let path = body.components(separatedBy: " — ").first ?? body
                report.paths.append(path.trimmingCharacters(in: .whitespaces))
            } else if section == "findings" {
                var severity: FindingSeverity?
                if raw.contains("[BLOCKING]") { report.findings.blocking += 1; severity = .blocking }
                else if raw.contains("[SHOULD-FIX]") { report.findings.shouldFix += 1; severity = .shouldFix }
                else if raw.contains("[PRE-EXISTING]") { report.findings.preExisting += 1; severity = .preExisting }
                else if raw.contains("[NIT]") { report.findings.nits += 1; severity = .nit }
                if let severity, let close = raw.firstIndex(of: "]") {
                    let rest = raw[raw.index(after: close)...].trimmingCharacters(in: .whitespaces)
                    let spot = rest.components(separatedBy: " ").first ?? ""
                    let path = spot.range(of: #":\d+.*$"#, options: .regularExpression).map { String(spot[..<$0.lowerBound]) } ?? spot
                    if !path.isEmpty { report.found.append((path, severity)) }
                }
            }
        }
        return report
    }

    private static func safe(_ area: String) -> String {
        String(area.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || "-_".unicodeScalars.contains($0) })
    }

    /// The ledger path a full path from a session file stands for: the longest tail of it the ledger lists.
    static func ledgerPath(_ full: String, in paths: Set<String>) -> String? {
        let parts = full.split(separator: "/", omittingEmptySubsequences: true)
        for i in parts.indices {
            let candidate = parts[i...].joined(separator: "/")
            if paths.contains(candidate) { return candidate }
        }
        return nil
    }

    private static func readFull(_ folder: URL, _ activity: ReviewActivity?, _ live: ReviewLive?, _ now: Double) -> ReviewProgress {
        let ledger = ledger(folder)
        var reviewers: [ReviewerRowInfo] = []
        var reported = Set<String>()
        var liveFindings = ReportedFindings()
        var cells: [String: ReviewFileCell] = [:]
        if let ledger { for path in ledger.ordered { cells[path] = ReviewFileCell(path: path) } }
        let names = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
        let sessionsKnown = live.map { $0.found && !$0.agents.isEmpty } ?? false
        if let ledger {
            var runningLeft = activity.map { $0.agentsRunning } ?? Int.max
            for dispatch in ledger.dispatches {
                let area = safe(dispatch.area)
                let given = ledger.given["\(dispatch.area)-\(dispatch.chunk)"] ?? 0
                // Every pass of this dispatch: the newest report, and the newest session.
                let reportPass = (1...6).reversed().first { names.contains(LensReportName(area: area, chunk: dispatch.chunk, pass: $0).file) } ?? 0
                let livePasses = (live?.agents ?? [:]).filter { $0.key.area == area && $0.key.chunk == dispatch.chunk }
                let pass = max(reportPass, livePasses.keys.map(\.pass).max() ?? 1, 1)
                let agent = livePasses.first { $0.key.pass == pass }?.value
                var row = ReviewerRowInfo(area: dispatch.area, chunk: dispatch.chunk, chunks: ledger.chunks, state: .waiting, filesGiven: given,
                                          filesReported: nil, findings: nil, pass: pass)
                // Files this reviewer's sessions opened, over all its passes.
                var opened = Set<String>()
                for (_, other) in livePasses { for full in other.reads { if let p = ledgerPath(full, in: ledger.paths) { opened.insert(p) } } }
                for p in opened { cells[p]?.readers.append(row.shortTitle) }
                row.filesRead = agent.map { Set($0.reads.compactMap { ledgerPath($0, in: ledger.paths) }).count } ?? 0
                row.doing = agent?.doing
                row.lastAt = agent?.lastAt ?? 0
                if reportPass == pass, let text = try? String(contentsOf: folder.appendingPathComponent(LensReportName(area: area, chunk: dispatch.chunk, pass: pass).file), encoding: .utf8) {
                    let report = lens(text)
                    let listed = report.paths.filter { ledger.paths.contains($0) }
                    reported.formUnion(listed)
                    liveFindings = liveFindings + report.findings
                    for p in listed { cells[p]?.reportedBy.append(row.shortTitle) }
                    for item in report.found where cells[item.path] != nil { cells[item.path]!.severity = max(cells[item.path]!.severity ?? .nit, item.severity) }
                    row.state = .done
                    row.filesReported = report.paths.count
                    row.findings = report.findings
                    row.doing = nil
                } else if sessionsKnown {
                    if let agent { row.state = agent.ended && now - agent.lastAt > 5 ? .failed : .running }
                    else { row.state = .waiting }
                } else {
                    row.state = runningLeft > 0 ? .running : .waiting
                    if runningLeft > 0 { runningLeft -= 1 }
                }
                reviewers.append(row)
            }
        }
        for (path, cell) in cells where cell.state == .unread {
            if !cell.reportedBy.isEmpty { cells[path]!.state = .reported }
            else if !cell.readers.isEmpty { cells[path]!.state = .reading }
        }
        let allDone = !reviewers.isEmpty && reviewers.allSatisfy { $0.state == .done }
        let finalDone = names.contains("gate.json") || names.contains("comments.json")
        let gather = names.contains("brief.md") || ledger != nil
        var listed: String?
        if let ledger {
            listed = "\(ledger.count) file\(ledger.count == 1 ? "" : "s")" + (ledger.chunks > 1 ? ", \(ledger.chunks) chunks" : "")
            if !ledger.tags.isEmpty { listed! += ", risk: " + ledger.tags.prefix(3).joined(separator: ", ") }
        }
        let doneCount = reviewers.filter { $0.state == .done }.count
        let steps = ordered([
            ("reading", "Reading the PR", gather, gatherFact(folder)),
            ("listing", "Listing files", ledger != nil, listed),
            ("reviewers", "Reviewers", allDone || finalDone || (names.contains("review.md") && ledger != nil),
             reviewers.isEmpty ? nil : "\(doneCount) of \(reviewers.count) done, \(reported.count) of \(ledger?.count ?? 0) files"),
            ("final", "Final check", finalDone, finalDone ? finalFact(folder) : nil),
            ("result", "Result", false, nil),
        ])
        var progress = ReviewProgress(kind: .full, steps: steps, reviewers: reviewers, filesTotal: ledger?.count ?? 0, filesReported: reported.count,
                                      liveFindings: liveFindings, checked: names.contains("comments.json"), activity: activity)
        progress.fileMap = (ledger?.ordered ?? []).compactMap { cells[$0] }
        progress.live = live
        progress.gateWritten = names.contains("gate.json")
        return progress
    }

    private static func finalFact(_ folder: URL) -> String? {
        var parts: [String] = []
        if let cards = json(folder, "comments.json") as? [Any] { parts.append("\(cards.count) comment\(cards.count == 1 ? "" : "s")") }
        if let gate = (json(folder, "gate.json") as? [String: Any])?["gate"] as? String { parts.append(gate.replacingOccurrences(of: "_", with: " ").capitalized) }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private static func readFollowUp(_ folder: URL, _ activity: ReviewActivity?) -> ReviewProgress {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let parts = names.filter { $0.hasPrefix("followup") && $0.hasSuffix(".diff") }.count
        let input = exists(folder, "followup-input.json")
        let done = exists(folder, "followup.json")
        let steps = ordered([
            ("changes", "Reading the new commits", input || parts > 0 || done, parts > 1 ? "\(parts) parts" : nil),
            ("earlier", "Checking the earlier findings", done, nil),
            ("result", "Result", false, nil),
        ])
        return ReviewProgress(kind: .followUp, steps: steps, reviewers: [], filesTotal: 0, filesReported: 0, liveFindings: ReportedFindings(), checked: done, activity: activity)
    }

    private static func readReplies(_ folder: URL, _ activity: ReviewActivity?) -> ReviewProgress {
        let input = json(folder, "reply-input.json") as? [String: Any]
        let threads = (input?["threads"] as? [Any])?.count
        let answered = ((try? Data(contentsOf: folder.appendingPathComponent("reply-out.json")))?.isEmpty == false)
        let steps = ordered([
            ("replies", "Reading the replies", answered, threads.map { "\($0) thread\($0 == 1 ? "" : "s")" }),
            ("result", "Result", false, nil),
        ])
        return ReviewProgress(kind: .replies, steps: steps, reviewers: [], filesTotal: 0, filesReported: 0, liveFindings: ReportedFindings(), checked: false, activity: activity)
    }

    // MARK: The "now" line

    /// What the run is doing now, naming the file when a session file says which: "Reading brief.md",
    /// "Security 2: reading definitions.ts". The newer of the main session and the busiest reviewer wins.
    public var doingNow: String? {
        guard let live, live.found else { return nil }
        let busy = reviewers.filter { $0.state == .running && $0.doing != nil }.max { $0.lastAt < $1.lastAt }
        if let busy, busy.lastAt >= (live.mainLastAt ?? 0), let doing = busy.doing { return "\(busy.shortTitle): \(doing)" }
        if let doing = live.mainDoing, !live.mainEnded { return doing.prefix(1).uppercased() + doing.dropFirst() }
        return nil
    }

    /// "Reading a file · 4m 12s"; the step's own words when the hook has said nothing yet.
    public func nowLine(elapsed: Double?) -> String {
        var what: String
        if let doing = doingNow { what = doing }
        else if let tool = activity?.tool { what = ReviewActivity.words(tool) }
        else if let step = current { what = step.title }
        else { what = "Working" }
        if let running = activity?.agentsRunning, running > 0, current?.id == "reviewers" { what += " · \(running) reviewer\(running == 1 ? "" : "s") at work" }
        if let elapsed { what += " · " + ReviewProgress.clock(elapsed) }
        return what
    }

    /// Tool calls per five seconds over the last five minutes, across the main session and every reviewer; nil without session files.
    public func heartbeat(now: Double) -> ReviewHeartbeat? {
        guard let live, live.found else { return nil }
        return ReviewHeartbeat.make(steps: live.stepTimes, now: now)
    }

    /// "No activity for 2m" or "Finished, closing"; nil while work is moving or when no source says either way.
    public func notice(now: Double, since: Double?) -> ReviewNotice? {
        let sources = live?.found == true || activity != nil
        let last = [live?.lastStepAt, activity.map(\.updatedAt).flatMap { $0 > 0 ? $0 : nil }].compactMap { $0 }.max()
        let closing = gateWritten && live?.mainEnded == true
        if !sources && !closing { return nil }
        return ReviewNotice.decide(now: now, lastStep: last, since: since, gateWritten: gateWritten, mainEnded: live?.mainEnded == true)
    }

    public static func clock(_ seconds: Double) -> String {
        let s = Int(max(0, seconds))
        return s < 60 ? "\(s)s" : s < 3600 ? "\(s / 60)m \(s % 60)s" : "\(s / 3600)h \(s % 3600 / 60)m"
    }
}
