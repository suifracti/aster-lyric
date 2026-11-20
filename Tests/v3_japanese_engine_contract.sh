#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
V3="$ROOT/SpotifyLyrics/Views/MainWindow/AppleMusicImmersiveV3Lyrics.swift"

grep -q 'userEntries: \[ReadingDictionaryEntry\]' "$V3" || {
  echo "V3 reading cache must accept user correction entries" >&2
  exit 1
}
grep -q 'settings.readingUserDictionary.load()' "$V3" || {
  echo "V3 lyric rows must load the shared correction dictionary" >&2
  exit 1
}
grep -q 'trackStableKey:' "$V3" || {
  echo "V3 correction lookup must carry track scope" >&2
  exit 1
}
grep -q 'artistDisplay:' "$V3" || {
  echo "V3 correction lookup must carry artist scope" >&2
  exit 1
}

echo "V3 Japanese engine contract passed"
