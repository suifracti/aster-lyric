#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
TMP_DIR="$(mktemp -d /tmp/spotifylyrics-spotify-web.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT
cp Tests/spotify_web_catalog_contract.swift "$TMP_DIR/main.swift"
swiftc -D DEBUG -parse-as-library \
  SpotifyLyrics/Models/Models.swift \
  SpotifyLyrics/Lyrics/TrackIdentity.swift \
  SpotifyLyrics/Lyrics/LyricsModels.swift \
  SpotifyLyrics/Lyrics/AlignmentModels.swift \
  SpotifyLyrics/Lyrics/TrackAlias.swift \
  SpotifyLyrics/Lyrics/TrackMetadata.swift \
  SpotifyLyrics/Lyrics/TrackTextNormalizer.swift \
  SpotifyLyrics/Lyrics/JapaneseRomanizer.swift \
  SpotifyLyrics/Lyrics/JapaneseReadingPipeline.swift \
  SpotifyLyrics/Lyrics/JapaneseKanaGenerator.swift \
  SpotifyLyrics/Lyrics/LyricsE2ELog.swift \
  SpotifyLyrics/DebugDatabaseSafety.swift \
  SpotifyLyrics/Lyrics/PersonalLyricsLibraryModels.swift \
  SpotifyLyrics/Search/SongSearchModels.swift \
  SpotifyLyrics/Search/TrackSearchModels.swift \
  SpotifyLyrics/Providers/PlaybackProvider.swift \
  SpotifyLyrics/Spotify/SpotifyAPIModels.swift \
  SpotifyLyrics/Spotify/SpotifyTokenStore.swift \
  SpotifyLyrics/Spotify/SpotifyCatalogService.swift \
  SpotifyLyrics/Spotify/SpotifyAuthorizationManager.swift \
  SpotifyLyrics/Search/SpotifyTrackMapper.swift \
  SpotifyLyrics/Search/TrackSearchProvider.swift \
  SpotifyLyrics/Search/SpotifySearchProvider.swift \
  "$TMP_DIR/main.swift" \
  -o "$TMP_DIR/spotify-web-catalog-contract"
"$TMP_DIR/spotify-web-catalog-contract"
if grep -q 'kSecUseDataProtectionKeychain' SpotifyLyrics/Spotify/SpotifyTokenStore.swift; then
  echo "SpotifyTokenStore must not use the data protection keychain: ad-hoc builds have no application-identifier entitlement" >&2
  exit 1
fi
grep -q 'kSecUseAuthenticationUI' SpotifyLyrics/Spotify/SpotifyTokenStore.swift
grep -q 'spotify-oauth.v3' SpotifyLyrics/Spotify/SpotifyTokenStore.swift
grep -q 'SecAccessCreate' SpotifyLyrics/Spotify/SpotifyTokenStore.swift
grep -q 'dashboardRedirectURI = "http://127.0.0.1/callback"' SpotifyLyrics/Spotify/SpotifyCatalogService.swift
grep -q 'port: .any' SpotifyLyrics/Spotify/SpotifyAuthorizationManager.swift
grep -q 'redirectURI(port: port)' SpotifyLyrics/Spotify/SpotifyAuthorizationManager.swift
grep -q 'redirectURI: pending.redirectURI' SpotifyLyrics/Spotify/SpotifyAuthorizationManager.swift
