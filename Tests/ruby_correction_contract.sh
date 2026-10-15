#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d /tmp/spotifylyrics-reading-engines.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

swiftc -parse-as-library \
  "$ROOT_DIR/SpotifyLyrics/DebugDatabaseSafety.swift" \
  "$ROOT_DIR/SpotifyLyrics/Models/Models.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/TrackIdentity.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/ReadingModels.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/ReadingSettings.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/ReadingLanguageGate.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/LyricsModels.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/AlignmentModels.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/JapaneseRomanizer.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/JapaneseReadingPipeline.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/JapaneseKanaGenerator.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/JapaneseReadingEngines.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/ChinesePinyinReadingEngine.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/ReadingScriptConversion.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/ReadingUserDictionary.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/ReadingEngineRegistry.swift" \
  "$ROOT_DIR/Tests/ruby_correction_contract.swift" \
  -o "$TMP_DIR/ruby_correction_contract"

"$TMP_DIR/ruby_correction_contract"
