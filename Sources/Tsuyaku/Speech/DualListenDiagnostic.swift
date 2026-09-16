import Foundation
import Speech
import AVFoundation
import OSLog

/// Runs the Japanese and English recognizers side by side and prints every
/// number the language picker would use, so the thresholds can be **fitted from
/// real meeting audio instead of guessed**.
///
/// This exists because the picker is the whole feature and its constants are
/// the part that cannot be derived from first principles. It deliberately calls
/// `LanguageScore` and `PickerState` directly rather than reimplementing them,
/// so the "pick" column is the shipping decision, not an approximation of it.
///
///   --listen-dual [bundle|global] [seconds]   live capture
///   --listen-dual-file <path.wav>             deterministic replay
///
/// The file mode is the important half: record once with `--capture`, then
/// replay the same meeting against as many tunings as you like and get the same
/// answer every time.
enum DualListenDiagnostic {

    // MARK: - Live capture

    static func runLive(bundle: String, seconds: Double) async {
        do {
            let prepared = try await TranscriberFactory.make(
                primary: Locale(identifier: "ja-JP"),
                secondary: Locale(identifier: "en-US"),
                primaryTerms: ["ラクスル", "見積もり", "定例会議"]
            )

            guard case .dual(let ja, let en, let format) = prepared else {
                print("dual transcription unavailable on this machine; nothing to measure")
                return
            }

            let tap = SystemAudioTap(bundleIDs: bundle == "global" ? [] : [bundle],
                                     outputFormat: format)
            try await ja.start()
            try await en.start()
            try tap.start()

            let recorder = Recorder(format: format)
            await recorder.header(bundle: bundle, seconds: seconds, format: format)

            let pump = Task {
                // Sequential, not a broadcast: `feed` only yields into a
                // bounded stream, so a stalled engine drops its own oldest
                // buffers rather than starving the other one. Sharing one
                // stream also means both engines degrade on the SAME audio,
                // which is exactly what arbitration needs.
                for await chunk in tap.buffers {
                    await ja.feed(chunk)
                    await en.feed(chunk)
                    await recorder.countChunk()
                }
            }
            let jaReader = Task { for await s in ja.segments { await recorder.observe(s) } }
            let enReader = Task { for await s in en.segments { await recorder.observe(s) } }

            try? await Task.sleep(for: .seconds(seconds))
            try tap.stop()
            pump.cancel()
            await ja.finish()
            await en.finish()
            _ = await jaReader.result
            _ = await enReader.result

            await recorder.summary(elapsed: seconds)
        } catch {
            print("listen-dual FAILED: \(error)")
        }
    }

    // MARK: - Deterministic replay

    static func runFile(path: String) async {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("no such file: \(path)")
            return
        }

        do {
            let prepared = try await TranscriberFactory.make(
                primary: Locale(identifier: "ja-JP"),
                secondary: Locale(identifier: "en-US"),
                primaryTerms: ["ラクスル", "見積もり", "定例会議"]
            )
            guard case .dual(let ja, let en, let format) = prepared else {
                print("dual transcription unavailable on this machine; nothing to measure")
                return
            }

            let probe = try AVAudioFile(forReading: url)
            let seconds = Double(probe.length) / probe.fileFormat.sampleRate
            let recorder = Recorder(format: format)
            await recorder.header(bundle: url.lastPathComponent, seconds: seconds, format: format)

            let jaReader = Task { for await s in ja.segments { await recorder.observe(s) } }
            let enReader = Task { for await s in en.segments { await recorder.observe(s) } }

            // Each engine gets its own file handle, so each has its own read
            // cursor and they consume the same audio independently.
            async let jaDone: Void = ja.analyze(file: url)
            async let enDone: Void = en.analyze(file: url)
            try await jaDone
            try await enDone

            await ja.finish()
            await en.finish()
            _ = await jaReader.result
            _ = await enReader.result

            await recorder.summary(elapsed: seconds)
        } catch {
            print("listen-dual-file FAILED: \(error)")
        }
    }

    // MARK: - Recording and reporting

    /// Accumulates everything the summary needs. An actor because both engines'
    /// reader tasks and the feed pump all report into it.
    private actor Recorder {

        private let format: AVAudioFormat
        private let start = ContinuousClock.now
        private var state = PickerState()

        private var chunks = 0
        private var lastVolatilePrint: [SpokenLanguage: ContinuousClock.Instant] = [:]
        private var finals: [SpokenLanguage: Int] = [:]
        private var finalAt: [SpokenLanguage: [Double]] = [:]
        private var confidences: [SpokenLanguage: [Double]] = [:]
        private var confidenceOnVolatile = false
        private var confidenceOnFinal = false
        private var scores: [Double] = []
        private var locks: [SpokenLanguage: Int] = [:]
        private var lockReasons: [PickerState.Choice.Reason: Int] = [:]
        private var terminatorHits: [SpokenLanguage: [Character: Int]] = [:]

        init(format: AVAudioFormat) { self.format = format }

        func countChunk() { chunks += 1 }

        func header(bundle: String, seconds: Double, format: AVAudioFormat) {
            print("# tsuyaku --listen-dual \(bundle) \(Int(seconds))s   fmt=\(Int(format.sampleRate))Hz/\(format.channelCount)ch/common\(format.commonFormat.rawValue)  footprint=\(Footprint.megabytes())MB")
            print("#    t  eng F   conf  hira  kata kanji glue  run score  pick         text")
        }

        func observe(_ segment: Segment) {
            guard !segment.text.isEmpty else { return }
            let now = ContinuousClock.now
            let d = now - start
            let t = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18

            let lang = segment.language
            let wasLocked = state.locked
            state.observe(segment)

            if let c = segment.confidence {
                confidences[lang, default: []].append(c)
                if segment.isFinal { confidenceOnFinal = true } else { confidenceOnVolatile = true }
            }

            if segment.isFinal {
                finals[lang, default: 0] += 1
                finalAt[lang, default: []].append(t)
                countTerminators(segment.text, lang)
            }

            // Volatile results arrive ~10x a second per engine; throttle them so
            // the log stays readable. Finals are never dropped.
            if !segment.isFinal {
                if let last = lastVolatilePrint[lang], now - last < .milliseconds(250) { return }
                lastVolatilePrint[lang] = now
            }

            let choice = state.choose()
            if segment.language == .ja, segment.isFinal || wasLocked == nil {
                scores.append(choice.score)
                locks[choice.language, default: 0] += 1
                lockReasons[choice.reason, default: 0] += 1
            }

            print(row(t: t, segment: segment, choice: choice, wasLocked: wasLocked))
        }

        private func countTerminators(_ text: String, _ lang: SpokenLanguage) {
            for ch in text where "。！？.!?".contains(ch) {
                terminatorHits[lang, default: [:]][ch, default: 0] += 1
            }
        }

        private func row(t: Double,
                         segment: Segment,
                         choice: PickerState.Choice,
                         wasLocked: SpokenLanguage?) -> String {
            let conf = segment.confidence.map { String(format: "%5.2f", $0) } ?? "    -"
            let mark = segment.isFinal ? "F" : "."

            // The script columns are computed from the ja engine's text only;
            // they are meaningless for the en engine and print as dashes.
            var cols = "    -     -     -    -    -     -  -           "
            if segment.language == .ja {
                let s = LanguageScore.stats(segment.text)
                let c = Double(max(s.content, 1))
                // Not "*lock": this diagnostic never submits gate events, so
                // nothing actually locks. This is the decision the picker WOULD
                // make, with the rule that produced it.
                let pick = "\(choice.language.display)(\(choice.reason.rawValue))"
                cols = String(format: "%5.2f %5.2f %5.2f %4d %4d %5.2f  %-12@",
                              Double(s.hiragana) / c,
                              Double(s.katakana) / c,
                              Double(s.kanji) / c,
                              s.glueHits,
                              s.longestKatakanaRun,
                              choice.score,
                              pick as NSString)
            }

            return String(format: "%6.2f  %@  %@  %@ %@  %@",
                          t, segment.language.rawValue, mark, conf, cols, segment.text)
        }

        func summary(elapsed: Double) {
            print("\n--- dual listen summary (\(String(format: "%.1f", elapsed))s) ---")
            print("format            \(Int(format.sampleRate))Hz \(format.channelCount)ch common\(format.commonFormat.rawValue)   (joint negotiation: ok)")
            print("footprint         \(Footprint.megabytes())MB   (compare against `--listen` for the ja-only baseline)")
            if chunks > 0 { print("chunks            fed \(chunks)") }
            print("finalization      ja finals \(finals[.ja] ?? 0)   en finals \(finals[.en] ?? 0)")
            print(skewLine())

            print("confidence        on volatile: \(confidenceOnVolatile ? "YES" : "NO")   on finals: \(confidenceOnFinal ? "YES" : "NO")")
            for l in SpokenLanguage.allCases {
                let cs = confidences[l] ?? []
                guard !cs.isEmpty else {
                    print("                  \(l.rawValue): no confidence values reported")
                    continue
                }
                let mean = cs.reduce(0, +) / Double(cs.count)
                let sd = (cs.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(cs.count)).squareRoot()
                print(String(format: "                  %@ mean %.2f sd %.2f  range [%.2f .. %.2f]  n=%d",
                             l.rawValue, mean, sd, cs.min() ?? 0, cs.max() ?? 0, cs.count))
            }
            if confidenceOnVolatile || confidenceOnFinal {
                print("                  ^ CHECK the range: 0..1 is assumed, the SDK documents nothing")
            }

            print(histogram())
            let lockLine = locks.map { "\($0.key.display) \($0.value)" }.sorted().joined(separator: "  ")
            let reasonLine = lockReasons.map { "\($0.key.rawValue) \($0.value)" }.sorted().joined(separator: " ")
            print("picker            \(lockLine.isEmpty ? "no decisions" : lockLine)   reasons: \(reasonLine)")

            for l in SpokenLanguage.allCases {
                let hits = terminatorHits[l] ?? [:]
                let rendered = hits.isEmpty ? "none" : hits.map { "\($0.key)\($0.value)" }.sorted().joined(separator: " ")
                print("terminators \(l.rawValue)        \(rendered)")
            }
            if (terminatorHits[.en] ?? [:]).isEmpty {
                print("                  ^ no English terminators: that gate will be timer-driven")
            }
        }

        private func skewLine() -> String {
            let a = finalAt[.ja] ?? [], b = finalAt[.en] ?? []
            guard !a.isEmpty, !b.isEmpty else {
                return "                  skew: not enough finals to measure"
            }
            var deltas: [Double] = []
            for t in a {
                if let nearest = b.min(by: { abs($0 - t) < abs($1 - t) }) {
                    deltas.append(abs(nearest - t))
                }
            }
            deltas.sort()
            let mean = deltas.reduce(0, +) / Double(deltas.count)
            let p95 = deltas[min(deltas.count - 1, Int(Double(deltas.count) * 0.95))]
            return String(format: "                  |dt(final)| mean %.2fs  p95 %.2fs  max %.2fs",
                          mean, p95, deltas.last ?? 0)
        }

        private func histogram() -> String {
            guard !scores.isEmpty else { return "score histogram   (no scored utterances)" }
            let edges = [0.1, 0.3, 0.5, 0.7, 0.9, 1.01]
            let labels = ["<0.1", ".1-.3", ".3-.5", ".5-.7", ".7-.9", ">0.9"]
            var counts = [Int](repeating: 0, count: edges.count)
            for s in scores {
                for (i, e) in edges.enumerated() where s < e {
                    counts[i] += 1
                    break
                }
            }
            let body = zip(labels, counts).map { "\($0): \($1)" }.joined(separator: "  ")
            return "score histogram   \(body)\n                  suggested threshold (widest gap): \(String(format: "%.2f", suggestedThreshold()))"
        }

        /// Midpoint of the widest empty interval between observed scores: the
        /// split that puts the most daylight between the two clusters.
        private func suggestedThreshold() -> Double {
            let s = scores.sorted()
            guard s.count > 1 else { return 0.5 }
            var bestGap = 0.0, bestMid = 0.5
            for i in 1..<s.count where s[i] - s[i - 1] > bestGap {
                bestGap = s[i] - s[i - 1]
                bestMid = (s[i] + s[i - 1]) / 2
            }
            return bestMid
        }
    }
}

/// Resident memory, for comparing one analyzer against two.
enum Footprint {
    static func megabytes() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kerr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kerr == KERN_SUCCESS else { return -1 }
        return Int(info.phys_footprint / (1024 * 1024))
    }
}
