#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT
cat > "$BUILD/logger.swift" <<'SWIFT'
enum LyricsE2ELog { static func log(_ message: String) {} }
SWIFT
swiftc -parse-as-library \
  "$ROOT/SpotifyLyrics/Models/Models.swift" \
  "$ROOT/SpotifyLyrics/Lyrics/TrackIdentity.swift" \
  "$ROOT/SpotifyLyrics/Lyrics/LyricsModels.swift" \
  "$ROOT/SpotifyLyrics/Lyrics/AlignmentModels.swift" \
  "$ROOT/SpotifyLyrics/Lyrics/TrackAlias.swift" \
  "$ROOT/SpotifyLyrics/Lyrics/TrackMetadata.swift" \
  "$ROOT/SpotifyLyrics/Lyrics/TrackTextNormalizer.swift" \
  "$ROOT/SpotifyLyrics/Lyrics/JapaneseRomanizer.swift" \
  "$ROOT/SpotifyLyrics/Lyrics/JapaneseReadingPipeline.swift" \
  "$ROOT/SpotifyLyrics/Lyrics/JapaneseKanaGenerator.swift" \
  "$ROOT/SpotifyLyrics/Lyrics/LyricsQueryPlanner.swift" \
  "$ROOT/SpotifyLyrics/Lyrics/LyricsSafeMatcher.swift" \
  "$ROOT/SpotifyLyrics/Lyrics/LyricsRecoveryModels.swift" \
  "$ROOT/SpotifyLyrics/Providers/LinkCoreLyricsProvider.swift" \
  "$ROOT/SpotifyLyrics/Lyrics/LyricsSearchManager.swift" \
  "$BUILD/logger.swift" \
  "$ROOT/Tests/search_timeout_contract.swift" \
  -o "$BUILD/search-timeout-contract"
"$BUILD/search-timeout-contract"
