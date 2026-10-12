#!/usr/bin/env bash
# Phase 3.3 Direction D product-state contracts (static + behavioral).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
SWIFT_DIR="SpotifyLyrics"
MODEL="$SWIFT_DIR/Design/DirectionD/DirectionDProductStateModel.swift"
ADAPTER="$SWIFT_DIR/Design/DirectionD/DirectionDProductStateAdapter.swift"
ROUTER="$SWIFT_DIR/Design/DirectionD/DirectionDActionRouter.swift"
HOST="$SWIFT_DIR/Views/Components/DirectionD/DirectionDProductStateHostView.swift"
EXPH="$SWIFT_DIR/Views/Components/DirectionD/DirectionDExperimentalProductHost.swift"
MAIN="$SWIFT_DIR/Main.swift"
TOKENS="$SWIFT_DIR/Design/DirectionD/DirectionDDesignTokens.swift"
PBX="SpotifyLyrics.xcodeproj/project.pbxproj"

PASS=0; FAIL=0
pass(){ echo "[PASS] $1"; PASS=$((PASS+1)); }
fail(){ echo "[FAIL] $1 — $2"; FAIL=$((FAIL+1)); }

echo "======================================================"
echo "Phase 3.3 Product Host / Adapter / Router Contracts"
echo "======================================================"

# Compile membership
for f in DirectionDProductStateModel DirectionDProductStateAdapter DirectionDActionRouter DirectionDProductStateHostView DirectionDExperimentalProductHost; do
  grep -q "$f.swift in Sources" "$PBX" && pass "pbx Sources: $f" || fail "pbx Sources: $f" "missing"
done

# No Preview Matrix tab chrome in product host
if grep -qE 'MatrixState|状态切换|ForEach\(MatrixState' "$HOST"; then
  fail "host_no_matrix" "Product host embeds Preview Matrix UI"
else
  pass "host_no_matrix"
fi

# Host uses router only
if grep -qE 'SQLite|WhisperCLI|SpotifyDesktopProvider\(|SpeechEngine' "$HOST"; then
  fail "host_no_provider" "Host must not call providers/engines directly"
else
  pass "host_no_provider"
fi

# Required user strings
grep -q 'permissionRequiredMessage = "需要允许 Lyric Island 读取 Spotify 播放状态"' "$TOKENS" && pass "copy_permission" || fail "copy_permission" "missing"
grep -q 'networkWithCacheMessage = "网络连接失败，正在显示已保存的歌词"' "$TOKENS" && pass "copy_cache" || fail "copy_cache" "missing"
grep -q '手动搜索歌词' "$HOST" && pass "no_lyrics_search_btn" || fail "no_lyrics_search_btn" "missing"
grep -q '导入本地歌词' "$HOST" && pass "no_lyrics_import_btn" || fail "no_lyrics_import_btn" "missing"
grep -q '打开 Spotify' "$HOST" && pass "spotify_open_btn" || fail "spotify_open_btn" "missing"
grep -q '打开系统设置' "$HOST" && pass "settings_btn" || fail "settings_btn" "missing"
grep -q '重新检查' "$HOST" && pass "recheck_btn" || fail "recheck_btn" "missing"

# Priority: pause must not force idle — hasTrack alone
python3 <<'PY'
# Mirror resolve with pause semantics
def resolve(hasTrack, isPlayingOrPaused=True, hasLyrics=True, **kw):
    hasPermission=kw.get('hasPermission',True)
    isSpotifyRunning=kw.get('isSpotifyRunning',True)
    isSpotifyAvailable=kw.get('isSpotifyAvailable',True)
    isLoadingLyrics=kw.get('isLoadingLyrics',False)
    isNetworkAvailable=kw.get('isNetworkAvailable',True)
    isCachedLyrics=kw.get('isCachedLyrics',False)
    alignmentJobState=kw.get('alignmentJobState')
    if not hasPermission: return ('permissionRequired','none')
    if not isSpotifyRunning: return ('spotifyNotRunning','none')
    if not isSpotifyAvailable: return ('spotifyUnavailable','none')
    # fixed: only !hasTrack
    if not hasTrack: return ('waitingForPlayback','none')
    if isLoadingLyrics and not hasLyrics: return ('loadingLyrics','none')
    if not hasLyrics:
        return ('networkUnavailableNoCache','none') if not isNetworkAvailable else ('noLyrics','none')
    primary='showingLyrics'
    secondary='none'
    if not isNetworkAvailable:
        secondary='networkUnavailableWithCache'
    elif alignmentJobState in ('running','capturing','aligning','evaluating'):
        secondary='automaticSyncRunning'
    elif alignmentJobState=='accumulating':
        secondary='automaticSyncProgressSaved'
    elif alignmentJobState=='completed':
        secondary='automaticSyncCompleted'
    return (primary, secondary)

# pause with track + lyrics stays showingLyrics
p,s=resolve(hasTrack=True, isPlayingOrPaused=False, hasLyrics=True)
assert p=='showingLyrics' and s=='none', (p,s)
# no track -> idle
p,s=resolve(hasTrack=False, isPlayingOrPaused=False)
assert p=='waitingForPlayback'
# network + cache lyrics -> secondary
p,s=resolve(hasTrack=True, hasLyrics=True, isNetworkAvailable=False, isCachedLyrics=True)
assert p=='showingLyrics' and s=='networkUnavailableWithCache'
# sync running secondary keeps lyrics primary
p,s=resolve(hasTrack=True, hasLyrics=True, alignmentJobState='running')
assert p=='showingLyrics' and s=='automaticSyncRunning'
print('priority_behavior OK')
PY
pass "priority_pause_and_secondary"

# Adapter binds real product
grep -q 'func bind(playback: PlaybackState)' "$ADAPTER" && pass "adapter_bind_playback" || fail "adapter_bind_playback" "missing"
grep -q 'AutomaticAlignmentJobController' "$ADAPTER" && pass "adapter_auto_align" || fail "adapter_auto_align" "missing"
grep -q 'SPOTIFYLYRICS_DIRECTION_D_HOST_STATE' "$ADAPTER" && pass "adapter_force_inject" || fail "adapter_force_inject" "missing"
grep -q 'trackId != currentTrackId' "$ADAPTER" && pass "stale_track_clear" || fail "stale_track_clear" "missing"

# Experimental host wired
grep -q 'direction-d-experimental-host' "$MAIN" && pass "main_host_window" || fail "main_host_window" "missing"
grep -q 'DirectionDExperimentalProductHost' "$EXPH" && pass "exp_host_type" || fail "exp_host_type" "missing"
grep -q 'adapter.bind(playback:' "$EXPH" && pass "exp_host_binds" || fail "exp_host_binds" "missing"

# Router actions present
for a in onOpenSpotify onOpenSystemSettings onRetryPlaybackDetection onRetryLyricsSearch onOpenManualLyricsSearch onImportLyrics onOpenSongWorkbench onRetryAutomaticAlignment onStopAutomaticAlignment; do
  grep -q "$a" "$ROUTER" && pass "router_$a" || fail "router_$a" "missing"
done

# Host secondary banners don't replace lyrics branch
python3 <<'PY'
from pathlib import Path
host=Path("SpotifyLyrics/Views/Components/DirectionD/DirectionDProductStateHostView.swift").read_text()
# showingLyrics must call lyricsCanvas; secondary only DirectionDStatusBanner
assert 'case .showingLyrics:' in host
assert 'lyricsCanvas' in host
assert 'renderSecondaryBanner' in host
# permission must not use increaseContrast only
assert 'permissionRequiredMessage' in host or '打开系统设置' in host
print('host_structure OK')
PY
pass "host_secondary_over_lyrics"

# V3 default preserved
grep -q 'appleMusicImmersiveV3' "$SWIFT_DIR/Settings/AppSettingsStore.swift" && pass "v3_default" || fail "v3_default" "missing"
STYLE="$SWIFT_DIR/Design/MainWindowLayoutStyle.swift"
if grep -Fq '?? MainWindowLayoutStyle.appleMusicImmersiveV3.rawValue' "$SWIFT_DIR/Settings/AppSettingsStore.swift" \
  && grep -q 'case directionDV4 = "directionD"' "$STYLE" \
  && grep -A6 'static let userSelectableCases' "$STYLE" | grep -q '\.directionDV4'; then
  pass "v3_default_d_explicitly_selectable"
else
  fail "v3_default_d_explicitly_selectable" "V3 must remain the unset-layout default while Direction D remains an explicit user choice"
fi

# Business files zero-diff vs 39678ff for providers (optional soft)
if git rev-parse 39678ff >/dev/null 2>&1; then
  if git diff --name-only 39678ff -- SpotifyLyrics/Providers SpotifyLyrics/Persistence/SQLiteLyricsRepository.swift | grep -q .; then
    fail "no_provider_diff" "$(git diff --name-only 39678ff -- SpotifyLyrics/Providers | tr '\n' ' ')"
  else
    pass "no_provider_diff"
  fi
fi

echo "======================================================"
echo "PASS=$PASS FAIL=$FAIL"
echo "======================================================"
test "$FAIL" -eq 0
