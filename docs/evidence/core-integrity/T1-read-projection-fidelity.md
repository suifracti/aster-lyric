# T1 — Read / Projection Fidelity

- `batch_id`: `T1`
- `result`: `AUTOMATED_VERIFIED / USER_VERIFICATION_REQUIRED / NOT_RUN`
- `base_head`: `c062cfe371a2fcab3b1569888a6da35646627f0e` (H1 final HEAD)
- `checkpoint`: `633a59b3eff9e78d34056649eef15ad773cca8ec` (pushed before T1 edits)
- `branch`: `codex/t1-read-projection-fidelity`
- `validated_production_commit`: `2963f710c85e0993963d0127514791ee6a19196f`
- `contract_followup_commits`: `0109ac3c42d0456587fefd9c3c5377b2ce989389`, `93e9b017096005b1c9919bde561dc8d10f4c38aa`, `2963f710c85e0993963d0127514791ee6a19196f`
- `validated_source_and_contract_identity`: `2963f710c85e0993963d0127514791ee6a19196f`
- `upstream`: `origin/codex/t1-read-projection-fidelity`
- `next`: Planner targeted review complete with no Blocker / necessary Relevant; T2 has not started
- `human verification`: `USER_VERIFICATION_REQUIRED / NOT_RUN`

## H1 prerequisite check

The T1 branch starts from the requested H1 final commit, not the older
`main`. I reviewed the H1 production diff and its evidence before T1 work.
H1 keeps provider/version dedup identity separate from canonical source
identity, computes `sourceContentHash` from stored lyric rows, and retains the
repository `sourceContentMismatch` guard. The H1 production chain contract was
rerun on this branch and passed. No H1 blocker or necessary H1 repair was
found.

The H1 evidence separately records legacy runner drift:
`sqlite_editing_contract.sh`, `translation_persistence_contract.sh`, and
`synthetic_text_lyrics_e2e_contract.sh` omit newer history/statistics source
files; `translation_session_contract.sh` requires zsh and its fake lacks
current protocol methods. Those old runners were not rerun for T1 and are not
counted as T1 product failures. Their broader editing/translation-session
coverage remains outside this focused batch. T1's dedicated contract compiles
and exercises the production repository, session and editor controllers for
the read/projection path in scope.

## Change summary

The source fix is confined to six production files:

- `SpotifyLyrics/Models/Models.swift`: added a line copy helper that preserves
  all current `LyricLine` fields while replacing its ID.
- `SpotifyLyrics/Lyrics/LyricsModels.swift`: added document copy helpers that
  preserve current document metadata, partial timeline mask, identity and
  timing attachment identity.
- `SpotifyLyrics/Persistence/SQLiteLyricsRepository.swift`: timing projection
  now keeps the exact selected timing version ID; locked-reading overlay
  updates only kana/romaji on the existing line values and keeps all other
  fields.
- `SpotifyLyrics/Services/LyricsSessionController.swift`: loaded-document
  enrichment preserves the document and its fields. Persisted source hashes
  are carried into the session; fresh provider results hash the input document
  before display enrichment.
- `SpotifyLyrics/Editor/LyricsEditorModels.swift`: existing editor drafts now
  carry performer, spans, reading projection fields, synchronization state,
  language, partial mask and timing version ID.
- `SpotifyLyrics/Services/LyricsEditorSessionController.swift`: line-ID,
  translation and reading projections use the fidelity-preserving copies.
  Selecting another stored translation version now changes only translation
  text on a copy of the existing draft, preserving the rest of its projection.

The editor's new-version conversion (`LyricsEditorDraft.document()` /
`LyricsEditorLineDraft.asLyricLine()`) still does not create or carry forward a
timing attachment. That save path is reserved for T2 and was not changed here.
No schema, old reading layer, historical row, or migration was changed.

The focused contract is in
`Tests/t1_read_projection_fidelity_contract.swift` and
`Tests/t1_read_projection_fidelity_contract.sh`. Contract source SHA-256:

```text
ca8c64dc3da254fded05b2ff533ae622e5036c5e9f58c35dbd92a24e812e109e  Tests/t1_read_projection_fidelity_contract.sh
86eba390d1c1297ded523064cd8201de374036a4dda6cc58c26e6058095555aa  Tests/t1_read_projection_fidelity_contract.swift
```

## Independent counterexamples

Both red runs used the same focused contract source copied into an isolated
worktree at the pre-T1 H1 source `c062cfe371a2fcab3b1569888a6da35646627f0e`.
Each runner used its own temporary SQLite fixture; the formal user database
was not opened.

### A — Partial unsynchronized timeline

The fixture contains an unsynchronized line with a meaningful start at `0`
and an end at `2`, plus an untimed placeholder row whose in-memory timestamp
is also `0`. The saved partial mask is `[0]`.

Before the fix, `bash Tests/t1_read_projection_fidelity_contract.sh partial`
exited `1`. The real session projection had `mask=nil`, `line0Explicit=false`
and `line1Explicit=false`; it lost the explicit-zero marker and could not
distinguish the placeholder.

```text
FAIL: session dropped explicit-zero/placeholder mask or canonical source identity
partial session observed mask=nil sync=false hashMatch=true line0Explicit=false line1Explicit=false
T1_PREFX_PARTIAL_EXIT=1
```

After the fix, the same command exits `0`. Repository, session and editor
preserve `isSynchronized=false`, mask `[0]`, line 0 start `0` / end `2`, and
line 1's absent editor start time. Both repository and session report line 0
explicit and line 1 not explicit. No performer, spans, old locked reading or
timing attachment is fabricated. In-memory `nil` and empty masks remain
distinct through session and draft copies; SQLite's existing mapper returns
`nil` for a stored unsynchronized version with no timed rows, so T1 does not
claim that the database distinguishes an explicit empty set from `nil`.

```text
partial session observed mask=Optional(Set([0])) sync=false hashMatch=true line0Explicit=true line1Explicit=false
T1 read/projection fidelity contract passed (partial)
```

### B — Legacy locked-reading overlay on timed lyrics

The fixture stores source text `今日🌸今日`, an end time of `4`, a compatibility
translation, language `ja`, performer `v2`, three real spans, and a locked
legacy reading layer (`こんにち` / `konnichi`). The repeated `今日` and `🌸`
exercise repeated text and UTF-16 Unicode span boundaries. A translation
version for the same canonical source is also loaded into the editor.

Before the fix, `bash Tests/t1_read_projection_fidelity_contract.sh legacy`
exited `1`. The old lock correctly projected kana/romaji, but repository
overlay output had `spans=0`, `performer=nil`, `language=nil`, and
`timingID=nil`.

```text
FAIL: repository locked-reading overlay dropped timing, metadata, or failed to apply the locked reading
legacy overlay observed kana=Optional("こんにち") romaji=Optional("konnichi") spans=0 performer=nil language=nil timingID=nil provider=Optional("t1-authoritative-provider-source")
T1_PREFX_LEGACY_EXIT=1
```

After the fix, the same command exits `0`. The lock remains active in the
editor; kana/romaji are `こんにち` / `konnichi`; original text, start/end
times, line translation, performer, all three spans, language `ja`,
provider source ID and the selected same-version timing UUID survive the
repository → session → editor chain. The editor's selected translation
version remains the displayed draft translation. The canonical source hash
and H1 debug binding token stay equal to the stored-row hash even though
hashing the locked-reading display projection produces a different value.

```text
legacy overlay observed kana=Optional("こんにち") romaji=Optional("konnichi") spans=3 performer=Optional("v2") language=Optional("ja") timingID=Optional(88309C91-EDD7-4506-8CDB-7CC4C9D421C9) provider=Optional("t1-authoritative-provider-source")
T1 read/projection fidelity contract passed (legacy)
```

Repeated repository loads, session switch to an untimed sibling and back, and
editor switch to that sibling and back all preserve the same loaded fields.

### C — Switching translation versions inside the editor draft

The same timed source version has two complete stored translation versions.
The contract enters the editor with the first translation, switches to the
alternate translation, switches back, and then switches the lyrics version
away and back. This exercises `selectTranslation` on an existing draft rather
than only the initial repository-to-editor projection.

Before the fix, the new case ran against production source HEAD
`3e800d39eee8dd5304f3b0182284cec20e8ac176` with the updated focused contract.
`bash Tests/t1_read_projection_fidelity_contract.sh legacy` exited `1` at the
editor assertion after selecting the alternate translation. The repository
overlay log immediately before that assertion still showed the original
locked reading, all three spans, performer, language and timing attachment;
the loss occurred in the translation-version draft projection.

```text
FAIL: editor draft translation=切换后的译文 lost locked reading, line timing, spans, performer/language, attachment identity, or source identity
legacy overlay observed kana=Optional("こんにち") romaji=Optional("konnichi") spans=3 performer=Optional("v2") language=Optional("ja") timingID=Optional(977B731A-FF43-4350-9CA6-87C52B699A10) provider=Optional("t1-authoritative-provider-source")
```

After the fix, `selectTranslation` copies the existing draft, replaces its
translation text, and marks the projection clean. The final `all` contract
exits `0` and checks both translation values while also checking the locked
reading, start/end times, spans, performer/language, exact timing UUID,
source identity and canonical hash after each switch. Returning from the
untimed sibling preserves the currently selected latest translation. The
new-version save converter remains unchanged for T2.

```text
legacy overlay observed kana=Optional("こんにち") romaji=Optional("konnichi") spans=3 performer=Optional("v2") language=Optional("ja") timingID=Optional(FDC28D1F-A6CC-4E4D-96E9-99400DF36139) provider=Optional("t1-authoritative-provider-source")
T1 read/projection fidelity contract passed (all)
```

## Field facts by layer

| Field | SQLite load / repository overlay | Session | Editor draft |
|---|---|---|---|
| Partial mask / sync | `[0]` and `false`; explicit `0` differs from a placeholder; no-timed-row mask loads as `nil` | `[0]`, `nil`, and in-memory `[]` remain distinct; sync state retained | Same distinctions retained; meaningful start `0` vs placeholder `nil` retained |
| Line start / end | Partial fixture: `0` / `2`; locked-reading fixture: `0` / `4` | Values unchanged | Draft start/end unchanged |
| Timed spans | Absent fixture stays absent; timed fixture returns all 3 spans | All 3 spans remain attached | All 3 spans and their text/UTF-16 coordinates remain attached |
| Performer | Absent fixture stays `nil`; timed fixture returns `v2` | `v2` retained | `v2` retained |
| Language | The no-language input follows the existing mapper rule and is stored/read as `und`; timed fixture reads `ja` | `und` / `ja` retained | `und` / `ja` retained |
| Translation | Stored compatibility line translation is retained alongside the reading overlay | `compatibility line translation` retained | Selecting either stored same-version translation changes only translation text; returning to the timed lyrics version selects the latest complete translation under existing policy while all other draft fields remain equal |
| Legacy locked reading | No overlay in partial fixture; timed fixture applies stored kana/romaji while keeping original source rows | Display reading remains projected; canonical source hash is passed separately | Display reading and locked state retained |
| Attachment identity | Exact selected timing version UUID present for timed fixture; absent for partial fixture | Same UUID carried through loaded document | Same UUID carried through draft; no replacement attachment is created |
| Document identity / metadata | Request identity, track metadata, source, confidence, provider source ID and language come from the production mapper | Document copy preserves them | Draft keeps track metadata, source version ID and canonical source hash |
| Database writes | Fixture/setup writes happen before read snapshot | — | Repository/session/editor load and switching do not mutate rows |

The `nil` versus `[]` statement is deliberately scoped: model, session and
draft copies preserve the distinction; the current SQLite schema cannot
persist that distinction for an empty unsynchronized mask. No migration or
new storage semantics were added.

## Database no-write evidence

The contract seeds a temporary database using the production repository,
including both translations, and an isolated historical locked-reading row.
Immediately before read-path checks it takes a read-only snapshot of every
table plus `PRAGMA data_version`. After repeated repository loads, session
adoption/switches, editor begin, translation selection and editor version
switches, the complete snapshot and data version are equal.
The contract logs `temporary_copy=YES` and `formal_database_opened=NO`.
Fixture setup is intentionally outside this read-only comparison window.

## Commands and results

All commands ran from the isolated T1 worktree unless noted.

| Command | Exit | Result |
|---|---:|---|
| Pre-fix `bash Tests/t1_read_projection_fidelity_contract.sh partial` at H1 base | `1` | Expected RED: partial mask lost in real session projection |
| Pre-fix `bash Tests/t1_read_projection_fidelity_contract.sh legacy` at H1 base | `1` | Expected RED: lock projected, timing/metadata/attachment lost |
| Pre-fix `bash Tests/t1_read_projection_fidelity_contract.sh legacy` at `3e800d39eee8dd5304f3b0182284cec20e8ac176` | `1` | Expected RED: selecting another translation discarded fields from the editor draft |
| `bash Tests/t1_read_projection_fidelity_contract.sh partial` | `0` | Production SQLite → session → draft partial timeline |
| `bash Tests/t1_read_projection_fidelity_contract.sh legacy` | `0` | Production locked-reading overlay → session → editor and switches |
| `bash Tests/t1_read_projection_fidelity_contract.sh all` at source/test commit `2963f710c85e0993963d0127514791ee6a19196f` | `0` | Both required counterexamples, translation selection, nil/empty masks and no-write snapshot |
| `bash Tests/h1_hash_domain_boundary_contract.sh` | `0` | H1 hash identity and mismatch-guard regression |
| `bash Tests/sqlite_session_contract.sh` | `0` | Existing SQLite/session contract |
| `bash Tests/timing_persistence_immutable_contract.sh` | `0` | Existing immutable timing identity / idempotency contract |
| `bash Tests/lyrics_editor_contract.sh` | `0` | Existing editor contract |
| `bash Tests/phase_2_5c_contract.sh` | `0` | Existing translation/session contract |
| `bash Tests/phase_2_6a_persistence_contract.sh` | `0` | Existing reading persistence contract |
| `git diff --check` | `0` | Whitespace check before production commit |
| `xcodebuild -project SpotifyLyrics.xcodeproj -scheme SpotifyLyrics -configuration Debug -derivedDataPath /tmp/lyrics-t1-read-projection-deriveddata CODE_SIGNING_ALLOWED=NO build` | `0` | `BUILD SUCCEEDED` |

The build emitted an existing Swift 6 `Sendable` warning in
`WhisperCLISpeechEngine.swift`; AppIntents metadata extraction was skipped
because the target has no `AppIntents.framework` dependency. Neither blocked
the build.

During contract development, two standalone-runner compile attempts exited
`1` due to a missing production source file in the runner list and a C-string
initializer mismatch; both were corrected in the runner. One combined-run
assertion initially expected exactly two editor versions although the shared
fixture had more; it now checks for the required minimum. A later assertion
assumed an omitted language remained `nil`; inspection confirmed the existing
mapper stores it as `und`, and the contract now verifies that established
behavior. These were harness or assertion corrections, not product
regression results. The first post-fix translation-switch run also had an
incorrect expected translation after returning from another lyrics version;
the existing editor selects the latest complete same-version translation.
The contract was corrected to that observed selection rule while retaining
an explicit switch-back assertion. These were harness or assertion
corrections, not product regression results. The final targeted commands
listed above all passed. The full suite was not run.

## Not run and handoff boundary

- No formal user database, app launch, real player, audio recording, AI call,
  credential access, or external provider request.
- Human acceptance is `USER_VERIFICATION_REQUIRED / NOT_RUN`.
- No timing-attachment save behavior was changed or verified; that is T2.
- No S1/O1/R1/provider/UI work, merge, tag, release or deployment was started.

Rollback scope: revert source/test commit
`2963f710c85e0993963d0127514791ee6a19196f`, test follow-up commits
`93e9b017096005b1c9919bde561dc8d10f4c38aa` and
`0109ac3c42d0456587fefd9c3c5377b2ce989389`, then production commit
`bd6127c699a282d0bab5ab350cccd6a781446f41`, to remove the T1 contract and
code. The checkpoint is a zero-diff commit; no schema or user-data rollback
is needed. A separate docs/status commit only changes evidence and stage
pointers. Planner's targeted review confirmed the evidence and found no T1
Blocker / necessary Relevant. T2 has not started. Human verification remains
`USER_VERIFICATION_REQUIRED / NOT_RUN`.
