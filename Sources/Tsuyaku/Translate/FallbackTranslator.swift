import Foundation
import OSLog

/// When to send a failed request again.
///
/// A retry is made only while nothing has been shown for the line yet: once
/// text has streamed, sending the request again would append a second
/// translation to the first. And only while the line is young -- a 429 fails
/// in 200 ms and is worth another try, but a request that already waited out
/// a ten-second timeout would only wait again while the meeting moves on.
struct RetryPolicy: Sendable {
    /// One entry per retry, waited before it.
    var delays: [Duration] = [.milliseconds(400), .milliseconds(1200)]
    /// No retry starts later than this after the line's first attempt did.
    var budget: Duration = .seconds(3)

    /// One attempt and no retries.
    static let once = RetryPolicy(delays: [])

    enum Outcome: Equatable {
        /// The last attempt ended without a failure, with or without text.
        case finished
        /// Failed after some text was already emitted. Not retried.
        case failedAfterText(String)
        /// Failed before any text, and no retry is left.
        case failed(String, transient: Bool)
        /// The caller went away. Nothing more should be emitted.
        case cancelled
    }

    /// Runs `attempt` until it finishes or a failure is not worth retrying.
    /// Text is passed to `emit` as it arrives; each attempt's `.failed` and
    /// `.done` are kept back, since only the outcome can say which is final.
    func run(_ attempt: () -> AsyncStream<TranslationDelta>,
             emit: (TranslationDelta) -> Void) async -> Outcome {
        let clock = ContinuousClock()
        let started = clock.now
        var remaining = delays[...]
        while true {
            var failure: (message: String, transient: Bool)?
            var produced = false
            for await delta in attempt() {
                switch delta {
                case .text:
                    produced = true
                    emit(delta)
                case .failed(let message, let transient):
                    failure = (message, transient)
                case .usingFallback:
                    emit(delta)
                case .done:
                    break
                }
            }
            // A cancelled stream just ends, so this is how it looks from here.
            if Task.isCancelled { return .cancelled }
            guard let failure else { return .finished }
            if produced { return .failedAfterText(failure.message) }
            guard failure.transient,
                  let delay = remaining.first,
                  started.duration(to: clock.now) + delay <= budget else {
                return .failed(failure.message, transient: failure.transient)
            }
            remaining = remaining.dropFirst()
            do { try await Task.sleep(for: delay) } catch { return .cancelled }
        }
    }
}

/// A text backend with a fallback: when the primary cannot translate a line,
/// the fallback does, so a rate limit or an outage mid-meeting costs some
/// fluency rather than the sentence.
///
/// Per line: the primary is tried under `policy`, and if it still fails
/// before producing any text, the line goes to the fallback. The fallback's
/// text is preceded by `.usingFallback`, which is how the pipeline knows to
/// tell the user. If the fallback fails too, the *primary's* error is
/// reported -- it is the one the user can do something about.
///
/// A transient failure also opens a circuit for `cooldown`: during an outage
/// every line would otherwise pay for three failed attempts before its
/// fallback, and the subtitles would fall further behind with each one.
/// Lines go straight to the fallback until the cooldown ends, and then one
/// line probes the primary with no retries. The circuit only opens when the
/// fallback actually worked, so on a Mac without the on-device model every
/// line keeps trying the primary.
///
/// A failure that is not transient -- a bad key, a refusal, an empty reply --
/// falls back for that line only. It costs one fast attempt per line, and a
/// refusal says nothing about the next line.
struct FallbackTranslator: Translator {

    private static let log = Logger(subsystem: "com.loind.tsuyaku", category: "fallback")

    let primary: any Translator
    let fallback: any Translator
    let policy: RetryPolicy
    let cooldown: Duration
    private let breaker = Breaker()

    init(primary: any Translator,
         fallback: any Translator,
         policy: RetryPolicy = RetryPolicy(),
         cooldown: Duration = .seconds(30)) {
        self.primary = primary
        self.fallback = fallback
        self.policy = policy
        self.cooldown = cooldown
    }

    func translate(_ text: String, context: [(source: String, target: String)]) -> AsyncStream<TranslationDelta> {
        AsyncStream { continuation in
            let task = Task {
                await run(text, context: context) { continuation.yield($0) }
                continuation.yield(.done)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(_ text: String,
                     context: [(source: String, target: String)],
                     emit: (TranslationDelta) -> Void) async {
        let reason: String
        let transient: Bool
        let triedPrimary: Bool

        switch await breaker.state(now: ContinuousClock.now) {
        case .open(let lastReason):
            (reason, transient, triedPrimary) = (lastReason, true, false)
        case let state:
            let attempts = state == .probing ? RetryPolicy.once : policy
            let outcome = await attempts.run({ primary.translate(text, context: context) }, emit: emit)
            switch outcome {
            case .finished:
                await breaker.reset()
                return
            case .cancelled:
                return
            case .failedAfterText(let message):
                emit(.failed(message))
                return
            case .failed(let message, let isTransient):
                (reason, transient, triedPrimary) = (message, isTransient, true)
            }
        }

        var produced = false
        for await delta in fallback.translate(text, context: context) {
            guard case .text = delta else { continue }
            if !produced { emit(.usingFallback(reason)) }
            produced = true
            emit(delta)
        }
        if Task.isCancelled { return }
        guard produced else {
            emit(.failed(reason, transient: transient))
            return
        }
        if triedPrimary && transient {
            Self.log.info("primary unavailable, using fallback for \(cooldown, privacy: .public): \(reason, privacy: .public)")
            await breaker.trip(until: ContinuousClock.now + cooldown, reason: reason)
        }
    }

    /// Whether the primary is worth trying. Shared by every copy of the
    /// struct, since the pipeline holds the translator by value.
    private actor Breaker {
        enum State: Equatable {
            case closed
            /// Skip the primary; `reason` is why it was last skipped.
            case open(reason: String)
            /// The cooldown is over: try the primary once, no retries.
            case probing
        }

        private var skipUntil: ContinuousClock.Instant?
        private var reason = ""

        func state(now: ContinuousClock.Instant) -> State {
            guard let skipUntil else { return .closed }
            return now < skipUntil ? .open(reason: reason) : .probing
        }

        func trip(until: ContinuousClock.Instant, reason: String) {
            skipUntil = until
            self.reason = reason
        }

        func reset() { skipUntil = nil }
    }
}

/// Retries for an audio backend. No fallback: there is no source text to
/// hand an on-device translator, only the audio.
struct RetryingAudioTranslator: AudioTranslator {

    let inner: any AudioTranslator
    let policy: RetryPolicy

    init(_ inner: any AudioTranslator, policy: RetryPolicy = RetryPolicy()) {
        self.inner = inner
        self.policy = policy
    }

    func translate(audio: Data, context: [String]) -> AsyncStream<TranslationDelta> {
        AsyncStream { continuation in
            let task = Task {
                let outcome = await policy.run({ inner.translate(audio: audio, context: context) }) {
                    continuation.yield($0)
                }
                switch outcome {
                case .failed(let message, let transient):
                    continuation.yield(.failed(message, transient: transient))
                case .failedAfterText(let message):
                    continuation.yield(.failed(message))
                case .finished, .cancelled:
                    break
                }
                continuation.yield(.done)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
