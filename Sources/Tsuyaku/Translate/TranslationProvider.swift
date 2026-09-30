import Foundation

/// Which backend renders the translation.
enum TranslationProvider: String, CaseIterable, Sendable, Codable {
    case apple
    case foundation
    case ollama
    case anthropic
    case deepseek
    case opencodeGo
    case qwenOmni
    case geminiLive

    var displayName: String {
        switch self {
        case .apple:      "Apple on-device (NMT)"
        case .foundation: "Apple on-device LLM"
        case .ollama:     "Ollama (\(OllamaTranslator.defaultModel))"
        case .anthropic:  "Claude (claude-haiku-4-5)"
        case .deepseek:   "DeepSeek (deepseek-flash)"
        case .opencodeGo: "OpenCode Go (\(Settings.opencodeModel))"
        case .qwenOmni:   "Qwen Omni (speech \u{2192} English, cloud)"
        case .geminiLive: "Gemini Live Translate (speech \u{2192} English, cloud)"
        }
    }

    /// For the panel header, which has room for a word or two, not a model ID.
    var shortName: String {
        switch self {
        case .apple:      "Apple NMT"
        case .foundation: "Apple LLM"
        case .ollama:     "Ollama"
        case .anthropic:  "Claude"
        case .deepseek:   "DeepSeek"
        case .opencodeGo: "OpenCode Go"
        case .qwenOmni:   "Qwen Omni"
        case .geminiLive: "Gemini"
        }
    }

    /// Keychain account holding this provider's key, or nil if it needs none.
    var keychainAccount: String? {
        switch self {
        case .apple, .foundation, .ollama: nil
        case .anthropic:          "anthropic"
        case .deepseek:           "deepseek"
        case .opencodeGo:         "opencodeGo"
        case .qwenOmni:           "dashscope"
        case .geminiLive:         "gemini"
        }
    }

    var needsKey: Bool { keychainAccount != nil }

    var hasKey: Bool {
        guard let account = keychainAccount else { return true }
        return Keychain.read(account: account) != nil
    }

    /// Why this backend cannot run right now, or nil if it can. A key is not
    /// the only way to be unconfigured: the on-device LLM is gated on Apple
    /// Intelligence being enabled, and Ollama on a server being up, so `hasKey`
    /// alone would report both ready on a machine where every request fails.
    ///
    /// The Ollama branch does blocking network I/O, so this must not be called
    /// on the main actor -- see the note on `makeTranslator`. Callers that
    /// display it (`AppDelegate`, `Settings.load`) already run it detached.
    var unusableReason: String? {
        switch self {
        case .apple:
            return nil
        case .foundation:
            return FoundationModelTranslator.isAvailable
                ? nil
                : FoundationModelTranslator.describe(FoundationModelTranslator.availability)
        case .ollama:
            return OllamaTranslator.probe()
        case .anthropic, .deepseek, .opencodeGo, .qwenOmni, .geminiLive:
            return hasKey ? nil : "no key -- run: --set-key \(rawValue) <key>"
        }
    }

    /// Whether this backend consumes audio rather than recognized text.
    ///
    /// The one bit `PipelineController` needs to decide whether to build a
    /// transcription graph at all. Kept here so adding a second audio-native
    /// backend later is one case, not a search for every `== .qwenOmni`.
    var isAudioNative: Bool { self == .qwenOmni || self == .geminiLive }

    /// Whether this backend holds one streaming session open instead of taking
    /// cut utterances. Only meaningful when `isAudioNative`: it chooses between
    /// the two audio graphs, one with a `VoiceSegmenter` and one without.
    var isLiveStream: Bool { self == .geminiLive }

    /// One probe, not two: `unusableReason` is the single source of truth.
    var isUsable: Bool { unusableReason == nil }

    /// The audio-native counterpart to `makeTranslator`, nil for text backends.
    func makeAudioTranslator(glossary: Glossary) -> (any AudioTranslator)? {
        guard case .qwenOmni = self,
              let key = Keychain.read(account: "dashscope") else { return nil }
        return QwenOmniTranslator(apiKey: key,
                                  model: Settings.omniModel,
                                  glossary: glossary)
    }

    /// The streaming counterpart to `makeAudioTranslator`, nil for every other
    /// backend. Takes no glossary: the translate model accepts no instructions.
    func makeLiveTranslator(echoEnglish: Bool) -> (any LiveTranslator)? {
        guard case .geminiLive = self,
              let key = Keychain.read(account: "gemini") else { return nil }
        return GeminiLiveTranslator(apiKey: key,
                                    model: Settings.geminiModel,
                                    echoTargetLanguage: echoEnglish)
    }

    /// Builds the backend, degrading to on-device NMT when the backend is
    /// configured but unreachable, so a lost keychain entry or a disabled Apple
    /// Intelligence means "works, more literal" rather than "silently
    /// translates nothing".
    ///
    /// Deliberately does NOT consult `isUsable`: `PipelineController` is
    /// `@MainActor`, so an Ollama probe here would block the main thread for up
    /// to two seconds while the panel sits empty -- the same failure the
    /// keychain read caused before it was moved off the main thread. The cheap
    /// checks stay inline; Ollama's reachability is left to surface as a
    /// `.failed` delta on the first translation, which names the real cause in
    /// the panel instead of pretending the user picked Apple NMT.
    func makeTranslator(glossary: Glossary) -> any Translator {
        switch self {
        case .apple:      return AppleTranslator()
        case .foundation: return FoundationModelTranslator.isAvailable
                                 ? FoundationModelTranslator(glossary: glossary)
                                 : AppleTranslator()
        case .ollama:     return OllamaTranslator(glossary: glossary)
        case .anthropic:
            guard let key = Keychain.read(account: "anthropic") else { return AppleTranslator() }
            return MessagesAPITranslator.anthropic(apiKey: key, glossary: glossary)
        case .deepseek:
            guard let key = Keychain.read(account: "deepseek") else { return AppleTranslator() }
            return MessagesAPITranslator.deepSeek(apiKey: key, glossary: glossary)
        case .opencodeGo:
            guard let key = Keychain.read(account: "opencodeGo") else { return AppleTranslator() }
            return MessagesAPITranslator.opencodeGo(apiKey: key, model: Settings.opencodeModel, glossary: glossary)
        case .qwenOmni, .geminiLive:
            // Unreachable on the audio paths, which never build a `Translator`
            // -- see `isAudioNative`. Reached only if the key vanished between
            // `start()` choosing the branch and this call, and then the honest
            // answer is the same degradation every other backend makes.
            return AppleTranslator()
        }
    }
}
