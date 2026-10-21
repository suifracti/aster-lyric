# Main performance baseline — user-confirmed window

Source: 67b5be926b918ae8f1a36444517275d19994ad42, same as origin/main at measurement.
Production entry point unchanged. Built from git archive in /tmp/lyricsq-67b5be9-source; active dirty worktree preserved.

Build: Xcode 26.6 (17F113), macOS arm64, Debug, project defaults, CODE_SIGNING_ALLOWED=NO. BUILD SUCCEEDED.
DerivedData: /tmp/lyricsq-67b5be9-derived.
Executable: /private/tmp/lyricsq-67b5be9-derived/Build/Products/Debug/SpotifyLyrics.app/Contents/MacOS/SpotifyLyrics, PID56356.
SHA256: b6392ede6c986285c8a3ea5dfbc03e7074e38cacb36fc06c7648e380ad4b51fa.

Method: Scripts/measure-playback-resources.py, cumulative process CPU time / elapsed wall time, RSS once a second; 10s warmup, 30s sample. One core=100%.
CPU:0.100%. RSS:137.64→107.62MiB. Raw samples attached.

NOT ACCEPTED AS A LISTENING BASELINE: CUA could not inspect/capture the actual main window. ScreenCaptureKit SCStreamErrorDomain -3811, audio/video capture failed to start. Song, window dimensions, active scene, playback state and visibility are unverified. No FPS inferred. No valid candidate comparison performed.

The prior daily dev process53575 was terminated before this launch; only one lyrics test app ran. /Applications was not replaced. No direct Keychain access, Spotify UI actions, system permissions or mouse movement. No source changes or push for this measurement. Later batches remain gated on a genuine same-condition comparison. UI captures and Claude visual approval remain pending.

## Visible-window baseline, after user confirmation

The user confirmed that the main window had remained open on the cached song throughout. The screenshot API failure was a tool failure, not evidence of a closed app. Repeated the same30s capture after this confirmation, with no rebuild or settings changes. Baseline: meanCPU1.366%, RSS96.25→117.02MiB. Full raw samples: baseline-resources.json. This is a single observation, not proof against long-term memory growth. Earlier diagnostic remains separately labelled. Song/window are user-confirmed; scene dimensions and visual rendering cannot be independently captured because CUA returns-3811. No invented FPS or visual PASS.
