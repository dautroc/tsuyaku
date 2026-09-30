import Foundation

/// Checks the saved transcript against a scratch directory: when a file is
/// opened, what goes in it, and that Stop leaves no stray rows behind for the
/// next meeting. No audio, no network, and nothing written outside the temp
/// directory.
///
/// Run with `Tsuyaku --store-selftest` (via `make test`).
@MainActor
enum TranscriptSelfTest {

    private static var failures = 0

    static func run() -> Int {
        failures = 0
        print("\n=== transcript self-test ===")
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "tsuyaku-selftest-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: dir) }

        sessionWritesOneFile(in: dir.appending(path: "session"))
        rowsOutsideASessionAreDropped(in: dir.appending(path: "outside"))
        noRowIsWrittenTwice(in: dir.appending(path: "twice"))
        return failures
    }

    private static func sessionWritesOneFile(in dir: URL) {
        let w = TranscriptWriter(directory: dir)
        w.begin()
        expect("no file before the first row", w.currentFile == nil && files(in: dir).isEmpty)

        w.append([row("お疲れ様です。", "Thanks for your hard work.")])
        w.append([row("始めましょう。", "Let's begin."), row("", "Next item.")])
        guard let url = w.currentFile else {
            expect("the first row opens a file", false)
            return
        }
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        expect("the file starts with its header", text.hasPrefix("# Meeting transcript — "))
        expect("rows are appended in order",
               text.contains("> お疲れ様です。\n\nThanks for your hard work.")
               && text.range(of: "Thanks")!.lowerBound < text.range(of: "Let's begin.")!.lowerBound)
        expect("a row with no source has no quote", !text.contains("> \n"))
        let mode = (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) as? Int
        expect("the file is readable by its owner only", mode == 0o600)

        w.finish()
        w.begin()
        w.append([row("次の議題です。", "Next topic.")])
        w.finish()   // waits for the append to land
        expect("the next session gets its own file", files(in: dir).count == 2)
    }

    /// A translation cancelled by Stop finishes its row a moment after the
    /// pipeline has stopped; it must not open a file of its own.
    private static func rowsOutsideASessionAreDropped(in dir: URL) {
        let w = TranscriptWriter(directory: dir)
        w.append([row("まだ開始前。", "Not started yet.")])
        w.begin()
        w.append([row("本題です。", "The main topic.")])
        w.finish()
        w.append([row("遅れて完了。", "Finished late.")])
        _ = w.currentFile   // drain the queue
        let all = files(in: dir)
        let text = all.first.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        expect("only rows inside the session are written",
               all.count == 1 && text.contains("The main topic.")
               && !text.contains("Not started yet.") && !text.contains("Finished late."))
    }

    /// A row stranded in the live pane is written at Stop, and is still in the
    /// live pane at the next Stop. It belongs to the first meeting only.
    private static func noRowIsWrittenTwice(in dir: URL) {
        let w = TranscriptWriter(directory: dir)
        let stranded = row("納期については", "As for the deadline")
        w.begin()
        w.append([stranded])
        w.append([stranded])
        w.finish()
        w.begin()
        w.append([stranded, row("次です。", "Next.")])
        w.finish()

        let texts = files(in: dir).compactMap { try? String(contentsOf: $0, encoding: .utf8) }
        let count = texts.map { $0.components(separatedBy: "As for the deadline").count - 1 }.reduce(0, +)
        expect("a row is written once across sessions", count == 1)
        expect("new rows still reach the second session", texts.count == 2)
    }

    // MARK: -

    private static func row(_ source: String, _ target: String) -> SubtitleLine {
        SubtitleLine(utterance: UUID(), source: source, target: target,
                     provisional: false, translationDone: true, failed: false, at: .now)
    }

    private static func files(in dir: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    }

    private static func expect(_ what: String, _ ok: Bool) {
        print("  \(ok ? "ok  " : "FAIL") \(what)")
        if !ok { failures += 1 }
    }
}
