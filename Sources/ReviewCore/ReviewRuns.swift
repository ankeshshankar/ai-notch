import Foundation

// Runs are kept, cards follow the checked report. A review folder holds the latest run at its top level and each
// run (of the same head) in `runs/<n>/`; the cards are rebuilt from a new run's `comments.json` without losing what
// the reviewer did; a card whose finding the final check did not keep is marked "not checked". No AppKit, no network.

public enum ReviewRuns {
    /// What a run leaves in the folder: the contract's files and the headless run's output.
    public static let resultFiles = ["out.json", "report.md", "review.md", "comments.json", "gate.json", "drops.json", "ledger.json",
                                     "others.json", "followup.json", "followup-input.json", "followup.diff"]

    public static func runsURL(_ folder: URL) -> URL { folder.appendingPathComponent("runs", isDirectory: true) }

    /// The numbers of the saved runs, ascending.
    public static func numbers(_ folder: URL) -> [Int] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: runsURL(folder).path)) ?? []
        return names.compactMap(Int.init).sorted()
    }

    public static func hasResults(_ folder: URL) -> Bool {
        resultFiles.contains { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
    }

    /// Copies the folder's result files into `runs/<n>/` (n: the next number). Nil when there is nothing to keep.
    @discardableResult
    public static func snapshot(_ folder: URL) -> Int? {
        let fm = FileManager.default
        let present = resultFiles.filter { fm.fileExists(atPath: folder.appendingPathComponent($0).path) }
        guard !present.isEmpty else { return nil }
        let number = (numbers(folder).last ?? 0) + 1
        let target = runsURL(folder).appendingPathComponent(String(number), isDirectory: true)
        do { try fm.createDirectory(at: target, withIntermediateDirectories: true) } catch { return nil }
        for name in present { try? fm.copyItem(at: folder.appendingPathComponent(name), to: target.appendingPathComponent(name)) }
        return number
    }

    /// Whether the top level still equals the newest saved run (same `out.json`), so it is not saved twice.
    static func isSaved(_ folder: URL) -> Bool {
        guard let last = numbers(folder).last else { return false }
        let top = folder.appendingPathComponent("out.json"), kept = runsURL(folder).appendingPathComponent(String(last)).appendingPathComponent("out.json")
        guard let a = try? Data(contentsOf: top), let b = try? Data(contentsOf: kept) else { return false }
        return a == b
    }

    /// Before a new run in a folder that already holds one: the earlier result is saved (if it was not) and the top
    /// level is cleared, so a file of the old run is never read as the new run's. `chat.json`, `replies.json` stay.
    public static func begin(_ folder: URL) {
        guard hasResults(folder) else { return }
        if !isSaved(folder) { snapshot(folder) }
        for name in resultFiles { try? FileManager.default.removeItem(at: folder.appendingPathComponent(name)) }
    }

    /// After a run finished: it is kept as the next `runs/<n>/` (the top level already holds it).
    @discardableResult
    public static func finish(_ folder: URL) -> Int? { snapshot(folder) }
}

/// "Not checked": a card names a finding (`F3`) that the checked report has no line for.
public enum CardCheck {
    /// The finding ids (`F1`, `F12`) written in `review.md`.
    public static func findingIDs(in report: String) -> Set<String> {
        var found = Set<String>()
        guard let regex = try? NSRegularExpression(pattern: #"\bF\d{1,3}\b"#) else { return found }
        let range = NSRange(report.startIndex..., in: report)
        for match in regex.matches(in: report, range: range) {
            if let r = Range(match.range, in: report) { found.insert(String(report[r])) }
        }
        return found
    }

    /// Marks the cards whose finding is missing from the report (switched off); a card with no finding id (an older
    /// review) or no report to check against is left as it is.
    public static func mark(_ cards: [SuggestedComment], report: String?) -> [SuggestedComment] {
        guard let report, !report.isEmpty else { return cards }
        let ids = findingIDs(in: report)
        return cards.map { card in
            var card = card
            if let finding = card.finding, !ids.contains(finding) {
                card.unchecked = true
                card.include = false
            } else { card.unchecked = nil }
            return card
        }
    }
}

public enum CardRebuild {
    /// The new run's cards, each keeping what the reviewer did to its match among the old cards (finding id first,
    /// then path and line). Posted cards stay as posted; a posted or hand-edited or chat-made card that the new run
    /// no longer has is kept at the end with a badge, so what is on Bitbucket never disappears from the window.
    public static func merge(old: [SuggestedComment], new: [SuggestedComment]) -> [SuggestedComment] {
        var remaining = old
        var result: [SuggestedComment] = []
        let hadCards = !old.isEmpty
        for fresh in new {
            var index = fresh.finding.flatMap { f in remaining.firstIndex { $0.finding == f } }
            if index == nil, let path = fresh.path, let line = fresh.line {
                index = remaining.firstIndex { $0.path == path && $0.line == line }
            }
            guard let i = index else {
                var card = fresh
                if hadCards { card.badge = "new" }
                result.append(card)
                continue
            }
            let prior = remaining.remove(at: i)
            var card = fresh
            card.id = prior.id
            if prior.isPosted {
                // What went to Bitbucket stays exactly as sent.
                var kept = prior
                kept.finding = fresh.finding ?? prior.finding
                kept.unchecked = fresh.unchecked
                result.append(kept)
                continue
            }
            if prior.bodyEdited == true { card.body = prior.body; card.bodyEdited = true; card.suggestion = prior.suggestion }
            if prior.includeTouched == true { card.include = prior.include; card.includeTouched = true }
            if card.unchecked == true { card.include = false }
            card.asSuggestion = prior.asSuggestion
            card.addTask = prior.addTask
            card.status = prior.status
            card.statusReason = prior.statusReason
            card.done = prior.done
            result.append(card)
        }
        // Ids stay unique.
        var seen = Set(result.map(\.id))
        for var card in remaining where card.isPosted || card.bodyEdited == true || card.id.hasPrefix("n-") {
            if !seen.insert(card.id).inserted { card.id += "-old" }
            card.badge = card.isPosted ? "not in latest run" : "kept"
            result.append(card)
        }
        return result
    }
}
