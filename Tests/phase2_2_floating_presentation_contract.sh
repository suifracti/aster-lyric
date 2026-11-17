#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VIEW="$ROOT/SpotifyLyrics/Views/Floating/FloatingLyricsView.swift"
CONTROLLER="$ROOT/SpotifyLyrics/Windows/FloatingLyricsWindowController.swift"
SETTINGS="$ROOT/SpotifyLyrics/Settings/AppSettingsStore.swift"
PRESENTATION="$ROOT/SpotifyLyrics/Lyrics/FloatingLyricsPresentation.swift"

require() {
  local pattern="$1"
  local file="$2"
  grep -Eq "$pattern" "$file" || {
    echo "FAIL: missing /$pattern/ in $file" >&2
    exit 1
  }
}

require 'floatingLyrics\.legacyPanel\.v1' "$PRESENTATION"
require 'floatingLyrics\.transparent\.v2' "$PRESENTATION"
require 'ultraTransparent' "$PRESENTATION"
require 'lightMaterial' "$PRESENTATION"
require 'floatingLyricsPresentation' "$SETTINGS"
require 'floatingLyricsSurfaceStyle' "$SETTINGS"
require 'presentationVersion' "$VIEW"
require 'presentationStyle' "$VIEW"
require 'isHovering' "$VIEW"
require '\.v3OnHover' "$VIEW"
require 'surfaceBackground' "$VIEW"
require 'Color\.clear' "$VIEW"
require 'regularMaterial\.opacity' "$VIEW"
require 'ignoresMouseEvents' "$CONTROLLER"
require 'interactionMode' "$VIEW"
require 'legacyPanel' "$VIEW"
require 'ultraTransparent' "$VIEW"
require 'lightMaterial' "$VIEW"
require '\$floatingLyricsPresentationRawValue' "$CONTROLLER"
require '\$floatingLyricsSurfaceStyleRawValue' "$CONTROLLER"
require 'restoreInteractiveMode' "$CONTROLLER"

require 'windowController.toggleInteractionMode' "$VIEW"
require '解锁桌面歌词' "$VIEW"
require 'FloatingLyricsLayout' "$VIEW"

apply_presentation="$(sed -n '/private func applyPresentation()/,/^    }$/p' "$CONTROLLER")"
if printf '%s\n' "$apply_presentation" | grep -Eq 'setFrame|\.frame|screen|interactionMode|applyInteractionMode'; then
  echo 'FAIL: applyPresentation must not reset window frame, screen, or interaction state' >&2
  exit 1
fi

if grep -Eq 'LyricsSessionController|TranslationSessionController|PlaybackProvider|Timer\.scheduledTimer|URLSession' "$VIEW" "$CONTROLLER"; then
  echo 'FAIL: floating presentation owns a second business/timer path' >&2
  exit 1
fi

echo "phase2.2 floating presentation contract passed"
