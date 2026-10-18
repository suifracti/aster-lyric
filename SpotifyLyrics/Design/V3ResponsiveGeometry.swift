import CoreGraphics
import Foundation

/// Geometry shared by the V3 foreground and backdrop. The view layer is
/// intentionally responsible only for rendering these already-safe values;
/// this keeps window resizing from turning a readable layout into an overflow.
enum V3ResponsiveGeometry {
    enum LayoutRegime: String, Equatable, Sendable {
        case compact
        case regular
        case wide
    }

    /// Small, explicit composition regimes shared by the maintained V3
    /// surfaces. These thresholds describe available space, not a second
    /// layout preference or a scale factor.
    static func layoutRegime(canvasSize: CGSize) -> LayoutRegime {
        let width = finitePositive(canvasSize.width)
        let height = finitePositive(canvasSize.height)
        let aspectRatio = width / height

        if width < 900 || height < 600 || aspectRatio < 1.25 {
            return .compact
        }

        if width >= 1_280 || (width >= 1_080 && aspectRatio >= 1.70) {
            return .wide
        }

        return .regular
    }

    enum ForegroundLayout: Equatable {
        case adaptiveSplit
        case portrait
        case lyricsFocus
    }

    /// Preserve the continuous split in landscape and near-square windows.
    /// Tall windows gain a player header and a full-width reading viewport;
    /// the explicit compact focus preference always takes priority.
    static func foregroundLayout(
        canvasSize: CGSize,
        automaticLyricsFocus: Bool,
        compactFocusWidth: CGFloat = 900,
        compactFocusHeight: CGFloat = 640
    ) -> ForegroundLayout {
        let width = finitePositive(canvasSize.width)
        let height = finitePositive(canvasSize.height)
        if automaticLyricsFocus,
           width <= compactFocusWidth || height <= compactFocusHeight {
            return .lyricsFocus
        }
        if height >= 800, height >= width * 1.10 { return .portrait }
        return .adaptiveSplit
    }

    struct PortraitMetrics: Equatable {
        let horizontalPadding: CGFloat
        let topPadding: CGFloat
        let bottomPadding: CGFloat
        let contentWidth: CGFloat
        let headerHeight: CGFloat
        let headerInset: CGFloat
        let headerGap: CGFloat
        let coverColumnWidth: CGFloat
        let coverSize: CGFloat
        let metadataWidth: CGFloat
        let gap: CGFloat
        let lyricsHeight: CGFloat
    }

    static func portraitMetrics(canvasSize: CGSize, artworkScale: CGFloat) -> PortraitMetrics {
        let width = finitePositive(canvasSize.width)
        let height = finitePositive(canvasSize.height)
        let horizontalPadding = min(40, max(32, width * 0.04))
        let contentWidth = max(1, width - horizontalPadding * 2)
        let topPadding: CGFloat = 72
        let bottomPadding: CGFloat = 28
        let gap: CGFloat = 24
        let headerInset: CGFloat = 16
        let headerGap: CGFloat = 24
        let headerHeight = min(312, max(248, contentWidth * 0.34 + headerInset * 2))
        let coverColumnWidth = min(headerHeight - headerInset * 2, contentWidth * 0.36)
        let normalizedScale = min(1, max(0, (finiteValue(artworkScale) - 0.8) / 0.6))
        let coverSize = coverColumnWidth * (0.70 + normalizedScale * 0.30)
        return PortraitMetrics(
            horizontalPadding: horizontalPadding, topPadding: topPadding, bottomPadding: bottomPadding,
            contentWidth: contentWidth, headerHeight: headerHeight, headerInset: headerInset,
            headerGap: headerGap, coverColumnWidth: coverColumnWidth, coverSize: coverSize,
            metadataWidth: max(1, contentWidth - headerInset * 2 - headerGap - coverColumnWidth),
            gap: gap, lyricsHeight: max(1, height - topPadding - bottomPadding - gap - headerHeight)
        )
    }

    struct ColumnSplit: Equatable {
        let artwork: CGFloat
        let lyrics: CGFloat
        let gap: CGFloat
    }

    struct AdaptiveSplitMetrics: Equatable {
        let horizontalPadding: CGFloat
        let verticalPadding: CGFloat
        let contentWidth: CGFloat
        let availableHeight: CGFloat
        let artworkWidth: CGFloat
        let lyricsWidth: CGFloat
        let gap: CGFloat
        let coverSize: CGFloat
        let reservedTrackChromeHeight: CGFloat
    }

    /// One continuous geometry model for every horizontal V3 layout. The old
    /// wide/medium implementations used unrelated ratios and let artwork scale
    /// resize the entire column, so crossing 1080pt could move the cover by
    /// hundreds of points. Here only the cover occupancy responds to the user
    /// scale; column allocation and padding interpolate with the canvas.
    static func adaptiveSplitMetrics(
        canvasSize: CGSize,
        artworkScale: CGFloat
    ) -> AdaptiveSplitMetrics {
        let width = finitePositive(canvasSize.width)
        let height = finitePositive(canvasSize.height)
        let interpolation = min(1, max(0, (width - 800) / 560))
        let horizontalPadding = interpolate(from: 32, to: 64, progress: interpolation)
        let verticalPadding = interpolate(from: 28, to: 34, progress: interpolation)
        let gap = interpolate(from: 24, to: 28, progress: interpolation)
        let contentWidth = max(1, width - horizontalPadding * 2)
        let availableHeight = max(1, height - verticalPadding * 2)
        let artworkRatio = interpolate(from: 0.40, to: 0.43, progress: interpolation)
        let split = splitColumns(
            containerWidth: contentWidth,
            requestedArtworkRatio: artworkRatio,
            gap: gap,
            minimumArtworkWidth: min(220, contentWidth * 0.30),
            minimumLyricsWidth: min(280, contentWidth * 0.36)
        )

        // Metadata, progress, time labels, playback buttons and their spacing
        // keep a fixed vertical budget. This is what prevents a 140% cover
        // from pushing transport controls below a short wide window.
        let chromeBudget = interpolate(from: 248, to: 280, progress: interpolation)
        let reservedTrackChromeHeight = min(chromeBudget, max(0, availableHeight - 1))
        let maximumCover = min(
            max(1, split.artwork - 12),
            max(1, availableHeight - reservedTrackChromeHeight),
            620
        )
        let normalizedScale = min(1, max(0, (finiteValue(artworkScale) - 0.8) / 0.6))
        let coverOccupancy = interpolate(from: 0.70, to: 1.0, progress: normalizedScale)
        let coverSize = max(1, maximumCover * coverOccupancy)

        return AdaptiveSplitMetrics(
            horizontalPadding: horizontalPadding,
            verticalPadding: verticalPadding,
            contentWidth: contentWidth,
            availableHeight: availableHeight,
            artworkWidth: split.artwork,
            lyricsWidth: split.lyrics,
            gap: split.gap,
            coverSize: coverSize,
            reservedTrackChromeHeight: reservedTrackChromeHeight
        )
    }

    static func boundedCoverSize(
        availableWidth: CGFloat,
        availableHeight: CGFloat,
        desiredSize: CGFloat,
        minimum: CGFloat = 1,
        maximum: CGFloat = .greatestFiniteMagnitude
    ) -> CGFloat {
        let width = finitePositive(availableWidth)
        let height = finitePositive(availableHeight)
        let desired = finitePositive(desiredSize)
        let lowerBound = finitePositive(minimum)
        let upperBound = min(width, height, finitePositive(maximum))

        return min(upperBound, max(lowerBound, desired))
    }

    static func splitColumns(
        containerWidth: CGFloat,
        requestedArtworkRatio: CGFloat,
        gap: CGFloat,
        minimumArtworkWidth: CGFloat,
        minimumLyricsWidth: CGFloat
    ) -> ColumnSplit {
        let width = finiteNonNegative(containerWidth)
        let resolvedGap = min(width, finiteNonNegative(gap))
        let remaining = max(0, width - resolvedGap)
        let artworkMinimum = min(remaining, finiteNonNegative(minimumArtworkWidth))
        let lyricsMinimum = min(remaining, finiteNonNegative(minimumLyricsWidth))
        let ratio = min(1, max(0, finiteNonNegative(requestedArtworkRatio)))

        guard remaining > 0 else {
            return ColumnSplit(artwork: 0, lyrics: 0, gap: resolvedGap)
        }

        // Honour both minimums whenever the container can hold them. If it
        // cannot, preserve the requested ratio without producing negatives.
        let artwork: CGFloat
        if artworkMinimum + lyricsMinimum <= remaining {
            let preferred = remaining * ratio
            artwork = min(remaining - lyricsMinimum, max(artworkMinimum, preferred))
        } else {
            artwork = min(remaining, max(0, remaining * ratio))
        }

        return ColumnSplit(
            artwork: artwork,
            lyrics: max(0, remaining - artwork),
            gap: resolvedGap
        )
    }

    /// Lyrics occupy an overlay viewport; cover orientation never divides the stage.
    static func stageReadingRect(canvasSize: CGSize, artworkAspectRatio: CGFloat, position: String, lyricPosition: String = "automatic", readingScale: CGFloat = 1) -> CGRect {
        let width = finitePositive(canvasSize.width)
        let height = finitePositive(canvasSize.height)
        let readingWidth = min(860 * min(1.5, max(1, readingScale)), max(1, width - 80))
        let margin = min(40, max(0, (width - readingWidth) / 2))
        let x = lyricPosition == "left" ? margin
            : lyricPosition == "right" ? width - readingWidth - margin : (width - readingWidth) / 2
        // Reserve the actual 96pt HUD (centered 60pt above the bottom)
        // plus 24pt of reading air, even while the HUD is faded out.
        let top = min(76, height * 0.15)
        let bottom = max(top + 1, height - 108 - 24)
        return CGRect(x: x, y: top,
                      width: readingWidth, height: max(1, bottom - top))
    }

    /// Return the pointer hit region that reveals the playback details.
    ///
    /// The caller supplies the measured cover/player composition rather than
    /// an assumed half of the window. A small, bounded expansion keeps the
    /// cover-to-card gap comfortable without allowing the lyric viewport to
    /// become a trigger zone.
    static func playbackRevealRect(region: CGRect, canvas: CGRect) -> CGRect {
        guard !region.isNull, !region.isEmpty, !canvas.isNull, !canvas.isEmpty else {
            return .null
        }
        let expanded = region.insetBy(dx: -12, dy: -12)
        return expanded.intersection(canvas)
    }

    /// Shared visibility policy for the playback details in every V3 layout.
    /// Toolbar visibility deliberately remains a separate state machine.
    static func playbackDetailsVisible(
        hoverOnly: Bool,
        pointerInRegion: Bool,
        interacting: Bool,
        panelPresented: Bool
    ) -> Bool {
        !hoverOnly || pointerInRegion || interacting || panelPresented
    }

    /// Scale the foreground cover only while playback details are hidden.
    /// The layout frame remains unchanged, so the lyrics column and the hover
    /// anchor never move with the visual animation. All layouts share the
    /// same expansion, bounded by their actual available space.
    static func ambientHiddenCoverScale(
        coverSize: CGFloat,
        availableWidth: CGFloat,
        availableHeight: CGFloat,
        compact: Bool,
        portrait: Bool
    ) -> CGFloat {
        let size = finitePositive(coverSize)
        let width = finitePositive(availableWidth)
        let height = finitePositive(availableHeight)
        let widthLimit = max(1, width / size)
        let heightLimit = max(1, height / size)
        return min(1.24, widthLimit, heightLimit)
    }

    /// Visual-only centering for the enlarged cover. The measured frame and
    /// hover anchor remain unchanged; this merely places the scaled aspect-fit
    /// image in the same media column without moving the lyric column.
    static func ambientHiddenCoverOffset(
        containerWidth: CGFloat,
        coverSize: CGFloat,
        scale: CGFloat,
        alignment: String
    ) -> CGFloat {
        let width = finitePositive(containerWidth)
        let size = finitePositive(coverSize)
        let slack = max(0, width - size)
        switch alignment {
        case "right": return -slack / 2
        case "center": return 0
        default: return slack / 2
        }
    }

    /// Reclaim the hidden metadata's space to center the cover. The intrinsic
    /// composition stays measured in place, preserving the hover target and
    /// lyric layout while the complete cover moves toward the column center.
    static func hiddenCoverVerticalOffset(
        containerHeight: CGFloat,
        compositionHeight: CGFloat,
        coverSize: CGFloat,
        scale: CGFloat,
        compact: Bool,
        topChromeInset: CGFloat = 0
    ) -> CGFloat {
        guard compositionHeight.isFinite, compositionHeight > 0 else { return 0 }
        let height = finitePositive(containerHeight)
        let size = finitePositive(coverSize)
        let scaledHalfSize = size * max(1, finiteValue(scale)) / 2
        let originalCenter = (height - compositionHeight + size) / 2
        guard scaledHalfSize <= height / 2, originalCenter >= 0 else { return 0 }
        // Split layouts reserve 44pt at the top for the toolbar. Their media
        // column is therefore centered 22pt below the full canvas midpoint.
        let desiredCenter = height / 2 - finiteNonNegative(topChromeInset) / 2
        let boundedCenter = min(height - scaledHalfSize, max(scaledHalfSize, desiredCenter))
        return boundedCenter - originalCenter
    }

    /// Stage playback controls use the full player canvas as their hit area.
    /// A small midpoint hysteresis band prevents a pointer resting on the
    /// split from rapidly toggling the details during native event jitter.
    static func stagePlaybackDetailsVisible(
        pointerY: CGFloat?,
        canvasHeight: CGFloat,
        previousVisible: Bool,
        hysteresis: CGFloat = 16
    ) -> Bool {
        guard let pointerY, pointerY.isFinite else { return false }
        let midpoint = finitePositive(canvasHeight) * 0.5
        let band = min(24, max(8, finitePositive(hysteresis)))
        if pointerY < midpoint - band { return false }
        if pointerY > midpoint + band { return true }
        return previousVisible
    }

    /// Stage puts the active lyric slightly below the old midpoint, but the
    /// shift is bounded in points so short windows cannot push the lyric into
    /// the bottom HUD. Other layouts retain the established anchor.
    static func lyricScrollAnchor(viewportHeight: CGFloat, stage: Bool) -> CGFloat {
        guard stage else { return 0.47 }
        let height = finitePositive(viewportHeight)
        return 0.47 + min(0.05, 48 / height)
    }

    /// Largest centered aspect-fit image. Legacy zoom/position never crop the stage.
    static func stageArtworkRect(
        canvasSize: CGSize,
        artworkAspectRatio: CGFloat,
        requestedScale: CGFloat = 1.0,
        position: String = "left"
    ) -> CGRect {
        let width = finitePositive(canvasSize.width)
        let height = finitePositive(canvasSize.height)
        let aspect = artworkAspectRatio.isFinite && artworkAspectRatio > 0 ? artworkAspectRatio : 1
        let imageHeight = min(height, width / aspect)
        let imageWidth = imageHeight * aspect
        return CGRect(x: (width - imageWidth) / 2, y: (height - imageHeight) / 2,
                      width: imageWidth, height: imageHeight)
    }

    private static func finitePositive(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 1 }
        return max(1, value)
    }

    private static func finiteValue(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 0 }
        return value
    }

    private static func finiteNonNegative(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 0 }
        return max(0, value)
    }

    private static func interpolate(from start: CGFloat, to end: CGFloat, progress: CGFloat) -> CGFloat {
        start + (end - start) * min(1, max(0, progress))
    }
}
