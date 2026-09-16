import Foundation

/// A gate event that has been attributed to a language and cleared to render.
struct DecidedEvent: Sendable, Equatable {
    let language: SpokenLanguage
    let event: SegmentGate.Event
}

/// The decision core: which of the two recognizers is right, per spoken turn.
///
/// Deliberately a plain value type with an injected clock -- no actor, no
/// streams, no `ContinuousClock.now` inside -- so every rule below is
/// reachable from `PickerSelfTest` with no audio and no timing. `LanguagePicker`
/// is the thin actor that owns one of these and wires it to streams.
///
/// The rule that matters most is not in here: **both gates are fed every
/// segment, always.** Suppression happens on gate *events*, never on segments.
/// A `SegmentGate` only advances its sentence watermark when it ingests, so
/// starving the losing gate would leave its watermark stale, and on its next
/// win -- mid engine-utterance, since the two engines do not finalize together
/// -- it would re-emit sentences the user already read in the other language.
struct PickerState: Sendable {

    struct Tuning: Sendable {
        /// japaneseness >= threshold picks Japanese. MEASURE: fit from
        /// `--listen-dual` output rather than trusting this default.
        var threshold = 0.50
        var minContentChars = 6
        /// How much English text counts as "the other engine is clearly hearing
        /// something" when the Japanese engine has produced nothing to score.
        var minSilenceEvidenceChars = 12
        /// Scores this close to the threshold are treated as undecidable.
        var stickyBand = 0.12
        /// OFF until the confidence attribute is shown to separate the two
        /// models on known-language audio. Never promoted above script ratio.
        var useConfidenceTiebreak = false
        var confidenceMargin = 0.10
        /// A winner engine that never finalizes would otherwise wedge the loser
        /// out of the panel permanently.
        var lockTimeout: Duration = .seconds(12)
        var defaultLanguage: SpokenLanguage = .ja
        var weights = LanguageScore.Weights()

        init() {}

        init(_ settings: Settings) {
            self.init()
            threshold = settings.languageThreshold
            useConfidenceTiebreak = settings.confidenceTiebreak
            defaultLanguage = .matching(settings.sourceLocale)
        }
    }

    enum Outcome: Sendable, Equatable {
        case forward(DecidedEvent)
        case drop(SpokenLanguage)
    }

    struct Choice: Sendable, Equatable {
        enum Reason: String, Sendable, Equatable {
            case score, sticky, tooShort, confidence, silence
        }
        let language: SpokenLanguage
        /// Japaneseness of the ja recognizer's text. 0.5 means "not enough text".
        let score: Double
        let reason: Reason
    }

    private struct Evidence: Sendable {
        var text = ""
        var confidence: Double?
        /// Cumulative text already attributed to earlier turns. Volatile results
        /// are cumulative per *engine* utterance, which straddles turns.
        var baseline = ""
    }

    let tuning: Tuning

    private(set) var locked: SpokenLanguage?
    private(set) var lockedUtterance: UUID?
    private(set) var lastTurn: SpokenLanguage?

    private var evidence: [SpokenLanguage: Evidence] = [:]
    private var lastForwardAt: ContinuousClock.Instant?

    init(tuning: Tuning = .init()) {
        self.tuning = tuning
        for l in SpokenLanguage.allCases { evidence[l] = Evidence() }
    }

    // MARK: - Evidence

    mutating func observe(_ segment: Segment) {
        var e = evidence[segment.language] ?? Evidence()
        e.text = segment.text
        if let c = segment.confidence { e.confidence = c }
        // A final restarts the engine's cumulative text, so the prefix baseline
        // no longer refers to anything.
        if segment.isFinal { e.baseline = "" }
        evidence[segment.language] = e
    }

    /// Text to score: the part of this engine's cumulative output that belongs
    /// to the current turn. Unlike the gate's watermark, a stale baseline here
    /// degrades gracefully -- a slightly wrong ratio, never duplicated content.
    private func scoredText(_ language: SpokenLanguage) -> String {
        guard let e = evidence[language] else { return "" }
        guard !e.baseline.isEmpty, e.text.hasPrefix(e.baseline) else { return e.text }
        let suffix = String(e.text.dropFirst(e.baseline.count))
        return suffix.count >= tuning.minContentChars ? suffix : e.text
    }

    // MARK: - Decision

    func choose() -> Choice {
        let score = LanguageScore.japaneseness(scoredText(.ja),
                                               minContentChars: tuning.minContentChars,
                                               w: tuning.weights)

        if score == LanguageScore.Weights.unknown {
            // Measured with `--listen-dual`: fed English, the Japanese model
            // may emit *nothing at all* rather than transliterating it. The
            // script ratio cannot see that case -- there is no text to score --
            // but one engine sitting silent while the other produces a full
            // sentence is itself strong, calibration-free evidence.
            // Deliberately `isEmpty` rather than "short": a ja engine that has
            // emitted even a character or two is hearing something, and letting
            // it fall through to the score path costs one more volatile result.
            // Firing on "short" instead misreads a ja engine that is merely a
            // beat behind the en engine as a silent one.
            if scoredText(.ja).isEmpty,
               scoredText(.en).count >= tuning.minSilenceEvidenceChars {
                return Choice(language: .en, score: score, reason: .silence)
            }
            return Choice(language: lastTurn ?? tuning.defaultLanguage,
                          score: score, reason: .tooShort)
        }

        if abs(score - tuning.threshold) < tuning.stickyBand {
            if tuning.useConfidenceTiebreak,
               let cja = evidence[.ja]?.confidence,
               let cen = evidence[.en]?.confidence,
               abs(cja - cen) >= tuning.confidenceMargin {
                return Choice(language: cja > cen ? .ja : .en,
                              score: score, reason: .confidence)
            }
            // A speaker holds the floor, so "same as last turn" is a genuinely
            // strong prior for the short utterances that are undecidable from
            // text alone (はい / yeah / OK).
            return Choice(language: lastTurn ?? tuning.defaultLanguage,
                          score: score, reason: .sticky)
        }

        return Choice(language: score >= tuning.threshold ? .ja : .en,
                      score: score, reason: .score)
    }

    var displayLanguage: SpokenLanguage { locked ?? choose().language }

    // MARK: - Arbitration

    mutating func submit(_ event: SegmentGate.Event,
                         from language: SpokenLanguage,
                         now: ContinuousClock.Instant) -> Outcome {
        switch event {
        case .translate(let id, _, _):
            if locked == nil {
                // The first translatable unit *is* the deadline. No separate
                // "wait 1.5s before deciding" timer is needed or wanted.
                locked = choose().language
                lastForwardAt = now
            }
            guard locked == language else { return .drop(language) }
            if lockedUtterance == nil { lockedUtterance = id }
            lastForwardAt = now
            return .forward(DecidedEvent(language: language, event: event))

        case .settled(let id):
            // The loser's engine finalizing is not this turn ending.
            guard locked == language else { return .drop(language) }
            guard lockedUtterance == nil || lockedUtterance == id else { return .drop(language) }
            let decided = DecidedEvent(language: language, event: event)
            endTurn()
            return .forward(decided)
        }
    }

    /// Returns true when the safety valve fired.
    mutating func tick(now: ContinuousClock.Instant) -> Bool {
        guard locked != nil, let last = lastForwardAt, now - last >= tuning.lockTimeout else {
            return false
        }
        endTurn()
        return true
    }

    private mutating func endTurn() {
        lastTurn = locked
        locked = nil
        lockedUtterance = nil
        lastForwardAt = nil
        // Everything heard so far belongs to the turn just ended.
        for l in SpokenLanguage.allCases {
            guard var e = evidence[l] else { continue }
            e.baseline = e.text
            evidence[l] = e
        }
    }
}

/// Stream plumbing around `PickerState`. Follows `SegmentGate`'s continuation
/// idiom exactly, which is already proven under strict concurrency here.
actor LanguagePicker {

    /// Cleared events, in order. Unbounded for the same reason the gate's
    /// `events` is: dropping one loses a line of the meeting permanently.
    let decided: AsyncStream<DecidedEvent>
    private let emit: @Sendable (DecidedEvent) -> Void

    /// The live "still hearing" row. Unlike `decided` this may flip language
    /// freely -- it is uncommitted, so showing the currently-leading engine's
    /// tail costs nothing if the lock later goes the other way.
    let hearing: AsyncStream<String>
    private let emitHearing: @Sendable (String) -> Void

    private var state: PickerState

    init(tuning: PickerState.Tuning = .init()) {
        self.state = PickerState(tuning: tuning)

        var d: AsyncStream<DecidedEvent>.Continuation!
        self.decided = AsyncStream(bufferingPolicy: .unbounded) { d = $0 }
        let dCont = d!
        self.emit = { dCont.yield($0) }

        var h: AsyncStream<String>.Continuation!
        self.hearing = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { h = $0 }
        let hCont = h!
        self.emitHearing = { hCont.yield($0) }
    }

    func observe(_ segment: Segment) {
        state.observe(segment)
    }

    func submit(_ event: SegmentGate.Event, from language: SpokenLanguage) {
        if case .forward(let decided) = state.submit(event, from: language, now: .now) {
            emit(decided)
        }
    }

    func hearing(_ text: String, from language: SpokenLanguage) {
        guard language == state.displayLanguage else { return }
        emitHearing(text)
    }

    func tick() {
        _ = state.tick(now: .now)
    }

    var snapshot: (locked: SpokenLanguage?, lastTurn: SpokenLanguage?) {
        (state.locked, state.lastTurn)
    }
}
