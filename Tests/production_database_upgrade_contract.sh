#!/usr/bin/env bash
set -euo pipefail
umask 077
while IFS= read -r name; do
  case "$name" in SPOTIFYLYRICS_*|LYRICSQ_*|SPOTIFY_CLIENT_ID) unset "$name" ;; esac
done < <(compgen -e)

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
TMP_DIR="$(mktemp -d /tmp/spotifylyrics-production-upgrade.XXXXXX)"
export CFFIXED_USER_HOME="$TMP_DIR/home"
export TMPDIR="$TMP_DIR/tmp/"
mkdir -m 700 -p "$CFFIXED_USER_HOME" "$TMP_DIR/m1-home" "$TMPDIR"
export SPOTIFYLYRICS_CONTRACT_ROOT="$TMP_DIR"

cat > "$TMP_DIR/logger.swift" <<'SWIFT'
import Foundation
enum LyricsE2ELog { static func log(_ message: String) { print(message) } }
SWIFT
SOURCES=(
  SpotifyLyrics/Models/Models.swift
  SpotifyLyrics/Lyrics/TrackIdentity.swift
  SpotifyLyrics/Lyrics/LyricsModels.swift
  SpotifyLyrics/Lyrics/AlignmentModels.swift
  SpotifyLyrics/Lyrics/TrackAlias.swift
  SpotifyLyrics/Lyrics/TrackMetadata.swift
  SpotifyLyrics/Lyrics/TrackTextNormalizer.swift
  SpotifyLyrics/Lyrics/JapaneseRomanizer.swift
  SpotifyLyrics/Lyrics/JapaneseReadingPipeline.swift
  SpotifyLyrics/Lyrics/JapaneseKanaGenerator.swift
  SpotifyLyrics/Lyrics/LyricsMatcher.swift
  SpotifyLyrics/Lyrics/LyricsSafeMatcher.swift
  SpotifyLyrics/Lyrics/LyricsQueryPlanner.swift
  SpotifyLyrics/Lyrics/LyricsRecoveryModels.swift
  "$TMP_DIR/logger.swift"
  SpotifyLyrics/Lyrics/LyricsSearchManager.swift
  SpotifyLyrics/Lyrics/CompositeLyricsProvider.swift
  SpotifyLyrics/Lyrics/LRCParser.swift
  SpotifyLyrics/Lyrics/LocalAlignedLyricsStore.swift
  SpotifyLyrics/Lyrics/ReadingModels.swift
  SpotifyLyrics/Lyrics/PersonalLyricsLibraryModels.swift
  SpotifyLyrics/Lyrics/ListeningHistoryModels.swift
  SpotifyLyrics/Lyrics/ListeningStatisticsModels.swift
  SpotifyLyrics/Search/SongSearchModels.swift
  SpotifyLyrics/Search/TrackSearchModels.swift
  SpotifyLyrics/Search/LocalLyricsIndex.swift
  SpotifyLyrics/Services/LyricsSessionController.swift
  SpotifyLyrics/Editor/LyricsEditorModels.swift
  SpotifyLyrics/Editor/LyricsTimelineValidator.swift
  SpotifyLyrics/AI/AITranslationModels.swift
  SpotifyLyrics/Persistence/DatabaseModels.swift
  SpotifyLyrics/Persistence/DatabaseMigrator.swift
  SpotifyLyrics/Persistence/LyricsRepository.swift
  SpotifyLyrics/Persistence/AlignmentProvenanceStore.swift
  SpotifyLyrics/Lyrics/LyricsLanguageGate.swift
  SpotifyLyrics/Persistence/LyricsPersistenceMapper.swift
  SpotifyLyrics/Persistence/TranslationRepository.swift
  SpotifyLyrics/Persistence/LyricsEditingRepository.swift
  SpotifyLyrics/Persistence/SQLiteLyricsRepository.swift
  SpotifyLyrics/DebugDatabaseSafety.swift
  Tests/production_database_upgrade_contract.swift
)
for input in "${SOURCES[@]}"; do
  [[ -f "$input" ]] || { echo "missing input: $input" >&2; exit 78; }
done
shasum -a 256 "$0" "${SOURCES[@]}" > "$TMP_DIR/inputs.sha256"
echo "PREPARE_EXIT=0 BUILD=$TMP_DIR"
cat "$TMP_DIR/inputs.sha256"
if swiftc -D DEBUG -parse-as-library "${SOURCES[@]}" -o "$TMP_DIR/production-upgrade-contract"; then
  echo 'COMPILE_EXIT=0'
else
  result=$?; echo "COMPILE_EXIT=$result RUN_EXIT=NOT_RUN"; exit "$result"
fi


if CFFIXED_USER_HOME="$TMP_DIR/home" UPGRADE_FIXTURE_EXPORT="$TMP_DIR/v5.sqlite3" "$TMP_DIR/production-upgrade-contract"; then
  echo 'V5_RUN_EXIT=0'
else
  result=$?; echo "V5_RUN_EXIT=$result"; exit "$result"
fi

if [[ -n "${UPGRADE_AUDIT_BINARY:-}" ]]; then cp "$TMP_DIR/production-upgrade-contract" "$UPGRADE_AUDIT_BINARY"; fi

if CFFIXED_USER_HOME="$TMP_DIR/m1-home" "$TMP_DIR/production-upgrade-contract" --m1-migrations; then
  echo 'V10_V11_V12_RUN_EXIT=0 RUN_EXIT=0'
else
  result=$?; echo "V10_V11_V12_RUN_EXIT=$result"; exit "$result"
fi
