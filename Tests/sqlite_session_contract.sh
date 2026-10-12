#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
TMP_DIR="$(mktemp -d /tmp/spotifylyrics-sqlite-session.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT
cp Tests/sqlite_session_contract.swift "$TMP_DIR/main.swift"

cat > "$TMP_DIR/logger.swift" <<'SWIFT'
import Foundation
enum LyricsE2ELog { static func log(_ message: String) { print(message) } }
SWIFT
swiftc -D DEBUG -parse-as-library \
  SpotifyLyrics/Models/Models.swift \
  SpotifyLyrics/Lyrics/TrackIdentity.swift \
  SpotifyLyrics/Lyrics/LyricsModels.swift \
  SpotifyLyrics/Lyrics/AlignmentModels.swift \
  SpotifyLyrics/Lyrics/TrackAlias.swift \
  SpotifyLyrics/Lyrics/TrackMetadata.swift \
  SpotifyLyrics/Lyrics/TrackTextNormalizer.swift \
  SpotifyLyrics/Lyrics/JapaneseRomanizer.swift \
  SpotifyLyrics/Lyrics/JapaneseReadingPipeline.swift \
  SpotifyLyrics/Lyrics/JapaneseKanaGenerator.swift \
  SpotifyLyrics/Lyrics/LyricsMatcher.swift \
  SpotifyLyrics/Lyrics/LyricsSafeMatcher.swift \
  SpotifyLyrics/Lyrics/LyricsQueryPlanner.swift \
  SpotifyLyrics/Lyrics/LyricsRecoveryModels.swift \
  "$TMP_DIR/logger.swift" \
  SpotifyLyrics/Lyrics/LyricsSearchManager.swift \
  SpotifyLyrics/Lyrics/CompositeLyricsProvider.swift \
  SpotifyLyrics/Lyrics/LRCParser.swift \
  SpotifyLyrics/Lyrics/PersonalLyricsLibraryModels.swift \
  SpotifyLyrics/Lyrics/ListeningHistoryModels.swift \
  SpotifyLyrics/Lyrics/ListeningStatisticsModels.swift \
  SpotifyLyrics/Lyrics/LocalAlignedLyricsStore.swift \
  SpotifyLyrics/Search/SongSearchModels.swift \
  SpotifyLyrics/Search/TrackSearchModels.swift \
  SpotifyLyrics/Search/LocalLyricsIndex.swift \
  SpotifyLyrics/Services/LyricsSessionController.swift \
  SpotifyLyrics/Editor/LyricsEditorModels.swift \
  SpotifyLyrics/Editor/LyricsTimelineValidator.swift \
  SpotifyLyrics/AI/AITranslationModels.swift \
  SpotifyLyrics/Persistence/DatabaseModels.swift \
  SpotifyLyrics/Lyrics/ReadingModels.swift \
  SpotifyLyrics/Persistence/DatabaseMigrator.swift \
  SpotifyLyrics/Persistence/LyricsRepository.swift \
  SpotifyLyrics/Persistence/AlignmentProvenanceStore.swift \
  SpotifyLyrics/Lyrics/LyricsLanguageGate.swift \
  SpotifyLyrics/Persistence/LyricsPersistenceMapper.swift \
  SpotifyLyrics/Persistence/TranslationRepository.swift \
  SpotifyLyrics/Persistence/LyricsEditingRepository.swift \
  SpotifyLyrics/Persistence/SQLiteLyricsRepository.swift \
  SpotifyLyrics/DebugDatabaseSafety.swift \
  "$TMP_DIR/main.swift" \
  -o "$TMP_DIR/sqlite-session-contract"

"$TMP_DIR/sqlite-session-contract"
