# Tsuyaku

Live Japanese → English subtitles for meetings on macOS 26. On-device speech recognition via Apple `SpeechAnalyzer`, translation through Claude/Apple/DeepSeek, and Core Audio process taps for audio capture. No cloud STT, no screen recording, no virtual audio driver, no Xcode.

# Overview

Tsuyaku sits in your menu bar and streams translated subtitles for Japanese speech happening in any meeting app. It uses Apple's on-device `ja-JP` speech model, pipes the transcript through a translator of your choice, and displays the result in a small floating panel.

Audio is captured with Core Audio process taps, so it does not need a virtual cable, screen recording, or echo cancellation. A self-signed code-signing identity keeps macOS TCC grants stable across rebuilds.

# Quick start

```bash
./scripts/make-cert.sh          # once: create a self-signed code-signing identity
make bundle                     # build, assemble, and sign the app
make check-dr                   # must print OK
./build/Tsuyaku.app/Contents/MacOS/Tsuyaku --install-assets   # install ja-JP speech model
open build/Tsuyaku.app          # menu bar app
```

On first launch, accept the prompt to install the Japanese → English translation model.

Run diagnostics one layer at a time:

```bash
./build/Tsuyaku.app/Contents/MacOS/Tsuyaku --probe
./build/Tsuyaku.app/Contents/MacOS/Tsuyaku --apple-preflight
./build/Tsuyaku.app/Contents/MacOS/Tsuyaku --listen global 20
./build/Tsuyaku.app/Contents/MacOS/Tsuyaku --pipeline global 60
```

Run self-checks without a meeting:

```bash
make test
./build/Tsuyaku.app/Contents/MacOS/Tsuyaku --device-switch-test
```

# Feature

| Feature | Description |
|---|---|
| On-device speech recognition | Japanese `ja-JP` recognition using Apple's `Speech` framework; free, offline, and private. |
| Real-time translation | Four backends: Apple (on-device, free), DeepSeek (`deepseek-flash`), Anthropic (`claude-haiku-4-5`), and OpenCode Go (`deepseek-v4.1-flash`, default when a key is set). |
| Core Audio process taps | Captures meeting audio without screen recording, virtual cables, or echo cancellation. |
| Floating subtitle panel | Resizable subtitle window shown/hidden from the menu bar. |
| Automatic English detection | Optional concurrent `en-US` recognizer shows English turns verbatim; off by default. |
| Gemini Live Translate | Optional `geminiLive` backend: streams meeting audio to `gemini-3.5-live-translate-preview`, which transcribes and translates it in the cloud with no on-device recognizer. |
| Glossary | **Edit Glossary…** opens `glossary.txt`, one `ラクスル = Raksul` per line. Terms help recognition hear names and keep translations consistent. Changes apply at the next Start. |
| Capture From | Subtitle one app (Zoom, Teams, a browser) instead of everything the Mac plays. The menu lists the apps currently playing audio. |
| Saved transcripts | Each session is saved as Markdown in `~/Library/Application Support/Tsuyaku/Transcripts` as its lines settle, beyond the panel's 500-line history. **Save Transcripts** turns this off; **Open Transcripts Folder** shows them. |
| Settings persistence | Provider choice and API keys in the keychain survive relaunches. |

Choose a backend from the menu bar or with `--provider`. Store API keys in the keychain with:

```bash
./build/Tsuyaku.app/Contents/MacOS/Tsuyaku --set-key <provider> <key>
```

Supported key-backed providers: `anthropic`, `deepseek`, `opencodeGo`, `qwenOmni`, `geminiLive`. Use `--opencode-model <id>` to pick a different OpenCode Go model.

Before relying on Gemini Live in a meeting, check the key and model against a recording:

```bash
./build/Tsuyaku.app/Contents/MacOS/Tsuyaku --capture global 20
./build/Tsuyaku.app/Contents/MacOS/Tsuyaku --gemini-test /tmp/tsuyaku-capture.wav
```
