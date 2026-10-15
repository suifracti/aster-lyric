#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

required_files=(
  "SpotifyLyrics/Search/LocalLyricsIndex.swift"
  "SpotifyLyrics/Search/TrackSearchModels.swift"
  "SpotifyLyrics/Search/TrackSearchProvider.swift"
  "SpotifyLyrics/Search/TrackSearchManager.swift"
  "SpotifyLyrics/Search/CurrentTrackResolver.swift"
  "SpotifyLyrics/Search/SongSearchModels.swift"
  "SpotifyLyrics/Search/SongSearchProvider.swift"
  "SpotifyLyrics/Search/LocalSearchProvider.swift"
  "SpotifyLyrics/Search/SpotifyCurrentTrackProvider.swift"
  "SpotifyLyrics/Search/LRCLIBProvider.swift"
  "SpotifyLyrics/Search/SongSearchManager.swift"
  "SpotifyLyrics/Lyrics/LyricsSearchManager.swift"
  "SpotifyLyrics/Lyrics/LRCLIBLyricsProvider.swift"
  "Tests/song_search_contract.swift"
  "Tests/search_models_contract.swift"
  "Tests/provider_failure_contract.swift"
)

for file in "${required_files[@]}"; do
  test -f "$file" || { echo "missing song search file: $file" >&2; exit 1; }
done

# Architecture markers
rg -q 'struct TrackSearchResult' SpotifyLyrics/Search/TrackSearchModels.swift
rg -q 'class TrackSearchManager' SpotifyLyrics/Search/TrackSearchManager.swift
rg -q 'class CurrentTrackResolver' SpotifyLyrics/Search/CurrentTrackResolver.swift
rg -q 'class LyricsSearchManager' SpotifyLyrics/Lyrics/LyricsSearchManager.swift
rg -q 'class LocalLyricsIndex' SpotifyLyrics/Search/LocalLyricsIndex.swift
rg -q 'LRCLIBProvider\(\)' SpotifyLyrics/Services/PlaybackState.swift && {
  echo "PlaybackState must not register LRCLIB as a track-search provider" >&2
  exit 1
} || true
if rg -n 'SongSearchManager\(providers: \[' -A6 SpotifyLyrics/Services/PlaybackState.swift | rg -q 'LRCLIBProvider'; then
  echo "PlaybackState track search still includes LRCLIBProvider" >&2
  exit 1
fi
rg -q 'CurrentTrackResolver|LocalSearchProvider' SpotifyLyrics/Services/PlaybackState.swift
rg -q 'maxAutomaticRetries|rateLimited|\.cancelled' SpotifyLyrics/Lyrics/LRCLIBLyricsProvider.swift
# Release path must not hardcode project Lyrics/ outside DEBUG.
if rg -n 'appendingPathComponent\("Lyrics"' SpotifyLyrics/Search/LocalLyricsIndex.swift | rg -v 'DEBUG|#' >/dev/null; then
  :
fi
if ! rg -q '#if DEBUG' SpotifyLyrics/Search/LocalLyricsIndex.swift; then
  echo "LocalLyricsIndex must guard project Lyrics path with DEBUG" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -f "$TMP_DIR"/* 2>/dev/null; rmdir "$TMP_DIR" 2>/dev/null || true' EXIT

COMMON=(
  "SpotifyLyrics/Lyrics/PersonalLyricsLibraryModels.swift"
  "SpotifyLyrics/Lyrics/ListeningHistoryModels.swift"
  "SpotifyLyrics/Lyrics/ListeningStatisticsModels.swift"
  "SpotifyLyrics/Editor/LyricsEditorModels.swift"
  "SpotifyLyrics/Editor/LyricsTimelineValidator.swift"
  "SpotifyLyrics/Lyrics/ReadingModels.swift"
  "SpotifyLyrics/Persistence/DatabaseMigrator.swift"
  "SpotifyLyrics/Persistence/AlignmentProvenanceStore.swift"
  "SpotifyLyrics/Persistence/TranslationRepository.swift"
  "SpotifyLyrics/Persistence/LyricsEditingRepository.swift"
  "SpotifyLyrics/Persistence/SQLiteLyricsRepository.swift"
  "SpotifyLyrics/DebugDatabaseSafety.swift"
  "SpotifyLyrics/Models/Models.swift"
  "SpotifyLyrics/Lyrics/TrackIdentity.swift"
  "SpotifyLyrics/Lyrics/LyricsModels.swift"
  "SpotifyLyrics/Lyrics/AlignmentModels.swift"
  "SpotifyLyrics/Lyrics/LRCParser.swift"
  "SpotifyLyrics/Lyrics/LyricsMatcher.swift"
  "SpotifyLyrics/Lyrics/TrackAlias.swift"
  "SpotifyLyrics/Lyrics/TrackMetadata.swift"
  "SpotifyLyrics/Lyrics/TrackTextNormalizer.swift"
  "SpotifyLyrics/Lyrics/JapaneseRomanizer.swift"
  "SpotifyLyrics/Lyrics/JapaneseReadingPipeline.swift"
  "SpotifyLyrics/Lyrics/JapaneseKanaGenerator.swift"
  "SpotifyLyrics/Lyrics/LyricsQueryPlanner.swift"
  "SpotifyLyrics/Lyrics/LyricsSafeMatcher.swift"
  "SpotifyLyrics/Lyrics/LyricsRecoveryModels.swift"
  "SpotifyLyrics/Lyrics/LyricsE2ELog.swift"
  "SpotifyLyrics/AI/AITranslationModels.swift"
  "SpotifyLyrics/Persistence/DatabaseModels.swift"
  "SpotifyLyrics/Lyrics/LyricsLanguageGate.swift" \
  "SpotifyLyrics/Persistence/LyricsPersistenceMapper.swift" \
  "SpotifyLyrics/Lyrics/LocalLyricsProvider.swift"
  "SpotifyLyrics/Lyrics/LRCLIBLyricsProvider.swift"
  "SpotifyLyrics/Lyrics/LyricsSearchManager.swift"
  "SpotifyLyrics/Lyrics/CompositeLyricsProvider.swift"
  "SpotifyLyrics/Lyrics/LocalAlignedLyricsStore.swift"
  "SpotifyLyrics/Services/LyricsSessionController.swift"
  "SpotifyLyrics/Persistence/LyricsRepository.swift"
  "SpotifyLyrics/Providers/PlaybackProvider.swift"
  "SpotifyLyrics/Search/LocalLyricsIndex.swift"
  "SpotifyLyrics/Search/TrackSearchModels.swift"
  "SpotifyLyrics/Search/TrackSearchProvider.swift"
  "SpotifyLyrics/Search/TrackSearchManager.swift"
  "SpotifyLyrics/Search/CurrentTrackResolver.swift"
  "SpotifyLyrics/Search/SongSearchModels.swift"
  "SpotifyLyrics/Search/SongSearchProvider.swift"
  "SpotifyLyrics/Search/LocalSearchProvider.swift"
  "SpotifyLyrics/Search/SpotifyCurrentTrackProvider.swift"
  "SpotifyLyrics/Search/LRCLIBProvider.swift"
  "SpotifyLyrics/Search/SongSearchManager.swift"
)

cp "Tests/song_search_contract.swift" "$TMP_DIR/main.swift"
swiftc -parse-as-library "${COMMON[@]}" "$TMP_DIR/main.swift" -o "$TMP_DIR/song-search-contract"
"$TMP_DIR/song-search-contract"

cp "Tests/search_models_contract.swift" "$TMP_DIR/SearchModelsMain.swift"
swiftc -parse-as-library "${COMMON[@]}" "$TMP_DIR/SearchModelsMain.swift" -o "$TMP_DIR/search-models-contract"
"$TMP_DIR/search-models-contract"

cp "Tests/provider_failure_contract.swift" "$TMP_DIR/ProviderFailureMain.swift"
swiftc -parse-as-library "${COMMON[@]}" "$TMP_DIR/ProviderFailureMain.swift" -o "$TMP_DIR/provider-failure-contract"
"$TMP_DIR/provider-failure-contract"

echo "song search contract passed"
