CONFIG ?= debug
APP     = build/Tsuyaku.app
BUNDLE_ID = com.loind.tsuyaku
VERSION  ?= $(shell tr -d '[:space:]' < VERSION)
DIST_NAME = Tsuyaku-$(VERSION).zip
# Exported so `make dist VERSION=9.9.9` reaches bundle.sh, which stamps the
# Info.plist. Without this, a command-line override would rename the zip and
# leave the bundle inside it claiming the old version.
export VERSION

# Pin the SDK. The 27.0 SDK redeclares SwiftUI's @State (and friends) as a
# macro backed by a SwiftUIMacros plugin that ships only with Xcode, so with
# Command Line Tools alone every SwiftUI file fails with "plugin for module
# 'SwiftUIMacros' not found". 26.5 still declares them as property wrappers.
# Drop this pin only once `find /Library/Developer -name 'libSwiftUIMacros*'`
# finds something.
#
# The fallback is for machines that have Xcode rather than CLT-only -- CI, for
# one. There the plugin *does* ship, so whatever `xcrun` selects is fine, and
# hard-coding a CLT path that does not exist would fail with a far less
# obvious error than "SDK not found".
CLT_SDK = /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
export SDKROOT ?= $(shell test -d $(CLT_SDK) && echo $(CLT_SDK) || xcrun --show-sdk-path)

.PHONY: build bundle run cert clean check-dr reset-tcc release test install icon dist version

build:
	swift build -c $(CONFIG) -Xswiftc -strict-concurrency=complete

bundle: build
	CONFIG=$(CONFIG) ./scripts/bundle.sh

run: bundle
	$(APP)/Contents/MacOS/Tsuyaku

release:
	$(MAKE) bundle CONFIG=release

# Redraw Resources/AppIcon.icns and the menu bar template. The outputs are
# committed, so this only needs running when the art changes.
icon:
	swift scripts/make-icon.swift .

version:
	@echo $(VERSION)

# What the release workflow attaches to a GitHub Release: a zip of the signed
# bundle. ditto, not zip(1) -- only ditto preserves the symlinks and extended
# attributes a bundle's signature is validated over.
dist: release
	@mkdir -p dist
	rm -f dist/$(DIST_NAME) dist/$(DIST_NAME).sha256
	ditto -c -k --keepParent --sequesterRsrc $(APP) dist/$(DIST_NAME)
	@# Run from inside dist/ so the checksum file names the artifact, not a
	@# path that only makes sense in this working tree.
	@cd dist && shasum -a 256 $(DIST_NAME) | tee $(DIST_NAME).sha256
	@echo "==> dist/$(DIST_NAME)"

# Subtitle pane logic, headless: no audio device, no network, no panel.
test: build
	@.build/$(CONFIG)/Tsuyaku --store-selftest

cert:
	./scripts/make-cert.sh

# Install to /Applications. Safe to re-run: the Designated Requirement is
# certificate-anchored and carries no path, so the TCC grant follows the app
# across the copy without re-prompting. Always builds release -- a debug
# binary is not what you want sitting in the audio path of a live meeting.
install: release
	@codesign --verify --strict $(APP)
	@osascript -e 'quit app "Tsuyaku"' >/dev/null 2>&1 || true
	rm -rf /Applications/Tsuyaku.app
	ditto $(APP) /Applications/Tsuyaku.app
	@codesign -d -r- /Applications/Tsuyaku.app 2>&1 | grep -q cdhash \
	  && echo "==> FAIL: DR is cdhash-pinned; TCC will re-prompt." \
	  || echo "==> OK: DR is certificate-anchored; TCC grant persists."
	@echo "==> Installed: /Applications/Tsuyaku.app"

# The single check that predicts whether TCC grants survive a rebuild.
check-dr:
	@codesign -d -r- $(APP) 2>&1 | grep -q cdhash \
	  && echo "FAIL: DR is cdhash-pinned; TCC will re-prompt every build." \
	  || echo "OK: DR is certificate-anchored; TCC grants persist."

# Use once after switching from ad-hoc to a real identity, to clear stale csreq.
reset-tcc:
	tccutil reset AudioCapture $(BUNDLE_ID) || true
	tccutil reset Microphone   $(BUNDLE_ID) || true

clean:
	rm -rf .build build dist
