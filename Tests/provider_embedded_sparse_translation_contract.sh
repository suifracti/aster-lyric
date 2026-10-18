#!/bin/zsh
set -euo pipefail
umask 077
for name in ${(k)parameters}; do
  if [[ "$name" == SPOTIFYLYRICS_* || "$name" == LYRICSQ_* || "$name" == SPOTIFY_CLIENT_ID ]]; then unset "$name"; fi
done
ROOT="${0:A:h}/.."
BUILD="$(mktemp -d /tmp/spotifylyrics-provider-embedded-contract.XXXXXX)"
export SPOTIFYLYRICS_PROVIDER_EMBEDDED_TEST_ROOT="$BUILD/fixtures"
export CFFIXED_USER_HOME="$BUILD/home"
export TMPDIR="$BUILD/tmp/"
export SPOTIFYLYRICS_DATABASE_PATH="$BUILD/fixtures/SpotifyLyrics.sqlite3"
mkdir -p "$SPOTIFYLYRICS_PROVIDER_EMBEDDED_TEST_ROOT" "$CFFIXED_USER_HOME" "$TMPDIR"
git -C "$ROOT" show HEAD:SpotifyLyrics/Persistence/TranslationRepository.swift > "$BUILD/TranslationRepository.swift"
cat > "$BUILD/logger.swift" <<'SWIFT'
import Foundation
enum LyricsE2ELog { static func log(_ message: String) { print(message) } }
SWIFT
SOURCES=(
  "$ROOT/SpotifyLyrics/Models/Models.swift"
  "$ROOT/SpotifyLyrics/Lyrics/TrackIdentity.swift"
  "$ROOT/SpotifyLyrics/Lyrics/LyricsModels.swift"
  "$ROOT/SpotifyLyrics/Lyrics/AlignmentModels.swift"
  "$ROOT/SpotifyLyrics/Lyrics/TrackAlias.swift"
  "$ROOT/SpotifyLyrics/Lyrics/TrackMetadata.swift"
  "$ROOT/SpotifyLyrics/Lyrics/TrackTextNormalizer.swift"
  "$ROOT/SpotifyLyrics/Lyrics/JapaneseRomanizer.swift"
  "$ROOT/SpotifyLyrics/Lyrics/JapaneseReadingPipeline.swift"
  "$ROOT/SpotifyLyrics/Lyrics/JapaneseKanaGenerator.swift"
  "$ROOT/SpotifyLyrics/Lyrics/LyricsMatcher.swift"
  "$ROOT/SpotifyLyrics/Editor/LyricsEditorModels.swift"
  "$ROOT/SpotifyLyrics/Editor/LyricsTimelineValidator.swift"
  "$ROOT/SpotifyLyrics/AI/AITranslationModels.swift"
  "$ROOT/SpotifyLyrics/AI/AITranslationConfiguration.swift"
  "$ROOT/SpotifyLyrics/Persistence/DatabaseModels.swift"
  "$ROOT/SpotifyLyrics/Lyrics/ReadingModels.swift"
  "$ROOT/SpotifyLyrics/Persistence/DatabaseMigrator.swift"
  "$ROOT/SpotifyLyrics/Persistence/LyricsRepository.swift"
  "$ROOT/SpotifyLyrics/Persistence/AlignmentProvenanceStore.swift"
  "$ROOT/SpotifyLyrics/Lyrics/LyricsLanguageGate.swift"
  "$ROOT/SpotifyLyrics/Persistence/LyricsPersistenceMapper.swift"
  "$BUILD/TranslationRepository.swift"
  "$ROOT/SpotifyLyrics/Persistence/LyricsEditingRepository.swift"
  "$ROOT/SpotifyLyrics/Persistence/SQLiteLyricsRepository.swift"
  "$ROOT/SpotifyLyrics/Lyrics/ListeningHistoryModels.swift"
  "$ROOT/SpotifyLyrics/Lyrics/ListeningStatisticsModels.swift"
  "$ROOT/SpotifyLyrics/Lyrics/PersonalLyricsLibraryModels.swift"
  "$ROOT/SpotifyLyrics/DebugDatabaseSafety.swift"
  "$ROOT/Tests/provider_embedded_sparse_translation_contract.swift"
  "$BUILD/logger.swift"
)
for input in "${SOURCES[@]}"; do
  [[ -f "$input" ]] || { print -u2 "missing input: $input"; exit 78; }
done
if swiftc -D DEBUG -parse-as-library "${SOURCES[@]}" -o "$BUILD/provider_embedded_sparse_translation_contract"; then
  print 'COMPILE_EXIT=0'
else
  result=$?
  print "COMPILE_EXIT=$result RUN_EXIT=NOT_RUN"
  exit "$result"
fi
if "$BUILD/provider_embedded_sparse_translation_contract"; then
  print 'RUN_EXIT=0'
else
  result=$?
  print "RUN_EXIT=$result"
  exit "$result"
fi
