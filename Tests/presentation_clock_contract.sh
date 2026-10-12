#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
TMP_DIR="$(mktemp -d /tmp/spotifylyrics-clock-test.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT
PLAYBACK_STATE="SpotifyLyrics/Services/PlaybackState.swift"

swiftc -parse-as-library SpotifyLyrics/Models/Models.swift Tests/presentation_clock_contract.swift -o "$TMP_DIR/clock_test"
"$TMP_DIR/clock_test"

rg -q 'PlaybackTickTimeUpdatePolicy\.shouldPublish\(currentTime: currentTime, nextTime: nextTime\)' "$PLAYBACK_STATE"
rg -q 'PlaybackTickTimeUpdatePolicy\.shouldFinishMockPlayback\(' "$PLAYBACK_STATE"
if sed -n '/private func tick()/,/private func publishTickTime/p' "$PLAYBACK_STATE" | grep -Eq 'currentTime[[:space:]]*='; then
  echo 'FAIL: periodic tick bypasses same-value publication guard' >&2
  exit 1
fi
