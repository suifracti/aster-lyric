#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}/.."
FILE="$ROOT/SpotifyLyrics/Views/Components/CurrentSongOperationsView.swift"

for needle in \
  'translationSection' \
  'translationProgressMessage' \
  '重新翻译' \
  '锁定当前翻译' \
  '删除当前翻译' \
  'selectTranslation' \
  'lockSelectedTranslation' \
  'deleteSelectedTranslation'; do
  grep -F "$needle" "$FILE" >/dev/null
done

print "translation UI contract passed"

# Source-scope contract: preview enters a branch with no live operation views.
# This is static UI evidence, not native rendering or button-click acceptance.
python3 - "$ROOT" <<'PYUI'
from pathlib import Path
import sys
root = Path(sys.argv[1])
canvas = (root / 'SpotifyLyrics/Views/Components/LyricsCanvasView.swift').read_text()
content = canvas[canvas.index('struct LyricsStateContentFirstView:'):]
body = content[content.index('var body: some View'):content.index('private var statusContent')]
assert 'if state.isShowingSearchPreview {\n                searchPreviewContent' in body, 'preview empty/candidate branch must be read-only before live status/actions'
readonly = content[content.index('private var searchPreviewContent'):content.index('private var statusContent')]
for forbidden in ['markCurrentTrackAsInstrumental', 'ManualLyricsActionsView', 'selectNoLyricsVersion', 'importLocalAudioForASR', 'candidateToPreview =', 'onAdopt:']:
    assert forbidden not in readonly, 'live mutation reachable from read-only preview: ' + forbidden
assert 'clearSearchPreview()' in readonly
assert 'if !state.isShowingSearchPreview {' in body, 'old candidate sheet must not survive preview'
system = canvas[canvas.index('private var systemStateContent'):canvas.index('private var contentFirstStateContent')]
assert 'if state.isShowingSearchPreview {' in system and 'LyricsStateContentFirstView(state: state' in system, 'classic renderer must share preview boundary'
v3 = (root / 'SpotifyLyrics/Views/MainWindow/AppleMusicImmersiveV3WindowView.swift').read_text()
assert 'if liveOnly || !state.isShowingSearchPreview {' in v3, 'live-only toolbar retained'
assert 'liveOnly ? state.liveLyricsState : state.lyricsState' in v3
print('PASS static preview noLyrics/noMatch/failed/candidates action scope; classic/contentFirst; live-only source boundary retained')
PYUI
