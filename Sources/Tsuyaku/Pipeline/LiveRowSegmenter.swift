import Foundation

/// Turns a live session's two interleaved text streams into subtitle rows.
///
/// The live path has no `SegmentGate`: the server hears and translates on its
/// own schedule, and what comes back is a source transcript and a translation
/// arriving independently, each in fragments of a few words. The translate
/// model sends no turn boundaries at all -- no `turnComplete`, no
/// `generationComplete` (measured with `--gemini-test`) -- so rows are cut
/// from the text itself:
///
///   - **One row per sentence.** The translation is cut at every sentence end,
///     mid-fragment if need be, which is the row shape the recognizer paths
///     produce too. Output that stops without one closes after `idleClose`.
///   - **Source joins the row being translated.** The transcript leads the
///     translation by a fraction of a second, so source heard while a row is
///     open is attributed to it, and source heard between rows waits on the
///     "still hearing" line for the next. This is by arrival time, so a row's
///     Japanese can run a few words into the next sentence. The English is
///     never affected.
///   - **English rows are the echo.** With `echoTargetLanguage` the model
///     repeats English speech back as its output, about a second behind.
///     That output is cut at the same sentence ends, so it -- not the
///     transcript running ahead of it -- is the row's text.
///
/// A plain value type with an injected clock, like `PickerState`, so every
/// rule is reachable from `LiveSelfTest` with no network and no timing.
struct LiveRowSegmenter: Sendable {

    struct Tuning: Sendable {
        /// Output silence that closes a row with no sentence end. Longer than
        /// the gaps inside one sentence: the server sends a fragment about
        /// once a second, and a pause mid-sentence stretches that.
        var idleClose: Duration = .milliseconds(2500)
        /// Source nothing is ever rendered for -- English with echo off, or a
        /// noise the recognizer took for speech -- is dropped after this long.
        var staleSource: Duration = .seconds(6)
        /// japaneseness >= this reads as source language, for fragments that
        /// arrive without a language code.
        var threshold = 0.50
    }

    /// What to do to the store. See `SubtitleStore.apply`.
    enum Op: Sendable, Equatable {
        case hearing(String)
        case begin(UUID, SpokenLanguage)
        case source(UUID, String)
        case target(UUID, String)
        case finish(UUID)
    }

    private struct Row {
        let id: UUID
        let language: SpokenLanguage
        var lastActivity: ContinuousClock.Instant
        /// The row's output so far, for finding its sentence end.
        var output: String
    }

    let tuning: Tuning
    private var row: Row?
    /// Source heard ahead of the row it belongs to.
    private var pending = ""
    private var pendingLanguage: SpokenLanguage?
    private var pendingAt: ContinuousClock.Instant?
    /// The language of the latest source fragment that had one. Outlives
    /// `pending`: an English row consumes no pending text, and the row after
    /// it still has to know it is English.
    private var heardLanguage: SpokenLanguage?

    init(tuning: Tuning = Tuning()) {
        self.tuning = tuning
    }

    mutating func ingest(_ delta: LiveDelta, now: ContinuousClock.Instant) -> [Op] {
        switch delta {
        case .source(let text, let code):  heard(text, code: code, now: now)
        case .target(let text, _):         rendered(text, now: now)
        case .turnEnd:                     close()
        case .reconnecting, .failed:       []
        }
    }

    /// Closes a row that has gone quiet, and drops source nothing answered.
    mutating func tick(now: ContinuousClock.Instant) -> [Op] {
        var ops: [Op] = []
        if let open = row, now - open.lastActivity >= tuning.idleClose {
            ops += close()
        }
        if let at = pendingAt, now - at >= tuning.staleSource {
            clearPending()
            ops.append(.hearing(""))
        }
        return ops
    }

    /// Ends everything in flight, for when the session stops or fails. A row
    /// left open would sit in the live pane forever.
    mutating func flush() -> [Op] {
        var ops = close()
        if !pending.isEmpty { ops.append(.hearing("")) }
        clearPending()
        heardLanguage = nil
        return ops
    }

    // MARK: -

    private mutating func heard(_ text: String, code: String?,
                                now: ContinuousClock.Instant) -> [Op] {
        // Scored on the fragment alone: judged against everything heard so
        // far, a switch would be outvoted by the language being switched from.
        let language = Self.language(code: code, text: text, threshold: tuning.threshold)
        if let language { heardLanguage = language }
        let spoken = language ?? heardLanguage ?? .ja

        if let open = row, open.language == spoken {
            // A translated row takes its source as it is heard. An English
            // row takes nothing: its echo will carry these same words.
            return open.language == .en ? [] : [.source(open.id, text)]
        }

        // Heard ahead of its own row -- nothing is being rendered, or the
        // open row is in the other language and still finishing. The open row
        // is left alone: its translation usually has a few words to go.
        if let language, let previous = pendingLanguage, language != previous {
            pending = ""
        }
        pending += text
        pendingLanguage = language ?? pendingLanguage
        pendingAt = now
        return [.hearing(pending)]
    }

    private mutating func rendered(_ text: String, now: ContinuousClock.Instant) -> [Op] {
        var ops: [Op] = []
        var rest = Substring(text)
        while !rest.isEmpty {
            if row == nil {
                // Fragments often lead with the space after the previous
                // sentence; that alone opens nothing, and never starts a row.
                rest = rest.drop(while: \.isWhitespace)
                guard !rest.isEmpty else { break }
                ops += open(now: now)
            }
            guard var open = row else { break }

            let end = Self.sentenceEnd(after: open.output, in: rest)
            let head = end.map { rest[..<$0] } ?? rest
            rest = end.map { rest[$0...] } ?? ""

            open.output += head
            open.lastActivity = now
            row = open
            if !head.isEmpty {
                // An English row is shown verbatim, and verbatim text lives in
                // `source` -- the same row shape the recognizer paths use.
                ops.append(open.language == .en ? .source(open.id, String(head))
                                                : .target(open.id, String(head)))
            }
            if end != nil { ops += close() }
        }
        return ops
    }

    private mutating func open(now: ContinuousClock.Instant) -> [Op] {
        let id = UUID()
        // Output with nothing heard before it is still a translation, so it
        // renders as one.
        let language = (pending.isEmpty ? nil : pendingLanguage) ?? heardLanguage ?? .ja
        row = Row(id: id, language: language, lastActivity: now, output: "")
        var ops: [Op] = [.begin(id, language)]
        if !pending.isEmpty {
            ops.append(.hearing(""))
            if language != .en { ops.append(.source(id, pending)) }
        }
        clearPending()
        return ops
    }

    private mutating func close() -> [Op] {
        guard let open = row else { return [] }
        row = nil
        return [.finish(open.id)]
    }

    private mutating func clearPending() {
        pending = ""
        pendingLanguage = nil
        pendingAt = nil
    }

    /// Where in `rest` the row's first sentence ends, judged with the row's
    /// output so far in front of it -- an abbreviation can straddle two
    /// fragments.
    private static func sentenceEnd(after prefix: String, in rest: Substring) -> Substring.Index? {
        let english = GateConfig.english
        let combined = prefix + rest
        guard let end = SentenceSplitter.firstEnd(in: combined,
                                                  terminators: english.terminators,
                                                  abbreviations: english.abbreviations)
        else { return nil }
        let offset = combined.distance(from: combined.startIndex, to: end) - prefix.count
        return rest.index(rest.startIndex, offsetBy: min(max(offset, 0), rest.count))
    }

    /// `.ja` here means "not English, so translated" -- the translate model
    /// accepts any of its source languages, and a row only needs to know
    /// whether it renders as source plus translation or verbatim.
    static func language(code: String?, text: String, threshold: Double) -> SpokenLanguage? {
        if let code, !code.isEmpty, code.lowercased() != "und" {
            return code.lowercased().hasPrefix("en") ? .en : .ja
        }
        let score = LanguageScore.japaneseness(text)
        guard score != LanguageScore.Weights.unknown else { return nil }
        return score >= threshold ? .ja : .en
    }
}

extension SubtitleStore {
    /// Applies what `LiveRowSegmenter` decided. Here rather than in the
    /// pipeline so `LiveSelfTest` can drive a real store with it.
    func apply(_ ops: [LiveRowSegmenter.Op]) {
        for op in ops {
            switch op {
            case .hearing(let text):
                hearing = text
            case .begin(let id, let language):
                activeLanguage = language
                // Never provisional: nothing will come back to revise it.
                beginLine(utterance: id, source: "", provisional: false, language: language)
            case .source(let id, let text):
                appendSource(utterance: id, delta: text)
            case .target(let id, let text):
                append(utterance: id, delta: text)
            case .finish(let id):
                finishLine(utterance: id)
            }
        }
    }
}
