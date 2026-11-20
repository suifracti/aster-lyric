#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VIEW="$ROOT/SpotifyLyrics/Views/MainWindow/AppleMusicImmersiveV3Lyrics.swift"
LINE="$ROOT/SpotifyLyrics/Views/Components/LyricLineView.swift"

grep -q 'maxWidth: readableLineWidth' "$VIEW" || {
  echo 'FAIL: V3 ruby rows do not pass their readable column width' >&2
  exit 1
}

grep -q 'let maxWidth: CGFloat?' "$LINE" || {
  echo 'FAIL: ruby flow layout has no explicit width contract' >&2
  exit 1
}

grep -q 'RubyTokenFlowLayout(horizontalSpacing: 0, verticalSpacing: tokenVerticalSpacing, maxWidth: maxWidth, alignmentFraction: textAlignment.lyricAlignmentFraction)' "$LINE" || {
  echo 'FAIL: ruby token flow does not use its explicit width' >&2
  exit 1
}

grep -q 'RubyTokenFlowLayout(horizontalSpacing: 0, verticalSpacing: 5, maxWidth: maxWidth, alignmentFraction: textAlignment.lyricAlignmentFraction)' "$LINE" || {
  echo 'FAIL: kana replacement flow does not use its explicit width' >&2
  exit 1
}

echo 'V3 long ruby wrap contract: PASS'
