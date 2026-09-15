import Foundation

/// Incremental output of a translation request.
enum TranslationDelta: Sendable {
    case text(String)      // append to the in-progress line
    case done
    case failed(String)
}

/// A backend that translates one finalized source segment.
///
/// Protocol-first so the Claude backend can be swapped for Apple's on-device
/// Translation framework (free, offline, more literal) without touching the
/// pipeline.
protocol Translator: Sendable {
    /// - Parameter context: recent (source, translated) pairs, oldest first.
    ///   This is what resolves dropped Japanese subjects, keigo register, and
    ///   topic-chained pronouns -- the single biggest quality lever.
    func translate(_ text: String, context: [(source: String, target: String)]) -> AsyncStream<TranslationDelta>
}
