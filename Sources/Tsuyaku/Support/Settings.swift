import Foundation

/// User-facing configuration. Persisted in UserDefaults; the API key lives in
/// the keychain instead.
struct Settings: Sendable {
    var sourceLocale: Locale = Locale(identifier: "ja-JP")
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
        static let bundleIDs = "targetBundleIDs"
        static let maxLatency = "maxLatencySeconds"
        static let contextTurns = "contextTurns"
        static let provider = "translationProvider"
        static let glossary = "glossary"
    }

    static func load() -> Settings {
        let d = UserDefaults.standard
        var s = Settings()
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
        // A provider whose key was removed must not silently degrade.
        if !s.provider.hasKey { s.provider = .apple }
        if let data = d.data(forKey: Key.glossary),
           let g = try? JSONDecoder().decode(Glossary.self, from: data) { s.glossary = g }
        return s
    }

    func save() {
        let d = UserDefaults.standard
        d.set(targetBundleIDs, forKey: Key.bundleIDs)
        d.set(maxLatencySeconds, forKey: Key.maxLatency)
        d.set(contextTurns, forKey: Key.contextTurns)
        d.set(provider.rawValue, forKey: Key.provider)
        if let data = try? JSONEncoder().encode(glossary) { d.set(data, forKey: Key.glossary) }
    }
}
