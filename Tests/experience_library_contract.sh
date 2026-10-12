#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

swiftc \
  "$ROOT/SpotifyLyrics/Models/Models.swift" \
  "$ROOT/SpotifyLyrics/Lyrics/TrackIdentity.swift" \
  "$ROOT/SpotifyLyrics/Lyrics/LyricsModels.swift" \
  "$ROOT/SpotifyLyrics/Lyrics/AlignmentModels.swift" \
  "$ROOT/SpotifyLyrics/Design/PresentationCatalog.swift" \
  "$ROOT/SpotifyLyrics/Design/PresentationPreviewContext.swift" \
  "$ROOT/SpotifyLyrics/Design/PresentationPreviewEngine.swift" \
  "$ROOT/SpotifyLyrics/Design/PresentationPreviewRendererRegistry.swift" \
  "$ROOT/SpotifyLyrics/Design/SettingsCenterPresentation.swift" \
  "$ROOT/Tests/experience_library_contract.swift" \
  -o "$TMP/experience-library-contract"

"$TMP/experience-library-contract"

ADAPTERS="$ROOT/SpotifyLyrics/Views/Debug/PresentationPreviewAdapters.swift"
if grep -v '^///' "$ADAPTERS" | grep -Eq 'PlaybackState|LyricsSession|TranslationSession|Timer|SQLite|seek\('; then
  echo "FAIL: preview adapters contain forbidden runtime ownership or commands" >&2
  exit 1
fi

VIEW="$ROOT/SpotifyLyrics/Views/Settings/ExperienceLibrarySettingsView.swift"
if [[ ! -f "$VIEW" ]]; then
  echo "FAIL: missing release experience library view" >&2
  exit 1
fi
grep -q '体验版本库' "$VIEW"
grep -q 'PresentationPreviewAdapterView' "$VIEW"
grep -q 'applyPresentationSelection' "$VIEW"
grep -q 'Restore Recommended\|恢复推荐' "$VIEW"
if grep -Eq 'snapshotKey|renderer signature|Observer 数量|Debug geometry|Apply-to-Debug' "$VIEW"; then
  echo "FAIL: debug-only diagnostics leaked into release experience library" >&2
  exit 1
fi

SETTINGS="$ROOT/SpotifyLyrics/Views/Settings/SettingsRootView.swift"
if grep -Eq 'ForEach\(SettingsCategory\.allCases\.filter \{ includeExperienceLibrary \|\| \$0 != \.experienceLibrary \}\)' "$SETTINGS"; then
  echo "FAIL: experience library is still a top-level Settings item" >&2
  exit 1
fi
python3 - "$SETTINGS" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text()
primary_start = source.index("static var primaryCases")
primary_end = source.index("\n    }", primary_start)
primary_cases = source[primary_start:primary_end]
assert ".experienceLibrary" not in primary_cases, "experience library must stay out of primary sidebar"

label = 'Label("打开体验版本库"'
label_index = source.index(label)
button_start = source.rfind("Button {", 0, label_index)
button_end = source.index('accessibilityIdentifier("btn_enter_experience_library")', label_index)
button = source[button_start:button_end]
assert "onOpenTool(.experienceLibrary)" in button, "experience library button has no selected-tool route"

detail_start = source.index("private struct SettingsDetailView")
detail = source[detail_start:]
assert "onOpenTool: { tool in selection = tool }" in detail, "advanced settings do not route tool selection"
experience_case = detail.index("case .experienceLibrary:")
assert "ExperienceLibrarySettingsView(selectionStore: settings.presentationSelections)" in detail[experience_case:], \
    "experience-library selection does not present the production settings view"
print("experience library settings route: PASS")
PY

echo "experience library source contract: PASS"
