#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WINDOW="$ROOT/SpotifyLyrics/Views/MainWindow/AppleMusicImmersiveV3WindowView.swift"
TRANSPORT="$ROOT/SpotifyLyrics/Views/MainWindow/AppleMusicImmersiveV3Transport.swift"
INSPECTOR="$ROOT/SpotifyLyrics/Views/MainWindow/AppleMusicImmersiveV3Inspector.swift"
METADATA="$ROOT/SpotifyLyrics/Views/Components/TrackMetadataView.swift"
OPERATIONS="$ROOT/SpotifyLyrics/Views/Components/CurrentSongOperationsView.swift"

grep -q "interactionHeight" "$TRANSPORT" \
  || { echo "missing expanded progress interaction target" >&2; exit 1; }
grep -q 'gearshape' "$WINDOW" \
  || { echo "settings toolbar still uses the layout icon" >&2; exit 1; }
grep -q 'ViewThatFits' "$METADATA" \
  || { echo "metadata still has only a single-line layout" >&2; exit 1; }
grep -q 'metadataStacked' "$METADATA" \
  || { echo "metadata fallback layout is missing" >&2; exit 1; }
grep -q 'ScrollView(.vertical)' "$OPERATIONS" \
  || { echo "current-song operations popover is not resize-safe" >&2; exit 1; }
grep -q 'Text("场景")' "$INSPECTOR" \
  || { echo "V3 tuning panel is missing scene header" >&2; exit 1; }

echo "V3 responsive UI finish contract: PASS"
