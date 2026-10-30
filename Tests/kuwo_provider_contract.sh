#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TASK_TMP_DIR="$(mktemp -d /tmp/kuwo-provider-contract.XXXXXX)"
trap 'rm -rf "$TASK_TMP_DIR"' EXIT
swiftc -parse-as-library SpotifyLyrics/Models/Models.swift SpotifyLyrics/Lyrics/TrackIdentity.swift SpotifyLyrics/Lyrics/TrackTextNormalizer.swift SpotifyLyrics/Lyrics/TrackAlias.swift SpotifyLyrics/Lyrics/AlignmentModels.swift SpotifyLyrics/Lyrics/LyricsModels.swift SpotifyLyrics/Lyrics/LyricsMatcher.swift SpotifyLyrics/Providers/KuwoExperimentalLyricsProvider.swift Tests/kuwo_provider_contract.swift -o "$TASK_TMP_DIR/contract"
"$TASK_TMP_DIR/contract"
