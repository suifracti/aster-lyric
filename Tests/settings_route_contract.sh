#!/usr/bin/env bash
# Migrated to XCTest; see Tests/NATIVE_TESTS.md.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
exec bash "$ROOT_DIR/Scripts/test-native.sh" -only-testing:SpotifyLyricsTests/MenuBarPresentationTests "$@"
