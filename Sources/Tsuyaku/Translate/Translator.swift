import Foundation

/// Incremental output of a translation request.
enum TranslationDelta: Sendable {
    case text(String)      // append to the in-progress line
    case done
    /// - Parameter transient: the same request sent again has a fair chance of
    ///   working -- a rate limit, an overloaded server, a dropped connection.
    ///   What `FallbackTranslator` retries; everything else goes straight to
    ///   the fallback.
    case failed(String, transient: Bool = false)
    /// The primary backend failed on this line, and the text that follows
    /// comes from the fallback. Carries the primary's error. Emitted only by
    /// `FallbackTranslator`.
    case usingFallback(String)
}

/// Which way a translator works. Colleagues' Japanese into English for the
/// subtitle panel, or the user's own English into Japanese for the caption
/// panel their colleagues read on the shared screen.
enum TranslationDirection: Sendable, Equatable {
    case japaneseToEnglish
    case englishToJapanese

    /// As the interpreter prompt names them.
    var sourceName: String {
        switch self {
        case .japaneseToEnglish: "Japanese"
        case .englishToJapanese: "English"
        }
    }

    var targetName: String {
        switch self {
        case .japaneseToEnglish: "English"
        case .englishToJapanese: "Japanese"
        }
    }

    /// For Apple's `Translation` framework.
    var sourceLanguage: Locale.Language {
        switch self {
        case .japaneseToEnglish: .init(identifier: "ja")
        case .englishToJapanese: .init(identifier: "en")
        }
    }

    var targetLanguage: Locale.Language {
        switch self {
        case .japaneseToEnglish: .init(identifier: "en")
        case .englishToJapanese: .init(identifier: "ja")
        }
    }
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

/// Which failures are worth sending again, shared by every HTTP backend so
/// they agree on what "transient" means.
enum TransientFailure {

    /// 529 is Anthropic's "overloaded". 501 and 505 are 5xx too, but say the
    /// request itself is wrong, so asking again gets the same answer.
    static func isTransient(status: Int) -> Bool {
        [408, 429, 500, 502, 503, 504, 529].contains(status)
    }

    /// Connection trouble. A timeout counts, although `RetryPolicy`'s budget
    /// means a line that already waited that long goes to the fallback
    /// instead of waiting again.
    static func isTransient(_ error: Error) -> Bool {
        guard let error = error as? URLError else { return false }
        switch error.code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost,
             .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet:
            return true
        default:
            return false
        }
    }
}
