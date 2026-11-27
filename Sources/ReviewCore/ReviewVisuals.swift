import Foundation

// The pure parts of the live review view: how bad a finding is, the file map's cells, the activity graph and the
// two plain-word notices ("No activity for 2m", "Finished, closing"). Everything here is a function of what the
// folder and the session files said and of the clock the caller passes in, so it can be tested without a window.

public enum FindingSeverity: Int, Sendable, Comparable, CaseIterable {
    case nit = 0, preExisting, shouldFix, blocking

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    /// The word on a lens report's finding line: "[SHOULD-FIX]".
    public init?(tag: String) {
        switch tag {
        case "BLOCKING": self = .blocking
        case "SHOULD-FIX": self = .shouldFix
        case "PRE-EXISTING": self = .preExisting
        case "NIT": self = .nit
        default: return nil
        }
    }

    public var words: String {
        switch self {
        case .blocking: return "blocking"
        case .shouldFix: return "should fix"
        case .preExisting: return "was already there"
        case .nit: return "nit"
        }
    }
}

public enum FileMapState: Int, Sendable, Equatable {
    /// No reviewer has opened it yet.
    case unread
    /// A reviewer's session shows it opened; its report is not in yet.
    case reading
    /// A reviewer's report lists it.
    case reported
}

public struct ReviewFileCell: Sendable, Equatable {
    public var path: String
    public var state: FileMapState = .unread
    /// The worst finding that landed on this file, if any.
    public var severity: FindingSeverity?
    /// Reviewer names that opened it, and that listed it in their report.
    public var readers: [String] = []
    public var reportedBy: [String] = []

    /// The tooltip: the path and who has been through it.
    public var tooltip: String {
        var lines = [path]
        if let severity { lines.append("Finding: \(severity.words)") }
        if !reportedBy.isEmpty { lines.append("Checked by " + reportedBy.joined(separator: ", ")) }
        let reading = readers.filter { !reportedBy.contains($0) }
        if !reading.isEmpty { lines.append((reportedBy.isEmpty ? "Opened by " : "Also opened by ") + reading.joined(separator: ", ")) }
        if readers.isEmpty && reportedBy.isEmpty { lines.append("Not read yet") }
        return lines.joined(separator: "\n")
    }
}

/// Tool calls per bucket over the last few minutes, oldest first.
public struct ReviewHeartbeat: Sendable, Equatable {
    public static let window: Double = 300
    public static let bucket: Double = 5
    public var counts: [Int]

    public var peak: Int { counts.max() ?? 0 }
    public var total: Int { counts.reduce(0, +) }

    /// `steps` are tool-call times. A step in the bucket that ends at `now` counts there; older than `window` is left out.
    public static func make(steps: [Double], now: Double, window: Double = Self.window, bucket: Double = Self.bucket) -> ReviewHeartbeat {
        let n = max(1, Int((window / bucket).rounded()))
        var counts = [Int](repeating: 0, count: n)
        for t in steps where t <= now && t > now - window {
            let back = Int((now - t) / bucket)
            counts[max(0, n - 1 - back)] += 1
        }
        return ReviewHeartbeat(counts: counts)
    }
}

/// A plain-words line about the run that is not a step: it is quiet, or it has finished and is closing.
public enum ReviewNotice: Sendable, Equatable {
    /// Seconds with no step in any session.
    case quiet(Int)
    case closing

    public var text: String {
        switch self {
        case .closing: return "Finished, closing"
        case .quiet(let seconds): return "No activity for \(seconds >= 3600 ? "\(seconds / 3600)h \(seconds % 3600 / 60)m" : "\(max(1, seconds / 60))m")"
        }
    }

    /// Quiet from this many seconds; below it the graph alone says what is going on.
    public static let quietAfter: Double = 60

    /// `closing` wins: the gate is written and the main session's last message ended its turn, yet the run is still open.
    /// Otherwise the run is quiet once nothing has happened for a minute, counted from the newest step (or from the start).
    public static func decide(now: Double, lastStep: Double?, since: Double?, gateWritten: Bool, mainEnded: Bool) -> ReviewNotice? {
        if gateWritten && mainEnded { return .closing }
        guard let last = [lastStep, since].compactMap({ $0 }).max() else { return nil }
        let gap = now - last
        return gap >= quietAfter ? .quiet(Int(gap)) : nil
    }
}

extension ReviewProgress {
    static let areaOrder = ["correctness", "security", "data", "tests", "compat", "conventions"]

    /// The reviewers grouped by area, then by chunk, for the tiles: correctness 1…6 sit together.
    public var tiles: [ReviewerRowInfo] {
        func rank(_ area: String) -> Int { Self.areaOrder.firstIndex(of: area) ?? Self.areaOrder.count }
        return reviewers.sorted { a, b in
            if rank(a.area) != rank(b.area) { return rank(a.area) < rank(b.area) }
            if a.area != b.area { return a.area < b.area }
            return a.chunk < b.chunk
        }
    }
}

/// How the file map lays out its squares, and which square a pointer is over.
public struct ReviewFileGrid: Sendable, Equatable {
    public var cell: Double
    public var gap: Double
    public var columns: Int
    public var rows: Int

    public var height: Double { rows == 0 ? 0 : Double(rows) * (cell + gap) - gap }

    /// Biggest square (at most 18 points, at least 5) that keeps the map within `maxHeight` for `count` files in `width`.
    public static func layout(width: Double, count: Int, maxHeight: Double = 96, gap: Double = 2) -> ReviewFileGrid {
        guard count > 0, width > 0 else { return ReviewFileGrid(cell: 0, gap: gap, columns: 0, rows: 0) }
        var best = ReviewFileGrid(cell: 5, gap: gap, columns: 1, rows: count)
        for size in stride(from: 18.0, through: 5.0, by: -1) {
            let columns = max(1, Int((width + gap) / (size + gap)))
            let rows = (count + columns - 1) / columns
            best = ReviewFileGrid(cell: size, gap: gap, columns: columns, rows: rows)
            if best.height <= maxHeight { break }
        }
        return best
    }

    /// The file under a point of the map, or nil over a gap or past the last square.
    public func index(x: Double, y: Double, count: Int) -> Int? {
        guard columns > 0, x >= 0, y >= 0 else { return nil }
        let step = cell + gap
        let col = Int(x / step), row = Int(y / step)
        guard col < columns, x - Double(col) * step <= cell, y - Double(row) * step <= cell else { return nil }
        let i = row * columns + col
        return i < count ? i : nil
    }
}
