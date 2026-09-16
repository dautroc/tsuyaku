import Foundation

/// Which language a turn was spoken in.
///
/// The app runs one recognizer per case, concurrently, over the same audio.
enum SpokenLanguage: String, Sendable, Codable, CaseIterable {
    case ja
    case en

    var bcp47: String {
        switch self {
        case .ja: "ja-JP"
        case .en: "en-US"
        }
    }

    var display: String {
        switch self {
        case .ja: "JA"
        case .en: "EN"
        }
    }

    var other: SpokenLanguage { self == .ja ? .en : .ja }

    /// The app listens for exactly two languages, so anything that is not
    /// Japanese is treated as the English side.
    static func matching(_ locale: Locale) -> SpokenLanguage {
        locale.identifier(.bcp47).lowercased().hasPrefix("ja") ? .ja : .en
    }
}

/// Decides which of two concurrent recognizers is hearing its own language.
///
/// The signal is the *script* of the Japanese recognizer's output, not a
/// comparison of the two engines' confidences. A ja model fed English audio
/// transliterates it into katakana; a ja model fed Japanese emits hiragana
/// grammatical glue on nearly every clause. That asymmetry lives inside one
/// model's output alphabet, so it needs none of the cross-model calibration
/// that makes comparing two engines' confidence numbers unsound.
///
/// The naive version of this -- "mostly katakana means English" -- is wrong,
/// and wrong on ordinary meeting speech: 「ミーティングのスケジュールをリスケ
/// してもいいですか」 is entirely Japanese and two-thirds katakana. Three
/// signals are combined so that sentence still scores high:
///
///   1. hiragana fraction   -- glue characters the transliterator never emits
///   2. kanji fraction      -- a bonus, deliberately the smallest weight, because
///                             perfectly ordinary Japanese can contain no kanji
///   3. glue-token hits     -- particles and inflections, the strongest evidence
///
/// minus a penalty for long unbroken katakana runs, which is what transliterated
/// English actually looks like: real Japanese breaks loanwords up with particles.
///
/// Everything here is a pure function of a `String`, so the whole decision
/// surface is checkable headlessly. See `PickerSelfTest`.
enum LanguageScore {

    struct Stats: Sendable, Equatable {
        var hiragana = 0
        var katakana = 0
        var kanji = 0
        var latin = 0
        var digit = 0
        var other = 0
        var glueHits = 0
        /// Longest unbroken katakana span, counting 'ー' and '・'.
        var longestKatakanaRun = 0

        /// Characters that carry language evidence. Punctuation and spaces do not.
        var content: Int { hiragana + katakana + kanji + latin }
    }

    /// Every tunable constant, in one place, so fitting against recorded audio
    /// is a sweep rather than an edit. Defaults are a starting hypothesis and
    /// are expected to be replaced by values fitted from `--listen-dual` output.
    struct Weights: Sendable {
        var hiragana = 0.45
        var kanji = 0.15
        var glue = 0.40
        var runPenalty = 0.25

        var hiraganaLo = 0.06, hiraganaHi = 0.28
        var kanjiLo = 0.01, kanjiHi = 0.10
        /// One glue hit per this many content characters counts as saturated.
        var gluePer = 12.0
        var runFloor = 8.0, runSpan = 12.0

        init() {}

        /// Returned when there is not enough text to judge. Deliberately the
        /// exact midpoint so callers can test for it.
        static let unknown = 0.5
    }

    /// Particles and inflections. A model transliterating English into katakana
    /// essentially never produces these; Japanese business speech is saturated
    /// with them. Multi-character entries overlap the single-character ones on
    /// purpose -- 「でしょう」 counting as both で and でしょう is extra evidence,
    /// not a bug, because the score saturates anyway.
    static let glueTokens: [String] = [
        "は", "を", "が", "の", "に", "へ", "で", "と", "も",
        "から", "まで", "です", "ます", "ました", "ません", "ない",
        "ので", "けど", "という", "でしょう", "ください",
    ]

    static func stats(_ text: String) -> Stats {
        var s = Stats()
        var run = 0

        for ch in text {
            guard let v = ch.unicodeScalars.first?.value else { continue }

            switch v {
            case 0x3041...0x309F:
                s.hiragana += 1
                run = 0
            case 0x30A0...0x30FF, 0xFF66...0xFF9D:
                // 'ー' (U+30FC) and '・' (U+30FB) fall in this range and extend a
                // run, which is what makes the run signal track transliteration.
                s.katakana += 1
                run += 1
                s.longestKatakanaRun = max(s.longestKatakanaRun, run)
            case 0x4E00...0x9FFF, 0x3400...0x4DBF:
                s.kanji += 1
                run = 0
            default:
                if ch.isLetter { s.latin += 1 }
                else if ch.isNumber { s.digit += 1 }
                else { s.other += 1 }
                run = 0
            }
        }

        for token in glueTokens {
            s.glueHits += occurrences(of: token, in: text)
        }
        return s
    }

    /// 1.0 = certainly Japanese speech. 0.0 = certainly English audio being
    /// transliterated by the Japanese model. Exactly `Weights.unknown` (0.5)
    /// means there was not enough text to judge, which callers treat as
    /// "keep doing whatever we were doing" rather than as a coin flip.
    static func japaneseness(_ text: String,
                             minContentChars: Int = 6,
                             w: Weights = .init()) -> Double {
        let s = stats(text)
        guard s.content >= minContentChars else { return Weights.unknown }

        let content = Double(s.content)
        let h = norm(Double(s.hiragana) / content, w.hiraganaLo, w.hiraganaHi)
        let k = norm(Double(s.kanji) / content, w.kanjiLo, w.kanjiHi)
        let g = min(1, Double(s.glueHits) / max(1, content / w.gluePer))
        let runExcess = clamp((Double(s.longestKatakanaRun) - w.runFloor) / w.runSpan, 0, 1)

        let raw = w.hiragana * h + w.kanji * k + w.glue * g
        return clamp(raw - w.runPenalty * runExcess, 0, 1)
    }

    // MARK: -

    static func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var from = haystack.startIndex
        while from < haystack.endIndex,
              let r = haystack.range(of: needle, range: from..<haystack.endIndex) {
            count += 1
            from = r.upperBound
        }
        return count
    }

    private static func norm(_ x: Double, _ lo: Double, _ hi: Double) -> Double {
        guard hi > lo else { return 0 }
        return clamp((x - lo) / (hi - lo), 0, 1)
    }

    private static func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double {
        min(max(x, lo), hi)
    }
}
