import Foundation

/// Checks `FallbackTranslator` and `RetryingAudioTranslator` against scripted
/// backends: when a line is retried, when it goes to the fallback, and that an
/// outage stops costing every line its retries. No network; the delays are
/// milliseconds, so the suite takes about a second.
///
/// Run with `Tsuyaku --store-selftest` (via `make test`).
@MainActor
enum FallbackSelfTest {

    private static var failures = 0

    /// Retries as in the app, minus the waiting.
    private static let fast = RetryPolicy(delays: [.milliseconds(1), .milliseconds(1)])

    static func run() async -> Int {
        failures = 0
        print("\n=== fallback self-test ===")
        await transientFailureIsRetried()
        await fallsBackOnceRetriesRunOut()
        await permanentFailureIsNotRetried()
        await outageSkipsThePrimaryUntilItRecovers()
        await noCircuitWithoutAWorkingFallback()
        await failureAfterTextIsReported()
        await fallbackFailureReportsThePrimary()
        await slowFailureIsNotRetried()
        await cancelDuringBackoffStopsEverything()
        await audioIsRetriedButNeverFallsBack()
        return failures
    }

    private static func transientFailureIsRetried() async {
        let primary = ScriptedTranslator([[.fail("HTTP 529", transient: true)], [.text("Hello.")]])
        let fallback = ScriptedTranslator([[.text("NMT")]])
        let t = FallbackTranslator(primary: primary, fallback: fallback, policy: fast)
        let out = await collect(t.translate("こんにちは。", context: []))
        expect("a transient failure is retried", out == ["text:Hello.", "done"] && primary.calls == 2)
        expect("a retry that works needs no fallback", fallback.calls == 0)
    }

    private static func fallsBackOnceRetriesRunOut() async {
        let primary = ScriptedTranslator([[.fail("HTTP 503", transient: true)]])
        let fallback = ScriptedTranslator([[.text("Hello"), .text(" there.")]])
        let t = FallbackTranslator(primary: primary, fallback: fallback, policy: fast)
        let out = await collect(t.translate("こんにちは。", context: []))
        expect("two retries, then the fallback", primary.calls == 3 && fallback.calls == 1)
        expect("the fallback's text is announced first",
               out == ["fallback:HTTP 503", "text:Hello", "text: there.", "done"])
    }

    private static func permanentFailureIsNotRetried() async {
        let primary = ScriptedTranslator([[.fail("HTTP 401", transient: false)]])
        let fallback = ScriptedTranslator([[.text("NMT")]])
        let t = FallbackTranslator(primary: primary, fallback: fallback, policy: fast)
        let out = await collect(t.translate("こんにちは。", context: []))
        expect("a bad key goes straight to the fallback",
               out == ["fallback:HTTP 401", "text:NMT", "done"] && primary.calls == 1)
        _ = await collect(t.translate("次です。", context: []))
        expect("and the next line still tries the primary", primary.calls == 2)
    }

    private static func outageSkipsThePrimaryUntilItRecovers() async {
        let down: [ScriptedTranslator.Step] = [.fail("HTTP 503", transient: true)]
        let primary = ScriptedTranslator([down, down, down, down, [.text("Back.")]])
        let fallback = ScriptedTranslator([[.text("NMT")]])
        let t = FallbackTranslator(primary: primary, fallback: fallback,
                                   policy: fast, cooldown: .milliseconds(200))

        _ = await collect(t.translate("一。", context: []))
        let skipped = await collect(t.translate("二。", context: []))
        expect("during the cooldown the primary is skipped",
               primary.calls == 3 && skipped == ["fallback:HTTP 503", "text:NMT", "done"])

        try? await Task.sleep(for: .milliseconds(250))
        _ = await collect(t.translate("三。", context: []))
        expect("after it, one probe with no retries", primary.calls == 4 && fallback.calls == 3)

        try? await Task.sleep(for: .milliseconds(250))
        let back = await collect(t.translate("四。", context: []))
        _ = await collect(t.translate("五。", context: []))
        expect("a probe that works closes the circuit",
               back == ["text:Back.", "done"] && primary.calls == 6 && fallback.calls == 3)
    }

    private static func noCircuitWithoutAWorkingFallback() async {
        let primary = ScriptedTranslator([[.fail("HTTP 503", transient: true)]])
        let fallback = ScriptedTranslator([[.fail("model not installed", transient: false)]])
        let t = FallbackTranslator(primary: primary, fallback: fallback, policy: fast)
        _ = await collect(t.translate("一。", context: []))
        _ = await collect(t.translate("二。", context: []))
        expect("with no working fallback, every line tries the primary", primary.calls == 6)
    }

    private static func failureAfterTextIsReported() async {
        let primary = ScriptedTranslator([[.text("As for"), .fail("connection lost", transient: true)]])
        let fallback = ScriptedTranslator([[.text("NMT")]])
        let t = FallbackTranslator(primary: primary, fallback: fallback, policy: fast)
        let out = await collect(t.translate("納期については", context: []))
        expect("a failure after text is reported, not retried",
               out == ["text:As for", "failed:connection lost", "done"]
               && primary.calls == 1 && fallback.calls == 0)
    }

    private static func fallbackFailureReportsThePrimary() async {
        let primary = ScriptedTranslator([[.fail("HTTP 401", transient: false)]])
        let fallback = ScriptedTranslator([[.fail("model not installed", transient: false)]])
        let t = FallbackTranslator(primary: primary, fallback: fallback, policy: fast)
        let out = await collect(t.translate("こんにちは。", context: []))
        expect("if both fail, the primary's error is shown", out == ["failed:HTTP 401", "done"])
    }

    private static func slowFailureIsNotRetried() async {
        let primary = ScriptedTranslator([[.wait(.milliseconds(80)), .fail("timed out", transient: true)]])
        let fallback = ScriptedTranslator([[.text("NMT")]])
        let policy = RetryPolicy(delays: [.milliseconds(1)], budget: .milliseconds(50))
        let t = FallbackTranslator(primary: primary, fallback: fallback, policy: policy)
        let out = await collect(t.translate("こんにちは。", context: []))
        expect("a failure past the budget is not retried",
               primary.calls == 1 && out == ["fallback:timed out", "text:NMT", "done"])
    }

    private static func cancelDuringBackoffStopsEverything() async {
        let primary = ScriptedTranslator([[.fail("HTTP 529", transient: true)]])
        let fallback = ScriptedTranslator([[.text("NMT")]])
        let policy = RetryPolicy(delays: [.seconds(5)], budget: .seconds(10))
        let t = FallbackTranslator(primary: primary, fallback: fallback, policy: policy)
        let started = ContinuousClock.now
        let consumer = Task { await collect(t.translate("こんにちは。", context: [])) }
        try? await Task.sleep(for: .milliseconds(50))
        consumer.cancel()
        _ = await consumer.value
        // The wrapper's task outlives the consumer by a hop; give it one.
        try? await Task.sleep(for: .milliseconds(50))
        expect("Stop during a backoff neither retries nor falls back",
               primary.calls == 1 && fallback.calls == 0
               && started.duration(to: .now) < .seconds(1))
    }

    private static func audioIsRetriedButNeverFallsBack() async {
        let flaky = ScriptedTranslator([[.fail("HTTP 429", transient: true)], [.text("Hi.")]])
        let out = await collect(RetryingAudioTranslator(flaky, policy: fast)
            .translate(audio: Data(), context: []))
        expect("audio is retried", out == ["text:Hi.", "done"] && flaky.calls == 2)

        let broken = ScriptedTranslator([[.fail("HTTP 400", transient: false)]])
        let failed = await collect(RetryingAudioTranslator(broken, policy: fast)
            .translate(audio: Data(), context: []))
        expect("and a bad request fails once", failed == ["failed:HTTP 400", "done"] && broken.calls == 1)
    }

    // MARK: -

    private static func collect(_ stream: AsyncStream<TranslationDelta>) async -> [String] {
        var out: [String] = []
        for await delta in stream {
            switch delta {
            case .text(let t):            out.append("text:\(t)")
            case .failed(let m, _):       out.append("failed:\(m)")
            case .usingFallback(let r):   out.append("fallback:\(r)")
            case .done:                   out.append("done")
            }
        }
        return out
    }

    private static func expect(_ what: String, _ ok: Bool) {
        print("  \(ok ? "ok  " : "FAIL") \(what)")
        if !ok { failures += 1 }
    }
}

/// Plays one script per call, in order, repeating the last. Both a text and
/// an audio backend, so one fake covers both wrappers.
private final class ScriptedTranslator: Translator, AudioTranslator, @unchecked Sendable {

    enum Step: Sendable {
        case text(String)
        case fail(String, transient: Bool)
        case wait(Duration)
    }

    private let lock = NSLock()
    private let scripts: [[Step]]
    private var made = 0

    init(_ scripts: [[Step]]) { self.scripts = scripts }

    var calls: Int { lock.withLock { made } }

    func translate(_ text: String, context: [(source: String, target: String)]) -> AsyncStream<TranslationDelta> {
        play(next())
    }

    func translate(audio: Data, context: [String]) -> AsyncStream<TranslationDelta> {
        play(next())
    }

    private func next() -> [Step] {
        lock.withLock {
            defer { made += 1 }
            return scripts[min(made, scripts.count - 1)]
        }
    }

    private func play(_ script: [Step]) -> AsyncStream<TranslationDelta> {
        AsyncStream { continuation in
            let task = Task {
                for step in script {
                    switch step {
                    case .text(let t):
                        continuation.yield(.text(t))
                    case .fail(let m, let transient):
                        continuation.yield(.failed(m, transient: transient))
                    case .wait(let d):
                        try? await Task.sleep(for: d)
                    }
                }
                continuation.yield(.done)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
