# T2 — Lossless Editing / Timing Attachment Fidelity

- `batch_id`: `T2`
- `result`: `AUTOMATED_VERIFIED / USER_VERIFICATION_REQUIRED / NOT_RUN`
- `base_head`: `f61088e6b749b2b86ab590e98f209a7f2a484981` (T1 final HEAD)
- `checkpoint`: `01b5edad25a13e359298036df039227b4c20806f` (pushed before T2 edits)
- `branch`: `codex/t2-lossless-editing-timing`
- `production_commit`: `40cc1b57fd3a20345d292a5be0f9304f9d5df06d`
- `validated_source_identity`: production commit above; source diff SHA-256 `7f296affb00d9be27e49b1ffb979f392589c4b9fd652463d1045b8a8dcdaf876`
- `test_identity`:
  - `Tests/t2_lossless_editing_timing_contract.sh`: `f640e8e4a79efa38578fb2ea402ff0e63bf4f85c2b09d2af0095325432535970`
  - `Tests/t2_lossless_editing_timing_contract.swift`: `9b389872779692767e192a714175e02bfc6463c50897ce77ba74ce2e3e7471be`
- `upstream`: `origin/codex/t2-lossless-editing-timing`
- `Planner review`: targeted review complete; no Blocker / necessary Relevant.
- `human verification`: `USER_VERIFICATION_REQUIRED / NOT_RUN`
- `next`: stop before S1; wait for Planner handoff / human verification as scheduled.

## Scope and route findings

The repair covers the two manual new-version paths that copy an existing provider lyric:

1. provider version → repository load → editor session/draft → editor copy/save → SQLite close/reopen → selected document and renderer input;
2. provider version → repository load → library revision draft → `saveManualEdit` → SQLite close/reopen → selected document and renderer input.

Before T2, `LyricsEditorLineDraft.asLyricLine()` dropped performer and timed spans, both draft-to-document projections omitted some document timing metadata, and `documentWithoutTranslations()` reconstructed lines without performer/spans. `saveManualEdit()` then inserted a child lyric version without a timing attachment. The library revision sheet had no timing-loss confirmation. Timing payload loading/automatic arbitration checked decodability and hash/owner lookup but did not validate every span against current text and UTF-16 boundaries.

The repair keeps the existing storage schema and reading layer. It adds a shared value-level compatibility check, carries compatible timing through both projections, prompts before an edit discards timing, writes a child-owned immutable timing attachment inside the existing save transaction, and validates payloads before load or automatic word-timing promotion. Translation-only saves continue through the existing translation-version mechanism.

## Independent counterexamples

Both baseline and fixed runs used parser-produced spans and the production SQLite repository/editing/session paths. Each run used temporary directories and databases. Debug-safety output reported `temporary_copy=YES` and `formal_database_opened=NO`.

### A — TTML through editor copy

The fixture is parsed from TTML and contains three real spans over `今日🌸今日`: repeated `今日`, a flower emoji with a two-unit UTF-16 boundary, a TTML performer `v1`, language `ja`, and an additional untimed row. A locked legacy-reading row is overlaid before opening the editor.

At pre-fix checkpoint `01b5edad25a13e359298036df039227b4c20806f`, the isolated red harness used the actual editor force-copy and repository save path, released that helper scope, opened a new repository for the same SQLite file, and reported:

```text
PRE-FIX editor: draft spans 0/3, reopened spans 0/3
exit code: 1 (expected red)
```

At production commit `40cc1b57fd3a20345d292a5be0f9304f9d5df06d`, the tracked T2 contract reports three identical spans after save/reopen. The child has its own timing attachment ID, the parent attachment and spans are unchanged, the canonical child hash matches its stored source rows, the locked reading remains applied, and `TimedTextComposer` receives renderer input equal to the parent.

### B — YRC through library revision

The fixture is parsed from YRC and contains repeated text plus Unicode spans. It is deliberately unsynchronized: line 0 has an explicit valid `0` second start and real spans; line 1 is an unset placeholder whose model timestamp is also zero. The document carries language `zh-Hans` and partial mask `[0]`.

At pre-fix checkpoint `01b5edad25a13e359298036df039227b4c20806f`, the isolated red harness used `LibraryLyricsRevisionDraft` and the real `saveManualEdit` route, released that helper scope, opened a new repository for the same SQLite file, and reported:

```text
PRE-FIX library: draft spans 0/3, reopened spans 0/3
exit code: 1 (expected red)
```

At the production commit, the library child reopens with all three exact spans, mask `[0]`, explicit line 0, unset line 1, and language `zh-Hans`. Its attachment ID is new; the parent attachment and spans are unchanged; its renderer input equals the parent.

## Field facts by layer

| Field / behavior | Editor copy route | Library revision route | Reopen / persistence fact |
|---|---|---|---|
| Original text | TTML source text is copied unchanged in the lossless case | YRC source text is copied unchanged; added row is untimed | Parent remains unchanged; changed text is saved only after confirmation |
| Real spans | Three exact TTML spans reach draft and repository request | Three exact YRC spans reach revision request | Span values, text, times, UTF-16 offsets, IDs and granularity compare equal after reopen when compatible |
| Repeated text / Unicode | `今日` repeats; `🌸` exercises UTF-16 boundaries | Same repeated-text and Unicode coverage | Renderer segments compare equal to the parent after reopen |
| Row starts / ends | Child start and end values equal parent in the copy case | Partial zero start and unset placeholder remain distinct | Changed row start/end keeps only spans that still satisfy the new boundary after confirmation |
| Partial timing mask | Session draft carries current synchronization and mask fields | `[0]` survives `saveRequest()` and SQLite reload | Explicit zero remains timed; placeholder line 1 remains untimed |
| Performer / language | `v1` / `ja` survives editor projection and child attachment | Language `zh-Hans` survives | Child timing payload is loaded against the child document; no absent performer is fabricated |
| Locked reading | Existing locked layer remains active in the editor and child | No locked layer exists in this fixture | Reading projection is stored in its existing separate layer and stripped from canonical source rows before hashing |
| Attachment identity | Parent ID is unchanged; child ID is non-nil and different | Parent ID is unchanged; child ID is non-nil and different | Loader finds the child attachment only under the child lyrics-version ID and child source hash |
| Canonical source identity | Child source hash equals hash of its stored source rows | Child follows the same repository hash path | Display/locked-reading projection is not re-hashed as canonical source; H1 mismatch regression remains green |
| Translation-only edit | One translation version is added | Not applicable to this library text revision case | No lyric version or timing attachment is added; timed selected document remains unchanged |

The existing schema does not persist an explicit empty partial-mask presence bit: its mapper represents an unsynchronized version with no timed rows as `nil`. T1's focused regression retains the in-memory distinction between `nil` and an empty set across session/editor projection; T2 does not add a schema migration.

## Loss confirmation and transaction evidence

- Editor text edit: changing the first `今日` to `明日` reports one incompatible span on one line. Cancel leaves the editor open and does not change SQLite `data_version` or table counts. Confirm saves the child with the changed original text and only the two still-compatible spans; the parent text/spans remain intact.
- Library row-start edit: moving start to `1.0` reports two incompatible spans. An unconfirmed `saveRequest()` throws before any repository call; read-only `data_version` and table counts remain unchanged. Confirmation saves the compatible remainder and does not paste earlier spans onto the new line time.
- Row-end edit: shortening the row end to `0.7` reports two spans beyond that changed boundary. Confirmation preserves only the span ending at `0.4`; the child reloads with end `0.7` and that single compatible span.
- Translation only: the editor adds exactly one translation layer; lyric-version and timing-attachment counts do not change, and the selected timed lyric still reloads.
- Transaction failure: a temporary SQLite trigger aborts timing-attachment insertion after child-row insertion has begun. The original error `T2 injected attachment failure` escapes. After rollback, all measured row counts and `data_version` match their prior values and the explicitly selected parent remains selected.
- Malformed attachment: an `Int.max` UTF-16 offset payload does not load as spans and is not promoted by automatic word-timing arbitration. Explicit preferred line-only selection still wins.

## Changed files

Production commit `40cc1b57fd3a20345d292a5be0f9304f9d5df06d` contains:

- `SpotifyLyrics/Editor/LyricsEditorModels.swift`
- `SpotifyLyrics/Models/Models.swift`
- `SpotifyLyrics/Persistence/DatabaseModels.swift`
- `SpotifyLyrics/Persistence/LyricsEditingRepository.swift`
- `SpotifyLyrics/Persistence/SQLiteLyricsRepository.swift`
- `SpotifyLyrics/Services/LyricsEditorSessionController.swift`
- `SpotifyLyrics/Settings/PersonalLyricsLibraryService.swift`
- `SpotifyLyrics/Views/Editor/LyricsEditorWindowView.swift`
- `SpotifyLyrics/Views/Settings/PersonalLyricsLibraryView.swift`
- `Tests/t2_lossless_editing_timing_contract.swift`
- `Tests/t2_lossless_editing_timing_contract.sh`

The evidence report and repository/Obsidian current-stage pointers are documentation follow-up. No schema migration, old reading-schema deletion, or change to manual selection policy was made.

## Commands and results

All focused contracts ran against temporary fixtures. Each listed command exited `0` after the fix:

```text
bash Tests/t2_lossless_editing_timing_contract.sh all
bash Tests/h1_hash_domain_boundary_contract.sh
bash Tests/t1_read_projection_fidelity_contract.sh
bash Tests/library_revisions_contract.sh
bash Tests/timing_persistence_immutable_contract.sh
bash Tests/ttml_parser_contract.sh
git diff --check
git diff --cached --check
```

Both required Debug builds exited `0`:

```text
xcodebuild -project SpotifyLyrics.xcodeproj -scheme SpotifyLyrics -configuration Debug -derivedDataPath /tmp/spotifylyrics-t2-lossless-deriveddata CODE_SIGNING_ALLOWED=NO build
xcodebuild -project SpotifyLyrics.xcodeproj -scheme SpotifyLyrics -configuration Debug -derivedDataPath /tmp/spotifylyrics-t2-lossless-deriveddata-review CODE_SIGNING_ALLOWED=NO build
```

The fresh build log contains existing Swift 6 Sendable warnings in `Capture/WhisperCLISpeechEngine.swift` (`FileManager` stored in a `Sendable` struct) and `Windows/WindowManager.swift` (main-actor properties accessed from Sendable closures), plus unrelated AVFoundation/AppKit deprecation and unused-variable warnings. No warnings were emitted for the changed source files. The build also reports that AppIntents metadata extraction was skipped because the target has no AppIntents dependency.

The H1 and library shell scripts are tracked without executable permission. Their bare direct launch returned `126` (`permission denied`); invoking the same scripts with `bash` passed with exit `0`. This is a runner mode issue, not a product-contract failure. Other broad/legacy runners were not run.

## Isolation, no-write basis, and limits

- Every T2 contract database and provenance directory is created under `FileManager.default.temporaryDirectory` with a unique task-specific name and removed by the contract's `defer` cleanup.
- The contract's only stub is the external `AppSettingsStore` preference singleton. The actual parser, draft/session controller, SQLite repository, transaction, attachment, selection, and renderer-composition logic are compiled from production sources.
- Cancel paths are checked with read-only SQLite probes for both `PRAGMA data_version` and counts of tracks, lyrics versions, lyric lines, timing attachments, translation versions and reading layers. They remain unchanged.
- Attachment insertion is inside the existing child-save transaction; the injected insert error proves no child, attachment, selection update, or translation survives a failure.
- The formal database was not opened. No real player, recording, AI, credential access, project generator, full test suite, or interactive application session was run.
- Human experience checks remain `USER_VERIFICATION_REQUIRED / NOT_RUN`: make an actual untampered copy/revision of a song with real spans and restart the app; then make an incompatible text/time edit, inspect the loss explanation, cancel, and verify the saved source is unchanged.
- Planner targeted review completed with no Blocker / necessary Relevant; review did not edit files or rerun tests.

## Rollback and next batch

The reversible T2 code checkpoint is `01b5edad25a13e359298036df039227b4c20806f`; the production commit is `40cc1b57fd3a20345d292a5be0f9304f9d5df06d`. Reverting the production commit removes this batch's source and focused contract while retaining the checkpoint. The documentation follow-up is a separate revertable docs-only commit. No history rewrite is needed.

Stop at T2. S1 has not started and must be planned separately after this handoff.
