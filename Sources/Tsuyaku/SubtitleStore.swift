import Foundation
import SwiftUI

/// One rendered subtitle row.
struct SubtitleLine: Identifiable, Equatable {
    /// Unique per row. Distinct from `utterance`: one spoken turn is often
    /// several sentences, and they all share an utterance id, so using that as
    /// the SwiftUI identity gives `ForEach` duplicate ids and makes
    /// `scrollTo` resolve to the wrong row.
    let id = UUID()
    /// The gate's utterance id. Addresses this row from the pipeline.
    let utterance: UUID
    var source: String
    var target: String
    /// Japanese rows carry source + translation. English rows are shown
    /// verbatim: the recognized text IS the subtitle, so `target` stays empty
    /// and the view renders one line instead of a gloss over a translation.
    var language: SpokenLanguage = .ja
    /// Flushed early because the speaker was still going; may be revised.
    var provisional: Bool
    /// The translation stream for this row has ended (successfully or not).
    var translationDone: Bool
    var failed: Bool
    let at: Date
}

/// The view model behind the floating panel.
///
/// Rows live in one of two panes. A row starts in `live` -- heard, maybe still
/// being translated, still revisable -- and graduates to `history` once its
/// translation has finished and the gate has stopped revising it. Splitting
/// them is what lets the user scroll back through `history` without the live
/// text scrolling away underneath them.
///
/// `ObservableObject` rather than `@Observable`: the `@Observable` macro needs
/// a compiler plugin, and SwiftPM under Command Line Tools has known trouble
/// resolving `CompilerPluginSupport`.
@MainActor
final class SubtitleStore: ObservableObject {

    /// Settled rows, oldest first. The scrollable pane.
    @Published private(set) var history: [SubtitleLine] = []
    /// Rows still in flight. Pinned to the bottom of the panel, never scrolls.
    @Published private(set) var live: [SubtitleLine] = []
    /// Live untranslated source text -- the "still hearing" row.
    @Published var hearing: String = ""
    @Published var isRunning = false
    @Published var status: String = "Idle"
    /// Transient banner in the header: device changes, capture failures.
    /// Distinct from `status`, which the header only shows while stopped.
    @Published var notice: String?

    /// Which language the picker committed to for the turn being rendered, or
    /// nil before the first decision. Drives the header, which doubles as a
    /// live indicator that detection is working -- exactly where a user looks
    /// when they suspect a misdetection.
    @Published var activeLanguage: SpokenLanguage?
    /// Whether two recognizers are actually running. False when the user has
    /// auto-detect off, or when preparing the second locale failed and the
    /// pipeline degraded to Japanese only.
    @Published var autoDetecting: Bool = false

    /// Every row that has ever graduated into `history`, counted. Monotonic,
    /// which `history.count` is not: past `maxLines` rows `graduate()` appends
    /// and trims in the same breath and the count stops moving, so anything
    /// watching it -- the panel's auto-scroll, the "N new" pill -- silently
    /// goes dead for the rest of a long meeting.
    @Published private(set) var settledCount = 0

    /// Cap retained history so a three-hour meeting can't grow without bound.
    private let maxLines = 500

    var hasLiveContent: Bool { !live.isEmpty || !hearing.isEmpty }

    /// - Parameter language: defaults to Japanese so existing call sites, and
    ///   the store self-tests, keep their meaning unchanged.
    func beginLine(utterance: UUID, source: String, provisional: Bool,
                   language: SpokenLanguage = .ja) {
        // The tail backstop can translate an unfinished clause, and the finished
        // sentence then arrives moments later. Replace the provisional row in
        // place so the panel shows one line that firms up, not a near-duplicate.
        if !provisional, let last = live.last, last.utterance == utterance, last.provisional,
           source.hasPrefix(last.source) || last.source.hasPrefix(source) {
            live[live.count - 1] = SubtitleLine(utterance: utterance, source: source, target: "",
                                                language: language,
                                                provisional: false, translationDone: false,
                                                failed: false, at: last.at)
            return
        }
        live.append(SubtitleLine(utterance: utterance, source: source, target: "",
                                 language: language,
                                 provisional: provisional, translationDone: false,
                                 failed: false, at: .now))
    }

    func append(utterance: UUID, delta: String) {
        guard let i = liveIndex(utterance) else { return }
        live[i].target += delta
    }

    func fail(utterance: UUID, message: String) {
        guard let i = liveIndex(utterance) else { return }
        // Never blank a subtitle on a translation failure: the source line is
        // still useful, and the user can see what went wrong.
        live[i].target = message
        live[i].failed = true
    }

    /// The translation stream for this row ended. A row that won't be revised
    /// graduates now; a provisional one waits for `settle`.
    func finishLine(utterance: UUID) {
        guard let i = liveIndex(utterance) else { return }
        live[i].translationDone = true
        graduate()
    }

    func settle(utterance: UUID) {
        for i in live.indices where live[i].utterance == utterance { live[i].provisional = false }
        graduate()
    }

    /// Sentences of one turn share an utterance id but are translated strictly
    /// one at a time, so the newest matching row is always the one in flight.
    private func liveIndex(_ utterance: UUID) -> Int? {
        live.lastIndex { $0.utterance == utterance }
    }

    /// Move finished, non-provisional rows down into the history pane.
    ///
    /// Deliberately not "drain from the front": if a provisional row ever gets
    /// stranded at the head of `live`, taking only the prefix would wedge every
    /// row behind it. Relative order among the rows that do move is preserved.
    private func graduate() {
        let isReady = { (l: SubtitleLine) in l.translationDone && !l.provisional }
        let ready = live.filter(isReady)
        guard !ready.isEmpty else { return }
        live.removeAll(where: isReady)
        history.append(contentsOf: ready)
        // Before the trim, and by rows rather than by call: one spoken turn can
        // graduate several sentences at once.
        settledCount += ready.count
        if history.count > maxLines { history.removeFirst(history.count - maxLines) }
    }

    func clear() {
        history.removeAll()
        live.removeAll()
        hearing = ""
        notice = nil
        // Zero is the signal the panel watches for, to re-arm follow mode and
        // drop a "N new" count of rows that no longer exist.
        settledCount = 0
    }

    /// Show a notice, then take it down. A later flash supersedes an earlier
    /// one rather than having two timers race to clear the same slot.
    private var noticeGeneration = 0
    func flashNotice(_ text: String, for seconds: Double = 4) {
        notice = text
        noticeGeneration &+= 1
        let generation = noticeGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, self.noticeGeneration == generation else { return }
            self.notice = nil
        }
    }

    /// The header label. Japanese-only mode keeps the original string.
    var headerLabel: String {
        if let notice { return notice }
        guard isRunning else { return status }
        guard autoDetecting else { return "JA → EN" }
        switch activeLanguage {
        case .ja?: return "auto · JA → EN"
        case .en?: return "auto · EN"
        case nil:  return "auto · JA → EN / EN"
        }
    }

    var transcriptMarkdown: String {
        var out = "# Meeting transcript\n\n"
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        for l in history + live {
            out += "**\(fmt.string(from: l.at))**\n\n"
            if l.language == .en {
                // Not a blockquote: an English row is the subtitle itself, not
                // a source line being glossed by a translation below it.
                out += "\(l.source)\n\n"
            } else {
                out += "> \(l.source)\n\n"
                out += "\(l.target)\n\n"
            }
        }
        return out
    }
}
