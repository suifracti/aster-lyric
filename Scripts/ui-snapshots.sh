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
  "toolbar-faint|--toolbar faint"
  "toolbar-full|--toolbar full"
  "lyric-notice|--toolbar notice"
  "model-picker|--surface models --model-fixture --appearance light"
  "hover-library|--panel hover:library"
  "pin-library|--panel pin:library"
  "hover-search|--panel hover:search"
  "pin-search|--panel pin:search"
  "search-panel|--surface search-panel --appearance light"
  "search-full|--surface search-full --appearance light"
  "pin-picture|--panel pin:picture"
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
  "big-line|--scene originalAmbient --big-line true --toolbar faint"
  "countdown|--scene originalAmbient --countdown true --time 6 --toolbar faint"
  "reading-only|--scene originalAmbient --layers readingOnly --toolbar faint"
  "translation-only|--scene originalAmbient --layers translationOnly --toolbar faint"
  "drawer-library|--drawer library --toolbar faint"
  "drawer-search|--drawer search --toolbar faint"
  "scene-flowingField|--scene flowingField --toolbar faint"
  "scene-coverPhoto|--scene coverPhoto --toolbar faint"
  "scene-linerNotes|--scene linerNotes --toolbar faint"
  "scene-focusedLyrics|--scene focusedLyrics --toolbar faint"
  "scene-flowingField-feathered|--scene flowingField --renderer v3ArtworkPresentation.feathered.v1 --toolbar faint"
  "scene-coverPhoto-gaussian|--scene coverPhoto --renderer v3ArtworkPresentation.gaussian.v1 --toolbar faint"
  "scene-coverPhoto-stage|--scene coverPhoto --renderer v3ArtworkPresentation.stage.v1 --toolbar faint"
  "classic-authenticAmbient|--classic v3ArtworkPresentation.authenticAmbient.v1 --toolbar faint"
  "classic-ambient|--classic v3ArtworkPresentation.ambient.v1 --toolbar faint"
  "classic-stage|--classic v3ArtworkPresentation.stage.v1 --toolbar faint"
  "classic-classic|--classic v3ArtworkPresentation.classic.v1 --toolbar faint"
  "classic-gaussian|--classic v3ArtworkPresentation.gaussian.v1 --toolbar faint"
  "classic-feathered|--classic v3ArtworkPresentation.feathered.v1 --toolbar faint"
  "classic-lyricsOnly|--classic v3ArtworkPresentation.lyricsOnly.v1 --toolbar faint"
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
)

selected=("$@")
for entry in "${CASES[@]}"; do
  name="${entry%%|*}"
  args="${entry#*|}"
  if ((${#selected[@]})) && [[ ! " ${selected[*]} " =~ " $name " ]]; then continue; fi
  rm -f "$OUT/$name".png "$OUT/$name"-panel*.png
  # shellcheck disable=SC2086
  PYTHONUNBUFFERED=1 python3 "$ROOT/Tools/experience_visual_host/run.py" $args --surface main \
    --output "$OUT/$name.png" > "$OUT/$name.log" 2>&1 || echo "FAILED $name (see $OUT/$name.log)"
  ls "$OUT/$name"*.png 2>/dev/null | sed "s|$OUT/|  |"
done
echo "Snapshots in $OUT"
