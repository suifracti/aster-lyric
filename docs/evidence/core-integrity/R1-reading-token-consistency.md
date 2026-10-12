# R1 — Reading Token Consistency

- `batch_id`: `R1`
- `result`: `AUTOMATED_VERIFIED`
- `base_head`: O1 final `c31805467ae877e67ddd14e50af6b6587f719416`
- `checkpoint_head`: `f6e33debc35017fd900029dd1a98ac79f4154b51` (`chore: checkpoint R1 reading token baseline`, pushed before implementation)
- `branch`: `codex/r1-reading-token-consistency`
- `source_worktree`: `/private/tmp/spotifylyrics-r1-reading-token-consistency`
- `initial_production_commit`: `4944a818b8c3059b5f575578eaef6194bdd8b373` (`fix: keep manual reading tokens consistent`)
- `latest_production_commit`: `bad730103632cedeb852bffec0836745879ce109` (`fix: reject inconsistent kana tokens from all sources`)
- `test_followup_commit`: `63498bc9e9a4f53474fe87577092513c1ea92f97` (`test: reopen database before reading version selection`; the generated-source rejection case is included with `bad7301`)
- `human verification`: `USER_VERIFICATION_REQUIRED / NOT_RUN`

## Base and source identity

The R1 worktree was created from the supplied O1 final source, not from the formal root's older H1 checkout. Git ancestry checks passed for H1 `449df0a6446dd01f250ff84eec34ff87efccf70d`, T1 `2963f710c85e0993963d0127514791ee6a19196f`, T2 `40cc1b57fd3a20345d292a5be0f9304f9d5df06d`, S1 `e566bbf51d1389e0279f0ba0412fa344bb449ac2`, and O1 `69c922b37331bf42be7b00494d9ba2f0f5dda3f7`. The initial production implementation is in `4944a81`; `bad7301` closes the save guard for inconsistent nonempty kana token maps from any source. Test follow-ups are `a1da539` and `63498bc`; the final reselect case calls the production `select(versionID:)` path used by the UI. The reversible checkpoint and all task commits are on the task branch. No schema migration or reading-version rewrite was made.

The formal project root remained `/Users/apple/backup/sptifylyrics` at its H1 checkout. Its three pre-existing untracked `PROJECT_FULL_AUDIT_*.md` files were not touched or staged. All test databases, defaults suites, and build products were isolated under temporary paths. Obsidian README/Handoff now point to R1; the dated `Decisions.md` workspace entry is labeled historical and defers the current phase to README/Handoff and the active user instruction.

## Paths and reading truth

| Path | Production flow | Reading truth and token rule |
| --- | --- | --- |
| Whole-line editor | `ReadingVersionEditorView` → `ReadingManualEdit.lines` → `ReadingSessionController.saveManualEdit` → SQLite save/adopt → reloaded projection | A changed `readingText` is authoritative for that edit. Since the editor has no position map, it clears tokens for that changed line; an unchanged line and an unchanged value keep the exact parent tokens. The parent version remains immutable. |
| Word-click correction | existing Japanese Ruby action → `correctRuby` / `ReadingRubyCorrection.lines` → SQLite save/adopt → song-scoped dictionary memory → projection | The existing exact-surface correction path and track scope remain in use. It persists a new version before remembering the rule; valid aligned correction tokens can drive Ruby and romaji. |

Manual save validates the lyric-version UUID and canonical source hash, cancels and waits for any in-flight generation, reconciles rows against the selected parent, then saves and adopts before publishing the new selected version. Errors are rethrown to the editor; the editor stays open with an error and does not dismiss as if the edit succeeded. Generation checks cancellation, session revision, lyric-version identity, and source hash after persistence and before adoption/publication, so an older generated result cannot replace the later manual edit.

A stored token map is displayable only when token IDs are unique, Swift `Character` ranges exactly and contiguously cover the original surface, each range spells its token surface, and the map reconstructs `readingText`. The repository rejects inconsistent nonempty token maps on every kana save, regardless of source kind; an empty map remains a legal safe fallback. On load, historical invalid maps are cleared in the returned value only; the stored `readingText` and version remain available. For a manual edit with no reliable tokens, independent kana and romaji use the saved `readingText`, and inline Ruby is absent. Generated unresolved-row fallback remains unchanged. No second tokenizer or reading generator was added.

## Before / after counterexamples

| Counterexample | Before R1 | After R1 |
| --- | --- | --- |
| Existing repeated-word user-dictionary tokens, edit only the first occurrence, save, close/reopen DB and create a new session | The production round-trip contract failed: `changed line retained old tokens after save/reopen = true`; projection could take the old token readings despite the edited whole-line value. | Contract prints `changed line retained old tokens after save/reopen = false`. The changed row reloads with new `readingText`, no stale token map, no inline Ruby from the old map, and romaji derived from the new text. The untouched repeated-word row keeps its exact user-dictionary tokens and Ruby. |
| Delayed generated save completes after a newer whole-line manual edit | The production race contract failed: the persisted current version became `generated` with `reading=あいうえお`, replacing the intended edit. | Contract prints `persisted current after delayed generation = manualEdit, reading=かきくけこ`; the manual version remains selected/current after reopen. |

These failures were captured by the focused contract against the pre-fix production path before the implementation changed. The contract then passed against the production repository, session, and projection code.

## Fixture and preservation matrix

The manual fixture uses an isolated SQLite database, a timed AMLL-source document with TTML/YRC-representative span values, duplicate `身体` tokens, the second unchanged `月と月` row, an emoji ZWJ grapheme, and a combining kana grapheme. It records source hash, provider metadata, performer, line/end times, spans and timing attachment identity before editing. Save/session work runs in a helper that returns only value fixtures; the production session and repository are released before a new repository opens the same database. The sequence includes an unchanged-value save, a partial reading change in one row, a failed wrong-source save, database close/reopen, a fresh session, malformed historical token injection, invalid range/conflicting-token rejection, and prior-version reselection through the production selector.

| Field or behavior | Changed row after save/reopen | Unchanged row / source |
| --- | --- | --- |
| `readingText` | Exact edited `からだとしんたい👩‍🎤が` survives and is the independent kana text. | `つきとつき` survives. |
| Tokens / Ruby | Changed row's stale tokens are absent; Ruby projection is `nil` when no reliable map exists. | Existing `月:つき`, particle-without-Ruby, `月:つき` mapping is retained. |
| Romaji | Equals romanization of the saved whole-line reading. | Existing valid token projection remains available. |
| No-op and partial edit | No-op keeps valid tokens. Editing only part of a line invalidates that entire row because there is no proven subrange map. | Other rows keep their exact tokens. |
| Text/range validation | Conflicting manual and generated kana text/token combinations and out-of-range Character offsets are rejected; no readable child version is left. Empty token fallback remains valid. | Emoji/combining Character boundaries validate without UTF-16/Character offset confusion. |
| Older version | New child does not overwrite the parent; the parent can be selected again and its current selection persists. | Earlier user-dictionary correction remains in its immutable version. |
| H1 / T1 / T2 source data | Source identity and source hash do not change. | Original lyrics, line/end times, spans, language, performer, provider metadata and timing attachment UUID match the pre-edit fixture. |
| Read-only load/projection | — | A separate SQLite probe observed the same `PRAGMA data_version` before and after load, version validation, new-session restoration and projection. Production load/projection added no database write. |
| Click correction | — | Existing click correction persists through reopen, projects to independent kana, inline Ruby and romaji, and remains in the song-scoped dictionary. |

The invalid historic-token fixture is deliberately seeded by direct SQL before the read-only probe. That fixture mutation represents pre-R1 stored data; the loader itself does not rewrite it.

The generated-source negative case was added with `bad7301` after review found that the earlier save guard only covered `.manualEdit`. The final contract rejects the inconsistent `.generated` payload and verifies that no version row remains. No separate pre-fix execution result for this additional case was retained, so it is reported as a regression check, not as an observed pre-fix runtime failure.

## Changed files

- `SpotifyLyrics/Lyrics/ReadingModels.swift` — Character-range and kana reconstruction validation; exact line-change token invalidation helper.
- `SpotifyLyrics/Lyrics/ReadingSessionController.swift` — manual save reconciliation, stale generation cancellation/revision guards, and source-kind-aware projection context.
- `SpotifyLyrics/Lyrics/ReadingUserDictionary.swift` — fail-closed Ruby token projection and safe kana/romaji fallback from the stored manual reading.
- `SpotifyLyrics/Persistence/SQLiteLyricsRepository.swift` — reject inconsistent nonempty kana token maps from every source on save; drop invalid legacy token maps from loaded values without rewriting rows.
- `SpotifyLyrics/Views/Components/ReadingVersionEditorView.swift` — await save; only dismiss on success; keep editor open and show failure on error.
- `Tests/r1_reading_token_consistency_contract.swift` and `.sh` — production-path manual, projection, reopen, validation, click-correction and delayed-generation contracts.
- `docs/evidence/core-integrity/R1-reading-token-consistency.md` and `docs/STATUS.md` — evidence and rolling status.

## Commands and results

All focused contracts exited `0`. Debug database logs reported temporary database paths and `formal_database_opened=NO`.

| Command | Exit | Result |
| --- | ---: | --- |
| `bash Tests/r1_reading_token_consistency_contract.sh all` | 0 | Whole-line save/reopen, no-op token retention, changed-row invalidation, repeated/Unicode surfaces, per-projection result, bad historical tokens, bad ranges, conflicting manual and generated kana maps rejected without a readable row, prior-version reselection, click correction and delayed-generation race passed. |
| `bash Tests/h1_hash_domain_boundary_contract.sh` | 0 | H1 canonical hash boundary regression passed. |
| `bash Tests/t1_read_projection_fidelity_contract.sh` | 0 | T1 partial mask, locked reading, metadata and projection regression passed. |
| `bash Tests/t2_lossless_editing_timing_contract.sh` | 0 | T2 save/reopen, attachment, partial timing, cancellation and transaction regression passed. |
| `bash Tests/s1_durable_manual_adoption_contract.sh all` | 0 | S1 candidate persistence, current selection, timing and stale-result regression passed with the broader kana save guard. |
| `bash Tests/ruby_correction_contract.sh` | 0 | Existing Ruby correction regression passed. |
| `bash Tests/japanese_reading_contract.sh` | 0 | Japanese reading generation regression passed. |
| `bash Tests/japanese_ruby_restoration_contract.sh` | 0 | Japanese Ruby restoration passed. |
| `bash Tests/ruby_timed_projection_contract.sh` | 0 | Timed Ruby projection and time independence passed. |
| `bash Tests/v3_local_ruby_priority_contract.sh` | 0 | V3 local correction priority passed. |
| `bash Tests/v3_inline_ruby_gate_contract.sh` | 0 | V3 inline Ruby gate passed. |
| `set -o pipefail; xcodebuild -project SpotifyLyrics.xcodeproj -scheme SpotifyLyrics -configuration Debug -derivedDataPath /tmp/spotifylyrics-r1-final-artifact-debug CODE_SIGNING_ALLOWED=NO -quiet build 2>&1 | tee /tmp/spotifylyrics-r1-final-artifact-debug.log | awk '/warning:|error:|BUILD SUCCEEDED|BUILD FAILED|Using the first of multiple matching destinations|Supported platforms for the buildables/'` | 0 | Required Debug build succeeded from a fresh derived-data directory after the final production guard. No warning was emitted from an R1-changed source file. Existing warnings remain in `WindowManager.swift` (actor-isolated values inside a Sendable closure), `WhisperCLISpeechEngine.swift` (`FileManager` non-Sendable under Swift 6), and pre-existing deprecations/unused variables; Xcode also reported ambiguous matching macOS destinations. |
| `git diff --check` | 0 | No whitespace errors after the final evidence/status edits and before the documentation commit. |

Early harness setup exposed two test-only issues: the explicit Swift source list initially omitted `LyricsE2ELog.swift` and `DebugDatabaseSafety.swift`, and an initial fixture expectation incorrectly asked the current projection to annotate the Japanese particle `と`. The runner source list and expected projection were corrected to include the production support sources and preserve the existing no-Ruby particle behavior. These were harness setup/expectation corrections, not product passes; the pre-fix product failures above remained asserted and the final full R1 contract passed.

## Planner review, unrun work and rollback

Planner's final targeted code review found no remaining Blocker or necessary Relevant issue after the persisted reselection contract was switched to the production selector, the fixture closes its original database-owning scope before reopen, and the all-source kana save guard was added. The final guard was reviewed with the generated-source rejection case; Planner found no Blocker or necessary Relevant issue. No full test suite was run. No V3 UI, full-screen UI, real player, microphone, AI service, provider network or formal user database was opened or exercised. The requested hands-on V3 edit, inline/independent/full-screen comparison, romaji check, restart, and confirmation that word-click correction remains usable are `USER_VERIFICATION_REQUIRED / NOT_RUN`. U1 was not started.

To roll back product behavior, revert the R1 production commits in reverse order: `bad7301` then `4944a81`; keep the reversible checkpoint and O1 ancestry. Test-only commits `a1da539` and `63498bc` can remain as evidence or be reverted separately. Revert the evidence/STATUS commit only if the R1 status itself is being withdrawn; do not rewrite history. No schema or old version rows were removed or rewritten. If the implementation is reverted, the previous editor path can again persist changed `readingText` beside old tokens, projection may show the stale reading, and inconsistent kana token payloads from other sources can again be saved. The delayed generation race guard is also lost. Reading versions written during R1 remain in SQLite and the prior immutable version remains selectable. No claim is made that rollback has no user-visible effect.

Planner's final targeted review is complete. R1's hands-on checks remain pending; U1 belongs to a future separate batch. This work stops before U1. No merge, tag or release was created.
