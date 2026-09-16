import Foundation
import CoreMedia

/// Checks the three pure cores of the language detector -- script scoring,
/// sentence splitting, and turn arbitration -- with no audio, no models and no
/// network.
///
/// This exists because the picker is the whole feature: if it misfires, a
/// Japanese turn renders as English word salad, which is worse than a bad
/// translation. All three cores are pure functions or value types with an
/// injected clock precisely so that their entire decision surface is reachable
/// from here.
///
/// Run with `Tsuyaku --store-selftest` (via `make test`).
@MainActor
enum PickerSelfTest {

    private static var failures = 0

    static func run() -> Int {
        failures = 0
        print("\n=== language picker self-test ===")
        scoresGenuineJapaneseHigh()
        scoresTransliteratedEnglishLow()
        scoresLoanwordHeavyJapaneseHigh()
        reportsUnknownOnTooLittleText()
        splitsEnglishAroundAbbreviations()
        splitsJapaneseAroundDecimals()
        locksOnFirstTranslatableUnit()
        doesNotFlipMidTurn()
        onlyTheWinnerEndsTheTurn()
        safetyValveReleasesAWedgedLock()
        stickinessReusesThePreviousTurn()
        treatsASilentJapaneseEngineAsEvidence()
        return failures
    }

    // MARK: - LanguageScore

    /// Every fixture long enough to judge must read as clearly Japanese.
    private static func scoresGenuineJapaneseHigh() {
        var judged = 0, worst = 1.0, worstText = ""
        for u in Fixtures.japaneseMeetingUtterances {
            let s = LanguageScore.japaneseness(u)
            guard s != LanguageScore.Weights.unknown else { continue }
            judged += 1
            if s < worst { worst = s; worstText = u }
        }
        expect("every judged Japanese fixture scores > 0.8 (worst \(fmt(worst)) on \"\(worstText)\")",
               judged > 10 && worst > 0.8)
    }

    /// Katakana transliteration of English, which is what the ja model actually
    /// emits on English audio. Samples must eventually be REPLACED with real
    /// `--listen-dual` output -- hand-written katakana does not reproduce the
    /// model's spacing and 'ー' placement.
    private static func scoresTransliteratedEnglishLow() {
        let salad = [
            "ウィシュドシップオンフライデー",
            "アイシンクウィーシュドムーブザデッドラインネクストウィーク",
            "レッツゴーオーバーザナンバーズファースト",
            "キャンユーシェアザスクリーンプリーズ",
        ]
        var worst = 0.0, worstText = ""
        for t in salad {
            let s = LanguageScore.japaneseness(t)
            if s > worst { worst = s; worstText = t }
        }
        expect("transliterated English scores < 0.2 (worst \(fmt(worst)) on \"\(worstText)\")",
               worst < 0.2)
    }

    /// The case a naive "mostly katakana means English" rule gets wrong. These
    /// are entirely Japanese and mostly katakana.
    private static func scoresLoanwordHeavyJapaneseHigh() {
        let loanword = [
            "ミーティングのスケジュールをリスケしてもいいですか。",
            "クライアントのフィードバックをスプレッドシートにまとめました。",
            "リリースのタイミングはマーケティングチームと相談しています。",
        ]
        var worst = 1.0, worstText = ""
        for t in loanword {
            let s = LanguageScore.japaneseness(t)
            if s < worst { worst = s; worstText = t }
        }
        expect("loanword-heavy Japanese still scores > 0.8 (worst \(fmt(worst)) on \"\(worstText)\")",
               worst > 0.8)
    }

    private static func reportsUnknownOnTooLittleText() {
        let unknown = LanguageScore.Weights.unknown
        expect("\"はい\" is unknown, not a coin flip", LanguageScore.japaneseness("はい") == unknown)
        expect("empty text is unknown", LanguageScore.japaneseness("") == unknown)
        expect("\"OK\" is unknown", LanguageScore.japaneseness("OK") == unknown)
    }

    // MARK: - SentenceSplitter

    private static func splitsEnglishAroundAbbreviations() {
        let cfg = GateConfig.english
        let (s1, t1) = SentenceSplitter.split("Mr. Smith went to the U.S. on 3.5 percent.",
                                              terminators: cfg.terminators,
                                              abbreviations: cfg.abbreviations)
        expect("abbreviations and decimals do not split an English sentence (got \(s1.count))",
               s1.count == 1 && t1.isEmpty)

        let (s2, _) = SentenceSplitter.split("Hello. World.",
                                             terminators: cfg.terminators,
                                             abbreviations: cfg.abbreviations)
        expect("two ordinary English sentences still split", s2.count == 2)

        let (s3, t3) = SentenceSplitter.split("Let's ship it on Friday. I think we",
                                              terminators: cfg.terminators,
                                              abbreviations: cfg.abbreviations)
        expect("an unterminated English fragment stays in the tail",
               s3.count == 1 && t3 == "I think we")
    }

    private static func splitsJapaneseAroundDecimals() {
        let cfg = GateConfig.japanese
        let (s1, _) = SentenceSplitter.split("金額は3.5%です。",
                                             terminators: cfg.terminators,
                                             abbreviations: cfg.abbreviations)
        expect("a decimal point does not split a Japanese sentence (got \(s1.count))", s1.count == 1)

        let (s2, t2) = SentenceSplitter.split("それでは始めます。よろしく",
                                              terminators: cfg.terminators,
                                              abbreviations: cfg.abbreviations)
        expect("a terminated sentence plus an unterminated tail",
               s2.count == 1 && t2 == "よろしく")
    }

    // MARK: - PickerState

    private static let japanese = "それでは本日の定例会議を始めます。"
    private static let katakana = "アイシンクウィーシュドムーブザデッドラインネクストウィーク"

    private static func seg(_ text: String, _ language: SpokenLanguage, isFinal: Bool = false) -> Segment {
        Segment(text: text, isFinal: isFinal, range: .invalid, language: language)
    }

    private static func locksOnFirstTranslatableUnit() {
        var p = PickerState()
        p.observe(seg(japanese, .ja))
        p.observe(seg("so then let's about the meeting", .en))

        let id = UUID()
        let out = p.submit(.translate(id: id, source: japanese, provisional: false),
                           from: .ja, now: .now)
        expect("a Japanese turn locks to ja and forwards",
               out == .forward(DecidedEvent(language: .ja,
                                            event: .translate(id: id, source: japanese, provisional: false)))
               && p.locked == .ja)

        let dropped = p.submit(.translate(id: UUID(), source: "word salad", provisional: false),
                               from: .en, now: .now)
        expect("the losing engine's events are dropped, never translated",
               dropped == .drop(.en))
    }

    private static func doesNotFlipMidTurn() {
        var p = PickerState()
        p.observe(seg(katakana, .ja))
        p.observe(seg("we should move the deadline next week", .en))

        let id = UUID()
        _ = p.submit(.translate(id: id, source: "we should move the deadline", provisional: false),
                     from: .en, now: .now)
        expect("transliterated katakana locks the turn to en", p.locked == .en)

        // The ja engine revises into something that scores Japanese. Too late.
        p.observe(seg(japanese, .ja))
        let out = p.submit(.translate(id: UUID(), source: japanese, provisional: false),
                           from: .ja, now: .now)
        expect("a mid-turn revision cannot flip the language", out == .drop(.ja) && p.locked == .en)
    }

    private static func onlyTheWinnerEndsTheTurn() {
        var p = PickerState()
        p.observe(seg(japanese, .ja))
        let id = UUID()
        _ = p.submit(.translate(id: id, source: japanese, provisional: false), from: .ja, now: .now)

        let loser = p.submit(.settled(id: UUID()), from: .en, now: .now)
        expect("the loser finalizing does not end the turn",
               loser == .drop(.en) && p.locked == .ja)

        let winner = p.submit(.settled(id: id), from: .ja, now: .now)
        expect("the winner finalizing ends the turn and forwards",
               winner == .forward(DecidedEvent(language: .ja, event: .settled(id: id)))
               && p.locked == nil && p.lastTurn == .ja)
    }

    private static func safetyValveReleasesAWedgedLock() {
        var p = PickerState()
        p.observe(seg(japanese, .ja))
        let t0 = ContinuousClock.now
        _ = p.submit(.translate(id: UUID(), source: japanese, provisional: false), from: .ja, now: t0)

        expect("the lock holds before the timeout",
               p.tick(now: t0.advanced(by: .seconds(5))) == false && p.locked == .ja)
        expect("a winner that never finalizes is released by the safety valve",
               p.tick(now: t0.advanced(by: .seconds(13))) == true && p.locked == nil)
    }

    private static func stickinessReusesThePreviousTurn() {
        var tuning = PickerState.Tuning()
        tuning.defaultLanguage = .ja
        var p = PickerState(tuning: tuning)

        // Establish English as the previous turn.
        p.observe(seg(katakana, .ja))
        let id = UUID()
        _ = p.submit(.translate(id: id, source: "we should move the deadline", provisional: false),
                     from: .en, now: .now)
        _ = p.submit(.settled(id: id), from: .en, now: .now)
        expect("the previous turn is remembered", p.lastTurn == .en)

        // Now an utterance too short to judge.
        p.observe(seg("はい", .ja))
        let choice = p.choose()
        expect("an undecidable utterance sticks to the previous turn rather than the default",
               choice.language == .en && choice.reason == .tooShort)
    }

    /// Measured with `--listen-dual`: fed English, the ja model sometimes emits
    /// nothing at all instead of transliterating. The script ratio is blind to
    /// that -- there is no text to score -- so one engine's silence while the
    /// other produces a full sentence has to count on its own.
    private static func treatsASilentJapaneseEngineAsEvidence() {
        var p = PickerState()
        p.observe(seg("", .ja))
        p.observe(seg("I think we should move the deadline to next week", .en))

        let choice = p.choose()
        expect("a silent ja engine plus a talking en engine picks en",
               choice.language == .en && choice.reason == .silence)

        // The signal must not fire merely because nobody has said much yet.
        var q = PickerState()
        q.observe(seg("", .ja))
        q.observe(seg("okay", .en))
        expect("a brief en fragment alone is not enough to call it English",
               q.choose().reason == .tooShort)

        // A ja engine that is merely a beat behind must not be read as silent.
        var r = PickerState()
        r.observe(seg("そ", .ja))
        r.observe(seg("I think we should move the deadline to next week", .en))
        expect("a ja engine one character behind is not treated as silent",
               r.choose().reason == .tooShort)
    }

    // MARK: -

    private static func fmt(_ d: Double) -> String { String(format: "%.2f", d) }

    private static func expect(_ what: String, _ ok: Bool) {
        print("  \(ok ? "ok  " : "FAIL") \(what)")
        if !ok { failures += 1 }
    }
}
