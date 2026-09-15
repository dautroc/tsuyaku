#!/bin/bash
# One-time: create a self-signed code-signing identity so the app's Designated
# Requirement is anchored to a certificate rather than pinned to a cdhash.
#
# Why this matters: ad-hoc signing (`codesign -s -`) produces a DR of the form
#   cdhash H"..."
# which changes on every rebuild. macOS then silently stops matching the stored
# TCC grant -- while System Settings still shows the toggle ON. A cert-anchored
# DR keeps the grant across rebuilds. Per Apple DTS (forums 795739) and TN2206,
# a self-signed cert is sufficient; no Developer Program membership needed.
set -euo pipefail

CN="${1:-Tsuyaku Dev}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if security find-identity -p codesigning | grep -q "\"$CN\""; then
  echo "Identity '$CN' already exists. Nothing to do."
  exit 0
fi

echo "==> Generating self-signed code-signing certificate: $CN"
openssl req -x509 -newkey rsa:2048 -days 3650 -nodes \
  -keyout "$WORK/dev.key" -out "$WORK/dev.crt" \
  -subj "/CN=$CN" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=codeSigning" 2>/dev/null

# -legacy is REQUIRED. Without it the PKCS#12 import fails *silently*.
openssl pkcs12 -export -legacy \
  -in "$WORK/dev.crt" -inkey "$WORK/dev.key" \
  -out "$WORK/dev.p12" -password pass:tsuyaku 2>/dev/null

echo "==> Importing into the login keychain"
security import "$WORK/dev.p12" \
  -k "$HOME/Library/Keychains/login.keychain-db" \
  -P tsuyaku -T /usr/bin/codesign

# NOTE: marking the cert "trusted" is NOT required. An untrusted self-signed
# identity still signs, and still yields a certificate-anchored DR of the form
#   identifier "..." and certificate leaf = H"..."
# which is what makes TCC grants survive rebuilds. Trust only affects Gatekeeper
# evaluation, which is irrelevant for a locally-built app you launch yourself.

echo
security find-identity -p codesigning | grep "$CN" || true
echo
echo "Done. Now run: make bundle && make check-dr"
