import Foundation

// The review window's sidebar without the UI: which state group a pull request is in, the search
// matcher, what is pinned and recent (and what is remembered across launches), and the sections
// the list shows. No AppKit, no network, no process.

// MARK: Groups

/// The state groups inside "To review". Derived from `PRStage` (already tracked) and the unread replies.
public enum SidebarGroup: String, CaseIterable, Codable, Sendable {
    case needsYou, reviewingNow, waitingOnAuthor, approvedByYou

    public var title: String {
        switch self {
        case .needsYou: return "Needs you"
        case .reviewingNow: return "Reviewing now"
        case .waitingOnAuthor: return "Waiting on author"
        case .approvedByYou: return "Approved by you"
        }
    }

    /// The finished groups start folded.
    public var startsCollapsed: Bool { self == .waitingOnAuthor || self == .approvedByYou }

    public var info: String {
        switch self {
        case .needsYou: return "Not reviewed yet, new commits since your review, or a reply waiting on your comment."
        case .reviewingNow: return "A review or follow-up is queued or running."
        case .waitingOnAuthor: return "You asked for changes or posted comments, or it is a draft, and nothing new has arrived since."
        case .approvedByYou: return "You approved it and nothing new has arrived since."
        }
    }

    /// A reply waiting on my comment needs me, unless a run is already under way. A pull request with no stage fits no
    /// group and goes to Needs you.
    public static func of(stage: PRStage?, unseenReplies: Int) -> SidebarGroup {
        guard let stage else { return .needsYou }
        switch stage {
        case .reviewing: return .reviewingNow
        case .ready, .newCommits, .asked: return .needsYou
        case .draft, .posted, .waitingAuthor, .approvedByMe: return unseenReplies > 0 ? .needsYou : stage.isApproved ? .approvedByYou : .waitingOnAuthor
        }
    }
}

extension PRStage {
    fileprivate var isApproved: Bool { if case .approvedByMe = self { return true } else { return false } }
}

// MARK: Search

/// What the search looks at on one pull request.
public struct SidebarFields: Equatable, Sendable {
    public var number: Int?
    public var title: String
    public var author: String
    public var source: String
    public var repo: String

    public init(number: Int?, title: String, author: String, source: String, repo: String) {
        self.number = number
        self.title = title
        self.author = author
        self.source = source
        self.repo = repo
    }
}

public enum SidebarSearch {
    /// Ticket ids in a text ("WEB-123"), as written.
    public static func ticketIDs(in text: String) -> [String] {
        var out: [String] = []
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            // A letter run (2 to 10 letters or digits starting with a letter), a dash, then digits.
            if chars[i].isLetter, i == 0 || !(chars[i - 1].isLetter || chars[i - 1].isNumber) {
                var j = i
                while j < chars.count, chars[j].isLetter || chars[j].isNumber { j += 1 }
                let word = j - i
                if word >= 2, word <= 10, j < chars.count, chars[j] == "-" {
                    var k = j + 1
                    while k < chars.count, chars[k].isNumber { k += 1 }
                    if k > j + 1 { out.append(String(chars[i..<k])); i = k; continue }
                }
                i = max(j, i + 1)
            } else { i += 1 }
        }
        return out
    }

    /// Every word typed must match something: the number (with or without `#`), a word of the title, the author,
    /// the source branch, the repository or a ticket id in the title or branch. Case and accents do not matter.
    public static func matches(_ query: String, _ f: SidebarFields) -> Bool {
        let tokens = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if tokens.isEmpty { return true }
        let texts = [f.title, f.author, f.source, f.repo].map(fold)
        let tickets = (ticketIDs(in: f.title) + ticketIDs(in: f.source)).map { fold($0).replacingOccurrences(of: "-", with: "") }
        let number = f.number.flatMap { $0 > 0 ? String($0) : nil }
        return tokens.allSatisfy { token in
            if let hash = token.firstIndex(of: "#") {
                // "web-app#214" or "#214": the part before must match, the digits are the number.
                let before = fold(String(token[..<hash])), digits = String(token[token.index(after: hash)...])
                if !before.isEmpty, !texts.contains(where: { $0.contains(before) }) { return false }
                if digits.isEmpty { return true }
                return digits.allSatisfy(\.isNumber) && (number?.hasPrefix(digits) ?? false)
            }
            let t = fold(token)
            if t.allSatisfy(\.isNumber), let number, number.hasPrefix(t) { return true }
            if texts.contains(where: { $0.contains(t) }) { return true }
            let compact = t.replacingOccurrences(of: "-", with: "")
            return !compact.isEmpty && tickets.contains { $0.contains(compact) }
        }
    }

    private static func fold(_ text: String) -> String { text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
}

// MARK: What is remembered

/// Pins (in the order pinned), the last pull requests opened and which sections the user folded or opened.
/// Saved as one JSON value in the app's settings.
public struct SidebarMemory: Codable, Equatable, Sendable {
    public static let recentLimit = 5
    public static let defaultsKey = "reviewWindow.sidebar"

    public var pins: [String] = []
    /// Most recent first.
    public var recent: [String] = []
    /// A section the user folded (true) or opened (false); a section never touched follows its default.
    public var collapsed: [String: Bool] = [:]

    public init() {}

    public func isPinned(_ key: String) -> Bool { pins.contains(key) }

    public mutating func pin(_ key: String) { if !pins.contains(key) { pins.append(key) } }
    public mutating func unpin(_ key: String) { pins.removeAll { $0 == key } }
    public mutating func togglePin(_ key: String) { if isPinned(key) { unpin(key) } else { pin(key) } }

    /// Opened in the window: first in Recent, once, at most five.
    public mutating func noteOpened(_ key: String) {
        recent.removeAll { $0 == key }
        recent.insert(key, at: 0)
        if recent.count > Self.recentLimit { recent.removeLast(recent.count - Self.recentLimit) }
    }

    /// Drops pins and recents that left the lists (merged, declined, no longer asked). Returns whether anything went.
    @discardableResult
    public mutating func prune(keeping live: Set<String>) -> Bool {
        let before = (pins, recent)
        pins.removeAll { !live.contains($0) }
        recent.removeAll { !live.contains($0) }
        return before.0 != pins || before.1 != recent
    }

    public func isCollapsed(_ id: String, default fallback: Bool) -> Bool { collapsed[id] ?? fallback }
    public mutating func setCollapsed(_ id: String, _ value: Bool) { collapsed[id] = value }

    public static func load(from defaults: UserDefaults) -> SidebarMemory {
        guard let data = defaults.data(forKey: defaultsKey), let memory = try? JSONDecoder().decode(SidebarMemory.self, from: data) else { return SidebarMemory() }
        return memory
    }

    public func save(to defaults: UserDefaults) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}

// MARK: The sections

public struct SidebarItem: Equatable, Sendable {
    public var key: String
    public var group: SidebarGroup
    public var fields: SidebarFields

    public init(key: String, group: SidebarGroup, fields: SidebarFields) {
        self.key = key
        self.group = group
        self.fields = fields
    }
}

public struct SidebarSection: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable { case pinned, recent, group(SidebarGroup), mine, results }

    public var id: String
    public var kind: Kind
    public var title: String
    /// The rows to draw (none while folded).
    public var keys: [String]
    /// Everything in the section, pinned ones included, for the number in the header.
    public var total: Int
    /// How many of them show under Pinned instead.
    public var pinnedAbove: Int
    public var collapsed: Bool
    public var collapsible: Bool
    /// While folded: every pull request in it, so a selection can open it.
    public var hidden: [String]

    public init(id: String, kind: Kind, title: String, keys: [String], total: Int, pinnedAbove: Int, collapsed: Bool, collapsible: Bool, hidden: [String]) {
        self.id = id
        self.kind = kind
        self.title = title
        self.keys = keys
        self.total = total
        self.pinnedAbove = pinnedAbove
        self.collapsed = collapsed
        self.collapsible = collapsible
        self.hidden = hidden
    }
}

public struct SidebarLayout: Equatable, Sendable {
    public var sections: [SidebarSection]
    public var searching: Bool
    /// Search: matches out of everything searched.
    public var matches: Int
    public var searched: Int
    /// Rows the arrow keys walk, each pull request once, in the order drawn.
    public var navigable: [String]

    /// The folded section a pull request is in, for opening it when the pull request is selected.
    public func foldedSection(containing key: String) -> String? {
        sections.first { $0.collapsed && $0.hidden.contains(key) }?.id
    }

    public init(sections: [SidebarSection], searching: Bool, matches: Int, searched: Int, navigable: [String]) {
        self.sections = sections
        self.searching = searching
        self.matches = matches
        self.searched = searched
        self.navigable = navigable
    }
}

public enum SidebarBuilder {
    /// `toReview` and `mine` come in the order the list already has. Pinned ones show once under Pinned, not again in their
    /// group, which still counts them ("1 pinned above"). Recent is a short list of shortcuts, so a pull request there stays in its group.
    public static func build(toReview: [SidebarItem], mine: [SidebarItem], memory: SidebarMemory, query: String) -> SidebarLayout {
        let all = toReview + mine
        let byKey = Dictionary(all.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty

        if searching {
            let hits = all.filter { SidebarSearch.matches(query, $0.fields) }.map(\.key)
            let section = SidebarSection(id: "results", kind: .results, title: "Results", keys: hits, total: hits.count, pinnedAbove: 0, collapsed: false, collapsible: false, hidden: [])
            return SidebarLayout(sections: hits.isEmpty ? [] : [section], searching: true, matches: hits.count, searched: all.count, navigable: hits)
        }

        var sections: [SidebarSection] = []
        let pinned = memory.pins.filter { byKey[$0] != nil }
        if !pinned.isEmpty {
            sections.append(SidebarSection(id: "pinned", kind: .pinned, title: "Pinned", keys: pinned, total: pinned.count, pinnedAbove: 0, collapsed: false, collapsible: false, hidden: []))
        }
        let recent = memory.recent.filter { byKey[$0] != nil && !memory.isPinned($0) }
        if !recent.isEmpty {
            sections.append(SidebarSection(id: "recent", kind: .recent, title: "Recent", keys: recent, total: recent.count, pinnedAbove: 0, collapsed: false, collapsible: false, hidden: []))
        }
        func make(id: String, kind: SidebarSection.Kind, title: String, items: [SidebarItem], fallback: Bool) -> SidebarSection? {
            guard !items.isEmpty else { return nil }
            let shown = items.map(\.key).filter { !memory.isPinned($0) }
            let folded = memory.isCollapsed(id, default: fallback)
            return SidebarSection(id: id, kind: kind, title: title, keys: folded ? [] : shown, total: items.count, pinnedAbove: items.count - shown.count,
                                  collapsed: folded, collapsible: true, hidden: folded ? items.map(\.key) : [])
        }
        for group in SidebarGroup.allCases {
            if let section = make(id: group.rawValue, kind: .group(group), title: group.title, items: toReview.filter { $0.group == group }, fallback: group.startsCollapsed) {
                sections.append(section)
            }
        }
        if let section = make(id: "mine", kind: .mine, title: "Mine", items: mine, fallback: false) { sections.append(section) }

        var seen = Set<String>()
        let navigable = sections.filter { $0.kind != .recent }.flatMap(\.keys).filter { seen.insert($0).inserted }
        return SidebarLayout(sections: sections, searching: false, matches: all.count, searched: all.count, navigable: navigable)
    }

    /// The pull request after moving by `delta` in the rows the arrow keys walk: the first one when none is selected, stopping at either end.
    public static func move(from current: String?, in keys: [String], by delta: Int) -> String? {
        guard !keys.isEmpty else { return nil }
        guard let current, let index = keys.firstIndex(of: current) else { return delta >= 0 ? keys.first : keys.last }
        return keys[min(max(index + delta, 0), keys.count - 1)]
    }
}
