#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
TMP_DIR="$(mktemp -d /tmp/spotifylyrics-library-revisions.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT
git show HEAD:SpotifyLyrics/Persistence/TranslationRepository.swift > "$TMP_DIR/TranslationRepository.swift"

swiftc -parse-as-library \
  SpotifyLyrics/Models/Models.swift \
  SpotifyLyrics/DebugDatabaseSafety.swift \
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
  SpotifyLyrics/Lyrics/LyricsE2ELog.swift \
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
  "$TMP_DIR/TranslationRepository.swift" \
  SpotifyLyrics/Persistence/LyricsEditingRepository.swift \
  SpotifyLyrics/Persistence/SQLiteLyricsRepository.swift \
  Tests/library_revisions_contract.swift \
  -o "$TMP_DIR/library-revisions-contract"

"$TMP_DIR/library-revisions-contract"
