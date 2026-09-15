import Foundation
import Translation
import OSLog

/// Fully on-device translation via Apple's Translation framework.
///
/// Zero cost, zero network, no API key. More literal than an LLM on Japanese
/// business speech -- it has no view of the surrounding conversation, so it
/// cannot recover omitted subjects from context -- but it is free and private.
///
/// macOS 26 is the first release where `TranslationSession` has public
/// initializers; before that a session could only come from a SwiftUI
/// `.translationTask` modifier. `.lowLatency` (26.4+) trades some fidelity for
/// speed, which is the right trade for live subtitles.
///
/// `TranslationSession` is a non-Sendable class whose methods are `nonisolated
/// async`, so it cannot live inside an actor -- every call would "send" it
/// across an isolation boundary. Instead one long-lived worker task owns the
/// session for its whole lifetime and pulls requests off a queue, which also
/// serialises access for free.
final class AppleTranslator: Translator, @unchecked Sendable {

    private struct Job: Sendable {
        let text: String
        let reply: AsyncStream<TranslationDelta>.Continuation
    }

    private let jobs: AsyncStream<Job>
    private let submit: @Sendable (Job) -> Void
    private let worker: Task<Void, Never>

    init(source: Locale.Language = .init(identifier: "ja"),
         target: Locale.Language = .init(identifier: "en")) {

        var c: AsyncStream<Job>.Continuation!
        self.jobs = AsyncStream(bufferingPolicy: .unbounded) { c = $0 }
        let cont = c!
        self.submit = { cont.yield($0) }

        let stream = self.jobs
        self.worker = Task {
            let log = Logger(subsystem: "com.loind.tsuyaku", category: "apple-translate")
            let session: TranslationSession
            if #available(macOS 26.4, *) {
                session = TranslationSession(installedSource: source, target: target,
                                             preferredStrategy: .lowLatency)
            } else {
                // .lowLatency arrived in 26.4; degrade rather than raise the
                // whole app's deployment target.
                session = TranslationSession(installedSource: source, target: target)
            }
            for await job in stream {
                do {
                    let response = try await session.translate(job.text)
                    job.reply.yield(.text(response.targetText))
                    job.reply.yield(.done)
                } catch {
                    log.error("translate failed: \(error.localizedDescription)")
                    job.reply.yield(.failed(error.localizedDescription))
                }
                job.reply.finish()
            }
        }
    }

    deinit { worker.cancel() }

    func translate(_ text: String, context: [(source: String, target: String)]) -> AsyncStream<TranslationDelta> {
        // Context is ignored: this backend has no conversational memory.
        AsyncStream { continuation in
            submit(Job(text: text, reply: continuation))
        }
    }

    /// Reports whether the on-device ja->en model pair is actually usable, and
    /// tries to prepare it. Run this before relying on the backend.
    static func preflight(source: Locale.Language = .init(identifier: "ja"),
                          target: Locale.Language = .init(identifier: "en")) async -> String {
        let availability: LanguageAvailability
        if #available(macOS 26.4, *) {
            availability = LanguageAvailability(preferredStrategy: .lowLatency)
        } else {
            availability = LanguageAvailability()
        }
        let status = await availability.status(from: source, to: target)

        let session: TranslationSession
        if #available(macOS 26.4, *) {
            session = TranslationSession(installedSource: source, target: target,
                                         preferredStrategy: .lowLatency)
        } else {
            session = TranslationSession(installedSource: source, target: target)
        }

        var report = "availability = \(status), canRequestDownloads = \(session.canRequestDownloads)"
        do {
            try await session.prepareTranslation()
            report += ", prepareTranslation = ok"
        } catch {
            report += ", prepareTranslation threw: \(error)"
        }
        do {
            let probe = try await session.translate("テスト")
            report += ", probe translate = \"\(probe.targetText)\""
        } catch {
            report += ", probe translate threw: \(error)"
        }
        return report
    }
}
