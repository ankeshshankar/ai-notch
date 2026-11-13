import Foundation

/// How the text should read: the speaker's own words, or English.
public enum DictationStyle: String, CaseIterable, Sendable {
    case keepMyWords = "keep"
    case translateToEnglish = "english"

    public var title: String {
        switch self {
        case .keepMyWords: return "Keep my words"
        case .translateToEnglish: return "Translate to English"
        }
    }
}

/// The rule-based clean-up that always runs, with no network: it trims, drops filler words,
/// turns spoken punctuation into marks, tidies spacing, capitalises sentences and, for Hinglish,
/// writes any Devanagari in Latin letters. Pure functions on text.
public enum RuleCleaner {
    /// Fillers dropped on their own, with a comma that follows them.
    static let fillers = ["um", "umm", "ummm", "uh", "uhh", "uhhh", "er", "erm", "hmm", "hmmm", "mm", "mmm"]

    /// Spoken punctuation, longest first. `always` ones are replaced anywhere; the others (words
    /// that are also ordinary words) only at the very end of the text or before a line break word.
    private static let spoken: [(words: String, mark: String, always: Bool)] = [
        ("new paragraph", "\n\n", true),
        ("new line", "\n", true),
        ("question mark", "?", true),
        ("exclamation mark", "!", true),
        ("exclamation point", "!", true),
        ("semicolon", ";", true),
        ("full stop", ".", true),
        ("comma", ",", true),
        ("colon", ":", true),
        ("period", ".", false),
    ]

    public static func clean(_ text: String, style: DictationStyle = .keepMyWords) -> String {
        var s = text.replacingOccurrences(of: "\r", with: "\n")
        s = LatinScript.transliterateDevanagari(s)
        s = replaceSpokenPunctuation(s)
        s = dropFillers(s)
        s = tidySpacing(s)
        s = capitalise(s)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func replaceSpokenPunctuation(_ text: String) -> String {
        var s = text
        for item in spoken {
            let words = NSRegularExpression.escapedPattern(for: item.words).replacingOccurrences(of: "\\ ", with: "\\s+")
            // The speaker's own comma or full stop right after the word ("comma,") is absorbed.
            let pattern: String
            if item.always {
                pattern = "(?i)\\b\(words)\\b[.,]?"
            } else {
                pattern = "(?i)\\b\(words)\\b[.,]?(?=\\s*$|\\s*(?:new\\s+line|new\\s+paragraph)\\b)"
            }
            s = s.replacingOccurrences(of: pattern, with: item.mark, options: .regularExpression)
        }
        return s
    }

    static func dropFillers(_ text: String) -> String {
        let alternatives = fillers.joined(separator: "|")
        // The filler, a comma or dash after it, and the space before it.
        var s = text.replacingOccurrences(of: "(?i)(?:^|\\s)(?:\(alternatives))\\b[,.…-]*(?=\\s|$)", with: " ", options: .regularExpression)
        // "I, um, think": the comma before the filler stays out too.
        s = s.replacingOccurrences(of: "\\s+,", with: ",", options: .regularExpression)
        return s
    }

    static func tidySpacing(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        // No space before , . ? ! : ; and one after when a word follows.
        s = s.replacingOccurrences(of: "\\s+([,.?!:;])", with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "([,;?!])(?=[\\p{L}])", with: "$1 ", options: .regularExpression)
        s = s.replacingOccurrences(of: "([.:])(?=[\\p{L}])(?<![0-9]\\.)", with: "$1 ", options: .regularExpression)
        // Around line breaks: none of the spaces.
        s = s.replacingOccurrences(of: " *\\n *", with: "\n", options: .regularExpression)
        // A comma or period left at the very start (a dropped filler's).
        s = s.replacingOccurrences(of: "^[\\s,;:]+", with: "", options: .regularExpression)
        // A doubled mark ("..", ",,") from a word that carried its own.
        s = s.replacingOccurrences(of: ",{2,}", with: ",", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?<!\\.)\\.{2}(?!\\.)", with: ".", options: .regularExpression)
        return s
    }

    static func capitalise(_ text: String) -> String {
        var out = ""
        var upNext = true
        let chars = Array(text)
        for (i, ch) in chars.enumerated() {
            if upNext, ch.isLetter {
                out.append(contentsOf: String(ch).uppercased())
                upNext = false
                continue
            }
            out.append(ch)
            if ch == "\n" || ch == "." || ch == "?" || ch == "!" {
                // "3.5" or "e.g." mid-word: only a mark followed by space or the end starts a sentence.
                let next = i + 1 < chars.count ? chars[i + 1] : " "
                if ch == "\n" || next == " " || next == "\n" { upNext = true }
            } else if !ch.isWhitespace && !ch.isPunctuation { upNext = false }
        }
        // The pronoun: "i", "i'm", "i've", "i'll", "i'd".
        return out.replacingOccurrences(of: "\\bi(?=\\b|'(?:m|ve|ll|d)\\b)", with: "I", options: .regularExpression)
    }
}

/// Devanagari written in Latin letters (Hinglish is never left in Devanagari).
public enum LatinScript {
    public static func containsDevanagari(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x0900...0x097F).contains($0.value) }
    }

    /// A plain, diacritic-free romanisation of the Devanagari in `text`; other text untouched.
    /// A fallback only: with Claude on, the model writes natural Hinglish spelling instead.
    public static func transliterateDevanagari(_ text: String) -> String {
        guard containsDevanagari(text) else { return text }
        var out = ""
        var run = ""
        func flush() {
            guard !run.isEmpty else { return }
            let latin = run.applyingTransform(.toLatin, reverse: false) ?? run
            out += (latin.applyingTransform(.stripDiacritics, reverse: false) ?? latin)
            run = ""
        }
        for scalar in text.unicodeScalars {
            let v = scalar.value
            // The Devanagari block, and the danda marks that end its sentences.
            if (0x0900...0x097F).contains(v) {
                if v == 0x0964 { flush(); out += "." } else if v == 0x0965 { flush(); out += "." } else { run.unicodeScalars.append(scalar) }
            } else { flush(); out.unicodeScalars.append(scalar) }
        }
        flush()
        return out
    }
}
