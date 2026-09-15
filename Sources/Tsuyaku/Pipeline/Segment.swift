import Foundation
import CoreMedia
import AVFoundation

/// One unit of recognized speech flowing through the pipeline.
struct Segment: Sendable, Identifiable {
    let id: UUID
    /// Source-language text.
    let text: String
    /// `false` means this is a live hypothesis that will be revised.
    /// Only finalized segments are worth spending a translation call on.
    let isFinal: Bool
    let range: CMTimeRange
    /// Mach host time when this text became available, for latency measurement.
    let hostTime: UInt64

    init(id: UUID = UUID(), text: String, isFinal: Bool, range: CMTimeRange, hostTime: UInt64 = mach_absolute_time()) {
        self.id = id
        self.text = text
        self.isFinal = isFinal
        self.range = range
        self.hostTime = hostTime
    }
}

/// A backend that turns captured audio into `Segment`s.
///
/// This protocol exists from day one so the Apple on-device engine can be
/// swapped for a cloud engine (Deepgram et al.) without the rest of the
/// pipeline noticing.
protocol TranscriptionEngine: Actor {
    /// The audio format this engine requires. The capture layer converts to it.
    var inputFormat: AVAudioFormat { get }
    var segments: AsyncStream<Segment> { get }
    func start() async throws
    func feed(_ chunk: AudioChunk) async
    func finish() async
}
