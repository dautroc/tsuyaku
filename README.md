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
| M3 translation pipeline | three backends; DeepSeek is the default when a key exists |
| M4 floating subtitle UI | done |
| M5 polish | partial (transcript copy, settings persistence, device-loss recovery) |

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

## Translation backends

`Translator` is a protocol; pick a backend from the menu bar or with
`--provider`. Keys live in the keychain (`--set-key <provider> <key>`).

| Provider | Mean TTFB | Cost / meeting hour | Notes |
|---|---|---|---|
| `apple` | ~40ms | free | On device, offline. No view of the conversation, so it is literal on keigo and cannot recover omitted subjects. |
| `deepseek` | ~800ms | ~2-4c | `deepseek-flash`. Best quality/cost balance. |
| `anthropic` | untested | ~15c | `claude-haiku-4-5`. Needs a Console key. |

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
over the header -- which is why "Hide Panel" in the menu is the only way to put
it away.

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

**Nothing reads the keychain before the panel is up.** `hasKey` is a
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

So the panel is created and ordered front first, the status item goes up on a
bare "Starting…" menu that needs no keychain, and `Settings.load()` runs in a
detached task. The set of providers that have keys is cached from that same
task, because `buildMenu()` asks `hasKey` of every provider and the menu is
rebuilt on every provider change. Verified by injecting an 8-second sleep into
`Settings.load()`: the panel renders at 3 seconds, fully laid out.

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
  Speech/     AppleTranscriber, AssetGate
  Translate/  ClaudeTranslator, Translator, SSEParser, Glossary
  Pipeline/   SegmentGate, Segment
  Support/    CoreAudioUtil, Keychain
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
