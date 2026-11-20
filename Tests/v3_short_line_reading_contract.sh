#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VIEW="$ROOT/SpotifyLyrics/Views/MainWindow/AppleMusicImmersiveV3Lyrics.swift"

if grep -q 'effectiveOriginalText.count > 2' "$VIEW"; then
  echo 'FAIL: V3 skips automatic readings for short Japanese lyric lines' >&2
  exit 1
fi

grep -q 'guard !effectiveOriginalText.isEmpty,' "$VIEW" || {
  echo 'FAIL: V3 automatic reading fallback has no short-line guard' >&2
  exit 1
}

echo 'V3 short-line reading contract: PASS'
