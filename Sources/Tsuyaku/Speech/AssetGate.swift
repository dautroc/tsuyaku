import Foundation
import Speech

/// Ensures the on-device model assets for a locale are reserved and installed.
/// `SpeechAnalyzer.bestAvailableAudioFormat` returns nil until this succeeds,
/// so this must run before any audio format negotiation.
enum AssetGate {

    enum State: Sendable {
        case unsupported
        case installing(Progress)
        case ready
    }

    static func prepare(
        locale: Locale,
        onProgress: @Sendable (Progress) -> Void = { _ in }
    ) async throws -> SpeechTranscriber {

        guard let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw AssetError.unsupportedLocale(locale.identifier)
        }

        let transcriber = SpeechTranscriber(
            locale: resolved,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [.audioTimeRange]
        )

        // Reserving is idempotent; releases happen when we swap locales.
        let reserved = await AssetInventory.reservedLocales
        if !reserved.contains(where: { $0.identifier(.bcp47) == resolved.identifier(.bcp47) }) {
            _ = try await AssetInventory.reserve(locale: resolved)
        }

        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            onProgress(request.progress)
            try await request.downloadAndInstall()
        }
        return transcriber
    }

    enum AssetError: Error, CustomStringConvertible {
        case unsupportedLocale(String)
        var description: String {
            switch self {
            case .unsupportedLocale(let id): "locale \(id) is not supported by SpeechTranscriber"
            }
        }
    }
}
