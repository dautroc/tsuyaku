import Foundation

/// Checks the glossary file's parser. The file is edited by hand, often with a
/// Japanese IME active, so every rule here is about what a person actually
/// types rather than what a program would write.
///
/// Run with `Tsuyaku --store-selftest` (via `make test`).
@MainActor
enum GlossarySelfTest {

    private static var failures = 0

    static func run() -> Int {
        failures = 0
        print("\n=== glossary self-test ===")
        entriesAndComments()
        separatorsAndWhitespace()
        linesThatAreNotEntries()
        starterTextParses()
        targetTermsAreDistinct()
        return failures
    }

    private static func entriesAndComments() {
        let g = Glossary.parse("""
            # company names
            ラクスル = Raksul

              # indented comment
            見積もり = quote
            """)
        expect("comments and blank lines are skipped",
               g.entries == ["ラクスル": "Raksul", "見積もり": "quote"])
    }

    private static func separatorsAndWhitespace() {
        let g = Glossary.parse("""
            ハンコヤ＝Hankoya
            \u{3000}定例会議\u{3000}=\u{3000}weekly sync\u{3000}
            \tノバセル\t=\tNovasell
            式 = a = b
            """)
        expect("full-width ＝ separates, as a Japanese IME types it",
               g.entries["ハンコヤ"] == "Hankoya")
        expect("full-width spaces are trimmed", g.entries["定例会議"] == "weekly sync")
        expect("tabs are trimmed", g.entries["ノバセル"] == "Novasell")
        expect("only the first = separates", g.entries["式"] == "a = b")
    }

    private static func linesThatAreNotEntries() {
        let g = Glossary.parse("""
            no separator here
            = no source
            no target =
            ラクスル = Raksul
            """)
        expect("malformed lines are skipped, not fatal", g.entries == ["ラクスル": "Raksul"])
        expect("an empty file is an empty glossary", Glossary.parse("").isEmpty)
    }

    private static func starterTextParses() {
        expect("the starter file parses to its two examples",
               Glossary.parse(Glossary.starterText).entries == ["ラクスル": "Raksul", "見積もり": "quote"])
    }

    private static func targetTermsAreDistinct() {
        let g = Glossary.parse("""
            見積もり = quote
            見積 = quote
            ラクスル = Raksul
            """)
        expect("target terms are listed once each", g.targetTerms == ["Raksul", "quote"])
    }

    private static func expect(_ what: String, _ ok: Bool) {
        print("  \(ok ? "ok  " : "FAIL") \(what)")
        if !ok { failures += 1 }
    }
}
