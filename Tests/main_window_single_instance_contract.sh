#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MAIN_FILE="$ROOT_DIR/SpotifyLyrics/Main.swift"

if rg -n '^[[:space:]]*WindowGroup[[:space:]]*\{' "$MAIN_FILE"; then
  echo "main window must not use WindowGroup; duplicate main scenes can race during resize" >&2
  exit 1
fi

if ! rg -n '^[[:space:]]*Window\("Aster · Lyric", id: "main-window"\)[[:space:]]*\{' "$MAIN_FILE"; then
  echo "missing single main-window scene" >&2
  exit 1
fi

echo "main window single-instance contract passed"
