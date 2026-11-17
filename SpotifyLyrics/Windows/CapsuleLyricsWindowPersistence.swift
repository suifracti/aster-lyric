import AppKit

#if DEBUG
/// Internal-only comparison anchors for design-review builds. This type and
/// its non-center cases are not compiled into Release.
enum CapsuleDebugAnchor: String, CaseIterable {
    case topLeft
    case topCenter
    case topRight
}
#endif

/// Top-safe-area positioning for the capsule.  Unlike the floating lyrics
/// window this stores no arbitrary frame: the three presentation sizes are
/// fixed and only the horizontal offset from the target display's center is
/// persisted. An explicit display choice takes priority over following the main window.
@MainActor
final class CapsuleLyricsWindowPersistence {
    static let shared = CapsuleLyricsWindowPersistence()

    let collapsedSize = NSSize(width: 360, height: 46)
    let hoverSize = NSSize(width: 520, height: 82)
    let expandedSize = NSSize(width: 620, height: 220)
    private let topInset: CGFloat = 10

    private init() {}

    func size(for state: CapsulePresentationState) -> NSSize {
        switch state {
        case .collapsed: return collapsedSize
        case .hover: return hoverSize
        case .expanded: return expandedSize
        }
    }

    func size(
        for state: CapsulePresentationState,
        presentation: CapsuleLyricsPresentationVersion
    ) -> NSSize {
        guard presentation == .dynamicIslandDarkV4 else {
            return size(for: state)
        }
        return CapsuleDynamicIslandDarkV4.targetSize(for: state)
    }

    func targetScreen(mainWindow: NSWindow?, settings: AppSettingsStore?) -> NSScreen? {
        NSScreen.lyricsScreen(for: settings?.capsulePreferredDisplayID)
            ?? mainWindow?.screen
            ?? NSScreen.lyricsScreen(for: settings?.capsuleWindowScreenID)
            ?? NSScreen.main ?? NSScreen.screens.first
    }

    func frame(
        for state: CapsulePresentationState,
        screen: NSScreen,
        horizontalOffset: CGFloat
    ) -> NSRect {
        let visible = screen.visibleFrame
        let requested = size(for: state)
        let width = min(requested.width, max(1, visible.width))
        let height = min(requested.height, max(1, visible.height))
        let x = visible.midX - width / 2 + horizontalOffset
        return makeTopFrame(
            x: x,
            height: height,
            width: width,
            visible: visible,
            topSafeInset: topSafeInset(for: screen)
        )
    }

    func frame(
        for state: CapsulePresentationState,
        screen: NSScreen,
        horizontalOffset: CGFloat,
        presentation: CapsuleLyricsPresentationVersion
    ) -> NSRect {
        guard presentation == .dynamicIslandDarkV4 else {
            return frame(
                for: state,
                screen: screen,
                horizontalOffset: horizontalOffset
            )
        }

        return CapsuleDynamicIslandDarkV4.topCenteredFrame(
            for: state,
            visibleFrame: screen.visibleFrame,
            safeTopInset: topSafeInset(for: screen),
            // v4's phase-2 envelope is anchored at the screen center. The
            // existing v2 offset remains persisted for v2/v3 and is not
            // allowed to displace the v4 verification shell.
            horizontalOffset: 0
        )
    }

#if DEBUG
    func frame(
        for state: CapsulePresentationState,
        screen: NSScreen,
        horizontalOffset: CGFloat,
        debugAnchor: CapsuleDebugAnchor
    ) -> NSRect {
        let visible = screen.visibleFrame
        let requested = size(for: state)
        let width = min(requested.width, max(1, visible.width))
        let height = min(requested.height, max(1, visible.height))
        let x: CGFloat
        switch debugAnchor {
        case .topLeft:
            x = visible.minX + horizontalOffset
        case .topCenter:
            x = visible.midX - width / 2 + horizontalOffset
        case .topRight:
            x = visible.maxX - width - horizontalOffset
        }
        return makeTopFrame(
            x: x,
            height: height,
            width: width,
            visible: visible,
            topSafeInset: topSafeInset(for: screen)
        )
    }

    func frame(
        for state: CapsulePresentationState,
        screen: NSScreen,
        horizontalOffset: CGFloat,
        debugAnchor: CapsuleDebugAnchor,
        presentation: CapsuleLyricsPresentationVersion
    ) -> NSRect {
        guard presentation != .dynamicIslandDarkV4 else {
            // v4's verification build intentionally validates the real
            // top-center anchor; the old comparison anchors remain for v2.
            return frame(
                for: state,
                screen: screen,
                horizontalOffset: horizontalOffset,
                presentation: presentation
            )
        }
        return frame(
            for: state,
            screen: screen,
            horizontalOffset: horizontalOffset,
            debugAnchor: debugAnchor
        )
    }
#endif

    func restoreFrame(
        for state: CapsulePresentationState,
        settings: AppSettingsStore,
        mainWindow: NSWindow?
    ) -> NSRect {
        let screen = targetScreen(mainWindow: mainWindow, settings: settings)
        guard let screen else {
            return NSRect(origin: .zero, size: size(for: state))
        }
        return frame(
            for: state,
            screen: screen,
            horizontalOffset: CGFloat(settings.capsuleWindowHorizontalOffset)
        )
    }

    func restoreFrame(
        for state: CapsulePresentationState,
        settings: AppSettingsStore,
        mainWindow: NSWindow?,
        presentation: CapsuleLyricsPresentationVersion
    ) -> NSRect {
        let screen = targetScreen(mainWindow: mainWindow, settings: settings)
        guard let screen else {
            return NSRect(origin: .zero, size: size(for: state, presentation: presentation))
        }
        return frame(
            for: state,
            screen: screen,
            horizontalOffset: CGFloat(settings.capsuleWindowHorizontalOffset),
            presentation: presentation
        )
    }

#if DEBUG
    func restoreFrame(
        for state: CapsulePresentationState,
        settings: AppSettingsStore,
        mainWindow: NSWindow?,
        debugAnchor: CapsuleDebugAnchor
    ) -> NSRect {
        let screen = targetScreen(mainWindow: mainWindow, settings: settings)
        guard let screen else {
            return NSRect(origin: .zero, size: size(for: state))
        }
        return frame(
            for: state,
            screen: screen,
            horizontalOffset: CGFloat(settings.capsuleWindowHorizontalOffset),
            debugAnchor: debugAnchor
        )
    }

    func restoreFrame(
        for state: CapsulePresentationState,
        settings: AppSettingsStore,
        mainWindow: NSWindow?,
        debugAnchor: CapsuleDebugAnchor,
        presentation: CapsuleLyricsPresentationVersion
    ) -> NSRect {
        let screen = targetScreen(mainWindow: mainWindow, settings: settings)
        guard let screen else {
            return NSRect(origin: .zero, size: size(for: state, presentation: presentation))
        }
        return frame(
            for: state,
            screen: screen,
            horizontalOffset: CGFloat(settings.capsuleWindowHorizontalOffset),
            debugAnchor: debugAnchor,
            presentation: presentation
        )
    }
#endif

    private func topSafeInset(for screen: NSScreen) -> CGFloat {
        max(topInset, screen.safeAreaInsets.top)
    }

    private func makeTopFrame(
        x: CGFloat,
        height: CGFloat,
        width: CGFloat,
        visible: NSRect,
        topSafeInset: CGFloat
    ) -> NSRect {
        let y = visible.maxY - height - topSafeInset
        return clampTopFrame(
            NSRect(x: x, y: y, width: width, height: height),
            to: visible,
            topInset: topSafeInset
        )
    }

    func horizontalOffset(for frame: NSRect, screen: NSScreen) -> CGFloat {
        frame.midX - screen.visibleFrame.midX
    }

    func clampTopFrame(_ frame: NSRect, to visible: NSRect) -> NSRect {
        clampTopFrame(frame, to: visible, topInset: topInset)
    }

    func clampTopFrame(_ frame: NSRect, screen: NSScreen) -> NSRect {
        clampTopFrame(
            frame,
            to: screen.visibleFrame,
            topInset: topSafeInset(for: screen)
        )
    }

    private func clampTopFrame(_ frame: NSRect, to visible: NSRect, topInset: CGFloat) -> NSRect {
        guard visible.width > 0, visible.height > 0 else { return frame }
        let width = min(max(1, frame.width), visible.width)
        let height = min(max(1, frame.height), visible.height)
        let x = min(max(frame.minX, visible.minX), max(visible.minX, visible.maxX - width))
        let y = min(
            max(frame.minY, visible.minY),
            max(visible.minY, visible.maxY - height - topInset)
        )
        return NSRect(x: x, y: y, width: width, height: height)
    }
}
