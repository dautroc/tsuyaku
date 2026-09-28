import Foundation
import AVFoundation
import OSLog

/// Cuts the tap's continuous audio into utterances.
///
/// This is the job `SegmentGate` does in the Apple-STT modes, but it cannot be
/// reused: the gate segments on *sentence* structure in recognized text -- 。,
/// ?, sentence-final particles -- and on the omni path there is no text until
/// after the cut has already been made. So boundaries have to come from the
/// signal, which means energy-based voice activity detection.
///
/// Deliberately not a trained VAD. A meeting tap carries one speaker at a time
/// through a clean digital path with no room noise, so short-term energy
/// against a rolling noise floor separates speech from silence well enough, and
/// it costs no model, no asset download and no inference on the audio thread.
/// Its weakness is non-speech transients -- a door, a notification chime -- and
/// those are handled downstream instead, by the model returning no text.
actor VoiceSegmenter {

    private let log = Logger(subsystem: "com.loind.tsuyaku", category: "vad")

    struct Config: Sendable {
        /// How far above the noise floor a frame must sit to count as speech.
        /// In amplitude ratio, not dB: 3.5x is roughly 11 dB.
        var speechRatio: Double = 3.5
        /// Silence needed to close an utterance. Below ~500 ms this splits
        /// mid-sentence on the natural pauses of Japanese, which produces
        /// fragments the model then has to translate without their predicate.
        var trailingSilence: Duration = .milliseconds(700)
        /// Speech needed before an utterance is opened at all, so a single
        /// loud frame does not start one.
        var minimumSpeech: Duration = .milliseconds(250)
        /// Hard cut for a speaker who never pauses. The same role as the gate's
        /// `maxLatency`: a subtitle that arrives 20 seconds late is not a
        /// subtitle. Also bounds the per-request audio cost.
        var maximumUtterance: Duration = .seconds(12)
        /// Audio kept from before the trigger fired, so the utterance does not
        /// start clipped on its first mora.
        var preroll: Duration = .milliseconds(300)
    }

    private let config: Config
    private let sampleRate: Double

    /// Rolling estimate of the silence level, seeded high so the first frames
    /// of a meeting cannot be mistaken for speech before it has converged.
    private var noiseFloor: Double = 0.02
    private var inSpeech = false
    private var speechDuration: Duration = .zero
    private var silenceDuration: Duration = .zero
    private var utterance: [AVAudioPCMBuffer] = []
    private var preroll: [AVAudioPCMBuffer] = []

    private var continuation: AsyncStream<Utterance>.Continuation?
    let utterances: AsyncStream<Utterance>

    struct Utterance: Sendable {
        /// A UUID rather than a counter, because `SubtitleStore` keys rows by
        /// one -- the same identity the recognizer-driven branches use.
        let id: UUID
        let audio: Data
        let seconds: Double
    }

    init(config: Config = Config(), sampleRate: Double = 16_000) {
        self.config = config
        self.sampleRate = sampleRate
        var c: AsyncStream<Utterance>.Continuation!
        self.utterances = AsyncStream { c = $0 }
        self.continuation = c
    }

    func feed(_ chunk: AudioChunk) {
        let buffer = chunk.buffer
        let frames = Int(buffer.frameLength)
        guard frames > 0, let samples = buffer.int16ChannelData?[0] else { return }

        let span = Duration.seconds(Double(frames) / sampleRate)
        let level = rms(samples, frames)

        if level > noiseFloor * config.speechRatio {
            speechDuration += span
            silenceDuration = .zero
            if !inSpeech && speechDuration >= config.minimumSpeech {
                inSpeech = true
                utterance = preroll          // keep the run-up
                preroll = []
            }
            if inSpeech { utterance.append(buffer) }
        } else {
            // Adapt only on silence: updating the floor while someone is
            // talking would let it climb to the speech level and cut them off
            // mid-sentence.
            noiseFloor = noiseFloor * 0.95 + level * 0.05
            if inSpeech {
                utterance.append(buffer)     // keep the tail, it holds the last mora
                silenceDuration += span
                if silenceDuration >= config.trailingSilence { close() }
            } else {
                speechDuration = .zero
                preroll.append(buffer)
                trimPreroll()
            }
        }

        if inSpeech, WAVEncoder.duration(utterance, sampleRate: sampleRate)
            >= config.maximumUtterance.seconds {
            log.debug("forced cut at maximum utterance length")
            close()
        }
    }

    /// Flushes whatever is buffered. Called when capture stops, so the last
    /// sentence of a meeting is not swallowed.
    func finish() {
        if inSpeech { close() }
        continuation?.finish()
        continuation = nil
    }

    private func close() {
        defer {
            inSpeech = false
            speechDuration = .zero
            silenceDuration = .zero
            utterance = []
            preroll = []
        }
        let seconds = WAVEncoder.duration(utterance, sampleRate: sampleRate)
        guard seconds >= config.minimumSpeech.seconds,
              let audio = WAVEncoder.encode(utterance, sampleRate: sampleRate) else { return }
        continuation?.yield(Utterance(id: UUID(), audio: audio, seconds: seconds))
    }

    private func trimPreroll() {
        let limit = config.preroll.seconds
        while WAVEncoder.duration(preroll, sampleRate: sampleRate) > limit, !preroll.isEmpty {
            preroll.removeFirst()
        }
    }

    /// Root mean square over the frame, normalized to 0...1.
    private func rms(_ samples: UnsafePointer<Int16>, _ count: Int) -> Double {
        var sum = 0.0
        for i in 0..<count {
            let v = Double(samples[i]) / 32768.0
            sum += v * v
        }
        return (sum / Double(count)).squareRoot()
    }
}

private extension Duration {
    /// `Duration` has no seconds accessor; the components are (whole seconds,
    /// attoseconds) and both halves matter for the sub-second values used here.
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
