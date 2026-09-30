import Foundation
import OSLog

/// Saves a session's subtitles to disk as they settle, one Markdown file per
/// session.
///
/// The panel's history is capped at 500 rows and Copy Transcript only reaches
/// the clipboard, so without this a long meeting lost its beginning and every
/// meeting was gone at Quit. Rows are appended the moment they graduate
/// (`SubtitleStore.onSettled`), so a crash loses at most the rows still live.
///
/// A session is Start to Stop as the user sees it: `begin()` to `finish()`.
/// The file is opened lazily on the first row, so a session in which nobody
/// spoke leaves nothing behind. Cycling the pipeline for a settings change is
/// not a new session: one meeting stays in one file.
///
/// Rows outside a session are dropped, and no row is ever written twice. Both
/// matter at Stop: a translation cancelled mid-stream still finishes its row a
/// moment *after* the pipeline stops, and a row stranded in the live pane is
/// still there at the next Stop. The caller writes the live rows once, at
/// Stop, and these two rules keep either from turning up again -- in a
/// one-row file of its own, or in the next meeting's.
///
/// Writes go through a private serial queue, never the main thread, and a
/// failed write is logged rather than surfaced: the panel has one job during a
/// meeting, and a disk error is not it.
final class TranscriptWriter: @unchecked Sendable {

    private let log = Logger(subsystem: "com.loind.tsuyaku", category: "transcript")
    let directory: URL

    // Everything below is touched only on `queue`.
    private let queue = DispatchQueue(label: "com.loind.tsuyaku.transcript")
    private var active = false
    private var handle: FileHandle?
    private var fileURL: URL?
    /// Every row ever written, across sessions. A few thousand UUIDs a day.
    private var written: Set<UUID> = []
    private let rowTime = SubtitleLine.timeFormatter()

    init(directory: URL) {
        self.directory = directory
    }

    /// The file this session is writing to; nil before its first row. Waits
    /// for pending writes, so it is also how a caller knows they have landed.
    var currentFile: URL? { queue.sync { fileURL } }

    /// Starts a session, ending any still open.
    func begin() {
        queue.sync {
            close()
            active = true
        }
    }

    func append(_ lines: [SubtitleLine]) {
        guard !lines.isEmpty else { return }
        let startedAt = Date.now
        queue.async { [self] in
            guard active else { return }
            let fresh = lines.filter { written.insert($0.id).inserted }
            guard !fresh.isEmpty else { return }
            do {
                let handle = try handle ?? open(startedAt: startedAt)
                let text = fresh.map { $0.markdown(time: rowTime) }.joined()
                try handle.write(contentsOf: Data(text.utf8))
            } catch {
                log.error("transcript write failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Ends the session. Synchronous, so a write queued just before Quit is on
    /// disk before the process goes.
    func finish() {
        queue.sync {
            close()
            active = false
        }
    }

    private func close() {
        try? handle?.close()
        handle = nil
        fileURL = nil
    }

    private func open(startedAt date: Date) throws -> FileHandle {
        try AppPaths.ensureDirectory(directory)
        let name = Self.stamp("yyyy-MM-dd HH-mm-ss", date)
        var url = directory.appending(path: "\(name).md")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appending(path: "\(name) \(n).md")
            n += 1
        }
        // Owner-only: this is the full text of a meeting.
        let header = "# Meeting transcript — \(Self.stamp("yyyy-MM-dd HH:mm", date))\n\n"
        guard FileManager.default.createFile(atPath: url.path,
                                             contents: Data(header.utf8),
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        self.handle = handle
        fileURL = url
        log.info("saving transcript to \(url.path, privacy: .public)")
        return handle
    }

    /// POSIX locale and Gregorian calendar: a Mac set to the Japanese calendar
    /// would otherwise name the file by the Reiwa year.
    private static func stamp(_ format: String, _ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.dateFormat = format
        return fmt.string(from: date)
    }
}
