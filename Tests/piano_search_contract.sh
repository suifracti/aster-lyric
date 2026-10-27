#!/usr/bin/env bash
# Compile against the real app module; the standalone source list had drifted.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
if [[ " ${*:-} " == *" live "* ]]; then
  echo "NOT_RUN: this contract is offline; use the app for a live provider search." >&2
  exit 2
fi
exec bash "$ROOT_DIR/Scripts/test-native.sh" -only-testing:SpotifyLyricsTests/ProviderFailureContractTests/testPianoRecordingKeepsArrangementAndArtistIdentityRules "$@"
