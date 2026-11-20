#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VIEW="$ROOT_DIR/SpotifyLyrics/Views/Capsule/CapsuleLyricsView.swift"

for needle in \
  'dynamicIslandDarkV4Content' \
  'v4CollapsedContent' \
  'v4HoverContent' \
  'v4ExpandedContent' \
  'accessibilityReduceMotion' \
  'v4Artwork' \
  'v4TransportButton' \
  'CapsuleV4LyricRowView'; do
  grep -F "$needle" "$VIEW" >/dev/null
done

grep -F 'CapsuleDynamicIslandDarkV4.targetSize' "$VIEW" >/dev/null
grep -F 'preferredText(selection.current)' "$VIEW" >/dev/null
grep -F 'LyricTextLayers(' "$VIEW" >/dev/null
grep -F 'lineLimit(1)' "$VIEW" >/dev/null
grep -F 'pause.fill' "$VIEW" >/dev/null
grep -F 'forward.end.fill' "$VIEW" >/dev/null
grep -F 'backward.end.fill' "$VIEW" >/dev/null
grep -F 'truncationMode(.tail)' "$VIEW" >/dev/null
# The live line can be held for reading while the next/current cue keeps following playback.
for needle in 'state.liveLyrics' 'live.following' '正在唱' '定住这句' 'KeepLyricButton' 'windowController.notchGeometry.reservedWidth'; do
  grep -F "$needle" "$VIEW" >/dev/null
done

echo "capsule v4 content contract passed"
