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

## Hover vs click
Hover and click show **different** things:
- **Hover** shows a small panel inside the app with 3–5 quick controls. Every control in it can be used directly.
- **Click** opens the full panel, or does the button's action.

| Button | Hover: quick controls | Click |
|---|---|---|
| 歌词库 | This song's lyric versions; the adopted one has a check, and clicking another adopts it. 「打开歌词库」 at the bottom. | Opens the lyrics library. |
| 搜索 | A search field prefilled with the current song, plus the top 3 results. | Opens the full search. |
| 译文 | 原文 / 中文 / 读音 switches, one line naming the current translation source, and 「翻译整首」. | Full 译文 panel (below). |
| 文字 | Font size − / +, and alignment (left / centre / right). | Full 文字 panel (below). |
| 画面 | The 4 scene thumbnails; clicking one switches the scene. | Full 画面 panel (below). |
| 更多 | Window modes (桌面歌词, 顶部胶囊, 菜单栏歌词, 全屏), and lyric offset −0.1s / +0.1s. | Full 更多 panel (below). |
| 设置 | No hover panel, only a tooltip. | Opens settings. |

### Full panels
- **译文:**
  - 翻译 / 读音
  - 新歌词自动翻译
  - Saved translation versions and 并排对比
  - 重新翻译
  - 翻译服务, with the only link to AI settings in the toolbar
- **文字:**
  - Everything from the old 文字 tab
  - **清晰度**: 关闭 / 文字阴影 / 柔和光晕, default 关闭
- **画面:** what the old 画面 tab had: scenes, styles, and 悬停预览.
- **更多,** in this order:
  1. 当前歌曲 (歌词版本, offset)
  2. Window modes
  3. 桌面歌词交互
  - Removed: 「主窗口」, 「打开设置」, 「打开 AI 设置」, and the old global-offset note.

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
