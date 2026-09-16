import Foundation
import Speech
import AVFoundation
import OSLog

/// Builds the recognizer(s) the pipeline will run, and decides -- **before the
/// audio tap exists** -- whether English detection is available at all.
///
/// The ordering matters and is load-bearing: `SystemAudioTap` fixes its
/// `outputFormat` at init and the device-recovery path reuses it, so degrading
/// from two engines to one after the tap has been built would leave the tap
/// driving a format nobody negotiated. Every failure here therefore resolves to
/// `.single`, never to a thrown error: today's Japanese-only behaviour has to
/// survive every failure of the new path.
enum TranscriberFactory {

    private static let log = Logger(subsystem: "com.loind.tsuyaku", category: "stt")

    enum Prepared: Sendable {
        case dual(primary: AppleTranscriber, secondary: AppleTranscriber, format: AVAudioFormat)
        case single(AppleTranscriber, format: AVAudioFormat)

        var inputFormat: AVAudioFormat {
            switch self {
            case .dual(_, _, let f), .single(_, let f): f
            }
        }

        /// Every engine to feed and to finish, in a fixed order so any skew
        /// between them is deterministic.
        var engines: [AppleTranscriber] {
            switch self {
            case .dual(let p, let s, _): [p, s]
            case .single(let e, _): [e]
            }
        }

        var isDual: Bool {
            if case .dual = self { return true }
            return false
        }
    }

    static func make(primary: Locale,
                     secondary: Locale?,
                     primaryTerms: [String] = [],
                     secondaryTerms: [String] = [],
                     onProgress: @Sendable (Progress) -> Void = { _ in }) async throws -> Prepared {

        guard let secondary else { return try await single(primary, primaryTerms) }

        do {
            let prepared = try await AssetGate.prepareAll(locales: [primary, secondary],
                                                          onProgress: onProgress)
            guard prepared.count == 2 else {
                throw AssetGate.AssetError.unsupportedLocale(secondary.identifier)
            }

            guard let format = await sharedFormat(prepared.map(\.module)) else {
                throw AssetGate.AssetError.noSharedFormat(primary.identifier(.bcp47),
                                                          secondary.identifier(.bcp47))
            }

            let p = try await AppleTranscriber(module: prepared[0].module,
                                               language: .matching(primary),
                                               inputFormat: format,
                                               contextualStrings: primaryTerms)
            let s = try await AppleTranscriber(module: prepared[1].module,
                                               language: .matching(secondary),
                                               inputFormat: format,
                                               contextualStrings: secondaryTerms)

            log.info("dual transcription ready: \(primary.identifier(.bcp47), privacy: .public) + \(secondary.identifier(.bcp47), privacy: .public) at \(format.sampleRate)Hz")
            return .dual(primary: p, secondary: s, format: format)

        } catch {
            log.error("dual transcription unavailable, falling back to \(primary.identifier(.bcp47), privacy: .public) only: \(error.localizedDescription, privacy: .public)")
            return try await single(primary, primaryTerms)
        }
    }

    private static func single(_ locale: Locale, _ terms: [String]) async throws -> Prepared {
        let engine = try await AppleTranscriber(locale: locale, contextualStrings: terms)
        return .single(engine, format: engine.inputFormat)
    }

    /// One format both engines accept, so one tap can feed both.
    ///
    /// Measured on this machine: `ja-JP` and `en-US` both negotiate
    /// 16000Hz/mono/Int16 and the joint call succeeds, so step 2 is a guard
    /// against other locale pairs rather than an expected path.
    static func sharedFormat(_ modules: [SpeechTranscriber]) async -> AVAudioFormat? {
        if let joint = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) {
            return joint
        }

        var common: [AVAudioFormat]?
        for m in modules {
            let formats = await m.availableCompatibleAudioFormats
            common = common.map { c in c.filter { f in formats.contains { same($0, f) } } } ?? formats
        }
        return common?.first
    }

    private static func same(_ a: AVAudioFormat, _ b: AVAudioFormat) -> Bool {
        a.sampleRate == b.sampleRate
            && a.channelCount == b.channelCount
            && a.commonFormat == b.commonFormat
            && a.isInterleaved == b.isInterleaved
    }
}
