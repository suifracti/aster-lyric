#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
V3_VIEW="$ROOT/SpotifyLyrics/Views/MainWindow/AppleMusicImmersiveV3WindowView.swift"
V3_LYRICS="$ROOT/SpotifyLyrics/Views/MainWindow/AppleMusicImmersiveV3Lyrics.swift"
V3_TRANSPORT="$ROOT/SpotifyLyrics/Views/MainWindow/AppleMusicImmersiveV3Transport.swift"
BACKDROP="$ROOT/SpotifyLyrics/Views/Components/AppleMusicImmersiveV3BackdropView.swift"
SETTINGS="$ROOT/SpotifyLyrics/Views/Settings/SettingsRootView.swift"
WINDOW="$ROOT/SpotifyLyrics/Settings/WindowStatePersistence.swift"

grep -q 'LyricsDesignTokens.readableLyricLineMaxWidth' "$V3_LYRICS" || {
  echo 'FAIL: V3 lyric rows do not use a readable maximum width' >&2
  exit 1
}

grep -q 'providerKana.map { JapaneseReadingPipeline.analyze' "$V3_LYRICS" || {
  echo 'FAIL: V3 has no partial kana mapping when persisted ruby data is unavailable' >&2
  exit 1
}

if grep -q 'private var shouldRenderKanaFallback' "$V3_LYRICS"; then
  echo 'FAIL: V3 still renders an entire line of kana below the lyric' >&2
  exit 1
fi

grep -q 'regularMaterial' "$V3_VIEW" || {
  echo 'FAIL: V3 toolbar/popover still uses only the dark ultra-thin material' >&2
  exit 1
}

grep -q 'activeWidth = max(0, width \* progressFraction)' "$V3_TRANSPORT" || {
  echo 'FAIL: V3 progress rail still uses the old forced-width rendering' >&2
  exit 1
}

if grep -q 'completeArtworkLayer' "$BACKDROP"; then
  echo 'FAIL: V3 backdrop still renders a second floating artwork card' >&2
  exit 1
fi

grep -q 'scaledToFit()' "$BACKDROP" || {
  echo 'FAIL: V3 backdrop does not preserve the complete cover as a background layer' >&2
  exit 1
}

if grep -q '\.preferredColorScheme(\.dark)' "$SETTINGS"; then
  echo 'FAIL: Settings still force the black dark-only appearance' >&2
  exit 1
fi

grep -q 'NSVisualEffectView' "$WINDOW" || {
  echo 'FAIL: Settings window has no native macOS visual-effect surface' >&2
  exit 1
}

grep -q 'palette\.luminance' "$BACKDROP" || {
  echo 'FAIL: V3 backdrop readability is not adaptive to bright artwork' >&2
  exit 1
}

if grep -q 'return min(0\.08' "$BACKDROP"; then
  echo 'FAIL: V3 readability veil is still capped near zero' >&2
  exit 1
fi

stage_layers="$({ sed -n '/private func stageArtworkLayers/,/private func stageArtworkPlaneSize/p' "$BACKDROP"; } || true)"
if grep -q '\.blendMode(\.screen)' <<<"$stage_layers"; then
  echo 'FAIL: V3 stage whole-cover plane still uses screen blending and can disappear on white art' >&2
  exit 1
fi

echo 'V3 visual polish contract: PASS'
