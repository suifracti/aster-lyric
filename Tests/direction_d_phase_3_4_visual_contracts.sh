#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAIN="$ROOT/SpotifyLyrics/Views/Components/DirectionD/DirectionDMainWindowView.swift"
ROW="$ROOT/SpotifyLyrics/Views/Components/DirectionD/DirectionDLyricRowView.swift"
POLICY="$ROOT/SpotifyLyrics/Design/DirectionD/DirectionDLyricsPolicy.swift"
TOKENS="$ROOT/SpotifyLyrics/Design/DirectionD/DirectionDDesignTokens.swift"
TOOLBAR="$ROOT/SpotifyLyrics/Views/Components/DirectionD/DirectionDSongWorkbenchButton.swift"
INSPECTOR="$ROOT/SpotifyLyrics/Views/Components/DirectionD/DirectionDInspectorView.swift"
BACKDROP="$ROOT/SpotifyLyrics/Views/Components/TrackBackdropView.swift"
APP_MAIN="$ROOT/SpotifyLyrics/Main.swift"
CATALOG="$ROOT/SpotifyLyrics/Design/PresentationCatalog.swift"

PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "[PASS] $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "[FAIL] $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

contains() { grep -Fq "$2" "$1"; }
assert_contains() {
    if contains "$2" "$3"; then pass "$1"; else fail "$1 (missing: $3)"; fi
}
assert_not_contains() {
    if contains "$2" "$3"; then fail "$1 (unexpected: $3)"; else pass "$1"; fi
}

echo "======================================================"
echo "Lyric Island Phase 3.4 Direction D Visual Contract Suite"
echo "======================================================"

# The product window has a user-facing title while debug identifiers remain
# available for evidence capture.
assert_contains "product title is Lyric Island" "$APP_MAIN" 'Window("Lyric Island"'
assert_contains "debug window identifier remains stable" "$APP_MAIN" 'direction-d-main-window'
assert_contains "debug host preserves visual envelope" "$APP_MAIN" 'contentMinSize = NSSize(width: 520, height: 520)'
assert_contains "direct debug host owns its window" "$APP_MAIN" 'The DEBUG delegate below owns the isolated visual host'

# Quiet toolbar: no permanent focus ring, stable hit area, and SF Symbol
# actions grouped with the workbench rather than a backend-style toolbar.
assert_contains "quiet toolbar has stable hit area" "$TOOLBAR" ".contentShape(Rectangle())"
assert_contains "quiet toolbar disables focus effect" "$TOOLBAR" ".focusEffectDisabled()"
assert_contains "quiet toolbar fades on hover" "$TOOLBAR" "quietToolbarIdleOpacity"
assert_contains "quiet toolbar uses search symbol" "$TOOLBAR" 'systemName: "magnifyingglass"'
assert_contains "quiet toolbar uses settings symbol" "$TOOLBAR" 'systemName: "gearshape"'

# The main window uses one continuous artwork-backed canvas and the existing
# loader/cache path, with an opt-in Direction D treatment instead of a second
# downloader or palette cache.
assert_contains "Direction D uses shared artwork background" "$MAIN" "ArtworkBackgroundView(state: playbackState)"
assert_contains "Direction D enables presentation backdrop treatment" "$MAIN" "directionDBackdropTreatment"
assert_contains "backdrop remains track/URL keyed" "$BACKDROP" 'identity.stableKey)|\(track.artworkURL'
assert_contains "backdrop has lyric-side veil" "$BACKDROP" "lyric side is quieter"
assert_contains "backdrop keeps neutral fallback" "$BACKDROP" "neutralBackground"

# Lyric hierarchy is crisp rather than blur-based: the shared policy owns
# opacity/scale emphasis and the row keeps original + at most one auxiliary.
assert_contains "lyric policy has crisp zero blur" "$POLICY" "blurRadius: 0"
assert_contains "lyric row does not blur glyphs" "$ROW" ".blur(radius: 0)"
assert_not_contains "lyric row has no saturated cyan ruby" "$ROW" "Color.cyan.opacity(0.90)"
assert_contains "lyric row clamps readable width" "$ROW" "maxReadableLineWidth"
assert_contains "lyric scrolling uses stable reading anchor" "$MAIN" "readingAnchor"
assert_contains "lyric scroll remains live-index driven" "$MAIN" "projectedCurrentLineIndex"
assert_contains "lyrics focus has a bounded projection" "$MAIN" "renderLyricsSurface"

# Typography/layout tokens encode the readable current-line anchor and the
# Direction D hierarchy without introducing business state.
assert_contains "lyrics tokens define max readable width" "$TOKENS" "maxReadableLineWidth"
assert_contains "lyrics tokens define reading anchor" "$TOKENS" "readingAnchor"
assert_contains "lyrics tokens define active scale" "$TOKENS" "activeScale"
assert_contains "hero typography is semibold" "$TOKENS" ".system(size: size, weight: .semibold"

# The workbench identifies unavailable actions without implying fixed completion.
assert_contains "inspector explains experimental scope" "$INSPECTOR" 'title: "Direction D 实验界面"'
assert_contains "inspector explains unavailable details" "$INSPECTOR" '暂未接入此工作台'
assert_not_contains "inspector avoids false completed state" "$INSPECTOR" 'status: "已完成"'
assert_not_contains "inspector has no 100 percent badge" "$INSPECTOR" "100%"
assert_not_contains "inspector has no debug badge title" "$INSPECTOR" "DEBUG"

# Direction D remains experimental and V3 remains the default; visual repair
# must not silently switch the product default.
assert_contains "Direction D remains experimental" "$CATALOG" '.experimental'
assert_contains "V3 remains default" "$ROOT/SpotifyLyrics/Design/MainWindowLayoutStyle.swift" "appleMusicImmersiveV3"

# Main view is still only a projection: no new playback/session/timer owner.
assert_not_contains "visual repair creates no second playback state" "$MAIN" "PlaybackState("
assert_not_contains "visual repair creates no second lyrics session" "$MAIN" "LyricsSessionController("
assert_not_contains "visual repair creates no timer" "$MAIN" "Timer.scheduledTimer"

echo "======================================================"
echo "Summary: $PASS_COUNT passed, $FAIL_COUNT failed."
echo "======================================================"

if [ "$FAIL_COUNT" -ne 0 ]; then exit 1; fi
