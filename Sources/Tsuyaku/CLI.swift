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
      --set-key <provider> <key>  store a key (provider: anthropic | deepseek)
      --provider <name>           apple | foundation | ollama | anthropic | deepseek (default: saved setting)
      --locale <bcp47>            speech locale for --listen / --install-assets (default: ja-JP)
      --compare                   run every configured backend over a Japanese fixture set
      --capture [bundle|global] [s]   dump captured audio to /tmp/tsuyaku-capture.wav
      --listen  [bundle|global] [s]   live transcription only, to stdout
      --listen-dual [bundle|global] [s]   ja + en side by side, with picker scores
      --listen-dual-file <path.wav>   the same, replayed from a --capture recording
      --translate-text <ja>       one-shot translation, reports TTFB
      --pipeline [bundle|global] [s]  full pipeline to stdout
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
            case .failed(let e): out = "[failed: \(e)]"
            case .done: break
            }
        }
        return (out, first ?? .zero)
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
            await MainActor.run { StoreSelfTest.run() }
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
                print("usage: --set-key <anthropic|deepseek> <key>"); exit(1)
            }
            let ok = Keychain.write(CommandLine.arguments[i+2], account: account)
            print(ok ? "\(provider.displayName) key stored in login keychain."
                     : "FAILED to store key.")
            exit(0)
        }

        if let i = CommandLine.arguments.firstIndex(of: "--translate-text") {
            let text = CommandLine.arguments.count > i+1 ? CommandLine.arguments[i+1]
                                                         : "それでは本日の定例会議を始めます。"
            let provider = selectedProvider() ?? .apple
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
            let available = TranslationProvider.allCases.filter(\.isUsable)
            for p in TranslationProvider.allCases where !p.isUsable {
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
            let glossary = Glossary(entries: ["ラクスル": "Raksul", "見積もり": "quote"])
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
                            if case .failed(let e) = d { out = "[translation failed: \(e)]" }
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
