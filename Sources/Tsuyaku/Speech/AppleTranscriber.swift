import Foundation
import Speech
import AVFoundation
import CoreMedia
import OSLog

/// On-device streaming transcription via macOS 26's `SpeechAnalyzer`.
///
/// Chosen over cloud STT because it is free, offline, private, and -- unlike
/// Whisper -- has no autoregressive decoder, so it cannot fall into the
/// hallucination loops that plague local Whisper deployments on silence.
/// `.volatileResults` gives live partial hypotheses for the subtitle UI.
actor AppleTranscriber: TranscriptionEngine {

    private let log = Logger(subsystem: "com.loind.tsuyaku", category: "stt")

    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    nonisolated let inputFormat: AVAudioFormat
    /// Which language this engine is listening for. Two of these run
    /// concurrently over the same audio; the picker arbitrates between them.
    nonisolated let language: SpokenLanguage

    nonisolated let segments: AsyncStream<Segment>
    private let emit: @Sendable (Segment) -> Void
    private let close: @Sendable () -> Void

    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    /// Host time of the most recent audio chunk, so a Segment can be dated to
    /// when its audio arrived rather than when the model finished with it.
    private var lastHostTime: UInt64 = 0

    /// Designated. Takes an already-prepared module and an already-negotiated
    /// format, because when two engines share one audio tap the format must be
    /// negotiated once across both of them rather than per engine.
    ///
    /// - Parameter contextualStrings: attendee names, product names, jargon.
    ///   Biasing the model with these measurably improves Japanese proper-noun
    ///   accuracy and costs nothing at runtime. `AnalysisContext` holds one
    ///   `contextualStrings` map per analyzer, which is why each language needs
    ///   its own analyzer rather than two modules sharing one -- otherwise the
    ///   Japanese glossary would bias the English model.
    init(module: SpeechTranscriber,
         language: SpokenLanguage,
         inputFormat: AVAudioFormat,
         contextualStrings: [String] = []) async throws {
        let transcriber = module
        self.transcriber = transcriber
        self.language = language
        self.inputFormat = inputFormat

        let context = AnalysisContext()
        if !contextualStrings.isEmpty {
            context.contextualStrings = [.general: contextualStrings]
        }

        // .processLifetime: a subtitle app runs for hours; never pay for a
        // mid-meeting model reload. .userInitiated keeps it off background QoS.
        let options = SpeechAnalyzer.Options(priority: .userInitiated,
                                             modelRetention: .processLifetime)

        self.analyzer = SpeechAnalyzer(modules: [transcriber], options: options)

        var c: AsyncStream<Segment>.Continuation!
        self.segments = AsyncStream(bufferingPolicy: .bufferingNewest(256)) { c = $0 }
        let cont = c!
        self.emit = { cont.yield($0) }
        self.close = { cont.finish() }

        try await analyzer.setContext(context)
    }

    /// Single-language convenience: prepares assets and negotiates its own
    /// format. Used by `--listen`, `--capture` and the ja-only fallback.
    init(locale: Locale, contextualStrings: [String] = []) async throws {
        let module = try await AssetGate.prepare(locale: locale)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw AssetGate.AssetError.unsupportedLocale(locale.identifier)
        }
        try await self.init(module: module,
                            language: .matching(locale),
                            inputFormat: format,
                            contextualStrings: contextualStrings)
    }

    func start() async throws {
        var c: AsyncStream<AnalyzerInput>.Continuation!
        let stream = AsyncStream<AnalyzerInput>(bufferingPolicy: .bufferingNewest(64)) { c = $0 }
        inputContinuation = c

        startResultsPump()
        try await analyzer.start(inputSequence: stream)
        log.info("analyzer started at \(self.inputFormat.sampleRate)Hz")
    }

    /// Replays a recording instead of live audio, so a meeting captured once
    /// with `--capture` can be scored against many tunings and give the same
    /// answer every time. Returns when the file has been fully consumed.
    func analyze(file url: URL) async throws {
        startResultsPump()
        let file = try AVAudioFile(forReading: url)
        _ = try await analyzer.analyzeSequence(from: file)
    }

    private func startResultsPump() {
        resultsTask = Task { [transcriber, emit, language] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    guard !text.isEmpty else { continue }
                    emit(Segment(text: text,
                                 isFinal: result.isFinal,
                                 range: result.range,
                                 hostTime: self.currentHostTime(),
                                 language: language,
                                 confidence: Self.meanConfidence(result.text)))
                }
            } catch {
                self.log.error("transcriber results ended: \(error.localizedDescription)")
            }
            emit(Segment(text: "", isFinal: true, range: .invalid, language: language))
        }
    }

    private func currentHostTime() -> UInt64 { lastHostTime }

    /// Character-length-weighted mean of the per-run confidences, or nil when
    /// the model reports none.
    ///
    /// Whether this is populated at all, whether it appears on volatile results
    /// or only on finals, and what its numeric range is are all MEASURED
    /// properties -- the SDK declares `Value = Double` and documents nothing
    /// further. See `--listen-dual`. Never the picker's primary signal.
    nonisolated static func meanConfidence(_ text: AttributedString) -> Double? {
        var weighted = 0.0
        var covered = 0
        for run in text.runs {
            let n = text[run.range].characters.count
            guard let c = run.transcriptionConfidence else { continue }
            weighted += c * Double(n)
            covered += n
        }
        return covered > 0 ? weighted / Double(covered) : nil
    }

    func feed(_ chunk: AudioChunk) {
        lastHostTime = chunk.hostTime
        inputContinuation?.yield(AnalyzerInput(buffer: chunk.buffer))
    }

    func finish() async {
        inputContinuation?.finish()
        inputContinuation = nil
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
        resultsTask?.cancel()
        close()
    }
}
