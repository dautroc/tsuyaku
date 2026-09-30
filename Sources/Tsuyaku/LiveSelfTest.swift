import Foundation
import AVFoundation

/// Checks the live path's row rules -- where a subtitle row begins and ends
/// when nothing but the text itself marks a boundary -- with scripted deltas
/// and an injected clock. No network, no audio device.
///
/// The two end-to-end scripts replay real server traffic: fragment for
/// fragment and to the tenth of a second, what `--gemini-test` printed for a
/// synthesised Japanese clip and an English one. The Gemini translate model
/// sends no turn boundaries, so these fragments are all the segmenter will
/// ever have to go on.
///
/// Run with `Tsuyaku --store-selftest` (via `make test`).
@MainActor
enum LiveSelfTest {

    private static var failures = 0
    private static let t0 = ContinuousClock.now

    static func run() -> Int {
        failures = 0
        print("\n=== live row self-test ===")
        pendingSourceMovesIntoTheRow()
        everySentenceEndClosesTheRow()
        anAbbreviationIsNotASentenceEnd()
        whitespaceAloneOpensNoRow()
        turnEndClosesTheRow()
        outputSilenceClosesTheRow()
        sourceAloneDoesNotKeepARowOpen()
        otherLanguageWaitsForTheOpenRow()
        reconnectingLeavesTheRowOpen()
        unansweredSourceIsDropped()
        newLanguageDiscardsPendingSource()
        englishRowsAreTheEcho()
        flushClosesTheOpenRow()
        languageFallsBackToScoringWithoutACode()
        recordedJapaneseBecomesOneRowPerSentence()
        recordedEnglishEchoIsVerbatim()
        wavWrapsTheSamePCM()
        return failures
    }

    // MARK: - Rows

    private static func pendingSourceMovesIntoTheRow() {
        var s = LiveRowSegmenter()
        let heard = s.ingest(.source("本日の会議を", language: "ja"), now: at(0))
        expect("source before any output shows on the hearing line",
               heard == [.hearing("本日の会議を")])
        let ops = s.ingest(.target("Let's start", language: "en"), now: at(1))
        guard let id = began(ops) else { return expect("first output opens a row", false) }
        expect("the pending source moves into the new row",
               ops == [.begin(id, .ja), .hearing(""), .source(id, "本日の会議を"), .target(id, "Let's start")])
        expect("source heard while the row is open joins it",
               s.ingest(.source("始めます。", language: "ja"), now: at(1.5)) == [.source(id, "始めます。")])
    }

    /// The server's fragments ignore sentence boundaries: " work. Now," ends
    /// one sentence and starts the next.
    private static func everySentenceEndClosesTheRow() {
        var s = LiveRowSegmenter()
        guard let first = began(s.ingest(.target("Thank you for your hard", language: "en"), now: at(0))) else {
            return expect("output opens a row", false)
        }
        let ops = s.ingest(.target(" work. Now,", language: "en"), now: at(0.7))
        guard ops.count == 4, case .begin(let second, .ja) = ops[2] else {
            return expect("a fragment spanning a sentence end is cut there (got \(ops))", false)
        }
        expect("a fragment spanning a sentence end is cut there, and the next row starts trimmed",
               ops == [.target(first, " work."), .finish(first), .begin(second, .ja), .target(second, "Now,")])
    }

    private static func anAbbreviationIsNotASentenceEnd() {
        var s = LiveRowSegmenter()
        guard let id = began(s.ingest(.target("I spoke to Mr", language: nil), now: at(0))) else {
            return expect("output opens a row", false)
        }
        expect("an abbreviation split across fragments does not cut",
               s.ingest(.target(". Tanaka about 3.5 million", language: nil), now: at(1))
                == [.target(id, ". Tanaka about 3.5 million")])
    }

    private static func whitespaceAloneOpensNoRow() {
        var s = LiveRowSegmenter()
        expect("whitespace-only output opens no row", s.ingest(.target(" ", language: nil), now: at(0)).isEmpty)
    }

    private static func turnEndClosesTheRow() {
        var s = LiveRowSegmenter()
        guard let id = began(s.ingest(.target("Hello", language: nil), now: at(0))) else {
            return expect("output opens a row", false)
        }
        expect("turn end closes the row", s.ingest(.turnEnd, now: at(0.2)) == [.finish(id)])
        expect("a second turn end is a no-op", s.ingest(.turnEnd, now: at(0.3)).isEmpty)
    }

    private static func outputSilenceClosesTheRow() {
        var s = LiveRowSegmenter()
        guard let id = began(s.ingest(.target("We will", language: nil), now: at(0))) else {
            return expect("output opens a row", false)
        }
        expect("the usual ~1s gap between fragments keeps the row", s.tick(now: at(2.0)).isEmpty)
        expect("2.5s of output silence closes it", s.tick(now: at(2.6)) == [.finish(id)])
    }

    /// Source for the next sentence must not hold the row open: the row is
    /// waiting for its translation, not for more speech.
    private static func sourceAloneDoesNotKeepARowOpen() {
        var s = LiveRowSegmenter()
        guard let id = began(s.ingest(.target("Thank you", language: nil), now: at(0))) else {
            return expect("output opens a row", false)
        }
        _ = s.ingest(.source("次に", language: "ja"), now: at(2.0))
        expect("source does not refresh a row's idle clock", s.tick(now: at(2.6)) == [.finish(id)])
    }

    /// The Japanese row's translation is usually still arriving when the
    /// English speaker starts. Cutting it there would render its last words
    /// as an English row.
    private static func otherLanguageWaitsForTheOpenRow() {
        var s = LiveRowSegmenter()
        _ = s.ingest(.source("よろしくお願いします。", language: "ja"), now: at(0))
        guard let ja = began(s.ingest(.target("Thank you", language: "en"), now: at(0.5))) else {
            return expect("output opens a row", false)
        }
        expect("English heard during a Japanese row waits on the hearing line",
               s.ingest(.source("Sounds good", language: "en"), now: at(0.8)) == [.hearing("Sounds good")])
        let ops = s.ingest(.target(" very much. Sounds", language: "en"), now: at(1.2))
        guard ops.count == 5, case .begin(let en, .en) = ops[2] else {
            return expect("the Japanese row finishes, then the echo opens an English row (got \(ops))", false)
        }
        expect("the Japanese row finishes its sentence, then the echo opens an English row",
               ops == [.target(ja, " very much."), .finish(ja), .begin(en, .en), .hearing(""), .source(en, "Sounds")])
    }

    private static func reconnectingLeavesTheRowOpen() {
        var s = LiveRowSegmenter()
        _ = s.ingest(.target("Next", language: nil), now: at(0))
        expect("a reconnect alone changes no row", s.ingest(.reconnecting, now: at(0.1)).isEmpty)
    }

    /// English with echo off: the server transcribes it and renders nothing.
    private static func unansweredSourceIsDropped() {
        var s = LiveRowSegmenter()
        _ = s.ingest(.source("Can everyone hear me?", language: "en"), now: at(0))
        expect("unanswered source is kept for a while", s.tick(now: at(5)).isEmpty)
        expect("and then dropped from the hearing line", s.tick(now: at(6.5)) == [.hearing("")])
    }

    private static func newLanguageDiscardsPendingSource() {
        var s = LiveRowSegmenter()
        _ = s.ingest(.source("Can everyone hear me?", language: "en"), now: at(0))
        let heard = s.ingest(.source("本日は", language: "ja"), now: at(1))
        expect("switching language restarts pending source", heard == [.hearing("本日は")])
        let ops = s.ingest(.target("Today", language: "en"), now: at(1.5))
        guard let id = began(ops) else { return expect("output opens a row", false) }
        expect("only the Japanese reaches the row", ops == [.begin(id, .ja), .hearing(""), .source(id, "本日は"), .target(id, "Today")])
    }

    private static func englishRowsAreTheEcho() {
        var s = LiveRowSegmenter()
        _ = s.ingest(.source("Okay, thanks", language: "en"), now: at(0))
        let ops = s.ingest(.target("Okay, thanks", language: "en"), now: at(1))
        guard let id = began(ops) else { return expect("the echo opens a row", false) }
        expect("an English row takes the echo as its text, and the transcript it repeats is dropped",
               ops == [.begin(id, .en), .hearing(""), .source(id, "Okay, thanks")])
        expect("English heard during an English row adds nothing: the echo carries it",
               s.ingest(.source(" everyone. I", language: "en"), now: at(1.5)).isEmpty)
        let next = s.ingest(.target(" everyone. I", language: "en"), now: at(2))
        guard next.count == 4, case .begin(let second, .en) = next[2] else {
            return expect("the row after an English row is still English (got \(next))", false)
        }
        expect("the row after an English row is still English",
               next == [.source(id, " everyone."), .finish(id), .begin(second, .en), .source(second, "I")])
    }

    private static func flushClosesTheOpenRow() {
        var s = LiveRowSegmenter()
        guard let id = began(s.ingest(.target("Half a", language: nil), now: at(0))) else {
            return expect("output opens a row", false)
        }
        expect("flush closes the open row", s.flush() == [.finish(id)])
        _ = s.ingest(.source("えーと", language: "ja"), now: at(1))
        expect("flush clears the hearing line", s.flush() == [.hearing("")])
    }

    private static func languageFallsBackToScoringWithoutACode() {
        let th = 0.5
        expect("a language code wins",
               LiveRowSegmenter.language(code: "en-US", text: "本日の定例会議を始めます", threshold: th) == .en)
        expect("any non-English code renders as a translation",
               LiveRowSegmenter.language(code: "th", text: "", threshold: th) == .ja)
        expect("no code: Japanese text scores as Japanese",
               LiveRowSegmenter.language(code: nil, text: "本日の定例会議を始めます", threshold: th) == .ja)
        expect("no code: English text scores as English",
               LiveRowSegmenter.language(code: "und", text: "we should ship this on friday", threshold: th) == .en)
        expect("no code: too little text to judge is nil",
               LiveRowSegmenter.language(code: nil, text: "はい", threshold: th) == nil)
    }

    // MARK: - Recorded traffic

    /// `--gemini-test` on "お疲れ様です。それでは本日の定例会議を始めます。
    /// まず、来月の見積もりについて確認させてください。"
    private static func recordedJapaneseBecomesOneRowPerSentence() {
        let rows = replay([
            (3.24, .source("お疲れ様です。それでは", language: "ja")),
            (3.43, .target("Thank you for your hard", language: "en")),
            (3.93, .source("本日の", language: "ja")),
            (4.12, .target(" work. Now,", language: "en")),
            (5.00, .source("定例会議を", language: "ja")),
            (5.14, .target(" let's start today's", language: "en")),
            (5.97, .source("始めます。まず", language: "ja")),
            (6.11, .target(" regular meeting.", language: "en")),
            (7.05, .source("来月の", language: "ja")),
            (7.37, .target(" First, let's", language: "en")),
            (8.05, .source("見積もりについ", language: "ja")),
            (8.36, .target(" discuss next month's", language: "en")),
            (9.09, .source("て確認", language: "ja")),
            (9.38, .target(" estimates.", language: "en")),
            (10.21, .source("させてください。", language: "ja")),
            (10.37, .target(" Please confirm.", language: "en")),
        ])
        expect("one row per English sentence, all settled",
               rows.history.map(\.target) == ["Thank you for your hard work.",
                                             "Now, let's start today's regular meeting.",
                                             "First, let's discuss next month's estimates.",
                                             "Please confirm."]
                && rows.live.isEmpty && rows.hearing.isEmpty)
        expect("every Japanese fragment lands on some row, in order",
               rows.history.map(\.source).joined()
                == "お疲れ様です。それでは本日の定例会議を始めます。まず来月の見積もりについて確認させてください。")
        expect("each row carries source near its own sentence",
               rows.history.map(\.source) == ["お疲れ様です。それでは本日の", "定例会議を始めます。まず",
                                               "来月の見積もりについて確認", "させてください。"])
    }

    /// `--gemini-test` on an English clip, echo on.
    private static func recordedEnglishEchoIsVerbatim() {
        let rows = replay([
            (3.25, .source("Okay, thanks everyone for", language: "en")),
            (3.83, .source(" joining today. I", language: "en")),
            (4.10, .target("Okay, thanks everyone for", language: "en")),
            (4.92, .source(" think we should ship the", language: "en")),
            (5.32, .target(" joining today. I", language: "en")),
            (5.92, .source(" new release on", language: "en")),
            (6.32, .target(" think we should ship the", language: "en")),
            (6.95, .source(" Friday and then", language: "en")),
            (7.30, .target(" new release on", language: "en")),
            (7.99, .source(" review the budget next", language: "en")),
            (8.60, .target(" Friday and then", language: "en")),
            (9.15, .source(" week.", language: "en")),
            (9.58, .target(" review the budget next", language: "en")),
            (10.57, .target(" week.", language: "en")),
        ])
        expect("English rows are verbatim, one per sentence, with no translation",
               rows.history.map(\.source) == ["Okay, thanks everyone for joining today.",
                                             "I think we should ship the new release on Friday and then review the budget next week."]
                && rows.history.allSatisfy { $0.language == .en && $0.target.isEmpty }
                && rows.live.isEmpty && rows.hearing.isEmpty)
    }

    /// Feeds `script` through a segmenter into a real store, ticking every
    /// 0.5 s as the pipeline does, and runs on past the end so the idle
    /// rules get their chance.
    private static func replay(_ script: [(Double, LiveDelta)]) -> SubtitleStore {
        var s = LiveRowSegmenter()
        let store = SubtitleStore()
        var clock = 0.0
        for (t, delta) in script {
            while clock + 0.5 <= t { clock += 0.5; store.apply(s.tick(now: at(clock))) }
            store.apply(s.ingest(delta, now: at(t)))
        }
        for _ in 0..<20 { clock += 0.5; store.apply(s.tick(now: at(clock))) }
        return store
    }

    // MARK: - Audio

    private static func wavWrapsTheSamePCM() {
        guard let b = AVAudioPCMBuffer(pcmFormat: WAVEncoder.captureFormat, frameCapacity: 160),
              let p = b.int16ChannelData?[0] else { return expect("allocate a test buffer", false) }
        b.frameLength = 160
        for i in 0..<160 { p[i] = Int16(i * 97 % 3000) }
        let pcm = WAVEncoder.pcm([b, b])
        let wav = WAVEncoder.encode([b, b]) ?? Data()
        expect("pcm is two bytes per frame", pcm.count == 640)
        expect("encode is a 44-byte header over exactly the pcm",
               wav.count == 44 + pcm.count && wav.dropFirst(44) == pcm)
    }

    // MARK: -

    private static func at(_ seconds: Double) -> ContinuousClock.Instant {
        t0.advanced(by: .milliseconds(Int(seconds * 1000)))
    }

    private static func began(_ ops: [LiveRowSegmenter.Op]) -> UUID? {
        for op in ops { if case .begin(let id, _) = op { return id } }
        return nil
    }

    private static func expect(_ what: String, _ ok: Bool) {
        print("  \(ok ? "ok  " : "FAIL") \(what)")
        if !ok { failures += 1 }
    }
}
