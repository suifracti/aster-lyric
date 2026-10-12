#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODELS="$ROOT/SpotifyLyrics/Models/Models.swift"
LINE="$ROOT/SpotifyLyrics/Views/Components/LyricLineView.swift"
TOKENS="$ROOT/SpotifyLyrics/Design/LyricsDesignTokens.swift"
ENRICHER="$ROOT/SpotifyLyrics/Lyrics/LyricsRecoveryModels.swift"
ALIGN="$ROOT/SpotifyLyrics/Lyrics/AlignmentModels.swift"

require() {
  local file="$1"
  local pattern="$2"
  local label="$3"
  grep -Eq "$pattern" "$file" || {
    echo "FAIL: $label ($file does not contain /$pattern/)" >&2
    exit 1
  }
}

require "$MODELS" 'struct LyricRubyToken' 'line-level ruby token model'
require "$MODELS" 'rubyTokens' 'ruby token storage on lyric lines'
require "$ENRICHER" 'reading\.tokens' 'ruby tokens come from morphology'
require "$ENRICHER" 'reading\.isTokenAligned' 'line-only readings cannot become whole-line ruby'
require "$ENRICHER" 'rubyTokens:' 'enrichment preserves/generated ruby tokens'
require "$ALIGN" 'rubyTokens' 'alignment preserves ruby tokens'

# SwiftUI word blocks: ruby above base, with a flow layout for long lines.
require "$LINE" 'RubyTokenFlowLayout' 'ruby flow layout'
require "$LINE" 'RubyTokenBlockLayout' 'ruby/base token layout'
require "$LINE" 'lastTextBaseline' 'shared base text baseline'
require "$LINE" 'explicitAlignment' 'explicit ruby baseline propagation'
require "$LINE" 'rubyFontSize' 'responsive ruby size'
require "$LINE" '0\.5[0-9]' 'ruby is approximately half-to-sixty-percent of base'
require "$LINE" 'fixedSize\(horizontal: true' 'ruby overhang is not compressed'
require "$LINE" 'baseSize' 'base width drives token layout'
require "$LINE" 'annotationOverhang' 'wide ruby uses bounded visual overhang'
require "$LINE" 'katakanaAnnotationTracking' 'katakana annotation has dedicated optical tracking'
require "$LINE" 'groupEdgeReserve' 'ruby overhang is reserved at morphology-group edges'
require "$LINE" '\.padding\(\.horizontal, groupEdgeReserve\)' 'ruby overhang cannot collide with adjacent groups'

# Visual hierarchy and rhythm.
require "$LINE" 'rubyOpacity' 'ruby contrast hierarchy'
require "$LINE" 'auxiliaryTopSpacing' 'auxiliary layer spacing'
require "$TOKENS" 'lyricRowSpacing' 'paragraph/block spacing'

if grep -Eq 'CTRubyAnnotation' "$LINE"; then
  echo 'FAIL: CoreText ruby is not the selected SwiftUI V1 path' >&2
  exit 1
fi

TMP_DIR="$(mktemp -d /tmp/ruby-token-contract.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT
swiftc -parse-as-library \
  "$ROOT/SpotifyLyrics/DebugDatabaseSafety.swift" \
  "$ROOT/SpotifyLyrics/Models/Models.swift" \
  "$ROOT/SpotifyLyrics/Lyrics/JapaneseRomanizer.swift" \
  "$ROOT/SpotifyLyrics/Lyrics/JapaneseReadingPipeline.swift" \
  "$ROOT/Tests/ruby_token_contract.swift" \
  -o "$TMP_DIR/ruby-token-contract"
"$TMP_DIR/ruby-token-contract"

echo 'PASS: ruby layout contract'
