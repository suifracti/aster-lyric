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
Saving a revision from the personal library does not adopt it automatically;
it refreshes the library, and adoption remains the explicit “set current” action.

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

Local full native target: **58 tests, 1 optional resource probe skipped,
0 failures**. The resource probe then passed separately. Native test mode also
skips automatic capture and orphan-capture cleanup and keeps capture logs in
the private host root. The isolated visual host builds after adapting its
entry-point replacement to the new XCTest-compatible app entrypoint. New coverage includes
both payload formats, real distributed transport under a private test name,
track/partial pause, process exit, hidden/show clock lifecycle, transient errors,
stale in-flight reads, same-recording pause recovery, position-only scripts,
short-track units, cover identity/de-duplication and sparse capture continuity.
The player names themselves use injected notification centers in tests; no
public player broadcasts were synthesized and no real recording was started.

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

Reproduce the optional sample after build-for-testing:

```sh
python3 Scripts/measure-playback-resources.py \
  --xctestrun /path/to/Build/Products/SpotifyLyrics_macosx26.5-arm64.xctestrun \
  --output /tmp/lyricsq-probe-new.json
```

Use the generated xctestrun filename for the installed SDK. The script refuses
to overwrite existing output and launches only the isolated test host.
