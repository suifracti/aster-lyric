# U1 — Honest Experimental UI

- `batch_id`: `U1`
- `result`: `AUTOMATED_VERIFIED`
- `base_head`: R1 final `44f949ac9d062a77d3adf6fede0e94e95b69b3f7`
- `checkpoint_head`: `9bbf14e7071a506ebff5b800dca9808a7ac1fd69` (`chore: checkpoint U1 honest UI baseline`, pushed before implementation)
- `branch`: `codex/u1-honest-experimental-ui`
- `source_worktree`: `/Users/apple/.codex/worktrees/u1-honest-experimental-ui/sptifylyrics`
- `initial_production_commit`: `7299241839864dd345b713dea1323fb3b72bef33` (`fix: make experimental UI actions honest`)
- `latest_production_commit`: `a33e9a160a413f928429fa976fc071f5e3f5fe27` (`fix: map D track summary from playback state`)
- `production_commits`: `7299241839864dd345b713dea1323fb3b72bef33`, `c19a53c800d03ff5a09deb95f5a86cc0815e86dc`, `a33e9a160a413f928429fa976fc071f5e3f5fe27`
- `human verification`: `USER_VERIFICATION_REQUIRED / NOT_RUN`
- `planner review`: completed after the track-summary follow-up; no remaining Blocker or necessary Relevant finding

## Base and source identity

The U1 worktree was created from R1 final `44f949a`, not the formal root's older H1 checkout. Its pushed checkpoint `9bbf14e` contains the requested H1/T1/T2/S1/O1/R1 ancestry. The three production commits are on top of that checkpoint. The formal project root `/Users/apple/backup/sptifylyrics` and its three existing untracked `PROJECT_FULL_AUDIT_*.md` files were left unchanged. The U1 branch does not change database schema, lyric assets, user dictionaries, offset storage, or persisted layout preferences.

The app's maintenance boundary remains Core V3/Fullscreen, Supported Secondary Desktop transparent v2/Menu Bar, Experimental Direction D/Capsule, and Legacy Classic V1/desktop legacy panel. These classifications do not imply that every action is implemented. Release routes were checked separately from Debug preview and diagnostic hosts; fixture-only preview callbacks were not treated as production false-success affordances.

## Entrance facts and treatment

| UI / route | Debug and Release reachability | Before: actual action and feedback | After: action, state, and treatment |
| --- | --- | --- | --- |
| Classic V1 immersive split, Favorite and More | Reachable when the persisted immersive-split layout resolves through `MainLyricsWindowView.legacyWindowBody → layoutBody → ImmersiveSplitWindowView`; available in Debug and Release. | Both controls had empty closures. Favorite disclosed that its library API was not connected; More implied song actions existed. Neither performed an operation or gave a result. | Removed only Favorite and More. Artwork, track metadata, playback controls, status, and the saved Classic layout remain. |
| Direction D lyric-row ellipsis | The saved `.directionDV4` route renders `DirectionDMainWindowView → DirectionDLyricRowView` in Debug and Release. | Ellipsis correctly opened a menu, but translate, phonetics, and timing callbacks only dismissed it. The unused optional context callback defaulted to an empty closure. | Kept ellipsis and popover dismissal. The three unavailable actions are disabled with action-specific reasons; removed the unused no-op callback. |
| Direction D inspector / small workbench sheet | Both are reachable from the Release and Debug D route. Open/close and navigation are local presentation actions. | Track title/artist/album were model supplied. Version, translation, Ruby and timing rows showed fixed “current/complete” states; history and candidate/search/calibration/import/export controls had empty behavior. Empty adapter title could become fabricated “当前歌曲”; the Debug small sheet fell through to preview-only sample defaults. | Kept live track summary and inspector/sheet navigation. Removed fixed success/current claims and empty controls/history gesture. Empty title is now mapped from live/mock-preview presence: absent track shows “等待歌曲”, an identified track with blank title shows “歌曲标题未知”, and known title is preserved. Debug small sheet now receives adapter metadata. Unavailable workbench capabilities are explained; D status banners remain tied to adapter state. |
| Direction D main toolbar and product host | Main Release route uses the real manual search, app Settings, and inspector routes. Debug scene/product hosts are reachable for diagnostics. | Main toolbar actions were real. The Debug product host sent manual search to `retryLyrics()`, Settings to an empty action, and prepared a TXT draft without opening the editor. Its AppKit diagnostic host had no SwiftUI presentation handlers but exposed clickable controls. | Main and ordinary Debug SwiftUI routes use `SongSearchPopover`, the real Settings route, and the existing editor route. TXT opens the editor only after successful preparation. If the direct AppKit host lacks a route, search/Settings/TXT controls are disabled with reasons; the TXT closure returns before preparation. |
| Direction D empty state and status banners | Release/Debug D main surface; the separate product-state host is Debug-only. | Retry, automatic retry/stop and local alignment were real controller/state actions. Main TXT import ignored the preparation result and did not open the editor. Secondary completion/error banners were real adapter-state projections. | Retained real retry/stop/alignment actions and model-driven banners. TXT now checks preparation success and routes the prepared draft into the existing editor. |
| Capsule control | Release-reachable through `LyricsPreferencesPopover → WindowManager.toggleCapsule`; existing Capsule window consumes common live playback projection. | It actually toggled Capsule and reflected `playbackState.showCapsulePlayer`, but did not identify the feature as experimental at the control. | Preserved toggle and user settings; added a nearby concise experimental note. No Capsule mode or layout default changed. |
| AI translation | Release-reachable from `CurrentSongOperationsView.translationSection`. | Translation/retranslation, progress, preview and adoption were real model/session actions; no local experiment/review note appeared at the entry. | Preserved the real actions and added a concise note that generated output is experimental and should be reviewed. No provider or AI behavior was added or invoked. |
| Automatic and local-file alignment | Release-reachable from settings and `CurrentSongOperationsView.alignmentSection`. | Retry/stop used `AutomaticAlignmentJobController`; local audio prepare/confirm/cancel used `PlaybackState`. These were real actions, but the entry did not explain the independent source limits clearly. | Kept both action paths. Added a scoped note: automatic capture is experimental/default-off and limited to ready Spotify Desktop; Apple Music is not automatic capture. User-selected local-file alignment remains independent. A0's source gate remains intact. |
| Direction D layout setting | Release-reachable setting and saved layout route; V3 remains default. | D's `.experimental` catalog classification existed, but its layout entry did not make the experimental boundary easy to see. | Added scoped experimental explanation at the D setting. Existing saved layout parsing, V3 default, and user layout preferences remain unchanged. |

The exact inspected routes and baseline red output are preserved in the task work notes under `/tmp/spotifylyrics-u1-sdd/task-1-report.md`; the maintained repository fact table above records the relevant production conclusions.

## Before / after counterexamples

| Counterexample | Before U1 | After U1 |
| --- | --- | --- |
| Click Classic Favorite/More or a D row action | Clickable control reached an empty closure; there was no operation-specific feedback. The red U1 contract reported these exposed no-ops. | Classic placeholders are absent. D row actions remain discoverable but disabled with a specific reason; menu dismissal still works. |
| Read the D inspector's current/completion status | Fixed copy claimed current lyrics/version/translation/Ruby/timing or completion without a matching model result. Candidate/history controls were empty. | Only live track metadata and actual model-driven status remain; unsupported workbench status/actions are described as unavailable. |
| Open the D workbench with no current track or blank title metadata | The host converted an empty title into “当前歌曲”; the Debug small sheet could use its initializer's fixed sample title. The first final Planner review reported this as a necessary Relevant finding. | Production `DirectionDTrackSummaryPresentation` uses actual live/mock-preview presence: no track → “等待歌曲”; track with blank title metadata → “歌曲标题未知”; known title → unchanged. Main D inspector/sheet and Debug product host inspector/sheet use that mapping and real metadata. |
| Manual TXT import in the D main window | It prepared a draft, ignored the Boolean result, and never opened the existing editor. | Failed/cancelled preparation leaves the editor closed; successful preparation opens it once with the prepared draft. The contract invokes `DirectionDActionRouter.performManualLyricsImport`, also wired to Debug/Release routes. |
| Manual search/Settings in the Debug product host | Search invoked retry instead of search; Settings did nothing. | Ordinary SwiftUI Debug routes call real search/Settings presentations. Hosts without a presentation route render these controls disabled with concrete help text. |
| TXT import from the direct AppKit Debug diagnostic host | The host lacked editor presentation closures while exposing actions; preparation could strand a draft/open a picker without an editor route. | Controls are disabled and the route guard returns before preparation when the editor route is absent. No attempt is made to open a real file picker in that harness. |
| Capsule/AI/alignment entry | Real operations were available, but users could not identify the scoped experimental boundary at the point of use. | Real behavior is preserved; concise capability-specific experiment notes are adjacent to the relevant controls. |

The original `bash Tests/u1_honest_experimental_ui_contract.sh` exited `1` on the baseline before implementation, reporting the concrete production route gaps above. After the initial implementation, review found that the direct AppKit Debug host still exposed actions when its presentation handlers were absent. A focused red check observed four expected failures before follow-up `c19a53c`; the same contract passed after the fix. Final Planner review then found the empty-title fallback described above. After adding three assertions and before the production mapping, the contract exited `1` with three failures: no production title mapping, main D title not bound to playback presence, and Debug host title not bound to adapter state. Commit `a33e9a1` adds the mapping and wires main/Debug inspectors and sheets to it; the contract then passed with direct behavior checks for absent track, blank metadata, and known title. No Release or ordinary SwiftUI Debug route was disabled.

## Verification matrix

| Check | Exit | Result |
| --- | ---: | --- |
| `bash Tests/u1_honest_experimental_ui_contract.sh` | 0 | Route/source contract passes. Swift behavior checks confirm absent track → waiting, blank title on a current track → unknown, known title is preserved, cancellation/failure does not open the editor, and successful TXT preparation opens it exactly once. |
| `bash Tests/direction_d_phase_3_4_contracts.sh` | 0 | 29/29 assertions pass. |
| `bash Tests/direction_d_phase_3_4_visual_contracts.sh` | 0 | 35/35 assertions pass after replacing the obsolete fixed-inspector expectations with the new honest state. |
| `bash Tests/direction_d_phase_3_4_correctness_contracts.sh` | 0 | 22/22 assertions pass. |
| `bash Tests/direction_d_phase_3_4_layout_recovery_contracts.sh` | 0 | Saved layout/recovery contract passes. |
| `bash Tests/main_window_layout_fusion_contract.sh` | 0 | Layout fusion contract passes; existing layout choices/default remain valid. |
| `bash Tests/capsule_window_behavior_contract.sh` | 0 | Existing Capsule behavior remains intact. |
| `bash Tests/experience_library_contract.sh` | 1 | Existing runner fails its assertion “control-focused v2 must remain the current capsule.” U1 changed neither the Capsule catalog nor its current selection; the direct Capsule runtime behavior contract above passes. This is a runner/catalog expectation gap, not counted as PASS. |
| `bash Tests/direction_d_phase_3_3_contracts.sh` | 1 | 33 pass, 1 fail: `no_d_default_layout` asserts Direction D must not be a `MainWindowLayoutStyle`. That conflicts with the existing separately selectable Release D layout while V3 is still default; U1 did not modify the layout model. D 3.4 contracts verify the preserved intended D/V3 behavior. Not counted as PASS. |
| `set -o pipefail; xcodebuild -project SpotifyLyrics.xcodeproj -scheme SpotifyLyrics -configuration Debug -derivedDataPath /tmp/spotifylyrics-u1-review-debug CODE_SIGNING_ALLOWED=NO -quiet build 2>&1 | tee /tmp/spotifylyrics-u1-review-debug-build.log | awk '/warning:|error:|BUILD SUCCEEDED|BUILD FAILED|Using the first of multiple matching destinations|Supported platforms for the buildables/'` | 0 | Required Debug build succeeded after `a33e9a1`. Existing Swift 6 Sendable, deprecation, and unused-value warnings remain in unchanged files; no warning points to a U1-changed source file. Xcode also prints its existing platform/destination selection notices. |
| `git diff --check 9bbf14e7071a506ebff5b800dca9808a7ac1fd69..HEAD` | 0 | No whitespace errors in the production/test diff. |

No full test suite was run. The two nonzero legacy runner results above are disclosed as failures/coverage gaps, never as passes. The baseline red and focused follow-up red were intentionally observed and retained in the task evidence; no failing assertion was removed to make the result green.

## Changed files

Production and focused-contract changes are limited to:

- `SpotifyLyrics/Design/DirectionD/DirectionDActionRouter.swift`
- `SpotifyLyrics/Design/DirectionD/DirectionDProductStateAdapter.swift`
- `SpotifyLyrics/Design/DirectionD/DirectionDProductStateModel.swift`
- `SpotifyLyrics/Main.swift`
- `SpotifyLyrics/Views/Components/CurrentSongOperationsView.swift`
- `SpotifyLyrics/Views/Components/DirectionD/DirectionDExperimentalProductHost.swift`
- `SpotifyLyrics/Views/Components/DirectionD/DirectionDInspectorView.swift`
- `SpotifyLyrics/Views/Components/DirectionD/DirectionDLyricRowView.swift`
- `SpotifyLyrics/Views/Components/DirectionD/DirectionDMainWindowView.swift`
- `SpotifyLyrics/Views/Components/DirectionD/DirectionDProductStateHostView.swift`
- `SpotifyLyrics/Views/Components/DirectionD/DirectionDSongWorkbenchButton.swift`
- `SpotifyLyrics/Views/Components/LyricsPreferencesPopover.swift`
- `SpotifyLyrics/Views/MainWindow/ImmersiveSplitWindowView.swift`
- `SpotifyLyrics/Views/MainWindow/MainLyricsWindowView.swift`
- `SpotifyLyrics/Views/Settings/SettingsRootView.swift`
- `Tests/direction_d_phase_3_4_visual_contracts.sh`
- `Tests/u1_honest_experimental_ui_contract.sh`
- `Tests/u1_honest_experimental_ui_contract.swift`

`docs/STATUS.md` and this evidence document record the batch. No application data or defaults were opened or changed by these checks. No database load/write path was exercised or modified. No formal user database, real player, recorder, AI service, credentials, or generated project file was accessed.

## UI smoke, user verification, and review

No interactive D/Classic UI smoke was run: there was no safe isolated UI harness for those actual windows, and launching the formal app could bind real playback. The Debug build and route/action contracts are automated evidence, not a visual smoke. The requested user check remains `USER_VERIFICATION_REQUIRED / NOT_RUN`:

- Inspect D and Classic to understand which actions work and which are unavailable.
- Confirm current/completion status is not misleading.
- Confirm working actions and saved layout preferences remain available.

Planner's initial targeted review found one necessary Relevant issue: the inspector could display “当前歌曲” without a bound track title, and the Debug small sheet could use preview defaults. `a33e9a1` fixes this by resolving title from actual playback/mock-preview presence and passing actual adapter metadata to both Debug inspector and sheet. The U1 contract tests the pure production mapping directly. Final Planner re-review confirmed the issue resolved and found no new Blocker or necessary Relevant issue; the review also confirmed the evidence/status facts and pending human verification status.

## Rollback

To roll back U1 behavior, revert production commits in reverse order: `a33e9a1`, `c19a53c`, then `7299241`; retain the pushed checkpoint and prior R1 ancestry. Revert U1 evidence/status commits only if withdrawing the U1 record. No stored user data or schema changed, so there is no data migration rollback. Reverting restores the empty Classic/D affordances, fixed inspector labels, fabricated empty-title fallback, and misrouted/unavailable Debug actions; it also removes the scoped experiment notes and focused contracts. It does not reset saved layouts or user preferences. No merge, tag, or release was created.

The next candidate is V1, pending acceptance only; this batch does not mark `M1_READY` and stops before V1.
