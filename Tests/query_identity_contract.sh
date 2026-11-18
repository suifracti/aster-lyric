#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

SOURCES=(
  "$ROOT_DIR/SpotifyLyrics/Models/Models.swift"
  "$ROOT_DIR/SpotifyLyrics/Lyrics/TrackIdentity.swift"
  "$ROOT_DIR/SpotifyLyrics/Lyrics/LyricsModels.swift"
  "$ROOT_DIR/SpotifyLyrics/Lyrics/AlignmentModels.swift"
  "$ROOT_DIR/SpotifyLyrics/Lyrics/TrackAlias.swift"
  "$ROOT_DIR/SpotifyLyrics/Lyrics/TrackMetadata.swift"
  "$ROOT_DIR/SpotifyLyrics/Lyrics/TrackTextNormalizer.swift"
  "$ROOT_DIR/SpotifyLyrics/Lyrics/ReadingModels.swift"
  "$ROOT_DIR/SpotifyLyrics/Lyrics/ReadingScriptConversion.swift"
  "$ROOT_DIR/SpotifyLyrics/Lyrics/JapaneseRomanizer.swift"
  "$ROOT_DIR/SpotifyLyrics/Lyrics/JapaneseReadingPipeline.swift"
  "$ROOT_DIR/SpotifyLyrics/Lyrics/JapaneseKanaGenerator.swift"
  "$ROOT_DIR/SpotifyLyrics/Lyrics/LyricsQueryPlanner.swift"
  "$ROOT_DIR/SpotifyLyrics/Lyrics/LyricsSafeMatcher.swift"
  "$ROOT_DIR/Tests/query_identity_contract.swift"
)

swiftc -parse-as-library "${SOURCES[@]}" -o "$TMP_DIR/query-identity-contract"
"$TMP_DIR/query-identity-contract"
