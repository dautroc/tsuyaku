# Changelog

Notable changes to Tsuyaku. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Pre-1.0, the minor version moves when the pipeline's behaviour changes and the
patch version moves for fixes and packaging. Nothing here is API-stable.

## [Unreleased]

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

[Unreleased]: https://github.com/dautroc/tsuyaku/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/dautroc/tsuyaku/releases/tag/v0.1.0
