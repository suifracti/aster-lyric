#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
V3="$ROOT/SpotifyLyrics/Views/MainWindow/AppleMusicImmersiveV3Lyrics.swift"

test -f "$V3" || { echo "FAIL: missing V3 lyrics view" >&2; exit 1; }

viewport="$({
  sed -n '/^struct AppleMusicImmersiveV3LyricsViewport:/,/^private struct AppleMusicImmersiveV3LyricsDocumentView:/p' "$V3"
} || true)"

# The V3 rows change height when the active line and auxiliary layers change.
# SwiftUI's lazy anchor-placement path can spin indefinitely when an animated
# scrollTo happens during that reflow. Keep this modest document eager and let
# ScrollViewReader own only the scroll animation.
if grep -Eq '^[[:space:]]*LazyVStack' <<<"$viewport"; then
  echo 'FAIL: V3 lyric viewport must not use LazyVStack with variable-height rows' >&2
  exit 1
fi

grep -q 'AppleMusicImmersiveV3LyricsDocumentView' <<<"$viewport" || {
  echo 'FAIL: V3 lyric viewport must host an eager document subtree' >&2
  exit 1
}

grep -Eq 'VStack\(alignment: .*spacing: rowSpacing\)' "$V3" || {
  echo 'FAIL: V3 lyric document must use an eager stack with the shared row spacing' >&2
  exit 1
}

grep -q 'onChange(of: displayedIndex)' <<<"$viewport" || {
  echo 'FAIL: V3 scrolling must be driven by line changes, not playback ticks' >&2
  exit 1
}

# Main V3 intentionally includes search preview and secondary windows use the
# live projection. Both paths must snapshot their selected document once per
# refresh instead of rebuilding rows from a playback tick.
grep -q 'let lines = documentLines' <<<"$viewport" || {
  echo 'FAIL: V3 does not snapshot the selected lyric document once per refresh' >&2
  exit 1
}

grep -Eq 'let currentIndex = liveOnly \? state\.liveCurrentLineIndex : state\.currentLineIndex' <<<"$viewport" || {
  echo 'FAIL: V3 must choose the active row from the selected document projection' >&2
  exit 1
}

grep -q 'trackStableKey: trackStableKey' <<<"$viewport" || {
  echo 'FAIL: V3 rows still recompute TrackIdentity independently' >&2
  exit 1
}

body="$(sed -n '/^    var body: some View/,/^    private var focusEmptyState:/p' <<<"$viewport")"
signature="$(sed -n '/^    private var renderSignature:/,/^    private func scheduleContentRefresh()/p' <<<"$viewport")"
if [[ "$(grep -c 'state.liveCurrentLineIndex' <<<"$body" || true)" -ne 1 \
   || "$(grep -c 'state.liveCurrentLineIndex' <<<"$signature" || true)" -ne 1 \
   || "$(grep -c 'state.liveCurrentLineIndex' <<<"$viewport" || true)" -ne 2 ]]; then
  echo 'FAIL: V3 must read the active index only in the render signature and viewport body' >&2
  exit 1
fi

if grep -q 'onChange(of: state.currentTime)' <<<"$viewport"; then
  echo 'FAIL: V3 scrolling must not react to every playback tick' >&2
  exit 1
fi

echo 'PASS: V3 lyric scroll stability contract'
