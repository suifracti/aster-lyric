# Lyric Island UI implementation — 2026-10-18

## Implemented
- Eight existing theme identities preserved; distinct cover edges/composition and backgrounds, editorial poster rules, standalone colour fields for applicable themes. Pure Gaussian stays static.
- Library / Search / Adjust / More; picture/text/current-song tabs, hover temporary panel, click pin/repeat close, wide 340pt inspector, narrow independent panel. Tab choice survives moving between hosts.
- Basic cover/softness/standard-or-edge controls remain visible; detailed framing, sizes, colour, placement and text layout are folded.
- Existing live operations, candidate adoption, translation/reading workflows, editing and offset controls retained. Provider/model/reasoning/conversation setup routes to Settings, including first presentation.
- Menu, desktop and capsule use shared cached song accents; desktop lock/pass-through feedback and capsule states retain existing window geometry.
- Library, recent listening, statistics, search, comparison and four revision editors use a stable record/archive presentation. Saving revisions retains the source version.
- Existing preferences and raw IDs retained; missing atmosphere preference means off. Edge progress stays visible independently of button hover and window key status.

## Checks performed
- Main-agent review of actual native diffs, with fixes for accent propagation, light/dark accent contrast, first settings route, atmosphere layer ordering, phase wrap, native visibility notifications, sidebar overflow, basic-control placement, selected-tab persistence and a stray declaration found by compilation.
- Xcode Debug build: succeeded after integration corrections (macOS 14 deployment target retained).
- `Tests/v3_inspector_navigation_contract.py`: production hover/pin/other-hover/repeat-close/switch/dismiss transitions passed.
- `Tests/v3_toolbar_popover_event_contract.sh`: native anchor pass-through, outside dismissal and Escape passed without sending system input.
- HTML/inline-JS source checks passed; no external assets. Browser rendering was not verified.
- Native isolated atmosphere sample: fixed synthetic palette, 1024×640, warm-up before each 5s interval. Process CPU time: static 0.000515s; dynamic 0.398109s (about 8% of one CPU core). Actual native frame inspected. This is not a whole-app GPU, lyric-scroll or drag benchmark; it does not establish that previous application lag is solved.

## Design and evidence
`index.html` is an interactive design demonstrator, with original cover artwork, fictional multilingual text, all eight scenes and thirteen surfaces. It simulates playback and version actions; it is not the running application. `DESIGN.md` records the implementation baseline and migration destinations.

Build/package/runtime evidence lives in `/private/tmp/lyricsq-island-ui-20261018/`. Current running identity, actual-window observations and remaining visual acceptance are recorded in the project's Obsidian Handoff after launch. Existing eleven local deletions and `.planning/` are retained, excluded from commits. No production database, Keychain, formal application installation or additional model requests are changed by this UI work.
