#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d /tmp/spotifylyrics-o1-offset.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

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
  "$ROOT_DIR/SpotifyLyrics/Lyrics/LRCParser.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/PersonalLyricsLibraryModels.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/ListeningHistoryModels.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/ListeningStatisticsModels.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/LocalAlignedLyricsStore.swift" \
  "$ROOT_DIR/SpotifyLyrics/Search/SongSearchModels.swift" \
  "$ROOT_DIR/SpotifyLyrics/Search/TrackSearchModels.swift" \
  "$ROOT_DIR/SpotifyLyrics/Search/LocalLyricsIndex.swift" \
  "$ROOT_DIR/SpotifyLyrics/Services/LyricsSessionController.swift" \
  "$ROOT_DIR/SpotifyLyrics/Services/LyricsEditorSessionController.swift" \
  "$ROOT_DIR/SpotifyLyrics/Capture/AssistedAlignmentDraft.swift" \
  "$ROOT_DIR/SpotifyLyrics/Editor/LyricsEditorModels.swift" \
  "$ROOT_DIR/SpotifyLyrics/Editor/TextLyricsImport.swift" \
  "$ROOT_DIR/SpotifyLyrics/Editor/LRCImportExport.swift" \
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
  "$ROOT_DIR/Tests/o1_scoped_lyrics_offset_contract.swift" \
  -o "$TMP_DIR/o1-scoped-lyrics-offset-contract"

"$TMP_DIR/o1-scoped-lyrics-offset-contract"

STATE="$ROOT_DIR/SpotifyLyrics/Services/PlaybackState.swift"
SETTINGS="$ROOT_DIR/SpotifyLyrics/Settings/AppSettingsStore.swift"
CONTROL="$ROOT_DIR/SpotifyLyrics/Views/Components/LyricsPreferencesPopover.swift"
EDITOR="$ROOT_DIR/SpotifyLyrics/Services/LyricsEditorSessionController.swift"
V3="$ROOT_DIR/SpotifyLyrics/Views/MainWindow/AppleMusicImmersiveV3WindowView.swift"
FULLSCREEN="$ROOT_DIR/SpotifyLyrics/Views/Fullscreen/FullScreenLyricsView.swift"
FLOATING="$ROOT_DIR/SpotifyLyrics/Views/Floating/FloatingLyricsView.swift"
CAPSULE="$ROOT_DIR/SpotifyLyrics/Views/Capsule/CapsuleLyricsView.swift"
SETTINGS_VIEW="$ROOT_DIR/SpotifyLyrics/Views/Settings/SettingsRootView.swift"

grep -Fq 'presentationOffset: settingsStore.lyricsOffsetStore.activeOffset' "$STATE"
grep -Fq 'syncLiveLyricsOffsetScope()' "$STATE"
grep -Fq 'session.$activeLyricsVersionID' "$STATE"
grep -Fq 'syncLiveLyricsOffsetScope(lyricsVersionID: versionID)' "$STATE"
grep -Fq 'settings.lyricsOffsetStore' "$CONTROL"
grep -Fq '.onChange(of: scope) { _, _ in syncInput() }' "$CONTROL"
grep -Fq 'persistentLyricsOffsetScope' "$EDITOR"
grep -Fq 'LyricsPresentationOffsetControl(settings: settings)' "$V3"
grep -Fq 'LyricsPresentationOffsetControl(settings: settings)' "$FLOATING"
grep -Fq 'LyricsPresentationOffsetControl(settings: settings)' "$SETTINGS_VIEW"
grep -Fq 'AppleMusicImmersiveV3WindowView(state: state, settings: settings,' "$FULLSCREEN"
grep -Fq 'currentIndex: state.liveCurrentLineIndex' "$CAPSULE"

if rg -n 'settingsStore\.lyricsPresentationOffset|settings\.lyricsPresentationOffset|defaults\.set\([^\n]*Key\.lyricsPresentationOffset' \
  "$STATE" "$CONTROL" "$ROOT_DIR/SpotifyLyrics/Views/MainWindow/AppleMusicImmersiveV3WindowView.swift" "$SETTINGS"; then
  echo 'FAIL: a production offset consumer still reads or writes the legacy global value' >&2
  exit 1
fi

if rg -n '\.lyricsPresentationOffset\b' "$ROOT_DIR/SpotifyLyrics" --glob '!SpotifyLyrics/Settings/AppSettingsStore.swift'; then
  echo 'FAIL: a production consumer still reads the legacy global property' >&2
  exit 1
fi

echo 'O1 scoped offset source routing: PASS'
