#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/capsule-v4-top-attached-contract.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

swiftc -parse-as-library \
  "$ROOT_DIR/SpotifyLyrics/Models/Models.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/TrackAlias.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/ReadingModels.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/ReadingScriptConversion.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/TrackTextNormalizer.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/TrackIdentity.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/AlignmentModels.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/LyricsModels.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/CapsuleLyricsPresentation.swift" \
  "$ROOT_DIR/Tests/capsule_v4_top_attached_contract.swift" \
  -o "$TMP_DIR/capsule-v4-top-attached-contract"

"$TMP_DIR/capsule-v4-top-attached-contract"

if ! rg -n 'debugEnvelopeSize|topAttachedEnvelopeFrame|topAttachedIslandFrame' \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/CapsuleLyricsPresentation.swift" >/dev/null; then
  echo "v4 must expose fixed top-attached geometry" >&2
  exit 1
fi

if ! rg -n 'screen\.frame|maxY.*envelope|envelopeHeight' \
  "$ROOT_DIR/SpotifyLyrics/Windows/CapsuleLyricsWindowController.swift" \
  "$ROOT_DIR/SpotifyLyrics/Lyrics/CapsuleLyricsPresentation.swift" >/dev/null; then
  echo "top-attached debug path must use the physical screen frame" >&2
  exit 1
fi

if ! rg -n 'hasShadow\s*=\s*false|ignoresMouseEvents|hitTest|addGlobalMonitorForEvents' \
  "$ROOT_DIR/SpotifyLyrics/Windows/CapsuleLyricsWindowController.swift" >/dev/null; then
  echo "top-attached debug path must provide transparent hit testing and pass-through" >&2
  exit 1
fi

if ! rg -n 'CapsuleV4TopAttachedShape|topAttached' \
  "$ROOT_DIR/SpotifyLyrics/Views/Capsule/CapsuleLyricsView.swift" >/dev/null; then
  echo "v4 top-attached path must use a dedicated one-sided shell shape" >&2
  exit 1
fi

echo "capsule v4 top-attached static contract: PASS"
