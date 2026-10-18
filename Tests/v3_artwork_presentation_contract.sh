#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SETTINGS="$ROOT/SpotifyLyrics/Settings/AppSettingsStore.swift"
BACKDROP="$ROOT/SpotifyLyrics/Views/Components/AppleMusicImmersiveV3BackdropView.swift"
WINDOW="$ROOT/SpotifyLyrics/Views/MainWindow/AppleMusicImmersiveV3WindowView.swift"

for stable_id in \
  'v3ArtworkPresentation.ambient.v1' \
  'v3ArtworkPresentation.stage.v1' \
  'v3ArtworkPresentation.classic.v1' \
  'v3ArtworkPresentation.gaussian.v1' \
  'v3ArtworkPresentation.feathered.v1' \
  'v3ArtworkPresentation.lyricsOnly.v1' \
  'v3ArtworkPresentation.albumPoster.v1'; do
  grep -q "$stable_id" "$SETTINGS" || {
    echo "missing stable V3 artwork presentation ID: $stable_id" >&2
    exit 1
  }
done

grep -q 'v3ArtworkPresentationRawValue' "$SETTINGS"
grep -q 'v3AmbientBackdropEnabled' "$SETTINGS" || {
  echo "old ambient preference must remain as a migration input" >&2
  exit 1
}
grep -q 'switch artworkPresentation' "$BACKDROP"
grep -q 'stageArtworkLayers' "$BACKDROP"
grep -q 'case .stage' "$BACKDROP"
grep -q 'case .ambientFeathered' "$BACKDROP" || {
  echo "missing independent feathered ambient mode" >&2
  exit 1
}
grep -q 'v3BackdropBlurFeathered' "$SETTINGS" || {
  echo "new mode must remember its own blur" >&2
  exit 1
}

grep -q 'settings.v3ArtworkPresentation = style' "$WINDOW"
grep -q 'V3ThemeSelectorView' "$WINDOW"
grep -q 'showsForegroundArtwork' "$WINDOW"
grep -q 'v3ShowForegroundArtwork' "$SETTINGS"
grep -q 'Toggle("显示前景封面", isOn: \$settings.v3ShowForegroundArtwork)' "$WINDOW"
grep -q 'lyricsOnlyLayout(in: geometry, hidesArtwork: true)' "$WINDOW"
grep -q 'V3WindowEdgePlaybackOverlay' "$WINDOW"
grep -q 'V3WindowEdgeProgressSettings' "$WINDOW"
grep -q 'lastWindowExitPoint = pointerLocationBox.location' "$WINDOW"
grep -q 'guard !settings.v3EdgeProgressEnabled else { return false }' "$WINDOW"
grep -q 'topChromeInset: 44' "$WINDOW"
grep -q 'blurControlTitle' "$SETTINGS" || {
  echo "V3 presentations must expose mode-specific blur semantics" >&2
  exit 1
}
grep -q 'artworkSizeControlTitle' "$SETTINGS" || {
  echo "V3 presentations must expose mode-specific size semantics" >&2
  exit 1
}
grep -q 'artworkPositionControlTitle' "$SETTINGS" || {
  echo "V3 presentations must expose mode-specific position semantics" >&2
  exit 1
}
grep -q 'min(1.4, max(0.8, artworkSizeScale))' "$BACKDROP" || {
  echo "Stage backdrop must honor the full 80–140% scale range" >&2
  exit 1
}
grep -q 'classicArtworkOffset' "$BACKDROP" || {
  echo "Classic backdrop must visibly react to crop position" >&2
  exit 1
}

python3 - "$ROOT" <<'PYTEST'
from pathlib import Path
import sys, tempfile, subprocess
root = Path(sys.argv[1])
s = (root/'SpotifyLyrics/Settings/AppSettingsStore.swift').read_text()
a = s.index('public enum V3ArtworkTheme:')
b = s.index('public enum PlaybackSourceMode:', a)
host = s[a:b] + '\n' + r'''
@main struct ThemeCheck {
    static func main() {
        precondition(V3ArtworkPresentation.ambientVariants.count == 3)
        precondition(V3ArtworkPresentation.enlargedVariants.count == 2)
        precondition(V3ArtworkPresentation.ambientVariants.allSatisfy { $0.theme == .ambient })
        precondition(V3ArtworkPresentation.enlargedVariants.allSatisfy { $0.theme == .enlarged })
        precondition(V3ArtworkPresentation.authenticAmbient.theme == .ambient)
        precondition(V3ArtworkPresentation.classic.theme == .ambient)
        precondition(V3ArtworkPresentation.ambient.theme == .enlarged)
        precondition(Set(V3ArtworkPresentation.ambientVariants).isDisjoint(with: Set(V3ArtworkPresentation.enlargedVariants)))
        precondition(V3ArtworkPresentation.allCases.count == 8)
        precondition(V3ArtworkTheme.allCases.suffix(2) == [.ambient, .enlarged])
        print("PASS three ambient variants and two enlarged variants; legacy IDs remain distinct")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='lyrics-theme-') as d:
    p = Path(d)/'ThemeCheck.swift'; p.write_text(host)
    subprocess.run(['swiftc', '-parse-as-library', str(p), '-o', str(Path(d)/'check')], check=True)
    subprocess.run([str(Path(d)/'check')], check=True)
window = (root/'SpotifyLyrics/Views/MainWindow/AppleMusicImmersiveV3WindowView.swift').read_text()
assert 'artworkStylePicker' not in window and 'isStylePickerPresented' not in window
backdrop = (root/'SpotifyLyrics/Views/Components/AppleMusicImmersiveV3BackdropView.swift').read_text()
start = backdrop.index('    private func gaussianArtworkLayers')
end = backdrop.index('    @ViewBuilder', start)
assert 'blur: effectiveBlurRadius' in backdrop[start:end]
assert '.blendMode' not in backdrop[start:end], 'pure Gaussian must remain separate from light bloom'
frame_start = backdrop.index('    private func framedArtwork')
frame_end = backdrop.index('    private func classicArtworkOffset', frame_start)
assert '.blur(radius: blur)' in backdrop[frame_start:frame_end]
PYTEST
echo "V3 artwork presentation contract passed"
