# S1 — Durable Manual Adoption

- `batch_id`: `S1`
- `result`: `AUTOMATED_VERIFIED / USER_VERIFICATION_REQUIRED / NOT_RUN`
- `base_head`: T2 final `a427ea65b645931fe2d6fd94dcff5f463b4b1952` (H1, T1 and T2 are ancestors)
- `checkpoint`: `bee7ad106bfee7bfdc2ff96ba536b669cb53a41a` (pushed before edits)
- `branch`: `codex/s1-durable-manual-adoption`
- `production_commit`: `e566bbf51d1389e0279f0ba0412fa344bb449ac2`
- `source_diff_sha256` (T2 final → production commit): `117fa2f5a9d35d9ca335542b490263fc174b667f0d11683d72f6d4f90060de2f`
- `test_identity`:
  - `Tests/s1_durable_manual_adoption_contract.sh`: `a305d588d5dc306e27d36bade8088fde20e71e4c9f64308ec661104d9f112410`
  - `Tests/s1_durable_manual_adoption_contract.swift`: `14d0e3bf8ca71ef6f3822044f32f1b876725b6a79f9141e214f59785d45e5faf`
- `upstream`: `origin/codex/s1-durable-manual-adoption`
- `human verification`: low-confidence manual adoption after restart remains `USER_VERIFICATION_REQUIRED / NOT_RUN`
- `planner review`: complete; no Blocker / necessary Relevant findings
- `next`: stop before O1

## Scope and call path

The candidate preview and manual adoption action are separate. Preview remains local to the candidate UI. Both candidate-sheet adoption and Song Search “apply to current song” capture the target `Track`, `TrackIdentity`, source document and request ID, then call the session's explicit manual path. The session publishes the new current document only after the repository returns a committed version ID and canonical source hash.

SQLite manual adoption validates identity, nonempty content and the original finite confidence in the 0...1 range. Spotify IDs are canonicalized; a Spotify ID or ISRC is rejected when it conflicts with the corresponding claim on the target identity. It deliberately bypasses only the automatic confidence threshold. The automatic `save` path and `LyricsMatcher.isHighConfidence` policy are unchanged. Provider, provider record ID, source, confidence and candidate claims are not rewritten as `manualImport` or confidence 1.

The SQLite transaction checks the current request and lock set, writes any new lyrics asset and compatible timing attachment, and updates `is_preferred` together. A lock conflict returns without writes. Confirmed lock IDs are compared with a fresh lock query inside the transaction; newly locked versions cause a new conflict. The transaction changes preferred selection but leaves old `is_locked` values intact.

## Baseline counterexamples (before production edits)

The initial focused harness exercised the T2 production session and repository paths using `bash Tests/s1_durable_manual_adoption_contract.sh all`; the pre-fix run exited `1` and recorded these results:

```text
baseline low-confidence source=lyricsOVH score=0 immediateCurrent=true persisted=nil status=nil
FAIL: explicit adoption for lyricsOVH confidence 0.0 was not durable
baseline low-confidence source=kugouExperimental score=0.5 immediateCurrent=true persisted=nil status=nil
FAIL: explicit adoption for kugouExperimental confidence 0.5 was not durable
baseline locked current=<old-id> restored=<old-id> live=nil
FAIL: locked conflict published candidate as current
baseline thrown save live=<candidate text> persisted=nil error=<injected S1 insert failure>
FAIL: failed persistence was still published as active document
```

The early test runner omitted `DebugDatabaseSafety.swift`, required by the repository's `#if DEBUG` compilation path. The runner was minimally corrected to compile that production source. This runner source-list drift is separate from the product failures above; the runner correction is included in the final contract script. No production behavior was counted as passing on the runner compile error.

## Post-fix result matrix

| Scenario | Production-path result |
|---|---|
| lyrics.ovh-style confidence `0.0` | Automatic `save` rejects and writes zero versions. Explicit adopt inserts the original source/confidence, persists preferred ID, and a new repository and session after reopen restore the same version. |
| Kugou-style confidence `0.5` | Same result; automatic low-confidence gate remains in force. Original source, provider ID and confidence survive the reopen. |
| Real timing candidate | Three spans over repeated `A🙂A` survive reopen with their times, text, UTF-16 ranges, performer `v1`, language `ja`, and attachment identity. |
| Repeated adoption / duplicate asset | Reuses the existing lyrics version and exact matching timing attachment identity. |
| Timed child copy | A copy carrying its parent's attachment ID gets a distinct timing attachment owned by the child lyrics version; parent attachment ownership is unchanged, spans still match, and the session publishes the child attachment ID returned by the transaction. |
| Existing locked current | First attempt returns `.lockedConflict`; candidate rows and current selection are unchanged. Cancel leaves the old choice intact. If another version is locked after the prompt, commit returns a fresh conflict. Explicit confirmation then selects the candidate while retaining both original lock flags. |
| Repository `.rejected` / `.skippedLocked` | A failure-response adapter substitutes only the repository result; the production session keeps the old current document and version. SQLite remains at one old version. Invalid identity, a mismatched independent Spotify ID claim and blank content are also rejected by production repository validation with no rows. |
| Preferred update failure | A temporary SQLite trigger aborts the `is_preferred` write. The production transaction propagates the error, rolls back candidate rows, and preserves the previous database and session selection. |
| Timing attachment failure | A temporary SQLite trigger aborts timing attachment insertion. The production transaction propagates the error, rolls back candidate rows, and preserves the previous selection. |
| A → B late completion | An I/O gate delays a manual repository call, then delegates to production SQLite. The confirmed A save completes under A; B's live identity, document and current version remain untouched. |
| Same-song overlapping requests | A newer same-identity request replaces the request token and commits. When the old delayed call resumes, production SQLite rejects it; the older candidate cannot reverse the new selected version. |

“Current” is read from the persisted active lyrics version ID; an unpersisted preview no longer satisfies the current-selection predicate. Candidate recommendation display still uses its existing recommendation confidence policy. Lock confirmation is explicit and cancelable; duplicate clicks during a save are disabled in the UI.

## Transaction and isolation evidence

The two injected SQLite failures—timing attachment insertion and preferred-selection update—escape the session as errors. Direct readback after each failure shows one original version, the original preferred ID, and no candidate asset. Rejected/skipped responses likewise leave the prior persistent selection and live session state unchanged. Lock-conflict and cancellation assertions compare version counts and the selected version before and after; neither path writes.

The S1 test contract creates every database and provenance directory under a unique `FileManager.default.temporaryDirectory` root and removes it after each scenario. Debug-safety output for the runs reports `temporary_copy=YES` and `formal_database_opened=NO`. The deferred repository wrapper only gates external call timing or injects a specified failure result; all successful persistence, validation, lock checking, selection and transaction logic runs through production `SQLiteLyricsRepository` and `LyricsSessionController`.

## Changed files

Production commit `e566bbf51d1389e0279f0ba0412fa344bb449ac2` contains:

- `SpotifyLyrics/Lyrics/LyricsModels.swift`
- `SpotifyLyrics/Persistence/LyricsRepository.swift`
- `SpotifyLyrics/Persistence/SQLiteLyricsRepository.swift`
- `SpotifyLyrics/Services/LyricsSessionController.swift`
- `SpotifyLyrics/Services/PlaybackState.swift`
- `SpotifyLyrics/Views/Components/LyricsCanvasView.swift`
- `SpotifyLyrics/Views/Components/SongSearchPopover.swift`
- `Tests/s1_durable_manual_adoption_contract.sh`
- `Tests/s1_durable_manual_adoption_contract.swift`

No schema migration, confidence threshold change, source relabeling, preference/lock policy change, timing fabrication or database write during preview was introduced.

## Commands and results

All commands below were run from the isolated S1 worktree. Each listed command exited `0`:

```text
bash Tests/s1_durable_manual_adoption_contract.sh all
bash Tests/h1_hash_domain_boundary_contract.sh
bash Tests/t1_read_projection_fidelity_contract.sh
bash Tests/t2_lossless_editing_timing_contract.sh all
bash Tests/sqlite_session_contract.sh
bash Tests/lyrics_ovh_provider_contract.sh
git diff --check
git diff --cached --check
```

The required Debug build exited `0`:

```text
xcodebuild -project SpotifyLyrics.xcodeproj -scheme SpotifyLyrics -configuration Debug -derivedDataPath /tmp/spotifylyrics-s1-deriveddata CODE_SIGNING_ALLOWED=NO build
```

That build log includes the existing Swift 6 warning in `Capture/WhisperCLISpeechEngine.swift` (`FileManager` is stored in a `Sendable` struct) and the standard AppIntents metadata-skipped warning because the target has no AppIntents dependency. No warning was emitted from an S1-changed source file. T2 evidence separately records previously observed unrelated warning sites; no warning was treated as a test pass.

H1, T1 and T2 focused regressions, SQLite session and lyrics.ovh provider contracts all passed. Full-suite tests were not run.

Planner completed a targeted read-only review of `a427ea6..e566bbf`; no Blocker / necessary Relevant finding remained. The reviewer did not edit files or rerun tests.

## Not run and human acceptance

- No formal user database, real player, recording, AI, credentials, production app session or full test suite was opened or used. `generate_xcodeproj.py` was not run.
- Native UI interaction was compile-verified but not automated in a real AppKit/SwiftUI session.
- Human check remains `USER_VERIFICATION_REQUIRED / NOT_RUN`: adopt a real confidence-0 or confidence-0.5 candidate, restart the application, and verify the same candidate remains current. This report does not claim that experience check occurred.
- O1 was not started.

## Rollback and next batch

The pushed reversible checkpoint is `bee7ad106bfee7bfdc2ff96ba536b669cb53a41a`. Reverting production commit `e566bbf51d1389e0279f0ba0412fa344bb449ac2` removes S1 code and its focused contract while retaining the checkpoint and all H1/T1/T2 ancestry. The evidence/status follow-up is a separate documentation-only commit. No history rewrite is needed.

Stop before O1. After the targeted Planner review, O1 may be planned as a separate batch; do not expand this S1 change into offset or matcher redesign.
