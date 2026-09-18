import Foundation
import AVFoundation

/// Wraps captured PCM in a RIFF/WAVE container.
///
/// Qwen-Omni takes audio as a base64 blob with a declared container format, not
/// as raw samples, so the utterance has to carry its own header. WAV rather
/// than a compressed format on purpose: the encoder is twenty lines and
/// allocation-light, where routing through `AVAudioFile` for AAC would mean a
/// temporary file per utterance in the live path. Bandwidth is not the
/// constraint -- at 16 kHz mono Int16 a ten-second turn is 320 KB, and the
/// request is already paying a round trip.
enum WAVEncoder {

    /// The format the omni path fixes the tap to: 16 kHz mono Int16.
    ///
    /// In the Apple-STT modes this format is whatever `SpeechAnalyzer`
    /// negotiated; with no analyzer in the graph there is nobody to negotiate
    /// with, so the omni path pins it here. 16 kHz because speech models are
    /// trained at it and anything higher is paid for twice -- once in upload,
    /// once in audio tokens.
    static let captureFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                             sampleRate: 16_000,
                                             channels: 1,
                                             interleaved: true)!

    /// Concatenates `buffers` into one WAV file.
    /// - Returns: nil if the buffers carry no frames, which the caller should
    ///   treat as "nothing to send" rather than as an error.
    static func encode(_ buffers: [AVAudioPCMBuffer],
                       sampleRate: Double = 16_000) -> Data? {
        var samples = Data()
        for buffer in buffers {
            guard let channel = buffer.int16ChannelData else { continue }
            let count = Int(buffer.frameLength)
            guard count > 0 else { continue }
            samples.append(UnsafeBufferPointer(start: channel[0], count: count))
        }
        guard !samples.isEmpty else { return nil }

        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(sampleRate) * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)

        var out = Data(capacity: samples.count + 44)
        out.append(ascii: "RIFF")
        out.append(le: UInt32(36 + samples.count))     // size of everything after this field
        out.append(ascii: "WAVE")
        out.append(ascii: "fmt ")
        out.append(le: UInt32(16))                      // PCM fmt chunk length
        out.append(le: UInt16(1))                       // format tag: uncompressed PCM
        out.append(le: channels)
        out.append(le: UInt32(sampleRate))
        out.append(le: byteRate)
        out.append(le: blockAlign)
        out.append(le: bitsPerSample)
        out.append(ascii: "data")
        out.append(le: UInt32(samples.count))
        out.append(samples)
        return out
    }

    /// Seconds of audio in a set of buffers, for cost logging and for the
    /// segmenter's maximum-utterance guard.
    static func duration(_ buffers: [AVAudioPCMBuffer], sampleRate: Double = 16_000) -> Double {
        let frames = buffers.reduce(0) { $0 + Int($1.frameLength) }
        return Double(frames) / sampleRate
    }
}

private extension Data {
    mutating func append(ascii text: String) { append(contentsOf: Array(text.utf8)) }

    /// RIFF is little-endian throughout; `withUnsafeBytes` over the
    /// little-endian representation avoids caring about the host's byte order.
    /// Module-qualified because `Data` has an instance method of the same name
    /// that would otherwise shadow the global one inside this extension.
    mutating func append<T: FixedWidthInteger>(le value: T) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }

    mutating func append(_ samples: UnsafeBufferPointer<Int16>) {
        samples.baseAddress.map {
            append(Data(bytes: $0, count: samples.count * MemoryLayout<Int16>.size))
        }
    }
}
