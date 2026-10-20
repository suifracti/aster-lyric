#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VIEW="$ROOT/SpotifyLyrics/Views/Settings/PersonalLyricsLibraryView.swift"
SERVICE="$ROOT/SpotifyLyrics/Settings/PersonalLyricsLibraryService.swift"
PLAYBACK="$ROOT/SpotifyLyrics/Services/PlaybackState.swift"
SESSION="$ROOT/SpotifyLyrics/Services/TranslationSessionController.swift"

grep -Fq 'Button("删除", role: .destructive)' "$VIEW"
grep -Fq '删除译文版本？' "$VIEW"
grep -Fq 'service.deleteTranslationVersion' "$VIEW"
grep -Fq '.disabled(tv.isLocked)' "$VIEW"
grep -Fq 'repository.deleteTranslation(versionID: versionID)' "$SERVICE"
grep -Fq 'reconcileExternalTranslationDeletion' "$PLAYBACK"
grep -Fq 'reconcileExternalDeletion' "$SESSION"

echo 'personal library translation deletion contract: PASS'
