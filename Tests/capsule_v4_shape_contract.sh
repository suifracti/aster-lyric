#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/capsule-v4-shape-contract.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

swiftc -parse-as-library \
  "$ROOT_DIR/SpotifyLyrics/DebugDatabaseSafety.swift" \
  "$ROOT_DIR/SpotifyLyrics/Models/Models.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/TrackAlias.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/ReadingModels.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/ReadingScriptConversion.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/TrackTextNormalizer.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/TrackIdentity.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/AlignmentModels.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/LyricsModels.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/CapsuleLyricsPresentation.swift" \
  "$ROOT_DIR/Tests/capsule_v4_shape_contract.swift" \
  -o "$TMP_DIR/capsule-v4-shape-contract"

"$TMP_DIR/capsule-v4-shape-contract"

test "$(grep -Ec '^final class CapsuleLyricsWindowController' "$ROOT_DIR/SpotifyLyrics/Windows/CapsuleLyricsWindowController.swift")" = "1"
if grep -rnE 'class .*V4.*WindowController|struct .*V4.*WindowController' "$ROOT_DIR/SpotifyLyrics" >/dev/null; then
  echo "v4 must not add a second capsule window controller" >&2
  exit 1
fi
if grep -rnE 'Timer|LyricsSessionController|TranslationSessionController' \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/CapsuleLyricsPresentation.swift" \
  "$ROOT_DIR/SpotifyLyrics/Windows/CapsuleLyricsWindowPersistence.swift" \
  "$ROOT_DIR/SpotifyLyrics/Views/Capsule/CapsuleLyricsView.swift" >/dev/null; then
  echo "v4 geometry/shell layer must not add timers or session owners" >&2
  exit 1
fi

# The only v4 force entry is a Debug command; Release has no such menu path.
awk '
  /#if DEBUG/ { debugDepth += 1 }
  /胶囊呈现（调试）/ { found = (debugDepth > 0) }
  /#endif/ { debugDepth -= 1 }
  END { exit(found ? 0 : 1) }
' "$ROOT_DIR/SpotifyLyrics/Main.swift"
