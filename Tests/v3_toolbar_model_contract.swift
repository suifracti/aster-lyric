// Rules from docs/TOOLBAR_BEHAVIOR.md (bad5213).
import XCTest
import CoreGraphics
import Foundation
import SwiftUI
@testable import SpotifyLyrics

final class V3ToolbarPresentationTests: XCTestCase {
    @MainActor
    func testPanelReportsContentHeightInsteadOfAFullScreen() async {
        let height = expectation(description: "the host receives the short panel's height")
        let suite = "panel-height-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettingsStore(defaults: defaults)
        let state = PlaybackState(provider: MockPlaybackProvider(), settings: settings)
        let root = V3ToolbarQuickControls(panel: .more, state: state, search: state.songSearchManager,
                                         openLibrary: {}, openSearch: {}) { Text("短面板") }
        .onPreferenceChange(V3ToolPanelHeight.self) { value in
            if value > 0 && value < 100 { height.fulfill() }
        }
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 360, height: 520),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        await fulfillment(of: [height], timeout: 2)
    }

    @MainActor
    func testLyricBarUsesExistingPreferences() {
        let defaults = UserDefaults(suiteName: "lyric-bar-\(UUID())")!
        let settings = AppSettingsStore(defaults: defaults)
        let actions = V3LyricActions(settings: settings)
        var display = settings.displayPreferences
        display.fontSize = 22
        settings.displayPreferences = display
        XCTAssertEqual(actions.fontSize(2), "字号 24")
        XCTAssertEqual(settings.displayPreferences.fontSize, 24)
        _ = actions.fontSize(100)
        XCTAssertEqual(settings.displayPreferences.fontSize, 42)
        _ = actions.fontSize(-100)
        XCTAssertEqual(settings.displayPreferences.fontSize, 14)
        settings.lyricsOffsetStore.activate(LyricsOffsetScope(canonicalTrackStableKey: "bar-fixture", lyricsVersionID: UUID()))
        XCTAssertEqual(actions.offset(0.1), "偏移 +0.1s")
        XCTAssertEqual(actions.offset(-0.1), "偏移 +0.0s")
        XCTAssertEqual(actions.offset(nil), "偏移 +0.0s")
        let original = actions.family
        _ = actions.scene(1)
        XCTAssertNotEqual(actions.family, original)
        _ = actions.scene(-1)
        XCTAssertEqual(actions.family, original)
    }

    func testHorizontalSceneGestureLeavesVerticalScrollAlone() {
        var swipe = V3SceneSwipe()
        XCTAssertNil(swipe.move(x: 0, y: 80))
        XCTAssertNil(swipe.move(x: -25, y: 0))
        XCTAssertEqual(swipe.move(x: -40, y: 0), 1)
        XCTAssertNil(swipe.move(x: -80, y: 0))
        swipe.begin()
        XCTAssertEqual(swipe.move(x: 65, y: 0), -1)
    }

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

    @MainActor
    func testCategoryShortcutUsesTheFullSelectorsStyle() {
        let suite = "lyricsq-family-shortcut-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettingsStore(defaults: defaults)
        settings.selectV3Scene(.coverPhoto, renderer: .classicGaussian)
        let current = V3SceneFamily.cover.target(settings: settings)
        XCTAssertEqual(current.0, .coverPhoto)
        XCTAssertEqual(current.1, .classicGaussian)
        let first = V3SceneFamily.focus.target(settings: settings)
        XCTAssertEqual(first.0, .focusedLyrics)
        XCTAssertEqual(first.1, .lyricsOnly)
    }

    func testHoverPanelStaysInsideTheMainWindow() {
        let owner = CGRect(x: 704, y: 540, width: 1152, height: 720)
        let overflowing = CGRect(x: 1547, y: 825, width: 346, height: 376)
        let placed = V3HoverPanelPlacement.frame(overflowing, inside: owner)
        XCTAssertTrue(owner.contains(placed))
        XCTAssertEqual(placed.maxX, owner.maxX)
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
