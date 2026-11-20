#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

WINDOW="SpotifyLyrics/Views/MainWindow/AppleMusicImmersiveV3WindowView.swift"
LYRICS="SpotifyLyrics/Views/MainWindow/AppleMusicImmersiveV3Lyrics.swift"
INSPECTOR="SpotifyLyrics/Views/MainWindow/AppleMusicImmersiveV3Inspector.swift"
BACKDROP="SpotifyLyrics/Views/Components/AppleMusicImmersiveV3BackdropView.swift"
STYLE="SpotifyLyrics/Design/MainWindowLayoutStyle.swift"
MAIN="SpotifyLyrics/Views/MainWindow/MainLyricsWindowView.swift"
SETTINGS="SpotifyLyrics/Settings/AppSettingsStore.swift"

for file in "$WINDOW" "$LYRICS" "$INSPECTOR" "$BACKDROP" "$STYLE" "$MAIN" "$SETTINGS"; do
  test -f "$file" || { echo "missing V3 file: $file" >&2; exit 1; }
done

grep -q 'case appleMusicImmersiveV3' "$STYLE"
grep -q 'AppleMusicImmersiveV3WindowView' "$MAIN"
grep -q 'AppleMusicImmersiveV3WindowView.swift' SpotifyLyrics.xcodeproj/project.pbxproj
grep -q 'AppleMusicImmersiveV3Lyrics.swift' SpotifyLyrics.xcodeproj/project.pbxproj
grep -q 'AppleMusicImmersiveV3BackdropView.swift' SpotifyLyrics.xcodeproj/project.pbxproj

# Responsive V3 remains one canvas with dynamic track/lyrics columns.
grep -q 'case .wide, .medium:' "$WINDOW"
grep -q 'adaptiveSplitLayout(in: geometry)' "$WINDOW"
grep -q 'V3ResponsiveGeometry.adaptiveSplitMetrics' "$WINDOW"
grep -q 'technicalMinimumSize = LyricsDesignTokens.technicalMinimumMainWindowSize' "$WINDOW"
grep -q 'comfortableMinimumSize = LyricsDesignTokens.comfortableMainWindowSize' "$WINDOW"
grep -q 'wideBreakpoint: CGFloat = 1_080' "$WINDOW"
grep -q 'onContinuousHover' "$WINDOW"

# Lyrics use token-aligned ruby, safe seeking, and current-line scrolling.
grep -q 'RubyLineView' "$LYRICS"
grep -q 'LyricsTimeline.validSeekTimestamp' "$LYRICS"
# The literal anchor is now a parameter so stage can move it by a bounded
# amount; V3ResponsiveGeometry keeps the ordinary 0.47 behavior and supplies
# the stage-specific value at the viewport boundary.
grep -q 'scrollTo(id, anchor: UnitPoint(x: 0.5, y: anchorY))' "$LYRICS"
grep -q 'V3ResponsiveGeometry.lyricScrollAnchor' "$LYRICS"
grep -q 'stage: stage' "$LYRICS"
! grep -q 'LyricsCanvasView' "$WINDOW" "$LYRICS"
grep -q 'shouldShowRuby' "$LYRICS"
grep -q 'distance <= 1' "$LYRICS"

# Backdrop work remains track-bound/cached and exposes the real renderers.
grep -q 'task(id: requestKey)' "$BACKDROP"
grep -q 'Task.detached(priority: .utility)' "$BACKDROP"
grep -q 'noiseData' "$BACKDROP"
grep -q 'maxPixel: 1280' "$BACKDROP"
# The old check looked for the cache capacity as if it were an image size.
# Keep the actual bounded-cache invariant explicit instead of dropping it.
grep -q 'capacity = 48' "$BACKDROP"
grep -q 'switch artworkPresentation' "$BACKDROP"
grep -q 'authenticAmbientArtworkLayers' "$BACKDROP"
grep -q 'ambientArtworkLayers' "$BACKDROP"
grep -q 'featheredAmbientArtworkLayers' "$BACKDROP"
grep -q 'stageArtworkLayers' "$BACKDROP"
grep -q 'classicArtworkLayers' "$BACKDROP"
grep -q 'gaussianArtworkLayers' "$BACKDROP"

# Stage removes the duplicate foreground card and scene choices remain persistent.
grep -q 'showsForegroundArtwork' "$WINDOW"
grep -q 'V3SceneFamily' "$INSPECTOR"
grep -q 'v3ArtworkPresentationRawValue' "$SETTINGS"

grep -q '.defaultSize(width: 1152, height: 720)' SpotifyLyrics/Main.swift

echo "Apple Music immersive V3 contract passed"
