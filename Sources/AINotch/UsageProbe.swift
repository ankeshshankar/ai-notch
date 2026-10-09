import Foundation
import NotchCore

/// Claude Code's plan limits, asked of Claude Code itself: a short-lived `claude` in SDK mode,
/// one `get_usage` request (what the editor extension's usage panel sends), then it quits. No
/// prompt, no model call, no MCP servers, no session. Used when the status line, which only the
/// terminal runs, has said nothing lately. Not a documented interface: it may stop working, and
/// then the meters only update from the terminal.
enum UsageProbe {
    private static let candidates = [".local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]

    static var executable: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return candidates.map { $0.hasPrefix("/") ? $0 : "\(home)/\($0)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Calls back on a background queue: the limits, or nil within ~20 seconds.
    static func fetch(_ done: @escaping @Sendable (ToolLimits?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            done(run())
        }
    }

    private static func run() -> ToolLimits? {
        guard let path = executable else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--output-format", "stream-json", "--verbose", "--input-format", "stream-json", "--strict-mcp-config"]
        process.currentDirectoryURL = NotchPaths.sessions.deletingLastPathComponent()
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
        }
        let requests = [
            #"{"type":"control_request","request_id":"notch-init","request":{"subtype":"initialize"}}"#,
            #"{"type":"control_request","request_id":"notch-usage","request":{"subtype":"get_usage"}}"#,
        ]
        for line in requests { input.fileHandleForWriting.write(Data((line + "\n").utf8)) }

        // Read lines until the answer, for at most 20 seconds.
        let deadline = Date().addingTimeInterval(20)
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: watchdog)
        defer { watchdog.cancel() }
        var buffer = Data()
        let handle = output.fileHandleForReading
        while Date() < deadline {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer = Data(buffer[buffer.index(after: newline)...])
                guard line.range(of: Data("notch-usage".utf8)) != nil,
                      let message = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                      let response = (message["response"] as? [String: Any]),
                      response["request_id"] as? String == "notch-usage" else { continue }
                return parse(response["response"] as? [String: Any] ?? [:])
            }
        }
        return nil
    }

    /// `{subscription_type, rate_limits: {five_hour: {utilization, resets_at}, seven_day: …}}`.
    static func parse(_ usage: [String: Any]) -> ToolLimits? {
        guard let rates = usage["rate_limits"] as? [String: Any] else { return nil }
        func window(_ key: String, minutes: Int) -> LimitWindow? {
            guard let entry = rates[key] as? [String: Any], let used = LimitsFile.number(entry["utilization"]) else { return nil }
            return LimitWindow(usedPercent: used, resetsAt: (entry["resets_at"] as? String).flatMap(time(of:)), minutes: minutes)
        }
        let five = window("five_hour", minutes: 300), week = window("seven_day", minutes: 10080)
        guard five != nil || week != nil else { return nil }
        return ToolLimits(fiveHour: five, weekly: week, plan: usage["subscription_type"] as? String,
                          at: Date().timeIntervalSince1970, source: "usage")
    }

    /// "2026-10-09T08:20:00.003518+00:00": the fraction dropped, which the formatter can't take at six digits.
    static func time(of text: String) -> Double? {
        let plain = text.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return ISO8601DateFormatter().date(from: plain)?.timeIntervalSince1970
    }
}
