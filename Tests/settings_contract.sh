#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STORE="$ROOT/SpotifyLyrics/Settings/AppSettingsStore.swift"
PROVIDERS="$ROOT/SpotifyLyrics/Settings/LyricsProviderConfiguration.swift"
SETTINGS="$ROOT/SpotifyLyrics/Views/Settings/SettingsRootView.swift"
MANAGER="$ROOT/SpotifyLyrics/Lyrics/LyricsSearchManager.swift"
REPOSITORY="$ROOT/SpotifyLyrics/Persistence/LyricsRepository.swift"
WINDOWS="$ROOT/SpotifyLyrics/Settings/WindowStatePersistence.swift"

test -f "$STORE"
test -f "$PROVIDERS"
test -f "$SETTINGS"
test -f "$WINDOWS"
grep -Eq 'mainWindowLayoutStyle|spotify\.clientID' "$STORE"
grep -Eq 'keepOnTop = defaults\.object\(forKey: Key\.keepMainWindowOnTop\) as\? Bool \?\? false' "$STORE"
grep -Eq 'display\.kanaDisplayMode|display\.assistantFontSize|display\.rubyFontSize' "$STORE"
grep -Eq 'floatingWindowFrame|floatingWindowInteractionMode|floatingWindowOpacity' "$STORE"
grep -q '桌面歌词保持置顶' "$ROOT/SpotifyLyrics/Views/Settings/AppearanceSettingsView.swift"
grep -Eq 'lyrics\.providers\.enabled|lyrics\.providers\.order' "$STORE"
grep -Eq 'lyrics\.sourceMode|lyricsSourceMode' "$STORE"
grep -Eq 'LyricsProviderID|LyricsSourceMode' "$PROVIDERS"
grep -Eq 'lyricsSourceMode\.standardFree\.v1|lyricsSourceMode\.experimentalFree\.v1' "$PROVIDERS"
grep -Eq 'updateProviders|providerSnapshot' "$MANAGER"
grep -Eq '歌词来源模式|标准免费模式' "$SETTINGS"
grep -Eq 'statistics\(\)|createBackup|clearLyricsCache' "$REPOSITORY"
grep -Eq 'NavigationSplitView|SettingsCategory' "$SETTINGS"
grep -Eq 'SettingsWindowBehavior|canJoinAllApplications' "$WINDOWS"
grep -Eq 'SettingsWindowBehavior' "$SETTINGS"

echo 'settings contract passed'
