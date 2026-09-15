import Foundation
import AVFoundation
import CoreAudio

/// Converts real-time tap buffers (typically 48 kHz float32 stereo) into the
/// format `SpeechAnalyzer` negotiated (16 kHz mono Int16 on this machine).
///
/// SpeechAnalyzer does no resampling of its own -- feeding it the tap format
/// directly raises `SFSpeechError.unexpectedAudioFormat` -- so this sits
/// directly in the IOProc path and must stay allocation-free per call.
final class FormatConverter: @unchecked Sendable {

    private let converter: AVAudioConverter
    private let sourceFormat: AVAudioFormat
    private let targetFormat: AVAudioFormat

    /// Preallocated. Sized for the largest IO buffer we expect (~4096 frames at
    /// 48 kHz), scaled by the resampling ratio with headroom.
    private let scratch: AVAudioPCMBuffer
    private let maxSourceFrames: AVAudioFrameCount = 8192

    /// `AVAudioConverterInputBlock` is declared `@Sendable`, though the
    /// converter in fact calls it synchronously before `convert` returns.
    /// Handing it a reusable box instead of capturing a local `var` and a
    /// non-Sendable buffer keeps that promise honestly, and allocates nothing
    /// per callback.
    private let slot = InputSlot()

    private final class InputSlot: @unchecked Sendable {
        var buffer: AVAudioPCMBuffer?
        var consumed = false
    }

    init(from source: AVAudioFormat, to target: AVAudioFormat) throws {
        guard let c = AVAudioConverter(from: source, to: target) else {
            throw CA.Err(status: -1, op: "AVAudioConverter(\(source) -> \(target))")
        }
        // Mixing N channels down to mono; the default matrix is what we want.
        c.downmix = true
        self.converter = c
        self.sourceFormat = source
        self.targetFormat = target

        let ratio = target.sampleRate / source.sampleRate
        let capacity = AVAudioFrameCount(Double(maxSourceFrames) * ratio) + 1024
        guard let s = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw CA.Err(status: -1, op: "allocate scratch buffer")
        }
        self.scratch = s
    }

    /// Called on the real-time audio thread.
    /// Returns a freshly-allocated buffer owned by the consumer, or nil if the
    /// input was empty or the conversion failed.
    func convert(_ input: UnsafePointer<AudioBufferList>) -> AVAudioPCMBuffer? {
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = abl.first, first.mDataByteSize > 0 else { return nil }

        let bytesPerFrame = sourceFormat.streamDescription.pointee.mBytesPerFrame
        guard bytesPerFrame > 0 else { return nil }
        let frames = AVAudioFrameCount(first.mDataByteSize / bytesPerFrame)
        guard frames > 0, frames <= maxSourceFrames else { return nil }

        guard let inBuf = AVAudioPCMBuffer(pcmFormat: sourceFormat,
                                           bufferListNoCopy: input,
                                           deallocator: nil) else { return nil }
        inBuf.frameLength = frames

        scratch.frameLength = scratch.frameCapacity
        slot.buffer = inBuf
        slot.consumed = false
        let slot = self.slot
        var error: NSError?
        let status = converter.convert(to: scratch, error: &error) { _, outStatus in
            if slot.consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            slot.consumed = true
            outStatus.pointee = .haveData
            return slot.buffer
        }
        // The wrapper aliases the IOProc's buffer list, which is valid only for
        // the duration of this callback. Never let it outlive the call.
        slot.buffer = nil

        guard status != .error, scratch.frameLength > 0 else { return nil }

        // Hand the consumer its own copy: `scratch` is reused on the next callback.
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat,
                                         frameCapacity: scratch.frameLength) else { return nil }
        out.frameLength = scratch.frameLength
        let bytes = Int(scratch.frameLength) * Int(targetFormat.streamDescription.pointee.mBytesPerFrame)
        if let src = scratch.int16ChannelData?[0], let dst = out.int16ChannelData?[0] {
            memcpy(dst, src, bytes)
        } else if let src = scratch.floatChannelData?[0], let dst = out.floatChannelData?[0] {
            memcpy(dst, src, bytes)
        } else {
            return nil
        }
        return out
    }
}
