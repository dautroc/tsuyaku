import Foundation

/// The version the running copy reports. `scripts/bundle.sh` stamps both keys
/// into the bundled Info.plist from `VERSION` and the commit count, so these
/// read back whatever that build was tagged as. A bare `swift build` binary has
/// no bundle Info.plist at all, hence the `dev` fallback -- an unstamped build
/// should say so rather than claim to be a release.
enum Version {
    static var short: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "dev"
    }

    static var full: String { "Tsuyaku \(short) (build \(build))" }
}
