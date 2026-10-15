#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SETTINGS="$ROOT/SpotifyLyrics/Settings/AppSettingsStore.swift"
BACKDROP="$ROOT/SpotifyLyrics/Views/Components/AppleMusicImmersiveV3BackdropView.swift"
WINDOW="$ROOT/SpotifyLyrics/Views/MainWindow/AppleMusicImmersiveV3WindowView.swift"

for stable_id in \
  'v3ArtworkPresentation.ambient.v1' \
  'v3ArtworkPresentation.stage.v1' \
  'v3ArtworkPresentation.classic.v1' \
  'v3ArtworkPresentation.feathered.v1'; do
  grep -q "$stable_id" "$SETTINGS" || {
    echo "missing stable V3 artwork presentation ID: $stable_id" >&2
    exit 1
  }
done

grep -q 'v3ArtworkPresentationRawValue' "$SETTINGS"
grep -q 'v3AmbientBackdropEnabled' "$SETTINGS" || {
  echo "old ambient preference must remain as a migration input" >&2
  exit 1
}
grep -q 'switch settings.v3ArtworkPresentation' "$BACKDROP"
grep -q 'stageArtworkLayers' "$BACKDROP"
grep -q 'case .stage' "$BACKDROP"
grep -q 'case .ambientFeathered' "$BACKDROP" || {
  echo "missing independent feathered ambient mode" >&2
  exit 1
}
grep -q 'v3BackdropBlurFeathered' "$SETTINGS" || {
  echo "new mode must remember its own blur" >&2
  exit 1
}

grep -q 'Picker("背景构图"' "$WINDOW"
grep -q 'V3ArtworkPresentation.allCases' "$WINDOW"
grep -q 'showsForegroundArtwork' "$WINDOW"
grep -q 'blurControlTitle' "$SETTINGS" || {
  echo "V3 presentations must expose mode-specific blur semantics" >&2
  exit 1
}
grep -q 'artworkSizeControlTitle' "$SETTINGS" || {
  echo "V3 presentations must expose mode-specific size semantics" >&2
  exit 1
}
grep -q 'artworkPositionControlTitle' "$SETTINGS" || {
  echo "V3 presentations must expose mode-specific position semantics" >&2
  exit 1
}
grep -q 'min(1.4, max(0.8, settings.v3ArtworkSizeScale))' "$BACKDROP" || {
  echo "Stage backdrop must honor the full 80–140% scale range" >&2
  exit 1
}
grep -q 'classicArtworkOffset' "$BACKDROP" || {
  echo "Classic backdrop must visibly react to crop position" >&2
  exit 1
}

echo "V3 artwork presentation contract passed"
