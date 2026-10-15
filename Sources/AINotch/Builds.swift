import CoreGraphics
import CryptoKit
import Foundation

// What the two build sources share, and nothing more: EAS builds (EASBuilds.swift) and Bitbucket
// Pipelines runs (BitbucketPipelines.swift) have their own models, configs, pollers and status,
// so a failure in one never hides or stalls the other. Both are read only: the notch never
// starts, stops or reruns anything. BuildStore.swift merges them for the panel.

/// Where a build or a run is.
enum BuildState: String, Sendable, Codable {
    case queued, running, paused, succeeded, failed, canceled

    var isActive: Bool { self == .queued || self == .running || self == .paused }
    var isFinished: Bool { !isActive }
    /// Really doing something (or about to): what the live line and the spinner count. A run
    /// paused at a manual step or held by a deployment lock is not.
    var isRunning: Bool { self == .queued || self == .running }
}

/// Why a source shows nothing new: a few words, and the explanation for its ⓘ.
struct SourceStatus: Equatable, Sendable {
    var text: String
    var help: String
    /// Not set up at all (no token, no CLI): quiet, not an error.
    var isSetup = false
}

/// When to fetch next. EAS: every 25 s while a build is new, queued or running, or while one of my
/// Bitbucket pipelines runs (it may queue one), else every 5 minutes. Bitbucket: per repository,
/// 5 minutes idle, 25 s for a repository with an active run (stretched to stay under its hourly
/// budget). After a failure that will not mend by itself (no CLI, logged out, a token without the
/// scope), every 10 minutes.
enum BuildPolling {
    static let busy: Double = 25
    static let idle: Double = 300
    static let broken: Double = 600
    /// Opening the notch refreshes a source whose data is older than this.
    static let openRefresh: Double = 60
    /// A paused or halted run whose steps have not changed for this long is left waiting: it
    /// no longer keeps the fast poll going and is re-read with the idle sweep.
    static let stalePause: Double = 7200
    /// Bitbucket: the workspace gate (one request for every repository), and the full per-repo
    /// sweep that catches what the gate cannot see (manual, scheduled and rerun pipelines do not
    /// move a repository's updated_on). Opening the notch also reads every repository not read
    /// in the last `openRefresh`.
    static let gate: Double = 120
    static let sweep: Double = Double(ProcessInfo.processInfo.environment["CLAUDE_NOTCH_BITBUCKET_SWEEP"] ?? "") ?? 300
    /// A stale waiting run that has dropped off its repository's first page is read by itself
    /// on a sweep at most this often.
    static let staleReread: Double = 900
    /// After the gate sees a push, the repository is read at the busy pace this long: the push's
    /// pipeline is created some seconds after updated_on moves.
    static let hot: Double = 180
    /// ETA history (median of recent successful runs or builds) is re-read this often.
    static let history: Double = 3600

    /// Whether the screen is locked now (the login window's own flag). Polling pauses while it is,
    /// unless something is running: its finish is what a notification is for.
    static var isScreenLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
}

/// "2026-10-13T07:07:44.170Z" or "2026-10-13T07:07:44.123456+00:00".
func buildTime(_ value: Any?) -> Double? {
    (value as? String).flatMap(UsageProbe.time(of:))
}

/// The median of some durations; nil for none.
func median(_ values: [Double]) -> Double? {
    let sorted = values.filter { $0 > 0 }.sorted()
    guard !sorted.isEmpty else { return nil }
    let mid = sorted.count / 2
    return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
}

/// "~4m left" while under the usual time, "usually 18m" once past it.
func etaText(median: Double?, elapsed: Double) -> String? {
    guard let median else { return nil }
    let left = median - elapsed
    if left > 30 { return "~\(shortDuration(left)) left" }
    return "usually \(shortDuration(median))"
}

/// "45s", "4m", "1h 5m".
func shortDuration(_ seconds: Double) -> String {
    let s = max(0, Int(seconds.rounded()))
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(Int((Double(s) / 60).rounded()))m" }
    return "\(s / 3600)h \((s % 3600) / 60)m"
}

/// "just now", "5m ago", "3h ago", "2d ago".
func ago(_ seconds: Double) -> String {
    if seconds < 60 { return "just now" }
    if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
    if seconds < 86_400 { return "\(Int(seconds / 3600))h ago" }
    return "\(Int(seconds / 86_400))d ago"
}

/// One child process with a deadline: its exit status, its output, and the end of its errors.
/// Its errors go to a file, so a chatty child never blocks on a full pipe.
struct ProcessResult: Sendable {
    var status: Int32
    var output: Data
    var errors: String
    var timedOut: Bool
}

/// Set once by the watchdog, read after the child exits.
private final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// Runs a child and waits for it: call it only off the main thread.
func runProcess(_ path: String, _ arguments: [String], environment: [String: String]? = nil,
                directory: URL? = nil, timeout: Double = 20) -> ProcessResult? {
    assert(!Thread.isMainThread, "runProcess blocks: never on the main thread")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    if let environment { process.environment = environment }
    if let directory { process.currentDirectoryURL = directory }
    let output = Pipe()
    let errorFile = FileManager.default.temporaryDirectory.appendingPathComponent("ai-notch-\(UUID().uuidString).err")
    FileManager.default.createFile(atPath: errorFile.path, contents: nil)
    defer { try? FileManager.default.removeItem(at: errorFile) }
    guard let errors = try? FileHandle(forWritingTo: errorFile) else { return nil }
    defer { try? errors.close() }
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = errors
    guard (try? process.run()) != nil else { return nil }
    let timedOut = TimeoutFlag()
    let watchdog = DispatchWorkItem {
        if process.isRunning {
            timedOut.set()
            process.terminate()
        }
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    watchdog.cancel()
    let text = String(decoding: (try? Data(contentsOf: errorFile)) ?? Data(), as: UTF8.self)
    return ProcessResult(status: process.terminationStatus, output: data, errors: String(text.suffix(2000)), timedOut: timedOut.isSet)
}

/// Reads a generic password the user stored with `security add-generic-password` (whose items
/// trust /usr/bin/security, so reading never prompts, whatever the app's signature). Off the main
/// thread only. The secret never reaches a log.
enum KeychainItem {
    struct Found: Sendable {
        var secret: String
        var account: String?
        /// The item's comment (`-j`), where the setup steps keep "expires YYYY-MM-DD".
        var comment: String?

        /// A hash of the secret, to tell a re-saved token from the one that was rejected
        /// without keeping the rejected one around.
        var fingerprint: String {
            SHA256.hash(data: Data(secret.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        }
    }

    static func read(service: String) -> Found? {
        guard let secret = runProcess("/usr/bin/security", ["find-generic-password", "-s", service, "-w"], timeout: 5),
              secret.status == 0 else { return nil }
        let value = String(decoding: secret.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        var found = Found(secret: value)
        // The attributes (no secret in them): the account and the comment.
        if let attributes = runProcess("/usr/bin/security", ["find-generic-password", "-s", service], timeout: 5), attributes.status == 0 {
            let text = String(decoding: attributes.output, as: UTF8.self)
            found.account = attribute("acct", in: text)
            found.comment = attribute("icmt", in: text)
        }
        return found
    }

    private static func attribute(_ name: String, in text: String) -> String? {
        guard let line = text.split(separator: "\n").first(where: { $0.contains("\"\(name)\"<blob>=\"") }),
              let start = line.range(of: "<blob>=\"")?.upperBound, let end = line.lastIndex(of: "\""), start < end else { return nil }
        return String(line[start..<end])
    }

    /// "expires 2027-10-15" (or any YYYY-MM-DD in the comment) → that day's end.
    static func expiry(in comment: String?) -> Double? {
        guard let comment, let range = comment.range(of: #"\d{4}-\d{2}-\d{2}"#, options: .regularExpression) else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: String(comment[range]))?.addingTimeInterval(86_399).timeIntervalSince1970
    }
}

/// Masks anything that looks like a secret before text leaves for the clipboard: bearer tokens,
/// JWTs, AWS-style keys, private keys, long hex or base64 runs, credentials in URLs, and the
/// values of `*_TOKEN=`, `*_SECRET=`, `PASSWORD=` and the like. `keep` lists values known to be
/// harmless (the commit hashes the report names), which stay as they are.
enum Redact {
    private static let rules: [(NSRegularExpression, String)] = {
        let list: [(String, String)] = [
            (#"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?(-----END [A-Z ]*PRIVATE KEY-----|$)"#, "[private key masked]"),
            (#"(?i)\b(Bearer|Basic)(\s+)[A-Za-z0-9._~+/=-]{8,}"#, "$1$2***"),
            (#"\beyJ[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{4,}"#, "***"),
            (#"\b(AKIA|ASIA|AGPA|AIDA|AROA)[A-Z0-9]{16}\b"#, "***"),
            (#"\b(ATATT|ATCTT|ATBB)[A-Za-z0-9_=+-]{10,}"#, "***"),
            (#"\b(gh[pousr]_[A-Za-z0-9]{20,}|xox[abprs]-[A-Za-z0-9-]{10,}|sk-[A-Za-z0-9_-]{20,}|glpat-[A-Za-z0-9_-]{16,})"#, "***"),
            (#"(https?://)[^/\s:@]+:[^/\s@]+@"#, "$1***@"),
            (#"(?i)([?&](?:x-goog-signature|x-goog-credential|x-amz-signature|x-amz-credential|x-amz-security-token|signature|sig|token|access_token|api_key|apikey|key)=)[^&\s"']+"#, "$1***"),
            // NAME_TOKEN=value, "apiSecret": "value", PASSWORD: value …
            (#"(?i)(\b[A-Za-z0-9_.-]*(?:token|secret|passw(?:or)?d|passwd|api[_-]?key|private[_-]?key|access[_-]?key|credentials?)[A-Za-z0-9_.-]*["']?\s*[:=]\s*)("[^"\n]*"|'[^'\n]*'|[^\s,;}]+)"#, "$1***"),
        ]
        return list.compactMap { pattern, template in (try? NSRegularExpression(pattern: pattern)).map { ($0, template) } }
    }()

    /// Long hex (32+) and long base64-ish runs (32+, mixed case with digits).
    private static let hex = try! NSRegularExpression(pattern: #"\b[0-9a-fA-F]{32,}\b"#)
    private static let base64 = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9+/_=-])[A-Za-z0-9+/_-]{32,}={0,2}(?![A-Za-z0-9+/_=-])"#)

    static func mask(_ text: String, keep: Set<String> = []) -> String {
        var out = text
        for (regex, template) in rules {
            out = regex.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: template)
        }
        out = replace(hex, in: out) { keep.contains($0) ? $0 : "***" }
        out = replace(base64, in: out) { run in
            if keep.contains(run) { return run }
            // Paths and identifiers are long too: only a run with upper, lower and digits that
            // is not a path counts as a token.
            if run.hasPrefix("/") || run.contains("//") || run.split(separator: "/").count > 2 { return run }
            let upper = run.contains { $0.isUppercase }, lower = run.contains { $0.isLowercase }
            let digits = run.filter(\.isNumber).count
            return upper && lower && digits >= 2 ? "***" : run
        }
        return out
    }

    private static func replace(_ regex: NSRegularExpression, in text: String, _ transform: (String) -> String) -> String {
        let ns = text as NSString
        var out = ""
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            out += transform(ns.substring(with: match.range))
            last = match.range.location + match.range.length
        }
        out += ns.substring(from: last)
        return out
    }
}

/// Strips terminal colour codes from a log line.
func plainLogLine(_ line: Substring) -> String {
    line.replacingOccurrences(of: #"\x1B\[[0-9;?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
        .replacingOccurrences(of: "\r", with: "")
}

/// The app's own log, without secrets: one line per event.
func noteBuildLog(_ line: String) {
    let log = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/notch/notch.log")
    let stamp = ISO8601DateFormatter().string(from: Date())
    guard let data = "\(stamp) \(Redact.mask(line))\n".data(using: .utf8) else { return }
    if let handle = try? FileHandle(forWritingTo: log) {
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    } else {
        try? data.write(to: log)
    }
}
