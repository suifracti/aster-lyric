# Main-window toolbar behaviour

This file is the contract for the toolbar and its panels. Claude decides the UI; GPT implements it (user decision, 2026-10-20).

- **Code:** `SpotifyLyrics/Views/MainWindow/V3ToolbarModel.swift`
- **Checks:** `V3ToolbarPresentationTests` (via `Tests/v3_toolbar_model_contract.sh`)
- **Screenshots:** `Scripts/ui-snapshots.sh`

To change a rule, update this file and the tests first, and attach before/after snapshots. Keep the tests to the rules written here.

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
| Background blur | **[** less blur / **]** more blur, stepping through 清晰 → 柔和 → 很糊 |
| Focus mode | **F** toggles it (see below) |
| Lyrics are early | **Z** moves the timeline up: offset −0.1 s per press |
| Lyrics are late | **C** moves the timeline down: offset +0.1 s per press |
| Reset offset | **X** sets the current song's offset back to 0 |
| Show all keys | **?** opens a centred list of every key; **?** again or **Esc** closes it |

- A gesture change shows a small notice at the bottom of the lyrics column, such as 「字号 22」 or 「封面」, which fades after about 1 s.
- **Letter keys** are case-insensitive and work only while the main window is focused and no text field has focus. They are not global hot keys.
- **Every key press shows the same small notice**, for example 「上一首」, 「偏移 −0.3s」, 「已加入喜欢」 or 「已在喜欢中」.
- **Holding Z or C repeats.** The offset is the same per-song offset as in 更多.
- **S, liking the song:**
  - **Spotify:** use the existing Spotify connection (`SpotifyAuthorizationManager`) and save the track to the user's Liked Songs. If it is already liked, only show 「已在喜欢中」.
  - **Spotify not connected, or missing library permission:** show 「需要连接 Spotify」 with a button that opens the connection settings.
  - **Apple Music:** mark the song as favourite.
- **Heart button:** the player (transport) has a heart. It is filled when the song is liked or favourited, and clicking it toggles that state.
- **No Command / Option shortcuts.** Each panel lists its keys in tooltips, written as plain letters.

## Listening extras (user-approved 2026-10-21)
**Scope:** lyricsQ is for listening to music and singing along. Don't add learning, sharing or social features.

- **Cover colours:** take the accent colour from the cover's palette and use it for the current-line highlight, the progress bar and the panel accent. It changes with each song. If the cover has almost no colour (saturation below about 0.08), use the current neutral colour. Reuse `LyricIslandArtworkColors`.
- **Night dimming:** a single switch, 「夜间柔和」, in 画面 → 更多画面选项, default off. Between 20:00 and 07:00 it lowers canvas brightness by 15% and caps 背景动态 at 轻柔. There are no other settings and no numbers for the user to set.
- **Focus mode:** **F** hides the toolbar, the title and the player, leaving only the lyrics and the background. **F** again or **Esc** brings them back. While it is on, the pointer does not bring the toolbar back.
- **Shuffle and repeat:** two small buttons in the player that drive the current player's own shuffle and repeat settings and show their state.
- **Loop one line:** right-click a lyric line → 「循环这一句」. Playback jumps back to that line's start each time it reaches the next line. The looped line has a small loop mark. Clicking the mark, right-click → 「取消循环」, or a track change stops the loop.
- **Big-line mode:** a 「大字模式」 switch in the 文字 panel. The current line is drawn at about twice the size; the other lines are 60% size and dimmed. It is meant for singing along from a distance.
- **Click to seek** already exists; keep it unchanged.

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
| 画面 | The 4 categories from `V3SceneFamily`. Below them, the selected category's style list, including 经典版. 背景封面模糊. 显示歌曲缩略图 / 前景封面. **播放呈现 (标准播放栏 / 窗口边缘).** **背景动态 (关闭 / 轻柔 / 鲜明).** A collapsed 「更多画面选项」 holding the rest of the picture controls (取景方式, 前景封面尺寸与位置, 背景缩放, 悬停时显示播放信息). |
| 更多 | 当前歌词偏移: −0.1s, a value field, +0.1s, 归零. Window modes as **switches**: 桌面歌词, 顶部胶囊, 菜单栏歌词. 全屏歌词 is a button. 桌面歌词交互. 恢复歌词时间. |
| 设置 | No panel; it opens settings. |

**Nothing is removed.** Every control that was in a toolbar panel before 2026-10-20 stays reachable from its panel, folding into a collapsed section where needed. The settings window may show them as well.

**Moved to the settings window:** 翻译服务 login and connection details (the model picker stays in 译文), 悬停预览, 恢复此风格的默认值, and every explanatory paragraph.

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
