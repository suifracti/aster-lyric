#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONTROLLER="$ROOT_DIR/SpotifyLyrics/Windows/CapsuleLyricsWindowController.swift"
PERSISTENCE="$ROOT_DIR/SpotifyLyrics/Windows/CapsuleLyricsWindowPersistence.swift"
VIEW="$ROOT_DIR/SpotifyLyrics/Views/Capsule/CapsuleLyricsView.swift"
STATUS="$ROOT_DIR/SpotifyLyrics/Views/Capsule/CapsuleLyricsStatusView.swift"
MANAGER="$ROOT_DIR/SpotifyLyrics/Windows/WindowManager.swift"
SETTINGS="$ROOT_DIR/SpotifyLyrics/Settings/AppSettingsStore.swift"
PLAYBACK="$ROOT_DIR/SpotifyLyrics/Services/PlaybackState.swift"

require_file() {
  test -f "$1" || { echo "FAIL: missing $2 ($1)" >&2; exit 1; }
}

require() {
  local file="$1" pattern="$2" label="$3"
  grep -Eq "$pattern" "$file" || {
    echo "FAIL: $label ($file does not contain /$pattern/)" >&2
    exit 1
  }
}

for pair in \
  "$CONTROLLER:controller" \
  "$PERSISTENCE:persistence" \
  "$VIEW:view" \
  "$STATUS:status view"; do
  require_file "${pair%%:*}" "${pair#*:}"
done

require "$CONTROLLER" 'NSPanel' 'capsule uses a dedicated NSPanel'
require "$CONTROLLER" 'nonactivatingPanel' 'capsule panel does not steal keyboard focus'
require "$CONTROLLER" 'effectivePanelLevel' 'capsule centralizes its window level policy'
require "$CONTROLLER" '\.floating' 'legacy capsule supports floating level'
require "$CONTROLLER" '\.statusBar' 'production island can reach the physical top edge'
require "$CONTROLLER" 'canJoinAllSpaces' 'capsule joins all Spaces'
require "$CONTROLLER" 'fullScreenAuxiliary' 'capsule is visible above full-screen content'
require "$CONTROLLER" 'didChangeScreenParametersNotification' 'capsule observes display changes'
require "$CONTROLLER" 'NSEvent\.addGlobalMonitorForEvents' 'expanded outside click collapse has a global monitor'
require "$CONTROLLER" 'removeMonitor' 'event monitor is removed'
require "$CONTROLLER" 'deinit' 'controller has explicit cleanup'
require "$CONTROLLER" '220_000_000' 'hover collapse uses the responsive debounce'
require "$CONTROLLER" 'presentationState == \.expanded' 'expanded state is the only draggable state'
! grep -Eq '\.modalPanel' "$CONTROLLER" || {
  echo 'FAIL: capsule uses a modal window level' >&2
  exit 1
}
! grep -Eq 'Timer\.scheduledTimer|LyricsSessionController|TranslationSessionController|PlaybackProvider|URLSession' "$CONTROLLER" "$VIEW" || {
  echo 'FAIL: capsule owns a second clock/provider/session/network path' >&2
  exit 1
}
require "$VIEW" 'liveLyrics' 'capsule consumes live lyrics'
require "$VIEW" 'liveLyricsState' 'capsule consumes live state'
require "$VIEW" 'onEditingChanged' 'expanded progress uses an explicit drag lifecycle'
require "$VIEW" 'state\.seek\(to: draftPosition' 'only completed slider interaction seeks'
! grep -Eq 'state\.lyrics([[:space:]]|\.|\[)' "$VIEW" || {
  echo 'FAIL: capsule view reads preview-capable state.lyrics' >&2
  exit 1
}
require "$PERSISTENCE" 'horizontalOffset' 'capsule persists horizontal position'
require "$PERSISTENCE" 'visibleFrame' 'capsule clamps to visible screen frame'
require "$PERSISTENCE" 'capsulePreferredDisplayID' 'capsule resolves the chosen display'
require "$CONTROLLER" 'capsuleWindowScreenID = screen.lyricsFrameScreenID' 'legacy capsule placement keeps its last screen'
require "$SETTINGS" 'capsuleWindowHorizontalOffset' 'settings has a capsule-specific position key'
require "$SETTINGS" 'capsuleWindowWasVisible' 'settings has capsule visibility recovery key'
require "$MANAGER" 'CapsuleLyricsWindowController' 'WindowManager owns the dedicated controller'
! grep -Eq 'private var capsuleWindow:[[:space:]]*NSWindow|contentView[[:space:]]*=[[:space:]]*NSHostingView\(rootView:[[:space:]]*CapsulePlayerView' "$MANAGER" || {
  echo 'FAIL: WindowManager still has the old direct capsule window path' >&2
  exit 1
}

# The DEBUG acceptance fixture has its own control-file polling timer, already
# present in the baseline. Count the production playback clock specifically.
if [ "$(grep -Ec '^[[:space:]]*timer = Timer\.scheduledTimer' "$PLAYBACK")" -ne 1 ]; then
  echo 'FAIL: PlaybackState must retain one production playback polling timer' >&2
  exit 1
fi

echo "capsule window behavior contract passed"
