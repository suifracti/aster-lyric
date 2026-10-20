// Rules from docs/TOOLBAR_BEHAVIOR.md (b5a1ed5).
import XCTest
import CoreGraphics
@testable import SpotifyLyrics

final class V3ToolbarPresentationTests: XCTestCase {
    func testHoverLifetimeAndMenus() {
        XCTAssertEqual(V3ToolbarModel.hoverGrace, .milliseconds(180))
        for panel in V3ToolbarModel.Panel.allCases {
            var m = V3ToolbarModel()
            XCTAssertEqual(m.pointerOnTrigger(panel, inside: true), .cancelHoverDismissal)
            m.dismissTimerFired(panel)
            XCTAssertEqual(m.hoverPanel, panel, "the button keeps its hover open")
            XCTAssertEqual(m.pointerOnTrigger(panel, inside: false), .scheduleHoverDismissal(panel))
            _ = m.pointerInPanel(panel, inside: true)
            m.dismissTimerFired(panel)
            XCTAssertEqual(m.hoverPanel, panel, "the panel keeps itself open")
            _ = m.menuTrackingBegan()
            _ = m.pointerInPanel(panel, inside: false)
            m.dismissTimerFired(panel)
            XCTAssertEqual(m.hoverPanel, panel, "a native menu keeps hover open")
            XCTAssertEqual(m.menuTrackingEnded(), .scheduleHoverDismissal(panel))
            m.dismissTimerFired(panel)
            XCTAssertEqual(m.mode, .idle)
        }
    }

    func testClicksPinRepeatSwitchAndDismiss() {
        XCTAssertEqual(V3ToolbarModel.Panel.allCases.map(\.title), ["歌词库", "搜索", "译文", "文字", "画面", "更多"])
        for panel in [V3ToolbarModel.Panel.translation, .text, .picture, .more] {
            var m = V3ToolbarModel()
            _ = m.pointerOnTrigger(panel, inside: true)
            m.click(panel)
            XCTAssertEqual(m.pinnedPanel, panel, "a hover click pins that same full panel")
            for other in V3ToolbarModel.Panel.allCases {
                XCTAssertEqual(m.isSelected(other), other == panel)
                _ = m.pointerOnTrigger(other, inside: true)
                XCTAssertEqual(m.pinnedPanel, panel, "pinned ignores other hovers")
            }
            m.hoverClosed(panel)
            XCTAssertEqual(m.pinnedPanel, panel, "outside clicks never close a pinned panel")
            m.click(panel)
            XCTAssertEqual(m.mode, .idle, "repeat click closes")
            m.click(panel)
            let other: V3ToolbarModel.Panel = panel == .more ? .text : .more
            m.click(other)
            XCTAssertEqual(m.pinnedPanel, other, "another button switches directly")
            m.dismiss() // Escape and the close button share this action.
            XCTAssertEqual(m.mode, .idle)
        }
        for action in [V3ToolbarModel.Panel.library, .search] {
            var m = V3ToolbarModel()
            m.click(.translation)
            m.click(action)
            XCTAssertEqual(m.mode, .idle, "library/search open their window and close panels")
        }
        var m = V3ToolbarModel()
        _ = m.pointerOnTrigger(.more, inside: true)
        m.hoverClosed(.more)
        XCTAssertEqual(m.mode, .idle, "outside clicks close hover")
        m.click(.text)
        m.click() // Settings has no hover panel.
        XCTAssertEqual(m.mode, .idle)
    }

    func testVisibilityAndEdgePriority() {
        var m = V3ToolbarModel()
        XCTAssertEqual(m.opacity(pointerInside: false, nearTop: false), 0)
        XCTAssertEqual(m.opacity(pointerInside: true, nearTop: false), 0.32)
        XCTAssertEqual(m.opacity(pointerInside: true, nearTop: true), 1)
        XCTAssertFalse(m.suppressesEdgeControls(nearTop: false))
        XCTAssertTrue(m.suppressesEdgeControls(nearTop: true))
        _ = m.pointerOnTrigger(.text, inside: true)
        XCTAssertEqual(m.opacity(pointerInside: false, nearTop: false), 1)
        XCTAssertTrue(m.suppressesEdgeControls(nearTop: false))
        m.click(.text)
        XCTAssertEqual(m.opacity(pointerInside: false, nearTop: false), 1)
        XCTAssertTrue(m.suppressesEdgeControls(nearTop: false))
        m.dismiss()
        XCTAssertTrue(m.suppressesEdgeControls(nearTop: false, otherPanelOpen: true))
        XCTAssertEqual(m.opacity(pointerInside: false, nearTop: false, otherPanelOpen: true), 1)
    }

    func testPinnedPlacement() {
        let visible = CGRect(x: 0, y: 0, width: 1800, height: 1100)
        let requested = CGSize(width: 360, height: 720)
        let owner = CGRect(x: 100, y: 180, width: 900, height: 800)
        let roomy = LyricIslandPanelPlacement.frame(owner: owner, visible: visible, requested: requested)
        XCTAssertEqual(roomy.minX, owner.maxX + 12)
        XCTAssertFalse(roomy.intersects(owner))
        let wide = CGRect(x: 760, y: 180, width: 900, height: 800)
        let edge = LyricIslandPanelPlacement.frame(owner: wide, visible: visible, requested: requested)
        XCTAssertEqual(edge.maxX, visible.maxX - 8)
        XCTAssertGreaterThan(edge.minX, wide.minX, "never to the left")
    }
}
