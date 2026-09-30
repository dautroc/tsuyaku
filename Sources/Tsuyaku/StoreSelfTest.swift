import Foundation
import CoreGraphics

/// Drives `SubtitleStore` through the event sequences the gate actually
/// produces, so the live -> history graduation rule can be checked without a
/// microphone, a network round trip, or eyeballing the panel.
///
/// Run with `Tsuyaku --store-selftest`.
@MainActor
enum StoreSelfTest {

    private static var failures = 0

    static func run() async {
        print("=== SubtitleStore self-test ===")
        singleSentence()
        multiSentenceTurn()
        provisionalThenRevised()
        failedTranslation()
        englishRowNeedsNoTranslation()
        transcriptDistinguishesTheTwoRowShapes()
        uniqueRowIDs()
        historyCap()
        settledCountSurvivesCap()
        settledCountCountsRowsNotCalls()
        clearResetsSettledCount()
        onSettledReportsEachRowOnce()
        transcriptOmitsAnEmptySource()
        scrollRuleFollowsTheSpeaker()
        scrollRuleSurvivesTheLivePane()
        scrollRuleLetsTheUserReadBack()
        failures += PickerSelfTest.run()
        failures += LiveSelfTest.run()
        failures += GlossarySelfTest.run()
        failures += TranscriptSelfTest.run()
        failures += PanelStyleSelfTest.run()
        failures += VoiceSelfTest.run()
        failures += await FallbackSelfTest.run()
        print(failures == 0 ? "\nall checks passed" : "\n\(failures) CHECK(S) FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - Cases

    /// The ordinary path: one sentence, translated, settled.
    private static func singleSentence() {
        let s = SubtitleStore()
        let u = UUID()
        s.beginLine(utterance: u, source: "お疲れ様です。", provisional: false)
        expect("stays live while translating", s.live.count == 1 && s.history.isEmpty)
        s.append(utterance: u, delta: "Thank you ")
        s.append(utterance: u, delta: "for your hard work.")
        s.finishLine(utterance: u)
        expect("graduates on translation end", s.live.isEmpty && s.history.count == 1)
        expect("carries the full translation",
               s.history.first?.target == "Thank you for your hard work.")
        s.settle(utterance: u)
        expect("late settle is harmless", s.live.isEmpty && s.history.count == 1)
    }

    /// One spoken turn cut into three sentences -- all sharing an utterance id.
    private static func multiSentenceTurn() {
        let s = SubtitleStore()
        let u = UUID()
        for (i, ja) in ["一つ目。", "二つ目。", "三つ目。"].enumerated() {
            s.beginLine(utterance: u, source: ja, provisional: false)
            s.append(utterance: u, delta: "part \(i + 1)")
            s.finishLine(utterance: u)
        }
        s.settle(utterance: u)
        expect("every sentence graduates", s.live.isEmpty && s.history.count == 3)
        expect("in spoken order",
               s.history.map(\.target) == ["part 1", "part 2", "part 3"])
    }

    /// The 7s backstop translates an unfinished clause, then the real sentence
    /// arrives and replaces it. The provisional row must NOT reach history.
    private static func provisionalThenRevised() {
        let s = SubtitleStore()
        let u = UUID()
        s.beginLine(utterance: u, source: "納期については", provisional: true)
        s.append(utterance: u, delta: "As for the deadline")
        s.finishLine(utterance: u)
        expect("provisional row waits in live", s.live.count == 1 && s.history.isEmpty)

        s.beginLine(utterance: u, source: "納期については来月まで。", provisional: false)
        expect("revision replaces, not appends", s.live.count == 1)
        expect("revised text shown", s.live.first?.source == "納期については来月まで。")
        expect("revision clears stale translation", s.live.first?.target == "")

        s.append(utterance: u, delta: "As for the deadline, until next month.")
        s.finishLine(utterance: u)
        expect("revised row graduates once", s.live.isEmpty && s.history.count == 1)
    }

    /// A translation failure is terminal: the row must still leave `live`,
    /// or the live pane wedges and history never grows again.
    private static func failedTranslation() {
        let s = SubtitleStore()
        let u = UUID()
        s.beginLine(utterance: u, source: "予算の件です。", provisional: false)
        s.fail(utterance: u, message: "translation failed: timeout")
        s.finishLine(utterance: u)
        expect("failed row graduates", s.live.isEmpty && s.history.count == 1)
        expect("failure is flagged", s.history.first?.failed == true)
    }

    /// `ForEach` and `scrollTo` both need row identity to be unique, which is
    /// exactly what sharing the utterance id used to break.
    /// An English row has no translation step at all, so nothing ever calls
    /// `append`. It still has to reach `finishLine` or it sits in the live pane
    /// forever -- the same wedge `failedTranslation` guards against.
    private static func englishRowNeedsNoTranslation() {
        let s = SubtitleStore()
        let u = UUID()
        s.beginLine(utterance: u, source: "Let's ship it on Friday.",
                    provisional: false, language: .en)
        expect("an English row starts live", s.live.count == 1 && s.history.isEmpty)
        s.finishLine(utterance: u)
        expect("an English row graduates with no translation deltas",
               s.live.isEmpty && s.history.count == 1)
        expect("the recognized text is the subtitle, and target stays empty",
               s.history.first?.source == "Let's ship it on Friday."
               && s.history.first?.target.isEmpty == true
               && s.history.first?.language == .en)
    }

    /// Japanese rows are a source line glossed by a translation; English rows
    /// are the subtitle itself. The transcript must not emit an empty
    /// blockquote pair for the latter.
    private static func transcriptDistinguishesTheTwoRowShapes() {
        let s = SubtitleStore()
        let ja = UUID(), en = UUID()
        s.beginLine(utterance: ja, source: "お疲れ様です。", provisional: false)
        s.append(utterance: ja, delta: "Thanks for your hard work.")
        s.finishLine(utterance: ja)
        s.beginLine(utterance: en, source: "Let's ship it on Friday.",
                    provisional: false, language: .en)
        s.finishLine(utterance: en)

        let md = s.transcriptMarkdown
        expect("the Japanese row keeps its quoted source and translation",
               md.contains("> お疲れ様です。") && md.contains("Thanks for your hard work."))
        expect("the English row is one unquoted line",
               md.contains("Let's ship it on Friday.")
               && !md.contains("> Let's ship it on Friday."))
        expect("no empty trailing block is emitted for the English row",
               !md.contains("\n\n\n\n"))
    }

    private static func uniqueRowIDs() {
        let s = SubtitleStore()
        let u = UUID()
        for ja in ["A。", "B。", "C。"] {
            s.beginLine(utterance: u, source: ja, provisional: false)
            s.finishLine(utterance: u)
        }
        expect("row ids are unique", Set(s.history.map(\.id)).count == s.history.count)
        expect("utterance id is retained", s.history.allSatisfy { $0.utterance == u })
    }

    /// A three-hour meeting must not grow without bound.
    private static func historyCap() {
        let s = SubtitleStore()
        for i in 0..<520 {
            let u = UUID()
            s.beginLine(utterance: u, source: "line \(i)", provisional: false)
            s.finishLine(utterance: u)
        }
        expect("history is capped at 500", s.history.count == 500)
        expect("the oldest lines are the ones dropped",
               s.history.first?.source == "line 20")
    }

    /// `history.count` stops moving the moment the cap engages -- which is
    /// exactly the point in a three-hour meeting where following the speaker
    /// matters most. Whatever the panel watches has to keep counting.
    private static func settledCountSurvivesCap() {
        let s = SubtitleStore()
        for i in 0..<520 {
            let u = UUID()
            s.beginLine(utterance: u, source: "line \(i)", provisional: false)
            s.finishLine(utterance: u)
        }
        expect("settledCount counts every graduated row", s.settledCount == 520)
        expect("while history.count has stopped moving", s.history.count == 500)

        let before = s.settledCount
        let u = UUID()
        s.beginLine(utterance: u, source: "one more", provisional: false)
        s.finishLine(utterance: u)
        expect("a row past the cap still moves settledCount", s.settledCount == before + 1)
        expect("and still does not move history.count", s.history.count == 500)
    }

    /// One spoken turn can graduate several sentences in a single `graduate()`
    /// call. Counting calls instead of rows would make the "N new" pill
    /// undercount a fast speaker.
    private static func settledCountCountsRowsNotCalls() {
        let s = SubtitleStore()
        let u = UUID()
        for ja in ["一つ目。", "二つ目。"] {
            s.beginLine(utterance: u, source: ja, provisional: true)
            s.append(utterance: u, delta: "x")
            s.finishLine(utterance: u)
        }
        expect("provisional rows have not settled yet", s.settledCount == 0)
        s.settle(utterance: u)
        expect("both rows counted by one graduate()", s.settledCount == 2)
        expect("and both reached history", s.history.count == 2)
    }

    /// Clear empties the pane, so the counter has to go with it -- otherwise the
    /// pill keeps offering to jump to rows that no longer exist.
    private static func clearResetsSettledCount() {
        let s = SubtitleStore()
        let u = UUID()
        s.beginLine(utterance: u, source: "予算の件です。", provisional: false)
        s.finishLine(utterance: u)
        expect("counted once", s.settledCount == 1)
        s.clear()
        expect("clear resets the counter", s.settledCount == 0)
        expect("clear empties history", s.history.isEmpty)
    }

    /// The saved transcript hangs off `onSettled`, and has to outlive the cap:
    /// every row reported exactly once, in order, and not before it settles.
    private static func onSettledReportsEachRowOnce() {
        let s = SubtitleStore()
        var reported: [SubtitleLine] = []
        s.onSettled = { reported += $0 }

        let turn = UUID()
        s.beginLine(utterance: turn, source: "納期については", provisional: true)
        s.append(utterance: turn, delta: "As for the deadline")
        s.finishLine(utterance: turn)
        expect("a provisional row is not reported", reported.isEmpty)
        s.beginLine(utterance: turn, source: "納期については来月まで。", provisional: false)
        s.append(utterance: turn, delta: "The deadline is next month.")
        s.finishLine(utterance: turn)
        expect("only its revision is reported",
               reported.map(\.target) == ["The deadline is next month."])

        for i in 0..<520 {
            let u = UUID()
            s.beginLine(utterance: u, source: "line \(i)", provisional: false)
            s.finishLine(utterance: u)
        }
        expect("every row is reported past the cap", reported.count == 521)
        expect("each exactly once", Set(reported.map(\.id)).count == reported.count)
        expect("in spoken order", reported.last?.source == "line 519")
    }

    /// Qwen rows have no source text, and an empty `> ` quote above every
    /// translation is noise in the copied and saved transcripts alike.
    private static func transcriptOmitsAnEmptySource() {
        let s = SubtitleStore()
        let u = UUID()
        s.beginLine(utterance: u, source: "", provisional: false)
        s.append(utterance: u, delta: "Let's begin.")
        s.finishLine(utterance: u)
        let md = s.transcriptMarkdown
        expect("a row with no source has no quote", !md.contains(">"))
        expect("but keeps its translation", md.contains("Let's begin."))
    }

    // MARK: - History pane follow rule

    private static func geo(_ offset: CGFloat, container: CGFloat, content: CGFloat) -> HistoryGeometry {
        HistoryGeometry(offset: offset, containerHeight: container, contentHeight: content)
    }

    /// Appending a row must not disturb the pin, and must not be "corrected"
    /// out from under the animation that carries it into view.
    private static func scrollRuleFollowsTheSpeaker() {
        // Parked at the bottom, a row lands: content grows, nothing else moves.
        let before = geo(9, container: 151, content: 160)
        let after  = geo(9, container: 151, content: 211)
        expect("an appended row leaves the pin alone",
               HistoryScrollRule.action(from: before, to: after, pinned: true,
                                        userIsScrolling: false, scrollIsIdle: true) == HistoryScrollAction.none)

        // Mid-animation the pane is briefly off-bottom. Snapping here would cut
        // the ease short.
        let midway = geo(30, container: 151, content: 211)
        expect("the follow animation is not cut short",
               HistoryScrollRule.action(from: after, to: midway, pinned: true,
                                        userIsScrolling: false, scrollIsIdle: false) == HistoryScrollAction.none)

        // Arrived.
        let landed = geo(60, container: 151, content: 211)
        expect("landing at the bottom re-arms",
               HistoryScrollRule.action(from: midway, to: landed, pinned: true,
                                        userIsScrolling: false, scrollIsIdle: true) == HistoryScrollAction.pin)
    }

    /// The regression that mattered. The live pane slides away over ~0.18s: the
    /// container grows in one callback and the scroll view settles the offset in
    /// the *next*, where both sizes look steady. Read as geometry alone that
    /// settle is indistinguishable from someone scrolling back, and the pane
    /// used to unpin itself every few seconds without being touched.
    private static func scrollRuleSurvivesTheLivePane() {
        // Live pane appears: container shrinks, newest row drops below the fold.
        let full   = geo(9, container: 195, content: 211)
        let shrunk = geo(9, container: 151, content: 211)
        expect("live pane appearing re-finds the bottom",
               HistoryScrollRule.action(from: full, to: shrunk, pinned: true,
                                        userIsScrolling: false, scrollIsIdle: true) == HistoryScrollAction.snapToBottom)

        // Live pane leaves: container grows...
        let grown = geo(9, container: 160, content: 211)
        expect("live pane leaving re-finds the bottom",
               HistoryScrollRule.action(from: shrunk, to: grown, pinned: true,
                                        userIsScrolling: false, scrollIsIdle: true) == HistoryScrollAction.snapToBottom)

        // ...and the offset settles a frame later, with both sizes steady. This
        // exact step is what used to unpin.
        let settled = geo(6, container: 160, content: 211)
        let verdict = HistoryScrollRule.action(from: grown, to: settled, pinned: true,
                                               userIsScrolling: false, scrollIsIdle: true)
        expect("the settle is not mistaken for a scroll back", verdict != HistoryScrollAction.unpin)
        expect("and the drifted pin is re-asserted", verdict == HistoryScrollAction.snapToBottom)

        // A container change while the user is reading back must not re-pin them.
        expect("a resize does not drag a reader back to the bottom",
               HistoryScrollRule.action(from: shrunk, to: grown, pinned: false,
                                        userIsScrolling: false, scrollIsIdle: true) == HistoryScrollAction.none)
    }

    /// Read-back is load-bearing: it has to switch off when the user scrolls up
    /// and back on when they return, including off a rubber-band overscroll.
    private static func scrollRuleLetsTheUserReadBack() {
        let atBottom = geo(400, container: 200, content: 624)
        let scrolledUp = geo(300, container: 200, content: 624)
        expect("a hand on the trackpad unpins",
               HistoryScrollRule.action(from: atBottom, to: scrolledUp, pinned: true,
                                        userIsScrolling: true, scrollIsIdle: false) == HistoryScrollAction.unpin)

        // Newly settled rows keep arriving while they read; nothing may move.
        let grew = geo(300, container: 200, content: 675)
        expect("rows arriving while reading do not move the viewport",
               HistoryScrollRule.action(from: scrolledUp, to: grew, pinned: false,
                                        userIsScrolling: false, scrollIsIdle: true) == HistoryScrollAction.none)

        // Fling back down: the offset overshoots the end, then bounces *back
        // down* -- a decreasing offset, at the bottom, under the user's hand.
        // Tested before the unpin rule, so it re-arms rather than unpinning.
        let overshot = geo(500, container: 200, content: 675)
        let bounced  = geo(475, container: 200, content: 675)
        expect("a rubber-band bounce re-arms instead of unpinning",
               HistoryScrollRule.action(from: overshot, to: bounced, pinned: false,
                                        userIsScrolling: true, scrollIsIdle: false) == HistoryScrollAction.pin)
    }

    // MARK: -

    private static func expect(_ what: String, _ ok: Bool) {
        print("  \(ok ? "ok  " : "FAIL") \(what)")
        if !ok { failures += 1 }
    }
}
