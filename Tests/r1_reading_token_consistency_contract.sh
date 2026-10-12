#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d /tmp/spotifylyrics-r1-reading-token.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT
cp "$ROOT_DIR/Tests/r1_reading_token_consistency_contract.swift" "$TMP_DIR/main.swift"

swiftc -D DEBUG -parse-as-library \
  "$ROOT_DIR/SpotifyLyrics/Models/Models.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/TrackIdentity.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/LyricsModels.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/AlignmentModels.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/TrackAlias.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/TrackMetadata.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/TrackTextNormalizer.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/LyricsE2ELog.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/JapaneseRomanizer.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/JapaneseReadingPipeline.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/JapaneseKanaGenerator.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/JapaneseReadingEngines.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/ChinesePinyinReadingEngine.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/ReadingModels.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/ReadingSettings.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/ReadingLanguageGate.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/ReadingScriptConversion.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/ReadingUserDictionary.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/ReadingEngineRegistry.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/ReadingSessionController.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/ListeningHistoryModels.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/ListeningStatisticsModels.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/PersonalLyricsLibraryModels.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/LyricsMatcher.swift" \
  "$ROOT_DIR/SpotifyLyrics/Editor/LyricsEditorModels.swift" \
  "$ROOT_DIR/SpotifyLyrics/Editor/LyricsTimelineValidator.swift" \
  "$ROOT_DIR/SpotifyLyrics/AI/AITranslationModels.swift" \
  "$ROOT_DIR/SpotifyLyrics/Persistence/DatabaseModels.swift" \
  "$ROOT_DIR/SpotifyLyrics/Persistence/DatabaseMigrator.swift" \
  "$ROOT_DIR/SpotifyLyrics/Persistence/LyricsRepository.swift" \
  "$ROOT_DIR/SpotifyLyrics/Persistence/AlignmentProvenanceStore.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/LyricsLanguageGate.swift" \
  "$ROOT_DIR/SpotifyLyrics/Persistence/LyricsPersistenceMapper.swift" \
  "$ROOT_DIR/SpotifyLyrics/Persistence/TranslationRepository.swift" \
  "$ROOT_DIR/SpotifyLyrics/Persistence/LyricsEditingRepository.swift" \
  "$ROOT_DIR/SpotifyLyrics/Persistence/SQLiteLyricsRepository.swift" \
  "$ROOT_DIR/SpotifyLyrics/DebugDatabaseSafety.swift" \
  "$TMP_DIR/main.swift" \
  -o "$TMP_DIR/r1-reading-token-consistency-contract"

if (($#)); then
  "$TMP_DIR/r1-reading-token-consistency-contract" "$@"
else
  "$TMP_DIR/r1-reading-token-consistency-contract" all
fi
