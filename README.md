# Tsuyaku

Live Japanese → English subtitles for meetings on macOS 26.

On-device speech recognition (Apple `SpeechAnalyzer`), Claude for translation,
Core Audio process taps for capture. No cloud STT, no screen recording, no
virtual audio driver, no Xcode.

## Status

| Milestone | State |
|---|---|
| M0 build + signing harness | done, verified |
| M1 audio capture | done, verified |
| M2 on-device transcription | done, verified |
| M3 translation pipeline | four text backends + one audio-native; DeepSeek is the default when a key exists |
| M4 floating subtitle UI | done |
| M5 polish | partial (transcript copy, settings persistence, device-loss recovery) |
| M6 automatic English detection | built and tested; thresholds not yet fitted on a real meeting, so it ships **off** |

## Setup

```bash
./scripts/make-cert.sh          # once: self-signed code-signing identity
make bundle                     # build + assemble + sign
make check-dr                   # must print OK
./build/Tsuyaku.app/Contents/MacOS/Tsuyaku --install-assets   # ja-JP speech model
open build/Tsuyaku.app          # menu bar app
```

On first launch the app offers to install the Japanese **translation** model
(separate from the speech model). Accept it -- see "Two models" below.

Diagnostics, one layer at a time:

```bash
./build/Tsuyaku.app/Contents/MacOS/Tsuyaku --probe
./build/Tsuyaku.app/Contents/MacOS/Tsuyaku --apple-preflight
./build/Tsuyaku.app/Contents/MacOS/Tsuyaku --listen  global 20
./build/Tsuyaku.app/Contents/MacOS/Tsuyaku --pipeline global 60
```

Two self-checks that need no meeting:

```bash
make test                                                      # subtitle pane logic
./build/Tsuyaku.app/Contents/MacOS/Tsuyaku --device-switch-test  # capture recovery
```

`--device-switch-test` needs audio playing to measure (`afplay something &`)
and briefly changes your default output device, restoring it afterwards.

## Releases and versioning

**Build from source rather than downloading a release.** The zip attached to a
GitHub Release is ad-hoc signed, because CI has no code-signing identity and the
one `scripts/make-cert.sh` creates is deliberately local-only. An ad-hoc
signature makes the app's Designated Requirement a cdhash, which means macOS
quarantines the download and drops the microphone and system-audio grants the
moment you replace one build with the next — the failure the whole signing
harness exists to avoid. A downloaded build is for trying the app out:

```bash
unzip Tsuyaku-<version>.zip
xattr -dr com.apple.quarantine Tsuyaku.app
mv Tsuyaku.app /Applications/
```

For anything beyond that, `make cert` once and then `make install`, which builds
release, signs with the certificate-anchored identity and copies to
`/Applications`. It re-runs safely: the DR carries no path, so the TCC grant
follows the app across the copy without re-prompting.

`VERSION` is the single source of truth. `scripts/bundle.sh` stamps it, plus the
commit count as `CFBundleVersion`, into the bundled `Info.plist`, so
`Tsuyaku --version` always reports what was actually packaged. A bare
`swift build` binary has no bundle to read and says build `dev` instead.

Cutting a release means editing `VERSION` and `CHANGELOG.md` in the same commit,
then tagging it:

```bash
git tag -a v0.2.0 -m "Tsuyaku 0.2.0"
git push origin main --follow-tags
```

`.github/workflows/release.yml` refuses to publish unless the tag, `VERSION` and
a matching `CHANGELOG.md` section all agree, then builds, packages with `ditto`,
verifies the signature and the reported version on the *unpacked* copy, and uses
that changelog section as the release notes. `.github/workflows/ci.yml` runs the
build, the self-tests and the full packaging path on every push and pull request.

## Icons

`Resources/AppIcon.icns` and `Resources/MenuBarIconTemplate.pdf` are drawn by
`scripts/make-icon.swift` and committed; `make icon` redraws them. Code rather
than a design file because a Command Line Tools build has no asset catalog and no
`actool`, so the `.icns` has to be assembled from an `.iconset` by hand either
way — and this way the art is diffable.

The app icon is drawn at three levels of detail. Scaling one drawing down to
16px turns the speech bubble's tail into three grey pixels and merges the two
subtitle bars into a smudge, so the small variants drop the tail and spend the
pixels on bar thickness and on the gap between the bars, which is the feature
that reads as "subtitles" rather than "a blob".

The menu bar mark is a template PDF: vector, so it tracks any menu bar height,
and the `Template` suffix is what makes AppKit tint it for light and dark. The
status item falls back to the `captions.bubble` SF Symbol it was drawn from when
the app runs outside a bundle.

## Two models, two install paths

Tsuyaku needs two separate on-device models, and they install differently.

| | Speech (ja-JP) | Translation (ja->en) |
|---|---|---|
| Framework | `Speech` / `AssetInventory` | `Translation` |
| Install | `--install-assets`, fully programmatic | system download sheet only |
| Why | `AssetInventory.assetInstallationRequest` works headless | a programmatic `TranslationSession(installedSource:)` reports `canRequestDownloads == false` and throws `.notInstalled` |

That asymmetry is why `TranslationDownloadHost` exists: Apple only offers the
translation download through the SwiftUI `.translationTask` modifier attached to
a live view, so the app keeps a small window purely to present that sheet.

## Automatic English detection

Meetings are mixed. Fed English, a `ja-JP` recognizer transliterates it and the
translator then renders the transliteration as nonsense -- so the app runs a
second `en-US` recognizer concurrently over the same audio and shows English
turns **verbatim, untranslated**.

Enable it from the menu bar (*Detect English Automatically*). It defaults to
**off**: the picker decides what you read, and a Japanese turn rendered as
English word salad is worse than a clumsy translation.

```
tap.buffers ──► fan-out ──┬─► ja.feed ──► ja.segments ──┬─► picker.observe
                          └─► en.feed ──► en.segments ──┴─► gate.ingest  (BOTH gates, always)
                                                                │
                              jaGate.events ──────────┐         │
                              enGate.events ──────────┴─► LanguagePicker ──► consume()
                                                                             ├─ ja ─► Translator
                                                                             └─ en ─► verbatim row
```

**Both gates ingest every segment; suppression happens on gate *events*, never
on segments.** A `SegmentGate` only advances its sentence watermark when it
ingests, so starving the losing gate leaves its watermark stale -- and on its
next win, mid engine-utterance, it re-emits sentences the user already read in
the other language. Feeding both always costs one extra gate and removes the
whole class of bug; `SegmentGate` needs no mute or reset API.

**The signal is script, not cross-model confidence.** Comparing a Japanese and
an English acoustic model's confidence numbers needs calibration we do not have.
The hiragana/kanji/glue ratio lives inside one model's output alphabet and needs
none. The naive form of this is wrong on ordinary speech --
「ミーティングのスケジュールをリスケしてもいいですか」 is entirely Japanese and
two-thirds katakana -- so the score combines hiragana fraction, kanji fraction
and grammatical-glue hits (は を の です ます …), minus a penalty for long
unbroken katakana runs, which is what transliterated English actually looks
like. `LanguageScore` is a pure function of a `String`; `PickerState` is a value
type with an injected clock. Both are checked headlessly by `make test`.

### What `--listen-dual` measured

```bash
./build/Tsuyaku.app/Contents/MacOS/Tsuyaku --capture     global 120   # record once
./build/Tsuyaku.app/Contents/MacOS/Tsuyaku --listen-dual-file /tmp/tsuyaku-capture.wav
./build/Tsuyaku.app/Contents/MacOS/Tsuyaku --listen-dual  global 60   # or live
```

Both engines side by side, with every number the picker would use and the
decision it would make. Two results already changed the code:

- **`transcriptionConfidence` is populated on finals only, never on volatile
  results.** The picker locks on the first translatable unit, which is usually
  volatile-derived, so confidence cannot inform that decision at all.
  `confidenceTiebreak` is off and stays off unless this changes. Requesting the
  attribute is free -- `AssetInventory.status` is identical with and without it.
- **Fed English, the `ja` model sometimes emits nothing rather than
  transliterating.** The script ratio is blind to that: there is no text to
  score. One engine sitting silent while the other produces a full sentence is
  now its own signal (`reason: .silence`), deliberately gated on the ja text
  being *empty* rather than merely short, so an engine that is a beat behind is
  not mistaken for a silent one.

Also measured: `maximumReservedLocales = 5` with only `ja-JP` reserved; all nine
`en-*` speech models already installed, so English needs no download;
`bestAvailableAudioFormat(compatibleWith: [ja, en])` returns the same
16 kHz/mono/Int16 the single engine already negotiated, so one tap feeds both and
`FormatConverter` is untouched. Note that `AssetInventory.status` reports
`.supported` rather than `.installed` until a locale is reserved *in that
process*, and reservation is per app identity -- so a status check before
`reserve` is not evidence of a missing model.

### Still to fit, on a real meeting

The thresholds are a starting hypothesis, not a measurement. On synthetic
back-to-back TTS the `ja` engine held **one utterance open across 28 seconds**,
spanning a language switch, which keeps its cumulative text scoring Japanese and
starves the English side until the 12s safety valve fires. Real meetings have
pauses, which is what makes the engine finalize -- but the turn model is keyed on
gate `.settled`, so this is the risk to watch. Record a real meeting with
`--capture`, replay it with `--listen-dual-file`, and set `languageThreshold`
from the suggested split before turning the feature on.

## Translation backends

`Translator` is a protocol; pick a backend from the menu bar or with
`--provider`. Keys live in the keychain (`--set-key <provider> <key>`).

| Provider | Mean TTFB | Cost / meeting hour | Notes |
|---|---|---|---|
| `apple` | ~40ms | free | On device, offline. No view of the conversation, so it is literal on keigo and cannot recover omitted subjects. |
| `deepseek` | ~800ms | ~2-4c | `deepseek-flash`. Best quality/cost balance. |
| `anthropic` | untested | ~15c | `claude-haiku-4-5`. Needs a Console key. |
| `qwenOmni` | untested | ~35c (est.) | Speech straight to English -- no transcription step. Cloud. See below. |

### Qwen Omni: audio in, English out

`qwenOmni` is the one backend that is not a `Translator`. It implements
`AudioTranslator` and takes the captured utterance as a WAV blob, so
`SpeechAnalyzer` is not in the graph at all. `PipelineController` branches on
`TranslationProvider.isAudioNative` before it builds a transcriber:

```
tap -> VoiceSegmenter (energy VAD) -> QwenOmniTranslator -> store
```

What this buys is a model that hears prosody, hesitation and proper nouns that
a recognizer has already flattened into text. What it costs, beyond money:

- **No Japanese transcript.** Nothing transcribes the source, so rows carry an
  empty source field and a copied transcript holds English only.
- **No `hearing` preview.** That line is fed by a recognizer's partial results.
- **No auto-detect.** `LanguagePicker` arbitrates between two recognizers and
  there are none; the model handles mixed-language speech itself.
- **Meeting audio leaves the machine.** The "no cloud STT" property in the
  header of this file does not hold on this path. Every other backend still
  transcribes on device and sends text at most.

Segmentation moves from `SegmentGate` (which cuts on sentence structure in
recognized text) to `VoiceSegmenter` (which cuts on silence), because on this
path there is no text until after the cut has been made.

Two Qwen-specific wire details, both load-bearing:

- `input_audio.data` must carry a `data:;base64,` prefix. Plain base64 -- what
  the OpenAI schema specifies and what OpenAI's own SDKs send -- is rejected
  (pydantic/pydantic-ai#3530).
- `stream` must be `true`; the omni tier refuses unary requests.

`modalities: ["text"]` is also not cosmetic: at the default the model
synthesises speech as well, billed far above the text output rate.

Model IDs here churn (`qwen3-omni-flash`, `qwen3.5-omni-flash`), so the ID is a
defaults key rather than a constant:

```bash
./build/Tsuyaku.app/Contents/MacOS/Tsuyaku --set-key qwenOmni <dashscope-key>
./build/Tsuyaku.app/Contents/MacOS/Tsuyaku --omni-model qwen3.5-omni-flash
./build/Tsuyaku.app/Contents/MacOS/Tsuyaku --omni-test sample.wav   # verify the wire format
```

`--omni-test` with no file sends one second of silence, which still proves auth,
region and framing. The endpoint defaults to Singapore
(`dashscope-intl.aliyuncs.com`); a key issued in the Beijing namespace will 401
against it.

Anthropic and DeepSeek share one client, `MessagesAPITranslator`: DeepSeek
serves the Anthropic Messages wire format at `api.deepseek.com/anthropic`,
mapping `claude-haiku-*` onto `deepseek-flash`.

Measured on the 18-utterance fixture set (`--compare`), Apple got 4 of 18
materially wrong and DeepSeek fixed all 4 -- including 「そこは追って詰めましょう」,
which Apple rendered as *"Let's chase and pack that."*

**DeepSeek must be sent `thinking: {"type":"disabled"}`.** Its reasoning tier
thinks by default and will spend the entire `max_tokens` budget deliberating
over a one-line translation, returning no text at all.

## Why these choices

**Core Audio process taps over ScreenCaptureKit.** The TCC prompt reads *"would
like access to record your system audio"* and the grant lands under *System
Audio Recording Only* — no screen-recording language, no purple menu-bar
indicator, no periodic re-prompt, and no video pipeline to run and discard.
macOS 26 added `bundleIDs` and `processRestoreEnabled`, so the tap reattaches
to the target app across relaunches.

**Apple `SpeechTranscriber` over Whisper or Deepgram.** Free, offline, private,
genuinely streaming with `.volatileResults`. Unlike Whisper it has no
autoregressive decoder, so it cannot fall into the hallucination loops that
require VAD gating and blocklists in local Whisper deployments. Verified
character-perfect on Japanese business speech.

**No acoustic echo cancellation.** Tapping the meeting app's process audio is
electrically separate from the microphone, so far-end audio never re-enters the
transcribed stream. This matters because Apple's `VoiceProcessingIO` still fails
with `err=-10875` on multichannel/Spatial Audio outputs on macOS 26, unfixed.

**Self-signed certificate, not ad-hoc signing.** Ad-hoc signing pins the
Designated Requirement to a `cdhash`, so every rebuild silently invalidates the
TCC grant *while System Settings still shows the toggle ON*. A certificate
anchors the DR to the cert instead, and the grant survives. `make check-dr`
guards this. Trust is not required — an untrusted self-signed cert signs fine
and still yields a stable DR.

**Claude Haiku 4.5 over NMT.** Japanese omits subjects, marks register through
keigo, and chains topics across sentences. Rolling context of the last 4 turns
is what resolves those; a sentence-at-a-time NMT model cannot.

## The panel window

`.titled` is load-bearing even though the titlebar is invisible: a borderless
window gets no edge-drag resize from `.resizable`, so dropping it would cost the
panel its resize handles. `.fullSizeContentView` reclaims that height for the
content, and the standard window buttons are hidden because they would float
over the header. The panel therefore has no controls of its own. It lives and
dies with a session: it stays hidden at launch, "Start Subtitles" shows it, and
"Stop Subtitles" hides it again. The history survives a stop and is only wiped
by "Clear". A failed start leaves the panel up so the error stays readable.

**`setFrameAutosaveName` saves a frame but never restores one.** For a window
built in code nothing reads it back; that needs an explicit `setFrameUsingName`.
The panel used to reset to 620x260 bottom-centre on every launch however the
user had left it. The default placement now runs only when the restore *fails*,
or when the restored frame lands nowhere usable. That second case is mostly
belt-and-braces: measured, `setFrameUsingName` already drags a frame saved at
9000,9000 back to 40,680 before we get to look at it. It earns its place as the
partner of `recoverIfOffScreen()`, which runs on
`didChangeScreenParametersNotification` when a display is unplugged mid-meeting.

`contentMinSize` is the floor, not the SwiftUI layout: an `NSHostingView` will
let the frame shrink past its content and simply clip it.

**Nothing reads the keychain before the menu bar item is up.** `hasKey` is a
`SecItemCopyMatching` hiding behind a computed property, and `Settings.load()`
asks it twice (choosing a first-run provider, then checking the chosen one still
has its key). That call used to run as a property initializer on `AppDelegate`,
so it happened while `main.swift` was still constructing the delegate -- before
`NSApplication.run()`. A keychain read can take *seconds* the first time a
rebuilt binary asks for an item the user granted to an earlier signature, and
for that whole window there was a live process with a menu bar icon and no
subtitle window, which reads exactly like a failed launch. It was diagnosed with
`sample`, which caught the main thread parked in `AppDelegate.init` half a minute
after launch.

So the status item goes up first on a bare "Starting…" menu that needs no
keychain (the panel is built too, but stays hidden until subtitles start), and
`Settings.load()` runs in a
detached task. The set of providers that have keys is cached from that same
task, because `buildMenu()` asks `hasKey` of every provider and the menu is
rebuilt on every provider change. Verified by injecting an 8-second sleep into
`Settings.load()`: the panel rendered at 3 seconds, fully laid out, back when
it was shown at launch.

A key added with `--set-key` while the app is running therefore needs a restart
to appear ungreyed in the menu. It already needed one in practice -- `--set-key`
is a separate process -- and `makeTranslator` reads the keychain fresh when the
pipeline starts, so a new key still takes effect for translation itself.

## Verified on this machine

- macOS 26.6.2, Swift 6.4, Command Line Tools only (no Xcode)
- **SDK pinned to 26.5 via `SDKROOT` in the Makefile.** The 27.0 SDK redeclares
  SwiftUI's `@State` as a macro backed by a `SwiftUIMacros` plugin that ships
  only with Xcode, so on Command Line Tools alone every SwiftUI file fails to
  compile with *"plugin for module 'SwiftUIMacros' not found"*. 26.5 still
  declares those as property wrappers.
- `SpeechTranscriber.supportedLocales` = 30 locales, `ja-JP` among them
  (note: **no** `vi-VN`, despite community lists claiming 42 locales)
- Analyzer negotiates **16 kHz mono Int16 interleaved**; it does no resampling
  of its own, so `FormatConverter` sits in the IOProc path
- `SpeechTranscriber.isAvailable == true` without any Apple Intelligence gate
- Tap format is 48 kHz float32; conversion to 16 kHz mono verified end to end

## Layout

```
Sources/Tsuyaku/
  Audio/      SystemAudioTap, FormatConverter, AudioChunk
  Speech/     AppleTranscriber, AssetGate, TranscriberFactory, DualListenDiagnostic
  Translate/  ClaudeTranslator, Translator, SSEParser, Glossary
  Pipeline/   SegmentGate, Segment, SentenceSplitter, LanguageScore, LanguagePicker
  Support/    CoreAudioUtil, Keychain, Settings, Version

Resources/    AppIcon.icns, MenuBarIconTemplate.pdf  (generated, committed)
scripts/      bundle.sh, make-cert.sh, make-icon.swift, changelog-section.sh
```

`TranscriptionEngine` and `Translator` are protocols so backends swap without
touching the pipeline.

## Surviving device changes

The thing that actually kills capture mid-meeting is a device **disappearing**
-- Bluetooth headphones walking out of range, a USB interface unplugged. The
IOProc stops firing, and there is no error and no callback: subtitles simply
stop, silently.

What does *not* kill it, contrary to the original plan, is the default output
device merely **changing** while both devices remain present. The process tap
captures upstream of the device, so the aggregate's sub-device is little more
than a clock. This was measured, not assumed: switching between two present
devices leaves capture completely undisturbed, so rebuilding on every default
change would tear down a working graph for nothing.

So the health signal is the audio itself. The IOProc fires ~95 times a second
whether or not anything is playing -- silence still produces buffers -- which
makes "no buffers at all for 3 seconds" an unambiguous death signal that
catches every cause rather than the one cause we guessed. A watchdog on that
timestamp rebuilds the tap, the aggregate, and the converter (the replacement
device can have a different sample rate). Watching the device list is layered
on top purely as a latency optimisation: when the device we built on vanishes,
rebuild at once instead of waiting out the stall.

Rebuild failures retry three times at 250ms -- the HAL will report a device
before it will host an aggregate -- and then back off to the watchdog, which
keeps trying, because headphones come back. The panel header turns orange and
says what happened; a `.failed` is reported once per outage, not once per
retry.

**Counting buffers does not prove capture works.** The first version of
`--device-switch-test` did exactly that and passed with the recovery code
commented out, because a dead graph on a live device still delivers a full
complement of silent buffers. The test now measures RMS and asserts on chunks
carrying actual signal, and it verifies the outage really happened before
crediting the recovery.

## Pipeline notes worth keeping

Three bugs here were only reachable with a *slow* translation backend, and are
worth not reintroducing:

- **The gate's unit of progress is the sentence, not a byte offset.** Volatile
  results are cumulative, but the recognizer revises text it already emitted
  (伸ばして -> して -> 伸ばして within one utterance), so any watermark based on a
  prefix string or character count drifts and starts cutting mid-word. The gate
  re-splits the cumulative text on terminators every time and counts sentences.
- **`.hearing` and `.translate` need separate streams.** Live partials arrive
  ~10x a second. Sharing one bounded stream meant that while a ~1s network
  translation blocked the consumer, partials evicted pending `.translate`
  events and whole sentences vanished. `events` is unbounded; `hearing` keeps
  only the newest.
- **A stream that completes with no text is a failure, not a blank subtitle.**

## The two panes

The panel is split, and the split is load-bearing:

| Pane | Holds | Scrolls |
|---|---|---|
| history (top) | rows whose translation is done and which the gate won't revise | yes, the user owns it |
| live (bottom) | what is being heard, plus the sentence currently translating | no, pinned |

A row graduates from live to history when `translationDone && !provisional`.
Provisional rows -- the 7s backstop's early flush -- stay live precisely
because they are still going to be rewritten, and rewriting a row the user has
already scrolled past is the thing to avoid.

Two things fall out of the split:

- **Reading back works.** Live text updates ~10x a second; before the split
  every one of those updates ran an auto-scroll animation on the same list the
  user was trying to read. Now the history pane only moves when a sentence
  settles, every few seconds.
- **Auto-scroll follows the speaker only while history is parked at the
  bottom.** Scroll back down, or hit the "N new" pill, to re-arm.

**Only the user's own hand unpins, and the geometry cannot tell you whose hand
it is.** When the live pane slides away the container grows in one callback and
the scroll view settles the offset in the *next* one, where both sizes look
steady -- so "the offset fell while nothing resized" reads as someone scrolling
back when it is really AppKit tidying up. The pane unpinned itself every few
seconds until the rule started asking `onScrollPhaseChange` who was driving.

Three things move the history pane, so the rule tests them in a fixed order:

1. **The container changed** -- the live pane appeared or vanished, or the
   window was resized. The bottom moves out from under the viewport while the
   content and the offset both hold still. This case used to fall through every
   branch: follow mode stayed nominally "on" with the newest row below the fold
   and the pill hidden, so the only way back was to scroll by hand. Now it
   silently re-finds the bottom.
2. **We are at the bottom** -- however we got there. Tested *before* the offset
   rule on purpose: flinging past the end rubber-bands the offset back down,
   which is shaped exactly like a deliberate scroll up, and the pane would
   otherwise unpin itself the instant the user reached the newest row.
3. **The offset fell while the user was driving** -- a deliberate scroll back.
   Without that last clause this branch fires on the scroll view's own settling.
4. **Still nominally following, but adrift, with nothing in flight** -- the
   residue of a container change settled a frame late. Re-assert the pin. Only
   while idle: mid-animation this would cut short the ease carrying a newly
   settled row into view.

Content growth needs no rule of its own. Every change to it comes out of
`graduate()`, which is what `SubtitleStore.settledCount` counts.

**`history.count` cannot be the auto-scroll trigger.** Past the 500-row cap,
`graduate()` appends and trims in one synchronous call, so the count stops
moving and anything watching it -- the scroll, the "N new" pill -- goes quietly
dead for the rest of the meeting. `settledCount` is monotonic and survives the
cap.

**New rows animate; corrections do not.** A row arriving is an event worth
seeing move. Re-finding the bottom after the pane changed shape is putting the
viewport back where it already was, and animating that reads as the list moving
on its own -- so it runs in a transaction with `disablesAnimations`, which also
stops the live pane's own 0.18s transition from leaking into the scroll.

**Row identity is not utterance identity.** One spoken turn is often several
sentences and they all share the gate's utterance id, so that id cannot be the
SwiftUI `Identifiable` id -- it gives `ForEach` duplicate keys and makes
`scrollTo(last.id)` resolve to the *first* row of the turn. `SubtitleLine.id`
is per row; `SubtitleLine.utterance` is what the pipeline addresses.

`Tsuyaku --store-selftest` drives the store through these sequences (normal
sentence, multi-sentence turn, provisional-then-revised, failed translation,
id uniqueness, history cap, and the three `settledCount` cases that guard the
auto-scroll trigger) with no audio or network. It also replays geometry-callback
sequences through `HistoryScrollRule` -- an appended row, the live pane arriving
and leaving, a read-back, a rubber-band bounce. That rule is split out of the
view precisely because it cannot be checked by looking at a running panel: the
sequences that break it are a handful of callbacks a fifth of a second apart.
