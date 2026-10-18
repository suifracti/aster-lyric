#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

swiftc -parse-as-library \
  "$ROOT/SpotifyLyrics/Models/Models.swift" \
  "$ROOT/SpotifyLyrics/Lyrics/TrackIdentity.swift" \
  "$ROOT/SpotifyLyrics/Lyrics/TrackAlias.swift" \
  "$ROOT/SpotifyLyrics/Lyrics/LyricsModels.swift" \
  "$ROOT/SpotifyLyrics/Lyrics/TrackTextNormalizer.swift" \
  "$ROOT/SpotifyLyrics/Lyrics/AlignmentModels.swift" \
  "$ROOT/SpotifyLyrics/Design/CurrentSongOperationState.swift" \
  "$ROOT/Tests/current_song_operations_contract.swift" \
  -o "$TMP/current-song-operations-contract"

"$TMP/current-song-operations-contract"

VIEW="$ROOT/SpotifyLyrics/Views/Components/CurrentSongOperationsView.swift"
if [[ ! -f "$VIEW" ]]; then
  echo "FAIL: missing current-song operations view" >&2
  exit 1
fi
grep -q 'selectNoLyricsVersion' "$VIEW"
grep -q 'selectNoTranslationVersion' "$VIEW"
grep -q 'prepareLyricsEditor\|prepareBlankLyricsEditor' "$VIEW"
grep -q 'retryLyrics' "$VIEW"
grep -q '版本状态' "$VIEW"
grep -q '已归档' "$VIEW"
grep -q '锁定' "$VIEW"
grep -q 'TranslationCandidatePreviewEvidence' "$VIEW"
if grep -Eq 'SQLite|Timer\(|currentTime\s*=|\.seek\(' "$VIEW"; then
  echo "FAIL: current-song view owns persistence, timers, or implicit seek" >&2
  exit 1
fi

python3 - "$VIEW" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text()
picker = source[source.index('private struct LyricsVersionPickerView:'):source.index('/// Formats the selected saved/displayed layers')]
assert '@State private var showSourceTranslation = false' in picker, 'version preview must hide provider translations by default'
assert 'Toggle("显示词源译文", isOn: $showSourceTranslation)' in picker, 'version preview must let the user reveal provider translations'
assert 'line.translationText' in picker, 'version preview must render stored provider translations when enabled'
assert '词源译文' in picker and '此版本没有词源译文' in picker, 'preview must distinguish available and absent provider translations'
PY

RECOVERY_VIEW="$ROOT/SpotifyLyrics/Views/Components/ManualLyricsActionsView.swift"
grep -q 'LyricsDiscoverySite' "$RECOVERY_VIEW"
grep -q '直接粘贴' "$RECOVERY_VIEW"
grep -q '复制检索词' "$RECOVERY_VIEW"

SETTINGS="$ROOT/SpotifyLyrics/Views/Settings/SettingsRootView.swift"
grep -q '随机度（Temperature）' "$SETTINGS"
grep -q '替换 API Key' "$SETTINGS"
grep -q '恢复推荐设置中心' "$SETTINGS"
grep -q 'settingsCenterPresentationRawValue' "$SETTINGS" || true
if grep -q 'hasStoredKey = keyStore.read' "$SETTINGS"; then
  echo "FAIL: AI settings reads Keychain on ordinary page appearance" >&2
  exit 1
fi

echo "current song operations source contract: PASS"
