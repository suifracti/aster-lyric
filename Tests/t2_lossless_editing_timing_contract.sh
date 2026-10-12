#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d /tmp/spotifylyrics-t2-lossless.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT
cp "$ROOT_DIR/Tests/t2_lossless_editing_timing_contract.swift" "$TMP_DIR/main.swift"

swiftc -D DEBUG -parse-as-library \
  "$ROOT_DIR/SpotifyLyrics/Models/Models.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/TrackIdentity.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/LyricsModels.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/AlignmentModels.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/TrackAlias.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/TrackMetadata.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/TrackTextNormalizer.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/JapaneseRomanizer.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/JapaneseReadingPipeline.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/JapaneseKanaGenerator.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/LyricsMatcher.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/LyricsSafeMatcher.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/LyricsQueryPlanner.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/LyricsRecoveryModels.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/LyricsE2ELog.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/LyricsSearchManager.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/CompositeLyricsProvider.swift" \
  "$ROOT_DIR/SpotifyLyrics/Capture/AssistedAlignmentDraft.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/LRCParser.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/TTMLParser.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/YRCParser.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/LocalAlignedLyricsStore.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/PersonalLyricsLibraryModels.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/ListeningHistoryModels.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/ListeningStatisticsModels.swift" \
  "$ROOT_DIR/SpotifyLyrics/Search/SongSearchModels.swift" \
  "$ROOT_DIR/SpotifyLyrics/Search/TrackSearchModels.swift" \
  "$ROOT_DIR/SpotifyLyrics/Search/LocalLyricsIndex.swift" \
  "$ROOT_DIR/SpotifyLyrics/Services/LyricsSessionController.swift" \
  "$ROOT_DIR/SpotifyLyrics/Editor/TextLyricsImport.swift" \
  "$ROOT_DIR/SpotifyLyrics/Editor/LRCImportExport.swift" \
  "$ROOT_DIR/SpotifyLyrics/Editor/LyricsEditorModels.swift" \
  "$ROOT_DIR/SpotifyLyrics/Editor/LyricsTimelineValidator.swift" \
  "$ROOT_DIR/SpotifyLyrics/AI/AITranslationModels.swift" \
  "$ROOT_DIR/SpotifyLyrics/AI/AITranslationConfiguration.swift" \
  "$ROOT_DIR/SpotifyLyrics/Persistence/DatabaseModels.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/ReadingModels.swift" \
  "$ROOT_DIR/SpotifyLyrics/Persistence/DatabaseMigrator.swift" \
  "$ROOT_DIR/SpotifyLyrics/Persistence/LyricsRepository.swift" \
  "$ROOT_DIR/SpotifyLyrics/Persistence/AlignmentProvenanceStore.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/LyricsLanguageGate.swift" \
  "$ROOT_DIR/SpotifyLyrics/Persistence/LyricsPersistenceMapper.swift" \
  "$ROOT_DIR/SpotifyLyrics/Persistence/TranslationRepository.swift" \
  "$ROOT_DIR/SpotifyLyrics/Persistence/LyricsEditingRepository.swift" \
  "$ROOT_DIR/SpotifyLyrics/Persistence/SQLiteLyricsRepository.swift" \
  "$ROOT_DIR/SpotifyLyrics/DebugDatabaseSafety.swift" \
  "$ROOT_DIR/SpotifyLyrics/Settings/ScopedLyricsOffsetStore.swift" \
  "$ROOT_DIR/SpotifyLyrics/Services/LyricsEditorSessionController.swift" \
  "$TMP_DIR/main.swift" \
  -o "$TMP_DIR/t2-lossless-editing-timing-contract"

"$TMP_DIR/t2-lossless-editing-timing-contract" "${1:-all}"
