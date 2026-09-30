import Foundation
import SwiftUI
import OSLog

/// Owns the live pipeline and drives the view model.
///
///   tap -> transcriber -> gate -> translator -> store
///
/// Each stage is an independent task so a slow translation never stalls capture.
@MainActor
final class PipelineController {

    private let log = Logger(subsystem: "com.loind.tsuyaku", category: "pipeline")
    private let store: SubtitleStore
    private let settings: Settings

    private var tap: SystemAudioTap?
    private var transcribers: [AppleTranscriber] = []
    private var segmenter: VoiceSegmenter?
    /// Row state for the live path. Mutated from two tasks -- the delta
    /// consumer and the idle ticker -- which is safe because both run on the
    /// main actor with this controller.
    private var liveRows = LiveRowSegmenter()
    private var tasks: [Task<Void, Never>] = []

    /// Recent (source, translated) pairs handed to the translator as context.
    private var history: [(source: String, target: String)] = []
    /// Whether the last translated row came from the on-device fallback, so
    /// the user is told once when the backend drops out and once when it is
    /// back -- not on every row in between.
    private var onFallback = false

    init(store: SubtitleStore, settings: Settings = .load()) {
        self.store = store
        self.settings = settings
    }

    func start() async {
        guard !store.isRunning else { return }
        store.status = "Starting…"
        onFallback = false

        do {
            // Re-read at every Start rather than held in `Settings`, so an edit
            // to the file needs nothing more than stopping and starting.
            let glossary = Glossary.loadUser()

            // The audio backends consume audio directly, so they need no
            // transcription graph at all -- and must not build one, since
            // `TranscriberFactory.make` downloads and starts `SpeechAnalyzer`
            // assets that would then sit idle.
            if settings.provider.isAudioNative {
                if settings.provider.isLiveStream {
                    try startLive(glossary: glossary)
                } else {
                    try await startAudioNative(glossary: glossary)
                }
                return
            }

            // Prepared BEFORE the tap exists, because `SystemAudioTap` fixes its
            // output format at init and the device-recovery path reuses it --
            // degrading from two engines to one afterwards would leave the tap
            // driving a format nobody negotiated.
            let prepared = try await TranscriberFactory.make(
                primary: settings.sourceLocale,
                secondary: settings.autoDetectLanguage ? settings.secondaryLocale : nil,
                primaryTerms: glossary.sourceTerms,
                secondaryTerms: glossary.targetTerms
            )

            let tap = SystemAudioTap(bundleIDs: settings.targetBundleIDs,
                                     outputFormat: prepared.inputFormat) { [weak self] event in
                // Fires on the tap's own queue when the output device changes.
                Task { @MainActor in self?.handleRecovery(event) }
            }
            let translator = makeTranslator(glossary: glossary)

            for engine in prepared.engines { try await engine.start() }
            try tap.start()

            self.transcribers = prepared.engines
            self.tap = tap
            store.autoDetecting = prepared.isDual
            store.activeLanguage = nil

            switch prepared {
            case .single(let stt, _):
                let gate = SegmentGate(maxLatency: .seconds(settings.maxLatencySeconds))
                tasks = [
                    Task { for await chunk in tap.buffers { await stt.feed(chunk) } },
                    Task { for await seg in stt.segments { await gate.ingest(seg) } },
                    Task { await self.tickForever { await gate.tick() } },
                    Task { await self.consume(gate.events, language: stt.language, using: translator) },
                    Task { for await text in gate.hearing { self.store.hearing = text } },
                ]

            case .dual(let ja, let en, _):
                var jaConfig = GateConfig.japanese
                jaConfig.maxLatency = .seconds(settings.maxLatencySeconds)
                var enConfig = GateConfig.english
                enConfig.maxLatency = .milliseconds(settings.englishMaxLatencyMillis)

                let jaGate = SegmentGate(config: jaConfig)
                let enGate = SegmentGate(config: enConfig)
                let picker = LanguagePicker(tuning: .init(settings))

                tasks = [
                    // Sequential fan-out, not a broadcast. `feed` only yields
                    // into a bounded stream, so a stalled engine drops its own
                    // oldest buffers instead of starving the other. Sharing one
                    // tap stream also means both engines degrade on the SAME
                    // audio, which is the property arbitration depends on.
                    Task {
                        for await chunk in tap.buffers {
                            await ja.feed(chunk)
                            await en.feed(chunk)
                        }
                    },

                    // Both gates ingest EVERY segment, unconditionally. A gate
                    // only advances its sentence watermark when it ingests, so
                    // starving the losing gate would leave it stale and make it
                    // re-emit already-read sentences on its next win.
                    Task {
                        for await seg in ja.segments {
                            await picker.observe(seg)
                            await jaGate.ingest(seg)
                        }
                    },
                    Task {
                        for await seg in en.segments {
                            await picker.observe(seg)
                            await enGate.ingest(seg)
                        }
                    },

                    Task { for await e in jaGate.events { await picker.submit(e, from: .ja) } },
                    Task { for await e in enGate.events { await picker.submit(e, from: .en) } },
                    Task { for await t in jaGate.hearing { await picker.hearing(t, from: .ja) } },
                    Task { for await t in enGate.hearing { await picker.hearing(t, from: .en) } },

                    Task {
                        await self.tickForever {
                            await jaGate.tick()
                            await enGate.tick()
                            await picker.tick()
                        }
                    },
                    Task { await self.consume(picker.decided, using: translator) },
                    Task { for await text in picker.hearing { self.store.hearing = text } },
                ]
            }

            store.isRunning = true
            store.status = "Listening"
            log.info("pipeline started (\(prepared.isDual ? "ja+en" : "single", privacy: .public))")
        } catch {
            log.error("pipeline start failed: \(error.localizedDescription)")
            store.status = "Failed: \(error.localizedDescription)"
            stop()
        }
    }

    /// Speech straight to the target language, with no recognizer in between.
    ///
    ///   tap -> segmenter (VAD) -> omni -> store
    ///
    /// Three things the Apple-STT branches provide are structurally absent
    /// here and are handled rather than faked:
    ///
    ///   - **No source text.** Nothing transcribes the Japanese, so rows carry
    ///     an empty source and the transcript copy holds English only.
    ///   - **No `hearing` preview.** The partial-result stream that feeds it is
    ///     a recognizer feature; the status line says "Listening" throughout
    ///     instead of flickering text that would never arrive.
    ///   - **No auto-detect.** `LanguagePicker` arbitrates between two
    ///     recognizers, and there are none. The model handles mixed-language
    ///     speech itself, so the setting is simply inert on this path.
    private func startAudioNative(glossary: Glossary) async throws {
        guard let omni = settings.provider.makeAudioTranslator(glossary: glossary) else {
            throw AudioNativeError.noKey(settings.provider)
        }
        let translator = RetryingAudioTranslator(omni)

        // Nobody negotiates a format on this path, so the tap is pinned to what
        // the encoder and the model both want.
        let tap = SystemAudioTap(bundleIDs: settings.targetBundleIDs,
                                 outputFormat: WAVEncoder.captureFormat) { [weak self] event in
            Task { @MainActor in self?.handleRecovery(event) }
        }
        var config = VoiceSegmenter.Config()
        config.maximumUtterance = .seconds(settings.maxLatencySeconds)
        let segmenter = VoiceSegmenter(config: config,
                                       sampleRate: WAVEncoder.captureFormat.sampleRate)

        try tap.start()
        self.tap = tap
        self.segmenter = segmenter
        store.autoDetecting = false
        store.activeLanguage = nil

        tasks = [
            Task { for await chunk in tap.buffers { await segmenter.feed(chunk) } },
            Task { await self.consume(segmenter.utterances, using: translator) },
        ]

        store.isRunning = true
        store.status = "Listening"
        log.info("pipeline started (omni, \(Settings.omniModel, privacy: .public))")
    }

    private func consume(_ utterances: AsyncStream<VoiceSegmenter.Utterance>,
                         using translator: any AudioTranslator) async {
        for await utterance in utterances {
            store.activeLanguage = .ja
            // Source is empty: see the note on `startAudioNative`. `provisional`
            // is false because a VAD cut is final -- unlike a recognizer's
            // hypothesis, it will never be revised.
            store.beginLine(utterance: utterance.id, source: "",
                            provisional: false, language: .ja)

            var accumulated = ""
            for await delta in translator.translate(audio: utterance.audio, context: history.map(\.target)) {
                switch delta {
                case .text(let t):
                    accumulated += t
                    store.append(utterance: utterance.id, delta: t)
                case .failed(let message, _):
                    store.fail(utterance: utterance.id, message: "translation failed: \(message)")
                case .usingFallback, .done:
                    break
                }
            }
            store.finishLine(utterance: utterance.id)
            store.settle(utterance: utterance.id)

            if !accumulated.isEmpty {
                history.append(("", accumulated))
                if history.count > settings.contextTurns {
                    history.removeFirst(history.count - settings.contextTurns)
                }
            }
        }
    }

    /// Speech straight to the target language over one streaming session.
    ///
    ///   tap -> live session -> row segmenter -> store
    ///
    /// No `VoiceSegmenter`: the model translates as it hears and wants the
    /// audio continuously -- silence included, which is also what makes it
    /// finish a sentence. Unlike the omni path the
    /// source transcript does exist here, streamed back by the server, so rows
    /// carry the Japanese and the "hearing" line works.
    ///
    /// "Detect English Automatically" keeps its meaning on this path: it
    /// becomes the model's `echoTargetLanguage`, so English turns come through
    /// verbatim with it on and are skipped with it off. The glossary and
    /// context turns have nowhere to go -- the model accepts no instructions.
    private func startLive(glossary: Glossary) throws {
        let echo = settings.autoDetectLanguage
        guard let translator = settings.provider.makeLiveTranslator(echoEnglish: echo) else {
            throw AudioNativeError.noKey(settings.provider)
        }
        if !glossary.isEmpty {
            log.info("glossary not applied: \(self.settings.provider.rawValue, privacy: .public) takes no instructions")
            // The user wrote those terms expecting them to work; say they don't
            // here, rather than leave them to conclude the file is broken.
            store.flashNotice("Glossary not used: this backend takes no instructions")
        }

        let tap = SystemAudioTap(bundleIDs: settings.targetBundleIDs,
                                 outputFormat: WAVEncoder.captureFormat) { [weak self] event in
            Task { @MainActor in self?.handleRecovery(event) }
        }
        var tuning = LiveRowSegmenter.Tuning()
        tuning.threshold = settings.languageThreshold

        try tap.start()
        self.tap = tap
        liveRows = LiveRowSegmenter(tuning: tuning)
        store.autoDetecting = echo
        store.activeLanguage = nil

        tasks = [
            Task { await self.consume(translator.translate(tap.buffers)) },
            Task { await self.tickForever { await self.tickLive() } },
        ]

        store.isRunning = true
        store.status = "Listening"
        log.info("pipeline started (live, \(Settings.geminiModel, privacy: .public))")
    }

    private func consume(_ deltas: AsyncStream<LiveDelta>) async {
        for await delta in deltas {
            switch delta {
            case .reconnecting:
                // Routine every ten minutes or so, but the handover can leave
                // a gap in the subtitles, and a gap should have a reason.
                store.flashNotice("Reconnecting to Gemini…")
            case .failed(let message):
                store.apply(liveRows.flush())
                // Nothing will retry after this, so the notice is not transient.
                log.error("live session lost: \(message, privacy: .public)")
                store.notice = "Translation lost — stop and start subtitles again"
                store.status = "Translation failed: \(message)"
            default:
                store.apply(liveRows.ingest(delta, now: .now))
            }
        }
    }

    private func tickLive() {
        store.apply(liveRows.tick(now: .now))
    }

    enum AudioNativeError: Error, LocalizedError {
        case noKey(TranslationProvider)
        var errorDescription: String? {
            switch self {
            case .noKey(let provider):
                "no \(provider.displayName) key -- run: --set-key \(provider.rawValue) <key>"
            }
        }
    }

    /// Drives the gates' early-flush timers for turns that never pause.
    private func tickForever(_ body: @Sendable @escaping () async -> Void) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(500))
            await body()
        }
    }

    func stop() {
        try? tap?.stop()
        tap = nil
        let engines = transcribers
        transcribers = []
        let vad = segmenter
        segmenter = nil
        if let vad { Task { await vad.finish() } }
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        // A live row still open would otherwise stay in the live pane for good.
        store.apply(liveRows.flush())
        Task { for e in engines { await e.finish() } }
        store.isRunning = false
        store.hearing = ""
        store.status = "Idle"
        store.notice = nil
        store.activeLanguage = nil
    }

    /// The user switched headphones (or a device dropped out) and the tap
    /// rebuilt itself around the new default output.
    private func handleRecovery(_ event: SystemAudioTap.RecoveryEvent) {
        guard store.isRunning else { return }
        switch event {
        case .rebuilt(let device):
            log.info("capture recovered on \(device, privacy: .public)")
            store.flashNotice("Audio device changed — now capturing \(device)")
        case .failed(let message):
            // Nothing will retry after this, so the notice is not transient.
            log.error("capture unrecoverable: \(message, privacy: .public)")
            store.notice = "Capture lost — stop and start subtitles again"
            store.status = "Capture failed: \(message)"
        }
    }

    /// The provider's translator, backed by on-device NMT for the lines it
    /// cannot translate. Not when it already is on-device NMT -- chosen, or
    /// degraded to because a key is missing -- which has nothing to fall back to.
    private func makeTranslator(glossary: Glossary) -> any Translator {
        let primary = settings.provider.makeTranslator(glossary: glossary)
        if primary is AppleTranslator { return primary }
        return FallbackTranslator(primary: primary, fallback: AppleTranslator())
    }

    /// Single-language mode: every event belongs to `language`.
    private func consume(_ events: AsyncStream<SegmentGate.Event>,
                         language: SpokenLanguage,
                         using translator: any Translator) async {
        for await event in events {
            await handle(event, language: language, using: translator)
        }
    }

    /// Auto-detect mode: the picker has already attributed each event.
    private func consume(_ events: AsyncStream<DecidedEvent>,
                         using translator: any Translator) async {
        for await decided in events {
            await handle(decided.event, language: decided.language, using: translator)
        }
    }

    private func handle(_ event: SegmentGate.Event,
                        language: SpokenLanguage,
                        using translator: any Translator) async {
        switch event {
        case .translate(let id, let source, let provisional):
            store.hearing = ""
            store.activeLanguage = language
            store.beginLine(utterance: id, source: source,
                            provisional: provisional, language: language)

            // English is shown verbatim. An explicit branch rather than a
            // passthrough `Translator` because the row shape differs: the text
            // belongs in ONE field, and a fake translator would copy it into
            // `target` and force every renderer to de-duplicate. It also keeps
            // "no tokens are spent on English" visible at the call site.
            guard language != .en else {
                // Still terminal: a row only leaves the live pane once
                // `translationDone` is set, so skipping this wedges it forever.
                store.finishLine(utterance: id)
                return
            }

            var accumulated = ""
            var servedByFallback = false
            for await delta in translator.translate(source, context: history) {
                switch delta {
                case .text(let t):
                    accumulated += t
                    store.append(utterance: id, delta: t)
                case .failed(let message, _):
                    store.fail(utterance: id, message: "translation failed: \(message)")
                case .usingFallback(let reason):
                    servedByFallback = true
                    if !onFallback {
                        onFallback = true
                        log.error("translating on-device: \(reason, privacy: .public)")
                        store.flashNotice("\(settings.provider.shortName) unavailable — translating on-device")
                    }
                case .done:
                    break
                }
            }
            if onFallback && !servedByFallback && !accumulated.isEmpty {
                onFallback = false
                log.info("\(self.settings.provider.rawValue, privacy: .public) is back")
                store.flashNotice("\(settings.provider.shortName) is back")
            }
            // Terminal for this row: it can now graduate to the history
            // pane, unless the gate still means to revise it.
            store.finishLine(utterance: id)

            // Japanese turns only. An English turn appended here would render
            // as a `user: text` / `assistant: same text` pair in the few-shot
            // window, which is a literal echo demonstration -- a real risk of
            // teaching a small local model to echo Japanese back untranslated.
            if !accumulated.isEmpty {
                history.append((source, accumulated))
                if history.count > settings.contextTurns {
                    history.removeFirst(history.count - settings.contextTurns)
                }
            }

        case .settled(let id):
            store.settle(utterance: id)
            store.hearing = ""
        }
    }
}
