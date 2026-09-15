CONFIG ?= debug
APP     = build/Tsuyaku.app
BUNDLE_ID = com.loind.tsuyaku

# Pin the SDK. The 27.0 SDK redeclares SwiftUI's @State (and friends) as a
# macro backed by a SwiftUIMacros plugin that ships only with Xcode, so with
# Command Line Tools alone every SwiftUI file fails with "plugin for module
# 'SwiftUIMacros' not found". 26.5 still declares them as property wrappers.
# Drop this pin only once `find /Library/Developer -name 'libSwiftUIMacros*'`
# finds something.
export SDKROOT ?= /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk

.PHONY: build bundle run cert clean check-dr reset-tcc release test

build:
	swift build -c $(CONFIG) -Xswiftc -strict-concurrency=complete

bundle: build
	CONFIG=$(CONFIG) ./scripts/bundle.sh

run: bundle
	$(APP)/Contents/MacOS/Tsuyaku

release:
	$(MAKE) bundle CONFIG=release

# Subtitle pane logic, headless: no audio device, no network, no panel.
test: build
	@.build/$(CONFIG)/Tsuyaku --store-selftest

cert:
	./scripts/make-cert.sh

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
	rm -rf .build build
