#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VIEW="$ROOT/SpotifyLyrics/Views/MainWindow/AppleMusicImmersiveV3Lyrics.swift"

test -f "$VIEW" || { echo "FAIL: missing V3 lyrics view" >&2; exit 1; }

row="$({
  sed -n '/private struct AppleMusicImmersiveV3LyricRowContent/,/^private struct AppleMusicImmersiveV3TimedRowView/p' "$VIEW"
} || true)"

if [[ -z "$row" ]]; then
  echo 'FAIL: could not extract V3 lyric row content' >&2
  exit 1
fi

if grep -Eq 'if isActive \{ return \.heavy \}' <<<"$row"; then
  echo 'FAIL: V3 still changes font weight when a row becomes active' >&2
  exit 1
fi

grep -Eq 'V3LyricMotionPolicy\.layoutWeight' <<<"$row" || {
  echo 'FAIL: V3 row must render with the shared layout weight' >&2
  exit 1
}

grep -Eq 'V3LyricMotionPolicy\.layoutNSWeight' <<<"$row" || {
  echo 'FAIL: V3 wrap measurement must use the shared layout weight' >&2
  exit 1
}

if grep -Eq 'Font\.Weight\.heavy\.nsWeightValue' <<<"$row"; then
  echo 'FAIL: V3 wrap measurement still uses heavy weight instead of the shared layout weight' >&2
  exit 1
fi

# Timed wrap must be computed for inactive rows too, then only the active
# row attaches the 60fps fill clock.
grep -Eq 'if let timedSpans = line\.timedSpans, !timedSpans\.isEmpty' <<<"$row" || {
  echo 'FAIL: timed multiline layout must not be gated on isActive' >&2
  exit 1
}

if grep -Eq 'if isActive, let timedSpans = line\.timedSpans' <<<"$row"; then
  echo 'FAIL: timed layout is still created only for the active row' >&2
  exit 1
fi

grep -q 'showsFill: isActive' "$VIEW" || {
  echo 'FAIL: timed rows must keep the same wrap and only fill the active line' >&2
  exit 1
}

viewport="$({
  sed -n '/^struct AppleMusicImmersiveV3LyricsViewport:/,/^private struct AppleMusicImmersiveV3LyricsDocumentView:/p' "$VIEW"
} || true)"

grep -q 'AppleMusicImmersiveV3LyricsDocumentView' <<<"$viewport" || {
  echo 'FAIL: V3 lyrics document must be an Equatable subtree that does not observe currentTime' >&2
  exit 1
}

grep -q '.equatable()' <<<"$viewport" || {
  echo 'FAIL: V3 lyrics document must skip equal playback-tick refreshes' >&2
  exit 1
}

if grep -Eq '\.animation\([^,]+,[[:space:]]*value: rowSpacing' <<<"$viewport"; then
  echo 'FAIL: V3 still interpolates row spacing during reflow' >&2
  exit 1
fi

echo 'PASS: V3 lyric layout stability contract'
