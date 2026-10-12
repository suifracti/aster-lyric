# Desktop typography cache keys

## Approved scope

Base: `4886985e9bf07e6e99c29db6814f03dda146dec0`, branch
`cloud/nightly-safe-followup`. On 2026-09-30 the user approved continuing the
previously presented complete-input cache-key repair. This is a cloud-only
working change; it does not authorize a push, merge, release or macOS app launch.

Two existing typography caches in `FloatingLyricsPresentation.swift` omit
Ruby token contents. Both keys collide when the same one-token lyric changes
its reading from `せい` to a longer reading. The font-fit key also collides for
the primary/companion pairs (`ABC-DE`, `F`) and (`ABC`, `DE-F`).

## Design

Use two immutable, equality-checkable `NSObject` keys, each wrapping a
`Hashable` input value, following the existing timed Ruby layout cache pattern.
The width key retains text, Ruby visibility, font size, outline width and the
complete optional Ruby token array. The fit key retains every fitting argument,
including separate primary/companion strings and complete Ruby tokens.

Keep the current measurement/fitting algorithm, public API and cache count
limits (width 512, fit 256). No playback, timing, persisted lyrics, source
selection or UI routes change. Clearing caches on correction would couple the
cache to selected UI paths; removing caches would restore repeated measurement.
Complete input equality covers all callers while retaining bounded reuse.

## Plan

1. Add focused regressions for changed Ruby text, surface and grouping IDs;
   separate primary/companion strings; stable A-to-B-to-A cache reuse; and every
   remaining key argument.
2. Replace only the two string keys and their `NSCache` key types.
3. Run runnable source-structure checks and whitespace/shell checks in Linux.
4. Review the full diff and preserve it without committing or publishing.

## Verification boundaries

- Production Swift compilation and the existing floating lyrics Swift contract
  require a Swift toolchain, currently unavailable here. Two same-host official
  toolchain connection attempts timed out; do not repeat or change download
  hosts to bypass the blocker.
- Cache input/equality checks can run in a Foundation-only Swift host once a
  verified toolchain is available.
- The real font-width/font-fit regressions require macOS/AppKit and remain
  unrun in Linux. Source checks and synthetic logical key-collision evidence
  are not a substitute for those results or a macOS build.
- The existing focused macOS command is
  `bash Tests/floating_lyrics_contract.sh`; a source change also needs the
  standard Debug build before a later release-ready claim.

## Cloud implementation and checks

The local working change replaces both string keys with the complete-input
classes above. `Tests/floating_lyrics_contract.swift` now covers Ruby reading,
surface and grouping-ID changes with equal token counts, all other key
arguments, the primary/companion collision, and A-to-B-to-A `NSCache` reuse.
Real font-width/font-fit assertions are guarded by `canImport(AppKit)`.

Checks actually run on 2026-09-30:

- `python3 Tests/floating_typography_cache_key_source_contract.py`: passed
  complete field, equality, call wiring, count-limit and regression-presence
  checks. Before the production edit this checker failed because the complete
  key classes were absent. This is source-structure evidence only.
- `git diff --check`: passed.
- `bash -n Tests/floating_lyrics_contract.sh`: passed shell syntax only.
- Python AST syntax check of the new source checker: passed.
- Compared both production function bodies after cache-key creation against
  `git show HEAD:SpotifyLyrics/Lyrics/FloatingLyricsPresentation.swift`: exact
  equality; measurement/fitting code is unchanged.

Swift compilation, runtime `NSCache` assertions, AppKit measurements, full
macOS Debug build, live Spotify/Music behavior and perceived stutter: **NOT
RUN**. The cloud still has neither `swiftc` nor `xcodebuild`. No download retry,
system dependency installation, credential access or player operation occurred.

Changes remain uncommitted in `cloud/nightly-safe-followup`; the base HEAD has
not changed. `docs/STATUS.md` and the formal source-of-truth documents are
untouched. Nothing has been pushed, merged or released.

A separate narrow code review found no Blocker or necessary Relevant issue.
It confirmed full key inputs, immutable hash/equality wiring, retained limits,
unchanged function signatures/measurement bodies and the intended regression
cases. That review does not establish compilation or macOS runtime correctness.
