#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h}/.."
BUILD="$(mktemp -d /tmp/spotifylyrics-ai-translation-contract.XXXXXX)"
export SPOTIFYLYRICS_CONTRACT_ROOT="$BUILD/fixtures"
export CFFIXED_USER_HOME="$BUILD/home"
export TMPDIR="$BUILD/tmp/"
export SPOTIFYLYRICS_DATABASE_PATH="$BUILD/fixtures/SpotifyLyrics.sqlite3"
mkdir -p "$CFFIXED_USER_HOME" "$TMPDIR"
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
  "$ROOT/SpotifyLyrics/Persistence/TranslationRepository.swift"
  "$ROOT/SpotifyLyrics/Persistence/LyricsEditingRepository.swift"
  "$ROOT/SpotifyLyrics/Persistence/SQLiteLyricsRepository.swift"
  "$ROOT/SpotifyLyrics/Lyrics/ListeningHistoryModels.swift"
  "$ROOT/SpotifyLyrics/Lyrics/ListeningStatisticsModels.swift"
  "$ROOT/SpotifyLyrics/Lyrics/PersonalLyricsLibraryModels.swift"
  "$ROOT/SpotifyLyrics/DebugDatabaseSafety.swift"
  "$ROOT/SpotifyLyrics/AI/AITranslationKeychain.swift"
  "$ROOT/SpotifyLyrics/AI/AITranslationPromptBuilder.swift"
  "$ROOT/SpotifyLyrics/AI/AITranslationResponseParser.swift"
  "$ROOT/SpotifyLyrics/AI/OpenAICompatibleClient.swift"
  "$ROOT/SpotifyLyrics/AI/AITranslationService.swift"
  "$ROOT/SpotifyLyrics/Lyrics/AIReadingCandidateService.swift"
  "$ROOT/SpotifyLyrics/Services/TranslationSessionController.swift"
  "$ROOT/Tests/ai_translation_contract.swift"
  "$BUILD/logger.swift"
)
# Preparation is fail-fast; a unique build cannot execute an older runner.
for input in "${SOURCES[@]}"; do
  [[ -f "$input" ]] || { print -u2 "missing input: $input"; exit 78; }
done
shasum -a 256 "$0" "${SOURCES[@]}" > "$BUILD/inputs.sha256"
print "PREPARE_EXIT=0 BUILD=$BUILD"
cat "$BUILD/inputs.sha256"
if swiftc -D DEBUG -parse-as-library "${SOURCES[@]}" -o "$BUILD/ai_translation_contract"; then
  print 'COMPILE_EXIT=0'
else
  result=$?
  print "COMPILE_EXIT=$result RUN_EXIT=NOT_RUN"
  exit "$result"
fi
if "$BUILD/ai_translation_contract"; then
  print 'RUN_EXIT=0'
else
  result=$?
  print "RUN_EXIT=$result"
  exit "$result"
fi

SERVICE="$ROOT/SpotifyLyrics/AI/AITranslationService.swift"
rg -q 'session.prepareTranslation\(\)' "$SERVICE" || { print -u2 'FAIL: Apple system translation preparation absent'; exit 1; }
print 'APPLE_PREPARATION_STATIC_EXIT=0'
