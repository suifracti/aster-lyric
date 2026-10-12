# A0 — Capture Source Verification & Containment

- `batch_id`: `A0`
- `base_head`: `a019766d3d7d01e1f74241636d8fcc531b9f890e`
- `predecessor_production_commit`: `b95ebd1636ff0d8e847390f608886e18484a30a9`
- `branch`: `main`
- `release identity`: formal GitHub Release `v0.1.2` (`6528be3103f75fd4f63757855b9d61cd30f757d8`)
- `result`: `A0_AUTOMATED_VERIFIED / USER_VERIFICATION_REQUIRED / NOT_RUN`
- `real capture`: `USER_VERIFICATION_REQUIRED / NOT_RUN`
- `validated_production_commit`: `e775f39702361dff9dba7894e746927c660c257b` (`fix: bind capture handoff to active source generation`)

## Starting state and boundary

The formal project root was `/Users/apple/backup/sptifylyrics`.

```text
branch: main
HEAD: a019766d3d7d01e1f74241636d8fcc531b9f890e
upstream: origin/main; main ahead by 3 commits
tracked diff: empty
staged diff: empty
untracked at start:
  PROJECT_FULL_AUDIT_2026-09-22.md
  PROJECT_FULL_AUDIT_ASTRA_2026-09-22.md
  PROJECT_FULL_AUDIT_GROK47_2026-09-22.md
```

The three audit reports were preserved and are not part of A0. No reset,
clean, stash, restore-overwrite, push, formal App launch, Spotify/Music
control, formal user SQLite, Keychain, recording, model, or full `Tests`
run was used. DerivedData was created only under task-specific `/tmp`
paths and is not a repository artifact.

A0 was limited to the automatic live-capture source boundary and the
existing source/track/generation invalidation path. It did not add Music.app
capture, change the aligner/quality/ASR pipeline, change persistence schema,
or change local-file alignment.

## Pre-fix source trace

Before A0, `PlaybackSnapshot` did not carry provider provenance. The active
provider could identify a current track, while the automatic controller then
reached:

```text
AutomaticAlignmentJobController.startJob
  -> LiveCaptureCoordinator.start
  -> SpotifyScreenCaptureAudioSpike.start
  -> SCShareableContent / discoverSpotifyApplications
```

The final discovery step independently selected Spotify applications. A
running Spotify process was therefore an insufficient source boundary when
Apple Music was the active playback provider. Existing track identity and
generation checks existed, but there was no source identity in their guard
and no source recheck immediately around persistence/adoption.

`PlaybackState.alignCurrentLyricsWithLocalAudio()` is a separate local-file
path. It uses the existing local audio chooser/environment seam and does not
call `LiveCaptureCoordinator` or Spotify ScreenCaptureKit discovery.

## Reachability matrix

| path | Debug | Release | entry / policy |
|---|---|---|---|
| `AutomaticAlignmentJobController` | compiled and callable | compiled and callable | product controller; `automaticAlignment.enabled.v1` remains default `false` |
| `LiveCaptureCoordinator.start` | compiled and callable | compiled and callable | product automatic job and existing Assist path; source gate runs before discovery |
| `SpotifyScreenCaptureAudioSpike.start` | compiled and callable | compiled and callable | low-level Spotify-only implementation; it is not itself a Debug-only implementation |
| `SPOTIFYLYRICS_SCK_S2` / `SPOTIFYLYRICS_SCK_S3A` launch hooks | Debug diagnostic hook | not compiled | coordinator diagnostic auto-start only |
| `SPOTIFYLYRICS_SCK_SPIKE` launch hook | Debug diagnostic hook | not compiled | direct spike diagnostic auto-start only |
| Main “排轴捕获 Spike（调试）” menu | Debug only | not compiled | diagnostic entry; not the automatic product path |

The automatic product path therefore remains Release-reachable but is
source-contained. The DEBUG-only environment hooks do not define product
reachability and were not used to turn the feature on.

## Implemented containment

### Source provenance and gate

- `PlaybackSourceIdentity` is carried by real provider snapshots:
  `SpotifyDesktopProvider` reports `.spotifyDesktop`,
  `AppleMusicDesktopProvider` reports `.appleMusic`, and
  `MockPlaybackProvider` reports `.mockPreview`.
- `PlaybackState` exposes the ready live snapshot's source identity. A
  no-track/unavailable snapshot becomes `.unknown`; this is fail-closed.
- `AutomaticLiveCaptureSourceGate` is the single source capability gate.
  It allows only a ready, identified Spotify Desktop live source. Music,
  unknown, mock/preview, unavailable, and no-identity cases are rejected
  before Spotify discovery/capture.
- Automatic entry requires `isPlaying`. The lower-level coordinator and
  debug spike use the same gate with `requiresPlaying: false` so the
  existing paused Spotify session/wait-for-resume behavior is preserved; this
  does not widen the allowed source set.
- `automaticAlignment.enabled.v1` remains opt-in with its existing default
  `false`. The automatic controller is a normal target source and remains
  Release-reachable; Debug menus remain diagnostic entry points only.

### Startup, source change, and adoption boundary

- `LiveCaptureCoordinator` now has a `.starting` state, an immutable
  `startGuard`, and a pending request ID. Playback observers are installed
  before the asynchronous low-level startup, and the guard is checked after
  startup before `.running`/`beginSession`.
- A source or live-track change invalidates the existing coordinator
  generation and pending startup. Stop is allowed during `.starting`, so a
  cancelled request can stop the low-level discovery/capture path.
- `SpotifyScreenCaptureAudioSpike` receives the guard, checks it after
  discovery, shareable-content lookup, immediately before `startCapture`,
  and immediately after `startCapture`. Its bound playback context is
  observed while discovering/capturing; stale source/track context causes
  cleanup and no active session.
- ScreenCaptureKit callbacks carry the active stream identity and a
  coordinator-assigned sample generation. The coordinator invalidates and
  drains the serial sample queue before closing a segment; both the
  synchronous WAV writer and the MainActor continuity update reject a stale
  generation. A queued sample from A cannot be relabeled into B.
- The automatic controller snapshots `lastStartedGeneration` before calling
  the coordinator, requires that this attempt advances the generation, and
  requires a handoff whose generation exactly matches that attempt. It no
  longer falls back to an unowned `lastPartialReport` when the handoff is
  missing or belongs to another session.
- `AutomaticLiveCaptureSessionGuard` requires the same Spotify source,
  exact track identity, exact generation, provider readiness, and non-mock
  state. The automatic controller checks it after capture startup, after the
  idle wait, before persistence, and after persistence before
  `lyricsSession.adoptPersisted`.
- A cancelled/stale save failure is ignored or marked stale; it cannot
  publish the old job's failure over the newer playback context.
- No SQLite schema, provider seek contract, or persisted source scope was
  changed. The guard is in-memory provenance only.

## Production and test files changed

Production:

- `SpotifyLyrics/Providers/PlaybackProvider.swift`
- `SpotifyLyrics/Providers/SpotifyDesktopProvider.swift`
- `SpotifyLyrics/Providers/AppleMusicDesktopProvider.swift`
- `SpotifyLyrics/Providers/MockPlaybackProvider.swift`
- `SpotifyLyrics/Services/PlaybackState.swift`
- `SpotifyLyrics/Capture/AutomaticAlignmentJobController.swift`
- `SpotifyLyrics/Capture/LiveCaptureCoordinator.swift`
- `SpotifyLyrics/Capture/SpotifyScreenCaptureAudioSpike.swift`
- `SpotifyLyrics/Main.swift`

Direct contracts:

- `Tests/a0_capture_source_containment_contract.swift`
- `Tests/a0_capture_source_containment_contract.sh`
- `Tests/playback_state_contract.swift`
- `Tests/spotify_connection_contract.sh`
- `Tests/apple_music_provider_contract.swift`

The A0 runtime contract compiles the production gate and session guard. Its
fake only counts discovery/capture/adoption side effects; it does not contain
a second implementation of source authorization or capture logic.

## Before / after fact table

`Spotify discoverable` and `Music discoverable` are fixture facts only in
rows A–H. The production gate decides before any ScreenCaptureKit discovery;
the fake counters do not implement the policy.

| case | active source | Spotify discoverable | Music discoverable | job started | capture started | source/track change | result produced | adopted | status | evidence type |
|---|---|---:|---:|---:|---:|---|---|---:|---|---|
| A. Spotify only | Spotify Desktop, ready/playing, `track:A` | yes | no | yes | yes (`1`) | none | current-session fixture | yes/current | PASS | runtime production gate + fake I/O counter |
| B. Music only | Apple Music, ready/playing, `track:A` | no | yes | no | no (`0`) | none | no | no (`0`) | PASS | runtime production gate |
| C. Music active + Spotify process | Apple Music, ready/playing, `track:A` | yes | yes | no | no (`0`) | none | no | no (`0`) | PASS | runtime production gate; Spotify presence cannot override source |
| D. both running, Spotify active | Spotify Desktop, ready/playing, `track:A` | yes | yes | yes | yes | none | current-session fixture | yes/current | PASS | runtime production gate |
| E. unknown source | unknown, identity fixture only | yes | no | no | no (`0`) | none | no | no (`0`) | PASS | runtime production gate |
| F. mock/preview | Mock Preview | yes | no | no | no (`0`) | none | no | no (`0`) | PASS | runtime production gate |
| G. source changes mid-job | Spotify A → Music A | yes | yes | initial yes | initial yes, then stopped | source changed | stale/old result rejected | no (`0`) | PASS | runtime session guard + source chain |
| H. track/generation changes | Spotify A → B, generation `41 → 42` | yes | no | initial yes | initial yes, then invalidated | track/generation changed | stale/old result rejected | no (`0`) | PASS | runtime session guard + source chain |
| I. local-file alignment under Music | local file; live source irrelevant | n/a | n/a | local path only | no live capture | none | outside A0 | outside A0 | PASS | exact production source trace |
| J. real ScreenCaptureKit / external player | actual Spotify or Music | not run | not run | not run | not run | not run | not run | not run | NOT_RUN | explicit boundary |

The runtime cases use the production `AutomaticLiveCaptureSourceGate` and
`AutomaticLiveCaptureSessionGuard`. The async startup ordering, observer
installation, and rechecks are separately supported by exact source-chain
checks and Debug/Release compilation; no real ScreenCaptureKit event was
pretended to have run.

## Commands and exit codes

All commands below were run from `/Users/apple/backup/sptifylyrics`.

| command | exit | source / test identity |
|---|---:|---|
| initial RED `swiftc -parse-as-library` of `PlaybackProvider.swift` + A0 contract | non-zero | expected pre-implementation missing gate/context/guard symbols |
| `bash Tests/a0_capture_source_containment_contract.sh` | `0` | production source gate, stream/sample generation guard, startup ordering, generation-matched handoff, source-chain checks; output contained two PASS lines (runtime and shell) |
| `bash Tests/automatic_alignment_trigger_contract.sh` | `0` | automatic trigger path |
| `bash Tests/automatic_alignment_disabled_contract.sh` | `0` | automatic switch remains opt-in |
| `bash Tests/automatic_alignment_product_path_contract.sh` | `0` | Release-reachable automatic product path |
| `bash Tests/automatic_alignment_track_change_contract.sh` | `0` | existing track invalidation contract |
| `bash Tests/automatic_alignment_complete_adopt_contract.sh` | `0` | existing completion/adopt path |
| `bash Tests/assist_report_handoff_contract.sh` | `0` | generation-owned handoff consumer |
| `bash Tests/stale_report_rejection_contract.sh` | `0` | stale report rejection |
| `bash Tests/s2_live_capture_contract.sh` | `0` | existing S2 source/continuity contract |
| `bash Tests/spotify_connection_contract.sh` | `0` | Spotify provider snapshot provenance |
| `bash Tests/apple_music_provider_contract.sh` | `133` | unexpected environment failure: `/System/Applications/Music.app` is absent, so the existing fake-runner test exits at its ready snapshot precondition; not bypassed or rewritten |
| `xcodebuild -project SpotifyLyrics.xcodeproj -scheme SpotifyLyrics -configuration Debug -derivedDataPath /tmp/spotifylyrics-a0-final-debug-deriveddata CODE_SIGNING_ALLOWED=NO build` | `0` | final production Debug compile/build after generation fix; warnings only |
| `xcodebuild -project SpotifyLyrics.xcodeproj -scheme SpotifyLyrics -configuration Release -derivedDataPath /tmp/spotifylyrics-a0-final-release-deriveddata CODE_SIGNING_ALLOWED=NO build` | `0` | final production Release compile/build after generation fix; warnings only |
| `git diff --check` | `0` | whitespace check |

The A0 contract was intentionally extended after review found the startup and
late-sample races. Its pre-fix extension failed at the missing `startGuard`
source boundary (exit `1`); after the startup, handoff, sample-generation,
and DEBUG-hook fixes it passed. Full `Tests` were not run.

## Native and external capture boundary

Not run:

- actual Spotify or Music playback;
- real ScreenCaptureKit discovery, stream, audio sample, or permission flow;
- real automatic alignment/ASR/model execution;
- formal SQLite, Keychain, network lyrics, recording, or user data.

The only verified capture effects are fake counters in the isolated contract.
Therefore `A0_AUTOMATED_VERIFIED` does not mean real player capture was
accepted. The external/user verification state is explicitly
`USER_VERIFICATION_REQUIRED / NOT_RUN`.

## Unexpected failures and skipped items

Unexpected:

- `Tests/apple_music_provider_contract.sh` exits `133` because the current
  host does not contain `/System/Applications/Music.app`. The source identity
  is still statically verified on every Apple Music snapshot path, and the
  production gate's `.appleMusic` runtime fixture proves fail-closed behavior
  without touching the formal app.
- Xcode emitted existing/known warnings for Sendable isolation, deprecated
  AVFoundation APIs, unused locals, and absent AppIntents metadata. Both
  configurations built successfully.

Skipped by authorization: real external capture, actual Spotify/Music,
formal DB/Keychain, full test suite, A1/H1, aligner/quality/ASR changes, and
release/push/PR actions.

## Final Git state

The production commits and the documentation commit are local only; no push
was performed. The three `PROJECT_FULL_AUDIT_*.md` files remain untracked and
untouched.
The final working tree contains no production source diff; any intentional
untracked audit files remain outside the A0 commit allowlist.

Production commit:

```text
bff4ed86ce48004081035e01678e0ddb89ae16a1
fix: contain automatic capture to supported playback sources

e775f39702361dff9dba7894e746927c660c257b
fix: bind capture handoff to active source generation
```

The documentation commit is a separate docs-only local commit created after
this report and `docs/STATUS.md` were staged; it contains no production files.
Its SHA is returned in the final task handoff rather than amended into its own
report.

## Next batch

Only **H1 — Hash Domain Boundary Repair** is next. A0 does not begin H1 or
any later batch.

## 2026-09-25 copy and Release-reachability follow-up

This is a narrow follow-up to the already automated-verified A0 batch, not a
new capture implementation or a real-capture acceptance. It corrects product
copy and comments that understated the existing Release path and its temporary
audio files.

### Source and test identity

```text
formal project root: /Users/apple/backup/sptifylyrics
protected formal-root checkout: codex/h1-hash-domain-boundary @ c062cfe371a2fcab3b1569888a6da35646627f0e
three PROJECT_FULL_AUDIT_*.md files: preserved, untracked, not edited
follow-up base: local main @ 87eade3314a595f06adeec7a0a8029790f44756e
follow-up branch: codex/a0-capture-source-verification
production/test source commit: 1f5389854dc63907cc79cf24ec46c4d549a787f3
upstream: none configured; no push performed
```

The selected source was the main-derived A0 line, not the formal-root H1
checkout. The unrelated H1 source-hash argument difference was not copied into
this branch. H1 was not entered or modified.

### Finding and before/after evidence

- The pre-existing source gate was correct and remains unchanged. The settings
  default remains `false`; automatic live capture remains restricted to an
  identified, ready Spotify Desktop source before discovery.
- The actual Release automatic job passes `runPartialAlignment: true` to
  `LiveCaptureCoordinator`; the coordinator invokes
  `SegmentPartialAlignmentPipeline.align`, which resolves
  `SpeechEngineRegistry`. Those product files compile in Release and are not
  file-level `#if DEBUG` implementations. Only diagnostic menus/hooks are
  Debug-only. Comments calling the candidate, pipeline, or optional Whisper
  engine Debug-only were inaccurate and are corrected.
- The capture coordinator stores temporary WAV segments under the system
  temporary directory. Normal job completion cleans the session directory;
  startup also attempts to scavenge leftovers. This is not a claim that every
  failure/crash guarantees cleanup. Copy now says temporary local WAV segments
  are used and cleanup is attempted; unsupported “no files saved/exported” and
  “not uploaded” claims were removed. No upload behavior was added or tested.
- Local-file alignment is separate from live capture and remains independent
  of whether Spotify or Music is the active playback source. Its prompts no
  longer incorrectly require a Spotify song/recording or imply that every
  selected file must come from Spotify.
- Before changing copy, the new copy contract failed with exit `1` because the
  permission text denied files even though the Release path writes temporary
  WAV segments. A second new Release-reachability assertion failed with exit
  `1` on the stale “Debug-only PartialAlignmentCandidate” comment. After the
  copy and comment corrections both assertions pass. These were real copy /
  source-documentation contradictions; the source-gate behavior itself was not
  failing.

### Files changed

Production copy/comments:

- `SpotifyLyrics/Info-Additions.plist`
- `SpotifyLyrics/Views/Settings/SettingsRootView.swift`
- `SpotifyLyrics/Views/Components/AssistExplainSheet.swift`
- `SpotifyLyrics/Services/PlaybackState.swift`
- `SpotifyLyrics/Capture/SegmentPartialAlignmentPipeline.swift`
- `SpotifyLyrics/Capture/PartialAlignmentModels.swift`
- `SpotifyLyrics/Capture/SpeechEngine.swift`
- `SpotifyLyrics/Capture/WhisperCLISpeechEngine.swift`

Focused contract:

- `Tests/a0_capture_source_containment_contract.sh`

No gate, provider, alignment algorithm, ASR selection behavior, automatic
default, persistence, schema, or database path changed. The focused contracts
exercise the production source gate/session guard with fake external effects
and static release-path/copy assertions. They do not open a user database.
This follow-up adds no database write; no repository save path is invoked.

### Fresh verification

All commands below ran from the follow-up worktree at the production/test
source commit above. Each listed contract and validation exited `0`:

```text
bash Tests/a0_capture_source_containment_contract.sh
bash Tests/automatic_alignment_trigger_contract.sh
bash Tests/automatic_alignment_disabled_contract.sh
bash Tests/automatic_alignment_product_path_contract.sh
bash Tests/automatic_alignment_track_change_contract.sh
bash Tests/automatic_alignment_complete_adopt_contract.sh
bash Tests/assist_report_handoff_contract.sh
bash Tests/stale_report_rejection_contract.sh
bash Tests/local_alignment_window_contract.sh
plutil -lint SpotifyLyrics/Info-Additions.plist
git diff --check && git diff --cached --check
```

Fresh isolated builds both exited `0` and ended with `** BUILD SUCCEEDED **`:

```text
xcodebuild -project SpotifyLyrics.xcodeproj -scheme SpotifyLyrics -configuration Debug -derivedDataPath /tmp/spotifylyrics-a0-copy-verify-debug-20260925 CODE_SIGNING_ALLOWED=NO build
xcodebuild -project SpotifyLyrics.xcodeproj -scheme SpotifyLyrics -configuration Release -derivedDataPath /tmp/spotifylyrics-a0-copy-verify-release-20260925 CODE_SIGNING_ALLOWED=NO build
```

The builds emitted existing warning classes: Swift actor/Sendable diagnostics,
deprecated AVFoundation/Speech APIs, unused locals, and skipped AppIntents
metadata because the target does not depend on AppIntents. No production logic
change was made to address unrelated warnings. Release compilation verifies
the partial-alignment and speech-engine path is compiled; it does not prove
real capture, permission, cleanup under crash, or provider/network behavior.

### Not run, side effects, and rollback

- Real Spotify/Music playback, ScreenCaptureKit discovery/capture, microphone,
  automatic alignment/ASR, App launch, formal SQLite, Keychain, network lyrics,
  AI, and user settings were not accessed. Real capture remains
  `USER_VERIFICATION_REQUIRED / NOT_RUN`.
- The previously recorded `Tests/apple_music_provider_contract.sh` host failure
  remains exit `133` because `/System/Applications/Music.app` is absent; it was
  not rerun or bypassed.
- Temporary build products are under `/tmp`. This follow-up was not pushed,
  merged, tagged, or released. Obsidian README/Decisions received only the
  accurate temporary-WAV fact; the newer Nightly Handoff pointer was preserved.
- Rollback is limited to reverting production commit
  `1f5389854dc63907cc79cf24ec46c4d549a787f3` and the separate documentation
  commit identified in the final handoff. Reverting this copy correction would
  restore misleading Debug-only/no-audio-file wording while the existing
  Release path remains. The original A0 source-gate commits are not part of
  this rollback.
