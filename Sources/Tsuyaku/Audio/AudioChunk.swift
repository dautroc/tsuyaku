import Foundation
import AVFoundation

/// One converted block of captured audio, handed off from the real-time audio
/// thread to the transcription actor.
///
/// `@unchecked Sendable` is sound here by construction: `FormatConverter`
/// allocates `buffer` fresh for each chunk and drops its reference immediately,
/// so exactly one owner exists at any moment. Nothing else aliases it.
struct AudioChunk: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    /// Mach host time of the first frame, for end-to-end latency measurement.
    let hostTime: UInt64
}
