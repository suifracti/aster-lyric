# Main-window toolbar behaviour

This file is the contract for the toolbar and its panels. Claude decides the UI; GPT implements it (user decision, 2026-10-20).

- **Code:** `SpotifyLyrics/Views/MainWindow/V3ToolbarModel.swift`
- **Checks:** `V3ToolbarPresentationTests` (via `Tests/v3_toolbar_model_contract.sh`)
- **Screenshots:** `Scripts/ui-snapshots.sh`

To change a rule, update this file and the tests first, and attach before/after snapshots. Keep the tests to the rules written here.

## 歌词版本与批量译文（2026-11-19）

- 歌词库歌曲详情的「查找其他版本」直接按这首录音搜索，可先预览和对读，再决定采用。原词列表与候选标出逐字、逐行或纯文本，声部与合唱用词源的标注。
- 「查找其他版本」和「对比原词」共用默认较大、可调整大小及全屏的歌词版本窗口。找到一个来源即可查看。点版本名预览，勾选至少两份已存稿或候选稿并排对比，滚动查看放不下的列。可换底稿、按正文或行号对齐，有时间的版本可按时间对齐，并可筛正文、时间或附文与声部。正文或时间对齐时，可把分行不同的同一段词排到同一组，同类署名也能对照。
- 逐行记录每句切换的时间。逐字还记录句内字词的时间，在预览和对读可展开查看。纯文本没有同步时间。
- 「对比译文」使用同样可调整大小的窗口。每句原文下并排显示底稿和参照稿，提供「末句」、只看不同与逐句勾选修订。有源时间轴的网易云存稿可「重新对齐词源译文」，结果另存待采用版本。
- 注音排版打开时，片假名保留原字形，并在上方显示平假名读音。
- 「译文」提供当前歌曲的已存译文预览、对话入口和翻译缓存。「批量翻译」在译文和歌单入口共用，可准备接下来两首、播放队列或所选歌单，显示进度并可停止。
- 搜索可切换全部、本地和在线，歌名与歌手、专辑分行。歌单小面板突出下一首，完整浏览器显示当前队列或所选歌单。
- 对唱：声部用左右位置和颜色区分，当前句外侧有声部色竖条，合唱居中；只显示词源给出的真实歌手名，不印「声部 N」「合唱」。
- 译文翻译中显示分步进度卡（准备、已发送、思考、写译文 n/N 行、校验）、已用时间与取消；面板关着时工具栏「译文」上有小进度弧。

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
  - 桌面歌词的悬停栏、菜单栏弹窗和展开的灵动岛都可以循环眼前有时间轴的句子。已经在循环时，这些按钮统一用来取消；在灵动岛定住一句后，也可以从那句开始循环。全屏和小窗继续操作正在播放的录音，即使主窗口正在预览别首歌。手动跳出循环范围会恢复正常播放。
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

**Moved to the settings window:** 翻译服务 login and connection details (keys, endpoints), 恢复此风格的默认值, and every explanatory paragraph. The choice of service itself is back in 译文 (2026-11-15, user request "想用 api"): 翻译服务, then API (自定义兼容 / DeepSeek) or 连接方式 (Gemini / Antigravity) when that service has several, and for an API service a 「在设置中填写…」 row that opens Settings → AI 翻译. Switching keeps each service's own model. API offers OpenAI API, DeepSeek API and a custom compatible API; OpenAI and DeepSeek need only a key (fixed endpoint, own Keychain item); saving the key lists the account's models, and the listener picks the model and 思考强度 (OpenAI: 模型默认/低/中/高). These rows are menus of buttons, not menu-style Pickers, which kept showing the old choice inside the hover panel. The rows live in `TranslationServicePanelRows`, a view that observes the settings itself and is rebuilt when the service, model or effort changes: rows borrowed from the window view's body still showed the old service after a switch, because the panel is a separate hosting window. 当前译文 adds 「AI 翻译（没有就不显示）」: a lasting preference that shows only AI translations and no translation for a song that has none yet; 自动（推荐） turns it off.

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
- **Apple Music:** the picker reads local playlists and its 「喜爱」 row uses Music’s favourite flag.
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
- Spotify uses the same confirmed queue as the player panel. Up to two distinct upcoming recordings are preloaded, following the visible queue and its skip marks.
- Apple Music preloads from the verified current playlist when shuffle is off and repeat-one is off. The Music app manages manual changes to Playing Next.
- Both players use the same lookup rules and storage as a normal lyric search.
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
| 翻译服务, AI 模型, 思考强度 | Toolbar 译文 | Settings AI 翻译 (it keeps service, key, endpoint and personal style) |
| 翻译风格 | Settings AI 翻译 → 翻译默认行为 | Two choices only (2026-11-15, user): 我的风格 shown as one editable box holding exactly the text sent to the model (2026-11-16: a separate summary above it read differently from the text below, so it was removed; stored as `ai.personalStyleOverride.v1`, used for new translations; 恢复默认 removes the edit so later built-in updates apply), and 自定义 with a text box whose text is used only while 自定义 is chosen. Older presets (自然歌曲, 忠实直译 …) stay readable as 「（旧设置）」 when already saved; 个人翻译风格档案 moved into 高级模型参数与提示词. |
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
- 歌词库 gets a filter 「缺歌词」 for tracks with no saved lyrics and tracks with only automatically adopted plain text.
- Next to it, a 「全部补全」 button searches them one by one with the normal free-source search and auto-adopt rules.
- The main and separate library windows share one batch. Leaving either view lets it continue. Both show progress and offer an explicit stop button.
- 「结果」 keeps the latest run's per-track outcomes until the next run, including tracks completed before a stop. Selecting a result opens that track's library details.
- Never call AI translation or any paid service; manual or locked lyrics are untouched.
- Each search is logged to source-stats with `batch: true`.

**3. Sleep timer.**
- In the 更多 panel: 「睡眠定时」 with 关闭 / 15 分钟 / 30 分钟 / 60 分钟 / 本曲结束后.
- When it fires, pause playback through the existing play/pause path.
- 「本曲结束后」 follows the current player across the same player's song boundary. Switching players cancels that option.
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
- **Personal data import:** all songs commit together. The preview flags assets attached to another recording or source version. Folder sync confirms the previewed file revision before import and before writing back. The library reports local import and folder write outcomes separately.
- **Two columns:** a compact list on the left (about 300 pt) and the selected item's detail on the right. No grey inner box.
- **歌词库 tab:**
  - **Filters:** 全部 · 当前歌曲 · 缺歌词 · 有译文 · 手动编辑 · 已锁定. The main panel, separate library, and Settings use the same filters. Selecting 缺歌词 offers 全部补全 for the current search once its results are ready.
  - **Rows:** 44 pt high, 32 pt cover, title and artist, badges 词 N / 译 N.
  - **Right column:** that song's versions, grouped 原词 / 译文 / 读音 / 时间轴 like the hover panel, with 采用 / 预览 / 编辑.
  - Opens with the current song selected.
  - Closing the panel remembers its search and filter. 「在新窗口打开」 takes the search, filter, and selected recording to the separate library, where the search can be changed independently.
- **搜索 tab:** two clearly named sections.
  - **「这首歌的歌词」:** provider candidates for the current song. Each shows the source, a 逐字 / 逐行 / 纯文本 badge, the duration difference and 预览 on hover. The action is 「采用此版本」.
  - **「其他歌曲」:** library and Spotify-catalog songs. The action is 「查看歌词」, plus a ▶ that plays the song.
  - The hover panel, main panel and search window share one query and its results. Opening an existing search keeps the typed text. After clearing it, reopening stays empty.
  - The current song appears once, not in both sections. Local results show first; online results stream in.
- **歌单 tab:**
  - **Left column:** 接下来播放 (from `/me/player/queue`), then 已点赞的歌曲, then the user's playlists (flat; Spotify gives no folders).
  - **Right column:** the selected playlist's tracks. Double-click a track, or press its ▶ (shown on row hover), to play it in that playlist's context (`PUT /me/player/play` with `context_uri` and an offset; the existing playback-write scope covers it). A 403 shows 「需要 Spotify Premium」.
  - The main panel and playlist window share the selected list and search text. Both can filter by playlist name or the track's title, artist or album. 「播放首个结果」 starts at the first visible track's original position and playback continues in the playlist.
  - A ✓ marks each playlist that holds the current song. An empty circle appears only on row hover. Clicking either adds or removes the song, reusing the picker's membership logic.
  - Round 7 below has the row and queue details.
- **New toolbar button 歌单** (`music.note.list`) between 搜索 and 译文.
  - Toolbar order: 歌词库 · 搜索 · 歌单 · 译文 · 文字 · 画面 · 更多 | 设置.
  - **Hover:** a panel titled 「接下来播放」 with the next 5 songs and an 「打开歌单」 button (Round 7).
  - **Click:** opens the panel on the 歌单 tab.
- The player's 「添加到歌单」 button keeps its quick popover for the current song.


## Rounds 6–26 活跃产品规格摘要（历史详录已归档）

Round 6–26（2026-10-27 至 2026-11-15）的逐轮实施记录已无损归档至 [toolbar-behavior-history-2026-11-20.md](archive/toolbar-behavior-history-2026-11-20.md)，下文保留其仍在生效的核心行为规范：

- **歌单、队列与播放**：右键插播（Play next / After current）跨窗口同步「接下来播放」；歌单筛选、搜索词与点赞曲库在主面板与独立窗共享；队列预取下两首，切回已存歌词不再重复联网搜词。
- **工具栏与折叠设计**：沿用 `V3ControlBarSurface` 统一面板表面；低频视觉开关收入折叠子行（folded entries），画面面板保持单屏；边缘胶囊（`V3EdgePillScrubber`）提供可拖拽短轨，可操作边缘区保持在窗内 6–20 pt 避开 macOS 缩放区。
- **沉浸视觉、随乐律动与情境**：画面合并为主场景 + 玻璃天气 + 流动背景 + 封面律动（微弱/标准、边灯、微呼吸、细光环、VU 表、声纹圈、轻粒频谱、微颗粒）；玻璃质感与环境光羽化沿用既有可调参数与 `authenticAmbientArtworkLayers`；非活跃/被遮挡/最小化窗口停止高帧渲染；全屏随显示器切换，状态栏支持双行与截断/滚动偏好。
- **歌词、对唱与译文**：QRC/KRC/YRC 与本地 TTML 支持逐字发光上浮、对唱双侧排布与真实歌手署名（无署名不硬贴「声部 1/2」）、和声小字独立成行、逐行缓存静默升级同词逐字轴、词源译文按版本切换与重新对齐、收藏金句与原词/译文分享卡。


## Round 27 · 不播放时的工作台（2026-11-18）

设置首页同时是本机歌词的工作台。最近收藏的句子打开所属歌曲，最近看过的档案可以接着整理。没有收藏时主入口打开歌词库。金句、缺歌词、最近播放、统计和连接都能单独进入。

主窗口在没有当前歌曲、演示或搜索预览时打开工作台。可直接找句、打开文件、写手稿或编歌本。播放时也能从窗口菜单、菜单栏、灵动岛或主窗口的「更多」主动进入工作台，后续播放保持在后台。点「歌词窗口」可以返回当前布局，空闲时也可以查看该布局。

暂停时，听歌界面仍显示当前歌曲。Spotify 或 Apple Music 明确停播或退出后，各窗口和状态栏一起离开当前歌曲。播放中错过停播通知时，下一次位置校准也可确认停播。临时读取失败继续保留最后确认的歌曲。

听歌窗和全屏各自按窗口是否实际可见运行动态画面。窗口最小化、隐藏或被完全盖住时，情境、频谱、流动背景和动态光效停止刷新。回到可见窗口后按当前歌曲继续。音乐暂停时，眼前的雨滴玻璃、水面等情境仍会缓慢变化，并遵循系统「减少动态效果」。

侧栏搜索同时查设置、本机已保存歌曲和歌词、收藏的金句。后退和前进保留查询和原来那首歌，支持 ⌘[、⌘] 和 ⌘F。最近播放的列表与封面墙、收藏的金句可以直接打开对应档案。只有使用者手动选择版本才会改变采用结果。

### 状态栏

播放时顶部保留曲目信息和收藏这句，正文展示前后句与已到位的译文，底部可以打开完整歌词。空闲时先显示本机收藏或歌词库。两种状态始终可到工作台、歌词库、主窗口；桌面歌词、灵动岛、恢复拖动和退出在更多菜单。系统栏原词与译文分两行显示，保留字体、宽度、溢出和注音偏好。

原文、译文各按本行宽度决定是否滚动或省略。长原文滚动时，短译文可以留在原位。暂停或启用减少动态效果时，超宽行用省略号结尾，悬停可以读全文。

弹窗的「完整歌词」停在打开时唱到的那一句，换歌后也可以继续读或复制。已有存稿时可以点「在歌词库阅读」，从同一处继续，并在阅读页打开该版本的档案。

有逐词时间的原词在弹窗里按播放位置填色，长句可以换行，右键可复制整句。暂停时填色停在当前字；只有逐行时间时整句显示。

### 收藏与接下一句

「收藏的金句」可以按卡片翻阅，也可以用列表查找。选中一张卡片能回到原词和歌曲档案、复制摘句或生成分享卡。「接下一句」先给出选中的原句，按回车或点揭晓再读下一句，之后可以接着往下或回到完整原词。读词页和主窗口内已保存歌词的右键菜单也能进入。全程使用本机已存版本。

### 本机空间

「高级与数据」显示歌曲档案、数据库备份以及可重建的媒体缓存各占多少空间。展开备份能逐份定位或移到废纸篓。「文件位置与内容」分别列出网络封面和歌手照片、Apple Music 本机封面及背景视频用量。「清理缓存」覆盖这些媒体缓存。收藏、冲洗台照片、歌曲各版歌词和个人选择照常使用。数据库备份与金句文件的位置也在这处明细中。

### 顶部灵动岛

平时在屏幕顶边读正在唱的歌词，刘海屏将这句放在摄像头下方。岛上根据已选原文、译文与读音取可用内容。展开后整行阅读，下一句、收藏、歌曲档案和播放进度都在同一处。「定住这句」让音乐继续，也让人有时间读完或收藏；「跟回演唱」、收起或换歌都会回到当前句。没有播放时，岛上可以打开工作台、歌词库和金句。

展开的灵动岛和桌面歌词的悬停工具栏可打开「完整歌词」。它与状态栏用同一份阅读视图，在独立窗口里保留打开时的内容。灵动岛定住的行优先作为阅读起点，没排轴的歌词从开头读。已有存稿可继续到该版本和同一行。Esc 关闭阅读窗。

展开灵动岛跟唱时，带逐词时间、适合当前版式的原词按进度填色。定住一句时保持静态阅读，返回跟唱后从当前播放位置继续。减少动态效果时使用静态文字。

透明桌面歌词、旧版桌面卡片和经典主窗也按原词自带的逐词时间填色。暂停时保留当前填色，拖到同句的另一处时按新位置显示。逐行稿仍按整句显示，减少动态效果时使用静态文字。

「只看译文」在主窗口、全屏、桌面歌词和灵动岛都只显示已存在的译文。切回其他模式会恢复已选的罗马音与拼音。隐藏原文时，拼音可以单独成行。桌面歌词和灵动岛显示下一句时也遵循所选文字层。菜单栏仍按自己的宽度和文字开关显示。

主窗口各布局、全屏、边缘播放器、封面进度、状态栏和顶部灵动岛共用拖动规则。松手时才提交当前录音的进度。拖到一半切歌会取消这次拖动，即使随后又回到原歌。

主窗口与全屏的「歌词偏移」和 Z/C/X 校准当前播放的已保存原词版本。搜索预览里显示「试听的歌词暂不能校准」。主窗预览另一首时，全屏仍可校准自己显示的实时歌词。校准只移动歌词时间。

### 歌词阅读与收藏出处

从工作台搜索、收藏的句子或曲目档案的「读歌词」进入本机阅读页；独立歌词库的预览和主窗口的版本预览复用同一页。阅读页显示来源、按行排版的原词和译文，读音可以展开。输入片段可在匹配处之间跳转，收藏从哪一行进入就先展示那一处。查阅任意历史稿都不改变当前采用版本或播放位置。

工作台的「继续阅读」打开上次看的版本并回到离开时看到的位置，包括手动翻到的段落。查找词和命中项仍可接着用。工作台旁的「最近阅读」和空白的 ⌘K 列出最近五份读过的稿，同一首歌的不同版本可以分别续读。浏览其他歌曲档案时，最近阅读仍可用。收藏摘句带来的译文仍在它原来的那句。

从阅读页打开「版本档案」会把刚才看的版本放在对应分类最上面，标明「刚才阅读」。从档案点「读歌词」或预览这份稿，会回到刚才的查找位置。独立歌词库在本窗内完成往返，设置里的后退也保留阅读位置。

同一录音有多份稿时，阅读页工具栏可直接「切换阅读版本」。菜单按原词、译文和读音显示本机存稿，沿用档案的自定名称。换稿保留查找词；两份稿对应同一版原词时可以留在原行。返回查找可继续原查询，打开档案则带入刚读的那份稿。

### 找回一句

在星弦的窗口按 ⌘K，或点菜单栏弹窗的「找一句」，即可查本机的歌名、原词、译文、读音、金句与设置。在其他支持 macOS 服务的应用里选中文字，使用「在星弦查找这句歌词」会把选区直接带过来。输入框支持中文和日文输入法，用上下键选结果，回车读上下文。阅读后可以回到原查询，也能打开完整档案。

歌曲标题与歌词同时命中时保留两个入口。译文或读音已经有自己的版本时，命中句优先进入那一份稿。

也可以在主窗歌词库面板、独立歌词库或设置的「我的歌词库」直接搜歌词。选中歌曲后，「读命中句」显示匹配片段，打开原词、译文或读音的实际存稿，并把搜索词带到阅读页。关闭阅读后可继续用原来的查询和歌曲选择。只匹配歌名等资料时仍可照常浏览档案。

### 版本对读与逐句修订

歌曲档案有两个原词或译文版本时，可以从「读歌词」旁的「对比版本」进入「对比原词」或「对比译文」。每份稿的「操作」也能指定底稿。可以只看不同、前后跳转，或展开查看逐字时间。参照稿优先选底稿的父版本。两边的稿都能换，选中另一侧正在看的版本就会互换。播放面板的「对比译文」还可以直接采用其中一稿。

两份译文对应同一版原词时，点「选这句」可从参照稿挑句，再带入译文编辑。保存后生成底稿的人工子版本；对读和挑句期间保留当前采用稿。

两栏同时显示演唱者、声部或合唱标记。比较原词时，单独更换声部也会显示在「只看不同」中。两边都保留原稿的行序。

从阅读页进入版本档案时，对读会先定位刚读的那一行。同一句重复唱时也能回到原来那一次。切换底稿和参照稿后，阅读位置跟着原来的版本。将参照译文带入编辑后，编辑器会显示选中的原词行。

### 打开本地歌词

从 Finder 或工作台打开 TXT、LRC、TTML，文档窗口可以逐行读、查找、切换译文和读音。文件自身带时间时，页边显示实际时间。点「存入歌词库」可以选择已有录音或新建本机档案，随后直接阅读已存的版本。在缺词歌曲里点「从本机文件补上」会带入这份档案。

TTML 带有多种译文时，文档窗右上角显示当前语言，可就地切换。存入一次即可在同一份原词下查阅、对读或编辑各语言版本。某种译文缺句就留空。人工编辑时可以指定新稿的译文语言。

存入后点「阅读已存版本」，从文件里当前选的译稿继续。查过歌词时保留查找词和选中的命中；普通浏览从刚才看到的行开始。存入后还可以先在文件里换语言，再打开对应的已存译稿。

文件、歌词库阅读、「接下一句」和状态栏「完整歌词」沿用听歌窗口的声部与合唱标记。阅读时同一时段的合唱可以合并为一行，各声部独有的译文、读音、和声和后来再唱的句子保留。歌词库仍能按原来存的行号打开收藏和摘句。

从文件、已存歌词的阅读页或编辑器可以带走手里的这份稿。TTML 保留逐字、对唱、和声和罗马音；原词与当前译文能分开存成 LRC，也可存成逐句排列的对照文本。读旧译稿时若对应原词已不同，仍可另存它自己的文字。编辑器里尚未保存的修改也可导出。

在工作台点「写手稿」，或在歌曲档案里为这首歌开稿。手稿可用系统存储面板保存在 Finder，随时接着写。空一行就分成两段，在「编排」中可以调整顺序，或把一段放到结尾再唱一次。「阅读」显示实际排版和手工写入的时间标签。「存入歌词库」将当前稿存为人工版本；从旧手稿继续改会在对应版本下留下分稿，已有录音仍沿用原来的采用选择。

在已存歌词的阅读页点「从这版写手稿」，可以直接复制看到的原词及每行的起始时间。手稿底部可回到关联版本，归档时默认定位这首歌，并把新稿挂在打开时的版本下面。逐词时间、对唱、和声、译文和读音仍可在底稿查阅，需要带齐时可导出完整 TTML。

### 外观

点选桌面示意图里的位置，可以单独调整主窗口、桌面歌词、灵动岛和菜单栏歌词。较小的设置窗口使用位置选择栏。工作台搜索「状态栏宽度」「桌面歌词字号」或「刘海」，都能直达对应位置。点桌面停靠按钮会显示歌词并挪到屏幕顶部或程序坞上方；灵动岛可试读收起与展开的样子。

菜单栏的两处外观入口可以预览当前歌词或试读日英长句。预览用系统栏的排版、字体、宽度和滚动规则，在较窄的面板内按比例缩小。

主窗口外观里可选「柔和光晕」和「独立色场」，搜索两种画面名称也会定位到这行。使用其他主窗口布局时，这一行可打开布局选择。从主窗口、桌面歌词或灵动岛的外观打开「体验版本库」，默认显示对应分类和已采用的版本。取消预览只作用于当前分类。

「自动」环境光跟随本窗口正在显示的封面。换歌、试听或打开全屏时，用所显示的那张封面选择光效，已保存的画面选择仍可恢复。情境指定的版式和手选画面优先。

换歌或试听时，已加载的封面直接显示。尚在下载时，前景显示当前歌曲的占位，背景采用中性色。选择歌手照片时先显示当前封面，可用的照片到达后再换入。

接入多个显示器时，可以直接把桌面歌词移到另一块屏幕，保留它原来靠上或靠下的位置。灵动岛可以跟随主窗口或固定到指定屏幕；临时断开显示器时先跟回主窗口，重新接上后回到所选屏幕。


### 编歌本

工作台可新建本机歌本。从歌词阅读页、单行菜单或收藏的金句收录已有版本，也可在歌本中搜索歌词库和金句。目录支持调整篇目顺序，封面和每篇的编者按可独立编辑。正文保存收录时的内容，篇目菜单可回到原稿。歌本文件可从 Finder 打开。「印本」可导出或打印 A5 版式，包含目录、页码和可点击的跳转。全文可在离线时阅读。

在歌本内搜索歌词时，打开命中结果可以查看所匹配的版本。可以按行号和时间分别收录同一句的多次出现，也可以收录整首。返回结果保留已有查询。摘句从篇目菜单回到当时的版本和那一行。

阅读页「摘一段」和歌本搜索「选一段」共用选段。点选起止行即可将连续歌词收进一个篇目，目录标明原稿的行号。篇目菜单回到同一份原稿，标出整段并定位到开头。

从已存版本收录的全文、摘段或单句，歌本正文和印本带上收录时的演唱者、声部或合唱标记。旧歌本里的声部编号按可读名称显示。

**亮背景自动保护与当前句译文** (2026-11-19, 文字 panel; desktop lyrics colours).
- The picture's real brightness is measured, including a playing Canvas clip (its brighter quarter). A bright picture is darkened slightly, lyrics get the text shadow in every layout, and the cover-coloured line is lightened until it reads. The foreground cover is never darkened. The switch is 「亮背景自动保护」 (formerly 亮封面自动加阴影).
- 当前译文放大 (on by default): only the sung line's translation grows to about 0.56 of the original and turns semibold; other lines keep the small translation.
- Desktop lyrics 柔和衬底 (on by default): a borderless blurred shadow behind the lines, in the outline colour.
