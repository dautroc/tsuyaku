import Foundation

/// Checks the pure parts of Translate My Voice: the prompt for each direction,
/// the reversed glossary, which backend takes the user's speech, and which
/// rows the caption panel shows. The microphone and the panel are checked by
/// hand -- see `--listen-mic`.
///
/// Run with `Tsuyaku --store-selftest` (via `make test`).
@MainActor
enum VoiceSelfTest {

    private static var failures = 0

    static func run() -> Int {
        failures = 0
        print("\n=== translate my voice self-test ===")
        subtitlePromptIsUnchanged()
        captionPromptIsJapaneseFacing()
        glossaryReverses()
        voiceNeedsATextBackend()
        captionsShowTheNewestTwo()
        directionsNameTheirLanguages()
        return failures
    }

    /// Every existing backend's prompt must come out byte for byte as it did
    /// before directions existed, or `--compare` results stop being
    /// comparable with earlier runs. This is that prompt, as it was.
    private static func subtitlePromptIsUnchanged() {
        let before = """
            You are a simultaneous interpreter in a live business meeting, rendering \
            Japanese speech into English.

            Rules:
            - Output ONLY the English translation. No preamble, no notes, no quotes, \
            no romanization, no alternatives.
            - \(InterpreterPrompt.finalTurnRule)
            - Match the register of natural spoken business English. Keigo becomes \
            ordinary professional politeness, not archaic formality.
            - Japanese routinely omits subjects. Recover them from context rather than \
            writing passive or subjectless English.
            - Speech is disfluent. Silently drop fillers (ええと, あの, まあ).
            - If a line is a fragment, translate it as a fragment. Never invent content \
            to complete it.

            Fixed terminology (use exactly):
            - ラクスル -> Raksul
            """
        let now = InterpreterPrompt.system(direction: .japaneseToEnglish,
                                           glossary: Glossary(entries: ["ラクスル": "Raksul"]),
                                           finalLineRule: InterpreterPrompt.finalTurnRule)
        expect("the Japanese → English prompt is unchanged", now == before)
    }

    private static func captionPromptIsJapaneseFacing() {
        let glossary = Glossary(entries: ["ラクスル": "Raksul"]).reversed
        let p = InterpreterPrompt.system(direction: .englishToJapanese,
                                         glossary: glossary,
                                         finalLineRule: InterpreterPrompt.finalTurnRule)
        expect("English → Japanese says so", p.contains("rendering English speech into Japanese"))
        expect("and asks for polite business Japanese", p.contains("です/ます"))
        expect("and drops English fillers", p.contains("um, uh"))
        expect("with none of the Japanese → English rules",
               !p.contains("Keigo becomes") && !p.contains("ええと"))
        expect("and the glossary facing the same way", p.contains("- Raksul -> ラクスル"))
    }

    private static func glossaryReverses() {
        let g = Glossary(entries: ["見積もり": "quote", "見積": "quote", "ラクスル": "Raksul"])
        expect("the glossary reverses, first sorted term winning a shared English one",
               g.reversed.entries == ["quote": "見積", "Raksul": "ラクスル"])
        expect("an empty glossary reverses to empty", Glossary.empty.reversed.isEmpty)
    }

    private static func voiceNeedsATextBackend() {
        expect("a text backend translates the voice too",
               TranslationProvider.voiceProvider(preferring: .anthropic, usable: []) == .anthropic)
        expect("an audio-only backend hands over to the first keyed text one",
               TranslationProvider.voiceProvider(preferring: .qwenOmni,
                                                 usable: [.opencodeGo, .deepseek, .qwenOmni]) == .deepseek)
        expect("and with none, to on-device NMT",
               TranslationProvider.voiceProvider(preferring: .geminiLive,
                                                 usable: [.geminiLive, .ollama]) == .apple)
    }

    private static func captionsShowTheNewestTwo() {
        let history = ["one", "two", "three"].map { row($0) }
        let live = [row("four")]
        let shown = CaptionRows.visible(history: history, live: live, limit: 2)
        expect("captions show the newest two, the live one last",
               shown.map(\.source) == ["three", "four"])
        expect("and settled rows alone once nothing is live",
               CaptionRows.visible(history: history, live: [], limit: 2).map(\.source) == ["two", "three"])
        expect("and nothing before anything is said",
               CaptionRows.visible(history: [], live: [], limit: 2).isEmpty)
    }

    private static func directionsNameTheirLanguages() {
        let reverse = TranslationDirection.englishToJapanese
        expect("each direction maps to its language pair",
               reverse.sourceLanguage.languageCode?.identifier == "en"
               && reverse.targetLanguage.languageCode?.identifier == "ja"
               && TranslationDirection.japaneseToEnglish.sourceLanguage.languageCode?.identifier == "ja")
    }

    // MARK: -

    private static func row(_ source: String) -> SubtitleLine {
        SubtitleLine(utterance: UUID(), source: source, target: "", language: .en,
                     provisional: false, translationDone: true, failed: false, at: .now)
    }

    private static func expect(_ what: String, _ ok: Bool) {
        print("  \(ok ? "ok  " : "FAIL") \(what)")
        if !ok { failures += 1 }
    }
}
