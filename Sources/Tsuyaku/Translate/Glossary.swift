import Foundation

/// Fixed source->target terminology (company names, product names, jargon).
/// Fed to the translator's system prompt, and separately to the transcriber's
/// `AnalysisContext.contextualStrings` to bias recognition of the same terms.
struct Glossary: Sendable, Codable {
    var entries: [String: String]

    static let empty = Glossary(entries: [:])
    var isEmpty: Bool { entries.isEmpty }

    /// Source-side terms, for biasing speech recognition.
    var sourceTerms: [String] { Array(entries.keys) }

    var promptLines: String {
        entries.sorted { $0.key < $1.key }
               .map { "- \($0.key) -> \($0.value)" }
               .joined(separator: "\n")
    }

    static func load(from url: URL) -> Glossary {
        guard let data = try? Data(contentsOf: url),
              let g = try? JSONDecoder().decode(Glossary.self, from: data)
        else { return .empty }
        return g
    }
}
