#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VIEW="$ROOT/SpotifyLyrics/Views/MainWindow/AppleMusicImmersiveV3Lyrics.swift"
TOKENS="$ROOT/SpotifyLyrics/Design/LyricsDesignTokens.swift"

require_view() {
  local pattern="$1"
  local label="$2"
  if ! grep -Eq "$pattern" "$VIEW"; then
    echo "FAIL: $label (missing /$pattern/)" >&2
    exit 1
  fi
}

require_file() {
  local file="$1"
  local pattern="$2"
  local label="$3"
  if ! grep -Eq "$pattern" "$file"; then
    echo "FAIL: $label (missing /$pattern/)" >&2
    exit 1
  fi
}

forbid_view() {
  local pattern="$1"
  local label="$2"
  if grep -Eq "$pattern" "$VIEW"; then
    echo "FAIL: $label (found /$pattern/)" >&2
    exit 1
  fi
}

require_file "$TOKENS" 'enum LyricsTransitionStyle' 'shared lyric transition policy'
require_file "$TOKENS" 'enum V3LyricMotionPolicy' 'V3 motion policy is explicit'
require_file "$TOKENS" 'static let followDuration: Double = 0.40' 'V3 line follow is 0.40s'
require_file "$TOKENS" 'static let layoutWeight: Font.Weight = \.semibold' 'V3 wrap weight is independent of the active row'
require_file "$TOKENS" 'static func followAnimation' 'V3 follow animation is policy-owned'
require_file "$TOKENS" 'smoothRelayoutV1' 'smooth lyric transition preset'
require_file "$TOKENS" 'lyricDuration' 'dedicated lyric transition duration'

require_view 'onChange\(of: displayedIndex\)' 'current-line transition trigger'
require_view 'private var v3LineFollowAnimation' 'V3 uses a dedicated follow animation'
require_view 'V3LyricMotionPolicy\.followAnimation' 'V3 follow uses the isolated motion policy'
require_view 'DispatchQueue\.main\.async' 'scroll animation is deferred off the layout transaction'
require_view 'withAnimation\(v3LineFollowAnimation' 'scroll follows the already-published active line'

forbid_view '\.easeOut\(duration: 0\.12\)' 'V3 line follow must not use the old 0.12s easeOut yank'

if grep -q 'value: state.liveCurrentLineIndex' "$VIEW"; then
  echo 'FAIL: V3 lyric stack still animates the entire document on every current-line update' >&2
  exit 1
fi

if ! grep -qF '.animation(nil, value: isActive)' "$VIEW"; then
  echo 'FAIL: V3 active-line handoff must not interpolate layout' >&2
  exit 1
fi

if ! grep -qF '.animation(nil, value: layoutSignature)' "$VIEW"; then
  echo 'FAIL: V3 wrap/layout signature must not interpolate' >&2
  exit 1
fi

if grep -qF '.animation(transitionAnimation, value: layoutSignature)' "$VIEW"; then
  echo 'FAIL: V3 still interpolates wrap through layoutSignature' >&2
  exit 1
fi

if sed -n '/private func scrollToCurrentLine/,/^    }/p' "$VIEW" | grep -q 'LyricsTransitionPolicy.perform'; then
  echo 'FAIL: V3 current-line handoff still delegates to the 0.34s shared relayout animation' >&2
  exit 1
fi

echo 'V3 lyric transition contract: PASS'
