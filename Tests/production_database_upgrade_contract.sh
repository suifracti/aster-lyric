#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
TMP_DIR="$(mktemp -d /tmp/spotifylyrics-production-upgrade.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

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
  SpotifyLyrics/Lyrics/LocalAlignedLyricsStore.swift \
  SpotifyLyrics/Lyrics/ReadingModels.swift \
  SpotifyLyrics/Lyrics/PersonalLyricsLibraryModels.swift \
  SpotifyLyrics/Lyrics/ListeningHistoryModels.swift \
  SpotifyLyrics/Lyrics/ListeningStatisticsModels.swift \
  SpotifyLyrics/Search/SongSearchModels.swift \
  SpotifyLyrics/Search/TrackSearchModels.swift \
  SpotifyLyrics/Search/LocalLyricsIndex.swift \
  SpotifyLyrics/Services/LyricsSessionController.swift \
  SpotifyLyrics/Editor/LyricsEditorModels.swift \
  SpotifyLyrics/Editor/LyricsTimelineValidator.swift \
  SpotifyLyrics/AI/AITranslationModels.swift \
  SpotifyLyrics/Persistence/DatabaseModels.swift \
  SpotifyLyrics/Persistence/DatabaseMigrator.swift \
  SpotifyLyrics/Persistence/LyricsRepository.swift \
  SpotifyLyrics/Persistence/AlignmentProvenanceStore.swift \
  SpotifyLyrics/Lyrics/LyricsLanguageGate.swift \
  SpotifyLyrics/Persistence/LyricsPersistenceMapper.swift \
  SpotifyLyrics/Persistence/TranslationRepository.swift \
  SpotifyLyrics/Persistence/LyricsEditingRepository.swift \
  SpotifyLyrics/Persistence/SQLiteLyricsRepository.swift \
  SpotifyLyrics/DebugDatabaseSafety.swift \
  Tests/production_database_upgrade_contract.swift \
  -o "$TMP_DIR/production-upgrade-contract"

CFFIXED_USER_HOME="$TMP_DIR/home" UPGRADE_FIXTURE_EXPORT="$TMP_DIR/v5.sqlite3" "$TMP_DIR/production-upgrade-contract"

if [[ -n "${UPGRADE_AUDIT_BINARY:-}" ]]; then cp "$TMP_DIR/production-upgrade-contract" "$UPGRADE_AUDIT_BINARY"; fi

CFFIXED_USER_HOME="$TMP_DIR/m1-home" "$TMP_DIR/production-upgrade-contract" --m1-migrations
