# Toolbar panel completeness — 2026-10-20

Input: `bad5213aa286c7e3ce938fdffff507981043c0aa`, including the `bab1afb` toolbar contract.

The hover and pinned surfaces still share `V3ToolbarQuickControls`. Restored the model picker, display layers, main font size, automatic/left/centre/right alignment, picture playback mode and background motion. Existing advanced picture/text controls are available in collapsed groups; settings still use the same controls. Library includes current source, adoption status and line count. No settings or database fields were added. The lyric bar uses 13 pt text at 30 pt height and aligns with the lyric column; feedback appears immediately above it.

## Verification

- Xcode 26.6 (17F113), arm64, Debug, `CODE_SIGNING_ALLOWED=NO`: full App build succeeded.
- `LYRICSQ_TEST_DERIVED_DATA=/tmp/lyricsq-f3-derived Scripts/test-native.sh`: **55 tests passed**, including `V3ToolbarPresentationTests` and the actual shared panel's content-height test. [Result](native-test-result.txt).
- `Scripts/ui-snapshots.sh` ran before and after with `lyric-bar lyric-notice hover-library hover-translation hover-text hover-picture pin-more pin-text`. The final run also covered `hover-search pin-translation pin-picture`.
- Measured final content sizes: search 360×194 pt, translation 360×254 pt, More 360×452 pt; text, picture and library cap at 360×520 pt and scroll. AppKit's title bar/arrow is additional window chrome.
- Rebuilt and restarted the daily development App from `/Users/apple/Library/Developer/Xcode/DerivedData/lyricsq-main/Build/Products/Debug/SpotifyLyrics.app`; confirmed the new executable path and existing song/lyrics loaded. `/Applications` was not replaced.

The screenshots use the existing native visual host with generated artwork, six synthetic lyric lines and private fixture storage. They capture native view rendering, not the desktop compositor. They do not establish real-pointer hover feel or performance; those were not retested in this change. Explanatory paragraphs remain in Settings or tooltips. The isolated tests/visual host disable Keychain; verification did not explicitly invoke models, control Spotify playback or move the mouse. The daily App was only restarted normally.

## Before / after

| Surface | Before | After |
|---|---|---|
| Text | [Before](before/hover-text-panel1.png) | [After](after/hover-text-panel1.png) |
| Translation | [Before](before/hover-translation-panel1.png) | [After](after/hover-translation-panel1.png) |
| More / content height | [Before](before/pin-more-panel1.png) | [After](after/pin-more-panel1.png) |
| Lyric bar / notice | [Before](before/lyric-notice.png) | [After](after/lyric-notice.png) |
| Library metadata | [Before](before/hover-library-panel1.png) | [After](after/hover-library-panel1.png) |
| Picture (top of scroll area) | [Before](before/hover-picture-panel1.png) | [After](after/hover-picture-panel1.png) |

The picture panel's restored playback/motion/advanced controls are below its categories and styles, beyond the initial 520 pt viewport; the top-of-panel screenshots alone do not verify these controls interactively.

Full build/test logs and all generated snapshots remain local under `/tmp/lyricsq-panel-completeness-*`. The existing untracked `.planning/` directory was preserved and excluded from this commit.
