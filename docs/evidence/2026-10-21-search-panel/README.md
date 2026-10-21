# Shared search results — 2026-10-21

Requirements: the search row in `docs/TOOLBAR_BEHAVIOR.md` at **67b5be9**. Later letter-key/listening-extra work remains separate.

The complete search page's row is now `SongSearchResultRow`, used by both the full page and toolbar panel. Rows show artwork, title, artist/album, duration, saved 词/译/读 badges, adoption status and checkmark. The panel groups 本地已存 / 在线, with up to five results each. Arrow keys select a result; Return loads that result through the existing preview/live-session path. The complete page also pre-fills the current song when no earlier query exists. External Spotify-open actions remain available.

Saved badges travel with the existing cached library-entry metadata. There are no per-row database lookups. Merging in higher-confidence online metadata retains the saved entry, so badges and local grouping survive. The existing local-first/online-later flow and normalization cache remain in place; no timeout, retry, database migration or index was added.

## Verification

- Full Debug App build passed (`/tmp/lyricsq-1021-search-daily-build.log`).
- **58 native tests passed**, including local-first search and one added case covering saved metadata through online-result merge, bridge conversion, badges and the five-per-group limit. [Test result](native-tests.txt).
- Native fixture screenshots: [before](before.png), [after panel](after-panel.png), [same row on full page](after-full-page.png). Captured using `Scripts/ui-snapshots.sh` cases `hover-search pin-search search-panel search-full`; script exited 0. These are generated-artwork/private-data fixtures, not desktop screenshots.
- Rebuilt and restarted the daily development App from `/Users/apple/Library/Developer/Xcode/DerivedData/lyricsq-main/Build/Products/Debug/SpotifyLyrics.app`. Exact executable path was verified. Real-app screenshots and manual arrow/Return checks could not be obtained because Computer Use returned `SCStreamErrorDomain -3811`; [attempt record](real-app-capture.txt). No physical mouse was moved. `/Applications` was not replaced.
- **Claude visual approval is pending.** Under the newly added real-App screenshot rule, the fixture images do not substitute for that approval.

## Concurrent history

UI work was committed and pushed as **5114261**. While search implementation was still in progress, another local executor's already-pushed **4773d11** (`docs(agents): fix rule numbering`) also included these seven unfinished search files: `SongSearchManager`, `SongSearchModels`, `TrackSearchManager`, `TrackSearchModels`, `PlaybackState`, `SongSearchPopover` and `AppleMusicImmersiveV3QuickControls`.

That shared commit is retained. This follow-up completes the shared-row change, preserves unknown-duration handling, adds current-song prefill, adds the focused regression test and records before/after evidence. No shared history was reset, amended or force-pushed. The existing untracked `.planning/` directory was excluded.

## Current follow-up

Keyboard selection uses the existing stable recording merge key, so an online metadata result replacing its local row ID does not lose the selected recording. Fresh archive production Debug build passed;3affected native search tests passed (and58total native tests passed in the preceding UI batch with the same search sources). ExecutableSHA256d7cc61520862b6ab4924c7ac38ced09001987a06785987c80b9cd102a0548d2c.

AX on this build again confirms Light source / kyiku, original+translation lyrics and17% progress. Real screenshot retrieval returns a StageManager thumbnail, not usable panel evidence. Manual arrow/Return in the actual panel and Claude visual approval remain pending; earlier fixture captures remain explicitly labelled fixtures.

## 30s resource observations

Same Debug configuration, executable path, DerivedData, cached Light source/kyiku and unchanged main window, with no model requests or other test/build processes during sampling. First search observation:CPU0.033%,RSS151.66→136.88MiB. Its immediate30s repeat:CPU0.000%,RSS136.75→101.09MiB. Restoring only the two production files in the temporary archive to prior UI41ebfd8, rebuilding and reopening the same song/window gaveCPU0.033%,RSS139.39→131.00MiB. The initially higher search RSS was not a repeatable sustained increase; both builds' RSS falls during the samples. Raw records retained; no stable foreground-playback improvement or long-term memory conclusion claimed. No real-window pixel comparison or manual search-panel acceptance claimed.
