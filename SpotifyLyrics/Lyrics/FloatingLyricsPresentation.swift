import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Stable identifiers for the two renderers that can be selected for the
/// single retained floating lyrics panel.
public enum FloatingLyricsPresentationVersion: String, CaseIterable, Codable, Sendable {
    case legacyPanel = "floatingLyrics.legacyPanel.v1"
    case transparentV2 = "floatingLyrics.transparent.v2"

    public static let current: Self = .transparentV2
    public static let archived: [Self] = [.legacyPanel]

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .legacyPanel: return "旧版卡片"
        case .transparentV2: return "透明桌面歌词"
        }
    }
}

public enum FloatingLyricsSurfaceStyle: String, CaseIterable, Codable, Sendable {
    case ultraTransparent
    case lightMaterial

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .ultraTransparent: return "超透明"
        case .lightMaterial: return "浅色材质"
        }
    }
}

/// Pure presentation helpers shared by the floating view and its contract
/// tests. This layer contains no playback clock and never mutates lyrics.
public struct FloatingLyricsSelection: Equatable, Sendable {
    public let visibleIndices: [Int]
    public let currentIndex: Int?
    public let autoScroll: Bool

    public init(visibleIndices: [Int], currentIndex: Int?, autoScroll: Bool) {
        self.visibleIndices = visibleIndices
        self.currentIndex = currentIndex
        self.autoScroll = autoScroll
    }
}

public enum FloatingLyricsPresentationHelper {
    public static func selection(
        lines: [LyricLine],
        currentIndex: Int?,
        isSynchronized: Bool,
        isPlaying: Bool,
        precedingCount: Int = 0,
        followingCount: Int = 1
    ) -> FloatingLyricsSelection {
        guard isSynchronized, !lines.isEmpty else {
            return FloatingLyricsSelection(
                visibleIndices: lines.indices.map { $0 },
                currentIndex: nil,
                autoScroll: false
            )
        }

        // Before the first timed line there is no current lyric yet. Keep a
        // small leading projection instead of expanding to the full document;
        // the floating window must remain bounded even during an intro.
        guard let currentIndex, lines.indices.contains(currentIndex) else {
            let upper = min(lines.count - 1, max(0, followingCount))
            return FloatingLyricsSelection(
                visibleIndices: Array(0...upper),
                currentIndex: nil,
                autoScroll: false
            )
        }

        let lower = max(0, currentIndex - max(0, precedingCount))
        let upper = min(lines.count - 1, currentIndex + max(0, followingCount))
        return FloatingLyricsSelection(
            visibleIndices: Array(lower...upper),
            currentIndex: currentIndex,
            // A paused player still needs the current line to remain in view;
            // the helper never advances time and only describes the target.
            autoScroll: true
        )
    }

    /// Kept deliberately small: the floating window never owns a timer. It
    /// is useful for pure contracts and for callers that need to reason about
    /// a paused state without starting a second playback clock.
    public static func advance(
        currentTime: TimeInterval,
        elapsed: TimeInterval,
        isPlaying: Bool
    ) -> TimeInterval {
        guard isPlaying, elapsed.isFinite, elapsed > 0 else { return currentTime }
        return currentTime + elapsed
    }
}

private final class FloatingTimedRubyLayoutBox: NSObject {
    let value: TimedRubyLayout?

    init(_ value: TimedRubyLayout?) {
        self.value = value
    }
}

final class FloatingTimedRubyLayoutCacheKey: NSObject {
    private struct Inputs: Hashable {
        let originalText: String
        let spans: [TimedTextSpan]
        let fontSize: CGFloat
        let weight: CGFloat
        let showsRuby: Bool
        let rubyTokens: [LyricRubyToken]?
        let design: String
    }

    private let inputs: Inputs

    init(
        originalText: String,
        spans: [TimedTextSpan],
        fontSize: CGFloat,
        weight: CGFloat,
        showsRuby: Bool,
        rubyTokens: [LyricRubyToken]?,
        design: String
    ) {
        inputs = Inputs(
            originalText: originalText,
            spans: spans,
            fontSize: fontSize,
            weight: weight,
            showsRuby: showsRuby,
            rubyTokens: rubyTokens,
            design: design
        )
    }

    override var hash: Int { inputs.hashValue }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? FloatingTimedRubyLayoutCacheKey else { return false }
        return inputs == other.inputs
    }
}

/// Bounded cache for desktop word-timing geometry. Playback time is not part
/// of this key because the layout stores geometry; the live clock is read by
/// the renderer when it paints progress.
public enum FloatingTimedRubyLayoutCache {
    private static let cache: NSCache<FloatingTimedRubyLayoutCacheKey, FloatingTimedRubyLayoutBox> = {
        let cache = NSCache<FloatingTimedRubyLayoutCacheKey, FloatingTimedRubyLayoutBox>()
        cache.countLimit = 512
        return cache
    }()

    static func key(
        originalText: String,
        spans: [TimedTextSpan],
        fontSize: CGFloat,
        weight: CGFloat,
        showsRuby: Bool,
        rubyTokens: [LyricRubyToken]?,
        design: String
    ) -> FloatingTimedRubyLayoutCacheKey {
        FloatingTimedRubyLayoutCacheKey(
            originalText: originalText,
            spans: spans,
            fontSize: fontSize,
            weight: weight,
            showsRuby: showsRuby,
            rubyTokens: rubyTokens,
            design: design
        )
    }

    static func layout(for key: FloatingTimedRubyLayoutCacheKey, make: () -> TimedRubyLayout?) -> TimedRubyLayout? {
        if let cached = cache.object(forKey: key) {
            return cached.value
        }
        let value = make()
        cache.setObject(FloatingTimedRubyLayoutBox(value), forKey: key)
        return value
    }
}

public enum FloatingLyricsStylePanelPlacement: String, Equatable, Sendable {
    case right
    case left
    case above
    case below
}

/// Chooses a detached settings-panel frame so it does not sit on top of the
/// transparent lyric surface. The fallback is clamped to the visible screen
/// when a display is too small to provide a complete side placement.
public struct FloatingLyricsStylePanelLayout: Equatable, Sendable {
    public let placement: FloatingLyricsStylePanelPlacement
    public let frame: CGRect

    public init(
        lyricsFrame: CGRect,
        panelSize: CGSize,
        visibleFrame: CGRect,
        gap: CGFloat = 12
    ) {
        let visible = visibleFrame.standardized
        let safeVisibleWidth = max(1, visible.width)
        let safeVisibleHeight = max(1, visible.height)
        let width = min(max(1, panelSize.width.isFinite ? panelSize.width : 360), safeVisibleWidth)
        let height = min(max(1, panelSize.height.isFinite ? panelSize.height : 620), safeVisibleHeight)
        let safeGap = max(0, gap.isFinite ? gap : 12)

        func clamped(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
            min(max(lower, value), upper)
        }

        let centeredY = clamped(
            lyricsFrame.midY - height / 2,
            lower: visible.minY,
            upper: visible.maxY - height
        )
        let centeredX = clamped(
            lyricsFrame.midX - width / 2,
            lower: visible.minX,
            upper: visible.maxX - width
        )
        let candidates: [(FloatingLyricsStylePanelPlacement, CGRect)] = [
            (.right, CGRect(x: lyricsFrame.maxX + safeGap, y: centeredY, width: width, height: height)),
            (.left, CGRect(x: lyricsFrame.minX - safeGap - width, y: centeredY, width: width, height: height)),
            (.above, CGRect(x: centeredX, y: lyricsFrame.maxY + safeGap, width: width, height: height)),
            (.below, CGRect(x: centeredX, y: lyricsFrame.minY - safeGap - height, width: width, height: height))
        ]

        if let fitting = candidates.first(where: { placement, candidate in
            visible.contains(candidate) && !candidate.intersects(lyricsFrame)
        }) {
            placement = fitting.0
            frame = fitting.1
            return
        }

        let availableSpace: [(FloatingLyricsStylePanelPlacement, CGFloat)] = [
            (.right, visible.maxX - lyricsFrame.maxX),
            (.left, lyricsFrame.minX - visible.minX),
            (.above, visible.maxY - lyricsFrame.maxY),
            (.below, lyricsFrame.minY - visible.minY)
        ]
        let fallbackPlacement = availableSpace.max(by: { $0.1 < $1.1 })?.0 ?? .right
        let fallback = candidates.first(where: { $0.0 == fallbackPlacement })?.1 ?? candidates[0].1
        let clampedFrame = CGRect(
            x: clamped(fallback.minX, lower: visible.minX, upper: visible.maxX - width),
            y: clamped(fallback.minY, lower: visible.minY, upper: visible.maxY - height),
            width: width,
            height: height
        )
        placement = fallbackPlacement
        frame = clampedFrame
    }
}

/// Reserve the same control strip before and during hover so lyrics never jump
/// or sit under controls. Short panels devote their scroll area to one verse.
public struct FloatingLyricsLayout: Equatable, Sendable {
    public let toolbarHeight: CGFloat = 36
    public let contentWidth: CGFloat
    public let followingCount: Int

    public init(width: CGFloat, height: CGFloat) {
        contentWidth = max(1, width.isFinite ? width - 32 : 328)
        followingCount = height >= 280 ? 1 : 0
    }
}

public enum FloatingDesktopLineMode: String, CaseIterable, Sendable {
    case single, double
    public var title: String { self == .single ? "单行" : "双行" }
}

public enum FloatingDesktopTheme: String, CaseIterable, Sendable {
    case mint, amber, ice
    public var title: String {
        switch self { case .mint: return "薄荷"; case .amber: return "暖金"; case .ice: return "冰蓝" }
    }
}

public enum FloatingDesktopRibbonAlignment: String, Equatable, Sendable {
    case center
    case leading
}

/// A text pass plan used by the AppKit desktop renderer. Outline and fill are
/// deliberately separate: the fill is drawn last so a stroke can never tint
/// the interior of the glyph, and masked highlight passes can omit the stroke
/// instead of drawing the same dark edge a second time.
public struct FloatingDesktopTextRenderPlan: Equatable, Sendable {
    public let outlineEnabled: Bool
    public let strokeWidthPercent: Double
    public let fillPassIsOpaque: Bool

    public init(outlineWidth: Double, fontSize: Double, drawOutline: Bool = true) {
        let safeWidth = outlineWidth.isFinite ? min(3, max(0, outlineWidth)) : 0
        let safeFontSize = fontSize.isFinite ? max(1, fontSize) : 1
        outlineEnabled = drawOutline && safeWidth > 0
        strokeWidthPercent = outlineEnabled ? 100 * safeWidth / safeFontSize : 0
        fillPassIsOpaque = true
    }
}

public struct FloatingDesktopColor: Equatable, Sendable {
    public let hex: String
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(hex: String, fallback: String) {
        func parse(_ value: String) -> UInt32? {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let clean = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
            guard clean.count == 6, clean.allSatisfy({ $0.isHexDigit }) else { return nil }
            return UInt32(clean, radix: 16)
        }
        let value = parse(hex) ?? parse(fallback) ?? 0xFFFFFF
        self.hex = String(format: "%06X", value)
        red = Double((value >> 16) & 255) / 255
        green = Double((value >> 8) & 255) / 255
        blue = Double(value & 255) / 255
    }
}

/// Typography caches compare their complete inputs, rather than a delimiter
/// string or Ruby token count. A reading correction can retain the same token
/// count while changing both measured width and the fitted font size.
final class FloatingEstimatedLineWidthCacheKey: NSObject {
    private struct Inputs: Hashable {
        let text: String?
        let rubyTokens: [LyricRubyToken]?
        let hasRuby: Bool
        let fontSize: Double
        let outlineWidth: Double
    }

    private let inputs: Inputs

    init(text: String?, rubyTokens: [LyricRubyToken]?, hasRuby: Bool, fontSize: Double, outlineWidth: Double) {
        inputs = Inputs(
            text: text, rubyTokens: rubyTokens, hasRuby: hasRuby,
            fontSize: fontSize, outlineWidth: outlineWidth
        )
    }

    override var hash: Int { inputs.hashValue }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? FloatingEstimatedLineWidthCacheKey else { return false }
        return inputs == other.inputs
    }
}

final class FloatingFittedFontSizeCacheKey: NSObject {
    private struct Inputs: Hashable {
        let requested: Double
        let height: Double
        let doubleLine: Bool
        let hasRuby: Bool
        let outlineWidth: Double
        let width: Double?
        let text: String?
        let rubyTokens: [LyricRubyToken]?
        let companionText: String?
        let minFontSize: Double
    }

    private let inputs: Inputs

    init(
        requested: Double, height: Double, doubleLine: Bool, hasRuby: Bool,
        outlineWidth: Double, width: Double?, text: String?, rubyTokens: [LyricRubyToken]?,
        companionText: String?, minFontSize: Double
    ) {
        inputs = Inputs(
            requested: requested, height: height, doubleLine: doubleLine,
            hasRuby: hasRuby, outlineWidth: outlineWidth, width: width,
            text: text, rubyTokens: rubyTokens, companionText: companionText,
            minFontSize: minFontSize
        )
    }

    override var hash: Int { inputs.hashValue }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? FloatingFittedFontSizeCacheKey else { return false }
        return inputs == other.inputs
    }
}

public enum FloatingDesktopTypography {
    public static func outlineWidth(_ value: Double) -> Double {
        value.isFinite ? min(3, max(0, value)) : 1.25
    }

    public static func panelOpacity(value: Double, transparent: Bool, keepsTextOpaque: Bool) -> Double {
        if transparent && keepsTextOpaque { return 1 }
        return value.isFinite ? min(1, max(0.45, value)) : 0.96
    }

    public static func firstVisible(_ values: [String?]) -> String? {
        values.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
    }

    public static func ribbonHeight(fontSize: Double, hasRuby: Bool, outlineWidth: Double) -> Double {
        let inset = 2 * (Self.outlineWidth(outlineWidth) + 1)
        return ceil(fontSize * 1.3) + inset
            + (hasRuby ? ceil(fontSize * 0.45 * 1.3) + inset + 2 : 0)
    }

    private static let estimatedLineWidthCache: NSCache<FloatingEstimatedLineWidthCacheKey, NSNumber> = {
        let cache = NSCache<FloatingEstimatedLineWidthCacheKey, NSNumber>()
        cache.countLimit = 512
        return cache
    }()

    private static let fittedFontSizeCache: NSCache<FloatingFittedFontSizeCacheKey, NSNumber> = {
        let cache = NSCache<FloatingFittedFontSizeCacheKey, NSNumber>()
        cache.countLimit = 256
        return cache
    }()

    public static func estimatedLineWidth(
        text: String?,
        rubyTokens: [LyricRubyToken]? = nil,
        hasRuby: Bool = false,
        fontSize: Double,
        outlineWidth: Double = 0
    ) -> Double {
        let cacheKey = FloatingEstimatedLineWidthCacheKey(
            text: text, rubyTokens: rubyTokens, hasRuby: hasRuby,
            fontSize: fontSize, outlineWidth: outlineWidth
        )
        if let cached = estimatedLineWidthCache.object(forKey: cacheKey) {
            return cached.doubleValue
        }

        let inset = max(1, Self.outlineWidth(outlineWidth) + 1)
        #if canImport(AppKit)
        let baseFont = NSFont.systemFont(ofSize: CGFloat(fontSize), weight: .bold)
        let rubyFont = NSFont.systemFont(ofSize: CGFloat(fontSize * 0.45), weight: .medium)

        if hasRuby {
            let tokens: [LyricRubyToken] = {
                if let rubyTokens, !rubyTokens.isEmpty { return rubyTokens }
                if let text, !text.isEmpty { return [LyricRubyToken(id: 0, surface: text, ruby: nil)] }
                return []
            }()

            var total: Double = 0
            var currentKey: Int?
            var groupTokenCount = 0
            var groupTokensWithRuby = 0

            for token in tokens {
                let key = token.id / 10_000
                if currentKey != key {
                    if groupTokenCount > 1 && groupTokensWithRuby == 1 {
                        total += 10
                    }
                    currentKey = key
                    groupTokenCount = 0
                    groupTokensWithRuby = 0
                }
                groupTokenCount += 1

                let rubyText: String? = {
                    if let ruby = token.ruby, !ruby.isEmpty { return ruby }
                    if token.surface.unicodeScalars.contains(where: { (0x30A1...0x30FA).contains($0.value) }) {
                        return token.surface
                    }
                    return nil
                }()
                if rubyText != nil { groupTokensWithRuby += 1 }

                let surfaceWidth = token.surface.isEmpty ? 0 : (ceil(Double((token.surface as NSString).size(withAttributes: [.font: baseFont]).width)) + inset * 2)
                let rubyWidth: Double = {
                    guard let rubyText, !rubyText.isEmpty else { return 0 }
                    return ceil(Double((rubyText as NSString).size(withAttributes: [.font: rubyFont]).width)) + inset * 2
                }()
                total += max(surfaceWidth, rubyWidth)
            }
            if groupTokenCount > 1 && groupTokensWithRuby == 1 {
                total += 10
            }
            let result = total + 8
            estimatedLineWidthCache.setObject(NSNumber(value: result), forKey: cacheKey)
            return result
        }

        guard let text, !text.isEmpty else {
            estimatedLineWidthCache.setObject(NSNumber(value: 0), forKey: cacheKey)
            return 0
        }
        let result = ceil(Double((text as NSString).size(withAttributes: [.font: baseFont]).width)) + inset * 2 + 8
        estimatedLineWidthCache.setObject(NSNumber(value: result), forKey: cacheKey)
        return result
        #else
        if hasRuby {
            let tokens = rubyTokens ?? (text.map { [LyricRubyToken(id: 0, surface: $0, ruby: nil)] } ?? [])
            var total: Double = 0
            for token in tokens {
                let sWidth = Double(token.surface.count) * fontSize + inset * 2
                let rWidth = Double(token.ruby?.count ?? 0) * (fontSize * 0.45) + inset * 2
                total += max(sWidth, rWidth)
            }
            return total + 8
        }
        guard let text, !text.isEmpty else { return 0 }
        return Double(text.count) * fontSize + inset * 2 + 8
        #endif
    }

    public static func fittedFontSize(
        requested: Double,
        height: Double,
        doubleLine: Bool,
        hasRuby: Bool = false,
        outlineWidth: Double = 0,
        width: Double? = nil,
        text: String? = nil,
        rubyTokens: [LyricRubyToken]? = nil,
        companionText: String? = nil,
        minFontSize: Double = 14
    ) -> Double {
        let cacheKey = FloatingFittedFontSizeCacheKey(
            requested: requested, height: height, doubleLine: doubleLine,
            hasRuby: hasRuby, outlineWidth: outlineWidth, width: width,
            text: text, rubyTokens: rubyTokens, companionText: companionText,
            minFontSize: minFontSize
        )
        if let cached = fittedFontSizeCache.object(forKey: cacheKey) {
            return cached.doubleValue
        }

        var size = fontSize(requested)
        let availableHeight = height.isFinite ? max(1, height) : 84
        while size > 12 {
            let primary = ribbonHeight(fontSize: size, hasRuby: hasRuby, outlineWidth: outlineWidth)
            let companion = doubleLine ? ribbonHeight(fontSize: size * 0.66, hasRuby: false, outlineWidth: outlineWidth) + 7 : 0
            if primary + companion + 16 <= availableHeight { break }
            size -= 0.25
        }
        size = max(12, size)

        if let width, width.isFinite, width > 0 {
            let targetWidth = max(1, width - 8)
            let minWidthSize = min(size, max(12, minFontSize))
            func neededWidth(at testSize: Double) -> Double {
                let primaryWidth = estimatedLineWidth(
                    text: text,
                    rubyTokens: rubyTokens,
                    hasRuby: hasRuby,
                    fontSize: testSize,
                    outlineWidth: outlineWidth
                )
                let companionWidth = (doubleLine && companionText != nil)
                    ? estimatedLineWidth(
                        text: companionText,
                        rubyTokens: nil,
                        hasRuby: false,
                        fontSize: testSize * 0.66,
                        outlineWidth: outlineWidth
                    )
                    : 0
                return max(primaryWidth, companionWidth)
            }

            if neededWidth(at: size) > targetWidth {
                if neededWidth(at: minWidthSize) > targetWidth {
                    size = minWidthSize
                } else {
                    var low = minWidthSize
                    var high = size
                    while high - low > 0.5 {
                        let mid = floor((low + high) / 2 * 2) / 2
                        if neededWidth(at: mid) <= targetWidth {
                            low = mid
                        } else {
                            high = mid - 0.5
                        }
                    }
                    size = low
                }
            }
        }
        let result = max(12, size)
        fittedFontSizeCache.setObject(NSNumber(value: result), forKey: cacheKey)
        return result
    }

    /// Spatial reveal only: never used as word highlighting or a playback clock.
    public static func ribbonOffset(textWidth: Double, viewport: Double, elapsed: Double, duration: Double) -> Double {
        guard textWidth.isFinite, viewport.isFinite, elapsed.isFinite, duration.isFinite else { return 0 }
        let overflow = max(0, textWidth - viewport)
        let progress = min(1, max(0, (elapsed - 0.5) / max(1, duration - 1)))
        return overflow * progress
    }

    /// Returns the visible placement of a ribbon. A zero or missing measured
    /// width means layout has not reported the text yet; it must not be
    /// treated as a genuinely zero-width line and centered into the right
    /// half of the clipped viewport.
    public static func ribbonPlacementOffset(
        measuredWidth: Double?,
        viewport: Double,
        elapsed: Double,
        duration: Double
    ) -> Double {
        guard let measuredWidth,
              measuredWidth.isFinite,
              measuredWidth > 0,
              viewport.isFinite,
              viewport > 0 else {
            return 0
        }
        if measuredWidth > viewport {
            return -ribbonOffset(
                textWidth: measuredWidth,
                viewport: viewport,
                elapsed: elapsed,
                duration: duration
            )
        }
        return max(0, (viewport - measuredWidth) / 2)
    }

    /// Chooses the frame alignment independently from the scroll offset. A
    /// missing measurement is still a live line, so a short line must not
    /// flash at the leading edge and then jump to center on the first
    /// PreferenceKey callback. Overflowing lines stay leading-aligned so the
    /// existing left-to-right reveal remains intact.
    public static func ribbonAlignment(
        measuredWidth: Double?,
        viewport: Double
    ) -> FloatingDesktopRibbonAlignment {
        guard let measuredWidth,
              measuredWidth.isFinite,
              measuredWidth > 0,
              viewport.isFinite,
              viewport > 0 else {
            return .center
        }
        return measuredWidth > viewport ? .leading : .center
    }

    public static func fontSize(_ value: Double) -> Double {
        value.isFinite ? min(64, max(22, value)) : 34
    }

    public static func companion(mode: FloatingDesktopLineMode, translation: String?, next: String?) -> String? {
        guard mode == .double else { return nil }
        return [translation, next].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    /// Resolves the desktop inspector's explicit second-line choice. Unlike
    /// the legacy helper above, this does not silently substitute another
    /// layer, so changing the Picker is immediately observable.
    public static func selectedCompanion(
        mode: FloatingDesktopLineMode,
        selection: String,
        translation: String?,
        next: String?,
        kana: String?,
        reading: String?
    ) -> String? {
        guard mode == .double else { return nil }
        let value: String?
        switch selection {
        case "kana": value = kana
        case "reading": value = reading
        case "next", "translation":
            let trimmedTranslation = translation?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmedTranslation, !trimmedTranslation.isEmpty {
                value = trimmedTranslation
            } else {
                value = next
            }
        default:
            let trimmedTranslation = translation?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmedTranslation, !trimmedTranslation.isEmpty {
                value = trimmedTranslation
            } else {
                value = next
            }
        }
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    public static func segments(line: LyricLine, currentTime: TimeInterval) -> [TimedTextSegment]? {
        guard let spans = line.timedSpans, !spans.isEmpty,
              spans.allSatisfy({ $0.startTime.isFinite && $0.endTime.isFinite && $0.endTime > $0.startTime }),
              currentTime.isFinite else { return nil }
        return TimedTextComposer.composeSegments(displayText: line.originalText,
            originalText: line.originalText, spans: spans, currentTime: currentTime)
    }
}
