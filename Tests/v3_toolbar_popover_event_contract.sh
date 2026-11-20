#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d /tmp/lyricsq-native-toolbar.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
python3 - "$ROOT_DIR" "$TEST_DIR" <<'PYTHON'
from pathlib import Path
import sys
root, temp = map(Path, sys.argv[1:])
source = (root / 'SpotifyLyrics/Views/MainWindow/AppleMusicImmersiveV3Toolbar.swift').read_text()
start = source.index('enum V3ToolbarLog {')
end = source.index('struct QuietToolbarButtonStyle:', start)
panel_glass = (root / 'SpotifyLyrics/Views/Components/V3PanelGlass.swift').read_text()
panel_glass = panel_glass.replace('import AppKit\nimport SwiftUI\n', '')
controls = (root / 'SpotifyLyrics/Views/Components/LyricIslandControls.swift').read_text()
geometry = controls.split('// BEGIN EXTERNAL PANEL GEOMETRY', 1)[1].split('// END EXTERNAL PANEL GEOMETRY', 1)[0]
fixture = (root / 'Tests/v3_toolbar_popover_event_contract.swift').read_text()
stubs = '''
struct V3SceneChrome: Equatable {
    var tint: Color = .clear
    var strength: Double = 0
}
private struct V3SceneChromeKey: EnvironmentKey { static let defaultValue: V3SceneChrome? = nil }
extension EnvironmentValues {
    var v3SceneChrome: V3SceneChrome? {
        get { self[V3SceneChromeKey.self] }
        set { self[V3SceneChromeKey.self] = newValue }
    }
}
enum V3ToolbarStyle { case standard, sidePull }
@MainActor final class AppSettingsStore {
    static let shared = AppSettingsStore()
    var v3ToolbarStyle: V3ToolbarStyle = .standard
}
'''
(temp / 'main.swift').write_text('import AppKit\nimport Combine\nimport SwiftUI\nimport os\n' + stubs + panel_glass + source[start:end] + geometry + fixture)
PYTHON
swiftc -parse-as-library "$TEST_DIR/main.swift" -o "$TEST_DIR/native-toolbar"
"$TEST_DIR/native-toolbar"
