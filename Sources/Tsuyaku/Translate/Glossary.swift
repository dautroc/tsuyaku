import Foundation

/// Fixed source->target terminology (company names, product names, jargon).
/// Fed to the translator's system prompt, and separately to the transcriber's
/// `AnalysisContext.contextualStrings` to bias recognition of the same terms.
struct Glossary: Sendable, Equatable {
    var entries: [String: String]

    static let empty = Glossary(entries: [:])
    var isEmpty: Bool { entries.isEmpty }

    /// Source-side terms, for biasing the Japanese recognizer.
    var sourceTerms: [String] { Array(entries.keys) }

    /// Target-side terms, for biasing the English recognizer when auto-detect
    /// runs one: "Raksul" is as foreign to en-US as ラクスル is familiar to ja-JP.
    var targetTerms: [String] { Array(Set(entries.values)).sorted() }

    var promptLines: String {
        entries.sorted { $0.key < $1.key }
               .map { "- \($0.key) -> \($0.value)" }
               .joined(separator: "\n")
    }

    /// The same terms the other way round, for translating the user's English
    /// into Japanese. The file is written Japanese-first, so two Japanese
    /// terms can share one English one (見積もり and 見積 both = quote); the
    /// first in sorted order wins, so the choice is stable across Starts.
    var reversed: Glossary {
        var flipped: [String: String] = [:]
        for (source, target) in entries.sorted(by: { $0.key < $1.key }) where flipped[target] == nil {
            flipped[target] = source
        }
        return Glossary(entries: flipped)
    }

    // MARK: - The user's file

    /// Read at every Start, so an edit takes effect the next time subtitles
    /// start, with nothing to reload. A missing file is an empty glossary.
    static func loadUser() -> Glossary {
        guard let text = try? String(contentsOf: AppPaths.glossaryFile, encoding: .utf8) else {
            return .empty
        }
        return parse(text)
    }

    /// One `source = target` per line.
    ///
    /// Plain text rather than JSON because this file is edited by hand, and
    /// TextEdit turns typed quotes into curly ones, which is invalid JSON with
    /// no error anyone would see. Full-width `＝` is accepted too: it is what a
    /// Japanese IME types for `=`. Only the first separator splits, so a target
    /// may itself contain one. Lines that are not an entry are skipped rather
    /// than failing the whole file.
    static func parse(_ text: String) -> Glossary {
        var entries: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"),
                  let sep = line.firstIndex(where: { $0 == "=" || $0 == "＝" })
            else { continue }
            let source = line[..<sep].trimmingCharacters(in: .whitespaces)
            let target = line[line.index(after: sep)...].trimmingCharacters(in: .whitespaces)
            guard !source.isEmpty, !target.isEmpty else { continue }
            entries[source] = target
        }
        return Glossary(entries: entries)
    }

    /// Written the first time the user asks to edit the glossary, so the file
    /// explains itself.
    static let starterText = """
        # Tsuyaku glossary: names and terms to always translate the same way.
        #
        # One entry per line:   Japanese = English
        # Lines starting with # are ignored. Changes apply the next time
        # subtitles start.
        #
        # Terms also help speech recognition hear names it would otherwise miss.

        ラクスル = Raksul
        見積もり = quote

        """
}
