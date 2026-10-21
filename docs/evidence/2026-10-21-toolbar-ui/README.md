# Toolbar UI — 2026-10-21

Contract/input: `9ccf7c65f5f40896a483bc0195d03eca28736974`.

Removed the lyric bar and its listening shortcuts. Offset uses the existing scoped offset editor in More. Space toggles the current player on the canvas and leaves text editing alone; pinch and horizontal swipe remain. Translation uses the shared model/reasoning pickers; selected and unselected catalog models both use their display names. Model selection initializes the same saved provider directory as Settings. Alignment now says 跟随场景 with a placement tooltip. Disclosure rows use the full width and a minimum 28 pt hit area. Desktop/capsule/menu-bar modes are switches; full screen remains a separate button. No settings or database fields were added.

## Checks

- Full Debug build: `xcodebuild -project SpotifyLyrics.xcodeproj -scheme SpotifyLyrics -configuration Debug -derivedDataPath /tmp/lyricsq-f3-derived CODE_SIGNING_ALLOWED=NO build` — passed.
- Native tests: `Scripts/test-native.sh`, using the same DerivedData — **57 passed**, including Space/text focus and model + reasoning selection persisted after reopening settings. [Test result](native-tests.txt).
- Native model-menu check using the shared `TranslationProviderControls` in an isolated fixture: keyboard-selected **Fixture Alpha → Fixture Beta**, read back `fixture-beta` in the ID field and **Fixture Beta** in the picker, then selected reasoning **高**. [Actual AX readback](model-selection-ax.txt). No provider/model request was sent.
- Before/after native screenshots at 1152×720: all **8 scene/style pairs and 8 classic styles** show standard transport and progress. [Per-case record](player-screenshots.csv). No permanently missing player was reproduced in this matrix, so no speculative player-layout change was made. Hover-only and window-edge pointer interaction, small-window limits, and actual provider playback were not exercised by this matrix.
- The baseline run generated all requested PNGs, then exited 2 after the running shell script was edited. The final script passed `bash -n`, and its complete candidate screenshot run exited 0.

Screenshots use generated artwork and isolated fixture storage. Native cached-view captures can show inactive control tint; they do not measure performance or compositor glass. All scene images and complete logs remain in `/tmp/lyricsq-1021-ui-before` and `/tmp/lyricsq-1021-ui-after`.

| Change | Before | After |
|---|---|---|
| More / offset / switches | [Before](before/pin-more-panel1.png) | [After](after/pin-more-panel1.png) |
| Text / follow scene / disclosure | [Before](before/pin-text-panel1.png) | [After](after/pin-text-panel1.png) |
| Translation / reasoning | [Before](before/pin-translation-panel1.png) | [After](after/pin-translation-panel1.png) |
| Lyric bar removal / gesture notice | [Before](before/lyric-notice.png) | [After](after/lyric-notice.png) |
