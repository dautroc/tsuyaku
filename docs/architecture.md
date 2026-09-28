# Tsuyaku Architecture

Tsuyaku is a macOS menu-bar app that captures another application's audio output, transcribes it on-device with Apple's `SpeechAnalyzer`, translates the recognized Japanese into English, and renders the result as a floating, always-on-top subtitle panel.

A second backend family, **Qwen Omni**, skips transcription entirely and translates straight from audio to English text.

---

## Table of contents

1. [High-level data flow](#1-high-level-data-flow)
2. [Runtime pipeline (single-language STT)](#2-runtime-pipeline-single-language-stt)
3. [Runtime pipeline (auto-detect STT)](#3-runtime-pipeline-auto-detect-stt)
4. [Runtime pipeline (audio-native Qwen Omni)](#4-runtime-pipeline-audio-native-qwen-omni)
5. [Component responsibilities](#5-component-responsibilities)
6. [Translation provider hierarchy](#6-translation-provider-hierarchy)
7. [Audio capture and recovery](#7-audio-capture-and-recovery)
8. [Configuration and secrets](#8-configuration-and-secrets)
9. [CLI diagnostics](#9-cli-diagnostics)

---

## 1. High-level data flow

```mermaid
flowchart TB
    subgraph Input["Audio input"]
        App["Meeting / media app"]
    end

    subgraph Capture["Capture"]
        Tap["SystemAudioTap<br/>Core Audio process tap"]
        Converter["FormatConverter"]
    end

    subgraph STT["On-device speech recognition<br/>(text backends)"]
        Factory["TranscriberFactory"]
        JaSTT["AppleTranscriber<br/>ja-JP"]
        EnSTT["AppleTranscriber<br/>en-US"]
    end

    subgraph Pipeline["Pipeline"]
        JaGate["SegmentGate<br/>Japanese"]
        EnGate["SegmentGate<br/>English"]
        Picker["LanguagePicker"]
        Segmenter["VoiceSegmenter<br/>audio-native"]
    end

    subgraph TextTranslate["Text translation backends"]
        TextProvider["TranslationProvider"]
        Apple["AppleTranslator<br/>on-device NMT"]
        Foundation["FoundationModelTranslator<br/>Apple Intelligence"]
        Ollama["OllamaTranslator<br/>local LLM"]
        Messages["MessagesAPITranslator<br/>Claude / DeepSeek / OpenCode Go"]
    end

    subgraph AudioTranslate["Audio-native translation"]
        Omni["QwenOmniTranslator<br/>speech → English"]
    end

    subgraph UI["User interface"]
        Store["SubtitleStore<br/>view model"]
        View["SubtitleView<br/>SwiftUI"]
        Panel["FloatingPanel<br/>always-on-top"]
        Menu["Menu bar menu"]
    end

    App -->|audio output| Tap
    Tap -->|raw buffers| Converter
    Converter -->|AudioChunk| Factory

    Factory -->|single| JaSTT
    Factory -.->|dual / auto-detect| EnSTT

    JaSTT -->|Segment| JaGate
    EnSTT -->|Segment| EnGate

    JaGate -->|Event| Picker
    EnGate -->|Event| Picker

    Picker -->|DecidedEvent| TextProvider
    TextProvider --> Apple
    TextProvider --> Foundation
    TextProvider --> Ollama
    TextProvider --> Messages

    Apple -->|TranslationDelta| Store
    Foundation -->|TranslationDelta| Store
    Ollama -->|TranslationDelta| Store
    Messages -->|TranslationDelta| Store

    Converter -->|AudioChunk| Segmenter
    Segmenter -->|Utterance WAV| Omni
    Omni -->|TranslationDelta| Store

    Store --> View
    View --> Panel
    Panel -->|display| User[(User)]

    AppDelegate{{AppDelegate}} -->|owns| Menu
    AppDelegate -->|owns / shows| Panel
    AppDelegate -->|creates| Store
    AppDelegate -->|creates / toggles| PipelineController
```

`PipelineController` decides at startup which branch to build:

- Text providers (`apple`, `foundation`, `ollama`, `anthropic`, `deepseek`, `opencodeGo`) build an `AppleTranscriber`-based graph.
- The audio-native provider (`qwenOmni`) builds a `VoiceSegmenter`-based graph instead and bypasses speech recognition.

---

## 2. Runtime pipeline (single-language STT)

When automatic English detection is **off**, one recognizer runs and every translatable segment is sent to the configured translator.

```mermaid
sequenceDiagram
    participant PC as PipelineController
    participant Tap as SystemAudioTap
    participant STT as AppleTranscriber
    participant Gate as SegmentGate
    participant T as Translator
    participant Store as SubtitleStore

    PC->>Tap: start(bundleIDs, outputFormat)
    PC->>STT: start()

    loop Audio buffers arrive
        Tap->>STT: feed(AudioChunk)
    end

    loop Segments emitted
        STT->>Gate: ingest(Segment)
        Gate->>Gate: split sentences, track watermark
        opt complete sentence or tail flush
            Gate->>PC: Event.translate(id, source, provisional)
            PC->>Store: beginLine(utterance: id, source, provisional, language)
            alt language == .en
                PC->>Store: finishLine(utterance: id)
            else
                PC->>T: translate(source, context: history)
                loop streaming deltas
                    T->>PC: .text(delta) / .failed(msg) / .done
                    PC->>Store: append / fail
                end
                PC->>Store: finishLine(utterance: id)
                opt non-empty target
                    PC->>PC: append (source, target) to history
                end
            end
        end
        opt utterance finalized
            Gate->>PC: Event.settled(id)
            PC->>Store: settle(utterance: id)
        end
    end

    PC->>Tap: stop()
    PC->>STT: finish()
```

`SegmentGate` cuts only at sentence terminators so that partial Japanese clauses (SOV word order) are not translated before the verb arrives. A `maxLatency` backstop flushes the trailing fragment anyway.

---

## 3. Runtime pipeline (auto-detect STT)

When automatic English detection is **on**, the same audio is fed to both a Japanese and an English recognizer. A `LanguagePicker` decides, per spoken turn, which recognizer to render.

```mermaid
flowchart LR
    Tap["SystemAudioTap"] -->|AudioChunk| Feed["sequential feed"]
    Feed --> JaSTT["AppleTranscriber ja-JP"]
    Feed --> EnSTT["AppleTranscriber en-US"]

    JaSTT -->|Segment| JaGate["SegmentGate ja"]
    EnSTT -->|Segment| EnGate["SegmentGate en"]

    JaSTT -->|hearing text| Picker
    EnSTT -->|hearing text| Picker

    JaGate -->|Event.translate / settled| Picker
    EnGate -->|Event.translate / settled| Picker

    Picker -->|DecidedEvent| Translator
    Translator -->|TranslationDelta| Store["SubtitleStore"]

    Picker -->|hearing| Store

    Store --> Panel["FloatingPanel / SubtitleView"]

    style Picker fill:#2d4a3e,stroke:#4caf50
    style Store fill:#2d3e50,stroke:#2196f3
```

Both gates ingest every segment so their sentence watermarks stay in sync. `LanguagePicker` uses `LanguageScore.japaneseness` to score the Japanese recognizer's text; English turns are shown verbatim without spending translation tokens. Each gate has its own tuning: Japanese uses a 7-second backstop and East-Asian terminators; English uses a 2.5-second backstop and ASCII terminators with abbreviation guards.

---

## 4. Runtime pipeline (audio-native Qwen Omni)

The `qwenOmni` provider skips transcription. Audio is cut into utterances by an energy-based voice-activity detector and sent straight to Qwen Omni on Alibaba Cloud Model Studio.

```mermaid
flowchart LR
    Tap["SystemAudioTap<br/>16 kHz mono"] -->|AudioChunk| Segmenter["VoiceSegmenter<br/>energy-based VAD"]
    Segmenter -->|Utterance WAV| Omni["QwenOmniTranslator"]
    Omni -->|TranslationDelta| Store["SubtitleStore"]
    Store --> Panel["FloatingPanel / SubtitleView"]
```

On this path:

- There is no source text; rows carry an empty source and the transcript copy holds English only.
- There is no `hearing` preview, because partial hypotheses are a recognizer feature.
- Auto-detect is inert; the model handles mixed-language speech itself.

---

## 5. Component responsibilities

```mermaid
classDiagram
    direction TB

    class AppDelegate {
        +SubtitleStore store
        +FloatingPanel panel
        +PipelineController controller
        +Settings settings
        +TranslationDownloadHost downloadHost
        +Set~TranslationProvider~ providersWithKeys
        +NSStatusItem statusItem
        +AnyCancellable runningObserver
        +applicationDidFinishLaunching()
        +toggle()
        +buildMenu()
        +loadSettings()
        +rebuildController()
        +installModel()
        +copyTranscript()
        +clear()
    }

    class PipelineController {
        +SubtitleStore store
        +Settings settings
        +SystemAudioTap? tap
        +[AppleTranscriber] transcribers
        +VoiceSegmenter? segmenter
        +[Task] tasks
        +start() async
        +stop()
        +handleRecovery(event)
        -startAudioNative(glossary)
        -makeTranslator(glossary) any Translator
        -consume(events, language, using translator)
        -consume(decided, using translator)
        -consume(utterances, using audioTranslator)
    }

    class SubtitleStore {
        +[SubtitleLine] history
        +[SubtitleLine] live
        +String hearing
        +Bool isRunning
        +String status
        +String? notice
        +SpokenLanguage? activeLanguage
        +Bool autoDetecting
        +Int settledCount
        +beginLine(utterance:source:provisional:language)
        +append(utterance:delta)
        +fail(utterance:message)
        +finishLine(utterance)
        +settle(utterance)
        +clear()
        +flashNotice(text)
        +headerLabel
        +transcriptMarkdown
    }

    class FloatingPanel {
        +init(store)
        +orderFrontRegardless()
        +recoverIfOffScreen()
        -positionAtBottomCentre()
    }

    class SubtitleView {
        +ObservedObject store
    }

    class SystemAudioTap {
        +AsyncStream~AudioChunk~ buffers
        +start()
        +stop()
        -createTap()
        -createAggregateDevice()
        -installIOProc()
        -addDefaultDeviceListener()
        -devicesChanged()
        -rebuild(attempt)
        -checkForStall()
        +simulateCaptureLoss()
    }

    class TranscriberFactory {
        <<enum>>
        +Prepared
        +make(primary:secondary:primaryTerms:secondaryTerms:onProgress) Prepared
        +sharedFormat(modules) AVAudioFormat?
    }

    class AppleTranscriber {
        +AVAudioFormat inputFormat
        +SpokenLanguage language
        +AsyncStream~Segment~ segments
        +init(module, language, inputFormat, contextualStrings)
        +init(locale, contextualStrings)
        +start()
        +feed(AudioChunk)
        +finish()
        +analyze(file)
    }

    class SegmentGate {
        +GateConfig config
        +AsyncStream~Event~ events
        +AsyncStream~String~ hearing
        +ingest(Segment)
        +tick()
    }

    class LanguagePicker {
        +AsyncStream~DecidedEvent~ decided
        +AsyncStream~String~ hearing
        +observe(Segment)
        +submit(Event, from)
        +hearing(String, from)
        +tick()
    }

    class PickerState {
        +Tuning tuning
        +choose() Choice
        +submit(Event, from, now) Outcome
        +observe(Segment)
        +tick(now)
    }

    class LanguageScore {
        <<enum>>
        +japaneseness(text) Double
    }

    class Translator {
        <<protocol>>
        +translate(text, context) AsyncStream~TranslationDelta~
    }

    class AudioTranslator {
        <<protocol>>
        +translate(audio: Data, context: [String]) AsyncStream~TranslationDelta~
    }

    class VoiceSegmenter {
        +Config config
        +AsyncStream~Utterance~ utterances
        +feed(AudioChunk)
        +finish()
    }

    class QwenOmniTranslator {
        +String apiKey
        +URL endpoint
        +String model
        +translate(audio, context)
    }

    class Settings {
        +Locale sourceLocale
        +Locale secondaryLocale
        +Bool autoDetectLanguage
        +Int englishMaxLatencyMillis
        +Double languageThreshold
        +Bool confidenceTiebreak
        +[String] targetBundleIDs
        +Int maxLatencySeconds
        +Int contextTurns
        +TranslationProvider provider
        +Glossary glossary
        +static String omniModel
        +load() Settings
        +save()
    }

    class TranslationProvider {
        <<enum>>
        apple
        foundation
        ollama
        anthropic
        deepseek
        opencodeGo
        qwenOmni
        +String? keychainAccount
        +Bool needsKey
        +Bool hasKey
        +String? unusableReason
        +Bool isAudioNative
        +Bool isUsable
        +makeTranslator(glossary) any Translator
        +makeAudioTranslator(glossary) any AudioTranslator?
    }

    class TranslationDownloadHost {
        +present()
    }

    class CLI {
        +run() async
    }

    AppDelegate --> PipelineController
    AppDelegate --> SubtitleStore
    AppDelegate --> FloatingPanel
    AppDelegate --> Settings
    AppDelegate --> TranslationDownloadHost

    PipelineController --> SystemAudioTap
    PipelineController --> AppleTranscriber
    PipelineController --> SegmentGate
    PipelineController --> LanguagePicker
    PipelineController --> Translator
    PipelineController --> AudioTranslator
    PipelineController --> VoiceSegmenter
    PipelineController --> SubtitleStore

    TranscriberFactory --> AppleTranscriber
    AppleTranscriber --> SegmentGate
    SegmentGate --> LanguagePicker
    LanguagePicker --> Translator
    Translator --> SubtitleStore
    AudioTranslator --> SubtitleStore
    SubtitleStore --> SubtitleView
    SubtitleView --> FloatingPanel

    TranslationProvider ..> Translator
    TranslationProvider ..> AudioTranslator
    Settings --> TranslationProvider
```

---

## 6. Translation provider hierarchy

The app ships with six providers. The user's choice is stored in `Settings`; API keys live in the Keychain.

```mermaid
flowchart TB
    subgraph Keychain["Keychain"]
        AnthropicKey["anthropic"]
        DeepSeekKey["deepseek"]
        OpenCodeGoKey["opencodeGo"]
        DashscopeKey["dashscope"]
    end

    subgraph Providers["TranslationProvider"]
        Apple["apple"]
        Foundation["foundation"]
        Ollama["ollama"]
        Anthropic["anthropic"]
        DeepSeek["deepseek"]
        OpenCodeGo["opencodeGo"]
        QwenOmni["qwenOmni"]
    end

    subgraph Backends["Translator implementations"]
        AT["AppleTranslator"]
        FMT["FoundationModelTranslator"]
        OT["OllamaTranslator"]
        MAT["MessagesAPITranslator"]
        QT["QwenOmniTranslator"]
    end

    Apple --> AT
    Foundation -->|if available| FMT
    Foundation -->|else degrade| AT
    Ollama --> OT
    Anthropic -->|read key| AnthropicKey
    Anthropic --> MAT
    DeepSeek -->|read key| DeepSeekKey
    DeepSeek --> MAT
    OpenCodeGo -->|read key| OpenCodeGoKey
    OpenCodeGo --> MAT
    QwenOmni -->|read key| DashscopeKey
    QwenOmni --> QT

    MAT -->|api.anthropic.com| AnthropicCloud["Anthropic Messages API"]
    MAT -->|api.deepseek.com/anthropic| DeepSeekCloud["DeepSeek Anthropic-compatible API"]
    MAT -->|opencode.ai/zen/go| OpenCodeGoCloud["OpenCode Go Messages API"]
    QT -->|dashscope-intl.aliyuncs.com| QwenCloud["Qwen Omni API"]
    OT -->|127.0.0.1:11434| OllamaServer["Ollama server"]
    AT -->|Apple Translation framework| OnDeviceNMT["On-device NMT model"]
    FMT -->|FoundationModels framework| AppleIntelligence["Apple Intelligence"]
```

`TranslationProvider.isUsable` checks more than key presence: it probes Ollama reachability and Apple Intelligence availability so unavailable backends are greyed out in the menu instead of silently degrading.

---

## 7. Audio capture and recovery

`SystemAudioTap` builds a Core Audio process tap and aggregate device, converts the audio to the downstream format, and survives output-device changes (for example, Bluetooth headphones disconnecting).

```mermaid
flowchart TB
    subgraph CoreAudio["Core Audio HAL"]
        Tap["CATapDescription / process tap"]
        Aggregate["Aggregate device"]
        IOProc["IOProc callback"]
    end

    Tap --> Aggregate --> IOProc
    IOProc -->|raw PCM| Converter["FormatConverter"]
    Converter -->|AudioChunk| Downstream["AppleTranscriber / VoiceSegmenter"]

    Watchdog["Watchdog timer<br/>stall detection"] -->|no buffer > 3s| Rebuild
    DeviceListener["Device-list listener"] -->|built-on device removed| Rebuild

    Rebuild["rebuild(attempt)"] --> Teardown["teardownGraph"]
    Teardown --> Build["buildGraph"]
    Build --> Tap

    Rebuild -->|success| RecoveryEvent["RecoveryEvent.rebuilt(device)"]
    Rebuild -->|failure| Failure["RecoveryEvent.failed(message)"]

    RecoveryEvent --> AppDelegate["AppDelegate.handleRecovery"]
    Failure --> AppDelegate
```

The tap can target a single bundle ID or all system audio except the app itself (`bundleIDs == []`). The `buffers` stream survives rebuilds; only `stop()` finishes it.

---

## 8. Configuration and secrets

User settings are persisted in `UserDefaults`. API keys are stored in the Keychain and are never written to defaults. On first launch, `Settings.load` prefers a configured cloud backend over the on-device Apple translator.

```mermaid
flowchart LR
    subgraph UserDefaults["UserDefaults"]
        Locales["source / secondary locale"]
        Detect["autoDetectLanguage"]
        EnglishLatency["englishMaxLatencyMillis"]
        Threshold["languageThreshold"]
        Tiebreak["confidenceTiebreak"]
        Bundles["targetBundleIDs"]
        Provider["translationProvider"]
        Latency["maxLatencySeconds"]
        Context["contextTurns"]
        Glossary["glossary"]
        OmniModel["omniModel"]
    end

    subgraph Keychain["Keychain"]
        Anthropic["anthropic"]
        DeepSeek["deepseek"]
        OpenCodeGo["opencodeGo"]
        Dashscope["dashscope"]
    end

    UserDefaults --> Settings["Settings.load() / save()"]
    Keychain --> Settings
    Keychain --> TranslationProvider["TranslationProvider.hasKey"]

    Settings --> AppDelegate["AppDelegate"]
    Settings --> PipelineController["PipelineController"]
    TranslationProvider --> PipelineController
```

---

## 9. CLI diagnostics

The same executable can run diagnostic subcommands instead of launching the GUI. These exercise one layer at a time and are useful for verifying setup.

```mermaid
flowchart LR
    CLI["CLI.run()"] --> Version["--version"]
    CLI --> Probe["--probe"]
    CLI --> Install["--install-assets"]
    CLI --> Preflight["--apple-preflight"]
    CLI --> SetKey["--set-key"]
    CLI --> Locale["--locale"]
    CLI --> Provider["--provider"]
    CLI --> OmniModel["--omni-model"]
    CLI --> OmniTest["--omni-test"]
    CLI --> Compare["--compare"]
    CLI --> Capture["--capture"]
    CLI --> Listen["--listen"]
    CLI --> ListenDual["--listen-dual"]
    CLI --> ListenDualFile["--listen-dual-file"]
    CLI --> Pipeline["--pipeline"]
    CLI --> StoreSelfTest["--store-selftest"]
    CLI --> DeviceSwitchTest["--device-switch-test"]
    CLI --> TranslateText["--translate-text"]

    Probe --> CoreAudio["CoreAudioUtil / CATapDescription"]
    Probe --> Speech["SpeechAnalyzer / AssetInventory"]
    Probe --> Translation["Translation framework"]

    Install --> AssetGate["AssetGate"]
    Listen --> SystemAudioTap["SystemAudioTap"]
    Listen --> AppleTranscriber["AppleTranscriber"]
    ListenDual --> DualListenDiagnostic["DualListenDiagnostic"]
    ListenDualFile --> DualListenDiagnostic
    Pipeline --> PipelineController["PipelineController"]
    StoreSelfTest --> SubtitleStore["SubtitleStore"]
    DeviceSwitchTest --> SystemAudioTap
    OmniTest --> QwenOmniTranslator["QwenOmniTranslator"]
```
