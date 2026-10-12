#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d /tmp/spotifylyrics-b0-clock.XXXXXX)"
SUITE="com.spotifylyrics.tests.b0-clock.$(basename "$TMP_DIR")"
TEMP_DATABASE="$TMP_DIR/b0.sqlite3"
trap 'rm -rf "$TMP_DIR"' EXIT

swiftc -parse-as-library \
  "$ROOT_DIR/SpotifyLyrics/Models/Models.swift" \
  "$ROOT_DIR/Tests/b0_clock_offset_truth_contract.swift" \
  -o "$TMP_DIR/b0-clock-offset-contract"

B0_DEFAULTS_SUITE="$SUITE" \
B0_TEMP_DATABASE="$TEMP_DATABASE" \
  "$TMP_DIR/b0-clock-offset-contract"

STATE="$ROOT_DIR/SpotifyLyrics/Services/PlaybackState.swift"
SETTINGS="$ROOT_DIR/SpotifyLyrics/Settings/AppSettingsStore.swift"
OFFSET_CONTROL="$ROOT_DIR/SpotifyLyrics/Views/Components/LyricsPreferencesPopover.swift"
V3="$ROOT_DIR/SpotifyLyrics/Views/MainWindow/AppleMusicImmersiveV3WindowView.swift"
FULLSCREEN="$ROOT_DIR/SpotifyLyrics/Views/Fullscreen/FullScreenLyricsView.swift"

grep -Fq 'public static let lyricsPresentationOffset = "lyrics.presentationOffset.v1"' "$SETTINGS"
grep -Fq 'public let lyricsOffsetStore: ScopedLyricsOffsetStore' "$SETTINGS"
grep -Fq 'public var legacyLyricsPresentationOffset: Double?' "$SETTINGS"
grep -Fq 'presentationOffset: settingsStore.lyricsOffsetStore.activeOffset' "$STATE"
grep -Fq 'Button("提前 0.10s") { adjust(0.1) }' "$OFFSET_CONTROL"
grep -Fq 'Button("延后 0.10s") { adjust(-0.1) }' "$OFFSET_CONTROL"
grep -Fq 'offsetStore.setValue(offset + delta, for: scope)' "$OFFSET_CONTROL"
grep -Fq 'Button("归零") { reset() }' "$OFFSET_CONTROL"
grep -Fq 'settings.lyricsOffsetStore.resetActiveValue()' "$V3"
grep -Fq 'let rawValue = draftPosition ?? state.presentationClock.playbackTime' "$V3"
grep -Fq 'min(max(playbackPosition / duration, 0), 1)' "$V3"
grep -Fq 'state.seek(to: min(max(draftPosition, 0), duration), source: "v3-progress-slider")' "$V3"
grep -Fq 'AppleMusicImmersiveV3WindowView(state: state, settings: settings,' "$FULLSCREEN"
grep -Fq 'liveOnly: true' "$FULLSCREEN"

if sed -n '/struct LyricsPresentationOffsetControl/,/^}/p' "$OFFSET_CONTROL" | grep -Eq '\bseek\s*\('; then
  echo 'FAIL: offset control contains a seek call' >&2
  exit 1
fi

if rg -n 'settingsStore\.lyricsPresentationOffset|settings\.lyricsPresentationOffset|defaults\.set\([^\n]*Key\.lyricsPresentationOffset' \
  "$STATE" "$OFFSET_CONTROL" "$V3" "$SETTINGS"; then
  echo 'FAIL: runtime consumers still read/write the historical global offset' >&2
  exit 1
fi

echo 'PASS: B0 source routing assertions (clock/settings/V3/fullscreen/no offset seek)'
