#!/usr/bin/env bash
# Run the contracts against the same app module and isolated data as the native suite.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
rg -q 'session.prepareTranslation\(\)' "$ROOT_DIR/SpotifyLyrics/AI/AITranslationService.swift"
exec bash "$ROOT_DIR/Scripts/test-native.sh" -only-testing:SpotifyLyricsTests/AITranslationContractTests "$@"
