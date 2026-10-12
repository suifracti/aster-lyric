# H1 — Lyrics Content Identity Boundary

- `batch_id`: `H1`
- `base_head`: `87eade3314a595f06adeec7a0a8029790f44756e`
- `branch`: `codex/h1-hash-domain-boundary`
- `checkpoint`: `origin/codex/h1-hash-domain-boundary @ 87eade3314a595f06adeec7a0a8029790f44756e`
- `validated_production_commit`: `449df0a6446dd01f250ff84eec34ff87efccf70d`
- `result`: `H1_AUTOMATED_VERIFIED / USER_VERIFICATION_REQUIRED / NOT_RUN`
- `human provider-switch save`: `USER_VERIFICATION_REQUIRED / NOT_RUN`
- `next candidate`: `T1` (not started)

## Starting state and scope

The formal project root was `/Users/apple/backup/sptifylyrics`. The actual
starting source was the local `main` required by the H1 contract, not the
older remote or the v0.1.2 release commit:

```text
branch: main
HEAD: 87eade3314a595f06adeec7a0a8029790f44756e
main vs origin/main: ahead 6
tracked diff: empty
staged diff: empty
untracked at start:
  PROJECT_FULL_AUDIT_2026-09-22.md
  PROJECT_FULL_AUDIT_ASTRA_2026-09-22.md
  PROJECT_FULL_AUDIT_GROK47_2026-09-22.md
```

That HEAD contains the completed local C1 and A0 work. Before production
edits, a zero-diff checkpoint branch was created from it and pushed as
`origin/codex/h1-hash-domain-boundary`.

The three audit reports were preserved, never overwritten, staged, or
committed. H1 did not open the user database, launch the formal app or a real
player, record audio, call AI, read credentials, migrate a schema, recalculate
historical hashes, or enter T1/T2/S1/O1/R1.

## Two hash domains

| value | producer and exact input boundary | consumers / purpose | projection boundary |
|---|---|---|---|
| Lyrics version `contentHash` | `LyricsPersistenceMapper.versionRecord` → private `contentHash`; source, provider source ID, synchronized flag, line index/timing/original/kana/romaji/translation | `SQLiteLyricsRepository.findVersionID` and stored version uniqueness; provider/version deduplication | May distinguish provider/source metadata and provider-embedded layers. It is not a translation/reading/timing source identity. |
| Canonical `sourceContentHash` | `LyricsSourceContentHasher`; synchronized flag plus sorted stored `lyric_lines` index/timing/original/kana/romaji; translation deliberately excluded | translation load/save, reading load/save, timing attachment/load, alignment provenance, editor compare-and-save | Must be computed from stored canonical rows. It must not be reverse-derived from a document after translation, locked reading, fine timing, or display conversion is projected. |

`SQLiteLyricsRepository.loadEditableVersion(s)` reads canonical
`DatabaseLyricLineRecord` rows first. It then may apply a compatible
`lyrics_timing_versions` payload and locked `lyric_reading_layers` to the
returned display/edit document. The stored lines therefore remain the correct
identity source even when the returned document carries auxiliary layers.

The fixed provider-A fixture proves the domains remain distinct and the
algorithms did not change:

```text
canonical source hash:
45e29e5816553994648ef33aa5646acdfde9f536f6132d96d4f57687f90a089e

provider/version dedup hash:
54aeeb5599664b75fd187ca8c250f4100f8ee851862f3897aa19c941d1f7fa6c
```

Saving the same provider-A document again still returns `.duplicate` and does
not add a version. The canonical hash remains the only accepted identity for
translation, reading, timing and editor compare-and-save operations.

## Pre-fix failure

`LyricsEditorSessionController.selectLyricsVersion` used
`DatabaseLyricsVersionRecord.contentHash` in three canonical-source positions:

1. filtering the preferred translation;
2. calling `loadTranslationVersions`;
3. beginning the selected editor session.

The temporary SQLite fixture saved provider A and provider B using production
mapper/repository code, saved their translations against production canonical
hashes, and opened the real editor controller on A. Before the production
change, selecting B reached the repository's unchanged mismatch guard and the
controller never completed the switch:

```text
FAIL: provider B selection did not complete
exit 133
```

This is the required real counterexample: provider B's version dedup hash was
not equal to the canonical source hash expected by
`loadTranslationVersions`. The failure was not produced by a fake hash
algorithm or a weakened save path.

The same wrong domain was present in `LyricsEditorSessionController.applySaved`
and `PlaybackState.applyLyricsEditorResult`, where a stored edit could refresh
the editor draft/live lyrics session with `record.contentHash` instead of the
canonical stored-row identity.

## Implemented repair

- `StoredEditableLyricsVersion.sourceContentHash` now exposes a read-only
  canonical identity computed from its stored `lines` and `record.isSynced`.
- Version translation preselection and loading use that canonical property.
- The selected version's `begin` call receives that canonical property.
- Editor save-result refresh uses it for the controller and replacement draft.
- PlaybackState's persisted-result adoption uses it for the live lyrics
  session, so translation/reading synchronization does not fall back into the
  dedup domain after save.
- Repository `sourceContentMismatch` guards and both existing hash algorithms
  are unchanged.
- Existing cancellation/generation checks are unchanged. A deliberately
  delayed provider-B load followed immediately by provider-A selection did
  not overwrite A when the B result arrived late.

No database schema, historical row, confidence, source label, or migration was
changed.

## Fixture and acceptance results

The H1 contract uses a new temporary database and production
`SQLiteLyricsRepository`, `LyricsPersistenceMapper`,
`LyricsSourceContentHasher`, `LyricsEditorSessionController`, translation
repository methods and manual edit save path.

| case | evidence | result |
|---|---|---|
| initial provider A open | canonical hash + translation A projected into real editor controller | PASS |
| provider A → B | B canonical identity used; translation B selected | PASS |
| provider A → B → A | translation A restored; no cross-version projection | PASS |
| manual version selection | manual translation and locked legacy reading layer retained | PASS |
| provider B timing layer | stored timing version ID and real timed spans remain attached after switches | PASS |
| provider A reading version | canonical-hash lookup still returns the locked reading version after switches | PASS |
| correct provider identity save | real controller save creates the revision and its translation reloads by canonical hash | PASS |
| post-save continued identity | controller and draft hold the saved version's canonical stored-row hash | PASS |
| wrong identity save | provider dedup hash passed as `sourceContentHash` throws `sourceContentMismatch` | PASS |
| rejected-write count | lyrics version count unchanged after the rejected request | PASS |
| delayed async result | delayed B cannot replace the later A selection | PASS |
| hash constants / dedup | both fixed SHA-256 values unchanged; duplicate provider save remains duplicate | PASS |

The only fake is a delay-only `LyricsEditingRepository` wrapper for the final
race case and a no-op settings singleton needed by the focused executable.
All identity calculation, SQLite reads/writes, mismatch checks, translation
binding and editor save behavior use production implementations.

## Files changed

Production:

- `SpotifyLyrics/Persistence/LyricsEditingRepository.swift`
- `SpotifyLyrics/Services/LyricsEditorSessionController.swift`
- `SpotifyLyrics/Services/PlaybackState.swift`

Direct H1 contract:

- `Tests/h1_hash_domain_boundary_contract.swift`
- `Tests/h1_hash_domain_boundary_contract.sh`

Evidence/status:

- `docs/evidence/core-integrity/H1-hash-domain-boundary.md`
- `docs/STATUS.md`

## Commands and exit codes

All commands were run from `/Users/apple/backup/sptifylyrics`.

| command | exit | identity / purpose |
|---|---:|---|
| pre-fix `bash Tests/h1_hash_domain_boundary_contract.sh` | `133` | expected RED: real provider B selection could not pass canonical hash validation |
| post-fix `bash Tests/h1_hash_domain_boundary_contract.sh` | `0` | real temporary SQLite + production mapper/repository/controller/save path; fixed hashes, A→B→A, manual, translation, reading, timing, mismatch/no-write and late result |
| `bash Tests/phase_2_6a_persistence_contract.sh` | `0` | existing reading persistence and stale-hash rejection |
| `bash Tests/timing_persistence_immutable_contract.sh` | `0` | existing timing source hash, immutable append and mismatch rejection |
| `bash Tests/lyrics_version_switch_contract.sh` | `0` | existing provider/manual version selection persistence |
| `bash Tests/sqlite_persistence_contract.sh` | `0` | existing provider content deduplication |
| `bash Tests/library_revisions_contract.sh` | `0` | existing canonical edit save/revision/selection path |
| `bash Tests/lyrics_editor_contract.sh` | `0` | editor draft/timeline/import model contracts |
| `bash Tests/phase_2_5c_contract.sh` | `0` | translation workflow/session behavior |
| `git diff --check` | `0` | whitespace verification before production commit |
| `xcodebuild -project SpotifyLyrics.xcodeproj -scheme SpotifyLyrics -configuration Debug -derivedDataPath /tmp/lyrics-h1-hash-domain-deriveddata CODE_SIGNING_ALLOWED=NO build` | `0` | required production Debug build; `BUILD SUCCEEDED` |

The initial H1 test source mistakenly asserted `timedSpans` on
`LyricsEditorLineDraft`, which intentionally does not expose that T1/T2 field;
that compile error was corrected before the behavioral RED run. Timing was
verified at the repository projection boundary instead.

## Existing runner drift / not counted as H1 failure

The following extra legacy runners were attempted but did not reach their
product assertions:

- `Tests/sqlite_editing_contract.sh`,
  `Tests/translation_persistence_contract.sh`, and
  `Tests/synthetic_text_lyrics_e2e_contract.sh` omit the now-required
  `ListeningHistoryModels.swift` / `ListeningStatisticsModels.swift` files
  from their standalone `swiftc` source lists.
- `Tests/translation_session_contract.sh` first requires zsh rather than bash;
  under zsh its in-memory fake is still missing the newer
  `adoptTranslation` and `archiveTranslation` protocol methods.

H1 did not modify these unrelated legacy runners. Their relevant persistence
and session behavior is exercised by the passing H1, reading, timing, library
revision and phase 2.5C contracts above. The full test suite was not run.

## Not run and human boundary

Not run:

- the formal user database or any historical-data rewrite;
- a real Spotify/Apple Music process or provider network request;
- the formal app UI, native provider-version click, or human text edit/save;
- AI, Keychain, recording, capture, release, tag, merge, or deployment work.

Therefore the human scenario “switch provider version, make a small edit, and
save” remains `USER_VERIFICATION_REQUIRED / NOT_RUN`. Automated acceptance is
not presented as human acceptance.

## Rollback and stop condition

The production/test change is isolated in commit
`449df0a6446dd01f250ff84eec34ff87efccf70d`. Reverting that commit removes the
computed DTO boundary, the three corrected consumers and the H1 contract; no
schema or data rollback is required. The evidence/status updates are separate
documentation-only commits.

H1 stops after this report. No T1 code, plan execution, merge, tag, release or
historical hash recalculation was started. The next candidate is T1 and
requires Planner direction.
