import AppKit
import Foundation

/// Frame persistence for the floating panel. The stored screen token is only
/// a recovery hint; every restore is clamped against a currently connected
/// visible frame before the panel is shown.
@MainActor
final class FloatingLyricsWindowPersistence {
    static let shared = FloatingLyricsWindowPersistence()

    let minimumSize = NSSize(width: 360, height: 120)
    let maximumSize = NSSize(width: 960, height: 640)

    private init() {}

    func defaultFrame() -> NSRect {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: min(820, visible.width), height: min(180, visible.height))
        return NSRect(
            x: visible.midX - size.width / 2,
            y: min(visible.minY + 64, visible.maxY - size.height),
            width: size.width,
            height: size.height
        )
    }

    func restoreFrame(settings: AppSettingsStore) -> NSRect {
        guard settings.restoreWindowState, let saved = settings.savedFloatingWindowFrame else { return defaultFrame() }
        let requested = NSRectFromString(saved)
        guard isUsable(requested) else { return defaultFrame() }
        let screen = NSScreen.lyricsScreen(for: settings.savedFloatingWindowScreenID)
            ?? screen(containing: requested) ?? NSScreen.main ?? NSScreen.screens.first
        return clamp(requested, to: screen?.visibleFrame ?? defaultFrame())
    }

    func save(frame: NSRect, settings: AppSettingsStore) {
        guard settings.restoreWindowState, isUsable(frame) else { return }
        let screen = screen(containing: frame) ?? NSScreen.main
        let safeFrame = clamp(frame, to: screen?.visibleFrame ?? defaultFrame())
        settings.saveFloatingWindowFrame(
            NSStringFromRect(safeFrame),
            screenID: screen?.lyricsFrameScreenID
        )
    }

    func clamp(_ frame: NSRect, to visibleFrame: NSRect) -> NSRect {
        guard visibleFrame.width > 0, visibleFrame.height > 0 else { return defaultFrame() }
        let width = min(max(frame.width, minimumSize.width), min(maximumSize.width, visibleFrame.width))
        let height = min(max(frame.height, minimumSize.height), min(maximumSize.height, visibleFrame.height))
        let x = min(
            max(frame.minX, visibleFrame.minX),
            max(visibleFrame.minX, visibleFrame.maxX - width)
        )
        let y = min(
            max(frame.minY, visibleFrame.minY),
            max(visibleFrame.minY, visibleFrame.maxY - height)
        )
        return NSRect(x: x, y: y, width: width, height: height)
    }

    func placing(_ frame: NSRect, from source: NSRect, on destination: NSRect) -> NSRect {
        let previous = clamp(frame, to: source)
        var next = clamp(previous, to: destination)
        let x = (previous.minX - source.minX) / max(1, source.width - previous.width)
        let y = (previous.minY - source.minY) / max(1, source.height - previous.height)
        next.origin.x = destination.minX + (destination.width - next.width) * x
        next.origin.y = destination.minY + (destination.height - next.height) * y
        return next
    }

    private func screen(containing frame: NSRect) -> NSScreen? {
        NSScreen.screens.filter { $0.visibleFrame.intersection(frame).area > 0 }.max { lhs, rhs in
            lhs.visibleFrame.intersection(frame).area < rhs.visibleFrame.intersection(frame).area
        }
    }

    private func isUsable(_ frame: NSRect) -> Bool {
        frame.origin.x.isFinite && frame.origin.y.isFinite
            && frame.width.isFinite && frame.height.isFinite
            && frame.width >= 1 && frame.height >= 1
    }
}

private extension CGRect {
    var area: CGFloat { max(0, width) * max(0, height) }
}
