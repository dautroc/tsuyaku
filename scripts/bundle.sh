#!/bin/bash
# Assemble a .app bundle by hand. SwiftPM has no app-bundle product type and
# CLT-only has no xcodebuild, so this is the whole packaging step.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${CONFIG:-debug}"
APP="$ROOT/build/Tsuyaku.app"
IDENTITY="${IDENTITY:-Tsuyaku Dev}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$ROOT/.build/$CONFIG/Tsuyaku" "$APP/Contents/MacOS/Tsuyaku"
cp "$ROOT/Info.plist"             "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

if security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
  codesign --force --options runtime \
           --entitlements "$ROOT/Tsuyaku.entitlements" \
           --sign "$IDENTITY" "$APP"
else
  echo "!! Identity '$IDENTITY' not found -- falling back to AD-HOC signing."
  echo "!! TCC permissions will NOT survive rebuilds. Run scripts/make-cert.sh."
  codesign --force --options runtime \
           --entitlements "$ROOT/Tsuyaku.entitlements" \
           --sign - "$APP"
fi

echo
echo "==> Designated Requirement (must NOT contain 'cdhash'):"
codesign -d -r- "$APP" 2>&1 | sed 's/^/    /'
echo "==> Bundle: $APP"
