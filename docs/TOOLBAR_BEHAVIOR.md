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
- **Hover panel:** dark frosted glass.
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
  - **Right column:** the selected playlist's tracks. Double-click a track, or press its ▶, to play it in that playlist's context (`PUT /me/player/play` with `context_uri` and an offset; the existing playback-write scope covers it). A 403 shows 「需要 Spotify Premium」.
  - Each playlist row shows a circle that is ✓ when the current song is in it. Clicking the circle adds or removes the song, reusing the picker's membership logic.
- **New toolbar button 歌单** (`music.note.list`) between 搜索 and 译文.
  - Toolbar order: 歌词库 · 搜索 · 歌单 · 译文 · 文字 · 画面 · 更多 | 设置.
  - **Hover:** the next 5 songs in the queue.
  - **Click:** opens the panel on the 歌单 tab.
- The player's 「添加到歌单」 button keeps its quick popover for the current song.
