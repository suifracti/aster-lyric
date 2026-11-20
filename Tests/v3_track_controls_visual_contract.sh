#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WINDOW="$ROOT/SpotifyLyrics/Views/MainWindow/AppleMusicImmersiveV3WindowView.swift"
TRANSPORT="$ROOT/SpotifyLyrics/Views/MainWindow/AppleMusicImmersiveV3Transport.swift"
TOKENS="$ROOT/SpotifyLyrics/Design/LyricsDesignTokens.swift"
CONTROLS="$ROOT/SpotifyLyrics/Views/Components/LyricIslandControls.swift"
METADATA="$ROOT/SpotifyLyrics/Views/Components/TrackMetadataView.swift"

grep -q 'presentation: .v3Immersive' "$WINDOW" \
  && grep -q 'presentation: .v3Immersive' "$TRANSPORT" || {
  echo 'FAIL: V3 does not opt into its readable metadata hierarchy' >&2
  exit 1
}

grep -q 'case v3Immersive' "$METADATA" \
  && grep -q 'Color.white.opacity(0.90)' "$METADATA" \
  && grep -q 'Color.white.opacity(0.72)' "$METADATA" || {
  echo 'FAIL: artist and album do not have a V3-specific white hierarchy' >&2
  exit 1
}

grep -q 'max(0, width \* progressFraction)' "$TRANSPORT" \
  && grep -q 'hoverThumbSize' "$TRANSPORT" \
  && grep -q 'hoverThumbSize' "$TOKENS" || {
  echo 'FAIL: progress rail lacks accurate fill or hover thumb' >&2
  exit 1
}

grep -q 'struct V3TransportIconButton' "$TRANSPORT" \
  && grep -q 'struct IslandTransportButton' "$CONTROLS" \
  && grep -q '\.help(label)' "$CONTROLS" || {
  echo 'FAIL: transport controls lack shared button hierarchy or hover help' >&2
  exit 1
}

grep -q 'progressActiveGradient' "$TRANSPORT" || {
  echo 'FAIL: V3 progress does not expose a legible active hierarchy' >&2
  exit 1
}

for symbol in backward.fill pause.fill play.fill forward.fill; do
  grep -q "\"$symbol\"" "$TRANSPORT" || {
    echo "FAIL: missing familiar transport symbol $symbol" >&2
    exit 1
  }
done

echo 'V3 track controls visual contract: PASS'
