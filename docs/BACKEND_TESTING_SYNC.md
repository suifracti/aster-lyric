# Backend test and playback synchronization work

## B1 — native test infrastructure

Input: `5c76b38735a3970bd49ad64060446a629bb9cd5c`.

Added the hosted `SpotifyLyricsTests` XCTest target and shared SpotifyLyrics
scheme. Tests import the built app module with `@testable`; they no longer
assemble partial production sources with hand-maintained `swiftc` lists.
The DEBUG test entrypoint skips normal SwiftUI startup, redirects shared
preferences/home/database/provenance to private test storage, and disables
Keychain. Individual repository fixtures use separate temporary SQLite files.

The specified editor, revisions, library identity/search, settings/menu-bar,
floating, history/statistics, experience and scoped-offset contracts are
migrated. The complete original O1 SQLite/editor/version checks are retained.
Song-search models/provider-failure tests are migrated too, so its wrapper no
longer needs rg or a second source list. Phase-1 UI uses system grep. The toolbar
model's 28 checks remain at `Tests/v3_toolbar_model_contract.swift`; inspector
navigation and source connections are included in the native target.

Validation on Mac: `LYRICSQ_TEST_DERIVED_DATA=/tmp/lyricsq-native-derived bash
Scripts/test-native.sh` — 35 tests, 0 failures. `bash
Tests/phase1_ui_contract.sh` passed. XCTest builds the full AppKit/SwiftUI app.
This is not physical mouse or visual acceptance. See `Tests/NATIVE_TESTS.md`
for migration mapping and test isolation boundaries.

CI now runs the complete target and existing supplemental checks, failing the
required final gate on any failure; it also runs for PRs and version tags.
A release must use a commit where this job is green.

## Editor copy guidance

Saving from the main lyrics editor immediately adopts its saved new version:
`LyricsEditorSessionController.applySaved` calls `onSaved`, and PlaybackState
routes that result to `lyricsSession.adoptPersisted`. Original versions remain.
Saving a lyrics revision from the personal library also adopts the new version.
For the currently playing song it uses the same `adoptCurrentLyricsVersion`
path as “set current”; editing another song updates only that song's saved
selection. Original and locked source versions remain available.

## B2 — desktop playback events

DesktopPlaybackEvents listens to Spotify PlaybackStateChanged and Music
playerInfo, plus player process/window visibility lifecycle. Track, metadata and
play/pause notifications update the shared session directly. Auto mode ignores
pause events from the other background player and still bootstraps when the
Spotify-only launch toggle is off (as does explicitly selected Music). Monotonic time remains available
when the published display clock is stopped; showing a lyric window catches up
immediately. The 0.2s display timer stops while paused or all lyric windows are
unexposed. Menu-bar text can retain one-shot line-boundary updates.

Steady-state AppleScript is a 10-second position/state/recording-ID correction,
only while playing and the selected process exists. Initial connection,
explicit reconnect and unacknowledged user commands retain bounded snapshot
reads. A notification missing cover art can trigger one identity-scoped asset
read; this does not poll playback state or repeat with every display tick.
Spotify and Music use their existing serial, timeout-bounded runners. The
existing refresh generation rejects stale reads and restores the accepted
provider cache/command route too. Recording/source gates and request dedup
remain; capture continuity uses the raw monotonic clock and elapsed-time drift,
so sparse hidden-window samples do not become false seeks.

The notification suite now keeps five scenarios: changing songs (Spotify and
Music payloads), pause/resume, hiding then showing lyrics, player exit, and an
old poll that cannot overwrite a newer notification. The duplicate concrete
provider stale-read scenario was removed; the existing provider position/asset
unit checks remain. Production playback behavior is unchanged by this trim.
The resource XCTest and its CI target membership have been removed.

### Matched 30-second backend resource comparison

Both are native hosted Debug -Onone arm64 builds on this Mac, with the same
cached-song probe, 2-second warmup and 30-second measurement. The before backend
is B1 `09272b4`, with the same test-only isolation hooks and probe; the candidate also includes the intervening library UI fix,
which is not instantiated in this headless probe.

| Measurement | Before | After |
| --- | ---: | ---: |
| Average host CPU | 1.197% | 0.985% |
| RSS start / end | 66.08 / 51.91 MiB | 66.08 / 60.27 MiB |
| Peak RSS | 66.16 MiB | 66.11 MiB |
| Provider refreshes during 30s | 26 | 3 |

This single paired backend fixture does **not** establish a new daily-App CPU
or memory baseline against the user's reported 0.1% / 130–150MB. It does not
measure child osascript CPU, WindowServer or frame time. Both runs load the
cached 64 lyric lines and make zero provider lyric requests/player commands.
Raw samples, exact executable hashes, build configuration and test excerpt:
[evidence](evidence/b2-playback-events-20261020/manifest.json).

### Manual process sampling (outside CI)

The table above is historical evidence from the removed headless XCTest probe.
It is not directly comparable with a visible app process. For a new comparison,
launch each desired build in turn with the same cached song, window and scene,
then sample its PID:

```sh
python3 Scripts/measure-playback-resources.py --pid APP_PID \
  --label "build SHA; song; scene; window size" --seconds 30 --warmup 2 \
  --output /tmp/lyricsq-process-sample.json
```

Run once per build with separate output files. This one-off script reads
cumulative process CPU time and RSS through `ps`; one core is 100%. Raw samples
and the executable path are included in JSON. It does not build or launch an
app, access its database, control a player, or measure child osascript CPU,
WindowServer or frame time. It has no performance thresholds and is not run by CI.
