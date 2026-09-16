#!/bin/bash
# Print one version's section of CHANGELOG.md, so the release notes on GitHub
# and the changelog in the repo cannot drift apart -- there is one source.
#
#   scripts/changelog-section.sh 0.1.0
#
# Exits non-zero if that version has no section, which is what makes the
# release workflow refuse to publish a tag nobody wrote notes for.
set -euo pipefail

version="${1:?usage: changelog-section.sh <version>}"
root="$(cd "$(dirname "$0")/.." && pwd)"

body="$(awk -v want="$version" '
  /^## \[/ {
    match($0, /\[[^]]+\]/)
    ver = substr($0, RSTART + 1, RLENGTH - 2)
    if (inside) exit          # next version heading ends the section
    inside = (ver == want)
    next
  }
  # The link-reference block at the foot of the file belongs to no section, but
  # it trails the last one, so it would otherwise be published as release notes.
  inside && /^\[[^]]+\]: / { exit }
  inside { buf[n++] = $0 }
  END {
    s = 0
    while (s < n && buf[s] == "") s++
    while (n > s && buf[n-1] == "") n--
    for (i = s; i < n; i++) print buf[i]
  }
' "$root/CHANGELOG.md")"

if [ -z "$body" ]; then
  echo "no CHANGELOG.md section for version $version" >&2
  exit 1
fi

printf '%s\n' "$body"
