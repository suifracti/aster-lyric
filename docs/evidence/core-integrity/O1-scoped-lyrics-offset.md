# O1 — Scoped Lyrics Offset

- `batch_id`: `O1`
- `result`: `AUTOMATED_VERIFIED`
- `base_head`: S1 final `6211bed5c2e31fa0325be00e5a2415d8563f0f25`
- `checkpoint_head`: `f228808` (`chore: checkpoint O1 scoped lyrics offset baseline`)
- `branch`: `codex/o1-scoped-lyrics-offset`
- `source_worktree`: `/private/tmp/spotifylyrics-o1-scoped-lyrics-offset`
- `initial_production_commit`: `dd55087502f3aa5e767f79ed9595e0f0eff9cd5d` (`fix: scope lyrics offsets by saved version`)
- `review_fix_commit`: `69c922b37331bf42be7b00494d9ba2f0f5dda3f7` (`fix: sync editor offset input on scope changes`)
- `latest_production_commit`: `69c922b37331bf42be7b00494d9ba2f0f5dda3f7`
- `human verification`: `USER_VERIFICATION_REQUIRED / NOT_RUN`

## Base and source identity

- The source began at the supplied S1 final HEAD, not the formal-root H1 checkout. H1 `449df0a...`, T1 `2963f71...`, T2 `40cc1b5...`, and S1 `e566bbf...` were confirmed in the ancestor chain.
- S1 worktree `/private/tmp/spotifylyrics-s1-durable-manual-adoption` was clean at `6211bed5c2e31fa0325be00e5a2415d8563f0f25`; its upstream matched. A fresh fetch also confirmed that remote source identity.
- A pushed, reversible O1 checkpoint is the branch parent. The formal root's old H1 checkout and its three pre-existing untracked `PROJECT_FULL_AUDIT_*.md` files were not touched or staged.
- Production behavior and contracts below were tested from that checkpoint plus the O1 source/test changes. The editor input synchronization follow-up is isolated in `69c922b`; this evidence document is committed in a later documentation commit.

## Identity and data flow

| Context | Persistent identity source | Offset behavior |
| --- | --- | --- |
| Live lyrics | `TrackIdentity.stableKey` plus `LyricsSessionController.activeLyricsVersionID`, accepted only when the session identity matches the live track | PlaybackState asks the repository to validate ownership and resolve the track redirect before activating a pair. Until identity is confirmed, the active scope is cleared and reads as zero. |
| Saved-version preview in the editor | The editor's current `TrackIdentity.stableKey` plus the selected loaded record's version UUID | The repository validates ownership and resolves redirects asynchronously; a raw historical key retained on a version record is never used as the pair key. Dirty, stale, new, or unresolved editor state disables writes with an explanation. |
| Unsaved draft | No persistent version identity | No scope is created and offset writes are disabled. There is no fallback to the old global value. |
| Search preview / no-selection / mock preview | Separate preview session or no saved version identity | Cannot activate a live persisted offset scope. |

`TrackIdentity.stableKey` remains the source identity. `SQLiteLyricsRepository.canonicalStableKeyForSavedLyricsVersion` applies the existing redirect resolver and returns a canonical key only if the persisted version belongs to that identity family. It is a read-only `SELECT`; unknown IDs, another track's version, and repositories that cannot validate saved ownership fail closed. The live binder and editor resolver both use this boundary. This matters for editor lists: the existing redirect-family query can return a version row whose stored `trackStableKey` is a historical alias. The editor therefore does not use that raw record field as the offset key. The pair key is the canonical track key plus the persisted lyrics-version UUID. No title, artist text, window ID, display projection, content hash, or array index participates.

`PlaybackState` clears the active pair as soon as the live track changes or a session publishes a different/empty version ID. Asynchronous resolution is generation-guarded; a late result for an older request cannot reactivate an old pair. Session changes after a stored load, explicit version selection, and manual adoption all flow through `activeLyricsVersionID`. A new pair starts at zero; selecting an existing pair reads its stored value.

## Consumer inventory

| Consumer | Shared scope source |
| --- | --- |
| Main V3 offset popover and reset | `AppSettingsStore.lyricsOffsetStore` active pair |
| Fullscreen | Reuses the V3 presentation implementation |
| Floating desktop offset control | The same `ScopedLyricsOffsetStore` instance |
| Settings offset control | The same active pair and shared control |
| Editor saved-version control | Same store, with the editor's selected saved pair supplied explicitly |
| Lyrics clock / line highlight / automatic scroll | `PlaybackState.presentationClock` reads the active pair; the existing C1 presentation clock remains the only time projection |
| Capsule | Uses `PlaybackState.liveCurrentLineIndex`; no separate offset store |

The old key `lyrics.presentationOffset.v1` remains in UserDefaults exactly as found. `AppSettingsStore` exposes it only to the short “unassigned historical setting” notice; it is not copied, broadcast, sign-flipped, removed, or written by O1. Scoped values live under `lyrics.presentationOffset.scoped.v1.*`. A new scoped namespace had no earlier migration values, so no ambiguous legacy per-pair identities were assigned. The real user's defaults and library were not opened.

## Change set

- `SpotifyLyrics/Settings/ScopedLyricsOffsetStore.swift` — pair type, shared UserDefaults store, pair reset, fail-closed async binding and stale-request guard.
- `SpotifyLyrics/Persistence/LyricsRepository.swift`, `SpotifyLyrics/Persistence/LyricsEditingRepository.swift`, and `SpotifyLyrics/Persistence/SQLiteLyricsRepository.swift` — saved-version ownership validation through the repository boundary and existing redirect resolver.
- `SpotifyLyrics/Services/PlaybackState.swift` — binds only the live selected persistent version and projects the active pair into the presentation clock.
- `SpotifyLyrics/Services/LyricsEditorSessionController.swift` — asynchronously resolves the selected saved version's canonical pair and exposes it only when clean, current, and repository-validated.
- `SpotifyLyrics/Settings/AppSettingsStore.swift` — shared scoped store; old global key retained read-only for the history note.
- `SpotifyLyrics/Views/Components/LyricsPreferencesPopover.swift`, `SpotifyLyrics/Views/Editor/LyricsEditorWindowView.swift`, `SpotifyLyrics/Views/MainWindow/AppleMusicImmersiveV3WindowView.swift` — shared live/editor control and pair-local reset.
- `LyricsPreferencesPopover.swift` also synchronizes the numeric editor input when its explicit saved-version scope resolves or changes, avoiding a stale initial `0.00` overwriting an existing value.
- `SpotifyLyrics.xcodeproj/project.pbxproj` — registers the new source file.
- `Tests/o1_scoped_lyrics_offset_contract.sh` and `.swift` — temporary defaults and SQLite contract using the production store, SQLite repository resolver, lyrics session, editor session, and presentation clock.
- Updated `Tests/b0_clock_offset_truth_contract.sh` and `Tests/c1_offset_semantics_contract.sh`; added the production store source to the fixed source lists in the H1/T1/T2 regression runners so those existing contracts still compile the editor controller after its new type reference.

No schema, timing payload, lyric timestamp, seek, global matching, selection policy, or provider behavior was changed.

## Acceptance matrix

| Case | Result |
| --- | --- |
| A/v1 `+0.75`, A/v2 `-0.50`, B/v1 `+1.25` | Independent values survive switching among all three pairs. |
| New B/v2 version | Defaults to zero and is written under its own version UUID; no parent value is inherited. |
| Pair reset | Reset A/v1 leaves A/v2 and B/v2 unchanged; resetting active B/v1 leaves the other pairs unchanged. |
| Reopened defaults store + reopened SQLite repository/session | A/v2 is selected again and its `-0.50` scoped offset is restored. |
| Unknown version / absent identity | Scope stays `nil`, presentation offset stays zero, and writes are refused. |
| Wrong track/version ownership | Repository returns no canonical scope. |
| Existing track redirect | Historical alias and canonical track resolve to the same A/v1 pair. |
| Redirect-family version in editor | A version row stored with the historical alias key resolves to canonical A + its own UUID; the raw alias never creates a second pair. |
| Late A identity result after request for B | Binding generation rejects the late A result; B/v1 and `+1.25` remain active. |
| Editor B/v2 while live A/v1 | The editor writes `-1.75` to B/v2 and leaves live A/v1 unchanged. A dirty editor draft loses its persistent target and explains why writes are disabled. |
| Active clock while paused | Scoped `-0.50` changes presentation time from 42.0 to 41.5 while raw playback time and authoritative anchor remain 42.0. |
| C1 bounds and direction | Scoped store clamps to `[-10,+10]`; non-finite input normalizes to zero. `+` advances lyric presentation; raw clock and seek path remain playback-domain. |
| Old global key | Isolated suite retained its original numeric value `1.375` across scoped writes and resets; it was not applied to any pair. |
| SQLite writes caused by offset storage | A read-only second connection's `PRAGMA data_version` was equal before and after the scoped UserDefaults write. The canonical ownership resolver executes `SELECT` only. |

The contract uses a real temporary SQLite repository and real `LyricsSessionController`; its delayed resolver adds only a delay and delegates validation to the production repository method. Window wiring is additionally source-checked. The contract does not instantiate the complete AppKit/SwiftUI `PlaybackState` host or call a real player; those remain outside automatic verification.

## Before / after behavior

At baseline the presentation clock and every offset control read/write one `AppSettingsStore.lyricsPresentationOffset`. Therefore A/v1, A/v2 and B/v1 necessarily shared one value; changing or resetting it affected every song/version, and an unresolved preview/live identity could still show the global number. This is confirmed by the pre-change source/dataflow and baseline diff, not by launching the previous app against a real user's defaults.

After O1, live scopes are created only after the persisted version is confirmed against the canonical redirect family. New/unknown identities read as zero, each pair has its own UserDefaults entry, editor writes target its selected saved pair, and the old one-number global preference remains unassigned history. The live presentation clock reads only the active scoped value.

The added redirect-family editor fixture first failed against the O1 implementation before the correction: a saved version with the historical alias in `record.trackStableKey` exposed that alias as its offset scope instead of canonical A. O1 now resolves the selected editor version through the same production repository ownership/redirect boundary; the test passes only when the editor scope equals canonical A plus that version UUID.

## Commands and results

All database contracts used temporary directories/databases. Debug database safety logs reported `formal_database_opened=NO` for the O1, T1, T2 and S1 contracts.

| Command | Exit | Result |
| --- | ---: | --- |
| `bash Tests/o1_scoped_lyrics_offset_contract.sh` | 0 | Pair isolation, redirect, ownership mismatch, unknown version, reopen, editor/live separation, late callback, reset, legacy preservation, clock and database-version checks passed. |
| `bash Tests/c1_offset_semantics_contract.sh` | 0 | C1 direction / presentation subscriber / no seek source contract passed. |
| `python3 Tests/c1_preview_seek_contract.py` | 0 | Cross-identity preview seek blocked; same live identity remains allowed. |
| `bash Tests/presentation_clock_contract.sh` | 0 | 14 presentation / raw playback clock cases passed. |
| `bash Tests/b0_clock_offset_truth_contract.sh` | 0 | Isolated raw/elapsed/offset/clamp, paused publisher ordering, shared routing and no-seek source assertions passed. |
| `bash Tests/lyrics_presentation_offset_contract.sh` | 0 | Shared offset control contract passed. |
| `bash Tests/h1_hash_domain_boundary_contract.sh` | 0 | H1 hash boundary regression passed. |
| `bash Tests/t1_read_projection_fidelity_contract.sh all` | 0 | T1 partial mask, projection, locked reading and metadata regression passed. |
| `bash Tests/t2_lossless_editing_timing_contract.sh all` | 0 | T2 editor/library timing, loss-confirmation, rollback and translation regression passed. |
| `bash Tests/s1_durable_manual_adoption_contract.sh all` | 0 | S1 low-confidence, locking, transaction and stale-result regressions passed. |
| `bash Tests/lyrics_version_switch_contract.sh` | 0 | Persisted version switching passed. |
| `bash Tests/sqlite_session_contract.sh` | 0 | SQLite session regression passed. |
| `xcodebuild -project SpotifyLyrics.xcodeproj -scheme SpotifyLyrics -configuration Debug -derivedDataPath /tmp/spotifylyrics-o1-debug CODE_SIGNING_ALLOWED=NO build` | 0 | Debug build succeeded. No warning was emitted from O1-changed files. Existing Swift concurrency warnings remain in `WindowManager.swift` (actor-isolated values used by a Sendable closure) and `WhisperCLISpeechEngine.swift` (`FileManager` in a Sendable struct); other pre-existing deprecation/unused-variable warnings were also present. Xcode also reported ambiguous matching macOS destinations and skipped AppIntents metadata because the target does not depend on AppIntents. |
| `git diff --check` | 0 | No whitespace errors. |

## Planner review follow-up

The first targeted Planner review found one Necessary Relevant issue: if the editor offset popover opened while repository validation was still resolving the selected saved version, the control was disabled with `0.00` in its text field. When the scope became writable, that text could remain stale; pressing Enter could write zero over an existing nonzero pair value. The editor scope is supplied asynchronously by `LyricsEditorSessionController`, while the prior text-field synchronization listened only to the shared live store's active offset/scope/revision.

The fix in `69c922b` adds an `onChange` listener for the control's explicit scope and a focused source contract assertion. The field now reads the resolved pair's stored value before the control becomes writable; unresolved scopes remain disabled. Planner reviewed this exact change and concluded the finding was resolved, with no remaining Blocker or necessary Relevant finding. Planner did not run tests or modify files.

After the fix, these focused checks were rerun and passed: `bash Tests/o1_scoped_lyrics_offset_contract.sh` (0), `bash Tests/c1_offset_semantics_contract.sh` (0), `python3 Tests/c1_preview_seek_contract.py` (0), `bash Tests/b0_clock_offset_truth_contract.sh` (0), `bash Tests/lyrics_presentation_offset_contract.sh` (0), and the Debug build (0). The rebuild emitted the pre-existing `WhisperCLISpeechEngine.swift` FileManager/Sendable warning and Xcode's ambiguous macOS destination warning; O1 changed files emitted no warnings. The O1 contract now source-checks the scope-change listener and exercises a nonzero saved pair through the production store, but it does not instantiate the SwiftUI/AppKit popover; real editor interaction remains part of human verification.

The redirect-family editor fixture's first O1 run exited 133 on the real product assertion described above; the correction was followed by a passing O1 rerun. The first H1 runner attempt after adding the editor's scope property exited 1 because that runner's fixed Swift source list omitted `ScopedLyricsOffsetStore.swift`. The same source-list drift affected T1/T2 by construction; the new source was added to only those three focused runner lists, without changing their assertions. The contracts then passed. Earlier O1 test setup attempts also exposed harness assumptions: `automaticallySearch: false` intentionally skips repository loading, and an unknown UUID must be asserted as unknown rather than awaited as a saved version. The fixture was corrected to use the normal production session load and to test unknown-version rejection directly. No failing product assertion was removed or weakened.

## Human verification and limits

- Not run: adjust A/v1, switch to A/v2 and B, restart, and confirm each scope returns.
- Not run: compare main, fullscreen and desktop windows on the running app.
- Not run: visually confirm the editor labels the selected saved version and disables writes for a dirty draft.
- Not run: real-player progress while changing a paused/playing pair.
- These remain `USER_VERIFICATION_REQUIRED / NOT_RUN`. No formal database, real player, recording, AI, credentials, or network-backed provider was used.

## Rollback impact and handoff

Rollback should revert the O1 production commit while keeping the reversible checkpoint and the O1 evidence history. Keep any `lyrics.presentationOffset.scoped.v1.*` values in UserDefaults. Older code may read the preserved global `lyrics.presentationOffset.v1` again and restore the former cross-song/version behavior; therefore rollback has a user-visible semantic effect and is not impact-free. Do not claim that scoped values are erased or that old behavior is neutral.

No schema migration or data deletion is required. Planner's targeted review is complete; this branch stops before R1 for a separate batch. No merge, tag, or release was created.
