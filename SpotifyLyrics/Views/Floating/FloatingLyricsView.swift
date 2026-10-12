import SwiftUI

/// The production floating renderer. It observes the existing PlaybackState
/// and WindowController only; it owns no provider, session, translation state
/// or playback timer. All lyric rows come from the shared live session.
struct FloatingLyricsView: View {
    @ObservedObject var state: PlaybackState
    @ObservedObject var windowController: FloatingLyricsWindowController
    @EnvironmentObject private var settings: AppSettingsStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    private var presentationVersion: FloatingLyricsPresentationVersion {
        settings.floatingLyricsPresentation
    }

    private var presentationStyle: FloatingLyricsSurfaceStyle {
        settings.floatingLyricsSurfaceStyle
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topTrailing) {
                surfaceBackground
                    .opacity(presentationVersion == .transparentV2 && settings.floatingDesktopKeepsTextOpaque
                             ? min(1, max(0.45, settings.floatingWindowOpacity)) : 1)

                VStack(spacing: 0) {
                    toolbar
                        .frame(height: FloatingLyricsLayout(width: geometry.size.width, height: geometry.size.height).toolbarHeight)
                    content(in: geometry)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .preferredColorScheme(.dark)
        .environment(\.lyricAgentPresentationMap, LyricAgentPresentationMap(lines: state.liveLyrics))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("悬浮歌词")
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button { state.previousTrack() } label: { Image(systemName: "backward.fill").frame(width: 24, height: 26) }
                .help("上一首")
                .accessibilityLabel("上一首")
            Button { state.togglePlayPause() } label: { Image(systemName: state.isPlaying ? "pause.fill" : "play.fill").frame(width: 24, height: 26) }
                .help(state.isPlaying ? "暂停" : "播放")
                .accessibilityLabel(state.isPlaying ? "暂停" : "播放")
            Button { state.nextTrack() } label: { Image(systemName: "forward.fill").frame(width: 24, height: 26) }
                .help("下一首")
                .accessibilityLabel("下一首")
            Text(windowController.interactionMode == .locked ? "已锁定" : "拖动移动")
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 4)
            Button { windowController.toggleStylePanel(settings: settings) } label: { Image(systemName: "textformat.size").frame(width: 26, height: 26) }
                .help("桌面歌词样式")
                .accessibilityLabel("桌面歌词样式")
                .accessibilityValue(windowController.isStylePanelVisible ? "已打开" : "已关闭")

            Button {
                windowController.toggleInteractionMode()
            } label: {
                Image(systemName: windowController.interactionMode == .locked ? "lock.open" : "lock")
                    .frame(width: 26, height: 26)
            }
            .help(windowController.interactionMode == .locked ? "解锁悬浮歌词" : "锁定悬浮歌词")
            .accessibilityLabel(windowController.interactionMode == .locked ? "解锁悬浮歌词" : "锁定悬浮歌词")
            Button {
                windowController.setInteractionMode(.passThrough)
            } label: {
                Image(systemName: "cursorarrow.slash").frame(width: 26, height: 26)
            }
            .help("启用鼠标穿透；即使主窗口不接收鼠标，也可用 ⌥⌘L 从应用菜单恢复交互")
            .accessibilityLabel("启用鼠标穿透")
            Button { windowController.close() } label: {
                Image(systemName: "xmark").frame(width: 26, height: 26)
            }
            .help("隐藏悬浮歌词")
            .accessibilityLabel("隐藏悬浮歌词")
        }
        .font(.system(size: 11, weight: .semibold))
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.9))
        .padding(.horizontal, 10)
        .background(Color.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 6)
        .opacity((isHovering || windowController.isStylePanelVisible) && windowController.interactionMode != .passThrough ? 1 : 0)
        .allowsHitTesting((isHovering || windowController.isStylePanelVisible) && windowController.interactionMode != .passThrough)
        .accessibilityHidden(windowController.interactionMode == .passThrough)
    }

    @ViewBuilder
    private var surfaceBackground: some View {
        switch presentationVersion {
        case .legacyPanel:
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.14), lineWidth: 1)
                }
        case .transparentV2:
            switch presentationStyle {
            case .ultraTransparent:
                Color.clear
            case .lightMaterial:
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.regularMaterial.opacity(0.66))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    }
            }
        }
    }

    @ViewBuilder
    private func content(in geometry: GeometryProxy) -> some View {
        let documentState = state.liveLyricsState
        let rows = state.liveLyrics
        let layout = FloatingLyricsLayout(width: geometry.size.width, height: geometry.size.height)
        let width = layout.contentWidth

        switch documentState {
        case .loaded, .alignmentPreview:
            if state.liveLyricsAreSynchronized, !rows.isEmpty {
                if presentationVersion == .transparentV2 {
                    desktopVerse(rows, width: width, height: geometry.size.height - layout.toolbarHeight)
                } else {
                    synchronizedRows(rows, width: width, followingCount: layout.followingCount)
                }
            } else if !rows.isEmpty {
                plainRows(rows, width: width, status: "纯文本 / 未排轴")
            } else {
                statusView(documentState)
            }
        case .alignmentQueued, .alignmentRunning:
            if !rows.isEmpty {
                plainRows(rows, width: width, status: "纯文本 / 未排轴")
            } else {
                statusView(documentState)
            }
        case .mockPreview, .loading, .idle, .noLyrics, .noSelection, .noMatch, .candidates, .failed:
            if !rows.isEmpty, documentState.isShowingRows {
                plainRows(rows, width: width, status: "纯文本")
            } else {
                statusView(documentState)
            }
        }
    }

    private func desktopVerse(_ rows: [LyricLine], width: CGFloat, height: CGFloat, synchronized: Bool = true) -> some View {
        let activeIndex = synchronized ? state.liveCurrentLineIndex : nil
        let index = activeIndex.flatMap { rows.indices.contains($0) ? $0 : nil } ?? 0
        let line = rows[index]
        let preferences = state.preferences
        let palette = FloatingDesktopPalette(settings: settings)
        let japanese = LyricsLanguageGate.allowsJapaneseReadings(language: state.liveLyricsLanguage, text: line.originalText)
        let presentation = V3JapaneseReadingCache.presentation(
            for: line, language: state.liveLyricsLanguage,
            userEntries: settings.readingUserDictionary.load(),
            trackStableKey: state.currentTrackIdentity?.stableKey,
            artistDisplay: state.currentTrack.artist
        )
        let kana = japanese && preferences.showKana ? presentation.kanaText : nil
        let isPinyin: Bool = {
            if line.readingRepresentationID?.hasPrefix("readingRepresentation.pinyin") == true {
                return true
            }
            if let lang = state.liveLyricsLanguage?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines), !lang.isEmpty {
                if lang.hasPrefix("ja") { return false }
                if lang.hasPrefix("zh") { return true }
            }
            return LyricsLanguageGate.containsHan(line.originalText) && !LyricsLanguageGate.containsKana(line.originalText)
        }()
        let reading = (isPinyin ? preferences.showPinyin : japanese && preferences.showRomaji)
            ? (presentation.romajiText ?? line.romajiText) : nil
        let conversion = settings.readingPreferences.scriptConversion
        let original: String = {
            let base = presentation.originalText
            guard conversion != .none else { return base }
            return ReadingScriptConverter.convert(base, using: conversion)
        }()
        let rubyTokens: [LyricRubyToken]? = {
            guard let tokens = presentation.rubyTokens else { return nil }
            guard conversion != .none else { return tokens }
            return ReadingScriptConverter.convertRubyTokens(
                tokens,
                originalText: presentation.originalText,
                convertedText: original,
                using: conversion
            ) ?? tokens
        }()
        let effectivePresentation: JapaneseRubyPresentation = {
            guard conversion != .none else { return presentation }
            return JapaneseRubyPresentation(
                originalText: original,
                reading: nil,
                preferredRubyTokens: rubyTokens,
                kanaText: presentation.kanaText,
                romajiText: presentation.romajiText
            )
        }()
        let primary = FloatingDesktopTypography.firstVisible([
            preferences.showOriginal ? original : nil,
            preferences.showTranslation ? line.translationText : nil, kana, reading
        ]) ?? ""
        let primaryIsOriginal = preferences.showOriginal && primary == original
        let showRuby = (japanese && preferences.showKana) || (isPinyin && preferences.showPinyin)
        let hasRuby = primaryIsOriginal && showRuby && presentation.hasRuby
        let next = preferences.showOriginal && rows.indices.contains(index + 1) ? rows[index + 1].originalText : nil
        let chosen: String? = {
            switch settings.floatingDesktopCompanion {
            case "next": return next
            case "kana": return hasRuby ? nil : kana
            case "reading": return reading
            default: return preferences.showTranslation ? line.translationText : nil
            }
        }()
        let lineMode = FloatingDesktopLineMode(rawValue: settings.floatingDesktopLineMode) ?? .double
        let companion = FloatingDesktopTypography.selectedCompanion(
            mode: lineMode,
            selection: settings.floatingDesktopCompanion,
            translation: chosen == primary ? nil : chosen,
            next: next,
            kana: kana,
            reading: reading
        )
        let effectiveCompanion = (companion != nil && companion != primary) ? companion : nil
        let fontSize = FloatingDesktopTypography.fittedFontSize(
            requested: settings.floatingDesktopFontSize,
            height: height,
            doubleLine: effectiveCompanion != nil,
            hasRuby: hasRuby,
            outlineWidth: palette.outlineWidth,
            width: Double(width),
            text: primary,
            rubyTokens: hasRuby ? rubyTokens : nil,
            companionText: effectiveCompanion
        )
        let minFontSize = 14.0
        let primaryWidth = FloatingDesktopTypography.estimatedLineWidth(
            text: primary,
            rubyTokens: hasRuby ? rubyTokens : nil,
            hasRuby: hasRuby,
            fontSize: fontSize,
            outlineWidth: palette.outlineWidth
        )
        let allowsPrimaryMotion = fontSize <= minFontSize + 0.01 && primaryWidth > Double(width)

        let companionWidth: Double = {
            guard let effectiveCompanion else { return 0 }
            return FloatingDesktopTypography.estimatedLineWidth(
                text: effectiveCompanion,
                rubyTokens: nil,
                hasRuby: false,
                fontSize: fontSize * 0.66,
                outlineWidth: palette.outlineWidth
            )
        }()
        let allowsCompanionMotion = effectiveCompanion != nil && fontSize <= minFontSize + 0.01 && companionWidth > Double(width)

        let end = line.endTime ?? (rows.indices.contains(index + 1) ? rows[index + 1].timestamp : state.currentTrack.duration)
        let duration = max(1, end - line.timestamp)
        let effectiveSpans = ReadingScriptConverter.convertSpans(
            line.timedSpans ?? [],
            originalText: line.originalText,
            convertedText: original,
            using: conversion
        ) ?? (line.timedSpans ?? [])
        let timedLayout: TimedRubyLayout?
        if primaryIsOriginal && activeIndex != nil {
            let weight = NSFont.Weight.bold.rawValue
            let key = FloatingTimedRubyLayoutCache.key(
                originalText: original,
                spans: effectiveSpans,
                fontSize: fontSize,
                weight: weight,
                showsRuby: hasRuby,
                rubyTokens: rubyTokens,
                design: "default"
            )
            timedLayout = FloatingTimedRubyLayoutCache.layout(for: key) {
                effectivePresentation.timedLayout(
                    spans: effectiveSpans,
                    fontSize: fontSize,
                    weight: weight,
                    showsRuby: hasRuby,
                    design: "default"
                )
            }
        } else {
            timedLayout = nil
        }
        let baseColor = timedLayout != nil || activeIndex == nil ? palette.original : palette.highlight
        let originalView: (TimeInterval?) -> RubyLineView = { time in
            RubyLineView(originalText: original, kanaText: hasRuby ? (presentation.kanaText ?? "") : "",
                         tokens: hasRuby ? rubyTokens : nil,
                         timedLayout: timedLayout, currentTime: time,
                         baseFont: .system(size: fontSize, weight: .bold),
                         rubyFont: .system(size: fontSize * 0.45, weight: .medium),
                         baseColor: baseColor, rubyColor: palette.ruby,
                         rubySpacing: 2, tokenVerticalSpacing: 0, maxWidth: nil,
                         highlightColor: palette.highlight, outlineColor: palette.outline,
                         outlineWidth: palette.outlineWidth,
                         baseNSFont: .systemFont(ofSize: fontSize, weight: .bold),
                         rubyNSFont: .systemFont(ofSize: fontSize * 0.45, weight: .medium),
                         unplayedOpacity: 1, showsRuby: hasRuby)
        }
        let hasTimelineMotion = (allowsPrimaryMotion || allowsCompanionMotion || timedLayout != nil) && !reduceMotion && state.isPlaying
        let primaryColor = primary == line.translationText ? palette.translation : palette.ruby
        let companionColor = companion == next ? palette.original
            : (settings.floatingDesktopCompanion == "kana" || settings.floatingDesktopCompanion == "reading" ? palette.ruby : palette.translation)

        return Group {
            if hasTimelineMotion {
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !state.isPlaying || reduceMotion)) { _ in
                    let presentedTime = state.presentationClock.presentationTime(at: ProcessInfo.processInfo.systemUptime)
                    let elapsed = reduceMotion || activeIndex == nil ? 0 : max(0, presentedTime - line.timestamp)
                    VStack(spacing: 7) {
                        FloatingDesktopRibbon(label: primary, width: width,
                            height: FloatingDesktopTypography.ribbonHeight(fontSize: fontSize, hasRuby: hasRuby, outlineWidth: palette.outlineWidth),
                            elapsed: elapsed, duration: duration, allowsMotion: allowsPrimaryMotion) {
                            if primaryIsOriginal {
                                originalView(timedLayout != nil ? presentedTime : nil)
                            } else {
                                OutlinedLyricText(text: primary, font: .systemFont(ofSize: fontSize, weight: .bold),
                                                  fill: primaryColor, outline: palette.outline, width: palette.outlineWidth)
                            }
                        }
                        if let companion, companion != primary {
                            FloatingDesktopRibbon(label: companion, width: width,
                                height: FloatingDesktopTypography.ribbonHeight(fontSize: fontSize * 0.66, hasRuby: false, outlineWidth: palette.outlineWidth),
                                elapsed: elapsed, duration: duration, allowsMotion: allowsCompanionMotion) {
                                OutlinedLyricText(text: companion, font: .systemFont(ofSize: fontSize * 0.66, weight: .bold),
                                                  fill: companionColor, outline: palette.outline, width: palette.outlineWidth)
                            }
                        }
                    }
                    .frame(width: width, alignment: .center)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .frame(maxHeight: .infinity, alignment: .center)
                    .transaction { transaction in
                        transaction.animation = nil
                    }
                }
            } else {
                VStack(spacing: 7) {
                    FloatingDesktopRibbon(label: primary, width: width,
                        height: FloatingDesktopTypography.ribbonHeight(fontSize: fontSize, hasRuby: hasRuby, outlineWidth: palette.outlineWidth),
                        elapsed: 0, duration: duration, allowsMotion: false) {
                        if primaryIsOriginal {
                            originalView(nil)
                        } else {
                            OutlinedLyricText(text: primary, font: .systemFont(ofSize: fontSize, weight: .bold),
                                              fill: primaryColor, outline: palette.outline, width: palette.outlineWidth)
                        }
                    }
                    if let companion, companion != primary {
                        FloatingDesktopRibbon(label: companion, width: width,
                            height: FloatingDesktopTypography.ribbonHeight(fontSize: fontSize * 0.66, hasRuby: false, outlineWidth: palette.outlineWidth),
                            elapsed: 0, duration: duration, allowsMotion: false) {
                            OutlinedLyricText(text: companion, font: .systemFont(ofSize: fontSize * 0.66, weight: .bold),
                                              fill: companionColor, outline: palette.outline, width: palette.outlineWidth)
                        }
                    }
                }
                .frame(width: width, alignment: .center)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .frame(maxHeight: .infinity, alignment: .center)
                .transaction { transaction in
                    transaction.animation = nil
                }
            }
        }
        .id("desktop-\(state.liveLyricsSessionRevision)-\(index)-\(settings.floatingDesktopLineMode)-\(settings.floatingDesktopCompanion)-\(preferences.showPinyin)-\(preferences.showKana)-\(conversion.rawValue)")
    }

    @ViewBuilder
    private func synchronizedRows(_ rows: [LyricLine], width: CGFloat, followingCount: Int) -> some View {
        let selection = FloatingLyricsPresentationHelper.selection(
            lines: rows,
            currentIndex: state.liveCurrentLineIndex,
            isSynchronized: state.liveLyricsAreSynchronized,
            isPlaying: state.isPlaying,
            followingCount: followingCount
        )
        let visibleLayerCount = visibleLayerCount

        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(selection.visibleIndices, id: \.self) { index in
                        let distance = selection.currentIndex.map { abs(index - $0) } ?? 0
                        LyricLineView(
                            line: rows[index],
                            isActive: index == selection.currentIndex,
                            distance: distance,
                            isSynchronized: true,
                            preferences: desktopPreferences,
                            availableWidth: width,
                            visibleLayerCount: visibleLayerCount,
                            language: state.liveLyricsLanguage
                        )
                        .shadow(color: .black.opacity(0.95), radius: 2, y: 1)
                        .shadow(color: .black.opacity(0.65), radius: 5, y: 1)
                        .id(rows[index].id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }
            .scrollIndicators(.automatic)
            // A new live session replaces this scroll surface directly; old
            // rows must never animate into a newly selected track.
            .id("lyrics-document-\(state.liveLyricsSessionRevision)")
            .onChange(of: selection.currentIndex) { _, index in
                guard let index, selection.autoScroll else { return }
                LyricsTransitionPolicy.perform(reduceMotion: reduceMotion) {
                    proxy.scrollTo(rows[index].id, anchor: .top)
                }
            }
            .onChange(of: state.preferences) { _, _ in
                guard let index = selection.currentIndex else { return }
                LyricsTransitionPolicy.perform(reduceMotion: reduceMotion) {
                    proxy.scrollTo(rows[index].id, anchor: .top)
                }
            }
            .task {
                guard let index = selection.currentIndex else { return }
                proxy.scrollTo(rows[index].id, anchor: .top)
            }
        }
    }

    @ViewBuilder
    private func plainRows(_ rows: [LyricLine], width: CGFloat, status: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(status)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 10)

            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 7) {
                    ForEach(rows) { line in
                        if presentationVersion == .transparentV2 {
                            desktopVerse([line], width: width,
                                         height: 160, synchronized: false)
                                .frame(height: 160)
                                .id(line.id)
                        } else {
                        LyricLineView(
                            line: line,
                            isActive: false,
                            distance: 0,
                            isSynchronized: false,
                            preferences: desktopPreferences,
                            availableWidth: width,
                            visibleLayerCount: visibleLayerCount,
                            language: state.liveLyricsLanguage
                        )
                        .shadow(color: .black.opacity(0.95), radius: 2, y: 1)
                        .shadow(color: .black.opacity(0.65), radius: 5, y: 1)
                        .id(line.id)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, presentationVersion == .transparentV2 ? 0 : 16)
                .padding(.vertical, 8)
            }
            .scrollIndicators(.automatic)
        }
    }

    @ViewBuilder
    private func statusView(_ state: LyricsLoadState) -> some View {
        FloatingLyricsStatusView(
            state: state,
            message: self.state.liveLyricsStatusMessage,
            title: self.state.currentTrack.title
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    // Keep the shared layer and reading preferences, but bound the desktop
    // type scale independently of the much larger main-window lyric stage.
    private var desktopPreferences: DisplayPreferences {
        var preferences = state.preferences
        preferences.fontSize = min(20, max(12.6, preferences.fontSize * 0.8))
        preferences.assistantFontSize = min(16, max(11, preferences.assistantFontSize))
        return preferences
    }

    private var visibleLayerCount: Int {
        let prefs = state.preferences
        var count = prefs.showOriginal ? 1 : 0
        count += prefs.showTranslation ? 1 : 0
        count += prefs.showRomaji ? 1 : 0
        count += prefs.showKana ? 1 : 0
        return max(1, count)
    }
}

/// The desktop style inspector lives in its own panel so a compact,
/// transparent lyric window never loses its only visible line underneath the
/// settings surface.
struct FloatingLyricsStylePanelView: View {
    @ObservedObject var settings: AppSettingsStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("桌面歌词").font(.headline)
                Picker("行数", selection: $settings.floatingDesktopLineMode) {
                    ForEach(FloatingDesktopLineMode.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                HStack {
                    Text("字号")
                    Slider(value: $settings.floatingDesktopFontSize, in: 22...64, step: 1)
                    Text("\(Int(settings.floatingDesktopFontSize))").monospacedDigit().frame(width: 26)
                }
                FloatingDesktopColorControls(settings: settings)
                Picker("第二行", selection: $settings.floatingDesktopCompanion) {
                    Text("译文 / 下一句").tag("translation")
                    Text("假名").tag("kana")
                    Text("罗马音 / 拼音").tag("reading")
                }
                Text("第二行按此处选择显示；无译文时默认显示下一句。")
                    .font(.caption).foregroundStyle(.secondary)
                LyricsPresentationOffsetControl(settings: settings)
                Divider()
                Text("共享歌词层").font(.caption).foregroundStyle(.secondary)
                Toggle("原文", isOn: $settings.displayPreferences.showOriginal)
                Toggle("译文", isOn: $settings.displayPreferences.showTranslation)
                Toggle("罗马音", isOn: $settings.displayPreferences.showRomaji)
                Toggle("拼音", isOn: $settings.displayPreferences.showPinyin)
                Toggle("假名", isOn: $settings.displayPreferences.showKana)
                Picker("繁简转换", selection: Binding(
                    get: { settings.readingPreferences.scriptConversionID },
                    set: { value in
                        var next = settings.readingPreferences
                        next.scriptConversionID = value
                        settings.readingPreferences = next
                    }
                )) {
                    Text("不转换").tag(ScriptConversionID.none.rawValue)
                    Text("繁体转简体").tag(ScriptConversionID.traditionalToSimplified.rawValue)
                    Text("简体转繁体").tag(ScriptConversionID.simplifiedToTraditional.rawValue)
                }
                Text("假名与拼音显示在原文上方；第二行可独立显示译文或其他读音。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("逐字变色仅用于带真实逐字时间的歌词；单行时间不模拟逐字进度。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(18)
            .frame(width: 352)
        }
        .frame(width: 352, height: 600)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.14)))
        .preferredColorScheme(.dark)
    }
}

/// Each layer is one measured horizontal ribbon. Shared playback position
/// reveals overflow; dragging lets a paused listener inspect either end.
private struct FloatingDesktopRibbon<Content: View>: View {
    let label: String
    let width: CGFloat
    let height: CGFloat
    let elapsed: Double
    let duration: Double
    var allowsMotion: Bool = true
    @ViewBuilder let content: () -> Content
    @State private var measuredWidth: CGFloat?
    @State private var manualOffset: CGFloat?
    @State private var dragOrigin: CGFloat?

    private var frameAlignment: Alignment {
        guard allowsMotion else { return .center }
        return .leading
    }

    private var automaticOffset: CGFloat {
        guard allowsMotion else { return 0 }
        return CGFloat(FloatingDesktopTypography.ribbonPlacementOffset(
            measuredWidth: measuredWidth.map(Double.init),
            viewport: Double(width),
            elapsed: elapsed,
            duration: duration
        ))
    }
    private var offset: CGFloat {
        guard allowsMotion else { return 0 }
        guard let measuredWidth, measuredWidth > 0 else { return 0 }
        guard measuredWidth > width else { return 0 }
        let overflow = measuredWidth - width
        let scrollOffset = min(overflow, max(0, manualOffset ?? -automaticOffset))
        return -scrollOffset
    }
    var body: some View {
        content()
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: true)
            .background(GeometryReader { geometry in
                Color.clear.preference(key: FloatingRibbonWidthKey.self, value: geometry.size.width)
            })
            .offset(x: offset)
            .frame(width: width, height: height, alignment: frameAlignment)
            .clipped()
            .contentShape(Rectangle())
            .onPreferenceChange(FloatingRibbonWidthKey.self) { value in
                guard value.isFinite, value > 0 else { return }
                measuredWidth = value
            }
            .gesture(DragGesture(minimumDistance: 4)
                .onChanged { value in
                    guard allowsMotion else { return }
                    if dragOrigin == nil { dragOrigin = manualOffset ?? max(0, -automaticOffset) }
                    let overflow = max(0, (measuredWidth ?? 0) - width)
                    manualOffset = min(overflow, max(0, (dragOrigin ?? 0) - value.translation.width))
                }
                .onEnded { _ in dragOrigin = nil })
            .help(allowsMotion ? "长句可左右拖动查看" : "")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
    }
}
private struct FloatingRibbonWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// AppKit draws the optional outline first and the fill second. Keeping the
/// fill pass separate prevents the stroke from tinting the glyph interior.
/// No blur, playback ownership, or timing projection lives in this primitive.
struct OutlinedLyricText: NSViewRepresentable {
    let text: String
    let font: NSFont
    let fill: Color
    let outline: Color
    let width: CGFloat
    var drawOutline: Bool = true

    func makeNSView(context: Context) -> OutlinedLyricTextView { OutlinedLyricTextView() }
    func updateNSView(_ view: OutlinedLyricTextView, context: Context) {
        view.update(text: text, font: font, fill: NSColor(fill), outline: NSColor(outline),
                    width: width, drawOutline: drawOutline)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: OutlinedLyricTextView, context: Context) -> CGSize? {
        // Measure the current SwiftUI value directly. Reading intrinsicContentSize here
        // can observe the previous AppKit value before updateNSView has received the
        // replacement line, which makes the new line render at an old/empty width for
        // one layout pass. The AppKit view keeps its intrinsic size for its own fallback;
        // SwiftUI's first measurement must be driven by the current text.
        let inset = max(1, width + 1)
        let size = NSAttributedString(string: text, attributes: [.font: font]).size()
        return CGSize(width: ceil(size.width) + inset * 2,
                      height: ceil(size.height) + inset * 2)
    }
}

final class OutlinedLyricTextView: NSView {
    private var fillText = NSAttributedString(string: "")
    private var outlineText: NSAttributedString?
    private var inset: CGFloat = 2
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        let size = fillText.size()
        return NSSize(width: ceil(size.width) + inset * 2, height: ceil(size.height) + inset * 2)
    }
    func update(text value: String, font: NSFont, fill: NSColor, outline: NSColor,
                width: CGFloat, drawOutline: Bool) {
        let nextInset = max(1, width + 1)
        let plan = FloatingDesktopTextRenderPlan(
            outlineWidth: Double(width),
            fontSize: Double(font.pointSize),
            drawOutline: drawOutline
        )
        let nextFillText = NSAttributedString(string: value, attributes: [
            .font: font,
            .foregroundColor: fill
        ])
        let nextOutlineText: NSAttributedString? = if plan.outlineEnabled {
            NSAttributedString(string: value, attributes: [
                .font: font,
                .foregroundColor: outline,
                .strokeColor: outline,
                .strokeWidth: plan.strokeWidthPercent
            ])
        } else {
            nil
        }

        let outlineMatches: Bool = switch (outlineText, nextOutlineText) {
        case (nil, nil): true
        case let (.some(existing), .some(next)): existing.isEqual(to: next)
        default: false
        }
        guard !fillText.isEqual(to: nextFillText) || !outlineMatches || inset != nextInset else { return }
        inset = nextInset
        fillText = nextFillText
        outlineText = nextOutlineText
        setAccessibilityElement(true)
        setAccessibilityLabel(value)
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        if let outlineText {
            outlineText.draw(at: NSPoint(x: inset, y: inset))
        }
        fillText.draw(at: NSPoint(x: inset, y: inset))
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct FloatingDesktopPalette {
    let original: Color
    let highlight: Color
    let ruby: Color
    let translation: Color
    let outline: Color
    let outlineWidth: CGFloat

    static func accentHex(theme: String) -> String {
        switch FloatingDesktopTheme(rawValue: theme) ?? .mint {
        case .mint: return "66FFC4"
        case .amber: return "FFD14D"
        case .ice: return "73D4FF"
        }
    }
    static func color(_ hex: String, fallback: String) -> Color {
        let rgb = FloatingDesktopColor(hex: hex, fallback: fallback)
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
    init(settings: AppSettingsStore) {
        original = Self.color(settings.floatingDesktopOriginalColorHex, fallback: "FFFFFF")
        highlight = Self.color(settings.floatingDesktopHighlightColorHex, fallback: Self.accentHex(theme: settings.floatingDesktopTheme))
        ruby = Self.color(settings.floatingDesktopRubyColorHex, fallback: "E5F3FF")
        translation = Self.color(settings.floatingDesktopTranslationColorHex, fallback: "FFFFFF")
        outline = Self.color(settings.floatingDesktopOutlineColorHex, fallback: "10131A")
        outlineWidth = FloatingDesktopTypography.outlineWidth(settings.floatingDesktopOutlineWidth)
    }
}

struct FloatingDesktopColorControls: View {
    @ObservedObject var settings: AppSettingsStore
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Picker("配色预设", selection: $settings.floatingDesktopTheme) {
                ForEach(FloatingDesktopTheme.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
            }
            .onChange(of: settings.floatingDesktopTheme) { _, _ in resetColors() }
            colorPicker("原文", value: $settings.floatingDesktopOriginalColorHex, fallback: "FFFFFF")
            colorPicker("已唱文字", value: $settings.floatingDesktopHighlightColorHex, fallback: FloatingDesktopPalette.accentHex(theme: settings.floatingDesktopTheme))
            colorPicker("假名 / 读音", value: $settings.floatingDesktopRubyColorHex, fallback: "E5F3FF")
            colorPicker("译文", value: $settings.floatingDesktopTranslationColorHex, fallback: "FFFFFF")
            colorPicker("文字描边", value: $settings.floatingDesktopOutlineColorHex, fallback: "10131A")
            HStack {
                Text("描边宽度")
                Slider(value: $settings.floatingDesktopOutlineWidth, in: 0...3, step: 0.25)
                Text(String(format: "%.2g", settings.floatingDesktopOutlineWidth)).monospacedDigit().frame(width: 28)
            }
            Toggle("文字保持不透明", isOn: $settings.floatingDesktopKeepsTextOpaque)
            Text("透明桌面模式下，开启后透明度只影响背景；关闭后影响整个悬浮窗。")
                .font(.caption).foregroundStyle(.secondary)
            Button("恢复当前预设颜色与描边") {
                resetColors()
                settings.floatingDesktopOutlineWidth = 1.25
            }
        }
    }
    private func colorPicker(_ title: String, value: Binding<String>, fallback: String) -> some View {
        ColorPicker(title, selection: Binding(
            get: { FloatingDesktopPalette.color(value.wrappedValue, fallback: fallback) },
            set: { color in
                guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
                value.wrappedValue = String(format: "%02X%02X%02X", Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
            }
        ), supportsOpacity: false)
    }
    private func resetColors() {
        settings.floatingDesktopOriginalColorHex = ""
        settings.floatingDesktopHighlightColorHex = ""
        settings.floatingDesktopRubyColorHex = ""
        settings.floatingDesktopTranslationColorHex = ""
        settings.floatingDesktopOutlineColorHex = ""
    }
}
