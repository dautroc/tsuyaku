import Foundation
import Speech

/// Ensures the on-device model assets for one or more locales are reserved and
/// installed. `SpeechAnalyzer.bestAvailableAudioFormat` returns nil until this
/// succeeds, so this must run before any audio format negotiation.
enum AssetGate {

    enum State: Sendable {
        case unsupported
        case installing(Progress)
        case ready
    }

    /// Requested on every transcriber. `.transcriptionConfidence` was measured
    /// to cost no extra asset -- `AssetInventory.status` is identical with and
    /// without it -- so it is always on, and the picker decides separately
    /// whether the numbers are trustworthy enough to use.
    static let defaultAttributes: Set<SpeechTranscriber.ResultAttributeOption> =
        [.audioTimeRange, .transcriptionConfidence]

    static func prepare(
        locale: Locale,
        attributes: Set<SpeechTranscriber.ResultAttributeOption> = defaultAttributes,
        onProgress: @Sendable (Progress) -> Void = { _ in }
    ) async throws -> SpeechTranscriber {
        let prepared = try await prepareAll(locales: [locale],
                                            attributes: attributes,
                                            onProgress: onProgress)
        guard let first = prepared.first else {
            throw AssetError.unsupportedLocale(locale.identifier)
        }
        return first.module
    }

    /// Reserves every locale, then issues **one** installation request covering
    /// all of them -- `assetInstallationRequest(supporting:)` takes an array, so
    /// asking once avoids N sequential downloads.
    ///
    /// Note that `AssetInventory.status` reports `.supported` rather than
    /// `.installed` until a locale is reserved *in this process*, and
    /// reservation is per app identity. A status check before `reserve` is
    /// therefore not evidence that a model is missing.
    static func prepareAll(
        locales: [Locale],
        attributes: Set<SpeechTranscriber.ResultAttributeOption> = defaultAttributes,
        onProgress: @Sendable (Progress) -> Void = { _ in }
    ) async throws -> [(locale: Locale, module: SpeechTranscriber)] {

        var prepared: [(locale: Locale, module: SpeechTranscriber)] = []
        var reserved = await AssetInventory.reservedLocales
        let maximum = AssetInventory.maximumReservedLocales

        for locale in locales {
            guard let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
                throw AssetError.unsupportedLocale(locale.identifier)
            }

            let module = SpeechTranscriber(
                locale: resolved,
                transcriptionOptions: [],
                reportingOptions: [.volatileResults, .fastResults],
                attributeOptions: attributes
            )

            // Reserving is idempotent. Nothing here ever releases, so the cap
            // is checked rather than discovered via `tooManyAssetLocalesAllocated`.
            if !reserved.contains(where: { $0.identifier(.bcp47) == resolved.identifier(.bcp47) }) {
                guard reserved.count < maximum else {
                    throw AssetError.tooManyLocales(resolved.identifier(.bcp47), maximum)
                }
                _ = try await AssetInventory.reserve(locale: resolved)
                reserved.append(resolved)
            }

            prepared.append((resolved, module))
        }

        if let request = try await AssetInventory.assetInstallationRequest(
            supporting: prepared.map(\.module)
        ) {
            onProgress(request.progress)
            try await request.downloadAndInstall()
        }

        return prepared
    }

    enum AssetError: Error, CustomStringConvertible {
        case unsupportedLocale(String)
        case tooManyLocales(String, Int)
        case noSharedFormat(String, String)

        var description: String {
            switch self {
            case .unsupportedLocale(let id):
                "locale \(id) is not supported by SpeechTranscriber"
            case .tooManyLocales(let id, let max):
                "cannot reserve \(id): already at the system limit of \(max) locales"
            case .noSharedFormat(let a, let b):
                "\(a) and \(b) negotiate no common audio format"
            }
        }
    }
}
