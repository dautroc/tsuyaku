# Changelog

Notable changes to Tsuyaku. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Pre-1.0, the minor version moves when the pipeline's behaviour changes and the
patch version moves for fixes and packaging. Nothing here is API-stable.

## [Unreleased]

## [0.3.0] - 2026-09-30

Adds two translation backends -- Gemini Live Translate, the first that streams
audio, and OpenCode Go -- and ties the subtitle panel to the running session.
Every existing backend is unchanged; both new ones are opt-in.

### Added

**Gemini Live Translate backend.** `geminiLive` streams the tap's audio to
`gemini-3.5-live-translate-preview` over the Live API's bidirectional
WebSocket. The server returns both the source transcript and the English
translation, so unlike the Qwen path, rows carry the Japanese and the "hearing"
line works. It implements a new `LiveTranslator` protocol rather than
`AudioTranslator`: the model translates as it hears, so there is no finished
utterance to hand over, and the next sentence is being heard while the last is
still being translated. There is no `VoiceSegmenter` on this path.

"Detect English Automatically" becomes the model's `echoTargetLanguage`: with it
on, English turns come through verbatim; with it off, they produce nothing.

Connections last about ten minutes. On `goAway` or a dropped socket the client
reconnects with the last session-resumption handle, keeps up to five seconds of
audio buffered during the handover, and flashes "Reconnecting to Gemini…". It
gives up after five failed connections in a row and says so in the panel.

**`LiveRowSegmenter`.** Decides where subtitle rows begin and end. The
translate model sends no turn boundaries at all -- no `turnComplete`, no
`generationComplete` -- so rows are cut from the text: one row per English
sentence, the same shape the recognizer paths produce, with 2.5 s of output
silence closing a row that never reaches a sentence end. English rows take their
text from the model's echo, which lines up with those cuts, rather than from the
transcript, which runs about a second ahead of it. It is a value type with an
injected clock, and `LiveSelfTest` in `make test` replays real server traffic
through it fragment for fragment.

**`--gemini-test [file.wav]`, `--gemini-model <id>`.** Streams a recording (or
one second of silence) in real time, followed by three seconds of silence, and
prints every raw server message, with audio payloads elided, next to the deltas
parsed from it. A refused setup or a wrong model ID surfaces here as the
server's close reason, and fails at once rather than being retried.

**OpenCode Go backend.** `opencodeGo` is a text backend on OpenCode Go's
Anthropic-compatible Messages endpoint, built on `MessagesAPITranslator` like
the Claude and DeepSeek ones. It sends the `x-opencode-session` header the
gateway requires. The model defaults to `deepseek-v4.1-flash` and is chosen with
`--opencode-model <id>`.

### Changed

**The subtitle panel follows the session.** Start/Stop Subtitles and Show/Hide
Panel used to be independent, so the app could translate with nothing on screen
or show an idle panel at every launch. They are now one menu item: Start shows
the panel and runs the pipeline, Stop halts it and hides the panel. The panel
stays hidden at launch, and history survives a stop until Clear. The item's
title now follows the pipeline's real state, where it used to read "Start
Subtitles" while running.

**The panel drags from anywhere.** The history scroll view used to refuse the
drag across most of the panel's surface. The panel's size survives a relaunch;
its position does not, and it reopens at the bottom of the screen under the
pointer.

**Architecture documentation.** `docs/architecture.md` describes the pipelines,
components, providers and configuration with Mermaid diagrams, and the README
is trimmed to a quick start and feature list.

### Gemini: verified against the live API

With synthesised speech from `say`, not yet in a real meeting:

- The transcription options belong at the top level of `setup`. The translate
  guide's sample puts them inside `generationConfig`, and the server refuses
  that. `translationConfig`, `sessionResumption` and `contextWindowCompression`
  are all accepted where they are.
- Japanese source and English translation arrive interleaved, a fragment of a
  few words about once a second. The translation trails its source by about
  0.2 s; the English echo trails its source by about 1 s.
- Session-resumption handles arrive every few seconds.

### Known limitations

All of these concern the Gemini path.

**The last words before audio stops are not translated.** The model does not
flush on `audioStreamEnd`; it needs silence after the speech. That is why
`--gemini-test` pads its input, and in a meeting the tap never stops.

**Reconnection is untested.** A `goAway` is expected about every ten minutes,
and no test has run that long. Run the app for more than fifteen minutes before
relying on it for a long meeting.

**Language detection can misfire.** On one run, a short synthesised English
clip was transcribed as Thai. The English output was still right, but the row
showed Thai as its source. A longer English clip was detected correctly.

**It is billed for audio nobody hears.** The translate model responds only
with AUDIO, so the text is read from its output transcription and the audio is
thrown away, but still paid for. At the preview prices listed in September 2026
($0.0053/min input, $0.0315/min output audio), a fully translated hour costs
about $2.20.

**No glossary and no context.** The translate model takes no instructions, so
the glossary and prior-turn context that the text backends use do not reach it.

**Source text is matched to rows by arrival time.** A row's Japanese can run a
few words into the next sentence, for example "お疲れ様です。それでは本日の"
over "Thank you for your hard work." The translation itself is unaffected.

## [0.2.0] - 2026-09-18

Adds a translation backend that listens instead of reading. Everything from
0.1.0 is unchanged and still the default; the new path is opt-in.

### Added

**Qwen Omni backend: speech straight to English.** `qwenOmni` is the first
backend that is not a `Translator`. It implements a new `AudioTranslator`
protocol and takes the captured utterance as a WAV blob, so `SpeechAnalyzer` is
not in the graph at all -- `PipelineController` branches on
`TranslationProvider.isAudioNative` before it builds a transcriber, and never
downloads or starts a speech asset on this path. What it buys is a model that
hears prosody, hesitation and proper nouns that a recognizer has already
flattened into text.

**`VoiceSegmenter`, an energy-based VAD.** `SegmentGate` cuts on sentence
structure in recognized text, which on the omni path does not exist until after
the cut has been made, so boundaries have to come from the signal instead. It is
deliberately not a trained VAD: a meeting tap carries one speaker at a time
through a clean digital path with no room noise, so short-term energy against a
rolling noise floor separates speech from silence well enough and costs no
model, no asset and no inference on the audio thread. Non-speech transients are
handled downstream, by the model returning no text.

**`WAVEncoder`.** Qwen takes audio as a base64 blob with a declared container,
so each utterance carries its own RIFF header. WAV rather than a compressed
format because the encoder is twenty lines, where routing through `AVAudioFile`
for AAC would mean a temporary file per utterance in the live path.

**`--omni-test [file.wav]`, `--omni-model <id>`.** Everything about the omni
request that can be wrong -- model ID, region, the `data:;base64,` prefix, the
key's namespace -- fails in `--omni-test` with the server's own message rather
than as an empty subtitle pane during a meeting. With no file it sends one
second of silence, which still proves auth, region and framing. Model IDs here
churn (`qwen3-omni-flash`, `qwen3.5-omni-flash`), so the ID is a defaults key
rather than a constant.

### Changed

`--compare` and `--translate-text` now exclude audio-native backends rather than
showing them fail: they cannot be driven from text fixtures at all.

### Known limitations

**The omni path has not been run against the live API.** The request shape is
confirmed only as far as authentication -- the endpoint accepts and parses it --
and the WAV framing and VAD segmentation are covered by their own checks. The
round trip itself, and therefore the model ID default, is unverified. Run
`--omni-test` before a meeting depends on it.

**`qwenOmni` gives up four things the recognizer-driven paths provide**, and
they are structural, not missing work: no Japanese transcript (nothing
transcribes the source, so rows carry an empty source field and a copied
transcript holds English only), no `hearing` preview (that line is fed by a
recognizer's partial results), no auto-detect (`LanguagePicker` arbitrates
between two recognizers and there are none), and **meeting audio leaves the
machine**. The "no cloud STT" property in the README header does not hold on
this path. Every other backend still transcribes on device and sends text at
most.

## [0.1.0] - 2026-09-16

First tagged release. Live Japanese to English meeting subtitles, running
entirely on the machine except for the optional hosted translation backends.

### Added

**Audio capture without a virtual driver.** `SystemAudioTap` uses the macOS 26
Core Audio process-tap API to read another app's output directly, so there is no
BlackHole-style kernel extension to install and no screen-recording permission to
grant. Capture is per-bundle-id or global; `FormatConverter` negotiates whatever
the speech analyzer asks for, which in practice is 16 kHz mono Int16.

**On-device transcription.** `AppleTranscriber` drives `SpeechAnalyzer` /
`SpeechTranscriber` with volatile and fast results enabled, so partial text
appears while someone is still speaking. `AssetGate` installs the ja-JP model
programmatically through `AssetInventory`; audio never leaves the device.

**Four translation backends** behind one `Translator` protocol, chosen from the
menu bar: Apple's on-device `Translation` framework, Apple FoundationModels,
Ollama, and the Anthropic and DeepSeek Messages APIs. All of them stream, because
time-to-first-token is what the subtitle reader experiences, not total latency.
Keys live in the login keychain, never in a config file. `--compare` runs every
configured backend over a fixed fixture set and reports mean TTFB, which is the
only honest way to pick one.

**Floating subtitle panel** with a two-pane store. The live pane holds what is
still being recognized or translated; rows graduate to the history pane when
their translation ends. `SubtitleStore` keeps the viewport pinned to the bottom
only while the reader has not scrolled away, and treats a rubber-band bounce or a
window resize as "still following" rather than as a deliberate scroll back.

**Automatic English detection**, shipping **off**. A second en-US recognizer runs
concurrently over the same audio and English turns are shown verbatim rather than
round-tripped through translation, because a ja-JP recognizer fed English
transliterates it and the translator then renders the transliteration as
nonsense. The decision signal is script ratio, not cross-model confidence:
`transcriptionConfidence` is populated on final results only, and the picker has
to lock on the first translatable unit, which is usually volatile-derived. The
thresholds in `LanguageScore` are a starting hypothesis and have not been fitted
against a real meeting, which is why the feature defaults to off.

**Recovery from device changes.** Losing the default output device mid-meeting
rebuilds the tap rather than silently going deaf, and a display unplugged
mid-meeting cannot strand the panel off-screen. `--device-switch-test` exercises
the first path for real by changing the default device and restoring it.

**Headless self-tests.** `make test` checks the subtitle pane logic and the
language picker with no audio device, no network and no window, so the parts with
real invariants are testable without a meeting to run them against.

**Build and signing harness** for Command Line Tools only — no Xcode.
`scripts/bundle.sh` assembles the `.app` by hand because SwiftPM has no
app-bundle product type. `scripts/make-cert.sh` creates a self-signed
code-signing identity so the app's Designated Requirement is anchored to a
certificate instead of a cdhash; without that, every rebuild silently invalidates
the stored TCC grant while System Settings continues to show the toggle as on.
`make check-dr` is the one command that predicts whether that has broken.

**App icon and menu bar mark**, generated from `scripts/make-icon.swift` and
committed. Code rather than a design file because a CLT-only build has no asset
catalog and no `actool`, so the `.icns` has to be assembled from an `.iconset`
either way. The menu bar mark is a template PDF, so it tints correctly in light
and dark and tracks any menu bar height.

**Versioning.** `VERSION` is the single source of truth; `scripts/bundle.sh`
stamps it and the commit count into the bundled `Info.plist` at package time, and
`Tsuyaku --version` reads them back. An unstamped `swift build` binary reports
build `dev` rather than claiming to be a release.

**GitHub Actions.** Every push and pull request builds and runs `make test` on
`macos-26`. Pushing a `v*` tag builds a release bundle, zips it with `ditto` and
attaches it to a GitHub Release with that version's section of this file as the
notes.

### Known limitations

Released builds are **ad-hoc signed**, not notarized. macOS quarantines them and
TCC grants will not survive replacing one build with the next, so a downloaded
build is for trying the app out, not for living in. For regular use, build from
source with a local signing identity — see "Install" in the README.

The English-detection thresholds are unfitted (above). Sandboxing is off
deliberately: without a provisioning profile it fights the process-tap and
aggregate-device path for no benefit in a local build.

[Unreleased]: https://github.com/dautroc/tsuyaku/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/dautroc/tsuyaku/releases/tag/v0.3.0
[0.2.0]: https://github.com/dautroc/tsuyaku/releases/tag/v0.2.0
[0.1.0]: https://github.com/dautroc/tsuyaku/releases/tag/v0.1.0
