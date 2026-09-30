import Foundation
import AppKit
import CoreAudio
import AVFoundation
import Speech
import Translation

/// Developer/diagnostic command line. The GUI is the real product; these
/// subcommands exist to exercise one layer of the pipeline at a time.
enum CLI {

    static let usage = """
    Tsuyaku -- live Japanese to English meeting subtitles

      (no arguments)              launch the menu bar app

      --version                   print the version and exit
      --probe                     report framework/model/asset status
      --install-assets            download the on-device speech model (see --locale)
      --apple-preflight           check the Apple ja->en translation model
      --set-key <provider> <key>  store a key (provider: anthropic | deepseek | opencodeGo | qwenOmni | geminiLive)
      --provider <name>           apple | foundation | ollama | anthropic | deepseek | opencodeGo | qwenOmni | geminiLive (default: saved setting)
      --opencode-model <id>       OpenCode Go model ID (default: deepseek-v4.1-flash)
      --omni-model <id>           Qwen omni model ID (default: qwen3-omni-flash)
      --omni-test [file.wav]      send one WAV to Qwen omni and print the reply
      --gemini-model <id>         Gemini Live model ID (default: gemini-3.5-live-translate-preview)
      --gemini-test [file.wav]    stream one WAV to Gemini Live and print every server event
      --locale <bcp47>            speech locale for --listen / --install-assets (default: ja-JP)
      --glossary                  print the glossary file's path and the entries parsed from it
      --compare                   run every configured backend over a Japanese fixture set
      --capture [bundle|global] [s]   dump captured audio to /tmp/tsuyaku-capture.wav
      --listen  [bundle|global] [s]   live transcription only, to stdout
      --listen-dual [bundle|global] [s]   ja + en side by side, with picker scores
      --listen-dual-file <path.wav>   the same, replayed from a --capture recording
      --translate-text <ja>       one-shot translation, reports TTFB
      --pipeline [bundle|global] [s]  full pipeline to stdout, with the glossary applied
      --store-selftest            check the subtitle pane logic (no audio, no network)
      --device-switch-test        switch the output device mid-capture and verify recovery

    'global' taps all system audio except this app. A bundle id (e.g. us.zoom.xos)
    taps just that app.
    """


    static func probeCoreAudioTaps() -> String {
        // Just prove the symbols link; don't create a tap yet.
        let desc = CATapDescription(stereoMixdownOfProcesses: [])
        desc.bundleIDs = ["us.zoom.xos"]
        desc.isProcessRestoreEnabled = true
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        return "CATapDescription ok: bundleIDs=\(desc.bundleIDs) restore=\(desc.isProcessRestoreEnabled) private=\(desc.isPrivate)"
    }

    static func probeSpeech() async -> String {
        guard SpeechTranscriber.isAvailable else { return "SpeechTranscriber.isAvailable == false" }
        let supported = await SpeechTranscriber.supportedLocales
        let installed = await SpeechTranscriber.installedLocales
        let ja = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "ja-JP"))
        return """
        SpeechTranscriber.isAvailable = true
          supported (\(supported.count)): \(supported.map { $0.identifier(.bcp47) }.sorted().joined(separator: ", "))
          installed (\(installed.count)): \(installed.map { $0.identifier(.bcp47) }.sorted().joined(separator: ", "))
          ja-JP resolves to: \(ja?.identifier(.bcp47) ?? "nil")
        """
    }

    static func probeSpeechFormat() async -> String {
        guard let ja = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "ja-JP")) else {
            return "no ja locale; skipping format probe"
        }
        let t = SpeechTranscriber(locale: ja,
                                  transcriptionOptions: [],
                                  reportingOptions: [.volatileResults, .fastResults],
                                  attributeOptions: [.audioTimeRange])
        let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [t])
        let status = await AssetInventory.status(forModules: [t])
        return "analyzer bestAvailableAudioFormat = \(fmt.map { "\($0.sampleRate)Hz ch=\($0.channelCount) \($0.commonFormat.rawValue)" } ?? "nil")\n  AssetInventory.status = \(status)\n  maximumReservedLocales = \(AssetInventory.maximumReservedLocales)"
    }

    static func probeTranslation() async -> String {
        let avail = LanguageAvailability()
        let ja = Locale.Language(identifier: "ja")
        let en = Locale.Language(identifier: "en")
        let status = await avail.status(from: ja, to: en)
        return "Translation ja->en status = \(status)"
    }

    static func selectedProvider() -> TranslationProvider? {
        guard let i = CommandLine.arguments.firstIndex(of: "--provider"),
              CommandLine.arguments.count > i+1 else { return nil }
        return TranslationProvider(rawValue: CommandLine.arguments[i+1])
    }

    /// Speech locale for the single-language diagnostics. Defaults to Japanese.
    static func selectedLocale() -> Locale {
        guard let i = CommandLine.arguments.firstIndex(of: "--locale"),
              CommandLine.arguments.count > i + 1 else {
            return Locale(identifier: "ja-JP")
        }
        return Locale(identifier: CommandLine.arguments[i + 1])
    }

    static func pad(_ s: String) -> String {
        s.padding(toLength: 10, withPad: " ", startingAt: 0)
    }

    /// Runs one translation and reports the text plus time-to-first-token.
    static func time(_ t: any Translator, _ text: String) async -> (String, Duration) {
        let clock = ContinuousClock()
        let begin = clock.now
        var out = ""
        var first: Duration?
        for await d in t.translate(text, context: []) {
            switch d {
            case .text(let s):
                if first == nil { first = clock.now - begin }
                out += s
            case .failed(let e, _): out = "[failed: \(e)]"
            case .usingFallback, .done: break
            }
        }
        return (out, first ?? .zero)
    }

    /// Any audio file, decoded and converted to the 16 kHz mono Int16 the
    /// audio backends are fed. A `--capture` recording is already close, but
    /// `AVAudioFile` hands back float32 whatever is on disk.
    static func readCaptureFormat(_ path: String) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let source = file.processingFormat
        let target = WAVEncoder.captureFormat
        guard let input = AVAudioPCMBuffer(pcmFormat: source,
                                           frameCapacity: AVAudioFrameCount(file.length)),
              let converter = AVAudioConverter(from: source, to: target) else {
            throw CA.Err(status: -1, op: "AVAudioConverter(\(source) -> \(target))")
        }
        try file.read(into: input)
        converter.downmix = true

        let capacity = AVAudioFrameCount(Double(input.frameLength) * target.sampleRate / source.sampleRate) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw CA.Err(status: -1, op: "allocate output buffer")
        }
        // The input block is `@Sendable`; a box keeps the one-shot handoff
        // honest without capturing a mutable local.
        final class Once: @unchecked Sendable { var buffer: AVAudioPCMBuffer? }
        let once = Once()
        once.buffer = input
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            guard let b = once.buffer else {
                outStatus.pointee = .endOfStream
                return nil
            }
            once.buffer = nil
            outStatus.pointee = .haveData
            return b
        }
        if status == .error { throw error ?? CA.Err(status: -1, op: "convert") }
        return output
    }

    /// `buffer` cut into consecutive buffers of `frames` frames each.
    static func slice(_ buffer: AVAudioPCMBuffer, frames: Int) -> [AudioChunk] {
        guard let source = buffer.int16ChannelData?[0] else { return [] }
        var out: [AudioChunk] = []
        var offset = 0
        let total = Int(buffer.frameLength)
        while offset < total {
            let n = min(frames, total - offset)
            guard let b = AVAudioPCMBuffer(pcmFormat: buffer.format,
                                           frameCapacity: AVAudioFrameCount(n)),
                  let dest = b.int16ChannelData?[0] else { break }
            dest.update(from: source + offset, count: n)
            b.frameLength = AVAudioFrameCount(n)
            out.append(AudioChunk(buffer: b, hostTime: 0))
            offset += n
        }
        return out
    }

    static func run() async throws {
        if CommandLine.arguments.contains("--help") || CommandLine.arguments.contains("-h") {
            print(usage); exit(0)
        }

        if CommandLine.arguments.contains("--version") {
            print(Version.full); exit(0)
        }

        if CommandLine.arguments.contains("--probe") {
            print("=== Tsuyaku probe ===")
            print(probeCoreAudioTaps())
            print(await probeSpeech())
            print(await probeSpeechFormat())
            print(await probeTranslation())
        }

        if CommandLine.arguments.contains("--install-assets") {
            let locale = selectedLocale()
            print("--- installing \(locale.identifier(.bcp47)) speech assets (this can take a while) ---")
            do {
                let t = try await AssetGate.prepare(locale: locale) { p in
                    print("  download progress object: \(p.localizedDescription ?? "n/a")")
                }
                let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [t])
                let installed = await SpeechTranscriber.installedLocales
                print("assets installed. installedLocales = \(installed.map { $0.identifier(.bcp47) })")
                print("bestAvailableAudioFormat = \(fmt.map { "\($0.sampleRate)Hz ch=\($0.channelCount) common=\($0.commonFormat.rawValue) interleaved=\($0.isInterleaved)" } ?? "nil")")
            } catch {
                print("asset install FAILED: \(error)")
            }
        }


        if let i = CommandLine.arguments.firstIndex(of: "--capture") {
            let bundle = CommandLine.arguments.count > i+1 ? CommandLine.arguments[i+1] : ""
            let seconds = CommandLine.arguments.count > i+2 ? Double(CommandLine.arguments[i+2]) ?? 10 : 10

            if bundle.isEmpty {
                print("running processes producing output audio:")
                for b in (try? CA.runningOutputBundleIDs()) ?? [] { print("  \(b)") }
            } else {
                guard let ja = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "ja-JP")),
                      let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [
                          SpeechTranscriber(locale: ja, preset: .progressiveTranscription)]) else {
                    print("could not negotiate analyzer format"); exit(1)
                }
                print("capturing \(bundle) for \(seconds)s into \(fmt.sampleRate)Hz ch=\(fmt.channelCount)")
                let tap = SystemAudioTap(bundleIDs: bundle == "global" ? [] : [bundle], outputFormat: fmt)
                do {
                    try tap.start()
                } catch {
                    print("tap.start FAILED: \(error)"); exit(1)
                }
                let url = URL(fileURLWithPath: "/tmp/tsuyaku-capture.wav")
                try? FileManager.default.removeItem(at: url)
                let file = try! AVAudioFile(forWriting: url, settings: fmt.settings,
                                            commonFormat: fmt.commonFormat, interleaved: fmt.isInterleaved)
                let deadline = Date().addingTimeInterval(seconds)
                var frames = 0, peak: Float = 0
                for await chunk in tap.buffers {
                    try? file.write(from: chunk.buffer)
                    frames += Int(chunk.buffer.frameLength)
                    if let p = chunk.buffer.int16ChannelData?[0] {
                        for k in 0..<Int(chunk.buffer.frameLength) {
                            peak = max(peak, abs(Float(p[k]) / 32768.0))
                        }
                    }
                    if Date() > deadline { break }
                }
                try? tap.stop()
                print("captured \(frames) frames (\(Double(frames)/fmt.sampleRate)s), peak amplitude \(peak)")
                print("wrote \(url.path)")
            }
        }


        if let i = CommandLine.arguments.firstIndex(of: "--listen") {
            let bundle  = CommandLine.arguments.count > i+1 ? CommandLine.arguments[i+1] : "global"
            let seconds = CommandLine.arguments.count > i+2 ? Double(CommandLine.arguments[i+2]) ?? 15 : 15

            do {
                let stt = try await AppleTranscriber(locale: selectedLocale(),
                                                     contextualStrings: ["ラクスル", "見積もり", "定例会議"])
                let fmt = stt.inputFormat
                let tap = SystemAudioTap(bundleIDs: bundle == "global" ? [] : [bundle], outputFormat: fmt)
                try await stt.start()
                try tap.start()
                print("listening to \(bundle) for \(seconds)s at \(fmt.sampleRate)Hz ...")

                let pump = Task {
                    for await chunk in tap.buffers { await stt.feed(chunk) }
                }
                let printer = Task {
                    var timebase = mach_timebase_info_data_t()
                    mach_timebase_info(&timebase)
                    for await seg in stt.segments where !seg.text.isEmpty {
                        let mark = seg.isFinal ? "FINAL" : "  ..."
                        print("[\(mark)] \(seg.text)")
                    }
                }
                try? await Task.sleep(for: .seconds(seconds))
                try tap.stop()
                pump.cancel()
                await stt.finish()
                _ = await printer.result
                print("--- listen complete ---")
            } catch {
                print("listen FAILED: \(error)")
            }
        }


        if let i = CommandLine.arguments.firstIndex(of: "--listen-dual") {
            let bundle  = CommandLine.arguments.count > i+1 ? CommandLine.arguments[i+1] : "global"
            let seconds = CommandLine.arguments.count > i+2 ? Double(CommandLine.arguments[i+2]) ?? 30 : 30
            await DualListenDiagnostic.runLive(bundle: bundle, seconds: seconds)
            exit(0)
        }

        if let i = CommandLine.arguments.firstIndex(of: "--listen-dual-file") {
            guard CommandLine.arguments.count > i+1 else {
                print("--listen-dual-file needs a path to a .wav recorded by --capture")
                exit(1)
            }
            await DualListenDiagnostic.runFile(path: CommandLine.arguments[i+1])
            exit(0)
        }

        if CommandLine.arguments.contains("--device-switch-test") {
            await DeviceSwitchTest.run()
            exit(0)
        }

        if CommandLine.arguments.contains("--store-selftest") {
            await StoreSelfTest.run()
            exit(0)
        }

        // What the pipeline will actually use, parsed exactly as Start parses
        // it -- so a line the parser skipped shows up here as a missing entry.
        if CommandLine.arguments.contains("--glossary") {
            let url = AppPaths.glossaryFile
            print("glossary file: \(url.path)")
            guard FileManager.default.fileExists(atPath: url.path) else {
                print("  (none yet -- create it from the menu bar: Edit Glossary…)")
                exit(0)
            }
            let glossary = Glossary.loadUser()
            print(glossary.isEmpty ? "  (no entries)" : glossary.promptLines)
            exit(0)
        }

        if CommandLine.arguments.contains("--apple-preflight") {
            print("=== Apple Translation preflight (ja -> en) ===")
            print(await AppleTranslator.preflight())
            exit(0)
        }

        if let i = CommandLine.arguments.firstIndex(of: "--set-key") {
            guard CommandLine.arguments.count > i+2,
                  let provider = TranslationProvider(rawValue: CommandLine.arguments[i+1]),
                  let account = provider.keychainAccount else {
                print("usage: --set-key <anthropic|deepseek|opencodeGo|qwenOmni|geminiLive> <key>"); exit(1)
            }
            let ok = Keychain.write(CommandLine.arguments[i+2], account: account)
            print(ok ? "\(provider.displayName) key stored in login keychain."
                     : "FAILED to store key.")
            exit(0)
        }

        if let i = CommandLine.arguments.firstIndex(of: "--opencode-model"),
           CommandLine.arguments.count > i+1 {
            Settings.opencodeModel = CommandLine.arguments[i+1]
            print("opencode model set to \(Settings.opencodeModel)")
            if !CommandLine.arguments.contains("--translate-text") &&
               !CommandLine.arguments.contains("--compare") &&
               !CommandLine.arguments.contains("--pipeline") { exit(0) }
        }

        if let i = CommandLine.arguments.firstIndex(of: "--omni-model"),
           CommandLine.arguments.count > i+1 {
            Settings.omniModel = CommandLine.arguments[i+1]
            print("omni model set to \(Settings.omniModel)")
            if !CommandLine.arguments.contains("--omni-test") { exit(0) }
        }

        // The wire-format check. Everything about the omni request that can be
        // wrong -- the model ID, the region, the `data:;base64,` prefix, the
        // key's namespace -- fails here with the server's own message, rather
        // than as an empty subtitle pane during a meeting.
        if let i = CommandLine.arguments.firstIndex(of: "--omni-test") {
            guard let key = Keychain.read(account: "dashscope") else {
                print("no key -- run: --set-key qwenOmni <key>"); exit(1)
            }
            let path = CommandLine.arguments.count > i+1
                && !CommandLine.arguments[i+1].hasPrefix("--")
                ? CommandLine.arguments[i+1] : nil

            let audio: Data
            if let path {
                guard let d = FileManager.default.contents(atPath: path) else {
                    print("cannot read \(path)"); exit(1)
                }
                audio = d
            } else {
                // A second of silence still exercises the whole request path;
                // the model returns nothing, which is the documented behaviour
                // for speechless audio and still proves auth and framing.
                guard let buffer = AVAudioPCMBuffer(pcmFormat: WAVEncoder.captureFormat,
                                                    frameCapacity: 16_000),
                      let d = { buffer.frameLength = 16_000
                                return WAVEncoder.encode([buffer]) }() else {
                    print("could not synthesise test audio"); exit(1)
                }
                print("no file given -- sending 1s of silence (expect an empty reply)")
                audio = d
            }

            let t = QwenOmniTranslator(apiKey: key, model: Settings.omniModel)
            print("model:    \(Settings.omniModel)")
            print("endpoint: \(QwenOmniTranslator.defaultEndpoint.absoluteString)")
            print("audio:    \(audio.count) bytes")
            let started = ContinuousClock.now
            var out = "", failure: String?
            for await delta in t.translate(audio: audio, context: []) {
                switch delta {
                case .text(let x):   out += x
                case .failed(let m, _):     failure = m
                case .usingFallback, .done: break
                }
            }
            if let failure { print("FAILED: \(failure)"); exit(1) }
            print("EN \(out.isEmpty ? "(empty)" : out)   [\(started.duration(to: .now))]")
            exit(0)
        }

        if let i = CommandLine.arguments.firstIndex(of: "--gemini-model"),
           CommandLine.arguments.count > i+1 {
            Settings.geminiModel = CommandLine.arguments[i+1]
            print("gemini model set to \(Settings.geminiModel)")
            if !CommandLine.arguments.contains("--gemini-test") { exit(0) }
        }

        // The wire-format check for the live path, and the way to learn what
        // the server actually sends: every message is printed raw (audio
        // elided) alongside the deltas parsed from it. A refused setup, a
        // wrong model ID or a misplaced config field all surface here as the
        // server's close reason.
        if let i = CommandLine.arguments.firstIndex(of: "--gemini-test") {
            guard let key = Keychain.read(account: "gemini") else {
                print("no key -- run: --set-key geminiLive <key>"); exit(1)
            }
            let path = CommandLine.arguments.count > i+1
                && !CommandLine.arguments[i+1].hasPrefix("--")
                ? CommandLine.arguments[i+1] : nil

            let audio: AVAudioPCMBuffer
            if let path {
                do {
                    audio = try readCaptureFormat(path)
                } catch {
                    print("cannot read \(path): \(error)"); exit(1)
                }
            } else {
                // Proves auth, model ID and setup framing. The model hears
                // nothing, so expect setupComplete and no transcription.
                guard let b = AVAudioPCMBuffer(pcmFormat: WAVEncoder.captureFormat,
                                               frameCapacity: 16_000) else {
                    print("could not synthesise test audio"); exit(1)
                }
                b.frameLength = 16_000
                print("no file given -- sending 1s of silence (expect setupComplete, no text)")
                audio = b
            }

            let echo = Settings.load().autoDetectLanguage
            let started = ContinuousClock.now
            let stamp = { @Sendable in
                let d = started.duration(to: .now).components
                return String(format: "%6.2fs", Double(d.seconds) + Double(d.attoseconds) / 1e18)
            }
            let t = GeminiLiveTranslator(apiKey: key, model: Settings.geminiModel,
                                         echoTargetLanguage: echo) { raw in
                print("\(stamp())  \u{1B}[90m<- \(raw)\u{1B}[0m")
            }
            let seconds = Double(audio.frameLength) / WAVEncoder.captureFormat.sampleRate
            print("model:    \(Settings.geminiModel)")
            print("endpoint: \(GeminiLiveTranslator.endpoint.absoluteString)")
            print("echo:     \(echo) (follows Detect English Automatically)")
            print("audio:    \(String(format: "%.1f", seconds))s + 3s of trailing silence, streamed in real time")

            // Real time, not as fast as possible: the server's turn detection
            // runs on the audio's own clock. The trailing silence is not
            // padding for its own sake -- the model does not flush on
            // `audioStreamEnd`, and without it the last sentence of a
            // recording is never transcribed or translated.
            let (stream, feed) = AsyncStream.makeStream(of: AudioChunk.self)
            var chunks = slice(audio, frames: 1_600)
            if let silence = AVAudioPCMBuffer(pcmFormat: WAVEncoder.captureFormat, frameCapacity: 48_000) {
                silence.frameLength = 48_000
                chunks += slice(silence, frames: 1_600)
            }
            let feeder = Task {
                for c in chunks {
                    feed.yield(c)
                    try? await Task.sleep(for: .milliseconds(100))
                }
                feed.finish()
            }

            var source = "", target = "", failure: String?
            for await delta in t.translate(stream) {
                switch delta {
                case .source(let x, let lang):
                    source += x
                    print("\(stamp())  \u{1B}[1mIN \u{1B}[0m(\(lang ?? "?")) \(x)")
                case .target(let x, let lang):
                    target += x
                    print("\(stamp())  \u{1B}[1;32mOUT\u{1B}[0m(\(lang ?? "?")) \(x)")
                case .turnEnd:
                    print("\(stamp())  -- turn end --")
                case .reconnecting:
                    print("\(stamp())  -- reconnecting --")
                case .failed(let m):
                    failure = m
                }
            }
            feeder.cancel()
            if let failure { print("FAILED: \(failure)"); exit(1) }
            print("\nIN  \(source.isEmpty ? "(empty)" : source)")
            print("OUT \(target.isEmpty ? "(empty)" : target)")
            exit(0)
        }

        if let i = CommandLine.arguments.firstIndex(of: "--translate-text") {
            let text = CommandLine.arguments.count > i+1 ? CommandLine.arguments[i+1]
                                                         : "それでは本日の定例会議を始めます。"
            let provider = selectedProvider() ?? .apple
            if provider.isAudioNative {
                let test = provider.isLiveStream ? "--gemini-test" : "--omni-test"
                print("\(provider.rawValue) takes audio, not text -- use \(test) <file.wav>")
                exit(1)
            }
            if let why = provider.unusableReason {
                print("\(provider.rawValue) is not usable: \(why)"); exit(1)
            }
            let t = provider.makeTranslator(glossary: .empty)
            let (out, ttfb) = await time(t, text)
            print("provider: \(provider.displayName)")
            print("JA \(text)")
            print("EN \(out)   [ttfb \(ttfb)]")
            exit(0)
        }

        // Side-by-side comparison across every configured backend. This is the
        // only honest way to answer "is provider X good enough for my meetings".
        if CommandLine.arguments.contains("--compare") {
            let fixtures = Fixtures.japaneseMeetingUtterances
            // Audio-native backends cannot be compared on text fixtures at
            // all, so they are excluded rather than shown failing.
            let available = TranslationProvider.allCases.filter { $0.isUsable && !$0.isAudioNative }
            for p in TranslationProvider.allCases where !p.isUsable && !p.isAudioNative {
                print("skipping \(p.rawValue): \(p.unusableReason ?? "unusable")")
            }
            // Load the on-device LLM's weights before timing, or the first
            // fixture pays for the load and the mean TTFB is a lie.
            if available.contains(.foundation) { FoundationModelTranslator.prewarm() }
            if available.contains(.ollama) { OllamaTranslator.prewarm() }
            print("comparing \(available.count) backend(s) over \(fixtures.count) utterances\n")

            var totals: [TranslationProvider: (Duration, Int)] = [:]
            for (n, ja) in fixtures.enumerated() {
                print("\u{1B}[1m\(n+1). \(ja)\u{1B}[0m")
                for provider in available {
                    let t = provider.makeTranslator(glossary: .empty)
                    let (out, ttfb) = await time(t, ja)
                    let prior = totals[provider] ?? (.zero, 0)
                    totals[provider] = (prior.0 + ttfb, prior.1 + 1)
                    print("   \(pad(provider.rawValue))  \(out)")
                }
                print("")
            }
            print("mean time-to-first-token:")
            for (provider, (total, count)) in totals where count > 0 {
                print("   \(pad(provider.rawValue))  \(total / count)")
            }
            exit(0)
        }

        if let i = CommandLine.arguments.firstIndex(of: "--pipeline") {
            let bundle  = CommandLine.arguments.count > i+1 ? CommandLine.arguments[i+1] : "global"
            let seconds = CommandLine.arguments.count > i+2 ? Double(CommandLine.arguments[i+2]) ?? 30 : 30
            let glossary = Glossary.loadUser()
            print("glossary: \(glossary.entries.count) term(s) from \(AppPaths.glossaryFile.path)")
            let provider = selectedProvider() ?? Settings.load().provider
            let translator = provider.makeTranslator(glossary: glossary)
            print("translator: \(provider.displayName)\(provider.isUsable ? "" : " -- \(provider.unusableReason ?? "unusable"), fell back to on-device")")
            if provider == .foundation { FoundationModelTranslator.prewarm() }
            if provider == .ollama { OllamaTranslator.prewarm() }
            let stt  = try await AppleTranscriber(locale: Locale(identifier: "ja-JP"),
                                                  contextualStrings: glossary.sourceTerms)
            let tap  = SystemAudioTap(bundleIDs: bundle == "global" ? [] : [bundle],
                                      outputFormat: stt.inputFormat)
            let gate = SegmentGate()

            try await stt.start()
            try tap.start()
            print("pipeline running on \(bundle) for \(seconds)s")

            let pump  = Task { for await c in tap.buffers { await stt.feed(c) } }
            let feed  = Task { for await s in stt.segments { await gate.ingest(s) } }
            let timer = Task { while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500)); await gate.tick() } }

            let hearing = Task {
                for await s in gate.hearing where !s.isEmpty {
                    print("  \u{1B}[90m... \(s)\u{1B}[0m")
                }
            }
            let driver = Task {
                var history: [(source: String, target: String)] = []
                for await ev in gate.events {
                    switch ev {
                    case .translate(let id, let source, let provisional):
                        let clock = ContinuousClock(); let begin = clock.now
                        var out = ""; var first: Duration?
                        for await d in translator.translate(source, context: history.suffix(4).map { $0 }) {
                            if case .text(let t) = d { if first == nil { first = clock.now - begin }; out += t }
                            if case .failed(let e, _) = d { out = "[translation failed: \(e)]" }
                        }
                        print("\u{1B}[1mJA\u{1B}[0m \(source)")
                        print("\u{1B}[1;32mEN\u{1B}[0m \(out)\(provisional ? "  (provisional)" : "")  [ttfb \(first?.description ?? "n/a")]")
                        history.append((source, out))
                        _ = id
                    case .settled:
                        break
                    }
                }
            }

            try? await Task.sleep(for: .seconds(seconds))
            try tap.stop(); pump.cancel(); timer.cancel()
            await stt.finish()
            try? await Task.sleep(for: .seconds(2))
            feed.cancel(); driver.cancel(); hearing.cancel()
            print("--- pipeline complete ---")
            exit(0)
        }


        print(usage)
        exit(0)
    }
}
