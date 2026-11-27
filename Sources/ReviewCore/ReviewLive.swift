import Foundation

// Live work of a running review, read from the run's own session files: the main session's transcript and, in the
// `subagents` folder beside it, one file per reviewer. Only what a tool call is (its name, the file it opens, the
// time) is read; no message text, no tool result and no prompt is kept, logged or shown. Each file is read from the
// byte where the last read stopped, so a poll costs what was appended, never the whole file. A line still being
// written is held back until its end arrives. Anything unreadable leaves the view as the folder alone shows it.
// No AppKit, no network.

/// A file read from where the last read ended; whole lines only.
public struct JSONLTail: Sendable, Equatable {
    public private(set) var offset: UInt64 = 0
    private var carry = Data()

    public init() {}

    /// The complete lines appended since the last call. A last line without its newline waits for the next call.
    public mutating func readNew(_ url: URL, maxBytes: Int = 16 << 20) -> [Data] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return [] }
        if size < offset { offset = 0; carry = Data() }
        guard size > offset, (try? handle.seek(toOffset: offset)) != nil,
              let chunk = try? handle.read(upToCount: maxBytes), !chunk.isEmpty else { return [] }
        offset += UInt64(chunk.count)
        carry.append(chunk)
        var lines: [Data] = []
        var start = carry.startIndex
        while let newline = carry[start...].firstIndex(of: 0x0A) {
            if newline > start { lines.append(Data(carry[start..<newline])) }
            start = carry.index(after: newline)
        }
        carry = Data(carry[start...])
        return lines
    }
}

/// A reviewer's report file name: `lens-<area>-<chunk>.md` for the first pass, `…<chunk>b.md`, `…c.md` for later passes.
public struct LensReportName: Sendable, Equatable, Hashable {
    public var area: String
    public var chunk: Int
    /// 1 for the first pass, 2 for `b`, 3 for `c`.
    public var pass: Int

    public var file: String { "lens-\(area)-\(chunk)\(pass > 1 ? String(UnicodeScalar(UInt8(96 + pass))) : "").md" }

    public init(area: String, chunk: Int, pass: Int = 1) { self.area = area; self.chunk = chunk; self.pass = pass }

    public static func parse(_ name: String) -> LensReportName? {
        guard name.hasPrefix("lens-"), name.hasSuffix(".md") else { return nil }
        let body = String(name.dropFirst(5).dropLast(3))
        guard let dash = body.lastIndex(of: "-") else { return nil }
        let area = String(body[..<dash]), tail = String(body[body.index(after: dash)...])
        guard !area.isEmpty else { return nil }
        let digits = tail.prefix { $0.isNumber }
        guard let chunk = Int(digits), !digits.isEmpty else { return nil }
        let rest = tail.dropFirst(digits.count)
        if rest.isEmpty { return LensReportName(area: area, chunk: chunk) }
        guard rest.count == 1, let letter = rest.unicodeScalars.first?.value, (98...122).contains(letter) else { return nil }
        return LensReportName(area: area, chunk: chunk, pass: Int(letter) - 96)
    }

    /// The reviewer a subagent file belongs to: the `REPORT: <folder>/lens-<area>-<k>.md` line of the prompt it was
    /// given, read from the file's first line. Only the file name is kept; nil for the final check and anything else.
    public static func fromPrompt(_ line: Data) -> LensReportName? {
        guard let text = String(data: line.prefix(1 << 18), encoding: .utf8) else { return nil }
        var search = text.startIndex..<text.endIndex
        while let hit = text.range(of: "REPORT: ", range: search) {
            let rest = text[hit.upperBound...]
            if let end = rest.range(of: ".md") {
                let path = String(rest[..<end.upperBound])
                if let name = parse(path.components(separatedBy: "/").last ?? path) { return name }
            }
            search = hit.upperBound..<text.endIndex
        }
        return nil
    }
}

/// One reviewer pass as the session file shows it.
public struct LiveAgent: Sendable, Equatable {
    /// Full paths this pass has opened (a Read, or a search aimed at one file).
    public var reads: Set<String> = []
    public var steps = 0
    public var lastAt: Double = 0
    /// "reading cron.service.ts", "searching", "running git": the newest step in plain words.
    public var doing: String?
    /// The pass's last message ended its turn.
    public var ended = false
}

public struct LivePassKey: Sendable, Hashable {
    public var area: String
    public var chunk: Int
    public var pass: Int
    public init(area: String, chunk: Int, pass: Int) { self.area = area; self.chunk = chunk; self.pass = pass }
}

/// The run's session files folded together, at one read.
public struct ReviewLive: Sendable, Equatable {
    public var agents: [LivePassKey: LiveAgent] = [:]
    /// Times of the tool calls of the main session and every reviewer, newest last, kept for the last quarter hour.
    public var stepTimes: [Double] = []
    /// The main session's last message ended its turn.
    public var mainEnded = false
    public var mainLastAt: Double?
    public var mainSteps = 0
    /// The main session's newest step in plain words.
    public var mainDoing: String?
    /// A main session file was read.
    public var found = false

    public init() {}

    public var lastStepAt: Double? { stepTimes.last }
}

/// What a tool call is called in the view: "reading cron.service.ts", "searching", "running git".
public enum LiveWords {
    public static func doing(tool: String, file: String?, command: String?) -> String {
        let name = tool.hasPrefix("mcp__") ? (tool.components(separatedBy: "__").last ?? tool) : tool
        switch name {
        case "Read": return file.map { "reading " + ($0.components(separatedBy: "/").last ?? $0) } ?? "reading a file"
        case "Grep", "Glob": return "searching"
        case "Bash":
            let first = (command ?? "").split(separator: " ").first.map { String($0).components(separatedBy: "/").last ?? "" } ?? ""
            return first == "git" ? "running git" : "running a command"
        case "Write", "Edit": return "writing the report"
        case "Agent", "Task": return "starting a reviewer"
        default: return name.lowercased()
        }
    }
}

/// Keeps the byte offsets and what was seen so far for one review. Call `update` from one queue at a time.
public final class ReviewLiveTracker: @unchecked Sendable {
    private struct FileState {
        var tail = JSONLTail()
        /// Nil until the first line is read; `.some(nil)` for a file that is no lens reviewer (the final check).
        var key: LensReportName??
        var agent = LiveAgent()
    }

    private var main = FileState()
    private var mainTranscript: URL?
    private var files: [String: FileState] = [:]
    private var times: [String: [Double]] = [:]
    private let lock = NSLock()
    /// How long a step time is kept.
    static let keep: Double = 900

    public init() {}

    /// Reads what was appended to the main transcript and the reviewers' files; the state as it stands after.
    public func update(transcript: URL?, now: Double) -> ReviewLive {
        lock.lock(); defer { lock.unlock() }
        var live = ReviewLive()
        guard let transcript else { return live }
        if mainTranscript != transcript { main = FileState(); mainTranscript = transcript; files = [:]; times = [:] }
        guard FileManager.default.fileExists(atPath: transcript.path) else { return live }
        live.found = true
        fold(lines: main.tail.readNew(transcript), into: &main, timesKey: "main")
        let dir = transcript.deletingPathExtension().appendingPathComponent("subagents", isDirectory: true)
        for url in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where url.pathExtension == "jsonl" {
            var state = files[url.lastPathComponent] ?? FileState()
            let lines = state.tail.readNew(url)
            if state.key == nil, let first = lines.first { state.key = .some(LensReportName.fromPrompt(first)) }
            fold(lines: lines, into: &state, timesKey: url.lastPathComponent)
            files[url.lastPathComponent] = state
        }
        var all: [Double] = []
        for (name, var stamps) in times {
            stamps.removeAll { $0 < now - Self.keep }
            times[name] = stamps
            all += stamps
        }
        live.stepTimes = all.sorted()
        live.mainEnded = main.agent.ended
        live.mainLastAt = main.agent.lastAt > 0 ? main.agent.lastAt : nil
        live.mainSteps = main.agent.steps
        live.mainDoing = main.agent.doing
        for state in files.values {
            guard let outer = state.key, let key = outer else { continue }
            live.agents[LivePassKey(area: key.area, chunk: key.chunk, pass: key.pass)] = state.agent
        }
        return live
    }

    private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plainStamp = ISO8601DateFormatter()

    static func time(_ text: String) -> Double? {
        (stamp.date(from: text) ?? plainStamp.date(from: text))?.timeIntervalSince1970
    }

    private func fold(lines: [Data], into state: inout FileState, timesKey: String) {
        let assistant = Data(#""type":"assistant""#.utf8), user = Data(#""type":"user""#.utf8)
        for line in lines {
            if line.range(of: assistant) != nil {
                guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                      let message = object["message"] as? [String: Any] else { continue }
                let at = (object["timestamp"] as? String).flatMap(Self.time) ?? 0
                if at > 0 { state.agent.lastAt = max(state.agent.lastAt, at) }
                var usedTool = false
                for block in message["content"] as? [[String: Any]] ?? [] where block["type"] as? String == "tool_use" {
                    usedTool = true
                    let tool = block["name"] as? String ?? ""
                    let input = block["input"] as? [String: Any] ?? [:]
                    let file = (input["file_path"] as? String) ?? (tool == "Read" ? nil : input["path"] as? String)
                    state.agent.steps += 1
                    if at > 0 { times[timesKey, default: []].append(at) }
                    if let file, tool == "Read" || tool == "Grep" || tool == "Glob" { state.agent.reads.insert(file) }
                    state.agent.doing = LiveWords.doing(tool: tool, file: file, command: input["command"] as? String)
                }
                if usedTool { state.agent.ended = false }
                else if message["stop_reason"] as? String == "end_turn" { state.agent.ended = true }
            } else if line.range(of: user) != nil {
                state.agent.ended = false
            }
        }
    }
}
