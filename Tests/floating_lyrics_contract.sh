#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TIMELINE="$ROOT_DIR/SpotifyLyrics/Lyrics/LyricsModels.swift"
PLAYBACK="$ROOT_DIR/SpotifyLyrics/Services/PlaybackState.swift"
TRANSLATION="$ROOT_DIR/SpotifyLyrics/Services/TranslationSessionController.swift"
FLOATING_VIEW="$ROOT_DIR/SpotifyLyrics/Views/Floating/FloatingLyricsView.swift"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/floating-lyrics-contract.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

swiftc -parse-as-library \
  "$ROOT_DIR/SpotifyLyrics/Models/Models.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/TrackIdentity.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/AlignmentModels.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/LyricsModels.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/FloatingLyricsPresentation.swift" \
  "$ROOT_DIR/Tests/floating_lyrics_contract.swift" \
  -o "$TMP_DIR/floating-lyrics-contract"

"$TMP_DIR/floating-lyrics-contract"

require() {
  local file="$1"
  local pattern="$2"
  local label="$3"
  grep -Eq "$pattern" "$file" || {
    echo "FAIL: $label ($file does not contain /$pattern/)" >&2
    exit 1
  }
}

# The floating window reads a live-only projection and binary-searches the
# shared timeline; it must not become another translation or clock owner.
require "$PLAYBACK" 'liveLyrics' 'floating window has a live-only lyric projection'
require "$PLAYBACK" 'liveCurrentLineIndex' 'floating window uses the shared current-line calculation'
require "$PLAYBACK" 'liveLyricsProjectionCache' 'projection cache is owned by PlaybackState'
require "$TRANSLATION" 'identity: TrackIdentity' 'translation projection can validate live identity'
require "$TIMELINE" 'middle = lower' 'timeline lookup uses binary search'
require "$FLOATING_VIEW" 'NSAttributedString\(string: text, attributes:' 'floating text measurement uses current text before AppKit view update'
require "$FLOATING_VIEW" 'FloatingTimedRubyLayoutCache\.layout\(for: key\)' 'desktop timed layout reuses bounded geometry cache'
! grep -Eq 'lines\.indices\.last' "$TIMELINE" || {
  echo 'FAIL: timeline still scans from the end on every playback tick' >&2
  exit 1
}
