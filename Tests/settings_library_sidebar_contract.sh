#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$ROOT_DIR/SpotifyLyrics/Views/Settings/SettingsRootView.swift" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text()
assert '("歌词", [.lyricsAndText, .aiTranslation, .reading, .library])' in source, \
    "personal lyrics library must remain visible in the Settings lyrics sidebar group"
route_start = source.index("case .library:", source.index("private struct SettingsDetailView"))
route_end = source.index("case .history:", route_start)
library_route = source[route_start:route_end]
assert "PersonalLyricsLibraryView()" in library_route, \
    "Settings library route must show the existing personal lyrics library"
assert "TransitionalBridgeContainer" not in library_route, \
    "Settings library must open as a persistent page rather than a hidden bridge destination"
print("settings library sidebar contract: PASS")
PY
