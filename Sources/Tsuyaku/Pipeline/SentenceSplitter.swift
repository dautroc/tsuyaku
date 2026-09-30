import Foundation

/// Splits cumulative recognizer text into complete sentences plus an
/// unterminated trailing fragment.
///
/// Pulled out of `SegmentGate` because it now has to serve two languages with
/// different punctuation, and because the ASCII '.' needs guards that are much
/// easier to check as a pure function than through a live recognizer.
///
/// The guards apply to '.' **only**. 。！？ are unambiguous terminators in
/// Japanese and are never second-guessed.
enum SentenceSplitter {

    static func split(_ text: String,
                      terminators: Set<Character>,
                      abbreviations: Set<String> = []) -> (sentences: [String], tail: String) {

        let chars = Array(text)
        var sentences: [String] = []
        var current = ""

        for i in chars.indices {
            let ch = chars[i]
            current.append(ch)

            guard terminators.contains(ch) else { continue }
            guard ch != "." || isTerminalPeriod(chars, at: i, abbreviations: abbreviations) else { continue }

            let s = current.trimmingCharacters(in: .whitespaces)
            if !s.isEmpty { sentences.append(s) }
            current = ""
        }

        return (sentences, current.trimmingCharacters(in: .whitespaces))
    }

    /// Where the first complete sentence in `text` ends: the index just past
    /// its terminator, or nil if there is none yet. The same rules as `split`,
    /// for callers that must cut a fragment at the boundary rather than
    /// receive it trimmed.
    static func firstEnd(in text: String,
                         terminators: Set<Character>,
                         abbreviations: Set<String> = []) -> String.Index? {
        let chars = Array(text)
        for i in chars.indices where terminators.contains(chars[i]) {
            if chars[i] != "." || isTerminalPeriod(chars, at: i, abbreviations: abbreviations) {
                return text.index(text.startIndex, offsetBy: i + 1)
            }
        }
        return nil
    }

    /// Whether the '.' at `i` actually ends a sentence.
    ///
    /// A '.' at the end of the buffer still terminates unless a guard fires.
    /// That asymmetry is deliberate: an abbreviation at the end of a cumulative
    /// buffer is common ("I talked to Mr." with more still coming), and an
    /// over-split costs one short extra line while a miss costs a full
    /// `maxLatency` stall.
    private static func isTerminalPeriod(_ chars: [Character],
                                         at i: Int,
                                         abbreviations: Set<String>) -> Bool {

        // A decimal point: 3.5, 1.2.3, version numbers, percentages.
        if i > 0, i + 1 < chars.count, chars[i - 1].isNumber, chars[i + 1].isNumber {
            return false
        }

        // The token immediately before the dot, letters plus interior dots, so
        // that "U.S." presents as "u.s" rather than as a bare "s".
        var token = ""
        var j = i - 1
        while j >= 0, chars[j].isLetter || chars[j] == "." {
            token.insert(chars[j], at: token.startIndex)
            j -= 1
        }

        if abbreviations.contains(token.lowercased()) { return false }

        // An initial: "A. Smith", "J. R. R. Tolkien".
        if token.filter({ $0.isLetter }).count == 1 { return false }

        return true
    }
}

/// Per-language tuning for `SegmentGate`.
struct GateConfig: Sendable {
    var maxLatency: Duration
    var terminators: Set<Character>
    var abbreviations: Set<String>

    init(maxLatency: Duration,
         terminators: Set<Character>,
         abbreviations: Set<String> = []) {
        self.maxLatency = maxLatency
        self.terminators = terminators
        self.abbreviations = abbreviations
    }

    /// The 7s backstop buys protection from SOV retraction: a Japanese clause
    /// flushed before its verb lands produces English that has to be rewritten.
    static let japanese = GateConfig(
        maxLatency: .seconds(7),
        terminators: ["。", "！", "？", "．", "!", "?", "."]
    )

    /// English is shown verbatim, so there is no retraction to protect against
    /// and latency is the only remaining cost -- hence a much shorter backstop.
    static let english = GateConfig(
        maxLatency: .milliseconds(2500),
        terminators: [".", "!", "?"],
        abbreviations: [
            "mr", "mrs", "ms", "dr", "prof", "st", "vs", "etc",
            "e.g", "i.e", "u.s", "u.k", "a.m", "p.m", "jr", "sr",
            "inc", "ltd", "co", "fig", "no", "approx", "dept", "est",
        ]
    )
}
