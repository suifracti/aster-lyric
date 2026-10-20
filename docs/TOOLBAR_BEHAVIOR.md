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

## Lyric bar (most-used controls)
Things people change during a song do not live in panels. They sit in a small bar next to the lyrics.

```
 A−  A+  │  ◀ 0.0s ▶  │  原 译 读  │  ⫷ ≡ ⫸  │  ‹ 封面 ›
```

| Group | Click | Notes |
|---|---|---|
| A− / A+ | Changes the 原文与译文 font size by 2 pt | Range 14–42. |
| ◀ 0.0s ▶ | Moves the lyric offset by 0.1 s | Click the value to reset it to 0. |
| 原 译 读 | Shows or hides 原文, 译文 and 读音 | A lit label means it is shown. 读 is greyed out when the song has no reading. |
| Alignment | Left, centre, right | The current one is lit. |
| ‹ name › | Switches to the previous or next of the 4 scene categories | The name is the current category. |

**When it shows:**
- It appears when the pointer rests on the lyrics column.
- It follows the toolbar's visibility rules: hidden outside the window, and hidden while any panel is open.
- Its place is fixed, just under the lyrics column. It never covers the current line.

**Every button has a tooltip** with its name and, where one exists, its shortcut written in words, for example 「放大字号（Command + 加号）」. Don't write ⌘ or ⌥ symbols.

**Feedback:** each change briefly shows a small centred notice, such as 「字号 22」, 「偏移 +0.3s」 or 「封面」, then it fades out.

## Gestures and shortcuts (optional extras)
Every action here also has a button in the lyric bar, so nobody needs to learn them.

| Action | Gesture | Shortcut |
|---|---|---|
| Font size | Pinch on the lyrics | Command + 加号 / 减号 |
| Scene | Two-finger swipe left or right on the canvas | Command + 左 / 右方向键 |
| Lyric offset | — | Option + 左 / 右方向键 |

## Panels
- **One panel per button.** Hover shows it temporarily; click pins it. **Hover and pin show the same content.**
- **Each panel fits on one screen:** at most about 8 controls and max height 520 pt.
- **No explanatory paragraphs.** Use an ⓘ tooltip when a control needs one.
- **Lyric bar controls are not repeated in panels.**
- **Rarely used settings live in the settings window**, not in toolbar panels.

| Button | Panel |
|---|---|
| 歌词库 | This song's versions grouped by type (原词 / 译文 / 读音 / 时间轴). The adopted one is checked; click another to adopt it. Each row shows source, date and line count. 「打开歌词库」 is at the bottom. |
| 搜索 | A search field prefilled with the current song. Local results show at once; online results are added when they arrive. Top 5, plus 「全部结果」, which opens the full search. |
| 译文 | 翻译 / 读音. The saved-translation version picker. 「翻译整首」 and 「重新翻译」. 新歌词自动翻译. 并排对比. |
| 文字 | 清晰度 (关闭 / 文字阴影 / 柔和光晕, default 关闭). 罗马音 / 拼音. 注音排版. 读音与辅助字 size. 假名 size. |
| 画面 | The 4 categories from `V3SceneFamily`. Below them, the selected category's style list, including 经典版. 背景封面模糊. 显示歌曲缩略图. |
| 更多 | Window modes (桌面歌词, 顶部胶囊, 菜单栏歌词, 全屏). 桌面歌词交互. 恢复歌词时间. |
| 设置 | No panel; it opens settings. |

**Moved to the settings window:** 翻译服务 and model, 悬停预览, 恢复此风格的默认值, and every explanatory paragraph.

**Removed from 更多:** 「歌词版本」, which 歌词库 now covers, and the offset, which the lyric bar now covers.

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
- An open panel takes priority over the toolbar.
- The toolbar takes priority over the window-edge controls.
- While the pointer is in the toolbar area or any panel is open, the edge play buttons stay hidden and only the progress rail shows.
