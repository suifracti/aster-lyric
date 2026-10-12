# C1 — Playback / Presentation Semantic Isolation

- `batch_id`: `C1`
- `base_head`: `0d75eeb80842126e12e98de064d67f3d8a5c01f8`
- `validated_production_commit`: `b95ebd1636ff0d8e847390f608886e18484a30a9`
- `branch`: `main`
- `release identity`: formal GitHub Release `v0.1.2` (`6528be3103f75fd4f63757855b9d61cd30f757d8`)
- `result`: `C1_AUTOMATED_VERIFIED / USER_EXTERNAL_PENDING`
- `native input`: `NATIVE_INPUT_PARTIAL`

## Starting state

The actual C1 start was the D0 checkout on `main`:

```text
HEAD 0d75eeb80842126e12e98de064d67f3d8a5c01f8
branch main
upstream origin/main; main ahead by 1 commit
tracked diff: empty
staged diff: empty
untracked: PROJECT_FULL_AUDIT_2026-09-22.md
           PROJECT_FULL_AUDIT_ASTRA_2026-09-22.md
           PROJECT_FULL_AUDIT_GROK47_2026-09-22.md
```

The three audit reports were preserved and were not staged. No reset, clean,
stash, restore, formal user database, Keychain, Spotify/Music control, or
formal App launch was used.

## Production changes

Only these production paths changed:

- `SpotifyLyrics/Models/Models.swift`
  - Added the explicit playback-domain `LyricsPresentationClock.playbackTime(at:)` projection.
  - Kept the canonical lyric formula as raw playback estimate plus offset, then clamp.
  - Added value-semantic `withPresentationOffset(_:)` for the subscriber's explicit emitted value.
- `SpotifyLyrics/Services/PlaybackState.swift`
  - Passed the emitted offset into the paused line-index projection instead of rereading the settings getter.
  - Added the shared displayed-lyrics identity boundary and `seekFromDisplayedLyrics` action.
- `SpotifyLyrics/Views/Components/LyricsPreferencesPopover.swift`
  - Corrected positive/negative user semantics and made the help text explicit.
- `SpotifyLyrics/Views/MainWindow/AppleMusicImmersiveV3WindowView.swift`
  - V3 rail, progress, transport labels, slider value, draft, and commit path now use playback-domain time.
  - Pointer mapping remains raw and the existing Coordinator callback remains the single commit path.
  - V3 lyric rows use the shared displayed-lyrics identity boundary.
- `SpotifyLyrics/Views/Components/LyricsCanvasView.swift`
  - Classic/shared lyric rows use the same identity boundary.

No provider seek API, polling loop, offset persistence key or persistence
scope was changed. Capsule and legacy transport consumers remain on their
existing raw `currentTime` path.

## Test changes

- `Tests/presentation_clock_contract.swift`
  - Corrected the old reverse “提前” naming and added playback/presentation,
    paused mutation and independent clamp assertions.
- `Tests/v3_seek_draft_contract.py`
  - Uses the real `LyricsPresentationClock` playback projection.
  - Executes the production draft/commit callbacks and the production
    `Coordinator.changed` callback with only a fake seek I/O recorder.
- `Tests/v3_seek_pointer_contract.py`
  - Repeats the real production pointer mapping for offsets `0`, `+2`, and
    `-2` to document that the mapping has no offset input.
- `Tests/b0_clock_offset_truth_contract.sh`
  - Updated only its C1-related source-routing assertions for the corrected
    button semantics and playback-domain V3 names; its B0 runtime cases are
    unchanged.
- `Tests/c1_offset_semantics_contract.sh`
  - Verifies button/label semantics, no offset-control seek, and the explicit
    subscriber value route.
- `Tests/c1_preview_seek_contract.py`
  - Executes the production identity guard/action body with a fake seek I/O
    recorder and checks both V3 and shared Classic wiring.

## Before / after fact table

| fact | Before C1 (B0 evidence) | After C1 |
|---|---|---|
| lyric clock | `presentation = raw anchor + elapsed + offset`, which remains canonical | unchanged; `+offset` advances lyrics and `-offset` delays lyrics |
| V3 transport display/progress | consumed presentation time | consumes `playbackTime`, without lyrics offset |
| pointer mapping | raw domain | unchanged raw domain; no global offset compensation |
| keyboard / AX slider start | presentation-domain value | playback-domain slider value |
| keyboard / AX commit | mixed presentation → raw interpretation | draft and seek target are playback-domain/raw |
| offset buttons | “提前” wrote negative; “延后” wrote positive | “提前” adds `+0.10`; “延后” adds `-0.10` |
| paused offset subscriber | could reread stale settings value in the publisher callback | uses the emitted `newOffset` explicitly |
| preview lyric row | direct seek could cross from preview B to live A | shared identity guard blocks cross-identity seek |
| Fullscreen | reused V3 but had no separate C1 transport implementation | still reuses the same V3 implementation; no Fullscreen-only compensation |

## Runtime behavior evidence

The following table records the focused contracts. “Fake” means only the
external seek I/O recorder; the clock and slider conversion under test are
production code extracted or compiled from the repository source.

| case | raw playback | offset | lyrics presentation | transport display | slider input | seek target | provider seek count | evidence / result |
|---|---:|---:|---:|---:|---:|---:|---:|---|
| 1. lyrics advance, timestamp 10 | 8 | `+2` | 10 | 8 | 8 | none | 0 | runtime clock + V3 playback projection; PASS |
| 2. lyrics delay, timestamp 10 | 12 | `-2` | 10 | 12 | 12 | none | 0 | runtime clock + V3 playback projection; PASS |
| 3. paused offset mutation | 10 → 10 | 0 → `+2` | 10 → 12 | 10 → 10 | n/a | none | 0 | runtime paused value-semantic clock + subscriber source chain; PASS |
| 4. absolute pointer / drag end | n/a | 0, `+2`, `-2` | n/a | n/a | x=150 / width=300 / duration=240 | 120 raw | 0 | runtime production pointer mapping; PASS |
| 5. keyboard / AX standalone increment | 10 | `+2` | n/a | 10 | starts 10, then 11 | 11 raw | 1 fake commit | runtime production Coordinator + draft commit; PASS |
| 6. independent clamp, lower | 0 | `-2` | 0 | 0 | n/a | none | 0 | runtime clock clamp; PASS |
| 6. independent clamp, upper | 60 | `+2` | 60 | 60 | n/a | none | 0 | runtime clock clamp; PASS |
| 7. Fullscreen shared V3 path | 10 | `+2` | 12 | 10 | raw V3 value | raw V3 target | shared fake path | runtime V3 harness + Fullscreen reuse assertions; PASS |
| 8. preview B click while live A | A position | n/a | preview document only | unchanged | n/a | none | 0 | runtime production identity guard/action; PASS |
| 8. same live identity / live lyric row | A position | n/a | live presentation | unchanged | n/a | existing row timestamp | 1 fake allowed call | runtime production identity guard/action; PASS |

Offset mutation itself has no provider call. The `1 fake commit` entries are
the expected seek caused by the explicitly tested slider or live-row action,
not by changing offset.

## Static/source-chain evidence

- `AppleMusicImmersiveV3PlaybackProgress.playbackPosition` reads
  `state.presentationClock.playbackTime(...)`, and the three V3 transport
  labels are `V3TransportClockLabel` using the same playback projection.
- `V3PlaybackInputSlider.updateNSView` writes the playback-domain binding
  value when tracking is not active. `Coordinator.changed` forwards the
  native raw value and brackets standalone keyboard/AX edits once.
- `V3PlaybackNativeSlider.pointerPosition` remains `x / width * duration`;
  it has no lyrics offset parameter or compensation.
- `PlaybackState`'s `lyricsPresentationOffset` subscriber receives
  `newOffset` and calls `syncPublishedLineIndex(... presentationOffset:
  newOffset)`. The callback does not call `seek`.
- `PlaybackState.seekFromDisplayedLyrics` compares the displayed track
  identity with `liveTrackIdentity` only while search preview is shown. V3
  and `LyricsCanvasView` both route lyric-row clicks through that method.
- `FullScreenLyricsView` embeds `AppleMusicImmersiveV3WindowView` with
  `liveOnly: true`; it does not define a second slider, clock or seek callback.
- Capsule / legacy transport still reads raw `currentTime`; lyric line
  projection remains presentation-based. This is the intended split.

## Native and external input boundary

Actually run in isolation:

- production pointer conversion function;
- production V3 draft/finish callback;
- production AppKit-compatible `Coordinator.changed` callback using an
  `NSObject` slider double with no window or player process;
- preview identity action with fake seek I/O.

Not run as native external events:

- real AppKit mouse-down / drag / mouse-up in a hosted window;
- real AppKit keyboard event delivery;
- real accessibility increment/decrement event delivery;
- real Spotify or Music seek / listening comparison.

Those events require a reliable isolated host and are not represented as
human or external-player PASS. Therefore this batch is
`NATIVE_INPUT_PARTIAL`, with `USER_EXTERNAL_PENDING` retained for V1 or a
later user-assisted check.

## Commands and exit codes

All commands were run from `/Users/apple/backup/sptifylyrics`.

| command | exit | identity / purpose |
|---|---:|---|
| `bash Tests/presentation_clock_contract.sh` | 0 | real `SpotifyLyrics/Models/Models.swift` clock |
| `python3 Tests/v3_seek_draft_contract.py` | 0 | production V3 draft/Coordinator extraction + Fullscreen reuse |
| `python3 Tests/v3_seek_pointer_contract.py` | 0 | production pointer mapping |
| `bash Tests/c1_offset_semantics_contract.sh` | 0 | offset UI and subscriber source chain |
| `python3 Tests/c1_preview_seek_contract.py` | 0 | production preview identity guard/action |
| `bash Tests/presentation_line_index_contract.sh` | 0 | existing direct line-index contract |
| `bash Tests/b0_clock_offset_truth_contract.sh` | 0 | unchanged B0 runtime clock cases plus updated C1 routing assertions |
| `xcodebuild -project SpotifyLyrics.xcodeproj -scheme SpotifyLyrics -configuration Debug -derivedDataPath /tmp/lyrics-window-macos-deriveddata CODE_SIGNING_ALLOWED=NO build` | 0 | production Debug compile/build smoke; warnings only |
| `git diff --check` | 0 | whitespace check |
| `git diff --cached --check` | 0 | pre-commit staged check |

`Tests/fullscreen_lyrics_contract.sh` was not run because B0 already recorded
its unrelated static literal/alias drift; the C1 V3 contract directly verified
Fullscreen's shared implementation and `liveOnly: true` route. Full `Tests`
were intentionally not run.

## Git / scope result

Production commit:

```text
b95ebd1636ff0d8e847390f608886e18484a30a9
fix: isolate lyrics presentation time from playback transport
```

The production commit staged only the five scoped production files and the
six directly related contracts listed above. It did not include the three
`PROJECT_FULL_AUDIT_*.md` reports, formal database data, Keychain data,
DerivedData or temporary fixtures. The documentation/evidence update is a
separate local docs-only commit after this production commit.

Final acceptance statement for this batch: `C1_AUTOMATED_VERIFIED /
USER_EXTERNAL_PENDING`, with `NATIVE_INPUT_PARTIAL`. `production source diff =
zero` after the documentation commit. The only next batch is **A0 — Capture
Source Verification & Containment**. C1 stops here; no A0 work was started.
