# UI completion for67b5be9

Completes the UI batch begun in5114261. Requirements only docs/TOOLBAR_BEHAVIOR.md at67b5be9.

- The shared scene selector now exposes its existing hover-preview switch in both toolbar presentations.
- Picture disclosure binds the already persisted v3PictureAdvancedExpanded preference (default true), so it remembers closing/reopening.
- Removed remaining custom Command/Option keyboard assignments. Standard macOS Settings Cmd-comma remains. Pinch, horizontal scene gesture and Space playback remain.
- Existing5114261 implements removal of lyric bar, offset in More, reasoning/model display names, scene alignment label/tooltip, disclosure hit area and switch mode controls.

Verification: full Debug arm64 build and58native tests passed; source is main67b5be9 plus only Main.swift/AppleMusicImmersiveV3Inspector.swift/AppleMusicImmersiveV3WindowView.swift. No pending search followup is included in the measured build. Xcode26.6 (17F113), default Debug optimization, CODE_SIGNING_ALLOWED=NO, same DerivedData as baseline. ExecutableSHA2566be4d82c71709ceacefcb94620467c08c1baba4356474002d47686f6c1152634.

Real app AX confirmed Lyric Island/main-window, Light source / kyiku, saved original+translation rows, edge playback progress17%. CUA returned a100x100 Stage Manager thumbnail even after AX Raise; attached as such, NOT a panel screenshot. Real panel screenshots and Claude visual approval remain NOT_RUN/pending. No host mouse was moved. ui-snapshots before attempt hung in existing pin:picture fixture and was stopped rather than repeatedly debugging capture tools; no successful fresh before/after screenshots claimed. Previous fixture-only16-scene/style player matrix is in2026-10-21-toolbar-ui; it is not real-app visual acceptance.

30s process observation: baseline CPU1.366%,RSS96.25→117.02MiB; candidate CPU0.000%,RSS132.14→99.53MiB. No sustained increase observed in this sample. These are paused/current-song desktop observations, not a foreground-playback stress pass; CUA visual visibility remains limited to Stage Manager thumbnail. Do not interpret lower CPU as a proved optimization. Raw candidate values include peak RSS.
