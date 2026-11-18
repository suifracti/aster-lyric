#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BACKDROP="$ROOT/SpotifyLyrics/Views/Components/AppleMusicImmersiveV3BackdropView.swift"
ARTWORK="$ROOT/SpotifyLyrics/Views/Components/ArtworkView.swift"
PALETTE="$ROOT/SpotifyLyrics/Design/BackdropPalette.swift"
TOKENS="$ROOT/SpotifyLyrics/Design/LyricsDesignTokens.swift"
V3="$ROOT/SpotifyLyrics/Views/MainWindow/AppleMusicImmersiveV3WindowView.swift"
FULLSCREEN="$ROOT/SpotifyLyrics/Views/Fullscreen/FullScreenLyricsView.swift"

require() {
  local file="$1"
  local pattern="$2"
  local label="$3"
  if ! grep -Eq "$pattern" "$file"; then
    echo "FAIL: $label ($file does not contain /$pattern/)" >&2
    exit 1
  fi
}

for file in "$BACKDROP" "$ARTWORK" "$PALETTE" "$TOKENS" "$V3" "$FULLSCREEN"; do
  test -f "$file" || { echo "FAIL: missing $file" >&2; exit 1; }
done

# Stable presentation IDs and the four runnable presets; Custom remains a
# reserved ID without becoming a settings surface in this phase.
require "$PALETTE" 'backdrop\.default\.v1' 'default backdrop presentation ID'
require "$PALETTE" 'backdrop\.legacyV3\.v1' 'legacy V3 backdrop presentation ID'
require "$PALETTE" 'backdrop\.clear\.v1' 'clear backdrop presentation ID'
require "$PALETTE" 'backdrop\.immersive\.v1' 'immersive backdrop presentation ID'
require "$PALETTE" 'backdrop\.highContrast\.v1' 'high contrast backdrop presentation ID'
require "$PALETTE" 'backdrop\.custom\.v1' 'custom backdrop presentation ID'
require "$PALETTE" 'static var active' 'debug-selectable active preset'

# Semantic, not user-facing raw rendering controls.
require "$TOKENS" 'enum Backdrop' 'backdrop semantic tokens'
require "$TOKENS" 'textureIntensity' 'texture intensity token'
require "$TOKENS" 'lyricVeil' 'lyric veil token'
require "$TOKENS" 'transitionDuration' 'backdrop transition token'
require "$TOKENS" 'enum Surface' 'surface semantic tokens'

# Snapshot and rendering remain track-bound and shared; playback time must not
# enter the key or start a new image pipeline.
require "$BACKDROP" 'BackdropPresentationID' 'presentation style input'
require "$BACKDROP" 'AppleMusicImmersiveV3BackdropCache\.shared' 'shared snapshot cache'
require "$BACKDROP" 'Task\.detached\(priority: \.utility\)' 'off-main snapshot generation'
require "$BACKDROP" 'task\(id: requestKey\)' 'track-bound task'
require "$BACKDROP" 'accessibilityDisplayShouldReduceTransparency' 'reduce transparency policy'
require "$BACKDROP" 'accessibilityDisplayShouldIncreaseContrast' 'increase contrast policy'
require "$BACKDROP" 'accessibilityDisplayOptionsDidChangeNotification' 'display accessibility updates'
require "$BACKDROP" 'accessibilityReduceMotion' 'reduce motion policy'
require "$BACKDROP" 'SPOTIFYLYRICS_BACKDROP_NO_ARTWORK' 'debug neutral fallback harness'
require "$BACKDROP" 'loadedArtwork\?\.request == requestKey' 'only show artwork that matches the current request'
require "$BACKDROP" 'picture\?\.palette \?\? \.neutral' 'neutral palette while the current artwork loads'
require "$BACKDROP" 'AppleMusicImmersiveV3BackdropKey\.make' 'shared snapshot key helper'
require "$BACKDROP" 'texture' 'texture layer'
require "$BACKDROP" 'lyric' 'lyric readability layer'
require "$BACKDROP" 'vignette' 'vignette layer'
require "$BACKDROP" 'noise' 'noise layer'

# Fullscreen and V3 continue to consume the same V3 backdrop view; no second
# artwork/snapshot implementation is allowed.
require "$V3" 'AppleMusicImmersiveV3BackdropView' 'V3 shared backdrop'
require "$FULLSCREEN" 'AppleMusicImmersiveV3WindowView' 'fullscreen shares V3 renderer and backdrop'
require "$ARTWORK" 'SPOTIFYLYRICS_BACKDROP_NO_ARTWORK' 'foreground neutral fallback harness'
if grep -Eq 'BackdropPaletteCache\.shared|URLSession|CGImageSourceCreateWithData' "$FULLSCREEN"; then
  echo 'FAIL: fullscreen contains a second background/cache pipeline' >&2
  exit 1
fi

# The presets must be materially different semantic presets rather than the
# same artwork recipe with a small opacity tweak. Keep this check data-driven
# so future token refactors cannot silently collapse the visual range again.
python3 - "$PALETTE" "$TOKENS" <<'PY'
import re
import sys

text = open(sys.argv[1], encoding="utf-8").read()
tokens = open(sys.argv[2], encoding="utf-8").read()

def case_body(name, next_name):
    match = re.search(rf"case \.{name}:\n(.*?)(?=\n        case \.{next_name}:)", text, re.S)
    if not match:
        raise SystemExit(f"FAIL: missing style body for {name}")
    return match.group(1)

def value(body, key):
    match = re.search(rf"{key}: ([0-9.]+)", body)
    if match:
        return float(match.group(1))
    # The recommended default intentionally comes from semantic DesignTokens.
    token_match = re.search(rf"{key}(?:\s*:\s*Double)?\s*=\s*([0-9.]+)", tokens)
    if token_match and "LyricsDesignTokens" in body:
        return float(token_match.group(1))
    raise SystemExit(f"FAIL: missing {key}")

default = case_body("defaultV1", "clearV1")
clear = case_body("clearV1", "immersiveV1")
immersive = case_body("immersiveV1", "highContrastV1")

for key in ("textureIntensity", "paletteSaturation", "glowIntensity", "noiseIntensity"):
    if value(clear, key) >= value(default, key):
        raise SystemExit(f"FAIL: clear preset must reduce {key}")
    if value(immersive, key) <= value(default, key):
        raise SystemExit(f"FAIL: immersive preset must increase {key}")

if value(clear, "minimumLyricVeil") < value(default, "minimumLyricVeil"):
    raise SystemExit("FAIL: clear preset must retain a stable lyric veil")
print("PASS: backdrop preset semantic contrast")
PY

echo 'PASS: Phase 2.3D background contract'
