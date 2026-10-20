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

## B2 — pending

Distributed desktop-player notifications, low-frequency position calibration,
visible/playing clock lifecycle, stale-result arbitration and a matched
30-second CPU/RSS measurement will follow B1 in a separate commit.
