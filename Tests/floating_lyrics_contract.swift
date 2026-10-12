import Foundation

@main
struct FloatingLyricsContract {
    static func main() {
        func widthKey(
            text: String? = "生", rubyTokens: [LyricRubyToken]? = nil,
            hasRuby: Bool = true, fontSize: Double = 34, outlineWidth: Double = 0
        ) -> FloatingEstimatedLineWidthCacheKey {
            FloatingEstimatedLineWidthCacheKey(
                text: text, rubyTokens: rubyTokens, hasRuby: hasRuby,
                fontSize: fontSize, outlineWidth: outlineWidth
            )
        }
        func fitKey(
            requested: Double = 34, height: Double = 160, doubleLine: Bool = false,
            hasRuby: Bool = true, outlineWidth: Double = 0, width: Double? = 180,
            text: String? = "生", rubyTokens: [LyricRubyToken]? = nil,
            companionText: String? = nil, minFontSize: Double = 14
        ) -> FloatingFittedFontSizeCacheKey {
            FloatingFittedFontSizeCacheKey(
                requested: requested, height: height, doubleLine: doubleLine,
                hasRuby: hasRuby, outlineWidth: outlineWidth, width: width,
                text: text, rubyTokens: rubyTokens, companionText: companionText,
                minFontSize: minFontSize
            )
        }

        let shortTokens = [LyricRubyToken(id: 0, surface: "生", ruby: "せい")]
        let longTokens = [LyricRubyToken(id: 0, surface: "生", ruby: String(repeating: "せい", count: 20))]
        let changedSurface = [LyricRubyToken(id: 0, surface: "生命", ruby: "せい")]
        let changedGrouping = [LyricRubyToken(id: 10_000, surface: "生", ruby: "せい")]
        let shortWidthKey = widthKey(rubyTokens: shortTokens)
        let shortFitKey = fitKey(rubyTokens: shortTokens)
        precondition(shortWidthKey == widthKey(rubyTokens: shortTokens))
        precondition(shortFitKey == fitKey(rubyTokens: shortTokens))
        for tokens in [longTokens, changedSurface, changedGrouping] {
            precondition(shortWidthKey != widthKey(rubyTokens: tokens), "width cache must compare full Ruby token contents, not token count")
            precondition(shortFitKey != fitKey(rubyTokens: tokens), "fit cache must compare full Ruby token contents, not token count")
        }
        for key in [widthKey(text: "生命"), widthKey(text: nil), widthKey(rubyTokens: []),
                    widthKey(hasRuby: false), widthKey(fontSize: 35), widthKey(outlineWidth: 1)] {
            precondition(widthKey() != key, "every width argument participates in cache identity")
        }
        for key in [fitKey(requested: 35), fitKey(height: 161), fitKey(doubleLine: true),
                    fitKey(hasRuby: false), fitKey(outlineWidth: 1), fitKey(width: 181),
                    fitKey(width: nil), fitKey(text: "生命"), fitKey(text: nil),
                    fitKey(rubyTokens: []), fitKey(companionText: "translation"),
                    fitKey(companionText: ""), fitKey(minFontSize: 15)] {
            precondition(fitKey() != key, "every fit argument participates in cache identity")
        }
        precondition(
            fitKey(doubleLine: true, text: "ABC-DE", companionText: "F")
                != fitKey(doubleLine: true, text: "ABC", companionText: "DE-F"),
            "primary and companion strings must not alias through a delimiter"
        )

        let widthProbe = NSCache<FloatingEstimatedLineWidthCacheKey, NSNumber>()
        widthProbe.setObject(NSNumber(value: 1), forKey: shortWidthKey)
        precondition(widthProbe.object(forKey: widthKey(rubyTokens: longTokens)) == nil)
        widthProbe.setObject(NSNumber(value: 2), forKey: widthKey(rubyTokens: longTokens))
        precondition(widthProbe.object(forKey: widthKey(rubyTokens: shortTokens))?.intValue == 1, "A-to-B-to-A width key reuse must restore A")
        let fitProbe = NSCache<FloatingFittedFontSizeCacheKey, NSNumber>()
        fitProbe.setObject(NSNumber(value: 34), forKey: shortFitKey)
        precondition(fitProbe.object(forKey: fitKey(rubyTokens: longTokens)) == nil)
        fitProbe.setObject(NSNumber(value: 14), forKey: fitKey(rubyTokens: longTokens))
        precondition(fitProbe.object(forKey: fitKey(rubyTokens: shortTokens))?.intValue == 34, "A-to-B-to-A fit key reuse must restore A")

        #if canImport(AppKit)
        let shortRubyWidth = FloatingDesktopTypography.estimatedLineWidth(
            text: "生", rubyTokens: shortTokens, hasRuby: true, fontSize: 34
        )
        let longRubyWidth = FloatingDesktopTypography.estimatedLineWidth(
            text: "生", rubyTokens: longTokens, hasRuby: true, fontSize: 34
        )
        precondition(longRubyWidth > shortRubyWidth, "same-count reading correction must invalidate real font width")
        precondition(FloatingDesktopTypography.estimatedLineWidth(text: "生", rubyTokens: shortTokens, hasRuby: true, fontSize: 34) == shortRubyWidth)
        let shortRubySize = FloatingDesktopTypography.fittedFontSize(
            requested: 34, height: 160, doubleLine: false, hasRuby: true,
            width: 180, text: "生", rubyTokens: shortTokens
        )
        let longRubySize = FloatingDesktopTypography.fittedFontSize(
            requested: 34, height: 160, doubleLine: false, hasRuby: true,
            width: 180, text: "生", rubyTokens: longTokens
        )
        precondition(longRubySize < shortRubySize, "same-count reading correction must invalidate font fit")
        precondition(FloatingDesktopTypography.fittedFontSize(requested: 34, height: 160, doubleLine: false, hasRuby: true, width: 180, text: "生", rubyTokens: shortTokens) == shortRubySize)
        #endif

        let lines = (0..<7).map { index in
            LyricLine(timestamp: TimeInterval(index * 10), originalText: "line \(index)")
        }

        let cacheSpans = [TimedTextSpan(
            id: 0, text: "A🙂A", startTime: 0, endTime: 1,
            utf16Start: 0, utf16Length: 4
        )]
        let cacheToken = LyricRubyToken(id: 0, surface: "A🙂A", ruby: "えー")
        let cacheKey: FloatingTimedRubyLayoutCacheKey = FloatingTimedRubyLayoutCache.key(
            originalText: "A🙂A", spans: cacheSpans, fontSize: 28,
            weight: 0.8, showsRuby: true, rubyTokens: [cacheToken], design: "default"
        )
        let equalCacheKey = FloatingTimedRubyLayoutCache.key(
            originalText: "A🙂A", spans: cacheSpans, fontSize: 28,
            weight: 0.8, showsRuby: true, rubyTokens: [cacheToken], design: "default"
        )
        precondition(cacheKey !== equalCacheKey && cacheKey == equalCacheKey, "cache keys compare all layout dependencies instead of relying on a reduced hash string")
        var layoutComputations = 0
        let firstCachedLayout = FloatingTimedRubyLayoutCache.layout(for: cacheKey) {
            layoutComputations += 1
            return TimedRubyLayout(originalText: "A🙂A", tokens: [])
        }
        let reusedLayout = FloatingTimedRubyLayoutCache.layout(for: cacheKey) {
            layoutComputations += 1
            return nil
        }
        precondition(firstCachedLayout != nil && reusedLayout == firstCachedLayout)
        precondition(layoutComputations == 1, "stable floating text dependencies reuse measured timed geometry")
        let changedTimingKey = FloatingTimedRubyLayoutCache.key(
            originalText: "A🙂A",
            spans: [TimedTextSpan(id: 0, text: "A🙂A", startTime: 0.1, endTime: 1.1, utf16Start: 0, utf16Length: 4)],
            fontSize: 28, weight: 0.8, showsRuby: true, rubyTokens: [cacheToken], design: "default"
        )
        precondition(changedTimingKey != cacheKey, "timing changes invalidate cached layout")
        let changedTokenKey = FloatingTimedRubyLayoutCache.key(
            originalText: "A🙂A", spans: cacheSpans, fontSize: 28,
            weight: 0.8, showsRuby: true,
            rubyTokens: [LyricRubyToken(id: 0, surface: "A🙂A", ruby: "ええ")], design: "default"
        )
        precondition(changedTokenKey != cacheKey, "reading changes invalidate cached layout")
        precondition(
            FloatingTimedRubyLayoutCache.key(
                originalText: "B🙂B", spans: cacheSpans, fontSize: 28,
                weight: 0.8, showsRuby: true, rubyTokens: [cacheToken], design: "default"
            ) != cacheKey,
            "display text changes invalidate cached layout"
        )
        precondition(
            FloatingTimedRubyLayoutCache.key(
                originalText: "A🙂A", spans: cacheSpans, fontSize: 29,
                weight: 0.8, showsRuby: true, rubyTokens: [cacheToken], design: "default"
            ) != cacheKey,
            "font size changes invalidate cached layout"
        )
        precondition(
            FloatingTimedRubyLayoutCache.key(
                originalText: "A🙂A", spans: cacheSpans, fontSize: 28,
                weight: 0.9, showsRuby: true, rubyTokens: [cacheToken], design: "default"
            ) != cacheKey,
            "font weight changes invalidate cached layout"
        )
        precondition(
            FloatingTimedRubyLayoutCache.key(
                originalText: "A🙂A", spans: cacheSpans, fontSize: 28,
                weight: 0.8, showsRuby: false, rubyTokens: [cacheToken], design: "default"
            ) != cacheKey,
            "Ruby visibility changes invalidate cached layout"
        )
        precondition(
            FloatingTimedRubyLayoutCache.key(
                originalText: "A🙂A", spans: cacheSpans, fontSize: 28,
                weight: 0.8, showsRuby: true, rubyTokens: [cacheToken], design: "rounded"
            ) != cacheKey,
            "layout design changes invalidate cached layout"
        )

        let synchronized = FloatingLyricsPresentationHelper.selection(
            lines: lines,
            currentIndex: 3,
            isSynchronized: true,
            isPlaying: true
        )
        precondition(synchronized.currentIndex == 3)
        precondition(Set(synchronized.visibleIndices) == Set(3...4))
        precondition(synchronized.autoScroll)

        let plain = FloatingLyricsPresentationHelper.selection(
            lines: lines,
            currentIndex: 3,
            isSynchronized: false,
            isPlaying: true
        )
        precondition(plain.currentIndex == nil)
        precondition(!plain.autoScroll)

        let beforeFirstLine = FloatingLyricsPresentationHelper.selection(
            lines: lines,
            currentIndex: nil,
            isSynchronized: true,
            isPlaying: true
        )
        precondition(beforeFirstLine.currentIndex == nil)
        precondition(beforeFirstLine.visibleIndices == Array(0...1))
        precondition(!beforeFirstLine.autoScroll)

        let paused = FloatingLyricsPresentationHelper.advance(
            currentTime: 12,
            elapsed: 0.2,
            isPlaying: false
        )
        precondition(paused == 12)

        let active = FloatingLyricsPresentationHelper.selection(
            lines: lines,
            currentIndex: LyricsTimeline.activeLineIndex(
                lines: lines,
                time: 35,
                isSynchronized: true
            ),
            isSynchronized: true,
            isPlaying: true
        )
        precondition(active.currentIndex == LyricsTimeline.activeLineIndex(
            lines: lines,
            time: 35,
            isSynchronized: true
        ))

        precondition(LyricsTimeline.activeLineIndex(lines: lines, time: -1, isSynchronized: true) == nil)
        let repeated = [
            LyricLine(timestamp: 0, originalText: "zero"),
            LyricLine(timestamp: 10, originalText: "first"),
            LyricLine(timestamp: 10, originalText: "second")
        ]
        precondition(LyricsTimeline.activeLineIndex(lines: repeated, time: 10, isSynchronized: true) == 2)
        precondition(LyricsTimeline.activeLineIndex(lines: lines, time: 35, isSynchronized: false) == nil)

        let compact = FloatingLyricsLayout(width: 360, height: 120)
        precondition(compact.toolbarHeight == 36)
        precondition(compact.contentWidth == 328)
        precondition(compact.followingCount == 0)
        precondition(FloatingLyricsLayout(width: 620, height: 320).followingCount == 1)
        precondition(FloatingLyricsLayout(width: 0, height: 0).contentWidth >= 1)
        precondition(FloatingDesktopTypography.fontSize(34) == 34)
        precondition(FloatingDesktopTypography.fontSize(900) == 64)
        precondition(FloatingDesktopTypography.fontSize(.nan) == 34)
        precondition(FloatingDesktopTypography.companion(mode: .single, translation: "译文", next: "next") == nil)
        precondition(FloatingDesktopTypography.companion(mode: .double, translation: "译文", next: "next") == "译文")
        precondition(FloatingDesktopTypography.companion(mode: .double, translation: "  ", next: "next") == "next")
        precondition(FloatingDesktopTypography.selectedCompanion(mode: .double, selection: "next", translation: "译文", next: "下一句", kana: "かな", reading: "kana") == "译文")
        precondition(FloatingDesktopTypography.selectedCompanion(mode: .double, selection: "next", translation: "", next: "下一句", kana: "かな", reading: "kana") == "下一句")
        precondition(FloatingDesktopTypography.selectedCompanion(mode: .double, selection: "kana", translation: "译文", next: "下一句", kana: "かな", reading: "kana") == "かな")
        precondition(FloatingDesktopTypography.selectedCompanion(mode: .double, selection: "translation", translation: "译文", next: "下一句", kana: "かな", reading: "kana") == "译文")
        precondition(FloatingDesktopTypography.selectedCompanion(mode: .double, selection: "translation", translation: "", next: "下一句", kana: "かな", reading: "kana") == "下一句")
        precondition(FloatingDesktopTypography.selectedCompanion(mode: .double, selection: "translation", translation: nil, next: "下一句", kana: "かな", reading: "kana") == "下一句")
        precondition(FloatingDesktopTypography.selectedCompanion(mode: .double, selection: "translation", translation: nil, next: nil, kana: "かな", reading: "kana") == nil)
        let untimed = FloatingDesktopTypography.segments(line: lines[0], currentTime: 5)
        precondition(untimed == nil, "Line timestamps must never synthesize word progress")
        var timed = LyricLine(timestamp: 0, originalText: "你好")
        timed.timedSpans = [
            TimedTextSpan(id: 0, text: "你", startTime: 1, endTime: 2, utf16Start: 0, utf16Length: 1),
            TimedTextSpan(id: 1, text: "好", startTime: 2, endTime: 3, utf16Start: 1, utf16Length: 1)
        ]
        let progress = FloatingDesktopTypography.segments(line: timed, currentTime: 1.5)!
        precondition(progress.map(\.text).joined() == "你好")
        precondition(progress.map(\.progress) == [0.5, 0])
        precondition(FloatingDesktopTypography.segments(line: timed, currentTime: .nan) == nil)
        precondition(FloatingDesktopTypography.firstVisible(["  ", "", "かな"]) == "かな")
        precondition(FloatingDesktopTypography.ribbonOffset(textWidth: 800, viewport: 300, elapsed: 0, duration: 8) == 0)
        precondition(FloatingDesktopTypography.ribbonOffset(textWidth: 800, viewport: 300, elapsed: 8, duration: 8) == 500)
        precondition(FloatingDesktopTypography.ribbonOffset(textWidth: 100, viewport: 300, elapsed: 4, duration: 8) == 0)
        precondition(FloatingDesktopTypography.ribbonPlacementOffset(measuredWidth: nil, viewport: 300, elapsed: 4, duration: 8) == 0)
        precondition(FloatingDesktopTypography.ribbonPlacementOffset(measuredWidth: 0, viewport: 300, elapsed: 4, duration: 8) == 0)
        precondition(FloatingDesktopTypography.ribbonPlacementOffset(measuredWidth: 100, viewport: 300, elapsed: 4, duration: 8) == 100)
        precondition(FloatingDesktopTypography.ribbonAlignment(measuredWidth: nil, viewport: 300) == .center)
        precondition(FloatingDesktopTypography.ribbonAlignment(measuredWidth: 0, viewport: 300) == .center)
        precondition(FloatingDesktopTypography.ribbonAlignment(measuredWidth: 100, viewport: 300) == .center)
        precondition(FloatingDesktopTypography.ribbonAlignment(measuredWidth: 400, viewport: 300) == .leading)
        let ribbonSize = FloatingDesktopTypography.fittedFontSize(requested: 34, height: 84, doubleLine: true)
        precondition(ribbonSize >= 22 && ribbonSize * 2.15 + 23 <= 84)
        let custom = FloatingDesktopColor(hex: "#12abef", fallback: "FFFFFF")
        precondition(custom.hex == "12ABEF")
        precondition(abs(custom.red - 18.0 / 255) < 0.0001)
        precondition(FloatingDesktopColor(hex: "not-a-color", fallback: "102030").hex == "102030")
        precondition(FloatingDesktopColor(hex: "12#3456", fallback: "102030").hex == "102030")
        precondition(FloatingDesktopColor(hex: "#FFFFFF00", fallback: "102030").hex == "102030", "Text colors must not accept hidden alpha")
        precondition(FloatingDesktopTypography.outlineWidth(.nan) == 1.25)
        precondition(FloatingDesktopTypography.outlineWidth(99) == 3)
        let plainTextPlan = FloatingDesktopTextRenderPlan(outlineWidth: 0, fontSize: 34)
        precondition(!plainTextPlan.outlineEnabled)
        precondition(plainTextPlan.fillPassIsOpaque)
        let outlinedTextPlan = FloatingDesktopTextRenderPlan(outlineWidth: 1.25, fontSize: 34)
        precondition(outlinedTextPlan.outlineEnabled)
        precondition(outlinedTextPlan.strokeWidthPercent > 0)
        precondition(outlinedTextPlan.fillPassIsOpaque)
        let highlightTextPlan = FloatingDesktopTextRenderPlan(outlineWidth: 1.25, fontSize: 34, drawOutline: false)
        precondition(!highlightTextPlan.outlineEnabled)
        precondition(FloatingDesktopTypography.panelOpacity(value: 0.5, transparent: true, keepsTextOpaque: true) == 1)
        precondition(FloatingDesktopTypography.panelOpacity(value: 0.5, transparent: false, keepsTextOpaque: true) == 0.5)
        precondition(FloatingDesktopTypography.panelOpacity(value: 0.5, transparent: true, keepsTextOpaque: false) == 0.5)
        let rubySize = FloatingDesktopTypography.fittedFontSize(requested: 64, height: 84, doubleLine: true, hasRuby: true, outlineWidth: 1.25)
        let rubyHeight = FloatingDesktopTypography.ribbonHeight(fontSize: rubySize, hasRuby: true, outlineWidth: 1.25)
        let auxiliaryHeight = FloatingDesktopTypography.ribbonHeight(fontSize: rubySize * 0.66, hasRuby: false, outlineWidth: 1.25)
        precondition(rubyHeight + auxiliaryHeight + 23 <= 84.01, "Minimum desktop must contain top ruby and outline as well as both lines")

        let shortTextSize = FloatingDesktopTypography.fittedFontSize(requested: 34, height: 160, doubleLine: false, width: 600, text: "短歌词")
        precondition(shortTextSize == 34, "Short text should retain requested font size")

        let longLyricText = "这是一首非常非常长并且需要单行展示的中文歌词测试文本"
        let longTextSize = FloatingDesktopTypography.fittedFontSize(requested: 34, height: 160, doubleLine: false, width: 400, text: longLyricText)
        precondition(longTextSize < 34 && longTextSize >= 14, "Long text should shrink to fit within width")
        let longWidth = FloatingDesktopTypography.estimatedLineWidth(text: longLyricText, fontSize: longTextSize)
        precondition(longWidth <= 400, "Estimated line width after shrinkage must fit within available width")

        let superLongText = String(repeating: "这是一句超级超级长的歌词用于测试达到合理最小字号兜底", count: 4)
        let minBoundSize = FloatingDesktopTypography.fittedFontSize(requested: 34, height: 160, doubleLine: false, width: 400, text: superLongText, minFontSize: 14)
        precondition(minBoundSize == 14, "Extremely long text must stop at minimum font size for horizontal scrolling fallback")

        let lyricsFrame = CGRect(x: 482, y: 1163, width: 620, height: 220)
        let visibleFrame = CGRect(x: 0, y: 23, width: 1920, height: 1394)
        let sidePanel = FloatingLyricsStylePanelLayout(
            lyricsFrame: lyricsFrame,
            panelSize: CGSize(width: 360, height: 660),
            visibleFrame: visibleFrame
        )
        precondition(sidePanel.placement == .right)
        precondition(sidePanel.frame.minX >= lyricsFrame.maxX + 12)
        precondition(!sidePanel.frame.intersects(lyricsFrame))

        let leftPlacement = FloatingLyricsStylePanelLayout(
            lyricsFrame: CGRect(x: 1260, y: 600, width: 620, height: 220),
            panelSize: CGSize(width: 300, height: 500),
            visibleFrame: visibleFrame
        )
        precondition(leftPlacement.placement == .left)
        precondition(!leftPlacement.frame.intersects(CGRect(x: 1260, y: 600, width: 620, height: 220)))
        print("floating lyrics pure-data contract passed")
    }
}
