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
start = source.index('private final class V3ToolAnchorView:')
end = source.index('private struct QuietToolbarButtonStyle:', start)
fixture = (root / 'Tests/v3_toolbar_popover_event_contract.swift').read_text()
(temp / 'main.swift').write_text('import AppKit\nimport SwiftUI\n' + source[start:end] + fixture)
PYTHON
swiftc -parse-as-library "$TEST_DIR/main.swift" -o "$TEST_DIR/native-toolbar"
"$TEST_DIR/native-toolbar"
