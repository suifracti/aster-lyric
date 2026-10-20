#!/usr/bin/env bash
# Compiles the real toolbar model and panel placement with the behaviour cases.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/lyrics-toolbar-model.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
# LyricIslandPanelPlacement is a pure geometry enum inside a SwiftUI file;
# extract just that block so the contract stays AppKit-free.
python3 - "$ROOT" "$WORK" <<'PY'
import sys, pathlib, re
root, work = map(pathlib.Path, sys.argv[1:])
src = (root/'SpotifyLyrics/Views/Components/LyricIslandControls.swift').read_text()
block = re.search(r'enum LyricIslandPanelPlacement \{.*?\n\}\n', src, re.S).group(0)
(work/'placement.swift').write_text('import CoreGraphics\n' + block)
PY
swiftc -parse-as-library \
  "$ROOT/SpotifyLyrics/Views/MainWindow/V3ToolbarModel.swift" \
  "$WORK/placement.swift" \
  "$ROOT/Tests/v3_toolbar_model_contract.swift" \
  -o "$WORK/contract"
"$WORK/contract"
