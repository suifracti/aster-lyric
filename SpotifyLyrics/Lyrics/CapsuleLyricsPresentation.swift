import Foundation
import CoreGraphics

/// Minimal identity contract shared by every capsule renderer.
///
/// A presentation is only a rendering choice. It must not own playback,
/// lyric-session, timing, window, or persistence state.
public protocol CapsulePresentation: Sendable {
    var id: String { get }
}

/// Stable identifiers for the capsule's independently switchable presentation
/// paths. The legacy path remains available as an internal rollback target;
/// only the current value is used by the active capsule view.
public enum CapsuleLyricsPresentationVersion: String, CaseIterable, Sendable, CapsulePresentation {
    case legacyV1 = "capsule.legacy.v1"
    case controlFocusedV2 = "capsule.controlFocused.v2"
    case dynamicIslandDarkV4 = "capsule.dynamicIslandDark.v4"

    public static let current: Self = .dynamicIslandDarkV4
    public static let archived: [Self] = [.legacyV1]

    public var id: String { rawValue }
}

/// The v4 shape envelope and top-center geometry.  This is deliberately a
/// value-only layer: it knows nothing about windows, playback, lyrics, or
/// persistence.  AppKit maps the resulting frame onto the existing capsule
/// controller.
public enum CapsuleDynamicIslandDarkV4 {
    public static let collapsedSize = CGSize(width: 312, height: 40)
    public static let hoverSize = CGSize(width: 332, height: 44)
    public static let expandedSize = CGSize(width: 600, height: 188)

    /// Fixed production host envelope. The historic public name remains an
    /// API compatibility alias for verification tools.
    public static let debugEnvelopeSize = CGSize(width: 680, height: 240)

    public static func targetSize(for state: CapsulePresentationState) -> CGSize {
        switch state {
        case .collapsed:
            return collapsedSize
        case .hover:
            return hoverSize
        case .expanded:
            return expandedSize
        }
    }

    public static func clampedSize(
        for state: CapsulePresentationState,
        availableSize: CGSize
    ) -> CGSize {
        let target = targetSize(for: state)
        return CGSize(
            width: min(target.width, max(1, availableSize.width)),
            height: min(target.height, max(1, availableSize.height))
        )
    }

    /// Returns the fixed transparent host frame for the top-attached island. AppKit coordinates use the physical screen frame, so the
    /// envelope's top edge is exactly `screenFrame.maxY` with no visible-frame
    /// or legacy top-inset adjustment.
    public static func topAttachedEnvelopeFrame(
        screenFrame: CGRect,
        envelopeSize: CGSize = debugEnvelopeSize
    ) -> CGRect {
        guard screenFrame.width > 0, screenFrame.height > 0 else {
            return CGRect(origin: screenFrame.origin, size: envelopeSize)
        }

        let size = CGSize(
            width: min(max(1, envelopeSize.width), screenFrame.width),
            height: min(max(1, envelopeSize.height), screenFrame.height)
        )
        return CGRect(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }

    /// Returns the internal island rect in the fixed envelope's bottom-left
    /// coordinate space. Its top edge stays flush with the envelope top while
    /// the state change only moves the bottom edge downward.
    public static func topAttachedIslandFrame(
        for state: CapsulePresentationState,
        envelopeSize: CGSize = debugEnvelopeSize
    ) -> CGRect {
        let size = clampedSize(for: state, availableSize: envelopeSize)
        return CGRect(
            x: (envelopeSize.width - size.width) / 2,
            y: envelopeSize.height - size.height,
            width: size.width,
            height: size.height
        )
    }

    /// Returns a frame whose top edge stays anchored while the envelope grows
    /// downwards.  The horizontal offset is intentionally relative to the
    /// screen center and is clamped to the visible frame.
    public static func topCenteredFrame(
        for state: CapsulePresentationState,
        visibleFrame: CGRect,
        safeTopInset: CGFloat,
        horizontalOffset: CGFloat = 0
    ) -> CGRect {
        guard visibleFrame.size.width > 0, visibleFrame.size.height > 0 else {
            return CGRect(origin: visibleFrame.origin, size: targetSize(for: state))
        }

        let safeInset = max(0, safeTopInset)
        let size = clampedSize(
            for: state,
            availableSize: CGSize(
                width: visibleFrame.size.width,
                height: max(1, visibleFrame.size.height - safeInset)
            )
        )
        let minX = visibleFrame.origin.x
        let maxX = max(minX, visibleFrame.origin.x + visibleFrame.size.width - size.width)
        let centeredX = visibleFrame.origin.x + visibleFrame.size.width / 2 - size.width / 2 + horizontalOffset
        let x = min(max(centeredX, minX), maxX)
        let y = max(
            visibleFrame.origin.y,
            visibleFrame.origin.y + visibleFrame.size.height - safeInset - size.height
        )
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }
}

/// Physical display geometry shared by rendering and mouse hit testing.
/// Auxiliary regions are in global screen coordinates. A symmetric reserve
/// also handles displays whose camera housing is slightly off-center.
public struct CapsuleNotchGeometry: Equatable, Sendable {
    public let reservedWidth: CGFloat
    public let depth: CGFloat

    public init(screenFrame: CGRect, safeTopInset: CGFloat,
                auxiliaryLeft: CGRect? = nil, auxiliaryRight: CGRect? = nil) {
        depth = max(0, safeTopInset)
        if depth > 0, let left = auxiliaryLeft, let right = auxiliaryRight,
           right.minX > left.maxX {
            reservedWidth = min(screenFrame.width, 2 * max(screenFrame.midX - left.maxX,
                right.minX - screenFrame.midX) + 16)
        } else {
            // Never put content in a possible hardware area when macOS has
            // reported a safe inset but has not yet supplied auxiliary areas.
            reservedWidth = depth > 0 ? min(screenFrame.width, 240) : 0
        }
    }

    public var expandedContentTop: CGFloat { depth > 0 ? depth + 8 : 0 }

    public func size(for state: CapsulePresentationState) -> CGSize {
        let base = CapsuleDynamicIslandDarkV4.targetSize(for: state)
        if state == .expanded {
            return CGSize(width: max(base.width, reservedWidth + 120), height: base.height + expandedContentTop)
        }
        let captionHeight: CGFloat = state == .hover ? 29 : 22
        let height = depth > 0 ? max(base.height, depth + captionHeight) : base.height
        return CGSize(width: max(base.width, reservedWidth + 100), height: height)
    }

    public func islandFrame(for state: CapsulePresentationState, envelopeSize: CGSize) -> CGRect {
        let requested = size(for: state)
        let size = CGSize(width: min(requested.width, envelopeSize.width),
                          height: min(requested.height, envelopeSize.height))
        return CGRect(x: (envelopeSize.width - size.width) / 2,
                      y: envelopeSize.height - size.height, width: size.width, height: size.height)
    }

    /// A growing shell only enables new click targets after its animation
    /// settles. Intersecting both shapes also excludes each rounded corner.
    public func contains(_ point: CGPoint, state: CapsulePresentationState,
                         restrictingTo previous: CapsulePresentationState,
                         envelopeSize: CGSize) -> Bool {
        contains(point, state: state, envelopeSize: envelopeSize)
            && contains(point, state: previous, envelopeSize: envelopeSize)
    }

    public func contains(_ point: CGPoint, state: CapsulePresentationState, envelopeSize: CGSize) -> Bool {
        let rect = islandFrame(for: state, envelopeSize: envelopeSize)
        guard rect.contains(point) else { return false }
        let radius: CGFloat = min(state == .expanded ? 26 : 22, rect.height / 2)
        // Exclude the transparent rounded bottom corners from the live target.
        if point.y < rect.minY + radius {
            let centerX = point.x < rect.midX ? rect.minX + radius : rect.maxX - radius
            if point.x < rect.minX + radius || point.x > rect.maxX - radius {
                return hypot(point.x - centerX, point.y - rect.minY - radius) <= radius
            }
        }
        let topRadius: CGFloat = state == .expanded ? 14 : 11
        if point.y > rect.maxY - topRadius {
            let centerX = point.x < rect.midX ? rect.minX + topRadius : rect.maxX - topRadius
            if point.x < rect.minX + topRadius || point.x > rect.maxX - topRadius {
                return hypot(point.x - centerX, point.y - rect.maxY + topRadius) <= topRadius
            }
        }
        return true
    }
}

/// Explicit keyboard/AX expansion has no physical hover entry. Keep it open
/// until a real entry, an outside click, or an explicit collapse occurs.
public struct CapsuleExpansionInteraction: Equatable, Sendable {
    public private(set) var awaitsPointerEntry = false
    public init() {}
    public var permitsHoverCollapse: Bool { !awaitsPointerEntry }
    public func permitsHoverCollapse(menuPresented: Bool) -> Bool {
        permitsHoverCollapse && !menuPresented
    }
    public mutating func expanded(explicit: Bool, pointerInside: Bool) {
        awaitsPointerEntry = explicit && !pointerInside
    }
    public mutating func pointerEntered() { awaitsPointerEntry = false }
    public mutating func reset() { awaitsPointerEntry = false }
}

public enum CapsulePresentationState: Equatable, Sendable {
    case collapsed
    case hover
    case expanded
}

/// The deliberately small projection consumed by the top capsule. Playback
/// and lyric sessions remain the owners of the clock and current-line lookup.
/// The following row is retained for the archived/hover presentation; the
/// active control-focused presentation renders only `current` when expanded.
public struct CapsuleLyricsSelection: Equatable, Sendable {
    public let current: LyricLine?
    public let following: LyricLine?
    public let isSynchronized: Bool
    public let status: String?

    public init(
        current: LyricLine?,
        following: LyricLine?,
        isSynchronized: Bool,
        status: String?
    ) {
        self.current = current
        self.following = following
        self.isSynchronized = isSynchronized
        self.status = status
    }
}

public enum CapsuleLyricsPresentation {
    /// Projects only the current and following line from the already shared
    /// current-line index.  It never derives an index from time and never
    /// treats the first plain-text line as a pseudo-current line.
    public static func selection(
        lines: [LyricLine],
        currentIndex: Int?,
        isSynchronized: Bool,
        state: LyricsLoadState
    ) -> CapsuleLyricsSelection {
        switch state {
        case .loading:
            return empty(isSynchronized: false, status: "正在加载歌词…")
        case .noLyrics:
            return empty(isSynchronized: false, status: "暂无歌词")
        case .noSelection:
            return empty(isSynchronized: false, status: "未选择歌词")
        case .noMatch:
            return empty(isSynchronized: false, status: "未找到歌词")
        case .candidates:
            return empty(isSynchronized: false, status: "请回主窗口选择歌词")
        case .failed(_, let failure):
            return empty(isSynchronized: false, status: failure.userFacingMessage)
        case .alignmentQueued, .alignmentRunning:
            return empty(isSynchronized: false, status: "未排轴")
        case .alignmentPreview:
            return empty(isSynchronized: false, status: "排轴预览")
        case .idle:
            return empty(isSynchronized: false, status: "等待歌词")
        case .mockPreview:
            return empty(isSynchronized: false, status: "Mock Preview")
        case .loaded:
            break
        }

        // A legacy/manual record can carry an optimistic synchronized flag
        // while all of its lines still have the zero timestamp used by plain
        // text.  The capsule is a live playback surface, so it must fail
        // closed rather than turn the first row into pseudo-sync.
        guard isSynchronized, hasTimingEvidence(lines) else {
            return CapsuleLyricsSelection(
                current: nil,
                following: nil,
                isSynchronized: false,
                status: "纯文本 / 未排轴"
            )
        }

        guard let currentIndex, lines.indices.contains(currentIndex) else {
            return CapsuleLyricsSelection(
                current: nil,
                following: nil,
                isSynchronized: true,
                status: "前奏"
            )
        }

        let followingIndex = currentIndex + 1
        return CapsuleLyricsSelection(
            current: lines[currentIndex],
            following: lines.indices.contains(followingIndex) ? lines[followingIndex] : nil,
            isSynchronized: true,
            status: nil
        )
    }

    private static func empty(isSynchronized: Bool, status: String) -> CapsuleLyricsSelection {
        CapsuleLyricsSelection(
            current: nil,
            following: nil,
            isSynchronized: isSynchronized,
            status: status
        )
    }

    private static func hasTimingEvidence(_ lines: [LyricLine]) -> Bool {
        lines.contains { line in
            if line.timestamp.isFinite, line.timestamp > 0 {
                return true
            }
            if let endTime = line.endTime, endTime.isFinite, endTime > 0 {
                return true
            }
            return false
        }
    }
}
