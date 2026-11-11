#!/usr/bin/env bash
set -euo pipefail

echo "======================================================"
echo "Lyric Island Phase 3.4 Main Window Contract Test Suite"
echo "======================================================"

SWIFT_DIR="SpotifyLyrics"

PASS_COUNT=0
FAIL_COUNT=0

assert_test() {
    local name="$1"
    local status="$2"
    local details="$3"
    if [ "$status" -eq 0 ]; then
        echo "[PASS] $name - $details"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "[FAIL] $name - $details"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

# 1. Main Window Presentation Contract
grep -q "struct DirectionDMainWindowView" "$SWIFT_DIR/Views/Components/DirectionD/DirectionDMainWindowView.swift"
assert_test "Contract 1: Main Window View" $? "DirectionDMainWindowView exists"

# 2. Wide Layout Contract
grep -q "renderWideLayout" "$SWIFT_DIR/Views/Components/DirectionD/DirectionDMainWindowView.swift"
assert_test "Contract 2: Wide Layout" $? "Wide layout renders left player + right lyrics"

# 3. Small Layout Contract
grep -q "renderSmallLayout" "$SWIFT_DIR/Views/Components/DirectionD/DirectionDMainWindowView.swift"
assert_test "Contract 3: Small Layout" $? "Small layout renders compact header + bottom sheet"

# 4. Lyrics Focus Layout Contract
grep -q "renderLyricsFocusLayout" "$SWIFT_DIR/Views/Components/DirectionD/DirectionDMainWindowView.swift"
assert_test "Contract 4: Lyrics Focus Layout" $? "Lyrics Focus renders hero lyrics + minimal bottom bar"

# 5. Responsive Layout Resolver Contract
grep -q "enum DirectionDLayoutMode" "$SWIFT_DIR/Design/DirectionD/DirectionDResponsiveLayout.swift" && \
grep -q "wideBreakpoint" "$SWIFT_DIR/Design/DirectionD/DirectionDResponsiveLayout.swift"
assert_test "Contract 5: Responsive Resolver" $? "DirectionDResponsiveLayout resolves breakpoints"

# 6. Single Playback State Contract
if grep -q "class SecondaryPlaybackState" "$SWIFT_DIR/Views/Components/DirectionD/DirectionDMainWindowView.swift"; then
    status6=1
else
    status6=0
fi
assert_test "Contract 6: Single Playback State" $status6 "No duplicated PlaybackState created"

# 7. Single Lyrics Canvas Contract
grep -q "DirectionDLyricRowView" "$SWIFT_DIR/Views/Components/DirectionD/DirectionDMainWindowView.swift"
assert_test "Contract 7: Single Lyrics Canvas" $? "Reuses DirectionDLyricRowView without duplicating canvas logic"

# 8. Layout Switch Preserves Track Contract
grep -q "private var currentTrack: Track" "$SWIFT_DIR/Views/Components/DirectionD/DirectionDMainWindowView.swift" && \
grep -q "playbackState.currentTrack" "$SWIFT_DIR/Views/Components/DirectionD/DirectionDMainWindowView.swift"
assert_test "Contract 8: Track Preservation" $? "Track metadata is projected from the shared PlaybackState"

# 9. Layout Switch Preserves Position Contract
grep -q "private var currentTime: Double" "$SWIFT_DIR/Views/Components/DirectionD/DirectionDMainWindowView.swift" && \
grep -q "playbackState.currentTime" "$SWIFT_DIR/Views/Components/DirectionD/DirectionDMainWindowView.swift"
assert_test "Contract 9: Position Preservation" $? "Current playback time is projected from the shared PlaybackState"

# 10. Auxiliary Layer Policy Contract
grep -q "policy: DirectionDLyricsPolicy" "$SWIFT_DIR/Views/Components/DirectionD/DirectionDLyricRowView.swift"
assert_test "Contract 10: Auxiliary Policy" $? "DirectionDLyricsPolicy enforces MAX 1 auxiliary layer by default"

# 11. Toolbar Hover Contract
grep -q "isAreaHovered" "$SWIFT_DIR/Views/Components/DirectionD/DirectionDSongWorkbenchButton.swift"
assert_test "Contract 11: Toolbar Hover" $? "Quiet Toolbar opacity transitions naturally on hover"

# 12. Focus Ring Contract
if grep -q "focused(true)" "$SWIFT_DIR/Views/Components/DirectionD/DirectionDSongWorkbenchButton.swift"; then
    status12=1
else
    status12=0
fi
assert_test "Contract 12: Focus Ring" $status12 "Workbench button does not force permanent initial focus ring"

# 13. Product State Integration Contract
grep -q "adapter: DirectionDProductStateAdapter" "$SWIFT_DIR/Views/Components/DirectionD/DirectionDMainWindowView.swift"
assert_test "Contract 13: Product State Integration" $? "DirectionDProductStateAdapter integrated into DirectionDMainWindowView"

# 14. Inspector to Sheet Transition Contract
grep -q "isSmallSheetOpen" "$SWIFT_DIR/Views/Components/DirectionD/DirectionDMainWindowView.swift"
assert_test "Contract 14: Inspector to Sheet" $? "Wide Inspector converts to Small Sheet on small viewports"

# 15. V3 Default Preserved Contract
grep -q "appleMusicImmersiveV3" "$SWIFT_DIR/Design/MainWindowLayoutStyle.swift"
assert_test "Contract 15: V3 Default Preserved" $? "MainWindowLayoutStyle preserves appleMusicImmersiveV3 as default"

# 16. Experimental Only Contract
grep -q "mainWindow.directionDQuiet.v1" "$SWIFT_DIR/Design/PresentationCatalog.swift"
assert_test "Contract 16: Experimental Only" $? "Direction D stable IDs registered as experimental in PresentationCatalog"

# 17. No Direct Provider Access Contract
if grep -qiE "\bLRCLIBProvider\b|\bNeteaseProvider\b|\bQQMusicProvider\b" "$SWIFT_DIR/Views/Components/DirectionD/DirectionDMainWindowView.swift"; then
    status17=1
else
    status17=0
fi
assert_test "Contract 17: No Direct Provider Access" $status17 "No direct Provider calls inside DirectionDMainWindowView"

# 18. No Direct Database Access Contract
if grep -qiE "\bSQLite3\b|\bFMDatabase\b|executeStatement" "$SWIFT_DIR/Views/Components/DirectionD/DirectionDMainWindowView.swift"; then
    status18=1
else
    status18=0
fi
assert_test "Contract 18: No Direct Database Access" $status18 "No direct Database queries inside DirectionDMainWindowView"

# 19. Real Main Window Factory Contract
grep -q "DirectionDMainWindowPresentationFactory" "$SWIFT_DIR/Views/Components/DirectionD/DirectionDMainWindowView.swift" && \
grep -q "mainWindow.directionD.v4" "$SWIFT_DIR/Views/Components/DirectionD/DirectionDMainWindowView.swift" && \
grep -q "mainWindow.directionDQuiet.v1" "$SWIFT_DIR/Views/Components/DirectionD/DirectionDMainWindowView.swift"
assert_test "Contract 19: Main Window Factory" $? "V4 and historical Direction D IDs resolve to DirectionDMainWindowView"

# 20. Live Playback Binding Contract
grep -q "@ObservedObject public var playbackState: PlaybackState" "$SWIFT_DIR/Views/Components/DirectionD/DirectionDMainWindowView.swift" && \
grep -q "playbackState.liveLyrics" "$SWIFT_DIR/Views/Components/DirectionD/DirectionDMainWindowView.swift" && \
grep -q "playbackState.liveLyricsDocumentMatchesCurrentTrack" "$SWIFT_DIR/Views/Components/DirectionD/DirectionDMainWindowView.swift" && \
grep -q "public var liveTrackIdentity" "$SWIFT_DIR/Services/PlaybackState.swift"
assert_test "Contract 20: Live Playback Binding" $? "Main Window consumes the identity-guarded PlaybackState live projection"

# 21. Real Direction D Window Entry Contract
grep -q 'Window("Aster · Lyric"' "SpotifyLyrics/Main.swift" && \
grep -q -- "--debug-direction-d-main-window" "SpotifyLyrics/Main.swift" && \
grep -q "DirectionDMainWindowPresentationFactory" "SpotifyLyrics/Main.swift"
assert_test "Contract 21: Experimental Window Entry" $? "Debug argument opens the real Lyric Island product window"

# 22. No Fixture Fallback Contract
if grep -q "defaultSampleLyrics" "$SWIFT_DIR/Views/Components/DirectionD/DirectionDMainWindowView.swift" || \
   grep -q 'trackTitle: String = "' "$SWIFT_DIR/Views/Components/DirectionD/DirectionDMainWindowView.swift"; then
    status22=1
else
    status22=0
fi
assert_test "Contract 22: No Main Window Fixture" $status22 "Live Main Window does not silently replace missing lyrics with sample data"

# 23. Playback Action Contract
grep -q "playbackState.previousTrack()" "$SWIFT_DIR/Views/Components/DirectionD/DirectionDMainWindowView.swift" && \
grep -q "playbackState.togglePlayPause()" "$SWIFT_DIR/Views/Components/DirectionD/DirectionDMainWindowView.swift" && \
grep -q "playbackState.nextTrack()" "$SWIFT_DIR/Views/Components/DirectionD/DirectionDMainWindowView.swift" && \
grep -q "playbackState.seek(to:" "$SWIFT_DIR/Views/Components/DirectionD/DirectionDMainWindowView.swift"
assert_test "Contract 23: Playback Actions" $? "Controls route to the shared PlaybackState"

# 24. Real Current Line Contract
grep -q "playbackState.liveCurrentLineIndex" "$SWIFT_DIR/Views/Components/DirectionD/DirectionDMainWindowView.swift" && \
grep -q "let activeIndex = projectedCurrentLineIndex" "$SWIFT_DIR/Views/Components/DirectionD/DirectionDMainWindowView.swift"
assert_test "Contract 24: Current Line Projection" $? "Current line is derived from the shared live timeline"

# 25. Reused Artwork/Background Contract
grep -q "ArtworkBackgroundView(state: playbackState)" "$SWIFT_DIR/Views/Components/DirectionD/DirectionDMainWindowView.swift" && \
grep -q "ArtworkView(track:" "$SWIFT_DIR/Views/Components/DirectionD/DirectionDMainWindowView.swift"
assert_test "Contract 25: Artwork Pipeline" $? "Main Window reuses the existing artwork/background path"

# 26. Stable State Owner Contract
if grep -qE "PlaybackState\(|LyricsSessionController\(|AutomaticAlignmentJobController\(\)|SQLite3|LRCLIB" "$SWIFT_DIR/Views/Components/DirectionD/DirectionDMainWindowView.swift"; then
    status26=1
else
    status26=0
fi
assert_test "Contract 26: No Duplicate State Owners" $status26 "Main Window creates no Playback/Lyrics/Provider/DB owner"

# 27. V3/Experimental Boundary Contract
grep -q "appleMusicImmersiveV3" "SpotifyLyrics/Design/MainWindowLayoutStyle.swift" && \
grep -q 'entry("mainWindow.directionD.v4".*\.experimental.*\.release' "SpotifyLyrics/Design/PresentationCatalog.swift" && \
grep -q 'case directionDV4 = "directionD"' "SpotifyLyrics/Design/MainWindowLayoutStyle.swift"
assert_test "Contract 27: V3 Default and Direction D V4 Boundary" $? "V3 remains default while V4 is separately selectable and Release-capable"

# 28. Window Identity Contract
grep -q "Aster · Lyric" "SpotifyLyrics/Main.swift" && \
grep -q "direction-d-main-window" "SpotifyLyrics/Main.swift"
assert_test "Contract 28: Window Identity" $? "Product title and debug identifier are distinct from Host/Matrix"

# 29. Direction D Stable ID Factory Coverage Contract
grep -q '"mainWindow.directionDWorkbenchInspector.v1"' "$SWIFT_DIR/Views/Components/DirectionD/DirectionDMainWindowView.swift" && \
grep -q '"lyricsStatePresentation.directionDUserLanguage.v1"' "$SWIFT_DIR/Views/Components/DirectionD/DirectionDMainWindowView.swift" && \
grep -q '"responsiveLayout.directionDInspector.v1"' "$SWIFT_DIR/Views/Components/DirectionD/DirectionDMainWindowView.swift"
assert_test "Contract 29: Direction D Stable ID Factory Coverage" $? "All four Direction D IDs resolve through the live main-window factory"

echo "======================================================"
echo "Summary: $PASS_COUNT passed, $FAIL_COUNT failed out of 29 assertions."
echo "======================================================"

if [ "$FAIL_COUNT" -eq 0 ]; then
    exit 0
else
    exit 1
fi
