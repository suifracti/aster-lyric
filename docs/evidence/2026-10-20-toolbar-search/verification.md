# Toolbar and local search verification — 2026-10-20

Requirements: `docs/TOOLBAR_BEHAVIOR.md` at `fe8f98a`; supersedes both earlier hover-panel designs.

Implemented separately on main:

- `fccec9d`: lyric bar, centred notices; snapshot fixture launch/capture repair.
- `c639201`: one panel view for hover and pin; rare controls in settings; all saved version types in library; 520pt content bound.
- `b75a038`: pinch, horizontal trackpad scene gesture, keyboard shortcuts sharing the bar actions.
- Search/cache implementation is the commit containing this report.

## Native evidence

Mac, Xcode Debug, `CODE_SIGNING_ALLOWED=NO`; same `Scripts/test-native.sh` configuration throughout.

- After lyric bar: 52 native checks passed.
- After unified panels: 52 native checks passed. An earlier run had two unrelated NSCache retention assertions fail; the same assertions passed in subsequent full runs without changing that code.
- After gestures: 53 native checks passed; the final affected toolbar checks also passed.
- Final search/cache run: 54 native checks passed (including toolbar, saved-library search and separate-connection invalidation). Log: `/tmp/lyricsq-search-final-tests.log`.
- Existing Japanese reading contract passed after the behavior-preserving kana lookup optimization.
- Isolated native App: Command + equals produced the visible notice `字号 20`; Command + right changed the scene to 内页; Command + left returned to the preceding family. The app was then quit.
- Physical pinch/two-finger feel: NOT_RUN. Offset's scoped actions were checked natively; its Option-arrow key delivery was not manually exercised.

Snapshots, made without real Spotify or the formal database, are retained locally:

- Before/after lyric bar: `/tmp/lyricsq-lyricbar-before`, `/tmp/lyricsq-lyricbar-after`.
- Before panel consolidation: `/tmp/lyricsq-hover-table-before`; final content/appearance: `/tmp/lyricsq-panels-final`.
- Before/after gesture wiring: `/tmp/lyricsq-panels-final`, `/tmp/lyricsq-gestures-after` (no intended visual change).
- Fixed More capture completed automatically in each final run. Fixture activation and drawing only the content view remove the launch stall/frame capture path.

These are native offscreen fixture snapshots, not proof of real-pointer hover feel or compositor translucency.

## Search timing

One Mac, Debug native test host. Read-only SQLite backup of the existing 390-song saved library into an isolated temporary database. No account, Keychain, live Spotify or model call. Online delay is deliberately controlled at 2000ms; it does not measure Spotify's real network latency.

| Measurement | Before | Final |
| --- | ---: | ---: |
| Saved query computation | 16204.7ms | 2.46ms with warm cache |
| First UI result | 18232.5ms | 2.77ms |
| First cache preparation | none | 1510.0ms once |
| Five warm queries, alternating hit/miss | none | 1.62, 2.61, 1.62, 2.43, 1.67ms |
| Refresh after changing one song | none | 18.90ms |

The old per-song SQL fetch for 397 physical keys / 86076 text rows took 174.5ms in a separate read-only SQLite probe; most prior cost was repeatedly comparing Unicode strings and converting reading text. An intermediate conversion improvement still took 1.6s. The final implementation stores canonical folded UTF-8 per version and only does substring matching for warm queries.

SQLite change counters detect local and separate-connection edits. Version/metadata signatures identify changed songs. Those songs reload their rows; unchanged version text is reused, including within a changed song. Other songs keep their cached text and library projection. Tests cover edits, separate-connection lock changes, deletion/search semantics via existing contracts, full-width/case/diacritic matching, saved readings/translations, and unchanged-song normalization counts.

No schema migration, full-text index, timeout, retry or fallback layer was added. Existing online authorization behavior remains unchanged. Local results publish before the online debounce and before online completion, through the same manager used by hover and full search.

Raw timing logs: `/tmp/lyricsq-search-measure-before.log`, `/tmp/lyricsq-search-cached-final-measurement.log`. One-off probe source: `/tmp/lyricsq-search-measurement/NativeSearchTimingProbe.swift`; it is not registered in CI. No database or private lyric contents are included in this report.

## Delivery build

Final daily Debug build succeeded (`/tmp/lyricsq-toolbar-search-daily-build.log`). The old app exited normally and the rebuilt app reopened at `/Users/apple/Library/Developer/Xcode/DerivedData/lyricsq-main/Build/Products/Debug/SpotifyLyrics.app`. Native accessibility readback showed the seven toolbar buttons and the existing song/translation content.

Executable SHA-256: `e94afd3bd87ba791cf46c1fb11fc7203a841de3e50ed1d0d165a40fbcb2ce6d7`.

Final search/More screenshots: `/tmp/lyricsq-search-final-snapshots`. Real online latency, all pointer paths and physical trackpad gestures remain unverified. Formal `/Applications` App was not replaced. The temporary real-data database copy was deleted after measurement; only logs and the one-off probe source remain locally.
