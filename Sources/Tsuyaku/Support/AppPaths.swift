import Foundation

/// Files the user owns, as opposed to settings the app owns.
///
/// Application Support rather than ~/Documents: an unsandboxed app still gets
/// a TCC prompt the first time it touches Documents, and a transcript write
/// that fails because that prompt was dismissed fails silently, mid-meeting.
enum AppPaths {

    static let directory: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "Tsuyaku", directoryHint: .isDirectory)

    /// Plain text, one `source = target` per line. See `Glossary.parse`.
    static let glossaryFile = directory.appending(path: "glossary.txt")

    /// One Markdown file per session. See `TranscriptWriter`.
    static let transcriptsDirectory = directory.appending(path: "Transcripts", directoryHint: .isDirectory)

    static func ensureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}
