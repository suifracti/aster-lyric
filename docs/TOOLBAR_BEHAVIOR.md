# Main-window toolbar behaviour

Either agent may edit the toolbar and its panels (user decision, 2026-10-20). To stop the behaviour drifting between edits, the rules below are the contract.

- **Code:** `SpotifyLyrics/Views/MainWindow/V3ToolbarModel.swift`
- **Checks:** `Tests/v3_toolbar_model_contract.sh` and `Tests/v3_inspector_navigation_contract.py`
- **Screenshots:** `Scripts/ui-snapshots.sh`

To change a rule, update this file and the contract first, and attach before/after snapshots.

## Buttons
Order: 歌词库 · 搜索 · 译文 · 调整 · 更多 | 设置. 设置 sits at the far right, after a divider.

## Visibility
- **Outside the window:** the toolbar is hidden.
- **Pointer inside the window:** the toolbar is faint (0.32 opacity).
- **Near the top edge, or any panel open:** the toolbar is fully shown.
- Buttons never move between these levels.

## Hover and pin
- **Hovering** 调整, 更多 or 译文 shows a temporary panel inside the app.
  - 译文 opens 调整 on the 当前歌曲 tab.
  - The panel stays open while the pointer is on the button, on the panel, or in a native menu inside it.
  - After the pointer leaves, it closes following a 180 ms grace period.
- **Clicking** pins the panel as a separate tool window. Every click visibly changes something:

| Click | When | Result |
|---|---|---|
| 调整 or 更多 | Not pinned | Pin it |
| 调整 or 更多 | That panel is already pinned | Close it |
| 调整 or 更多 | The other panel is pinned | Switch to this one |
| 译文 | — | Pin 调整 on 当前歌曲 |
| 译文 | 译文 is already lit | Close |
| 调整 | 译文 is lit | Switch to 画面 and keep the panel pinned |

- **Highlighting:** 译文 and 调整 never light up at the same time.
- **Tabs:** switching from hover to pinned keeps the current tab.
- **While pinned:** hovering other buttons does nothing.
- **What closes panels:** 歌词库, 搜索, 设置, Escape and the close button close all panels.
- **Outside clicks:** an outside click closes only the hover panel, never a pinned one.

## Clicks must always land
A click on a panel button counts no matter which path delivers it. Each path calls `V3ToolbarModel.click`:
- the SwiftUI button
- the first-click catcher, used when the window is not key or the app is inactive
- the hover popover's event monitor, used when the popover window overlaps the button

Clicks that land on the popover's transparent arrow or shadow area are forwarded to the toolbar underneath.

## Placement of the pinned window
- **Fits beside the main window on the right:** place it outside, 12 pt from the window.
- **Doesn't fit:** place it against the screen's right edge.
- **Never** to the left of the window.

## Appearance
- **Listening canvas:** always dark.
- **Hover panel:** keeps its dark frosted glass.
- **Pinned panel:** follows the system's light or dark setting.

## Priority
An open panel takes priority over the toolbar, and the toolbar over the window-edge controls. While the pointer is in the toolbar area, or any panel is open, the edge play buttons stay hidden and only the progress rail shows.
