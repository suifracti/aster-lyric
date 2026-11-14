# Native experience visual host

Builds an isolated copy of the current production sources with an alternate entry point. Uses the real V3 view, Floating and Capsule controllers with a scripted playback provider and temporary SQLite database. This is a visual/interaction fixture, not proof of real Spotify playback or release routing.

`python3 Tools/experience_visual_host/build.py` materializes/builds under `/tmp/lyrics-experience-visual-host`. Production Main.swift stays unchanged. Source hashes and invocation are recorded in the build directory. Launch with `python3 Tools/experience_visual_host/run.py` followed by arguments. The runner serves generated cover fixtures on loopback HTTP (the production artwork loader requires HTTP responses) and sets `SPOTIFYLYRICS_DATABASE_PATH` into the host directory. Host arguments: `--surface main|floating|capsule`, `--style ambient|stage|classic`, `--artwork square|portrait|landscape|bright|none`, `--width 1152 --height 720`, `--output /tmp/path.png`, optionally `--keep-open`.

App defaults use a unique test suite. No Spotify commands/network lyric providers are used. The temporary fixture SQLite DB contains only generated test tracks. Do not copy a user DB into this harness.

For floating fixtures add `--long-line --aux-layers`, `--floating-mode locked|passThrough|interactive`, or `--floating-behavior-checks`. Capsule supports `--capsule-state expanded`. Use CUA for actual pointer/hover/click checks: directly calling pointer methods does not establish real cursor location and is not sufficient hover acceptance.

Desktop matrix options: `--language chinese`, `--timed`, `--time 18`, `--desktop-mode single|double`, `--desktop-theme mint|amber|ice`, `--desktop-companion translation|next|kana|reading`, `--desktop-font 34`, and `--desktop-backdrop light`. Timed fixtures use generated per-character spans; the light backdrop is a native white backing view behind the production panel, not image postprocessing. Long-line fixtures intentionally test horizontal ribbon clipping/reveal.

Any setting: `--set key=value` (repeatable; true/false → Bool, numbers → Double, else String), for example `--set v3.wholeLineTiming.v1=true --playing true --timed`. Fixture lines (`--fixture-json`) take an optional `background` for 和声. Offscreen renders skip SwiftUI blur on some layers (四边灯带 shows a hard edge); judge soft light in the real window.
