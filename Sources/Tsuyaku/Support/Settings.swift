import Foundation

/// User-facing configuration. Persisted in UserDefaults; the API key lives in
/// the keychain instead.
struct Settings: Sendable {
    var sourceLocale: Locale = Locale(identifier: "ja-JP")
    /// The second recognizer, run concurrently so English turns can be shown
    /// verbatim instead of being transliterated and then "translated".
    var secondaryLocale: Locale = Locale(identifier: "en-US")
    /// Off for the first release: the picker decides what the user reads, and a
    /// Japanese turn rendered as English word salad is worse than a clumsy
    /// translation. Turn on once a real meeting confirms the threshold.
    var autoDetectLanguage: Bool = false
    /// English is shown verbatim, so there is no retraction to protect against
    /// and a much shorter backstop is strictly better latency.
    var englishMaxLatencyMillis: Int = 2500
    /// japaneseness >= this picks Japanese. Fit from `--listen-dual`.
    var languageThreshold: Double = 0.50
    /// Confidence is reported on finals only (measured), so it cannot inform
    /// the early lock. Left off unless a measurement says otherwise.
    var confidenceTiebreak: Bool = false
    /// Empty means tap all system audio except this app.
    var targetBundleIDs: [String] = []
    /// How long a turn may grow without finalizing before the gate flushes the
    /// complete sentences it has.
    var maxLatencySeconds: Int = 7
    /// Number of prior (source, target) pairs sent as translation context.
    var contextTurns: Int = 4
    var provider: TranslationProvider = .apple
    var glossary: Glossary = .empty

    private enum Key {
        static let sourceLocale = "sourceLocale"
        static let secondaryLocale = "secondaryLocale"
        static let autoDetect = "autoDetectLanguage"
        static let englishMaxLatency = "englishMaxLatencyMillis"
        static let languageThreshold = "languageThreshold"
        static let confidenceTiebreak = "confidenceTiebreak"
        static let bundleIDs = "targetBundleIDs"
        static let maxLatency = "maxLatencySeconds"
        static let contextTurns = "contextTurns"
        static let provider = "translationProvider"
        static let glossary = "glossary"
        static let omniModel = "omniModel"
        static let opencodeModel = "opencodeModel"
    }

    /// Which Qwen omni model ID to call. A defaults key rather than a stored
    /// property because it is set once from the CLI and read from
    /// `TranslationProvider`, which has no `Settings` in hand -- and because
    /// Alibaba retires omni model IDs often enough that a wrong one has to be
    /// fixable without a rebuild.
    static var omniModel: String {
        get { UserDefaults.standard.string(forKey: Key.omniModel) ?? QwenOmniTranslator.defaultModel }
        set { UserDefaults.standard.set(newValue, forKey: Key.omniModel) }
    }

    /// Which OpenCode Go model ID to call. Like `omniModel`, this is a
    /// defaults key so the provider menu and CLI can read it without a
    /// `Settings` instance.
    static var opencodeModel: String {
        get { UserDefaults.standard.string(forKey: Key.opencodeModel) ?? "deepseek-v4.1-flash" }
        set { UserDefaults.standard.set(newValue, forKey: Key.opencodeModel) }
    }

    static func load() -> Settings {
        let d = UserDefaults.standard
        var s = Settings()
        // sourceLocale used to be declared but never persisted, so it was a
        // constant in all but name.
        if let id = d.string(forKey: Key.sourceLocale) { s.sourceLocale = Locale(identifier: id) }
        if let id = d.string(forKey: Key.secondaryLocale) { s.secondaryLocale = Locale(identifier: id) }
        if d.object(forKey: Key.autoDetect) != nil { s.autoDetectLanguage = d.bool(forKey: Key.autoDetect) }
        if d.object(forKey: Key.englishMaxLatency) != nil {
            s.englishMaxLatencyMillis = d.integer(forKey: Key.englishMaxLatency)
        }
        if d.object(forKey: Key.languageThreshold) != nil {
            s.languageThreshold = d.double(forKey: Key.languageThreshold)
        }
        if d.object(forKey: Key.confidenceTiebreak) != nil {
            s.confidenceTiebreak = d.bool(forKey: Key.confidenceTiebreak)
        }
        if let ids = d.array(forKey: Key.bundleIDs) as? [String] { s.targetBundleIDs = ids }
        if d.object(forKey: Key.maxLatency) != nil { s.maxLatencySeconds = d.integer(forKey: Key.maxLatency) }
        if d.object(forKey: Key.contextTurns) != nil { s.contextTurns = d.integer(forKey: Key.contextTurns) }
        if let raw = d.string(forKey: Key.provider), let p = TranslationProvider(rawValue: raw) {
            s.provider = p
        } else {
            // First run: prefer a configured cloud backend over the on-device
            // model, which is markedly more literal on business Japanese.
            s.provider = TranslationProvider.allCases.first { $0.needsKey && $0.hasKey } ?? .apple
        }
        // A provider that cannot run must not silently degrade: a removed key,
        // or Apple Intelligence switched off under the on-device LLM.
        if !s.provider.isUsable { s.provider = .apple }
        if let data = d.data(forKey: Key.glossary),
           let g = try? JSONDecoder().decode(Glossary.self, from: data) { s.glossary = g }
        return s
    }

    func save() {
        let d = UserDefaults.standard
        d.set(sourceLocale.identifier(.bcp47), forKey: Key.sourceLocale)
        d.set(secondaryLocale.identifier(.bcp47), forKey: Key.secondaryLocale)
        d.set(autoDetectLanguage, forKey: Key.autoDetect)
        d.set(englishMaxLatencyMillis, forKey: Key.englishMaxLatency)
        d.set(languageThreshold, forKey: Key.languageThreshold)
        d.set(confidenceTiebreak, forKey: Key.confidenceTiebreak)
        d.set(targetBundleIDs, forKey: Key.bundleIDs)
        d.set(maxLatencySeconds, forKey: Key.maxLatency)
        d.set(contextTurns, forKey: Key.contextTurns)
        d.set(provider.rawValue, forKey: Key.provider)
        if let data = try? JSONEncoder().encode(glossary) { d.set(data, forKey: Key.glossary) }
    }
}
