# Nightly — automatic lyric selection and focused stutter check

**Result: `AUTOMATED_VERIFIED / USER_PENDING`.** This follow-up does not close M1 or replace the V1 human acceptance. The candidate was built but never launched. No formal database, app defaults, app credential, player, audio capture, or AI service was accessed. The requested Git push used the repository's configured authentication silently; no credential value was inspected or displayed.

## Source and test identity

| Item | Identity |
|---|---|
| Project root | `/Users/apple/backup/sptifylyrics` |
| Base | V1 branch `codex/v1-core-integrity-verification`, `ca98a9dea34df8f1cb9ce723543eb89ce2ed4595` |
| Production branch | `codex/nightly-auto-lyrics-stutter` |
| Latest production commit | `c51ef5df298630128569e8b1c7b41fe5408eaff6` — `fix: restore saved lyrics when auto-search is off` |
| Earlier Nightly production commit | `137be01c86434afc6e80dc688e1ed9e435abe11e` — `fix: rank automatic lyrics by valid timing`; tick de-duplication and bounded timed-layout cache are also in the branch ancestry |
| Production ancestry | Includes U1 `d75789ee74b1a68c6caf02cd062b14b3c59dcd24`, V1 `ca98a9dea34df8f1cb9ce723543eb89ce2ed4595`, and `137be01` |
| Original aggregate identity | Base `ca98a9d` plus the exact production/test diff later committed as `137be01`; the original 20/20 run predates the auto-search-off follow-up |
| Final aggregate identity | Production/test content equals commit `c51ef5df298630128569e8b1c7b41fe5408eaff6`; the final 20-contract run completed before commit, with no source or test changes between the run and commit |
| Candidate build configuration | Xcode scheme `SpotifyLyrics`, `Debug`, arm64, `CODE_SIGNING_ALLOWED=NO`; built from commit `c51ef5df298630128569e8b1c7b41fe5408eaff6` |

The first two push attempts failed during the HTTPS TLS handshake (`LibreSSL SSL_ERROR_SYSCALL`). A read-only remote check then succeeded and an ordinary push completed; production commit `137be01` is on the branch upstream. No force push or history rewrite was used.

## Changes

| Area | Files | Behavior |
|---|---|---|
| Automatic fresh-search selection | `SpotifyLyrics/Lyrics/LyricsSearchManager.swift`, `SpotifyLyrics/Lyrics/LyricsModels.swift`, `SpotifyLyrics/Models/Models.swift` | Retains the existing SafeMatcher identity/tier gate and only ranks already auto-eligible candidates. Within the first successful query variant, matcher score/tier come first, then validated word spans, valid line timing, and plain text; configured provider and candidate order break remaining ties. Local probes still execute before network probes. Provider confidence, provenance, identity rejection, preferred/locked persistence, and automatic thresholds are unchanged. Candidate projection now retains explicit partial-timeline mask semantics. |
| Tick invalidation | `SpotifyLyrics/Services/PlaybackState.swift`, `SpotifyLyrics/Models/Models.swift` | Periodic timer samples no longer publish `currentTime` when the value is unchanged. Real time changes, seeks, resets, and track changes still publish. Mock end-of-track handling no longer repeatedly resets an already stopped preview. |
| Desktop timed geometry | `SpotifyLyrics/Views/Floating/FloatingLyricsView.swift`, `SpotifyLyrics/Lyrics/FloatingLyricsPresentation.swift` | Reuses a bounded 512-entry cache for timed Ruby geometry. The immutable cache key compares all dependencies (text, spans, font, weight, Ruby visibility/tokens, design), so hash collisions cannot alias distinct layouts. Playback time stays outside the geometry key. |
| Saved selection with auto-search disabled | `SpotifyLyrics/Services/LyricsSessionController.swift`, `SpotifyLyrics/Services/PlaybackState.swift`, `SpotifyLyrics/Views/Components/LyricsCanvasView.swift` | `begin(... automaticallySearch: false)` now reads and applies an existing preferred/locked version without calling providers or writing it back. With no saved version, the session settles to idle and the live surface explains that automatic search is off while preserving an explicit manual-search action. |

No schema, storage selection policy, UI route, or user data was changed. The desktop cache and tick guard reduce repeated work in the identified path; they do not establish a measured or user-confirmed smoothness improvement.

## Reproduction and resolution

- **Automatic timing regression, before the ranking fix:** `bash Tests/phase_2_11a_retrieval_contract.sh` exited `133` on the production manager fixture. A SafeMatcher-equivalent invalid-span candidate appeared before a valid UTF-16 `A🙂A` word-span candidate; the first eligible result was returned. A strengthened mixed-valid/malformed multi-line payload assertion also exited `133` before the fix.
- **After the fix:** the valid complete partial payload wins; invalid text/range/time spans do not earn word-timing priority; valid line timing beats untimed text; partial mask, `nil`/empty distinctions, source identity, and unsynchronized semantics survive candidate projection. A different recording remains rejected before timing richness is considered. Confidence-zero Lyrics.ovh remains a manual-review candidate.
- **Provider lanes and order:** the first run of `search_concurrency_manual_contract` after the behavior change exited `133` because its old assertion required local results to short-circuit network work. The contract now checks the real rule: local lane executes first, then equivalent eligible results are compared; configured order wins an equal-quality tie. Updated runner passes. This was a stale assertion about selection policy, not a regression in probe ordering.
- **Cache identity:** the reviewer found that a key made only from `Hasher.finalize()` could alias distinct geometry. It was replaced with an equality-checkable immutable key; the focused cache contract passes. Final review found no remaining Blocker, Important, or Minor finding.
- **Session persistence:** a production `LyricsSessionController` and temporary `SQLiteLyricsRepository` fixture chooses the better timed candidate, writes the selected version/attachment, closes and reopens SQLite, and restores the same version, actual spans, and partial mask in a new session. DebugSafety reported `formal_database_opened=NO`.
- **Stutter evidence:** source inspection confirmed that paused `PlaybackState.tick()` assigned the same `currentTime` every 0.2 seconds and that Desktop timed geometry was recomputed through the view body. The production tick now filters only identical timer samples; the timed layout cache bounds geometry reuse. Contracts verify the path and dependencies. No isolated SwiftUI performance harness exists, so actual line-change latency and perceived smoothness remain unmeasured.
- **Automatic search disabled, before follow-up:** `bash Tests/s1_durable_manual_adoption_contract.sh auto-search-disabled-loads-selection` exited `1`; with the preference off, the session returned before loading the repository's persisted preferred/locked version.
- **After follow-up:** the same production contract exits `0` using a temporary SQLite database. It restores the exact selected version and source while automatic provider calls remain at zero; an uncached track reaches idle without searching, and explicit manual retry still invokes the provider. The live state exposes why search is idle and offers manual search. No stored selection or automatic-search threshold was changed.

## Verification

All listed commands ran on the production/test diff that is now commit `137be01`.

| Command | Exit | Result |
|---|---:|---|
| `bash Tests/phase_2_11a_retrieval_contract.sh` | 0 | Selection ranking, candidate identity, timing validity and partial mask |
| `bash Tests/search_concurrency_manual_contract.sh` | 0 | Bounded network concurrency, cancellation drain, local-first execution and configured tie order |
| `bash Tests/s1_durable_manual_adoption_contract.sh auto-search-timed-reopen` | 0 | Temporary DB save/close/reopen and new-session restoration |
| `bash Tests/floating_lyrics_contract.sh` | 0 | Bounded geometry cache and invalidation inputs |
| `bash Tests/presentation_clock_contract.sh` | 0 | Tick no-op policy, mock finish policy and presentation clock |
| `bash Tests/c1_offset_semantics_contract.sh` | 0 | Offset/transport and seek separation |
| `bash Tests/b0_clock_offset_truth_contract.sh` | 0 | Clock/source routing and paused presentation update |
| `bash Tests/presentation_line_index_contract.sh` | 0 | Shared active-line index |
| `bash Tests/v3_lyric_layout_stability_contract.sh` | 0 | V3 layout stability |
| `bash Tests/v3_lyric_transition_contract.sh` | 0 | V3 lyric transitions |
| `bash Tests/v3_lyrics_scroll_stability_contract.sh` | 0 | V3 scroll stability |
| `bash Tests/run_core_integrity.sh` | 0 | **20 run, 20 pass, 0 fail**; app UI smoke and human checks are outside this runner |
| `git diff --cached --check` | 0 | No whitespace errors before production commit |

Full V1 aggregate output: [Nightly aggregate contract log](Nightly-auto-lyrics-selection-stutter-contracts.txt).

The final aggregate after the auto-search-off fix is recorded separately at [final Nightly contract output](Nightly-auto-lyrics-selection-stutter-final-contracts.txt), so the original `137be01` run identity remains intact.

### Final-source follow-up verification (`c51ef5df298630128569e8b1c7b41fe5408eaff6` content)

| Command | Exit | Result |
|---|---:|---|
| `bash Tests/s1_durable_manual_adoption_contract.sh auto-search-disabled-loads-selection` before fix | 1 | Reproduced skipped persisted preferred/locked load |
| `bash Tests/s1_durable_manual_adoption_contract.sh auto-search-disabled-loads-selection` after fix | 0 | Restored saved selection; no automatic provider call; explicit retry still searches |
| `bash Tests/s1_durable_manual_adoption_contract.sh all` | 0 | S1 adoption suite including disabled-auto-search scenario |
| `bash Tests/phase_2_11a_retrieval_contract.sh` | 0 | Ranking, matching gates and timing validity |
| `bash Tests/search_concurrency_manual_contract.sh` | 0 | Cancellation, local-first and configured order |
| `bash Tests/u1_honest_experimental_ui_contract.sh` | 0 | Directly affected UI route/action contract |
| `bash Tests/run_core_integrity.sh` | 0 | **20 run, 20 pass, 0 fail**; no skips counted as passes |
| `git diff --check` / staged check | 0 | No whitespace errors |

Temporary SQLite fixtures reported `formal_database_opened=NO`. No source/test changes occurred between the aggregate and `c51ef5d` commit.

Original Nightly Debug build (`137be01`, historical candidate):

```sh
xcodebuild -project SpotifyLyrics.xcodeproj -scheme SpotifyLyrics -configuration Debug -derivedDataPath /tmp/spotifylyrics-nightly-deriveddata.0OfXMh/DerivedData CODE_SIGNING_ALLOWED=NO build
```

Exit `0` (`** BUILD SUCCEEDED **`). Unrelated pre-existing warnings remain, including `FileManager` Sendable in `WhisperCLISpeechEngine`, Keychain/AVFoundation deprecations, and Sendable/MainActor warnings in capture/window code. There were no compiler warnings in files changed by this batch. Xcode also reported that AppIntents metadata extraction was skipped because the target has no AppIntents dependency.

Final-source Debug build (`c51ef5df298630128569e8b1c7b41fe5408eaff6`):

```sh
xcodebuild -project SpotifyLyrics.xcodeproj -scheme SpotifyLyrics -configuration Debug -derivedDataPath /tmp/spotifylyrics-nightly-final-deriveddata-20260923 CODE_SIGNING_ALLOWED=NO build
```

Exit `0` (`** BUILD SUCCEEDED **`). Existing unrelated Swift warnings remain in AVFoundation metadata access, `WhisperCLISpeechEngine` Sendable conformance, and capture/window actor isolation, plus unused-variable/deprecation warnings and the no-AppIntents metadata notice. No compiler warning points to the four changed source/test files.

## Candidate and data boundary

- Final candidate App: `/tmp/spotifylyrics-nightly-final-deriveddata-20260923/Build/Products/Debug/SpotifyLyrics.app`
- Source commit: `c51ef5df298630128569e8b1c7b41fe5408eaff6` (latest production commit; built with no source changes)
- Bundle identifier: `com.spotifylyrics.app`
- Architecture/configuration: arm64 / Debug / unsigned (`CODE_SIGNING_ALLOWED=NO`)
- SHA-256 of `Contents/MacOS/SpotifyLyrics`: `09d3001314f07c835f6032848e9f6d668ec9c13d648fa6acb39b15ce36523856`
- The App is an ordinary temporary Debug build, unsigned, unlaunched, and not archived as a release.
- Xcode ran its Launch Services registration build step. Exact-path `lsregister -u -R` returned scan error `-10814`; a subsequent `lsregister -dump` search for the exact candidate path returned no record. The App was not launched.

There is no complete independent app-test configuration. A Debug-only `SPOTIFYLYRICS_DATABASE_PATH` override exists, but it does not isolate defaults, local lyrics, provenance, or Keychain. Because the bundle identifier matches the installed app, launching this candidate in the same macOS account would use:

- SQLite at `~/Library/Application Support/SpotifyLyrics/SpotifyLyrics.sqlite3`;
- `UserDefaults.standard` in the `com.spotifylyrics.app` preference domain;
- alignment provenance under `~/Library/Application Support/SpotifyLyrics/AlignmentProvenance`;
- the local LRC search roots `~/Music/SpotifyLyrics/Lyrics` and `~/Library/Application Support/SpotifyLyrics/Lyrics`;
- the same macOS user Keychain context.

The candidate runs in the same macOS user's Keychain context, although an unsigned Debug build may not be able to use an installed app's item and could fail or prompt; access was not tested. The actual saved user preferences were not read. Source defaults are Spotify connection on launch = true, lyric auto-search on track change = true, automatic alignment = false, and auto-translate-new-lyrics = false. Saved overrides remain in force if the candidate runs under the same account. Therefore it may connect to Spotify at launch; a saved automatic-alignment opt-in may start live capture when the source/track/playback gates are satisfied; a saved AI auto-translation opt-in with a configured engine may issue translation requests when a new lyric context loads. None of these settings, credentials, or private lyrics were inspected. The app was not launched, so none occurred.

### Safe use and recovery boundary

Preferred future test setup: a dedicated macOS test account with disposable settings, database, home-directory lyric folders, and Keychain. No account was created in this task. Do not launch this candidate from the current user account for acceptance.

If the user later explicitly chooses a same-account test, first quit every SpotifyLyrics instance and do not run while the installed app or candidate can write. Prepare a restricted backup folder; use SQLite's `.backup` command while the app is closed to take a consistent snapshot of `SpotifyLyrics.sqlite3` (including committed WAL state), run `PRAGMA integrity_check` against that snapshot, and separately copy the `AlignmentProvenance` directory. Export the `com.spotifylyrics.app` defaults domain to a private file without printing it, and snapshot both local LRC directories if they are to be used. Restore only after all app processes close: preserve the post-test state aside, replace the database from the snapshot with no stale `-wal`/`-shm` files, restore provenance and the defaults domain, and restore any local files if changed. Do not restore the defaults snapshot if the user has made wanted settings changes since capture. This cannot roll back external Spotify activity, AI requests, token refresh, or audio capture, which is another reason to use a separate macOS account.

## Human acceptance checklist — not run

Use one disposable macOS account/session and record each item as `PASS`, `FAIL`, or `NOT RUN`, with only track/version/provider identifiers and observed behavior (no lyric text or credentials). The current V1 LRC assets are synthetic and safe only in a disposable library: `/tmp/spotifylyrics-v1-human-acceptance-materials-d75789e/a-v1.lrc`, `a-v2.lrc`, `b-v1.lrc`, and `reading-and-long-line.lrc`. They cover version switching and reading/layout; **they contain neither word spans nor provider candidates**.

1. **Fresh automatic selection (new Nightly behavior):** use a new test track for which normal search naturally returns SafeMatcher-equivalent results of differing timing quality. Expect a text/range/time-valid word-timed result to beat line-timed/plain results while preserving provider identity and a persisted current version after restart. Provider responses are online and not deterministic; if no such candidate set appears, mark `NOT RUN`. Do not alter confidence, source identity, or thresholds.
2. **Playback, offset, scope, and restart:** import `a-v1.lrc`, `a-v2.lrc`, and `b-v1.lrc`. While playing and paused, adjust lyrics early/late and reset; verify lyrics update but playback progress stays put. Then drag the transport slider to seek (and check needed native keyboard/AX input), switch A/v1 → A/v2 → B/v1 → A/v1, restart, and compare main/fullscreen/desktop. If the editor opens B/v2 while live is A/v1, confirm it shows B/v2's saved offset without resetting it. Expect isolated pairs and restored values; only explicit transport input seeks.
3. **Lossless timing edit/copy:** use a saved version already known to contain real TTML/YRC spans. Create an unchanged revision and copy; restart and inspect spans. Then make an incompatible text edit and cancel; expect no write. Existing UI-import fixtures are LRC-only; if no real timed asset is available in the disposable account, record `NOT RUN` rather than treating those LRC files as span coverage.
4. **Manual adoption and locks:** use only naturally returned low-confidence candidates. Adopt, restart, and check the same saved selection; on a locked-current conflict, cancel and confirm the original selection remains. If the provider gives no low-confidence candidate, mark that subcase `NOT RUN`; no fixture may masquerade as a provider response.
5. **Reading consistency:** use `reading-and-long-line.lrc`, edit one Japanese reading row, switch inline/independent/fullscreen and check romaji, restart, then verify word-click correction still opens. The fixture is synthetic and contains repeated text/long-line content.
6. **Stutter and honest legacy states:** with a representative long/timed song, switch lines repeatedly in V3/fullscreen and desktop; record whether any hitch is actually perceived. Open D/Classic and confirm available actions still work and unavailable ones/statuses are clear. Source and contract evidence do not substitute for this observation.

Status remains `USER_VERIFICATION_REQUIRED / NOT_RUN`; no `M1_READY` claim is made. The final candidate must not be launched from the current macOS account for acceptance because its bundle ID and standard data locations overlap the installed app; use a dedicated disposable macOS account, or obtain an explicit decision to test against formal data only after following the backup/recovery boundary above.

## Remaining issues and rollback

- **Blocks M1 readiness:** the necessary V1/Nightly human experience checks above remain unrun. Evidence type: source/contract/build only. Next action: create/use a disposable macOS account, then Planner reviews the exact candidate and schedules the brief acceptance session.
- **Does not block automated result:** actual stutter magnitude and perceived improvement are unmeasured because no safe UI performance harness was available. Next action: note the song, layout, settings, and exact transition if the user sees a hitch.
- **Does not block automated result:** online provider candidate availability is nondeterministic; automated fixtures prove ranking, while UI behavior needs a naturally available real result.
- **Push:** the initial TLS failures were transient; production commits `137be01` and `c51ef5d` plus the evidence/status commits were pushed ordinarily. No force push or history rewrite was used.

Rollback the follow-up production code with a normal revert of `c51ef5df298630128569e8b1c7b41fe5408eaff6`, and revert the earlier Nightly change with a separate normal revert of `137be01` only if that whole behavior is intentionally rolled back; neither introduces a schema migration. Reverting code cannot undo lyrics versions/selection/timing saved while testing the candidate, nor external player/AI/capture activity. Restore data only under the quiesced backup procedure above.
