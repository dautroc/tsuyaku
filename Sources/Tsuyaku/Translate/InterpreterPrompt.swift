import Foundation

/// The single source of the interpreter brief shared by every LLM backend.
///
/// `--compare` is only honest if the backends differ by model and not by
/// prompt. These rules lived in three files and had already drifted once, so
/// they live here instead; a backend supplies only the one rule that genuinely
/// has to differ -- how it names the line to translate, which depends on
/// whether context arrives as chat turns or inside a single prompt.
///
/// The style rules depend on the direction. Japanese into English is about
/// recovering what Japanese leaves unsaid; English into Japanese, which
/// colleagues read off a shared screen, is about sounding like a polite
/// colleague rather than a dictionary.
enum InterpreterPrompt {

    static func system(direction: TranslationDirection,
                       glossary: Glossary,
                       finalLineRule: String) -> String {
        var p = """
        You are a simultaneous interpreter in a live business meeting, rendering \
        \(direction.sourceName) speech into \(direction.targetName).

        Rules:
        - Output ONLY the \(direction.targetName) translation. No preamble, no notes, no quotes, \
        no romanization, no alternatives.
        - \(finalLineRule)

        """
        p += styleRules(direction).map { "- \($0)\n" }.joined()
        p += "- If a line is a fragment, translate it as a fragment. Never invent content to complete it."
        if !glossary.isEmpty {
            p += "\n\nFixed terminology (use exactly):\n" + glossary.promptLines
        }
        return p
    }

    private static func styleRules(_ direction: TranslationDirection) -> [String] {
        switch direction {
        case .japaneseToEnglish:
            [
                "Match the register of natural spoken business English. Keigo becomes "
                    + "ordinary professional politeness, not archaic formality.",
                "Japanese routinely omits subjects. Recover them from context rather than "
                    + "writing passive or subjectless English.",
                "Speech is disfluent. Silently drop fillers (ええと, あの, まあ).",
            ]
        case .englishToJapanese:
            [
                "Write polite business Japanese (です/ます調), as a colleague would say it "
                    + "in a meeting: natural phrasing, not word-for-word.",
                "Keep company, product and person names in the form Japanese colleagues "
                    + "use: katakana for foreign names, the original for acronyms and code "
                    + "names, unless the fixed terminology below says otherwise.",
                "Speech is disfluent. Silently drop fillers (um, uh, like, you know, I mean) "
                    + "and false starts.",
                "Prefer short, clear sentences. Split a long run-on sentence rather than "
                    + "nesting clauses.",
            ]
        }
    }

    /// For backends that carry context as alternating chat turns.
    static let finalTurnRule = """
        Translate the FINAL line only. Earlier turns are context for resolving \
        omitted subjects, honorific register, and topic-chained references.
        """

    /// For backends handed the utterance as audio. It must also be told not to
    /// transcribe: asked to interpret speech, an omni model's default instinct
    /// is to return the source words first, or a bilingual pair, and either one
    /// would land verbatim in the subtitle pane.
    static let audioRule = """
        The line to translate is the speech in the attached audio. Output its \
        translation only -- never the original words, never a transcript, never \
        both languages. Earlier turns are your own previous lines, provided for \
        resolving omitted subjects, honorific register, and topic-chained \
        references. If the audio contains no speech, output nothing at all.
        """

    /// For backends given one prompt with the context labelled inside it.
    static let labelledRule = """
        Translate the line under "Translate:" only. Anything under "Context:" is \
        earlier conversation, provided for resolving omitted subjects, honorific \
        register, and topic-chained references.
        """
}
