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
    private var transcriber: AppleTranscriber?
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
            let stt = try await AppleTranscriber(locale: settings.sourceLocale,
                                                 contextualStrings: glossary.sourceTerms)
            let tap = SystemAudioTap(bundleIDs: settings.targetBundleIDs,
                                     outputFormat: stt.inputFormat) { [weak self] event in
                // Fires on the tap's own queue when the output device changes.
                Task { @MainActor in self?.handleRecovery(event) }
            }
            let gate = SegmentGate(maxLatency: .seconds(settings.maxLatencySeconds))
            let translator = makeTranslator(glossary: glossary)

            try await stt.start()
            try tap.start()

            self.transcriber = stt
            self.tap = tap

            tasks = [
                Task { for await chunk in tap.buffers { await stt.feed(chunk) } },
                Task { for await seg in stt.segments { await gate.ingest(seg) } },
                Task {
                    // Drives the early-flush timer for turns that never pause.
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(500))
                        await gate.tick()
                    }
                },
                Task { await self.consume(gate.events, using: translator) },
                Task { for await text in gate.hearing { self.store.hearing = text } },
            ]

            store.isRunning = true
            store.status = "Listening"
            log.info("pipeline started")
        } catch {
            log.error("pipeline start failed: \(error.localizedDescription)")
            store.status = "Failed: \(error.localizedDescription)"
            stop()
        }
    }

    func stop() {
        try? tap?.stop()
        tap = nil
        let stt = transcriber
        transcriber = nil
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        Task { await stt?.finish() }
        store.isRunning = false
        store.hearing = ""
        store.status = "Idle"
        store.notice = nil
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

    private func consume(_ events: AsyncStream<SegmentGate.Event>,
                         using translator: any Translator) async {
        for await event in events {
            switch event {
            case .translate(let id, let source, let provisional):
                store.hearing = ""
                store.beginLine(utterance: id, source: source, provisional: provisional)

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
}
