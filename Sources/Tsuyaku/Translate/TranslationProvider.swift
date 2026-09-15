import Foundation

/// Which backend renders the translation.
enum TranslationProvider: String, CaseIterable, Sendable, Codable {
    case apple
    case anthropic
    case deepseek

    var displayName: String {
        switch self {
        case .apple:     "Apple on-device"
        case .anthropic: "Claude (claude-haiku-4-5)"
        case .deepseek:  "DeepSeek (deepseek-flash)"
        }
    }

    /// Keychain account holding this provider's key, or nil if it needs none.
    var keychainAccount: String? {
        switch self {
        case .apple:     nil
        case .anthropic: "anthropic"
        case .deepseek:  "deepseek"
        }
    }

    var needsKey: Bool { keychainAccount != nil }

    var hasKey: Bool {
        guard let account = keychainAccount else { return true }
        return Keychain.read(account: account) != nil
    }

    /// Builds the backend, falling back to on-device if the key is missing so
    /// a lost keychain entry degrades to "works, more literal" rather than
    /// "silently translates nothing".
    func makeTranslator(glossary: Glossary) -> any Translator {
        guard let account = keychainAccount,
              let key = Keychain.read(account: account) else {
            return AppleTranslator()
        }
        switch self {
        case .apple:     return AppleTranslator()
        case .anthropic: return MessagesAPITranslator.anthropic(apiKey: key, glossary: glossary)
        case .deepseek:  return MessagesAPITranslator.deepSeek(apiKey: key, glossary: glossary)
        }
    }
}
