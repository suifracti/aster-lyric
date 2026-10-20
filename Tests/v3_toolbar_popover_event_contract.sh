#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d /tmp/lyricsq-native-toolbar.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
python3 - "$ROOT_DIR" "$TEST_DIR" <<'PYTHON'
from pathlib import Path
import sys
root, temp = map(Path, sys.argv[1:])
source = (root / 'SpotifyLyrics/Views/MainWindow/AppleMusicImmersiveV3WindowView.swift').read_text()
start = source.index('enum V3ToolbarLog {')
end = source.index('private struct QuietToolbarButtonStyle:', start)
controls = (root / 'SpotifyLyrics/Views/Components/LyricIslandControls.swift').read_text()
geometry = controls.split('// BEGIN EXTERNAL PANEL GEOMETRY', 1)[1].split('// END EXTERNAL PANEL GEOMETRY', 1)[0]
fixture = (root / 'Tests/v3_toolbar_popover_event_contract.swift').read_text()
(temp / 'main.swift').write_text('import AppKit\nimport SwiftUI\nimport os\n' + source[start:end] + geometry + fixture)
PYTHON
swiftc -parse-as-library "$TEST_DIR/main.swift" -o "$TEST_DIR/native-toolbar"
"$TEST_DIR/native-toolbar"
