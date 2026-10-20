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

declare -a CASES=(
  "toolbar-faint|--toolbar faint"
  "toolbar-full|--toolbar full"
  "hover-adjust|--panel hover:adjust --tab picture"
  "hover-translation|--panel hover:translation"
  "hover-more|--panel hover:more"
  "pin-adjust-dark|--panel pin:adjust --tab picture --appearance dark"
  "pin-adjust-light|--panel pin:adjust --tab picture --appearance light"
  "pin-more-light|--panel pin:more --appearance light"
  "pin-adjust-narrow-screen|--panel pin:adjust --width 1700 --height 900"
  "scene-originalAmbient|--scene originalAmbient"
  "scene-flowingField|--scene flowingField"
  "scene-coverPhoto|--scene coverPhoto"
  "scene-linerNotes|--scene linerNotes"
  "scene-focusedLyrics|--scene focusedLyrics"
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
  python3 "$ROOT/Tools/experience_visual_host/run.py" $args --surface main \
    --output "$OUT/$name.png" > "$OUT/$name.log" 2>&1 || echo "FAILED $name (see $OUT/$name.log)"
  ls "$OUT/$name"*.png 2>/dev/null | sed "s|$OUT/|  |"
done
echo "Snapshots in $OUT"
