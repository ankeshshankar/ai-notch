import Foundation

/// Pure text logic for live dictation: joining phrases typed one by one, the rule clean-up of a
/// single phrase, splitting text into small keyboard chunks, and cutting the pill's caption.
public enum LiveText {
    /// The separator to put between what is already typed and `next`: a space, except at the start,
    /// after a line break, before a line break, or before a closing mark.
    public static func separator(after typed: String, before next: String) -> String {
        guard let last = typed.last, let first = next.first else { return "" }
        if last.isNewline || last == " " || first.isNewline || first == " " { return "" }
        if ",.?!:;".contains(first) { return "" }
        return " "
    }

    /// Whether the next word starts a sentence: nothing typed yet, a line break, or a sentence mark.
    public static func startsSentence(after typed: String) -> Bool {
        var t = Substring(typed)
        while let l = t.last, l == " " || l == "\t" { t = t.dropLast() }
        guard let last = t.last else { return true }
        return last.isNewline || last == "." || last == "?" || last == "!"
    }

    /// The text to type for one final phrase, separator included: rules only, and no capital
    /// letter at the start unless the text before it ended a sentence. Empty when nothing is left.
    public static func phrase(_ raw: String, typedSoFar typed: String, style: DictationStyle = .keepMyWords) -> String {
        var cleaned = RuleCleaner.clean(raw, style: style, startsSentence: startsSentence(after: typed))
        if style == .keepMyWords { cleaned = LatinScript.transliterateDevanagari(cleaned) }
        // The clean-up trims line breaks at the edges, but a phrase of just "new line" (or one that
        // ends in it) still means a break here, and a lone spoken "comma" still means a mark.
        let spoken = RuleCleaner.replaceSpokenPunctuation(raw.replacingOccurrences(of: "\r", with: "\n"))
        func breaks(_ chars: [Character]) -> String { String(chars.prefix { $0 == "\n" || $0 == " " || $0 == "\t" }.filter { $0 == "\n" }) }
        let lead = breaks(Array(spoken))
        let trail = breaks(Array(spoken.reversed()))
        if cleaned.isEmpty {
            let marks = spoken.trimmingCharacters(in: .whitespaces)
            guard !marks.isEmpty, marks.allSatisfy({ ",.?!:;\n".contains($0) }) else { return "" }
            return marks
        }
        let body = lead + cleaned + trail
        return separator(after: typed, before: body) + body
    }

    /// `text` cut into pieces of at most `size` UTF-16 units, never inside a character. A single
    /// character longer than `size` stays whole.
    public static func chunks(_ text: String, size: Int = 20) -> [String] {
        let size = max(1, size)
        var out: [String] = []
        var current = ""
        var units = 0
        for ch in text {
            let n = String(ch).utf16.count
            if units + n > size, !current.isEmpty {
                out.append(current)
                current = ""
                units = 0
            }
            current.append(ch)
            units += n
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// The caption for the pill: the newest words that fit in `limit` characters, cut from the
    /// left at a word boundary. `final` is what Apple settled, `volatile` the tail still changing.
    public struct Caption: Equatable {
        public var final: String
        public var volatile: String
        public var cut: Bool
        public var isEmpty: Bool { final.isEmpty && volatile.isEmpty }
        public static let empty = Caption(final: "", volatile: "", cut: false)
        public init(final: String, volatile: String, cut: Bool) {
            self.final = final
            self.volatile = volatile
            self.cut = cut
        }
    }

    public static func caption(final: String, volatile: String, limit: Int) -> Caption {
        let f = final.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        let v = volatile.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        let joiner = (f.isEmpty || v.isEmpty) ? "" : " "
        let total = f.count + joiner.count + v.count
        guard limit > 0, total > limit else { return Caption(final: f, volatile: v, cut: false) }
        // Drop from the left: whole words first; a word longer than the limit is cut by letters.
        var drop = total - limit
        let all = Array(f + joiner + v)
        if drop < all.count, drop > 0, all[drop - 1] != " " {
            // Move to the next word start when one exists within the kept part.
            if let space = all[drop...].firstIndex(of: " "), space + 1 < all.count { drop = space + 1 }
        }
        while drop < all.count, all[drop] == " " { drop += 1 }
        let kept = Array(all[drop...])
        let fKept = max(0, f.count - drop)
        let finalPart = String(kept.prefix(fKept)).trimmingCharacters(in: .whitespaces)
        let volatilePart = String(kept.dropFirst(fKept)).trimmingCharacters(in: .whitespaces)
        return Caption(final: finalPart, volatile: volatilePart, cut: true)
    }
}
