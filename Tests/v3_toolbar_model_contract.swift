// Behaviour of the main-window toolbar, from docs/TOOLBAR_BEHAVIOR.md.
// Every case below comes from a real user report; change the spec first.
import CoreGraphics
import Foundation

@main
struct ToolbarModelContract {
    static var count = 0
    static func expect(_ ok: Bool, _ message: String, line: Int = #line) {
        count += 1
        if !ok { fatalError("FAIL line \(line): \(message)") }
    }

    static func main() {
        // Hover shows a temporary panel inside the app; leaving closes it
        // only after the grace timer, and not while the pointer is on it.
        var m = V3ToolbarModel()
        expect(m.pointerOnTrigger(.adjust, inside: true) == .cancelHoverDismissal, "hover cancels pending close")
        expect(m.hoverPanel == .adjust && m.pinnedPanel == nil, "hover opens inside")
        expect(m.pointerOnTrigger(.adjust, inside: false) == .scheduleHoverDismissal(.adjust), "leave schedules close")
        _ = m.pointerInPanel(.adjust, inside: true)
        m.dismissTimerFired(.adjust)
        expect(m.hoverPanel == .adjust, "pointer on panel keeps it open")
        expect(m.pointerInPanel(.adjust, inside: false) == .scheduleHoverDismissal(.adjust), "leaving panel schedules close")
        m.dismissTimerFired(.adjust)
        expect(m.mode == .idle, "grace timer closes hover")

        // A native menu inside the hover panel keeps it open.
        _ = m.pointerOnTrigger(.more, inside: true)
        _ = m.menuTrackingBegan()
        _ = m.pointerOnTrigger(.more, inside: false)
        m.dismissTimerFired(.more)
        expect(m.hoverPanel == .more, "menu tracking keeps hover open")
        expect(m.menuTrackingEnded() == .scheduleHoverDismissal(.more), "menu end schedules close")
        m.dismissTimerFired(.more)
        expect(m.mode == .idle, "closes after menu")

        // "悬停的情况下再点击更多没反应": clicking while its hover panel is open pins it.
        m = V3ToolbarModel()
        _ = m.pointerOnTrigger(.more, inside: true)
        m.click(.more)
        expect(m.pinnedPanel == .more && m.hoverPanel == nil, "click during hover pins")
        m.dismissTimerFired(.more)
        expect(m.pinnedPanel == .more, "stale hover timer cannot close a pinned panel")

        // While pinned, hovering other triggers does nothing.
        _ = m.pointerOnTrigger(.adjust, inside: true)
        expect(m.pinnedPanel == .more && m.hoverPanel == nil, "pinned ignores hover")
        m.click(.more)
        expect(m.mode == .idle, "second click closes")

        // 调整 ↔ 更多 switch directly.
        m.click(.adjust); m.click(.more)
        expect(m.pinnedPanel == .more, "switch pinned panel")

        // 译文: hover previews 当前歌曲; click pins 调整 on 当前歌曲; again closes.
        m = V3ToolbarModel()
        m.tab = .text
        _ = m.pointerOnTrigger(.translation, inside: true)
        expect(m.hoverPanel == .translation && m.tab == .currentSong, "译文 hover opens current song")
        m.click(.translation)
        expect(m.pinnedPanel == .adjust && m.tab == .currentSong, "译文 click pins adjust/current song")
        expect(m.isSelected(.translation) && !m.isSelected(.adjust), "only 译文 lit")
        m.click(.translation)
        expect(m.mode == .idle, "译文 again closes, never a silent no-op")

        // 译文 while 调整 is pinned on another tab: switch, don't close.
        m.click(.adjust); m.tab = .picture
        m.click(.translation)
        expect(m.pinnedPanel == .adjust && m.tab == .currentSong, "译文 switches tab")
        // 调整 while 译文 is lit: back to 画面, still pinned.
        m.click(.adjust)
        expect(m.pinnedPanel == .adjust && m.tab == .picture && m.isSelected(.adjust), "调整 takes over from 译文")
        m.click(.adjust)
        expect(m.mode == .idle, "调整 again closes")

        // Hover → pin keeps the tab.
        m.tab = .text
        _ = m.pointerOnTrigger(.adjust, inside: true)
        m.click(.adjust)
        expect(m.tab == .text, "pinning keeps the tab")

        // Other toolbar actions and Escape close everything.
        m.dismiss()
        expect(m.mode == .idle, "dismiss closes")
        _ = m.pointerOnTrigger(.adjust, inside: true)
        m.hoverClosed(.adjust)
        expect(m.mode == .idle, "outside click closes hover")
        m.click(.more)
        m.hoverClosed(.more)
        expect(m.pinnedPanel == .more, "a closing hover popover never closes the pinned panel")

        // Placement (user, 2026-10-20): outside on the right when it fits,
        // otherwise against the screen's right edge; never on the left.
        let visible = CGRect(x: 0, y: 0, width: 1800, height: 1100)
        let requested = CGSize(width: 360, height: 720)
        let roomy = LyricIslandPanelPlacement.frame(owner: CGRect(x: 100, y: 180, width: 900, height: 800), visible: visible, requested: requested)
        expect(roomy.minX == 1012 && !roomy.intersects(CGRect(x: 100, y: 180, width: 900, height: 800)), "beside the window")
        let wide = CGRect(x: 760, y: 180, width: 900, height: 800)
        let edge = LyricIslandPanelPlacement.frame(owner: wide, visible: visible, requested: requested)
        expect(edge.maxX == visible.maxX - 8, "no room: screen right edge")
        expect(edge.minX > wide.minX, "never left of the window")

        print("PASS \(count) toolbar behaviour checks")
    }
}
