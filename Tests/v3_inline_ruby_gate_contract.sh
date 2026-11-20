#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VIEW="$ROOT/SpotifyLyrics/Views/MainWindow/AppleMusicImmersiveV3Lyrics.swift"
# Verify the view consumes the shared projection and gates on usable annotations.
grep -Fq 'private var inlineRubyTokens: [LyricRubyToken]? { rubyPresentation.rubyTokens }' "$VIEW"
grep -Fq 'preferences.showOriginal && shouldShowRuby && rubyPresentation.hasRuby' "$VIEW"
grep -Fq 'tokens: inlineRubyTokens' "$VIEW"
grep -Fq 'return V3JapaneseReadingCache.resolvedPresentation(' "$VIEW"
# Exercise alignment, partial unknown, authority, legacy precedence and no-timing behavior.
bash "$ROOT/Tests/japanese_ruby_restoration_contract.sh"
echo 'V3 inline ruby gate contract: PASS'
