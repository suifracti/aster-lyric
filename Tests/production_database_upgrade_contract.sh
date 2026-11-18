#!/usr/bin/env bash
set -euo pipefail
umask 077
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
derived="${LYRICSQ_TEST_DERIVED_DATA:-${TMPDIR:-/tmp}/lyricsq-native-derived}"
architecture="$(uname -m)"
for name in $(compgen -e); do
  case "$name" in SPOTIFYLYRICS_*|LYRICSQ_*|SPOTIFY_CLIENT_ID) unset "$name" ;; esac
done

# Link the same complete app module as the native tests, with this isolated
# CLI as the entry point. This also keeps the optional audit binary standalone.
xcodebuild -quiet build -scheme SpotifyLyrics -project SpotifyLyrics.xcodeproj -configuration Debug \
  -destination "platform=macOS,arch=$architecture" -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO
objects="$derived/Build/Intermediates.noindex/SpotifyLyrics.build/Debug/SpotifyLyrics.build/Objects-normal/$architecture"
fixture="$(mktemp -d /tmp/spotifylyrics-production-upgrade.XXXXXX)"
trap 'rm -rf "$fixture"' EXIT
mkdir -m 700 "$fixture/home" "$fixture/m1-home"
runner="$fixture/production-upgrade-contract"
xcrun swiftc -parse-as-library -target "$architecture-apple-macos14" -I "$derived/Build/Products/Debug" \
  -Xfrontend -entry-point-function-name -Xfrontend upgradeContractMain -Xlinker -e -Xlinker _upgradeContractMain \
  -Xlinker -filelist -Xlinker "$objects/SpotifyLyrics.LinkFileList" Tests/production_database_upgrade_contract.swift -o "$runner"

export SPOTIFYLYRICS_CONTRACT_ROOT="$fixture"
CFFIXED_USER_HOME="$fixture/home" "$runner"
CFFIXED_USER_HOME="$fixture/m1-home" "$runner" --m1-migrations
if [[ -n "${UPGRADE_AUDIT_BINARY:-}" ]]; then cp "$runner" "$UPGRADE_AUDIT_BINARY"; fi
