import Foundation
import NotchCore
import SQLite3

/// The name each chat goes by in its editor's chat list, read in the background.
///
/// Claude Code: the extension lists a chat by its latest `custom-title` entry (your rename), else
/// its latest `ai-title`, both lines Claude Code appends to the transcript. Each transcript is read
/// once, then only what was added since. Cursor's agent: the chat's `name` in Cursor's own state
/// database (`composerData:<id>`, read only, one keyed row), else the first `<user_query>` of its
/// agent transcript.
final class ChatTitles: @unchecked Sendable {
    struct Found: Equatable, Sendable {
        /// Your rename, from the transcript.
        var custom: String?
        /// The title Claude Code generated.
        var ai: String?
        /// Cursor's name for the chat, or its first prompt.
        var cursor: String?
    }

    private let queue = DispatchQueue(label: "ai-notch.titles", qos: .utility)
    /// Per transcript: how far it was read, and the titles found so far. Touched on `queue` only.
    private var scans: [String: Scan] = [:]
    private var cursorChecked: [String: (at: Double, updatedAt: Double, name: String?)] = [:]
    private var isBusy = false

    private struct Scan {
        var offset: UInt64 = 0
        var custom: String?
        var ai: String?
    }

    static let cursorDatabase = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb").path

    /// Reads what changed for these sessions, then hands back every session's titles on the main queue.
    /// A call while the last one still runs is skipped: the next tick asks again.
    func refresh(_ sessions: [SessionState], done: @escaping @Sendable ([String: Found]) -> Void) {
        let jobs = sessions.map { (id: $0.id, path: $0.transcriptPath, isCursor: $0.isCursorAgent, updatedAt: $0.updatedAt) }
        queue.async { [self] in
            guard !isBusy else { return }
            isBusy = true
            defer { isBusy = false }
            let now = Date().timeIntervalSince1970
            var found: [String: Found] = [:]
            for job in jobs {
                if job.isCursor {
                    var cursor = cursorName(id: String(job.id.dropFirst("cursor-".count)), updatedAt: job.updatedAt, now: now)
                    if cursor == nil, let path = job.path { cursor = Self.firstCursorQuery(path) }
                    found[job.id] = Found(cursor: cursor)
                } else if let path = job.path {
                    let scan = scanned(path)
                    found[job.id] = Found(custom: scan.custom, ai: scan.ai)
                }
            }
            let live = Set(jobs.compactMap(\.path))
            scans = scans.filter { live.contains($0.key) }
            DispatchQueue.main.async { done(found) }
        }
    }

    /// The titles in one transcript, read from where the last read stopped.
    private func scanned(_ path: String) -> Scan {
        var scan = scans[path] ?? Scan()
        let size = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.uint64Value ?? 0
        // Rewritten shorter: read it again from the start.
        if size < scan.offset { scan = Scan() }
        if size > scan.offset { Self.read(path, into: &scan) }
        scans[path] = scan
        return scan
    }

    private static let markers = [Data(#""type":"custom-title""#.utf8), Data(#""type":"ai-title""#.utf8)]

    /// Reads complete lines past `scan.offset`, 8 MB at a time, and keeps the last title of each kind.
    private static func read(_ path: String, into scan: inout Scan) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        while true {
            guard (try? handle.seek(toOffset: scan.offset)) != nil,
                  let chunk = try? handle.read(upToCount: 8 << 20), !chunk.isEmpty else { return }
            // Only whole lines: a line still being written is read next time.
            guard let lastNewline = chunk.lastIndex(of: 0x0A) else {
                // A single line longer than the chunk (a huge tool result) holds no title: skip it.
                if chunk.count == 8 << 20 { scan.offset += UInt64(chunk.count); continue }
                return
            }
            let lines = chunk[chunk.startIndex...lastNewline]
            for marker in markers {
                var from = lines.startIndex
                while let hit = lines.range(of: marker, in: from..<lines.endIndex) {
                    let start = lines[..<hit.lowerBound].lastIndex(of: 0x0A).map { $0 + 1 } ?? lines.startIndex
                    let end = lines[hit.upperBound...].firstIndex(of: 0x0A) ?? lines.endIndex
                    from = end
                    // The marker inside a message's text is escaped (\"type\"), so a hit is a title line;
                    // parsing it says so for sure. Each kind is searched in file order: its last one wins.
                    guard let entry = (try? JSONSerialization.jsonObject(with: lines[start..<end])) as? [String: Any] else { continue }
                    switch entry["type"] as? String {
                    case "custom-title":
                        let title = (entry["customTitle"] as? String).map(clean)
                        scan.custom = title?.isEmpty == false ? title : nil
                    case "ai-title":
                        if let title = (entry["aiTitle"] as? String).map(clean), !title.isEmpty { scan.ai = title }
                    default:
                        break
                    }
                }
            }
            scan.offset += UInt64(lastNewline - chunk.startIndex + 1)
        }
    }

    private static func clean(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return flat.count > 160 ? String(flat.prefix(159)) + "…" : flat
    }

    /// Cursor's name for a chat: looked up when the chat had news, at most every 5 s, and every
    /// 30 s regardless (it names a chat a moment after its first prompt).
    private func cursorName(id: String, updatedAt: Double, now: Double) -> String? {
        if let last = cursorChecked[id], now - last.at < (last.updatedAt == updatedAt ? 30 : 5) { return last.name }
        let name = Self.lookUpCursorName(id) ?? cursorChecked[id]?.name
        cursorChecked[id] = (now, updatedAt, name)
        return name
    }

    private static func lookUpCursorName(_ id: String) -> String? {
        guard !id.isEmpty, FileManager.default.fileExists(atPath: cursorDatabase) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(cursorDatabase, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { sqlite3_close(db); return nil }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 200)
        var statement: OpaquePointer?
        let sql = "SELECT json_extract(CAST(value AS TEXT), '$.name') FROM cursorDiskKV WHERE key = ?"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        let key = "composerData:\(id)"
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, key, -1, transient)
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return nil }
        let name = clean(String(cString: text))
        return name.isEmpty ? nil : name
    }

    /// The first thing you asked in a Cursor agent transcript (`<user_query>…</user_query>`).
    private static func firstCursorQuery(_ path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let head = String(decoding: (try? handle.read(upToCount: 64 * 1024)) ?? Data(), as: UTF8.self)
        for line in head.split(separator: "\n") {
            guard let entry = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  entry["role"] as? String == "user",
                  let content = (entry["message"] as? [String: Any])?["content"] as? [[String: Any]] else { continue }
            for part in content {
                guard let text = part["text"] as? String, let open = text.range(of: "<user_query>"),
                      let close = text.range(of: "</user_query>", range: open.upperBound..<text.endIndex) else { continue }
                let query = clean(String(text[open.upperBound..<close.lowerBound]))
                if !query.isEmpty { return query }
            }
        }
        return nil
    }

    /// `AINotch --chat-title <transcript>`: the titles one transcript holds, for a check.
    static func printTitles(of path: String) {
        var scan = Scan()
        read(path, into: &scan)
        print("custom-title: \(scan.custom ?? "—")\nai-title: \(scan.ai ?? "—")\nshown: \(scan.custom ?? scan.ai ?? "—")")
    }
}
