import Foundation
import OSLog

/// Translate My Voice: the user's own English, into Japanese, for the caption
/// panel their colleagues read on the shared screen.
///
///   mic -> transcriber (en-US) -> gate -> translator (en -> ja) -> captions
///
/// The mirror of `PipelineController`'s single-language branch, run alongside
/// it rather than inside it. The two share nothing at runtime -- different
/// audio, recognizer, gate, translator, history and store -- so either can
/// start, stop or fail without touching the other, and toggling this one
/// mid-meeting leaves the subtitles running.
@MainActor
final class VoicePipeline {

    private let log = Logger(subsystem: "com.loind.tsuyaku", category: "voice")
    private let captions: SubtitleStore
    private let provider: TranslationProvider
    private let settings: Settings

    /// Its own, not the store's: the caption store outlives any one pipeline,
    /// and a pipeline being replaced must not stop the one replacing it.
    private var isRunning = false
    private var mic: MicrophoneCapture?
    private var transcriber: AppleTranscriber?
    private var tasks: [Task<Void, Never>] = []
    /// Recent (English, Japanese) pairs handed to the translator as context.
    private var history: [(source: String, target: String)] = []

    /// - Parameter provider: already resolved by
    ///   `TranslationProvider.voiceProvider`, since an audio-only backend
    ///   cannot take the user's text.
    init(captions: SubtitleStore, provider: TranslationProvider, settings: Settings) {
        self.captions = captions
        self.provider = provider
        self.settings = settings
    }

    /// - Returns: why it could not start, or nil once it is listening. The
    ///   caller shows the reason on the subtitle panel, which is the one the
    ///   user is looking at; the caption panel is for the colleagues.
    func start(glossary: Glossary) async -> String? {
        guard !isRunning else { return nil }
        guard await MicrophoneCapture.authorize() else {
            return "Microphone access denied — allow it in System Settings"
        }
        do {
            // The English terms bias recognition: "Raksul" is not a word
            // en-US knows.
            let stt = try await AppleTranscriber(locale: Locale(identifier: "en-US"),
                                                 contextualStrings: glossary.targetTerms)
            let mic = MicrophoneCapture(outputFormat: stt.inputFormat)
            var config = GateConfig.english
            config.maxLatency = .milliseconds(settings.englishMaxLatencyMillis)
            let gate = SegmentGate(config: config)
            let translator = makeTranslator(glossary: glossary.reversed)

            try await stt.start()
            transcriber = stt           // so a failed mic start still finishes it
            try mic.start()
            self.mic = mic
            history = []

            tasks = [
                Task { for await chunk in mic.buffers { await stt.feed(chunk) } },
                Task { for await seg in stt.segments { await gate.ingest(seg) } },
                Task {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(500))
                        await gate.tick()
                    }
                },
                Task { for await event in gate.events { await self.handle(event, using: translator) } },
                Task { for await text in gate.hearing { self.captions.hearing = text } },
            ]
            isRunning = true
            log.info("voice pipeline started (\(self.provider.rawValue, privacy: .public))")
            return nil
        } catch {
            log.error("voice pipeline start failed: \(error.localizedDescription, privacy: .public)")
            stop()
            return "Translate My Voice failed: \(error.localizedDescription)"
        }
    }

    func stop() {
        let wasRunning = isRunning
        isRunning = false
        mic?.stop()
        mic = nil
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        if let stt = transcriber { Task { await stt.finish() } }
        transcriber = nil
        if wasRunning { captions.hearing = "" }
    }

    /// The same shape as the subtitle side: on-device NMT stands in for a
    /// backend that fails, unless NMT already is the backend.
    private func makeTranslator(glossary: Glossary) -> any Translator {
        let primary = provider.makeTranslator(glossary: glossary, direction: .englishToJapanese)
        if primary is AppleTranslator { return primary }
        let nmt = AppleTranslator(source: TranslationDirection.englishToJapanese.sourceLanguage,
                                  target: TranslationDirection.englishToJapanese.targetLanguage)
        return FallbackTranslator(primary: primary, fallback: nmt)
    }

    private func handle(_ event: SegmentGate.Event, using translator: any Translator) async {
        switch event {
        case .translate(let id, let source, let provisional):
            captions.hearing = ""
            captions.beginLine(utterance: id, source: source, provisional: provisional, language: .en)
            var accumulated = ""
            for await delta in translator.translate(source, context: history) {
                switch delta {
                case .text(let t):
                    accumulated += t
                    captions.append(utterance: id, delta: t)
                case .failed(let message, _):
                    // Logged, not shown: colleagues reading the shared screen
                    // gain nothing from an HTTP status. The row keeps the
                    // English, which is still worth reading.
                    log.error("caption translation failed: \(message, privacy: .public)")
                    captions.fail(utterance: id, message: "")
                case .usingFallback(let reason):
                    log.info("captions translating on-device: \(reason, privacy: .public)")
                case .done:
                    break
                }
            }
            captions.finishLine(utterance: id)
            if !accumulated.isEmpty {
                history.append((source, accumulated))
                if history.count > settings.contextTurns {
                    history.removeFirst(history.count - settings.contextTurns)
                }
            }

        case .settled(let id):
            captions.settle(utterance: id)
            captions.hearing = ""
        }
    }
}
