# Native contracts

Run `bash Scripts/test-native.sh` (Xcode 16+ on macOS 14+). This builds the
complete SpotifyLyrics module, then runs `SpotifyLyricsTests` using
`@testable import SpotifyLyrics`. Individual tests no longer maintain source
file lists or fake app/settings/playback classes.

The shared scheme launches a minimal AppKit XCTest host instead of starting
the product. It uses a temporary database, provenance/home and private defaults
suite, disables Keychain, and does not connect to a player. Repository tests
create their own temporary SQLite files. No network calls are made by tests;
provider network responses are deterministic test fixtures.

Existing entrypoints remain compatible and select the matching target classes:

| Legacy entrypoint | Native coverage |
| --- | --- |
| lyrics_editor | LyricsEditorContractTests |
| library_revisions | LibraryRevisionsContractTests |
| library_identity_search | LibraryIdentitySearchContractTests |
| listening_history / listening_statistics | corresponding ContractTests |
| floating_lyrics | FloatingLyricsPresentationTests + source connections |
| experience_library | ExperienceLibraryPresentationTests + source connections |
| o1_scoped_lyrics_offset | ScopedLyricsOffsetPresentationTests + ScopedLyricsOffsetRepositoryTests + source connections |
| settings_route / menu_bar_lyrics_toggle | real MenuBarPresentationTests + source connections |
| song_search | SongSearchContractTests + SearchModelsContractTests + ProviderFailureContractTests + source connections |
| v3_toolbar_model / v3_inspector_navigation | V3ToolbarPresentationTests + source connections |

Toolbar behavior assertions stay at the agreed canonical path
`Tests/v3_toolbar_model_contract.swift`; rules remain in `docs/TOOLBAR_BEHAVIOR.md`.
The inspector Python entrypoint now runs these tests rather than compiling a
second copy of the production model. Phase-1 UI checks use system grep.

Migrated standalone `@main` sources and the settings-host fake types were
removed after their behavior was moved into XCTest. They were duplicate
runners, not deleted product behavior. Settings tests verify the real controller's
callback, repeated open and reopen with a native window; SwiftUI Settings scene
presentation and physical mouse interaction remain native UI acceptance tasks.
Historical source markers are checked against current production integration;
the idle menu title and repeated offset reset expectations follow their current
production contracts. The original O1 SQLite/version/editor integration checks
are retained alongside store/binder checks.

CI builds and runs the entire target on pull requests, main and release tags,
in addition to the existing five supplemental source/logic checks. Its final
step fails if either native tests or supplemental checks fail. A release must
use a commit with this job green; running a small selection is not a release gate.
New behavior tests belong in this target. Register source membership in the
manually maintained project; do not regenerate it with generate_xcodeproj.py.

Desktop playback event tests keep five scenarios: song changes, pause/resume,
hide/show, player exit, and an old poll completing after a new notification.
Provider position/asset unit checks remain separate. Resource sampling is not
in the native target or CI; use `Scripts/measure-playback-resources.py --pid PID
--output /tmp/lyricsq-sample.json` manually. It reads the already running
process without launching an app or controlling a player. See
`docs/BACKEND_TESTING_SYNC.md` for measurement boundaries and historical results.
