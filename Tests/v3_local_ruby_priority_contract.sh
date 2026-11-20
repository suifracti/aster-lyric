#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VIEW="$ROOT/SpotifyLyrics/Views/MainWindow/AppleMusicImmersiveV3Lyrics.swift"
grep -Fq 'storedRubyIsAuthoritative: line.readingRepresentationID == ReadingRepresentationID.kana.rawValue' "$VIEW"
grep -Fq 'providerKana.map { JapaneseReadingPipeline.analyze(originalText: normalizedText, providerKana: $0) } ?? JapaneseContextualReadingEngine.analyze(' "$VIEW"
bash "$ROOT/Tests/v3_inline_ruby_gate_contract.sh"
echo 'V3 local ruby priority contract: PASS'
