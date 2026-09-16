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
    private var tasks: [Task<Void, Never>] = []

    /// Recent (source, translated) pairs handed to the translator as context.
    private var history: [(source: String, target: String)] = []

    init(store: SubtitleStore, settings: Settings = .load()) {
        self.store = store
        self.settings = settings
    }

    func start() async {
        guard !store.isRunning else { return }
        store.status = "Starting…"

        do {
            let glossary = settings.glossary

            // Prepared BEFORE the tap exists, because `SystemAudioTap` fixes its
            // output format at init and the device-recovery path reuses it --
            // degrading from two engines to one afterwards would leave the tap
            // driving a format nobody negotiated.
            let prepared = try await TranscriberFactory.make(
                primary: settings.sourceLocale,
                secondary: settings.autoDetectLanguage ? settings.secondaryLocale : nil,
                primaryTerms: glossary.sourceTerms
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
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
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

    private func makeTranslator(glossary: Glossary) -> any Translator {
        settings.provider.makeTranslator(glossary: glossary)
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
            for await delta in translator.translate(source, context: history) {
                switch delta {
                case .text(let t):
                    accumulated += t
                    store.append(utterance: id, delta: t)
                case .failed(let message):
                    store.fail(utterance: id, message: "translation failed: \(message)")
                case .done:
                    break
                }
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
