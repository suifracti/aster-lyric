#!/usr/bin/env bash
# One compiled app module; all migrated contracts live in SpotifyLyricsTests.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
exec xcodebuild test -project SpotifyLyrics.xcodeproj -scheme SpotifyLyrics \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath "${LYRICSQ_TEST_DERIVED_DATA:-${TMPDIR:-/tmp}/lyricsq-native-derived}" \
  CODE_SIGNING_ALLOWED=NO "$@"
