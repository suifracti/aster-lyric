#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONTROL="$ROOT_DIR/SpotifyLyrics/Views/Components/LyricsPreferencesPopover.swift"
STATE="$ROOT_DIR/SpotifyLyrics/Services/PlaybackState.swift"

grep -Fq 'Button("提前 0.10s") { adjust(0.1) }' "$CONTROL"
grep -Fq 'Button("延后 0.10s") { adjust(-0.1) }' "$CONTROL"
grep -Fq 'return offset > 0 ? "提前 ' "$CONTROL"
grep -Fq '正值让歌词提前出现，负值让歌词延后出现' "$CONTROL"
if grep -Fq 'state.seek' "$CONTROL"; then
  echo 'FAIL: offset control must not seek the provider' >&2
  exit 1
fi

grep -Fq 'resolvedSettings.lyricsOffsetStore.$activeOffset' "$STATE"
grep -Fq '.sink { [weak self] newOffset in' "$STATE"
grep -Fq 'presentationOffset: newOffset' "$STATE"
echo 'C1 offset semantics/source contract: PASS'
