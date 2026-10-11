import Foundation

@main
struct V3ResponsiveGeometryContract {
    static func main() {
        let canvas = CGRect(x: 0, y: 0, width: 1200, height: 800)
        for region in [CGRect(x: 40, y: 32, width: 460, height: 736), CGRect(x: 700, y: 32, width: 460, height: 736), CGRect(x: 32, y: 72, width: 696, height: 280)] {
            let reveal = V3ResponsiveGeometry.playbackRevealRect(region: region, canvas: canvas)
            precondition(reveal.contains(CGPoint(x: region.midX, y: region.midY)))
            precondition(reveal.contains(CGPoint(x: region.minX - 8, y: region.midY)), "the gap beside cover is part of the region")
            precondition(!reveal.contains(CGPoint(x: region.midX, y: region.maxY + 24)))
            precondition(canvas.contains(reveal))
        }
        precondition(V3ResponsiveGeometry.playbackRevealRect(region: .null, canvas: canvas).isNull)
        let left = V3ResponsiveGeometry.playbackRevealRect(region: CGRect(x: 40, y: 32, width: 460, height: 736), canvas: canvas)
        precondition(!left.contains(CGPoint(x: 900, y: 400)), "lyrics side must not reveal controls")
        for hovered in [false, true] {
            precondition(V3ResponsiveGeometry.playbackDetailsVisible(hoverOnly: false, pointerInRegion: hovered, interacting: false, panelPresented: false))
            precondition(V3ResponsiveGeometry.playbackDetailsVisible(hoverOnly: true, pointerInRegion: hovered, interacting: true, panelPresented: false))
            precondition(V3ResponsiveGeometry.playbackDetailsVisible(hoverOnly: true, pointerInRegion: hovered, interacting: false, panelPresented: true))
        }
        precondition(!V3ResponsiveGeometry.playbackDetailsVisible(hoverOnly: true, pointerInRegion: false, interacting: false, panelPresented: false))
        let landscapeHiddenScale = V3ResponsiveGeometry.ambientHiddenCoverScale(
            coverSize: 320, availableWidth: 430, availableHeight: 656,
            compact: false, portrait: false
        )
        precondition(landscapeHiddenScale > 1.055 && landscapeHiddenScale <= 1.14)
        precondition(landscapeHiddenScale * 320 <= 430.001)
        let shortWindowScale = V3ResponsiveGeometry.ambientHiddenCoverScale(
            coverSize: 220, availableWidth: 280, availableHeight: 520,
            compact: true, portrait: false
        )
        precondition(shortWindowScale > 1 && shortWindowScale <= 1.06,
                     "short windows must cap the hidden-cover expansion")
        let portraitHiddenScale = V3ResponsiveGeometry.ambientHiddenCoverScale(
            coverSize: 180, availableWidth: 220, availableHeight: 236,
            compact: false, portrait: true
        )
        precondition(portraitHiddenScale > 1 && portraitHiddenScale <= 1.14)
        precondition(portraitHiddenScale * 180 <= 220.001)
        precondition(V3ResponsiveGeometry.ambientHiddenCoverOffset(containerWidth: 480, coverSize: 320, scale: 1, alignment: "left") == 0)
        precondition(abs(V3ResponsiveGeometry.ambientHiddenCoverOffset(containerWidth: 480, coverSize: 320, scale: 1.1, alignment: "left") - 80) < 0.001)
        precondition(abs(V3ResponsiveGeometry.ambientHiddenCoverOffset(containerWidth: 480, coverSize: 320, scale: 1.1, alignment: "right") + 80) < 0.001)
        precondition(!V3ResponsiveGeometry.stagePlaybackDetailsVisible(pointerY: nil, canvasHeight: 800, previousVisible: true))
        precondition(!V3ResponsiveGeometry.stagePlaybackDetailsVisible(pointerY: 120, canvasHeight: 800, previousVisible: false))
        precondition(V3ResponsiveGeometry.stagePlaybackDetailsVisible(pointerY: 680, canvasHeight: 800, previousVisible: false))
        precondition(!V3ResponsiveGeometry.stagePlaybackDetailsVisible(pointerY: 400, canvasHeight: 800, previousVisible: false),
                     "the upper side of the split must hide playback")
        precondition(V3ResponsiveGeometry.stagePlaybackDetailsVisible(pointerY: 400, canvasHeight: 800, previousVisible: true),
                     "the midpoint hysteresis band must preserve the current state")
        for height: CGFloat in [1, 120, 280, 520, 720, 1080, 1600] {
            let stage = V3ResponsiveGeometry.lyricScrollAnchor(viewportHeight: height, stage: true)
            precondition(stage > 0.47 && stage <= 0.520001)
            precondition((stage - 0.47) * height <= 48.0001)
            precondition(V3ResponsiveGeometry.lyricScrollAnchor(viewportHeight: height, stage: false) == 0.47)
        }
        for size in [CGSize(width: 760, height: 1000), CGSize(width: 1152, height: 720), CGSize(width: 1920, height: 1080)] {
            let left = V3ResponsiveGeometry.stageReadingRect(canvasSize: size, artworkAspectRatio: 1, position: "right", lyricPosition: "left")
            let center = V3ResponsiveGeometry.stageReadingRect(canvasSize: size, artworkAspectRatio: 1, position: "left", lyricPosition: "center")
            let right = V3ResponsiveGeometry.stageReadingRect(canvasSize: size, artworkAspectRatio: 1, position: "left", lyricPosition: "right")
            precondition(left.minX >= 0 && right.maxX <= size.width)
            precondition(left.minX <= center.minX && center.minX <= right.minX)
            precondition(abs(center.midX - size.width / 2) < 0.001)
            precondition(left.size == center.size && center.size == right.size, "Placement must not change lyric wrapping or height")
            precondition(abs(left.minX - (size.width - right.maxX)) < 0.001)
        }
        precondition(
            V3ResponsiveGeometry.layoutRegime(canvasSize: CGSize(width: 760, height: 520)) == .compact,
            "technical minimum must use the compact regime"
        )
        precondition(
            V3ResponsiveGeometry.layoutRegime(canvasSize: CGSize(width: 1_040, height: 680)) == .regular,
            "reference window must use the regular regime"
        )
        precondition(
            V3ResponsiveGeometry.layoutRegime(canvasSize: CGSize(width: 1_440, height: 900)) == .wide,
            "large canvas must use the wide regime"
        )

        // A user who leaves automatic lyrics focus disabled expects one
        // continuously resizing V3 composition. The former small-window
        // poster replaced the entire split layout at 800x600 and made a
        // one-point drag look like uncontrolled zooming.
        for size in [
            CGSize(width: 760, height: 520),
            CGSize(width: 799, height: 599),
            CGSize(width: 800, height: 599),
            CGSize(width: 800, height: 600),
            CGSize(width: 1_079, height: 599),
            CGSize(width: 1_080, height: 599),
            CGSize(width: 1_760, height: 1_174)
        ] {
            precondition(
                V3ResponsiveGeometry.foregroundLayout(
                    canvasSize: size,
                    automaticLyricsFocus: false
                ) == .adaptiveSplit,
                "manual V3 must keep one continuous split composition at \(size)"
            )
        }

        precondition(
            V3ResponsiveGeometry.foregroundLayout(
                canvasSize: CGSize(width: 860, height: 620),
                automaticLyricsFocus: true
            ) == .lyricsFocus,
            "automatic lyrics focus remains an explicit compact-window behavior"
        )

        for size in [CGSize(width: 760, height: 1000), CGSize(width: 800, height: 1200), CGSize(width: 900, height: 1400)] {
            precondition(V3ResponsiveGeometry.foregroundLayout(canvasSize: size, automaticLyricsFocus: false) == .portrait,
                         "Tall windows must give lyrics their own full-width region")
            precondition(V3ResponsiveGeometry.foregroundLayout(canvasSize: size, automaticLyricsFocus: true) == .lyricsFocus,
                         "Explicit automatic focus retains priority in portrait")
            for scale: CGFloat in [0.8, 1.0, 1.4] {
                let m = V3ResponsiveGeometry.portraitMetrics(canvasSize: size, artworkScale: scale)
                precondition(m.contentWidth >= size.width * 0.85, "Portrait lyrics use the window width")
                precondition(m.lyricsHeight > size.height * 0.5, "Lyrics retain most of the portrait height")
                precondition(m.topPadding + m.headerHeight + m.gap + m.lyricsHeight + m.bottomPadding <= size.height + 0.001,
                             "Header and lyrics must fit without an outer scroll view")
                precondition(m.coverSize <= m.headerHeight - m.headerInset * 2 + 0.001)
                precondition(m.metadataWidth >= 320, "Long metadata retains a usable column beside artwork")
                precondition(m.coverColumnWidth + m.headerGap + m.metadataWidth + m.headerInset * 2 <= m.contentWidth + 0.001)
            }
        }
        precondition(V3ResponsiveGeometry.foregroundLayout(canvasSize: CGSize(width: 760, height: 800), automaticLyricsFocus: false) == .adaptiveSplit,
                     "Near-square compact windows must not unexpectedly become portrait")

        let narrowCover = V3ResponsiveGeometry.boundedCoverSize(
            availableWidth: 170,
            availableHeight: 120,
            desiredSize: 300,
            minimum: 180
        )
        precondition(narrowCover <= 120.001, "cover must not exceed the narrowest available dimension")

        let split = V3ResponsiveGeometry.splitColumns(
            containerWidth: 760,
            requestedArtworkRatio: 0.45,
            gap: 28,
            minimumArtworkWidth: 220,
            minimumLyricsWidth: 300
        )
        precondition(abs(split.artwork + split.lyrics + split.gap - 760) < 0.001, "columns must fill the container exactly")
        precondition(split.artwork >= 0 && split.lyrics >= 0 && split.gap >= 0, "columns must never be negative")
        precondition(split.lyrics >= 300 - 0.001, "lyrics must retain a readable minimum when the container allows it")

        // A one-point resize across the former 1080pt breakpoint must not
        // replace the split composition with a poster or suddenly reallocate
        // a large part of the canvas to artwork. These expectations are
        // deliberately derived from continuity and containment, not from the
        // implementation's interpolation formula.
        let beforeWideBoundary = V3ResponsiveGeometry.adaptiveSplitMetrics(
            canvasSize: CGSize(width: 1_079, height: 720),
            artworkScale: 1.4
        )
        let afterWideBoundary = V3ResponsiveGeometry.adaptiveSplitMetrics(
            canvasSize: CGSize(width: 1_081, height: 720),
            artworkScale: 1.4
        )
        precondition(
            abs(beforeWideBoundary.artworkWidth - afterWideBoundary.artworkWidth) < 4,
            "artwork column must change continuously across the former wide breakpoint"
        )
        precondition(
            abs(beforeWideBoundary.coverSize - afterWideBoundary.coverSize) < 4,
            "cover size must change continuously across the former wide breakpoint"
        )

        for size in [
            CGSize(width: 800, height: 600),
            CGSize(width: 1_080, height: 720),
            CGSize(width: 1_760, height: 732)
        ] {
            let metrics = V3ResponsiveGeometry.adaptiveSplitMetrics(
                canvasSize: size,
                artworkScale: 1.4
            )
            precondition(
                abs(metrics.artworkWidth + metrics.lyricsWidth + metrics.gap - metrics.contentWidth) < 0.001,
                "adaptive split columns must fill the available width exactly"
            )
            precondition(
                metrics.coverSize <= metrics.artworkWidth - 12 + 0.001,
                "cover must remain inside its artwork column at 140 percent"
            )
            precondition(
                metrics.coverSize + metrics.reservedTrackChromeHeight <= metrics.availableHeight + 0.001,
                "cover, metadata and transport must remain inside the visible height"
            )
        }

        for canvas in [CGSize(width: 760, height: 520), CGSize(width: 1040, height: 680), CGSize(width: 1440, height: 900), CGSize(width: 760, height: 1000)] {
            let bounds = CGRect(origin: .zero, size: canvas)
            for aspect: CGFloat in [0.2, 0.65, 1, 1.8, 5] {
                let small = V3ResponsiveGeometry.stageArtworkRect(canvasSize: canvas, artworkAspectRatio: aspect, requestedScale: 0.8)
                let large = V3ResponsiveGeometry.stageArtworkRect(canvasSize: canvas, artworkAspectRatio: aspect, requestedScale: 1.4)
                precondition(small == large, "saved zoom cannot crop the complete stage cover")
                for position in ["left", "center", "right"] {
                    let cover = V3ResponsiveGeometry.stageArtworkRect(canvasSize: canvas, artworkAspectRatio: aspect, requestedScale: 0.8, position: position)
                    precondition(abs(cover.midX - bounds.midX) < 0.001 && abs(cover.midY - bounds.midY) < 0.001, "complete cover stays centered regardless of saved position")
                    precondition(abs(cover.width - canvas.width) < 0.001 || abs(cover.height - canvas.height) < 0.001, "cover uses the largest uncropped fit")
                    let reading = V3ResponsiveGeometry.stageReadingRect(canvasSize: canvas, artworkAspectRatio: aspect, position: position)
                    precondition(bounds.insetBy(dx: -0.001, dy: -0.001).contains(cover), "entire source image must stay inside the stage")
                    precondition(abs(cover.width / cover.height - aspect) < 0.001, "background preserves source proportions")
                    precondition(bounds.contains(reading) && reading.height > canvas.height * 0.5, "lyrics overlay gets the central stage, not a lower band")
                    precondition(reading == V3ResponsiveGeometry.stageReadingRect(canvasSize: canvas, artworkAspectRatio: 1, position: "center"), "lyrics position must not depend on cover orientation")
                }
            }
        }

        for size in [CGSize(width: 640, height: 420), CGSize(width: 1152, height: 720), CGSize(width: 480, height: 900)] {
            let reading = V3ResponsiveGeometry.stageReadingRect(canvasSize: size, artworkAspectRatio: 1, position: "center")
            precondition(reading.maxY <= size.height - 108 - 20, "Stage reading must clear the visible HUD by at least 20pt")
            precondition(reading.minX >= 0 && reading.maxX <= size.width, "Narrow stage stays inside the canvas")
        }
        print("V3 responsive geometry contract: PASS")
    }
}
