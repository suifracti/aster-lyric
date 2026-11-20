#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BACKDROP="$ROOT/SpotifyLyrics/Views/Components/AppleMusicImmersiveV3BackdropView.swift"
VIEW="$ROOT/SpotifyLyrics/Views/MainWindow/AppleMusicImmersiveV3WindowView.swift"
INSPECTOR="$ROOT/SpotifyLyrics/Views/MainWindow/AppleMusicImmersiveV3Inspector.swift"

grep -q '@ObservedObject var settings: AppSettingsStore' "$VIEW" || {
  echo 'FAIL: V3 main view does not observe live visual settings changes' >&2
  exit 1
}

grep -q 'settings: settings,' "$VIEW" || {
  echo 'FAIL: V3 main view is not wired to the shared settings store' >&2
  exit 1
}

grep -q '@ObservedObject var settings: AppSettingsStore' "$BACKDROP" || {
  echo 'FAIL: V3 backdrop does not observe live visual settings changes' >&2
  exit 1
}

grep -q '@ObservedObject var settings: AppSettingsStore' "$INSPECTOR" \
  && grep -q 'V3ThemeSelectorView(settings: settings,' "$VIEW" \
  && grep -q 'V3VisualControls(settings: settings,' "$VIEW" || {
  echo 'FAIL: V3 tuning controls do not receive the live settings store explicitly' >&2
  exit 1
}

echo 'V3 visual tuning reactivity contract: PASS'
