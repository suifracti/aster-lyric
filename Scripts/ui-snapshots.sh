#!/usr/bin/env bash
# Render the main UI states to PNGs with the isolated visual host
# (Tools/experience_visual_host). No real Spotify, user database, pointer or
# screen recording is used, so it works for any agent on this Mac.
#
#   Scripts/ui-snapshots.sh [output-dir] [case ...]
#
# Without cases every state below is rendered. Tool windows (hover popover,
# pinned panel) are written next to the main image as <case>-panelN.png.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/.local/ui-snapshots}"
shift || true
mkdir -p "$OUT"

python3 "$ROOT/Tools/experience_visual_host/build.py" > /dev/null

# Fix the scene toolbar state too; its pointer fade can otherwise be captured mid-animation.
declare -a CASES=(
  "r10-queue-hover-light|--panel hover:playlists --queue-hover-fixture --appearance light --toolbar full --window-composite"
  "r10-queue-large-light|--navigation playlists --queue-hover-fixture --appearance light --toolbar full --window-composite"
  "r10-queue-hover-dark|--panel hover:playlists --queue-hover-fixture --appearance dark --toolbar full --window-composite"
  "r10-queue-large-dark|--navigation playlists --queue-hover-fixture --appearance dark --toolbar full --window-composite"
  "r10-hover-bright-light|--panel hover:picture --scene coverPhoto --artwork white --appearance light --toolbar full --window-composite"
  "r10-pin-bright-light|--panel pin:picture --scene coverPhoto --artwork white --appearance light --toolbar full --window-composite"
  "r10-picker-bright-light|--surface playlist-picker --scene coverPhoto --artwork white --appearance light --toolbar full --window-composite"
  "r10-hover-dark-light|--panel hover:picture --scene coverPhoto --artwork dark --appearance light --toolbar full --window-composite"
  "r10-pin-dark-light|--panel pin:picture --scene coverPhoto --artwork dark --appearance light --toolbar full --window-composite"
  "r10-picker-dark-light|--surface playlist-picker --scene coverPhoto --artwork dark --appearance light --toolbar full --window-composite"
  "r10-hover-busy-light|--panel hover:picture --scene coverPhoto --artwork square --appearance light --toolbar full --window-composite"
  "r10-pin-busy-light|--panel pin:picture --scene coverPhoto --artwork square --appearance light --toolbar full --window-composite"
  "r10-picker-busy-light|--surface playlist-picker --scene coverPhoto --artwork square --appearance light --toolbar full --window-composite"
  "r10-hover-library-light|--panel hover:library --scene coverPhoto --appearance light --toolbar full --window-composite"
  "r10-pin-library-light|--panel pin:library --scene coverPhoto --appearance light --toolbar full --window-composite"
  "r10-hover-search-light|--panel hover:search --scene coverPhoto --appearance light --toolbar full --window-composite"
  "r10-pin-search-light|--panel pin:search --scene coverPhoto --appearance light --toolbar full --window-composite"
  "r10-hover-translation-light|--panel hover:translation --scene coverPhoto --appearance light --toolbar full --window-composite"
  "r10-pin-translation-light|--panel pin:translation --scene coverPhoto --appearance light --toolbar full --window-composite"
  "r10-hover-text-light|--panel hover:text --scene coverPhoto --appearance light --toolbar full --window-composite"
  "r10-pin-text-light|--panel pin:text --scene coverPhoto --appearance light --toolbar full --window-composite"
  "r10-hover-more-light|--panel hover:more --scene coverPhoto --appearance light --toolbar full --window-composite"
  "r10-pin-more-light|--panel pin:more --scene coverPhoto --appearance light --toolbar full --window-composite"
  "r10-hover-playlists-light|--panel hover:playlists --scene coverPhoto --appearance light --toolbar full --window-composite"
  "r10-pin-playlists-light|--panel pin:playlists --scene coverPhoto --appearance light --toolbar full --window-composite"
  "r10-hover-bright-dark|--panel hover:picture --scene coverPhoto --artwork white --appearance dark --toolbar full --window-composite"
  "r10-pin-bright-dark|--panel pin:picture --scene coverPhoto --artwork white --appearance dark --toolbar full --window-composite"
  "r10-picker-bright-dark|--surface playlist-picker --scene coverPhoto --artwork white --appearance dark --toolbar full --window-composite"
  "r10-hover-dark-dark|--panel hover:picture --scene coverPhoto --artwork dark --appearance dark --toolbar full --window-composite"
  "r10-pin-dark-dark|--panel pin:picture --scene coverPhoto --artwork dark --appearance dark --toolbar full --window-composite"
  "r10-picker-dark-dark|--surface playlist-picker --scene coverPhoto --artwork dark --appearance dark --toolbar full --window-composite"
  "r10-hover-busy-dark|--panel hover:picture --scene coverPhoto --artwork square --appearance dark --toolbar full --window-composite"
  "r10-pin-busy-dark|--panel pin:picture --scene coverPhoto --artwork square --appearance dark --toolbar full --window-composite"
  "r10-picker-busy-dark|--surface playlist-picker --scene coverPhoto --artwork square --appearance dark --toolbar full --window-composite"
  "r10-hover-library-dark|--panel hover:library --scene coverPhoto --appearance dark --toolbar full --window-composite"
  "r10-pin-library-dark|--panel pin:library --scene coverPhoto --appearance dark --toolbar full --window-composite"
  "r10-hover-search-dark|--panel hover:search --scene coverPhoto --appearance dark --toolbar full --window-composite"
  "r10-pin-search-dark|--panel pin:search --scene coverPhoto --appearance dark --toolbar full --window-composite"
  "r10-hover-translation-dark|--panel hover:translation --scene coverPhoto --appearance dark --toolbar full --window-composite"
  "r10-pin-translation-dark|--panel pin:translation --scene coverPhoto --appearance dark --toolbar full --window-composite"
  "r10-hover-text-dark|--panel hover:text --scene coverPhoto --appearance dark --toolbar full --window-composite"
  "r10-pin-text-dark|--panel pin:text --scene coverPhoto --appearance dark --toolbar full --window-composite"
  "r10-hover-more-dark|--panel hover:more --scene coverPhoto --appearance dark --toolbar full --window-composite"
  "r10-pin-more-dark|--panel pin:more --scene coverPhoto --appearance dark --toolbar full --window-composite"
  "r10-hover-playlists-dark|--panel hover:playlists --scene coverPhoto --appearance dark --toolbar full --window-composite"
  "r10-pin-playlists-dark|--panel pin:playlists --scene coverPhoto --appearance dark --toolbar full --window-composite"
  "r9-library-light|--navigation library --appearance light --toolbar full"
  "r9-library-hover-light|--panel hover:library --appearance light --toolbar full"
  "r9-search-light|--navigation search --appearance light --toolbar full"
  "r9-search-hover-light|--surface search-panel --appearance light --toolbar full"
  "r9-edge-bright-light|--artwork white --scene coverPhoto --edge-player-expanded --appearance light --toolbar full"
  "r9-edge-vertical-light|--artwork white --scene coverPhoto --edge-player-expanded --edge-player-vertical --appearance light --toolbar full"
  "r9-originalAmbient-light|--scene originalAmbient --appearance light --toolbar full"
  "r9-flowingField-light|--scene flowingField --appearance light --toolbar full"
  "r9-coverPhoto-light|--scene coverPhoto --appearance light --toolbar full"
  "r9-linerNotes-light|--scene linerNotes --appearance light --toolbar full"
  "r9-focusedLyrics-light|--scene focusedLyrics --appearance light --toolbar full"
  "r9-library-dark|--navigation library --appearance dark --toolbar full"
  "r9-library-hover-dark|--panel hover:library --appearance dark --toolbar full"
  "r9-search-dark|--navigation search --appearance dark --toolbar full"
  "r9-search-hover-dark|--surface search-panel --appearance dark --toolbar full"
  "r9-edge-bright-dark|--artwork white --scene coverPhoto --edge-player-expanded --appearance dark --toolbar full"
  "r9-edge-vertical-dark|--artwork white --scene coverPhoto --edge-player-expanded --edge-player-vertical --appearance dark --toolbar full"
  "r9-originalAmbient-dark|--scene originalAmbient --appearance dark --toolbar full"
  "r9-flowingField-dark|--scene flowingField --appearance dark --toolbar full"
  "r9-coverPhoto-dark|--scene coverPhoto --appearance dark --toolbar full"
  "r9-linerNotes-dark|--scene linerNotes --appearance dark --toolbar full"
  "r9-focusedLyrics-dark|--scene focusedLyrics --appearance dark --toolbar full"
  "r9-originalAmbient-playing-light|--scene originalAmbient --playing true --appearance light --toolbar full"
  "r9-flowingField-playing-light|--scene flowingField --playing true --appearance light --toolbar full"
  "r9-coverPhoto-playing-light|--scene coverPhoto --playing true --appearance light --toolbar full"
  "r9-linerNotes-playing-light|--scene linerNotes --playing true --appearance light --toolbar full"
  "r9-focusedLyrics-playing-light|--scene focusedLyrics --playing true --appearance light --toolbar full"
  "r9-flowing-feathered-paused-light|--scene flowingField --renderer v3ArtworkPresentation.feathered.v1 --playing false --appearance light --toolbar full"
  "r9-flowing-feathered-playing-light|--scene flowingField --renderer v3ArtworkPresentation.feathered.v1 --playing true --appearance light --toolbar full"
  "r9-cover-gaussian-paused-light|--scene coverPhoto --renderer v3ArtworkPresentation.gaussian.v1 --playing false --appearance light --toolbar full"
  "r9-cover-gaussian-playing-light|--scene coverPhoto --renderer v3ArtworkPresentation.gaussian.v1 --playing true --appearance light --toolbar full"
  "r9-cover-stage-paused-light|--scene coverPhoto --renderer v3ArtworkPresentation.stage.v1 --playing false --appearance light --toolbar full"
  "r9-cover-stage-playing-light|--scene coverPhoto --renderer v3ArtworkPresentation.stage.v1 --playing true --appearance light --toolbar full"
  "r9-classic-paused-light|--classic v3ArtworkPresentation.classic.v1 --playing false --appearance light --toolbar full"
  "r9-classic-playing-light|--classic v3ArtworkPresentation.classic.v1 --playing true --appearance light --toolbar full"
  "r9-originalAmbient-playing-dark|--scene originalAmbient --playing true --appearance dark --toolbar full"
  "r9-flowingField-playing-dark|--scene flowingField --playing true --appearance dark --toolbar full"
  "r9-coverPhoto-playing-dark|--scene coverPhoto --playing true --appearance dark --toolbar full"
  "r9-linerNotes-playing-dark|--scene linerNotes --playing true --appearance dark --toolbar full"
  "r9-focusedLyrics-playing-dark|--scene focusedLyrics --playing true --appearance dark --toolbar full"
  "r9-flowing-feathered-paused-dark|--scene flowingField --renderer v3ArtworkPresentation.feathered.v1 --playing false --appearance dark --toolbar full"
  "r9-flowing-feathered-playing-dark|--scene flowingField --renderer v3ArtworkPresentation.feathered.v1 --playing true --appearance dark --toolbar full"
  "r9-cover-gaussian-paused-dark|--scene coverPhoto --renderer v3ArtworkPresentation.gaussian.v1 --playing false --appearance dark --toolbar full"
  "r9-cover-gaussian-playing-dark|--scene coverPhoto --renderer v3ArtworkPresentation.gaussian.v1 --playing true --appearance dark --toolbar full"
  "r9-cover-stage-paused-dark|--scene coverPhoto --renderer v3ArtworkPresentation.stage.v1 --playing false --appearance dark --toolbar full"
  "r9-cover-stage-playing-dark|--scene coverPhoto --renderer v3ArtworkPresentation.stage.v1 --playing true --appearance dark --toolbar full"
  "r9-classic-paused-dark|--classic v3ArtworkPresentation.classic.v1 --playing false --appearance dark --toolbar full"
  "r9-classic-playing-dark|--classic v3ArtworkPresentation.classic.v1 --playing true --appearance dark --toolbar full"
  "edge-bright|--artwork white --scene coverPhoto --toolbar faint --edge-player-expanded"
  "edge-dark|--artwork dark --scene coverPhoto --toolbar faint --edge-player-expanded"
  "edge-vertical|--artwork white --scene coverPhoto --toolbar faint --edge-player-expanded --edge-player-vertical"
  "toolbar-faint|--toolbar faint"
  "toolbar-full|--toolbar full"
  "lyric-notice|--toolbar notice"
  "auto-selection|--toolbar auto-selection"
  "model-picker|--surface models --model-fixture --appearance light"
  "r8-light|--navigation playlists --appearance light --toolbar full"
  "r8-dark|--navigation playlists --appearance dark --toolbar full"
  "r8-hover-light|--panel hover:playlists --appearance light"
  "r8-hover-dark|--panel hover:playlists --appearance dark"
  "hover-library|--panel hover:library"
  "pin-library|--panel pin:library"
  "hover-search|--panel hover:search"
  "pin-search|--panel pin:search"
  "search-panel|--surface search-panel --appearance light"
  "search-full|--surface search-full --appearance light"
  "pin-picture|--panel pin:picture"
  "pin-more-sleep|--panel pin:more --sleep-timer"
  "pin-more|--panel pin:more"
  "hover-picture|--panel hover:picture"
  "hover-text|--panel hover:text"
  "pin-text|--panel pin:text"
  "pin-translation|--panel pin:translation"
  "hover-translation|--panel hover:translation"
  "hover-more|--panel hover:more"
  "pin-picture-dark|--panel pin:picture --appearance dark"
  "pin-picture-light|--panel pin:picture --appearance light"
  "pin-more-light|--panel pin:more --appearance light"
  "pin-picture-narrow-screen|--panel pin:picture --width 1700 --height 900"
  "scene-originalAmbient|--scene originalAmbient --toolbar faint"
  "big-line-cover|--scene coverPhoto --artwork white --big-line true --aux-layers --time 18 --fixture-json '${LYRICSQ_BIG_LINE_FIXTURE:-}' --toolbar faint"
  "big-line-ambient|--scene originalAmbient --artwork white --big-line true --aux-layers --time 18 --fixture-json '${LYRICSQ_BIG_LINE_FIXTURE:-}' --toolbar faint"
  "big-line|--scene originalAmbient --big-line true --toolbar faint"
  "countdown|--scene originalAmbient --countdown true --time 6 --toolbar faint"
  "reading-only|--scene originalAmbient --layers readingOnly --toolbar faint"
  "translation-only|--scene originalAmbient --layers translationOnly --toolbar faint"
  "library-missing|--navigation library --library-missing --toolbar faint"
  "navigation-library|--navigation library --toolbar faint"
  "navigation-playlists|--navigation playlists --toolbar faint"
  "hover-playlists|--panel hover:playlists"
  "navigation-playlists-hover|--navigation playlists --toolbar faint --playlist-hover-fixture"
  "navigation-playlists-empty|--navigation playlists --toolbar faint --queue-empty"
  "hover-playlists-empty|--panel hover:playlists --queue-empty"
  "navigation-search|--navigation search --toolbar faint"
  "scene-flowingField|--scene flowingField --toolbar faint"
  "scene-coverPhoto|--scene coverPhoto --toolbar faint"
  "cover-subject-a|--scene coverPhoto --artwork bright --artwork-path '${LYRICSQ_COVER_A:-}' --toolbar faint"
  "cover-subject-b|--scene coverPhoto --artwork dark --artwork-path '${LYRICSQ_COVER_B:-}' --toolbar faint"
  "scene-linerNotes|--scene linerNotes --toolbar faint"
  "scene-focusedLyrics|--scene focusedLyrics --toolbar faint"
  "scene-flowingField-feathered|--scene flowingField --renderer v3ArtworkPresentation.feathered.v1 --toolbar faint"
  "scene-coverPhoto-gaussian|--scene coverPhoto --renderer v3ArtworkPresentation.gaussian.v1 --toolbar faint"
  "scene-coverPhoto-stage|--scene coverPhoto --renderer v3ArtworkPresentation.stage.v1 --toolbar faint"
  "classic-classic|--classic v3ArtworkPresentation.classic.v1 --toolbar faint"
  "classic-albumPoster|--classic v3ArtworkPresentation.albumPoster.v1 --toolbar faint"
  "reading-bright-off|--artwork white --reading-protection off --scene coverPhoto --toolbar faint"
  "reading-bright-shadow|--artwork white --reading-protection shadow --scene coverPhoto --toolbar faint"
  "reading-bright-glow|--artwork white --reading-protection glow --scene coverPhoto --toolbar faint"
  "reading-dark-off|--artwork dark --reading-protection off --scene coverPhoto --toolbar faint"
  "reading-dark-shadow|--artwork dark --reading-protection shadow --scene coverPhoto --toolbar faint"
  "reading-dark-glow|--artwork dark --reading-protection glow --scene coverPhoto --toolbar faint"
  "menubar-dark|--surface menubar --appearance dark"
  "menubar-light|--surface menubar --appearance light"
  "settings-light|--surface settings --appearance light"
  "settings-lyrics|--surface settings --settings-page 歌词与翻译 --appearance light"
  "settings-ai|--surface settings --settings-page 'AI 翻译' --appearance light"
)

selected=("$@")
for entry in "${CASES[@]}"; do
  name="${entry%%|*}"
  args="${entry#*|}"
  if ((${#selected[@]})) && [[ ! " ${selected[*]} " =~ " $name " ]]; then continue; fi
  rm -f "$OUT/$name".png "$OUT/$name"-panel*.png
  PYTHONUNBUFFERED=1 python3 - "$ROOT" "$OUT" "$name" "$args" <<'PY_TIMEOUT'
import os, shlex, signal, subprocess, sys
root, out, name, args = sys.argv[1:]
with open(f"{out}/{name}.log", "w") as log:
    process = subprocess.Popen(
        [sys.executable, f"{root}/Tools/experience_visual_host/run.py",
         *shlex.split(args), "--surface", "main", "--output", f"{out}/{name}.png"],
        stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    try:
        if process.wait(timeout=60):
            print(f"FAILED {name} (see {out}/{name}.log)")
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()
        print("Screenshot timed out after 60 seconds.", file=log)
        print(f"FAILED {name} (timeout 60s; see {out}/{name}.log)")
PY_TIMEOUT
  ls "$OUT/$name"*.png 2>/dev/null | sed "s|$OUT/|  |" || true
done
echo "Snapshots in $OUT"
