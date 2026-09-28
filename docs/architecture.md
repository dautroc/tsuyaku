# Tsuyaku Architecture

Tsuyaku is a macOS menu-bar app that captures another application's audio output, transcribes it on-device with Apple's `SpeechAnalyzer`, translates the recognized Japanese into English, and renders the result as a floating, always-on-top subtitle panel.

This document describes the architecture using Mermaid diagrams. All diagrams are also rendered as PNGs in [`docs/assets/`](./assets/) for quick reference.

---

## Table of contents

1. [High-level data flow](#1-high-level-data-flow)
2. [Runtime pipeline single-language mode](#2-runtime-pipeline-single-language-mode)
3. [Runtime pipeline auto-detect mode](#3-runtime-pipeline-auto-detect-mode)
4. [Component responsibilities](#4-component-responsibilities)
5. [Translation provider hierarchy](#5-translation-provider-hierarchy)
6. [Audio capture and recovery](#6-audio-capture-and-recovery)
7. [Configuration and secrets](#7-configuration-and-secrets)
8. [CLI diagnostics](#8-cli-diagnostics)

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

    subgraph Speech["On-device speech recognition"]
        Factory["TranscriberFactory"]
        JaSTT["AppleTranscriber<br/>ja-JP"]
        EnSTT["AppleTranscriber<br/>en-US"]
    end

    subgraph Pipeline["Pipeline"]
        GateJa["SegmentGate<br/>Japanese"]
        GateEn["SegmentGate<br/>English"]
        Picker["LanguagePicker<br/>auto-detect"]
    end

    subgraph Translation["Translation backend"]
        Provider["TranslationProvider"]
        Apple["AppleTranslator<br/>on-device NMT"]
        Foundation["FoundationModelTranslator<br/>Apple Intelligence"]
        Ollama["OllamaTranslator<br/>local LLM"]
        Messages["MessagesAPITranslator<br/>Claude / DeepSeek"]
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

    Factory -->|single or dual| JaSTT
    Factory -.->|when auto-detect| EnSTT

    JaSTT -->|Segment| GateJa
    EnSTT -->|Segment| GateEn

    GateJa -->|Event| Picker
    GateEn -->|Event| Picker

    Picker -->|DecidedEvent| Provider
    Provider --> Apple
    Provider --> Foundation
    Provider --> Ollama
    Provider --> Messages

    Apple -->|TranslationDelta| Store
    Foundation -->|TranslationDelta| Store
    Ollama -->|TranslationDelta| Store
    Messages -->|TranslationDelta| Store

    Store --> View
    View --> Panel
    Panel -->|display| User[(User)]

    AppDelegate{{AppDelegate}} -->|owns| Menu
    AppDelegate -->|owns / shows| Panel
    AppDelegate -->|creates| Store
    AppDelegate -->|creates / toggles| PipelineController
```

---

## 2. Runtime pipeline (single-language mode)

When automatic English detection is **off**, one recognizer runs and every translatable segment is sent straight to the configured translator.

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
        opt complete sentence found
            Gate->>PC: Event.translate(id, source, provisional)
            PC->>Store: beginLine(utterance: id, source, language)
            PC->>T: translate(source, context: history)
            loop streaming deltas
                T->>PC: .text(delta)
                PC->>Store: append(utterance: id, delta)
            end
            T->>PC: .done
            PC->>Store: finishLine(utterance: id)
            opt accumulated target not empty
                PC->>PC: append to history context
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

---

## 3. Runtime pipeline (auto-detect mode)

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

---

## 4. Component responsibilities

```mermaid
classDiagram
    direction TB

    class AppDelegate {
        +SubtitleStore store
        +FloatingPanel panel
        +PipelineController controller
        +Settings settings
        +Set~TranslationProvider~ providersWithKeys
        +applicationDidFinishLaunching()
        +toggle()
        +buildMenu()
        +loadSettings()
    }

    class PipelineController {
        +SubtitleStore store
        +Settings settings
        +SystemAudioTap tap
        +[AppleTranscriber] transcribers
        +[Task] tasks
        +start()
        +stop()
        +handleRecovery(event)
        -makeTranslator(glossary)
        -consume(events, translator)
    }

    class SubtitleStore {
        +[SubtitleLine] history
        +[SubtitleLine] live
        +String hearing
        +Bool isRunning
        +String status
        +String notice
        +SpokenLanguage activeLanguage
        +beginLine(utterance:source:provisional:language)
        +append(utterance:delta)
        +finishLine(utterance)
        +settle(utterance)
        +clear()
    }

    class FloatingPanel {
        +init(store)
        +orderFrontRegardless()
        +recoverIfOffScreen()
    }

    class SubtitleView {
        +ObservedObject store
    }

    class SystemAudioTap {
        +AsyncStream~AudioChunk~ buffers
        +start()
        +stop()
        -buildGraph()
        -teardownGraph()
        -checkForStall()
        -rebuild(attempt)
    }

    class TranscriberFactory {
        +make(primary:secondary:...) Prepared
    }

    class AppleTranscriber {
        +AsyncStream~Segment~ segments
        +feed(AudioChunk)
        +start()
        +finish()
    }

    class SegmentGate {
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

    class Translator {
        <<protocol>>
        +translate(text, context) AsyncStream~TranslationDelta~
    }

    class Settings {
        +Locale sourceLocale
        +Locale secondaryLocale
        +Bool autoDetectLanguage
        +TranslationProvider provider
        +Glossary glossary
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
        +isUsable
        +makeTranslator(glossary) Translator
    }

    class CLI {
        +run()
    }

    AppDelegate --> PipelineController
    AppDelegate --> SubtitleStore
    AppDelegate --> FloatingPanel
    AppDelegate --> Settings

    PipelineController --> SystemAudioTap
    PipelineController --> AppleTranscriber
    PipelineController --> SegmentGate
    PipelineController --> LanguagePicker
    PipelineController --> Translator
    PipelineController --> SubtitleStore

    TranscriberFactory --> AppleTranscriber
    AppleTranscriber --> SegmentGate
    SegmentGate --> LanguagePicker
    LanguagePicker --> Translator
    Translator --> SubtitleStore
    SubtitleStore --> SubtitleView
    SubtitleView --> FloatingPanel

    TranslationProvider ..> Translator
    Settings --> TranslationProvider
```

---

## 5. Translation provider hierarchy

The app ships with five translation backends. The user's choice is stored in `Settings`; secrets live in the Keychain.

```mermaid
flowchart TB
    subgraph Keychain["Keychain"]
        AnthropicKey["anthropic"]
        DeepSeekKey["deepseek"]
    end

    subgraph Providers["TranslationProvider"]
        Apple["apple"]
        Foundation["foundation"]
        Ollama["ollama"]
        Anthropic["anthropic"]
        DeepSeek["deepseek"]
    end

    subgraph Backends["Translator implementations"]
        AT["AppleTranslator"]
        FMT["FoundationModelTranslator"]
        OT["OllamaTranslator"]
        MAT["MessagesAPITranslator"]
    end

    Apple --> AT
    Foundation -->|if available| FMT
    Foundation -->|else degrade| AT
    Ollama --> OT
    Anthropic -->|read key| AnthropicKey
    Anthropic --> MAT
    DeepSeek -->|read key| DeepSeekKey
    DeepSeek --> MAT

    MAT -->|api.anthropic.com| AnthropicCloud["Anthropic Messages API"]
    MAT -->|api.deepseek.com/anthropic| DeepSeekCloud["DeepSeek Anthropic-compatible API"]
    OT -->|127.0.0.1:11434| OllamaServer["Ollama server"]
    AT -->|Apple Translation framework| OnDeviceNMT["On-device NMT model"]
    FMT -->|FoundationModels framework| AppleIntelligence["Apple Intelligence"]
```

---

## 6. Audio capture and recovery

`SystemAudioTap` builds a Core Audio process tap and aggregate device, converts the audio to the recognizer's expected format, and survives output-device changes (for example, Bluetooth headphones disconnecting).

```mermaid
flowchart TB
    subgraph CoreAudio["Core Audio HAL"]
        Tap["CATapDescription / process tap"]
        Aggregate["Aggregate device"]
        IOProc["IOProc callback"]
    end

    Tap --> Aggregate --> IOProc
    IOProc -->|raw PCM| Converter["FormatConverter"]
    Converter -->|AudioChunk| Downstream["AppleTranscriber"]

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

---

## 7. Configuration and secrets

User settings are persisted in `UserDefaults`. API keys are stored in the Keychain and are never written to defaults.

```mermaid
flowchart LR
    subgraph UserDefaults["UserDefaults"]
        Locales["source / secondary locale"]
        Detect["autoDetectLanguage"]
        Provider["translationProvider"]
        Latency["maxLatencySeconds"]
        Context["contextTurns"]
        Glossary["glossary"]
    end

    subgraph Keychain["Keychain"]
        Anthropic["anthropic"]
        DeepSeek["deepseek"]
    end

    UserDefaults --> Settings["Settings.load() / save()"]
    Keychain --> Settings
    Keychain --> TranslationProvider["TranslationProvider.hasKey"]

    Settings --> AppDelegate["AppDelegate"]
    Settings --> PipelineController["PipelineController"]
    TranslationProvider --> PipelineController
```

---

## 8. CLI diagnostics

The same executable can run diagnostic subcommands instead of launching the GUI. These exercise one layer at a time and are useful for verifying setup.

```mermaid
flowchart LR
    CLI["CLI.run()"] --> Probe["--probe"]
    CLI --> Install["--install-assets"]
    CLI --> Preflight["--apple-preflight"]
    CLI --> SetKey["--set-key"]
    CLI --> Capture["--capture"]
    CLI --> Listen["--listen"]
    CLI --> ListenDual["--listen-dual"]
    CLI --> Pipeline["--pipeline"]
    CLI --> StoreSelfTest["--store-selftest"]
    CLI --> DeviceSwitchTest["--device-switch-test"]
    CLI --> TranslateText["--translate-text"]
    CLI --> Compare["--compare"]

    Probe --> CoreAudio["CoreAudioUtil"]
    Probe --> Speech["SpeechAnalyzer"]
    Probe --> Translation["Translation framework"]

    Install --> AssetGate["AssetGate"]
    Listen --> SystemAudioTap["SystemAudioTap"]
    Listen --> AppleTranscriber["AppleTranscriber"]
    Pipeline --> PipelineController["PipelineController"]
    StoreSelfTest --> SubtitleStore["SubtitleStore"]
    DeviceSwitchTest --> SystemAudioTap
```
