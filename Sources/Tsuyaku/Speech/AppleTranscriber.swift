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

    nonisolated let segments: AsyncStream<Segment>
    private let emit: @Sendable (Segment) -> Void
    private let close: @Sendable () -> Void

    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    /// Host time of the most recent audio chunk, so a Segment can be dated to
    /// when its audio arrived rather than when the model finished with it.
    private var lastHostTime: UInt64 = 0

    /// - Parameter contextualStrings: attendee names, product names, jargon.
    ///   Biasing the model with these measurably improves Japanese proper-noun
    ///   accuracy and costs nothing at runtime.
    init(locale: Locale, contextualStrings: [String] = []) async throws {
        let transcriber = try await AssetGate.prepare(locale: locale)
        self.transcriber = transcriber

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw AssetGate.AssetError.unsupportedLocale(locale.identifier)
        }
        self.inputFormat = format

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

    func start() async throws {
        var c: AsyncStream<AnalyzerInput>.Continuation!
        let stream = AsyncStream<AnalyzerInput>(bufferingPolicy: .bufferingNewest(64)) { c = $0 }
        inputContinuation = c

        resultsTask = Task { [transcriber, emit] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    guard !text.isEmpty else { continue }
                    emit(Segment(text: text,
                                 isFinal: result.isFinal,
                                 range: result.range,
                                 hostTime: self.currentHostTime()))
                }
            } catch {
                self.log.error("transcriber results ended: \(error.localizedDescription)")
            }
            emit(Segment(text: "", isFinal: true, range: .invalid))
        }

        try await analyzer.start(inputSequence: stream)
        log.info("analyzer started at \(self.inputFormat.sampleRate)Hz")
    }

    private func currentHostTime() -> UInt64 { lastHostTime }

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
