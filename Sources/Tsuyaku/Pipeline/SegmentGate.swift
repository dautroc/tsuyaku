import Foundation
import OSLog

/// Decides *when* a piece of speech is worth translating.
///
/// This is where the wait-k problem from the SiMT literature lands. Japanese is
/// SOV: the verb -- and with it negation, tense and modality -- arrives last, so
/// translating a partial clause produces English that must be retracted. Cutting
/// only at sentence terminators sidesteps that, because a terminated Japanese
/// sentence is syntactically complete.
///
/// Observed `SpeechTranscriber` behaviour that drives the design:
///   1. Volatile results are CUMULATIVE over the utterance, not deltas.
///   2. The recognizer revises text it has already emitted, so any watermark
///      based on a character count or a prefix string drifts and starts cutting
///      sentences mid-word.
///   3. A whole paragraph can arrive as a single final after 20+ seconds, so
///      waiting for `isFinal` alone leaves the panel frozen.
///
/// So the unit of progress is the *sentence*, not a byte offset: split the
/// cumulative text on terminators and track how many complete sentences have
/// been sent. Re-splitting from scratch every time makes revisions harmless.
actor SegmentGate {

    enum Event: Sendable, Equatable {
        case translate(id: UUID, source: String, provisional: Bool)
        case settled(id: UUID)
    }

    private let log = Logger(subsystem: "com.loind.tsuyaku", category: "gate")
    private static let debug = ProcessInfo.processInfo.environment["TSUYAKU_DEBUG"] != nil

    /// Per-language tuning: backstop latency, terminators, abbreviation guards.
    private let config: GateConfig
    /// How long an unterminated tail may sit before we translate it anyway.
    private var maxLatency: Duration { config.maxLatency }

    /// Count of complete sentences already sent for translation this utterance.
    private var sentSentences = 0
    /// Set when a trailing fragment was force-flushed, so the final doesn't repeat it.
    private var sentTail: String?
    private var tailSince: ContinuousClock.Instant?
    private var currentID = UUID()

    /// Translation work. Unbounded on purpose: dropping one of these loses a
    /// line of the meeting permanently. A slow backend must never cost content.
    let events: AsyncStream<Event>
    private let emit: @Sendable (Event) -> Void

    /// Live source text for the "still hearing" row. A separate stream keeping
    /// only the newest value: these arrive many times a second and only the
    /// latest is rendered, so they are safe -- and necessary -- to drop. Sharing
    /// one bounded stream with `events` let a backend slower than the speaker
    /// evict pending `.translate` events.
    let hearing: AsyncStream<String>
    private let emitHearing: @Sendable (String) -> Void

    init(maxLatency: Duration) {
        var c = GateConfig.japanese
        c.maxLatency = maxLatency
        self.init(config: c)
    }

    init(config: GateConfig = .japanese) {
        self.config = config

        var c: AsyncStream<Event>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .unbounded) { c = $0 }
        let cont = c!
        self.emit = { cont.yield($0) }

        var h: AsyncStream<String>.Continuation!
        self.hearing = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { h = $0 }
        let hCont = h!
        self.emitHearing = { hCont.yield($0) }
    }

    func ingest(_ segment: Segment) {
        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            if segment.isFinal { finishUtterance() }
            return
        }

        let (sentences, tail) = split(text)

        // Any newly-completed sentence is translatable immediately -- no need to
        // wait out maxLatency, which is only a backstop for unterminated tails.
        if sentences.count > sentSentences {
            for s in sentences[sentSentences...] where !s.isEmpty {
                emit(.translate(id: currentID, source: s, provisional: false))
            }
            sentSentences = sentences.count
            sentTail = nil
            tailSince = nil
        }

        if segment.isFinal {
            // Whatever is left over has no terminator but the speaker stopped,
            // so it is as complete as it will ever be.
            if !tail.isEmpty, tail != sentTail {
                emit(.translate(id: currentID, source: tail, provisional: false))
            }
            finishUtterance()
            return
        }

        if tail.isEmpty {
            tailSince = nil
        } else if tailSince == nil {
            tailSince = .now
        }
        emitHearing(tail)
    }

    /// Backstop for a speaker chaining clauses with ~て/~が/~けど for tens of
    /// seconds without ever reaching a terminator.
    func tick() {
        guard let since = tailSince, ContinuousClock.now - since >= maxLatency else { return }
        guard let tail = pendingTail, !tail.isEmpty, tail != sentTail else { return }
        if Self.debug { print("[gate] tail flush \(tail.count)ch") }
        // Genuinely provisional: cut mid-clause, so the verb may not have landed.
        emit(.translate(id: currentID, source: tail, provisional: true))
        sentTail = tail
        tailSince = .now
    }

    private var pendingTail: String?

    private func finishUtterance() {
        emit(.settled(id: currentID))
        sentSentences = 0
        sentTail = nil
        tailSince = nil
        pendingTail = nil
        currentID = UUID()
    }

    /// Splits cumulative text into complete (terminated) sentences plus any
    /// unterminated trailing fragment, and records the tail for `tick`.
    private func split(_ text: String) -> (sentences: [String], tail: String) {
        let result = SentenceSplitter.split(text,
                                            terminators: config.terminators,
                                            abbreviations: config.abbreviations)
        pendingTail = result.tail
        return result
    }
}
