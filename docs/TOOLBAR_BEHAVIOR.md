# Main-window toolbar behaviour

This file is the contract for the toolbar and its panels. Claude decides the UI; GPT implements it (user decision, 2026-10-20).

- **Code:** `SpotifyLyrics/Views/MainWindow/V3ToolbarModel.swift`
- **Checks:** `V3ToolbarPresentationTests` (via `Tests/v3_toolbar_model_contract.sh`)
- **Screenshots:** `Scripts/ui-snapshots.sh`

To change a rule, update this file and the tests first, and attach before/after snapshots. Keep the tests to the rules written here.

## Design principle (user, 2026-10-21)
**Minimal while listening, yet beautiful and complete.**
- **What shows:** at rest, the screen shows only lyrics and the picture.
- **Everything else** appears when the pointer or a key asks for it, and leaves smoothly.
- **Folding, not cutting:** minimal never means fewer features. Features are folded away, never removed, and each stays where people expect it.
- **Beauty is part of the requirement:** no popping, one control style, and colours from the cover.
- **Tie-breaker:** when a choice is unclear, choose the one that keeps the listening screen calmer without losing anything.

## Buttons
Order: 歌词库 · 搜索 · 译文 · 文字 · 画面 · 更多 | 设置. 设置 sits at the far right, after a divider.

The old 调整 button and its tabs are gone. Each panel has one job and no tabs.

## Visibility
- **Outside the window:** the toolbar is hidden.
- **Pointer inside the window:** the toolbar is faint (0.32 opacity).
- **Near the top edge, or any panel open:** the toolbar is fully shown.
- Buttons never move between these levels.

## Gestures and keys
There is no lyric bar; the user removed it on 2026-10-21. Every setting lives in its panel.

| Action | How |
|---|---|
| Font size | Pinch on the lyrics |
| Scene | Two-finger swipe left or right on the canvas, which moves to the previous or next of the 4 categories |
| Play / pause | **Space**, sent to the current player. It works only when no text field has focus. |
| Previous / next track | **A** / **D** |
| Like the song | **S** adds the current song to Spotify 「已点赞的歌曲」 (details below) |
| Blur presets | The **/** key (no Shift) cycles 背景封面模糊 through 0 → 25 → 50 → 75 → 100%, then back to 0. Pick the next preset above the current value. |
| Fine blur | **,** / **.** (the **<** / **>** keys): −5% / +5% of 背景封面模糊, from 0 to 100%; holding repeats. The notice shows the value, for example 「模糊 35%」. It is the same value as the 画面 panel slider. |
| Focus mode | **F** toggles it (see below) |
| Lyrics are early | **Z** moves the timeline up: offset −0.1 s per press |
| Lyrics are late | **C** moves the timeline down: offset +0.1 s per press |
| Reset offset | **X** sets the current song's offset back to 0 |
| Show all keys | **Shift + /** (that is **?**) opens a centred list of every key; **?** again or **Esc** closes it. Tell it apart from / by the Shift flag, not only by the character. |

- A gesture change shows a small notice at the bottom of the lyrics column, such as 「字号 22」 or 「封面」, which fades after about 1 s.
- **Letter keys** are case-insensitive and work only while the main window is focused and no text field has focus. They are not global hot keys.
- **Every key press shows the same small notice**, for example 「上一首」, 「偏移 −0.3s」, 「已加入喜欢」 or 「已在喜欢中」.
- **The [ and ] keys are not used.**
- **Holding Z or C repeats.** The offset is the same per-song offset as in 更多.
- **S, liking the song:**
  - The app only checks, adds and removes the current track in Liked Songs. Spotify scopes: `user-library-read` and `user-library-modify`, nothing else.
  - **Not liked:** S adds it and shows 「已加入喜欢」.
  - **Already liked:** S shows 「已在喜欢中 · 再按 S 移除」. A second S within 3 s removes it and shows 「已移出喜欢」.
  - **Spotify not connected, or missing permission:** show 「需要连接 Spotify」 with a button that opens the connection settings.
  - **Apple Music:** the same flow, using its favourite flag.
- **Heart button:** the player (transport) has a heart. It is filled when the song is liked or favourited. Clicking it adds the song, or, when it is already liked, removes it. Same notices as S.
- **No Command / Option shortcuts.** Each panel lists its keys in tooltips, written as plain letters.

## Listening extras (user-approved 2026-10-21)
**Scope:** lyricsQ is for listening to music and singing along. Don't add learning, sharing or social features.

- **Cover colours:** take the accent colour from the cover's palette and use it for the current-line highlight, the progress bar and the panel accent. It changes with each song. If the cover has almost no colour (saturation below about 0.08), use the current neutral colour. Reuse `LyricIslandArtworkColors`.
- **Night dimming:** a single switch, 「夜间柔和」, in 画面 → 更多画面选项, default off. Between 20:00 and 07:00 it lowers canvas brightness by 15% and caps 背景动态 at 轻柔. There are no other settings and no numbers for the user to set.
- **Focus mode:** **F** hides the toolbar, the title and the player, leaving only the lyrics and the background. **F** again or **Esc** brings them back. While it is on, the pointer does not bring the toolbar back.
- **Shuffle and repeat:** two small buttons in the player.
  - **Repeat** cycles 关 → 列表循环 → 单曲循环. It uses the usual repeat icon, plus a small "1" for 单曲循环, and shows a notice.
  - **Apple Music:** use its own repeat setting (off / all / one).
  - **Spotify:** Read modes from `GET /me/player`; write repeat using `PUT /me/player/repeat` (off/context/track) and shuffle using `PUT /me/player/shuffle`, then read once and display the returned state. Request `user-modify-playback-state` through the existing authorization flow. Only missing authorization or HTTP 403 uses desktop scripts; that fallback cycles 关 → 列表循环 → 关. No simulated end-of-track seek. Smart shuffle remains read-only.
  - **State:** read the player's real state, never the desktop script's echo. Spotify reads `GET /me/player` with `user-read-playback-state`; Apple Music reads its own `shuffle enabled` and `song repeat`. When the state cannot be read (no account, nothing playing, 204), the button shows 「未知」 instead of looking off, and the first click turns the mode on (repeat goes to 列表循环). After that first click the state is known: a click advances from the last known state (including the one the app just wrote), and a refresh that cannot read the player keeps that last operation state for the next click. That kept value records the last operation, not a fresh reading. Without this, every click restarted the cycle at its first step, so 循环 stayed on 列表循环 forever and 随机 could never be turned off.
  - **Smart Shuffle:** shown as 「智能随机」 with a ✦ badge when Spotify reports `smart_shuffle`. Spotify returns that field from `GET /me/player` but does not list it in the published response table, so it stays optional: without it the app shows ordinary shuffle only. The app never turns Smart Shuffle on; clicking while it is on turns shuffle off.
  - **Connecting:** the mode buttons need the existing Spotify account connection for state reads. 设置 → 播放 → Spotify shows 桌面播放 and 账号授权; 连接 Spotify runs the existing authorization, 补充授权 appears when the stored token lacks a scope, and the Client ID lives under 开发者配置. No separate authorization system exists. The token lives in one login-keychain item (`com.spotifylyrics.spotify-oauth.v3`); save, load and delete share that namespace, so a relaunch after a rebuild reads the account again. The data protection keychain is not used because local ad-hoc builds have no application-identifier entitlement.
- **Loop one line:** right-click a lyric line → 「循环这一句」. Playback jumps back to that line's start each time it reaches the next line. The looped line has a small loop mark. Clicking the mark, right-click → 「取消循环」, or a track change stops the loop.
- **Big-line mode:** a 「大字模式」 switch in the 文字 panel. The current line is drawn at about twice the size; the other lines are 60% size and dimmed. It is meant for singing along from a distance.
- **Click to seek** already exists; keep it unchanged.
- **Intro and break countdown:** when no vocal is due for 4 s or more (intro or instrumental break), show three dots where the next line will appear. They light up in turn and are full when the line starts, so the singer knows when to come in. Reuse the existing 前奏 detection, and draw only this small view, not the whole lyric list, each frame.
- **Reading-only / translation-only:** the 文字 panel's 显示 row gets a single control: 全部 / 只看读音 / 只看译文. 只看读音 shows the reading in the main line size. It only changes the existing 原文 / 译文 / 读音 switches together; it adds no new storage beyond them.

## Panels
- **One panel per button.** Hover shows it temporarily; click pins it. **Hover and pin show the same content.**
- **Each panel fits on one screen**, max height 520 pt. **The panel's height fits its content**, so there is no empty space below it.
- **No explanatory paragraphs.** Use an ⓘ tooltip when a control needs one.
- **Each panel holds everything about its topic.**
- **Disclosure rows** such as 「更多文字选项」 are clickable across their full width and at least 28 pt tall.
- **On/off settings use the same switch style everywhere.** Actions such as 全屏 are buttons, set apart from the switches.
- **Rarely used settings live in the settings window**, not in toolbar panels.

| Button | Panel |
|---|---|
| 歌词库 | This song's versions grouped by type (原词 / 译文 / 读音 / 时间轴). The adopted one is checked; click another to adopt it. Each row shows source, date and line count. 「打开歌词库」 is at the bottom. |
| 搜索 | A search field prefilled with the current song. Results are grouped as **本地已存** and **在线**. Each row shows a cover thumbnail, title · artist · album, duration, and badges for what is saved (词 / 译 / 读). The adopted one is checked. A row's status reads 「已采用」, 「点击采用」 or 「搜索中…」. Up and down arrows move the selection and Return adopts it. Top 5 per group, plus 「全部结果」, which opens the full search. |
| 译文 | 翻译 / 读音. **AI model picker** and **思考强度 picker** (one row each). Both show display names; the current model is shown the same way as the others in the list. Choosing another model must switch and persist. The saved-translation version picker. 「翻译整首」 and 「重新翻译」. 新歌词自动翻译. 并排对比. |
| 文字 | **显示: 原文 / 译文 / 读音.** **原文与译文 size.** **对齐: 跟随场景 / 左 / 中 / 右.** 「跟随场景」 replaces 「自动」; its tooltip says which side the current scene uses. 清晰度 (关闭 / 文字阴影 / 柔和光晕, default 关闭). 罗马音 / 拼音. 注音排版. 读音与辅助字 size. 假名 size. The ⓘ sits on the same line as its label. |
| 画面 | The 4 categories from `V3SceneFamily`. Below them, the selected category's style list, including 经典版. 背景封面模糊. 显示歌曲缩略图 / 前景封面. **播放呈现 (标准播放栏 / 窗口边缘).** **背景动态 (关闭 / 轻柔 / 鲜明).** A 「悬停预览」 switch next to the scene heading (user request 2026-10-18). An 「更多画面选项」 section, **expanded by default, which remembers whether it was open,** holding the rest of the picture controls (取景方式, 前景封面尺寸与位置, 背景缩放, 悬停时显示播放信息). |
| 更多 | 当前歌词偏移: −0.1s, a value field, +0.1s, 归零. Window modes as **switches**: 桌面歌词, 顶部胶囊, 菜单栏歌词. 全屏歌词 is a button. 桌面歌词交互. 恢复歌词时间. |
| 设置 | No panel; it opens settings. |

**Nothing is removed.** Every control that was in a toolbar panel before 2026-10-20 stays reachable from its panel, folding into a collapsed section where needed. The settings window may show them as well.

**Moved to the settings window:** 翻译服务 login and connection details (the model picker stays in 译文), 恢复此风格的默认值, and every explanatory paragraph.

**Removed from 更多:** 「歌词版本」, which 歌词库 now covers.

## Hover and pin rules
These apply to 歌词库, 搜索, 译文, 文字, 画面 and 更多.

- **A hover panel stays open while** the pointer is on the button, on the panel, or in a native menu inside it.
- **It closes** 180 ms after the pointer leaves.
- **Clicking pins a panel** in a separate tool window. Every click visibly changes something:

| Click | When | Result |
|---|---|---|
| A panel button | Nothing pinned, or only hovering it | Pin it |
| A panel button | That panel is already pinned | Close it |
| A panel button | Another panel is pinned | Switch to this one |
| 歌词库 or 搜索 | — | Open their window and close all panels |
| 设置 | — | Open their window and close all panels |

- **While pinned:** hovering other buttons does nothing.
- **Highlighting:** only the pinned panel's button is lit.
- **Escape** and the close button close all panels.
- **An outside click** closes only the hover panel, never a pinned one.

## Clicks must always land
A click on a toolbar button counts no matter which path delivers it. Each path calls `V3ToolbarModel.click`:
- the SwiftUI button;
- the first-click catcher, used when the window is not key or the app is inactive;
- the hover popover's event monitor, used when the popover window overlaps the button.

Clicks that land on the popover's transparent arrow or shadow area are forwarded to the toolbar underneath.

## Placement of the pinned window
- **Fits beside the main window on the right:** place it outside, 12 pt from the window.
- **Doesn't fit:** place it against the screen's right edge.
- **Never** to the left of the window.

## Appearance
- **Listening canvas:** always dark.
- **Hover panel:** frosted glass that follows the macOS light or dark setting (Round 8).
- **Pinned panel:** follows the system's light or dark setting.

## Priority
- **Every scene and style shows the player** (transport and progress) according to 播放呈现; none hides it permanently.
- An open panel takes priority over the toolbar.
- The toolbar takes priority over the window-edge controls.
- While the pointer is in the toolbar area or any panel is open, the edge play buttons stay hidden and only the progress rail shows.

## Constraints carried over from earlier decisions (Obsidian Decisions, 2026-10-18/19)
- **Scene merging (R3):**
  - Entries may be merged, but the liked effects must stay one click away: 原版环境光, 经典放大模糊 and 完整羽化.
  - Keep the 8 renderer raw IDs and their separate preferences.
  - The `flowingField + classic` path keeps its own drawing branch. Merging changes entries, never rendering.
- **Performance:**
  - Before merging, every UI batch gets a 30 s CPU/RSS check: same build, same song, same window, against the previous batch.
  - A repeatable rise blocks the merge.
  - Animations update only their own small views.

## Side drawer (trial, after the current round)
**Purpose:** pages that don't change the picture open inside the app instead of in separate windows.

- **Position:** it slides in from the **left** and covers the cover/artwork side.
  - The lyrics column does not move or reflow and keeps scrolling.
  - In layouts where lyrics are on the left, it slides in from the right instead, always on the side away from the lyrics.
- **Opening:** a thin handle shows when the pointer reaches that edge. Hover or click opens the drawer.
- **Closing:** Esc, clicking outside, or moving the pointer away for 1 s closes it.
- **Tabs, trial scope:** 歌词库 and 搜索 only, with the same content as their full windows' main views. Reuse those views; don't fork them.
- **Not included:**
  - Panels that change the picture (文字, 画面) stay as floating or pinned panels outside the window.
  - Deep settings stay in the settings window.
- **Width:** 360 pt, or 40% of the window if that is smaller.
- **Background:** dark frosted glass, like hover panels.
- **Trial:** the user tries it for a few days. If it's kept, 译文, 更多 and common settings move in next. If it isn't, it is removed.

## Edge player and progress rail (user feedback 2026-10-21)
**Following near the toolbar:**
- The edge player keeps following the pointer near the toolbar.
- The toolbar hides it only inside the toolbar's own rectangle plus 8 pt.
- When the pointer's nearest edge point falls in that area, the player sits at the closest free point: on the top edge just left of the toolbar, or on the right edge just below it.
- The toolbar and edge player must never overlap.

**Seeking on the progress rail:**
- **Hit area:** the clickable band is 14 pt thick along the rail. The visible line stays thin.
- **Hover:** when the pointer is within that band, the line thickens to 4 pt, and a small time label follows the pointer, for example 「1:23」, showing where a click would seek.
- **Seeking:** click seeks. Dragging scrubs with the label updating and seeks on release; while dragging, the lyrics do not jump.
- **Accent colour:** the rail and the label use the cover accent once 封面配色 exists.

**Motion (no popping):**
- **Appear:** fade in and scale from 0.92 to 1 over about 180 ms (ease-out). **Disappear:** fade out over about 140 ms.
- **Following:** while the player is visible, it glides to its new edge position with a soft spring (response about 0.3 s, no bounce) instead of jumping. Corner turns follow the same spring.
- **Edge switch:** moving to a different edge cross-fades: the old position fades out while the new one fades in. It never slides through the canvas.
- **Hide delay:** keep the existing hide timing, but end it with the fade instead of a cut.
- **Reduce Motion:** when the system has Reduce Motion on, use fades only, with no scale or glide.
- **Performance:** animate only the player view's position and opacity. Don't drive the lyrics or backdrop, and don't add a per-frame timer.

**Player information:** the edge player pill shows the elapsed and total time in small text, for example 「0:35 / 3:13」, beside the play controls. Nothing else is added.

## Add to playlist (like Spotify's 「新增至播放清單」)
**Entry (changed 2026-10-23; the user found the old "heart opens the picker once liked" rule undiscoverable):**
- **Heart:** only like / unlike. One click toggles, with the same notices as S. It never opens the picker.
- **「添加到歌单」 button:** a separate button right after the heart in the player pill, SF Symbol `text.badge.plus`, tooltip 「添加到歌单」. Clicking it opens the picker. Shown only when playlists are available (`canPickPlaylists`).
- **Right-click on the heart:** removed; the button replaces it.
- **S** stays as defined above.

**Picker** (a popover from the 「添加到歌单」 button, in the hover-panel style):
- **Top:** a search field, 「尋找播放清單」, which filters by name.
- **Next:** 「建立新清單」, which creates a private playlist named after what you typed (or 「新清單」) and adds the song.
- **List:**
  - The first row is always 「已按讚的歌曲」 (Liked Songs).
  - Then the user's own and collaborative playlists, most recently updated first.
  - Each row shows cover, name and track count.
- **Checkmarks:**
  - A check means the song is already in that playlist; tapping toggles add and remove at once.
  - Checks are loaded lazily for the visible rows and cached per playlist `snapshot_id`, so reopening is instant. Don't scan every playlist up front.
- **Done / 取消:** closes it. Changes take effect immediately, so there is nothing to confirm.

**Limits:**
- Spotify's Web API does not expose playlist folders, so the list is flat. Don't fake folders.
- Spotify scopes, added with the library ones: `playlist-read-private`, `playlist-read-collaborative`, `playlist-modify-private`, `playlist-modify-public`. The user re-connects once.
- **Apple Music:** the same picker using its local playlists, with no 「已按讚的歌曲」 row. Its favourite is the heart.
- **Errors:** a short notice such as 「添加失败，稍后再试」. No retry queue.


## Scene merge (R3, user-approved 2026-10-21)
Based on real-song screenshots of Light source, 花の塔 and Runa: two bright covers and one dark.

**Entries:** 16 become 4 categories with 9 styles. The separate 「经典版」 group is removed.

| Category | Styles |
|---|---|
| 环境光 | 原版环境光 · 柔和光晕 · 独立色场 · 柔光羽化 |
| 封面 | 封面 (switch: 静止 / 流动) · 舞台 |
| 内页 | 内页 · 唱片卡 |
| 专注 | 专注 |

**Where each old entry goes:**
- **经典·原版环境光 → 原版环境光.** It was pixel-identical in all three songs.
- **经典·柔光羽化 → 柔光羽化.**
- **经典·封面柔焦 → 原版环境光.** Add a 「背景明暗」 slider to 原版环境光 so the lighter look stays reachable.
- **经典·柔和光晕 and 经典·纯高斯 → 柔和光晕.**
- **封面柔焦 and 纯高斯 → 封面.** The 静止 / 流动 switch picks the existing renderer.
- **完整舞台 and 经典·封面舞台 → 舞台.** The existing 对齐 setting decides which side the lyrics sit on.
- **纯净歌词 and 经典·纯净歌词 → 专注.** The existing 显示歌曲缩略图 switch covers the difference.
- **经典·封面海报 → 唱片卡.**

**Rules:**
- Merging changes entries only. Every renderer, its raw ID and its separate preferences stay.
- `flowingField + classic` keeps its own drawing branch.
- Migrate users on removed entries to the merged entry that draws the same picture, and keep their parameters.

**Fixes found in the screenshots:**
- **Mini player time** (封面, 内页, 专注): the time wraps, e.g. 「00:2 / 0 03:05」. Show it on one line, using tabular digits.
- **Mini player caption:** drop 「正在播放 / 已暂停」. The play/pause button already shows the state, and in the 460pt 内页 footer the caption was squeezed into a vertical 「已…」.
- **唱片卡 header:** it still says 「LYRIC ISLAND · LISTENING EDITION」. Change it to 「ASTER · LYRIC · LISTENING EDITION」.
- **内页:** remove the explanatory text under the cover (「点击已同步的歌词可跳转……」).
- **Reading line:** hide it when the reading is identical to the original line, as with all-kana lines.

**Bright-cover readability:**
- **When:** in 封面 (both 静止 and 流动) and 舞台, if the cover is bright (average luminance above about 0.6) and 清晰度 is 关闭.
- **What:** automatically apply 文字阴影.
- **Strength:** a single tight glyph outline, about 2–3pt radius; no wide halo or dark fog. Shadow mode keeps the existing dim floor for non-current lines so 译文 and surrounding lines remain readable. No background plate is added.
- **Opting out:** a switch under 清晰度 in the 文字 panel, 「亮封面自动加阴影」, default on. Turning it off keeps 关闭 truly off.
- **No override:** an explicit 文字阴影 or 柔和光晕 choice is never changed.
- **Elsewhere:** other scenes and dark covers are unaffected.

## Lyrics matching and preloading (user-approved 2026-10-26)
**Spotify's playing duration is unreliable.** Spotify Desktop reports a different length for the same track on different plays: shion was reported as 150.8 s on one play and 168.0 s on another; YOU & IDOL as 201 s and 228.5 s. The suspected cause is playlist mixing or transitions.
- Matching, the 「自动选择 · 时长与 Spotify 相差 N 秒」 hint and the artist-credit lookup use the **catalog metadata fetched by Spotify track ID**: duration, full artist list and title.
- An exact track-ID match is trusted; it does not also need the playing duration to agree.
- The playing duration is used only for the progress bar.

**Preloading:**
- Setting 「提前加载下一首歌词」 in 设置 → 歌词, default on.
- When a track starts, read the Spotify queue and search lyrics for the next 2 tracks in the background, with the same rules and storage as a normal search.
- Preloading only searches lyrics; AI translation is never preloaded and runs only when the track actually plays.
- Stats lines from preloading carry `preload: true`.

## One Spotify ID, one song (user-approved 2026-10-26)
**Problem:** the stable key is `spotify-id:ID|metadata:title|artist|album|duration`. When Spotify's metadata changes, one recording splits into several keys: a different-script title, or a different reported duration (`…|201` and `…|229`). This caused 「歌词身份待确认」, lost selections and rejected translation saves.

**Rule:** a Spotify track ID identifies the song. The key format stays the same.
- When a new key appears and another key with the same Spotify ID already exists, automatically add a `track_identity_redirects` entry from the new key to the existing one. Prefer the key that holds the user's selected lyrics; otherwise use the oldest.
- Lyrics, translations, offsets and selections then follow the redirect.
- **Existing splits:** run a one-time pass that adds the same redirects. It never deletes rows, records every merge in the existing merge audit table, and backs up the database first.
- **Once the redirects work, remove the earlier one-off patches for this problem:** the translation-save "same recording" prefix check and the Spotify-ID fallback for selected lyrics. Remove them only after the tests pass.
- Tracks without a Spotify ID (Apple Music, local files) keep the current behaviour.

## Toolbar vs Settings: each control lives in one place (user-approved 2026-10-27)
**Rule:** visible effects live in the toolbar: 画面, 文字 and 译文. Settings holds connection and configuration only: playback source, accounts, startup, lyric sources and auto-alignment, preloading, AI service and keys, data, and the appearance details of the separate desktop-lyrics and menu-bar windows.

A control never appears on both sides. Where the other side used to have it, show one grey line such as 「显示开关在 工具栏 → 文字」. Clicking that line opens the panel.

| Control | Lives in | Remove from |
|---|---|---|
| 显示原文 / 译文 / 罗马音 / 拼音 | Toolbar 文字 / 译文 | Settings 歌词与翻译 and 读音; the current-song operations panel |
| 注音排版 (kana mode), 远处歌词隐藏辅助读音 | Toolbar 文字 | Settings 读音 (it keeps only the user dictionary; 假名替换 is one of the kana modes and moves with 注音排版); the current-song operations panel |
| AI 模型, 思考强度 | Toolbar 译文 | Settings AI 翻译 (it keeps service, key, endpoint and personal style) |
| 新歌词自动翻译 | Toolbar 译文 | Settings 歌词与翻译 |
| 菜单栏歌词 on/off | Toolbar 更多 | Settings 外观 (it keeps the window's appearance details) |
| 场景悬停预览 | Toolbar 画面 | Settings |
| 主窗口布局 | Toolbar 画面 | Settings |
| 播放呈现 | Toolbar 画面 | — |

**播放呈现** becomes one three-way choice: **标准播放栏 / 悬停时显示 / 窗口边缘**. It replaces the separate 「播放信息仅悬停显示」 toggle, so the choice and what the user sees always match. Migration:
- `v3EdgeProgressEnabled = true` → 窗口边缘;
- otherwise `v3PlaybackDetailsOnHover = true` → 悬停时显示;
- otherwise → 标准播放栏.

## Round 3 finishing items (user delegated decisions to Claude, 2026-10-27)
**画面 panel:**
- Blur presets are 0 / 25 / 50 / 75 / 100, the same as the `/` key cycle.
- The panel height fits its content up to 520 pt and scrolls beyond that. Nothing is clipped; 「显示歌曲缩略图」 was half cut off.
- Options that don't apply to the selected scene are hidden, not disabled.

**封面 / 舞台 lyric placement:**
- Lyric position 「自动」, the default, avoids the cover's subject.
- Run one Vision request per artwork (attention-based saliency plus face rectangles), cached by artwork URL. Compute the result in window coordinates, after the background crop.
- Place the lyrics column on the horizontal side opposite the salient centre, in the lower part of the window.
- If the subject is centred, compare the salient area in the left and right halves and use the emptier side. The column keeps its normal width; never narrow it. (Corrected 2026-10-27: bottom-centre plus a narrow column put lyrics on the subject and split lines badly.)
- The column's bottom edge stays above the player bar.
- Manual 左 / 中 / 右 always wins.
- No downloaded models; if Vision fails, fall back to the current bottom-trailing placement.

**Edge player:**
- **Vertical mode:** the time shows on two lines (elapsed over total) at 10 pt with monospaced digits, and is never truncated. Today it shows 「0:03…」.
- Every button gets the same small hover circle and the same spacing.
- 「添加到歌单」 is the same size as the heart.

**Side drawer replaced by a centred floating panel. This resolves the drawer / edge-player conflict on the left edge.**
- Clicking 歌词库 or 搜索 in the toolbar opens one centred panel.
  - Size: at most 760 × 600 pt, keeping at least 40 pt from the window edges.
  - Layout: tabs 歌词库 | 搜索 at the top, with the same content as today's drawer.
- The rest of the window dims and blurs slightly behind it.
- Esc, a click outside, or clicking the same toolbar button closes it.
- While it is open, the edge player and its hit band are hidden.
- A small 「在新窗口打开」 button opens the existing full window.
- Hover quick panels are unchanged.
- `V3SideDrawer` is removed once the panel works.

**AI translation "not refreshing":**
- The 译文 panel's model picker gets a refresh button that reloads the provider's model list, showing 「刷新中…」 and any error inline.
- 翻译整首 must show progress and then the result, or an inline error.
- Find and report the real cause; don't add retries.

## Listening extras, round 4 (user-approved 2026-10-27)
**1. Readings follow the song's language.**
- Detect the lyrics' language with the built-in `NLLanguageRecognizer`, once per lyric version.
- Remember the reading toggles (原文 / 译文 / 罗马音 / 拼音 / 注音排版) separately for 日语, 中文, 韩语 and 其他.
- When a song starts, apply the set for its language. Changing a toggle while a song plays updates that language's set.
- First run: every language starts from the user's current toggles, so nothing visibly changes until the user adjusts one.
- 文字 panel: a small caption 「当前：日语设置」 shows which set is active.

**2. Fill in missing lyrics from the library.**
- 歌词库 gets a filter 「缺歌词」 that lists tracks with no stored lyrics.
- Next to it, a 「全部补全」 button searches them one by one with the normal free-source search and auto-adopt rules.
- Show progress as 「12 / 66」. A stop button cancels.
- Never call AI translation or any paid service; manual or locked lyrics are untouched.
- Each search is logged to source-stats with `batch: true`.

**3. Sleep timer.**
- In the 更多 panel: 「睡眠定时」 with 关闭 / 15 分钟 / 30 分钟 / 60 分钟 / 本曲结束后.
- When it fires, pause playback through the existing play/pause path.
- While active, show the remaining time on that row. It resets after it fires.
- No volume fade.

**4. Current-line glow.**
- In the 文字 panel: slider 「当前句发光」 0–100%.
- The default equals today's look, so nothing changes until the user moves it.
- 0% means no glow at all. The slider affects only the current line, never other lines.

## Round 5: edge seeking, library / playlists / search panel (2026-10-27; user asked for all-at-once delivery)
**Edge player seeking.** Users kept grabbing the window-resize edge instead of the rail.
- The rail hit band moves inside the window, 6–20 pt from the edge. It is currently 0–14 pt, which overlaps macOS's resize zone.
- The edge pill gets its own short draggable progress track, beside the time in vertical mode and before it in horizontal mode, with the existing time bubble while dragging.

**Centred panel redesign: one place for 歌词库 · 搜索 · 歌单.**
- **Header row:**
  - tabs 歌词库 | 搜索 | 歌单;
  - one search field for the active tab;
  - a 「⋯」 menu holding 导出, 导入数据, 导入资产, 刷新 and 私人文件夹同步;
  - 在新窗口打开 and ×.
- **Two columns:** a compact list on the left (about 300 pt) and the selected item's detail on the right. No grey inner box.
- **歌词库 tab:**
  - **Filter chips:** 全部 · 当前歌曲 · 缺歌词 · 有译文 · 手动编辑. Selecting 缺歌词 shows 全部补全.
  - **Rows:** 44 pt high, 32 pt cover, title and artist, badges 词 N / 译 N.
  - **Right column:** that song's versions, grouped 原词 / 译文 / 读音 / 时间轴 like the hover panel, with 采用 / 预览 / 编辑.
  - Opens with the current song selected.
- **搜索 tab:** two clearly named sections.
  - **「这首歌的歌词」:** provider candidates for the current song. Each shows the source, a 逐字 / 逐行 / 纯文本 badge, the duration difference and 预览 on hover. The action is 「采用此版本」.
  - **「其他歌曲」:** library and Spotify-catalog songs. The action is 「查看歌词」, plus a ▶ that plays the song.
  - The current song appears once, not in both sections. Local results show first; online results stream in.
- **歌单 tab:**
  - **Left column:** 接下来播放 (from `/me/player/queue`), then 已点赞的歌曲, then the user's playlists (flat; Spotify gives no folders).
  - **Right column:** the selected playlist's tracks. Double-click a track, or press its ▶ (shown on row hover), to play it in that playlist's context (`PUT /me/player/play` with `context_uri` and an offset; the existing playback-write scope covers it). A 403 shows 「需要 Spotify Premium」.
  - A ✓ marks each playlist that holds the current song. An empty circle appears only on row hover. Clicking either adds or removes the song, reusing the picker's membership logic.
  - Round 7 below has the row and queue details.
- **New toolbar button 歌单** (`music.note.list`) between 搜索 and 译文.
  - Toolbar order: 歌词库 · 搜索 · 歌单 · 译文 · 文字 · 画面 · 更多 | 设置.
  - **Hover:** a panel titled 「接下来播放」 with the next 5 songs and an 「打开歌单」 button (Round 7).
  - **Click:** opens the panel on the 歌单 tab.
- The player's 「添加到歌单」 button keeps its quick popover for the current song.


## Round 6: 日用体验收口与真实问题复核（2026-10-27，GPT核对后交Codex实施）

**本轮定位**：用户要求把这一轮的实施规划写入 GitHub 再交 Codex。**这不是新一轮大改或新增功能。** 按本文件既有 Round 3/4/5 产品决定，修真实欠账、补齐必要验证、收口错误提示和日用手感。Claude 仍负责既定 UI 设计审查；Codex 执行代码；不让用户重复转发细节或陪跑长时间桌面自动化。

### 事实基线（实施前必须刷新）

- 审计时 GitHub `main = 91e1814db1b527c6513855de24f39f7dafc9c211`。**这是截点，不是固定施工基线**；Codex 启动和每次提交前先 `git fetch`，核对真正 `origin/main` 与 dirty，不 reset/clean/stash/force-push，不覆盖 `.planning/`、`.workbuddy/`、正式数据库或本机未提交代码。
- Round 5 **代码已提交**：大字模式防裁切 `5ff0d7b4`，边缘seek内移+短拖动条 `5defd615`，歌词库双栏 `53a14735`，搜索分组 `49b2591e`，歌单与队列 `369f9616`，后续修补至 `91e1814`。**不重复开发。**
- Round 4 **四项代码也已经提交**：按歌词语言记忆读音显示 `135e3744`、免费来源批量补词 `967e9823`、睡眠定时 `981e9ee9`、当前句发光强度 `7c27b212`。不要再作为“第10条待选功能”立项。
- 本机执行者报告 Debug Xcode 构建和 **110 PASS、1 SKIP、0 FAIL**，以及四张 **离屏**截图；这些不等于用户真实桌面交互、真实 Spotify 控制或稳定低占用已经通过。既有截图与报告位置：`/Users/apple/backup/sptifylyrics/.local/round5-20261027/`；能访问时直接复用，不要求用户重传。
- GitHub Actions `40478095735` 对 `91e1814` 的完整 macOS App 构建及 XCTest 步骤 **通过**，但整条 workflow 为 **FAIL**，因为额外的 Python 源码合同有 **两项旧检查失败**；不能整体宣称 CI 绿灯，也不能把这两项当成已复现的 UI Bug。

### R6-1｜先清理这两项过时检查，不改回已批准的产品行为（P0）

**A. 边缘轨道合同**：`Tests/v3_edge_pointer_state_contract.py` 仍硬编码期待旧 `height: 14` 的沿边输入区域。Round 5 已将可操作区域改到窗口内侧 **6–20pt**，避免与 macOS 窗口缩放重叠。改测试为验证**当前生产命中带真实几何**（至少包括离边缘3pt不能触发seek、6–20pt有效、窗口尺寸/方向变化后仍一致），不因为旧字符串不见了就报错。保留“旧歌曲拖动不能seek新歌曲”、鼠标跟踪不吞按钮、窗口边缘常驻进度等已有保护。

**B. 外置工具窗合同**：`Tests/v3_redesign_contract.py` 旧断言要求 `v3ToolPanelRoot(parent.content)` 出现至少两次。当前 `AppleMusicImmersiveV3Toolbar.swift` 改成一次创建 `let content = v3ToolPanelRoot(parent.content.onPreferenceChange(...))`，再分别用于 `NSHostingController(rootView: content)` 与 `hosting.rootView = content`。合同应验证**创建和更新同一套系统外观包装、固定窗与悬停窗的外观隔离，以及固定面板保留内容**，不以调用字符串出现次数判断功能。不得为了测试重新挂两份活跃面板，也不得删除其他身份/偏好/取消预览检查。

提交一个精确的测试修订，执行受影响的两个脚本及仓库现有 CI；要求 **native XCTest 与 source contracts 全部通过**。如果出现的是新行为失败而非陈旧断言，记录实因并定点修生产代码。不要以跳过脚本、修改 CI 成总是成功或大删断言来“修绿”。

### R6-2｜围绕 Round 5 的真实症状做一次精简原生检查（P1）

以下均为**先检查，失败才修改**；已通过就记证据，不写重复功能。

1. **大字模式**：使用历史复现曲《運命のふりをして》的当前句「ずっと前から決めてたんだね」，封面、环境光各查一次：开大字模式后**句首不能被顶端裁掉**；最多两行，两行仍放不下再缩字；有假名注音时原文与读音仍对应；上下句间距不乱。关闭大字模式仍按原行为。截图只是辅助，不能以离屏静图替代字体换行的本机验收。
2. **边缘进度/胶囊**：靠边3pt处不能seek/夺走系统窗口缩放；6–20pt能选/拖进度；横排与竖排胶囊中的短进度条都能拖动、能读时间；靠近四边唤出按钮位置不跳；轨道始终可见，拖动期间切歌不能误seek新歌。检验顶栏打开时边缘控制被压制，不抢浮层/歌词点击。
3. **居中浮层歌词库**：默认选中当前歌；标签/过滤、左右两栏及「⋯」操作布局清晰；**预览不等于采用**；采用、锁定、人工版本与原词/译文/读音/时间轴仍对应；关闭与在新窗口打开正常，不把灰色遮罩留在主窗。
4. **搜索**：本首「歌词版本」与「其他歌曲」分区清楚；同一录音不重复展示；不同 Spotify track ID 不被误合并；「查看歌词」不自动播放，「▶」才播放；逐字/逐行/纯文本与时长差确实取自候选证据；标签切换后各自查询与选中状态不串。
5. **歌单/播放队列**：悬停显示队列接下来的5首；歌单双栏与收藏勾选状态清晰；模拟歌单中第3首播放时 `offset=2`，且使用该歌单 `context_uri`；Spotify 未登录、401/403、无Premium、空歌单都给正确状态，不假装“没有歌单”。**自动测试仅用可控桩，不向用户真实 Spotify 发写请求**；真实播放留用户自行试用。

原生截图优先使用已存在的 Round5 四张；必要时取少量新图。屏幕接口故障（例如 ScreenCaptureKit -3811）不得阻塞实施，不用重新造截图工具或移动用户全局鼠标。

### R6-3｜Round 4 的四个已实现功能，只查联动不再重造（P1）

- **按歌词语言显示读音**：日语/中文/韩语/其他独立保存；首次迁移沿用旧显示偏好，不因切歌清空；同一版本语言判断缓存，无词时不猜语言。
- **批量补缺词**：「缺歌词」筛选准确、进度可取消；顺序有界免费查询，不启动 AI 翻译、不调用付费服务、不覆盖人工或锁定歌词；来源失败和无正文不能伪装成功，不持续重复请求。
- **睡眠定时**：15/30/60分钟与本曲结束后按当前播放源暂停；取消后不再触发，结束后重置，不新增后台每行/每窗口计时器。
- **当前句发光**：0% 无新增光，默认不改变既有外观，仅当前行受影响；对亮色封面、长句和减少动态效果做轻量检查，不重画所有歌词行。

### R6-4｜自动歌词在真实欠缺曲目上做定点复核（P2）

保留原有身份证据规则，**不能通过全局降低阈值换取“自动率”**。区分“来源查不到正文”“来源超时/500/503”“来源有纯文本但无时间轴”“当前曲目与候选不同录音”。可复用历史用例：HANABI/SACBEN 发行方有公开32行未同步文本；WAITING AT 3AM 当前发行页尚无正文；Piano Ver. 与普通编曲必须分辨。实际有可信歌词时完成 `搜索→AUTO_ADOPT→主窗显示→A→B→A缓存命中` 的日用闭环，手选/锁定版本不得被覆盖。无法获得歌词时保留诚实状态，不把没有正文推断为纯音乐。

### 性能、协作与完成判据

- **优先最小修改**：各子项独立一次提交，做完正常推送 `main` 并读回；提交前先 fetch/reconcile 同时发生的开发，不强推，不改前面已认可的原版环境光、羽化/柔焦/高斯、四场景分类或八个 renderer rawID。
- **30秒快速筛查**：影响UI/动画/窗口的修改，用同一Mac、同构建优化、同曲同窗同文字层，基线与候选比较 CPU/RSS（必要时 WindowServer）。这是回归筛查，不保证长期绝对低占用；出现持续增高先定位该项，不花半小时调鼠标脚本。禁止每行 Timer、逐帧全局 State 更新、预建所有场景或高分辨率逐帧模糊。
- **保护数据**：不覆盖正式安装版、SQLite、Keychain、手选或锁定歌词；不擅自调用付费 AI、不扩大账号权限、自动测试不直接修改真实用户歌单。
- **提交/报告**：每项说明实际修了什么、提交 SHA、受影响的一条真实检查及结果，`NOT_RUN` 单独列明。最终只发一份简短总报告（含来源测试 PASS/FAIL、Xcode XCTest、4处重要UI状态、CPU/RSS对照、尚未实测的 Spotify 写操作）。不要求用户逐步转发或做全量回归。
- **停止线**：Round6不再新增功能、不另造UI体系。上述问题均无真实缺陷时就收口；需要新设计的意见另记候选，不在本轮无边界扩大范围。


## Round 7: 歌单窗口收口与歌词卡顿（2026-10-31）

**Lyric rows never run the reading engine.**
- A view `body` must not start MeCab or wait for it. Each song's readings are computed once off the main thread.
- Lines show without readings until the result arrives, then gain them without a jump in position.
- Find out why the existing caches miss during playback, and fix that cause.

**歌单 panel, left column:**
- 接下来播放 and 已点赞的歌曲 get a 32 pt icon tile, so their titles line up with the playlist names.
- All rows share one selection style: rounded, inset 6 pt from the column edges.
- Membership mark: ✓ stays visible; an empty circle shows only on row hover. 接下来播放 has none.

**歌单 panel, right column:**
- Rows get a hover highlight; ▶ shows only on hover.
- **接下来播放 is read-only:** no ▶ and no double-click play. Spotify has no call to jump within the queue.
- **已点赞的歌曲:** play sends the chosen song plus the loaded songs after it through `uris`, so playback continues.
- Changing songs must not rebuild the panel or reset its scroll position.

**Header:** on the 歌单 tab the 「⋯」 menu holds only 刷新. Hide 导出, 导入 and 私人文件夹同步 there.

**Hover panel:** title 「接下来播放」, then the next 5 songs, then 「打开歌单」. An empty queue shows 「接下来没有待播歌曲」.

The 歌词库 · 搜索 · 歌单 tabs inside the panel stay for now, because the toolbar can hide.


## Round 8: 跟随系统外观、悬浮窗重做、插入播放、性能收口（2026-10-31）

**Appearance follows macOS, live.**
- Toolbar, hover panels, the centred panel, the add-to-playlist popover, settings and library windows follow the system light or dark setting, and change at once when it changes. There is no in-app appearance switch.
- The lyric canvas, cover scenes and edge player stay as they are, because their colours come from the artwork.
- Controls never take a tint from the cover. Tabs, links and icons use neutral system colours. Only the playing song may use the cover accent. Artwork colour may show through hover-panel glass (Round 10).

**Hover panels (歌单, and the same header on 歌词库 and 搜索).**
- Header: title on the left, a quiet text link on the right: 「全部」 for 歌单, 「打开歌词库」 and 「全部结果」 for the others. These replace the bottom buttons.
- Glass follows Round 10. Hairline border, 14 pt corners.
- 歌单 panel: 300 pt wide, 14 pt padding, five 44 pt rows with a 36 pt cover, title in primary and artist in secondary colour. Rows highlight on hover.
- It keeps showing the last known queue while refreshing, with no spinner flash, and refreshes when the song changes. The empty text stays.

**插入播放.**
- A button (`text.line.first.and.arrowtriangle.forward`, tooltip 「插入播放」) sits left of ▶ on hover, in playlist and liked rows and in the songs of the search tab. Queue rows do not have it.
- It calls `POST /me/player/queue`: the song plays after the current song and anything already inserted, and the playlist then continues.
- On success the icon shows ✓ for 1.5 s, and the queue reloads about 1 s later, since Spotify reads lag. A 403 shows 「需要 Spotify Premium」.

**Centred panel.**
- The right column opens with a header: 56 pt cover, name, 「N 首」 and a 「播放」 button that starts from the first song. 接下来播放 has no 播放 button. Its rows are clicked directly (Round 10).
- The playing song is marked in the list with the cover accent and a small level icon.

**Performance target:** while playing in a cover scene, the Release build averages at most 15% CPU, with clicks answered at once. The look stays the same to the eye.

**Repeat-one:** the end of a looping song must not read as paused. Playback state stays correct across each loop.


## Round 9: 歌词库、搜索和控件细节（2026-11-01）

**Version lists (centred 歌词库 panel, new-window library, hover 歌词库).**
- Names are always Chinese, from the existing display names. Raw source values such as `MANUALIMPORT` never show.
- Dates read 「10月31日 19:56」, with the year only when it differs from this year.
- Each version is one row about 48 pt high: mark, name, then 「日期 · N 行」 beneath.
- 预览 · 编辑 · 采用 show on the right on row hover. The adopted row always shows 「已采用」.
- Adopted rows use a neutral fill and ✓, with no blue fill and no left bar.
- Section titles (原词 / 译文 / 读音 / 时间轴) are 13 pt semibold with a grey count and a neutral icon. Remove the divider between versions.
- Library filter chips use the same neutral selection as the panel tabs.

**Song search (hover 搜索 and the search tab).**
- A song appears once. If it is both saved and online, keep the saved result.
- Titles get the whole row width; source and action sit on the second line.
- 「查看歌词」 and the selected mark use neutral colours.

**Edge player on bright covers:** icons and time must read clearly on a white cover. Darken the capsule backing until they do.

**Compact player:** the play button is the same in every scene and in both states: a near-white filled circle with a dark icon.


## Round 10: 更通透的悬浮窗与队列跳过（2026-11-01）

**Hover glass (every toolbar hover or pinned panel, in light and dark).**
- Clearly more see-through than now: the artwork's colours and large shapes show through, blurred, about like macOS Control Center.
- Body text stays easy to read on bright, dark and busy covers. Adjust the backing just enough for that.
- The add-to-playlist popover uses the same glass. The centred panel stays solid.
- Opening a panel must not put a focus ring on its first control.

**接下来播放: 跳过这首.**
- Spotify's Web API can read the queue and add to it, but has no call to remove or reorder items. Do not show a drag handle or anything else implying reorder.
- In the hover panel and the centred panel, row hover shows an × with tooltip 「跳过这首」.
- The row disappears at once. Whenever that song becomes the current song, however it got there (it arrives by itself, crossfades in, or the user presses Next in the app, in Spotify or on a media key), the app skips it immediately. The mark is then used up.
- Marks last for this app run only.
- A song started on purpose in the app always plays: from a row, from search, or with 上一首. 插入播放 on a marked song removes its mark.
- Spotify does not say why a song changed. If the user clicks a marked song inside Spotify, it is skipped once and the mark is used up, so clicking it again plays it. This is accepted. Do not add timing rules to tell these cases apart.

**接下来播放: fast, always current, clickable (2026-11-01).**
- The queue loads in the background at app launch, on every song change and each time a panel opens, so opening a panel shows the last list at once and then updates it. A failed load retries once after 2 s. A spinner only appears when nothing has ever loaded.
- On a song change, the list drops the new current song and everything before it straight away, without waiting for Spotify. The song now playing never stays as a row.
- Clicking a row, in the hover and centred panels, jumps to that song: the app calls Next as many times as it takes, in one quick run. Songs passed over use up their marks, and the jump never adds extra skips. × keeps its own click.
- With a repeating playlist the same song can appear later in the queue. Those rows are ordinary rows: only rows at the top of the list count as already played, and × on a later row marks it as usual.

**Pinned panels.**
- The glass runs to the top of the window, under the traffic lights. No separate title-bar strip, and no window title repeating the panel heading.

**Scrolling panels.**
- When the 画面 panel's content is taller than the panel, the bottom edge fades over about 16 pt instead of cutting a row in half.

