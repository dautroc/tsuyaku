import Foundation
import AVFoundation

/// One converted block of captured audio, handed off from the real-time audio
/// thread to the transcription actor.
///
/// `@unchecked Sendable` is sound here by construction: `FormatConverter`
/// allocates `buffer` fresh for each chunk and drops its reference immediately,
/// so the buffer is written once, on the audio thread, and is immutable from
/// then on. Any number of concurrent readers is therefore fine -- which is what
/// makes the ja/en fan-out in `PipelineController` safe, since both engines are
/// handed the same chunk.
struct AudioChunk: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    /// Mach host time of the first frame, for end-to-end latency measurement.
    let hostTime: UInt64
}
