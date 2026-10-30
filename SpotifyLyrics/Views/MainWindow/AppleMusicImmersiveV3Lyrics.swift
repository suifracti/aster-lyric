import Foundation
import SwiftUI
import AppKit
import CoreText
import Combine
import os

enum V3BigLineLayout {
    struct Measurement {
        var lines: Int
        var height: CGFloat
        var width: CGFloat
    }
    static func text(_ text: String, size: CGFloat, width: CGFloat) -> Measurement {
        let font = TimedTextComposer.makeSystemFont(size: size, weight: NSFont.Weight(V3LyricMotionPolicy.layoutNSWeight))
        let ranges = V3LyricDisplayLineBreaker.ranges(text, font: font, width: width)
        let source = text as NSString
        let measuredWidth = ranges.map {
            CTLineGetTypographicBounds(CTLineCreateWithAttributedString(NSAttributedString(string: source.substring(with: $0), attributes: [.font: font])), nil, nil, nil)
        }.max() ?? 0
        return Measurement(lines: ranges.count,
            height: CGFloat(ranges.count) * ceil(CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)), width: measuredWidth)
    }
    static func fit(preferredSize: CGFloat, maxHeight: CGFloat,
                    measure: (CGFloat) -> Measurement) -> CGFloat {
        func fits(_ size: CGFloat) -> Bool {
            let value = measure(size)
            return value.lines <= 2 && value.height <= maxHeight
        }
        if fits(preferredSize) { return preferredSize }
        var low: CGFloat = 0, high = preferredSize
        for _ in 0..<12 {
            let middle = (low + high) / 2
            if fits(middle) { low = middle } else { high = middle }
        }
        return max(0.1, low)
    }
}

private struct V3LyricsCopyRequest: Identifiable {
    let id = UUID()
    let lines: [LyricLine]
    let title: String
    let index: Int
    let trackStableKey: String?
    let artistDisplay: String
    let language: String?
}

struct AppleMusicImmersiveV3LyricsViewport: View, Equatable {
    @Environment(\.lyricTextAlignment) private var textAlignment
    let state: PlaybackState
    @State private var renderedSignature: RenderSignature?
    @State private var refreshQueue = RefreshQueue()

    private final class RefreshQueue { var isScheduled = false }
    private struct RenderSignature: Equatable {
        let lines: [LyricLine]
        let track: Track
        let currentIndex: Int?
        let synchronized: Bool
        let revision: UInt64
        let loadState: LyricsLoadState
        let language: String?
        let preferences: DisplayPreferences
        let preview: Bool
        let instrumental: Bool
        let wordClock: LyricsPresentationClock?
        let loopedLineID: UUID?
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.state === rhs.state && lhs.availableWidth == rhs.availableWidth
            && lhs.compact == rhs.compact && lhs.lyricsFocus == rhs.lyricsFocus
            && lhs.liveOnly == rhs.liveOnly && lhs.stage == rhs.stage
            && (lhs.onSearch == nil) == (rhs.onSearch == nil)
    }

    private var renderSignature: RenderSignature {
        let lines = documentLines
        let index = liveOnly ? state.liveCurrentLineIndex : state.currentLineIndex
        let sync = liveOnly ? state.liveLyricsAreSynchronized : state.lyricsAreSynchronized
        let usesWordClock = sync && index.map { lines.indices.contains($0) && lines[$0].timedSpans?.isEmpty == false } == true
        return RenderSignature(lines: lines, track: documentTrack, currentIndex: index,
            synchronized: sync, revision: documentRevision, loadState: documentState,
            language: isPreview ? nil : state.liveLyricsLanguage, preferences: state.preferences,
            preview: isPreview, instrumental: hasExplicitInstrumentalMark,
            wordClock: usesWordClock || LyricsTimeline.vocalCountdownWindow(lines: lines, currentIndex: index, isSynchronized: sync) != nil
                ? state.presentationClock : nil,
            loopedLineID: state.loopedLyricLineID)
    }

    private func scheduleContentRefresh() {
        guard !refreshQueue.isScheduled else { return }
        refreshQueue.isScheduled = true
        // objectWillChange arrives before the new values are stored. Coalesce
        // one main-turn read, then invalidate only for visible lyric changes.
        DispatchQueue.main.async {
            refreshQueue.isScheduled = false
            let next = renderSignature
            if next != renderedSignature { renderedSignature = next }
        }
    }
    @State private var rubyCorrection: RubyCorrectionRequest?
    @State private var copyRequest: V3LyricsCopyRequest?
    let availableWidth: CGFloat
    let compact: Bool
    let lyricsFocus: Bool
    let onSearch: (() -> Void)?
    var liveOnly: Bool = false
    let stage: Bool

    /// The active index is already published by PlaybackState at the
    /// presentation-clock boundary. Scrolling is only a visual follow; wrap
    /// and row height stay frozen, so this animation must not share a
    /// transaction with layout.
    private var v3LineFollowAnimation: Animation? {
        V3LyricMotionPolicy.followAnimation(reduceMotion: reduceMotion)
    }

    private var isPreview: Bool { !liveOnly && state.isShowingSearchPreview }
    private var hasExplicitInstrumentalMark: Bool {
        !state.isShowingSearchPreview && state.liveTrackIsMarkedInstrumental
    }
    private var documentLines: [LyricLine] { liveOnly ? state.liveLyrics : state.lyrics }
    private var documentState: LyricsLoadState { liveOnly ? state.liveLyricsState : state.lyricsState }
    private var documentRevision: UInt64 { liveOnly ? state.liveLyricsSessionRevision : state.lyricsSessionRevision }
    private var documentTrack: Track { liveOnly ? state.currentTrack : state.displayedTrack }
    @EnvironmentObject private var settings: AppSettingsStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.lyricPresentationScale) private var presentationScale

    var body: some View {
        let _ = renderedSignature
        // PlaybackState publishes time at a high cadence. Resolve the active
        // main-window document once for this render pass. Catalog selections
        // use the preview session; live-only projections belong to secondary
        // windows and must not keep the previous track's lyrics on screen.
        let lines = documentLines
        let synchronized = liveOnly ? state.liveLyricsAreSynchronized : state.lyricsAreSynchronized
        // Line identity is published only at lyric boundaries. Do not derive
        // it from the 5 Hz currentTime tick or the 60 fps presentation clock.
        let currentIndex = liveOnly ? state.liveCurrentLineIndex : state.currentLineIndex
        let language = isPreview ? nil : state.liveLyricsLanguage
        let trackStableKey = isPreview
            ? TrackIdentity(track: documentTrack).stableKey
            : state.currentTrackIdentity?.stableKey
        let artistDisplay = documentTrack.artist
        let seekDocumentIdentity = TrackIdentity(track: documentTrack)
        let seekDocumentRevision = documentRevision
        let seekDocumentSource: PlaybackState.LyricsSeekDocumentSource = isPreview ? .searchPreview : .live

        return VStack(alignment: .leading, spacing: LyricsDesignTokens.Spacing.xs) {
            if hasExplicitInstrumentalMark {
                HStack(spacing: 12) {
                    Label("已标记为纯音乐", systemImage: "music.note")
                        .foregroundStyle(.white.opacity(0.68))
                    Spacer(minLength: 0)
                    Button("撤销标记") { state.clearCurrentInstrumentalMark() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white.opacity(0.86))
                        .help("恢复这首歌原先保存的歌词选择，不重新搜索")
                        .accessibilityIdentifier("v3.instrumental.undo")
                }
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            if lines.isEmpty {
                if liveOnly {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(emptyTitle).font(.title2)
                        if !emptyDetail.isEmpty { Text(emptyDetail).foregroundStyle(.secondary) }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if lyricsFocus {
                    focusEmptyState
                } else {
                    emptyState
                }
            } else {
                lyricsScroll(
                    lines: lines,
                    synchronized: synchronized,
                    currentIndex: currentIndex,
                    language: language,
                    trackStableKey: trackStableKey,
                    artistDisplay: artistDisplay,
                    seekDocumentIdentity: seekDocumentIdentity,
                    seekDocumentRevision: seekDocumentRevision,
                    seekDocumentSource: seekDocumentSource
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: V3JapaneseReadingCache.Preparation(lines: lines, language: language,
            userEntries: settings.readingUserDictionary.load(), trackStableKey: trackStableKey,
            artistDisplay: artistDisplay, scriptConversion: settings.readingPreferences.scriptConversion)) {
                await V3JapaneseReadingCache.prepare(.init(lines: lines, language: language,
                    userEntries: settings.readingUserDictionary.load(), trackStableKey: trackStableKey,
                    artistDisplay: artistDisplay, scriptConversion: settings.readingPreferences.scriptConversion))
        }
        .environment(\.v3ExplicitInstrumentalMark, hasExplicitInstrumentalMark)
        .onAppear { renderedSignature = renderSignature }
        .onReceive(state.objectWillChange) { _ in scheduleContentRefresh() }
        .background {
            EmptyView()
                .sheet(item: $rubyCorrection) { request in
                    RubyCorrectionEditorView(state: state, request: request)
                }
        }
        .background {
            EmptyView()
                .sheet(item: $copyRequest) { request in
                    LyricsCopyView(lines: request.lines, title: request.title,
                        trackStableKey: request.trackStableKey, artistDisplay: request.artistDisplay,
                        language: request.language, userEntries: settings.readingUserDictionary.load(),
                        initialSelectedIndex: request.index)
                }
        }
        .onChange(of: state.currentTrackIdentity) { _, _ in rubyCorrection = nil; copyRequest = nil }
        .onChange(of: state.liveLyricsVersionID) { _, _ in rubyCorrection = nil; copyRequest = nil }
        .onChange(of: documentTrack.id) { _, _ in copyRequest = nil }

    }

    private var focusEmptyState: some View {
        LyricsStateContentFirstView(
            state: state,
            compact: true,
            lyricsFocus: true,
            compactLabel: "导入",
            onSearch: onSearch
        )
    }

    private var emptyState: some View {
        LyricsStateContentFirstView(
            state: state,
            compact: compact,
            lyricsFocus: false,
            onSearch: onSearch
        )
    }

    private var emptyTitle: String {
        switch documentState {
        case .loading: return "正在获取歌词…"
        case .failed: return "歌词暂不可用"
        case .noLyrics, .noSelection, .noMatch: return "暂无歌词"
        case .candidates: return "请选择歌词候选"
        case .idle: return "等待正在播放的歌曲"
        default: return "歌词"
        }
    }

    private var emptyDetail: String {
        switch documentState {
        case .failed(_, let failure): return failure.userFacingMessage
        case .noLyrics, .noMatch: return "可从右上角工具菜单重试自动补全"
        case .noSelection: return liveOnly ? "可从右上角选择歌词版本" : "当前会话未选择歌词版本；可从右上角重新搜索"
        default: return ""
        }
    }

    private func lyricsScroll(
        lines: [LyricLine],
        synchronized: Bool,
        currentIndex: Int?,
        language: String?,
        trackStableKey: String?,
        artistDisplay: String,
        seekDocumentIdentity: TrackIdentity,
        seekDocumentRevision: UInt64,
        seekDocumentSource: PlaybackState.LyricsSeekDocumentSource
    ) -> some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                let bigLine = settings.v3BigLineModeEnabled && synchronized
                let scrollAnchor = bigLine ? 0 : V3ResponsiveGeometry.lyricScrollAnchor(
                    viewportHeight: geometry.size.height,
                    stage: stage
                )
                let verticalPadding = synchronized
                    ? max(120, geometry.size.height * 0.47)
                    : 28.0
                let scroll = ScrollView(.vertical) {
                    // The active row and its reading/translation layers have
                    // variable heights. LazyVStack can enter SwiftUI's anchor
                    // placement loop when scrollTo is animated during that
                    // reflow (observed as a permanent 100% CPU hang). A song
                    // is a small, bounded document, so eager placement is the
                    // safer tradeoff for this primary reading surface.
                    AppleMusicImmersiveV3LyricsDocumentView(
                        lines: lines,
                        currentIndex: currentIndex,
                        synchronized: synchronized,
                        language: language,
                        trackStableKey: trackStableKey,
                        artistDisplay: artistDisplay,
                        title: documentTrack.title,
                        duration: documentTrack.duration,
                        availableWidth: availableWidth,
                        compact: compact,
                        preferences: state.preferences,
                        presentationClock: state.presentationClock,
                        documentRevision: documentRevision,
                        verticalPadding: bigLine ? 0 : verticalPadding,
                        bigLineAvailableHeight: bigLine ? max(1, geometry.size.height - 32) : nil,
                        isPreview: isPreview,
                        loopedLineID: isPreview ? nil : state.loopedLyricLineID,
                        onToggleLoop: { lineID in
                            state.toggleLyricLineLoop(lineID: lineID, documentIdentity: seekDocumentIdentity,
                                documentRevision: seekDocumentRevision)
                        },
                        onSeek: { timestamp in
                            state.seekFromDisplayedLyrics(
                                to: timestamp,
                                documentIdentity: seekDocumentIdentity,
                                documentRevision: seekDocumentRevision,
                                documentSource: seekDocumentSource,
                                source: "v3-lyric-line"
                            )
                        },
                        onRuby: isPreview ? nil : { surface, reading in
                            let trackKey = state.currentTrackIdentity?.stableKey
                                ?? TrackIdentity(track: documentTrack).stableKey
                            guard let versionID = state.liveLyricsVersionID
                                ?? state.lyricsSession.activeLyricsVersionID else { return }
                            if rubyCorrection == nil {
                                rubyCorrection = RubyCorrectionRequest(
                                    surface: surface,
                                    reading: reading,
                                    trackKey: trackKey,
                                    lyricsVersionID: versionID,
                                    readingVersionID: state.selectedReadingVersion?.record.id,
                                    lines: state.liveLyrics
                                )
                            }
                        },
                        onCopyLine: { LyricsCopyText.copy($0) },
                        onCopyAll: { LyricsCopyText.copy(LyricsCopyText.format(lines)) },
                        onCopyPassage: { index in
                            copyRequest = V3LyricsCopyRequest(
                                lines: lines,
                                title: documentTrack.title,
                                index: index,
                                trackStableKey: trackStableKey,
                                artistDisplay: artistDisplay,
                                language: language
                            )
                        }
                    )
                    .equatable()
                }
                .scrollIndicators(.hidden)
                // A new active session is a direct document replacement. Its
                // old rows must not animate into a different track.
                .id("lyrics-document-\(documentRevision)")

                Group {
                    if synchronized && !bigLine {
                        scroll.mask(
                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: 0),
                                    .init(color: .black, location: 0.12),
                                    .init(color: .black, location: 0.88),
                                    .init(color: .clear, location: 1)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    } else {
                        // Plain lyrics are a reading surface: no fake current
                        // line, no distance hierarchy, no clipped first/last row.
                        scroll
                    }
                }
                .padding(.vertical, bigLine ? 16 : 0)
                .onReceive(V3JapaneseReadingCache.shared.$revision.dropFirst()) { _ in
                    // Reading layers arrive together; keep the active line at the same anchor.
                    DispatchQueue.main.async {
                        scrollToCurrentLine(using: proxy, lines: lines, currentIndex: currentIndex,
                            synchronized: synchronized, animated: false, anchorY: scrollAnchor)
                    }
                }
                .onChange(of: settings.v3BigLineModeEnabled) { _, _ in
                    DispatchQueue.main.async {
                        scrollToCurrentLine(using: proxy, lines: lines, currentIndex: currentIndex,
                            synchronized: synchronized, animated: false, anchorY: scrollAnchor)
                    }
                }
                .onAppear {
                    scrollToCurrentLine(
                        using: proxy,
                        lines: lines,
                        currentIndex: currentIndex,
                        synchronized: synchronized,
                        animated: false,
                        anchorY: scrollAnchor
                    )
                    prewarmUpcoming(around: currentIndex, lines: lines, language: language, trackStableKey: trackStableKey, artistDisplay: artistDisplay)
                }
                .onChange(of: currentIndex) { _, newIndex in
                    scrollToCurrentLine(
                        using: proxy,
                        lines: lines,
                        currentIndex: newIndex,
                        synchronized: synchronized,
                        animated: true,
                        anchorY: scrollAnchor
                    )
                    prewarmUpcoming(around: newIndex, lines: lines, language: language, trackStableKey: trackStableKey, artistDisplay: artistDisplay)
                }
                .onChange(of: documentRevision) { _, _ in
                    scrollToCurrentLine(
                        using: proxy,
                        lines: lines,
                        currentIndex: currentIndex,
                        synchronized: synchronized,
                        animated: false,
                        anchorY: scrollAnchor
                    )
                    prewarmUpcoming(around: 0, lines: lines, language: language, trackStableKey: trackStableKey, artistDisplay: artistDisplay)
                }
                .onChange(of: state.preferences) { _, _ in
                    scrollToCurrentLine(
                        using: proxy,
                        lines: lines,
                        currentIndex: currentIndex,
                        synchronized: synchronized,
                        animated: true,
                        anchorY: scrollAnchor
                    )
                    prewarmUpcoming(around: currentIndex, lines: lines, language: language, trackStableKey: trackStableKey, artistDisplay: artistDisplay)
                }
            }
        }
    }

    private func prewarmUpcoming(around index: Int?, lines: [LyricLine], language: String?, trackStableKey: String?, artistDisplay: String) {
        guard !lines.isEmpty else { return }
        let width = availableWidth
        let isComp = compact
        let scale = presentationScale
        let prefs = state.preferences
        let conversion = settings.readingPreferences.scriptConversion
        let userEntries = settings.readingUserDictionary.load()
        let currentIndex = index ?? 0

        V3JapaneseReadingCache.preparationQueue.async {
            let start = max(0, currentIndex)
            let end = min(lines.count, start + 3)
            for i in start..<end {
                V3LayoutPrewarmer.prewarm(
                    line: lines[i],
                    availableWidth: width,
                    compact: isComp,
                    presentationScale: scale,
                    preferences: prefs,
                    language: language,
                    userEntries: userEntries,
                    trackStableKey: trackStableKey,
                    artistDisplay: artistDisplay,
                    scriptConversion: conversion
                )
            }
        }
    }

    private func scrollToCurrentLine(
        using proxy: ScrollViewProxy,
        lines: [LyricLine],
        currentIndex: Int?,
        synchronized: Bool,
        animated: Bool,
        anchorY: CGFloat
    ) {
        guard synchronized,
              let currentIndex,
              lines.indices.contains(currentIndex) else {
            return
        }
        let id = lines[currentIndex].id
#if DEBUG
        let transitionTime = String(format: "%.3f", ProcessInfo.processInfo.systemUptime)
        LyricsE2ELog.log(
            "[LINE_INDEX] UI_TRANSITION_START_TIME=\(transitionTime) index=\(currentIndex) animated=\(animated)"
        )
#endif
        let action = { proxy.scrollTo(id, anchor: UnitPoint(x: 0.5, y: anchorY)) }
        if animated && !settings.v3BigLineModeEnabled {
            // Defer so wrap/opacity from this index change commit first.
            // withAnimation around scrollTo otherwise interpolates layout.
            DispatchQueue.main.async {
                withAnimation(v3LineFollowAnimation, action)
            }
        } else if settings.v3BigLineModeEnabled {
            DispatchQueue.main.async(execute: action)
        } else {
            action()
        }
    }
}

private struct AppleMusicImmersiveV3LyricsDocumentView: View, Equatable {
    @Environment(\.lyricIslandScene) private var readingScene
    @State private var rubyActionRelay = RubyCorrectionAction()
    @Environment(\.lyricTextAlignment) private var textAlignment
    @EnvironmentObject private var settings: AppSettingsStore

    let lines: [LyricLine]
    let currentIndex: Int?
    let synchronized: Bool
    let language: String?
    let trackStableKey: String?
    let artistDisplay: String
    let title: String
    let duration: TimeInterval
    let availableWidth: CGFloat
    let compact: Bool
    let preferences: DisplayPreferences
    let presentationClock: LyricsPresentationClock
    let documentRevision: UInt64
    let verticalPadding: CGFloat
    let bigLineAvailableHeight: CGFloat?
    let isPreview: Bool
    let loopedLineID: UUID?
    let onToggleLoop: (UUID) -> Void
    let onSeek: (TimeInterval) -> Void
    let onRuby: ((String, String) -> Void)?
    let onCopyLine: (String) -> Void
    let onCopyAll: () -> Void
    let onCopyPassage: (Int) -> Void

    static func == (
        lhs: AppleMusicImmersiveV3LyricsDocumentView,
        rhs: AppleMusicImmersiveV3LyricsDocumentView
    ) -> Bool {
        lhs.lines == rhs.lines
            && lhs.currentIndex == rhs.currentIndex
            && lhs.synchronized == rhs.synchronized
            && lhs.language == rhs.language
            && lhs.trackStableKey == rhs.trackStableKey
            && lhs.artistDisplay == rhs.artistDisplay
            && lhs.title == rhs.title
            && lhs.duration == rhs.duration
            && lhs.availableWidth == rhs.availableWidth
            && lhs.compact == rhs.compact
            && lhs.preferences == rhs.preferences
            && (!lhs.needsWordClock || lhs.presentationClock == rhs.presentationClock)
            && lhs.documentRevision == rhs.documentRevision
            && lhs.verticalPadding == rhs.verticalPadding
            && lhs.bigLineAvailableHeight == rhs.bigLineAvailableHeight
            && lhs.isPreview == rhs.isPreview
            && lhs.loopedLineID == rhs.loopedLineID
    }

    private var needsWordClock: Bool {
        if countdownWindow != nil { return true }
        guard synchronized, let currentIndex, lines.indices.contains(currentIndex) else { return false }
        return lines[currentIndex].timedSpans?.isEmpty == false
    }

    private var countdownWindow: LyricsTimeline.VocalCountdownWindow? {
        LyricsTimeline.vocalCountdownWindow(lines: lines, currentIndex: currentIndex, isSynchronized: synchronized)
    }

    private var rowSpacing: CGFloat {
        if readingScene == .linerNotes { return compact ? 16 : 20 }
        let layerCount = (preferences.showRomaji ? 1 : 0)
            + (preferences.showTranslation ? 1 : 0)
        if !synchronized {
            return max(18, (compact ? 21 : 24) - CGFloat(max(0, layerCount - 1)))
        }
        return max(20, (compact ? 24 : 28) - CGFloat(max(0, layerCount - 1)) * 2)
    }

    var body: some View {
        let _ = rubyActionRelay.action = onRuby
        let countdown = countdownWindow
        VStack(alignment: textAlignment.lyricHorizontalAlignment, spacing: rowSpacing) {
            ForEach(Array(lines.enumerated()).filter {
                bigLineAvailableHeight == nil || $0.offset >= (currentIndex ?? 0)
            }, id: \.element.id) { index, line in
                if let window = countdown, window.lineIndex == index {
                    V3VocalCountdown(window: window, clock: presentationClock)
                        .frame(maxWidth: .infinity, alignment: textAlignment.lyricFrameAlignment)
                }
                row(for: line, index: index)
                    .padding(.top, readingScene == .linerNotes && isParagraphStart(index) ? 14 : 0)
                    .id(line.id)
            }
        }
        .frame(maxWidth: .infinity, alignment: textAlignment.lyricFrameAlignment)
        .padding(.top, verticalPadding)
        .padding(.bottom, verticalPadding)
        .padding(.leading, textAlignment == .leading ? 0 : (compact ? 10 : 18) * (textAlignment == .center ? 0.5 : 1))
        .padding(.trailing, textAlignment == .trailing ? 0 : (compact ? 10 : 18) * (textAlignment == .center ? 0.5 : 1))
    }

    private func isParagraphStart(_ index: Int) -> Bool {
        guard index > 0, lines.indices.contains(index) else { return false }
        if lines[index - 1].originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        if synchronized { return lines[index].timestamp - lines[index - 1].timestamp > 8 }
        return false
    }

    @ViewBuilder
    private func row(for line: LyricLine, index: Int) -> some View {
        let isActive = synchronized && currentIndex == index
        let distance = synchronized && currentIndex != nil
            ? abs(index - (currentIndex ?? index))
            : 0
        let content = AppleMusicImmersiveV3LyricRow(
            line: line,
            isActive: isActive,
            distance: readingScene == .linerNotes ? 0 : (readingScene == .focusedLyrics ? min(1, distance) : distance),
            isSynchronized: synchronized,
            availableWidth: bigLineAvailableHeight == nil ? availableWidth : max(1, availableWidth - 20),
            compact: compact,
            preferences: preferences,
            language: language,
            trackStableKey: trackStableKey,
            artistDisplay: artistDisplay,
            presentationClock: presentationClock,
            bigLineAvailableHeight: isActive ? bigLineAvailableHeight : nil
        )
        .equatable()
        .environmentObject(settings)
        .environment(\.rubyCorrectionAction, onRuby == nil ? nil : rubyActionRelay)
        .overlay(alignment: .trailing) {
            if loopedLineID == line.id {
                Button { onToggleLoop(line.id) } label: { Image(systemName: "repeat").font(.system(size: 13)) }
                    .buttonStyle(.plain).help("取消循环").accessibilityLabel("取消循环")
            }
        }
        .contextMenu {
            if !isPreview, LyricsTimeline.validSeekTimestamp(for: line, isSynchronized: synchronized, duration: duration) != nil {
                Button(loopedLineID == line.id ? "取消循环" : "循环这一句", systemImage: "repeat") { onToggleLoop(line.id) }
                Divider()
            }
            Button("复制这一行", systemImage: "doc.on.doc") {
                onCopyLine(line.originalText)
            }
            Button("复制整首歌词", systemImage: "doc.on.doc.fill") {
                onCopyAll()
            }
            Divider()
            Button("选择段落复制…", systemImage: "checklist") {
                onCopyPassage(index)
            }
        }
        if let timestamp = LyricsTimeline.validSeekTimestamp(
            for: line,
            isSynchronized: synchronized,
            duration: duration
        ) {
            content
                .contentShape(Rectangle())
                .onTapGesture { onSeek(timestamp) }
                .frame(maxWidth: .infinity, alignment: textAlignment.lyricFrameAlignment)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(line.originalText)
                .accessibilityAction(named: "跳转到歌词时间") {
                    onSeek(timestamp)
                }
        } else {
            content
                .frame(maxWidth: .infinity, alignment: textAlignment.lyricFrameAlignment)
        }
    }
}

/// Only the three dots are scheduled; lyric rows keep their boundary-driven rendering.
private struct V3VocalCountdown: View {
    @Environment(\.v3CoverAccent) private var accent
    let window: LyricsTimeline.VocalCountdownWindow
    let clock: LyricsPresentationClock
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.1, paused: !clock.isPlaying)) { _ in
            let time = clock.presentationTime(at: ProcessInfo.processInfo.systemUptime)
            let progress = (time - window.start) / (window.end - window.start)
            HStack(spacing: 7) {
                ForEach(0..<3) { index in
                    Circle().fill(accent.opacity(0.2 + 0.8 * max(0, min(1, progress * 3 - Double(index)))))
                        .frame(width: 8, height: 8)
                }
            }
            .opacity(time >= window.start && time < window.end ? 1 : 0)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("前奏或间奏，准备进入下一句")
        }
        .frame(height: 12)
    }
}

enum V3ChinesePinyinCache {
    private static let lock = NSLock()
    private static var cache: [String: JapaneseRubyPresentation] = [:]

    static func presentation(for text: String) -> JapaneseRubyPresentation {
        guard !text.isEmpty else {
            return JapaneseRubyPresentation(originalText: text, reading: nil)
        }
        lock.lock()
        if let cached = cache[text] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let characters = Array(text)
        var tokens: [LyricRubyToken] = []
        var pinyinWords: [String] = []
        for char in characters {
            let surface = String(char)
            let value = char.unicodeScalars.first?.value ?? 0
            if (0x3400...0x4DBF).contains(value) || (0x4E00...0x9FFF).contains(value) || (0xF900...0xFAFF).contains(value) {
                let mutable = NSMutableString(string: surface) as CFMutableString
                CFStringTransform(mutable, nil, kCFStringTransformMandarinLatin, false)
                let marked = (mutable as String).trimmingCharacters(in: .whitespacesAndNewlines)
                tokens.append(LyricRubyToken(id: tokens.count, surface: surface, ruby: marked.isEmpty ? nil : marked))
                if !marked.isEmpty {
                    pinyinWords.append(marked)
                }
            } else {
                tokens.append(LyricRubyToken(id: tokens.count, surface: surface, ruby: nil))
                if !surface.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    pinyinWords.append(surface)
                }
            }
        }
        let pinyinText = pinyinWords.joined(separator: " ")
        let result = JapaneseRubyPresentation(
            originalText: text,
            reading: nil,
            preferredRubyTokens: tokens.map(\.surface).joined() == text ? tokens : nil,
            romajiText: pinyinText
        )

        lock.lock()
        cache[text] = result
        if cache.count > 512, let oldest = cache.keys.first {
            cache.removeValue(forKey: oldest)
        }
        lock.unlock()
        return result
    }
}

/// Reading generation is a fallback for provider lines that do not carry a
/// kana layer. Keep it outside the SwiftUI body so a row redraw does not run
/// MeCab repeatedly, which otherwise makes lyric scrolling feel sticky.
final class V3JapaneseReadingCache: ObservableObject {
    static let shared = V3JapaneseReadingCache()
    @Published private(set) var revision = 0
    static let preparationQueue = DispatchQueue(label: "lyrics.reading-preparation", qos: .userInitiated)

    struct Preparation: Hashable {
        let lines: [LyricLine]
        let language: String?
        let userEntries: [ReadingDictionaryEntry]
        let trackStableKey: String?
        let artistDisplay: String?
        let scriptConversion: ScriptConversionID
    }

    static func prepare(_ input: Preparation) async {
        await withCheckedContinuation { continuation in
            preparationQueue.async {
                for line in input.lines {
                    _ = resolvedPresentation(for: line, language: input.language, userEntries: input.userEntries,
                        trackStableKey: input.trackStableKey, artistDisplay: input.artistDisplay,
                        scriptConversion: input.scriptConversion)
                }
                DispatchQueue.main.async {
                    shared.revision += 1
                    continuation.resume()
                }
            }
        }
    }

    static func presentation(for line: LyricLine, language: String?, userEntries: [ReadingDictionaryEntry],
                             trackStableKey: String?, artistDisplay: String?) -> JapaneseRubyPresentation {
        let original = line.readingSurfaceText ?? line.originalText
        if let pinyinTokens = line.rubyTokens,
           line.readingRepresentationID?.hasPrefix("readingRepresentation.pinyin") == true {
            return JapaneseRubyPresentation(originalText: original, reading: nil, preferredRubyTokens: pinyinTokens, romajiText: line.romajiText)
        }
        let lang = language?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let isChinese: Bool = {
            if lang?.hasPrefix("ja") == true { return false }
            if lang?.hasPrefix("zh") == true { return true }
            return LyricsLanguageGate.containsHan(original) && !LyricsLanguageGate.containsKana(original)
        }()
        if isChinese {
            return V3ChinesePinyinCache.presentation(for: original)
        }
        guard LyricsLanguageGate.allowsJapaneseReadings(language: language, text: original) else {
            return JapaneseRubyPresentation(originalText: original, reading: nil)
        }
        let stored = line.kanaText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let kana = stored.flatMap { $0.isEmpty ? nil : JapaneseRomanizer.displayKana($0) }
        let result = reading(for: original, userEntries: userEntries, trackStableKey: trackStableKey,
                             artistDisplay: artistDisplay, providerKana: kana)
        return JapaneseRubyPresentation(line: line, reading: result,
            storedRubyIsAuthoritative: line.readingRepresentationID == ReadingRepresentationID.kana.rawValue)
    }

    private static let lock = NSLock()
    private static var values: [String: JapaneseReadingResult] = [:]
    private static var valueOrder: [String] = []

    static func reading(
        for text: String,
        userEntries: [ReadingDictionaryEntry],
        trackStableKey: String?,
        artistDisplay: String?,
        providerKana: String? = nil
    ) -> JapaneseReadingResult? {
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty else { return nil }
        let applicableEntries = ReadingEngineSupport.applicableUserEntries(
            userEntries,
            trackStableKey: trackStableKey,
            artistDisplay: artistDisplay
        )
        let correctionSignature = applicableEntries.map {
            [
                $0.id.uuidString,
                $0.surface,
                $0.reading,
                String($0.priority),
                $0.trackStableKey ?? "",
                $0.artistScope ?? ""
            ].joined(separator: "|")
        }
        let key = ReadingEngineSupport.hashContext(
            [normalizedText, trackStableKey ?? "", artistDisplay ?? "", providerKana ?? ""] + correctionSignature
        )

        lock.lock()
        if let cached = values[key] {
            valueOrder.removeAll { $0 == key }
            valueOrder.append(key)
            lock.unlock()
            return cached
        }
        lock.unlock()

        // View reads never invoke morphology. The whole document is prepared on the worker queue.
        guard !Thread.isMainThread else { return nil }
        let result = providerKana.map { JapaneseReadingPipeline.analyze(originalText: normalizedText, providerKana: $0) } ?? JapaneseContextualReadingEngine.analyze(
            text: normalizedText,
            userEntries: applicableEntries,
            trackStableKey: trackStableKey,
            artistDisplay: artistDisplay
        )

        lock.lock()
        values[key] = result
        valueOrder.removeAll { $0 == key }
        valueOrder.append(key)
        if valueOrder.count > 256 { values.removeValue(forKey: valueOrder.removeFirst()) }
        lock.unlock()
        return result
    }

    private static var resolvedCache: [String: JapaneseRubyPresentation] = [:]
    private static var resolvedOrder: [String] = []

    static func resolvedPresentation(
        for line: LyricLine,
        language: String?,
        userEntries: [ReadingDictionaryEntry],
        trackStableKey: String?,
        artistDisplay: String?,
        scriptConversion: ScriptConversionID
    ) -> JapaneseRubyPresentation {
        let original = line.readingSurfaceText ?? line.originalText
        guard !original.isEmpty else {
            return JapaneseRubyPresentation(originalText: "", reading: nil)
        }
        // Projection UUIDs/timestamps are not reading inputs; dictionary contents are.
        var hasher = Hasher()
        hasher.combine(original)
        hasher.combine(line.kanaText)
        hasher.combine(line.romajiText)
        hasher.combine(line.rubyTokens)
        hasher.combine(line.readingRepresentationID)
        hasher.combine(language)
        hasher.combine(scriptConversion)
        hasher.combine(userEntries)
        hasher.combine(trackStableKey)
        hasher.combine(artistDisplay)
        let key = String(hasher.finalize())
        lock.lock()
        if let cached = resolvedCache[key] {
            resolvedOrder.removeAll { $0 == key }
            resolvedOrder.append(key)
            lock.unlock()
            return cached
        }
        lock.unlock()

        if Thread.isMainThread {
            return JapaneseRubyPresentation(originalText: ReadingScriptConverter.convert(original, using: scriptConversion),
                reading: nil)
        }
        let base = presentation(
            for: line,
            language: language,
            userEntries: userEntries,
            trackStableKey: trackStableKey,
            artistDisplay: artistDisplay
        )
        let resolved: JapaneseRubyPresentation
        if scriptConversion != .none {
            let convertedOriginal = ReadingScriptConverter.convert(base.originalText, using: scriptConversion)
            let convertedTokens: [LyricRubyToken]?
            if let tokens = base.rubyTokens {
                convertedTokens = ReadingScriptConverter.convertRubyTokens(
                    tokens,
                    originalText: base.originalText,
                    convertedText: convertedOriginal,
                    using: scriptConversion
                ) ?? tokens
            } else {
                convertedTokens = nil
            }
            resolved = JapaneseRubyPresentation(
                originalText: convertedOriginal,
                reading: nil,
                preferredRubyTokens: convertedTokens,
                kanaText: base.kanaText,
                romajiText: base.romajiText
            )
        } else {
            resolved = base
        }

        lock.lock()
        resolvedCache[key] = resolved
        resolvedOrder.removeAll { $0 == key }
        resolvedOrder.append(key)
        if resolvedOrder.count > 512 { resolvedCache.removeValue(forKey: resolvedOrder.removeFirst()) }
        lock.unlock()
        return resolved
    }
}

private final class V3TimedMultilineLayoutBox: NSObject {
    let value: TimedMultilineLayout?

    init(_ value: TimedMultilineLayout?) {
        self.value = value
    }
}

private final class V3TimedRubyLayoutBox: NSObject {
    let value: TimedRubyLayout?

    init(_ value: TimedRubyLayout?) {
        self.value = value
    }
}

/// Playback time updates frequently for word/syllable progress. Keep the
/// CoreText geometry stable across those updates; the timed row still reads
/// the live presentation clock for its fill progress.
private enum V3TimedLayoutCache {
    private static let multilineCache: NSCache<NSString, V3TimedMultilineLayoutBox> = {
        let cache = NSCache<NSString, V3TimedMultilineLayoutBox>()
        cache.countLimit = 512
        return cache
    }()
    private static let rubyCache: NSCache<NSString, V3TimedRubyLayoutBox> = {
        let cache = NSCache<NSString, V3TimedRubyLayoutBox>()
        cache.countLimit = 512
        return cache
    }()

    static func key(
        kind: String,
        line: LyricLine,
        fontSize: CGFloat,
        weight: CGFloat,
        availableWidth: CGFloat? = nil,
        rubyTokens: [LyricRubyToken]? = nil,
        scriptConversion: ScriptConversionID? = nil
    ) -> String {
        var hasher = Hasher()
        hasher.combine(kind)
        hasher.combine(line)
        hasher.combine(fontSize)
        hasher.combine(weight)
        hasher.combine(availableWidth)
        hasher.combine(rubyTokens)
        hasher.combine(scriptConversion)
        return "\(kind)-\(hasher.finalize())"
    }

    static func multiline(
        for key: String,
        make: () -> TimedMultilineLayout?
    ) -> TimedMultilineLayout? {
        let cacheKey = key as NSString
        if let cached = multilineCache.object(forKey: cacheKey) {
            return cached.value
        }
        let value = make()
        multilineCache.setObject(V3TimedMultilineLayoutBox(value), forKey: cacheKey)
        return value
    }

    static func ruby(
        for key: String,
        make: () -> TimedRubyLayout?
    ) -> TimedRubyLayout? {
        let cacheKey = key as NSString
        if let cached = rubyCache.object(forKey: cacheKey) {
            return cached.value
        }
        let value = make()
        rubyCache.setObject(V3TimedRubyLayoutBox(value), forKey: cacheKey)
        return value
    }
}

enum V3LayoutPrewarmer {
    static func prewarm(
        line: LyricLine,
        availableWidth: CGFloat,
        compact: Bool,
        presentationScale: CGFloat,
        preferences: DisplayPreferences,
        language: String?,
        userEntries: [ReadingDictionaryEntry],
        trackStableKey: String?,
        artistDisplay: String?,
        scriptConversion: ScriptConversionID
    ) {
        let original = line.readingSurfaceText ?? line.originalText
        guard !original.isEmpty else { return }

        let presentation = V3JapaneseReadingCache.resolvedPresentation(
            for: line,
            language: language,
            userEntries: userEntries,
            trackStableKey: trackStableKey,
            artistDisplay: artistDisplay,
            scriptConversion: scriptConversion
        )

        let isPinyin = line.readingRepresentationID?.hasPrefix("readingRepresentation.pinyin") == true
        let hasPinyin = isPinyin && preferences.showPinyin
        let hasReading = hasPinyin ? true : preferences.showRomaji
        let layerCount = 1 + (hasReading ? 1 : 0) + (preferences.showTranslation && line.translationText != nil ? 1 : 0)
        let sizeScale = max(0.7, preferences.fontSize / 18)
        let upperBound = (compact ? 34 : 42) * sizeScale
        let lowerBound: CGFloat = compact ? 22 : 28
        let layerPenalty = CGFloat(max(0, layerCount - 2)) * 1.7
        let activeBaseSize = max(lowerBound, CGFloat(upperBound) - layerPenalty) * presentationScale
        let readableLineWidth = min(max(240, availableWidth), LyricsDesignTokens.readableLyricLineMaxWidth * presentationScale)

        let effectiveText = presentation.originalText
        let hasRuby = preferences.showOriginal && presentation.hasRuby && (isPinyin ? preferences.showPinyin : true) && preferences.kanaDisplayMode == .inlineRuby

        if let spans = line.timedSpans, !spans.isEmpty {
            let effectiveSpans = ReadingScriptConverter.convertSpans(
                spans,
                originalText: line.originalText,
                convertedText: effectiveText,
                using: scriptConversion
            ) ?? spans

            if hasRuby {
                let rubyTokens = presentation.rubyTokens
                let key = V3TimedLayoutCache.key(
                    kind: "ruby",
                    line: line,
                    fontSize: activeBaseSize,
                    weight: Font.Weight.heavy.nsWeightValue,
                    rubyTokens: rubyTokens,
                    scriptConversion: scriptConversion
                )
                _ = V3TimedLayoutCache.ruby(for: key) {
                    presentation.timedLayout(spans: effectiveSpans, fontSize: activeBaseSize, weight: Font.Weight.heavy.nsWeightValue)
                }
            } else if preferences.showOriginal {
                let key = V3TimedLayoutCache.key(
                    kind: "multiline",
                    line: line,
                    fontSize: activeBaseSize,
                    weight: Font.Weight.heavy.nsWeightValue,
                    availableWidth: readableLineWidth,
                    scriptConversion: scriptConversion
                )
                _ = V3TimedLayoutCache.multiline(for: key) {
                    TimedTextComposer.computeMultilineLayout(
                        originalText: effectiveText,
                        spans: effectiveSpans,
                        fontSize: activeBaseSize,
                        weight: Font.Weight.heavy.nsWeightValue,
                        design: "rounded",
                        availableWidth: readableLineWidth,
                        balanced: true
                    )
                }
            }
        }

        if !hasRuby {
            let activeKey = V3TimedLayoutCache.key(
                kind: "balancedPlain",
                line: line,
                fontSize: activeBaseSize,
                weight: Font.Weight.heavy.nsWeightValue,
                availableWidth: readableLineWidth,
                scriptConversion: scriptConversion
            )
            if AppleMusicImmersiveV3LyricRowContent.balancedTextCache.object(forKey: activeKey as NSString) == nil {
                let text = V3LyricDisplayLineBreaker.breakText(
                    effectiveText,
                    fontSize: activeBaseSize,
                    weight: Font.Weight.heavy.nsWeightValue,
                    availableWidth: readableLineWidth
                )
                AppleMusicImmersiveV3LyricRowContent.balancedTextCache.setObject(text as NSString, forKey: activeKey as NSString)
            }
        }
    }
}

/// Adds presentation-only line breaks for long plain-text lyrics. Stored
/// lyrics, translations, timing, search matching, and ruby tokens are never
/// changed. Ruby rows already wrap at morphology-token boundaries.
private struct AppleMusicImmersiveV3LyricRow: View, Equatable {
    @Environment(\.v3PreviewPresentation) private var previewPresentation
    @Environment(\.lyricPresentationScale) private var presentationScale
    @Environment(\.lyricTextAlignment) private var textAlignment
    let line: LyricLine
    let isActive: Bool
    let distance: Int
    let isSynchronized: Bool
    let availableWidth: CGFloat
    let compact: Bool
    let preferences: DisplayPreferences
    let language: String?
    let trackStableKey: String?
    let artistDisplay: String?
    var presentationClock: LyricsPresentationClock = LyricsPresentationClock()
    var bigLineAvailableHeight: CGFloat? = nil
    @EnvironmentObject private var settings: AppSettingsStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.v3ResolvedReadingProtection) private var resolvedReadingProtection
    private var showsReadingShadow: Bool {
        // The window resolves the bright-cover automatic shadow once per
        // composition; without it rows use the raw 清晰度 setting.
        (resolvedReadingProtection ?? settings.v3ReadingProtection)
            .effective(reduceTransparency: reduceTransparency,
                       increasedContrast: contrast == .increased) == .shadow
    }
    @Environment(\.lyricAgentPresentationMap) private var agentPresentationMap

    static func == (lhs: AppleMusicImmersiveV3LyricRow, rhs: AppleMusicImmersiveV3LyricRow) -> Bool {
        lhs.line == rhs.line
            && lhs.isActive == rhs.isActive
            && lhs.clampedDistance == rhs.clampedDistance
            && lhs.isSynchronized == rhs.isSynchronized
            && lhs.availableWidth == rhs.availableWidth
            && lhs.bigLineAvailableHeight == rhs.bigLineAvailableHeight
            && lhs.compact == rhs.compact
            && lhs.preferences == rhs.preferences
            && lhs.language == rhs.language
            && lhs.trackStableKey == rhs.trackStableKey
            && lhs.artistDisplay == rhs.artistDisplay
            && (!lhs.isActive || lhs.line.timedSpans?.isEmpty != false
                || lhs.presentationClock == rhs.presentationClock)
    }

    private var clampedDistance: Int {
        min(6, distance)
    }

    private var isPinyinProjection: Bool {
        guard let representation = line.readingRepresentationID else { return false }
        return representation.hasPrefix("readingRepresentation.pinyin")
    }

    private var layerCount: Int {
        let hasPinyin = isPinyinProjection && preferences.showPinyin
        let hasReading = hasPinyin ? true : preferences.showRomaji
        return 1 + (hasReading ? 1 : 0) + (preferences.showTranslation && line.translationText != nil ? 1 : 0)
    }

    private var layoutSignature: LyricsLayoutSignature {
        // Distance and active state are focus handoff state, not a layout
        // reflow. Keep them out of the animation value so the new line's
        // weight, opacity and blur change on the first frame. Preference and
        // content changes still use the established soft relayout animation.
        LyricsTransitionPolicy.signature(
            line: line,
            preferences: preferences,
            availableWidth: availableWidth,
            visibleLayerCount: layerCount,
            isSynchronized: isSynchronized,
            distance: 0
        )
    }

    private var rowOpacity: Double {
        guard isSynchronized else { return 1 }
        if settings.v3BigLineModeEnabled { return isActive ? 1 : 0.3 }
        let factor = max(0.15, min(1, preferences.opacity / 0.85))
        if isActive { return 1 }

        // Ambient remains legible beyond the active line. Stage and Classic
        // retain their established hierarchy in this first visual pass.
        if (previewPresentation ?? settings.v3ArtworkPresentation) == .ambientFeathered {
            switch clampedDistance {
            case 0: return 0.70 * factor
            case 1: return 0.68 * factor
            case 2: return 0.46 * factor
            default: return max(0.28, 0.36 - Double(clampedDistance - 3) * 0.03) * factor
            }
        }

        if clampedDistance <= 0 { return 0.58 }
        switch clampedDistance {
        case 1: return 0.44 * factor
        case 2: return 0.24 * factor
        default: return max(0.14, (0.22 - Double(clampedDistance - 3) * 0.025) * factor)
        }
    }

    /// 文字阴影 exists for bright, busy covers. A dimmed line at 0.14 opacity
    /// is too faint for any halo to outline, so shadow mode raises the dim
    /// floor enough that non-active lines and their translations stay
    /// readable while the active line still leads by a wide margin.
    private var presentedOpacity: Double {
        guard showsReadingShadow, isSynchronized, !isActive else { return rowOpacity }
        return rowOpacity + (1 - rowOpacity) * 0.34
    }

    private var rowBlur: CGFloat {
        guard isSynchronized, clampedDistance > 1 else { return 0 }
        switch clampedDistance {
        case 2: return 0.2
        default: return min(0.6, 0.2 + CGFloat(clampedDistance - 2) * 0.1)
        }
    }

    var body: some View {
        AppleMusicImmersiveV3LyricRowContent(
            line: line,
            isActive: isActive,
            isAdjacent: isSynchronized && distance == 1,
            isNearActive: !isSynchronized || distance <= 1,
            isSynchronized: isSynchronized,
            availableWidth: availableWidth,
            compact: compact,
            preferences: preferences,
            language: language,
            trackStableKey: trackStableKey,
            artistDisplay: artistDisplay,
            presentationClock: presentationClock,
            scriptConversion: settings.readingPreferences.scriptConversion,
            dictionaryRevision: ReadingUserDictionaryStore.currentRevision,
            presentationScale: presentationScale * (settings.v3BigLineModeEnabled && isSynchronized ? (isActive ? 2 : 0.6) : 1),
            textAlignment: textAlignment,
            bigLineAvailableHeight: bigLineAvailableHeight
        )
        .equatable()
        // Only the current line emits light; readability protection stays independent.
        .shadow(color: isActive ? .white.opacity(0.6 * settings.v3CurrentLineGlow) : .clear,
                radius: 8, x: 0, y: 0)
        // A tight glyph outline keeps bright covers readable without a wide dark halo.
        .shadow(color: showsReadingShadow ? .black.opacity(0.95) : .clear,
                radius: 2.5, x: 0, y: 1)
        .offset(x: CGFloat(agentPresentationMap.horizontalOffset(for: line.performerID)))
        .opacity(presentedOpacity)
        .blur(radius: reduceMotion ? 0 : rowBlur)
        .animation(nil, value: isActive)
        .animation(nil, value: layoutSignature)
    }
}

private struct AppleMusicImmersiveV3LyricRowContent: View, Equatable {
    @ObservedObject private var readingCache = V3JapaneseReadingCache.shared
    @Environment(\.v3CoverAccent) private var coverAccent
    @Environment(\.v3PreviewPresentation) private var previewPresentation
    @Environment(\.v3ExplicitInstrumentalMark) private var hasExplicitInstrumentalMark
    let line: LyricLine
    let isActive: Bool
    let isAdjacent: Bool
    let isNearActive: Bool
    let isSynchronized: Bool
    let availableWidth: CGFloat
    let compact: Bool
    let preferences: DisplayPreferences
    let language: String?
    let trackStableKey: String?
    let artistDisplay: String?
    var presentationClock: LyricsPresentationClock = LyricsPresentationClock()
    let scriptConversion: ScriptConversionID
    let dictionaryRevision: Int
    let presentationScale: CGFloat
    let textAlignment: TextAlignment
    var bigLineAvailableHeight: CGFloat? = nil
    @EnvironmentObject private var settings: AppSettingsStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.rubyCorrectionAction) private var correctRuby

    static func == (lhs: AppleMusicImmersiveV3LyricRowContent, rhs: AppleMusicImmersiveV3LyricRowContent) -> Bool {
        lhs.line == rhs.line
            && lhs.isActive == rhs.isActive
            && lhs.isAdjacent == rhs.isAdjacent
            && lhs.isNearActive == rhs.isNearActive
            && lhs.isSynchronized == rhs.isSynchronized
            && lhs.availableWidth == rhs.availableWidth
            && lhs.bigLineAvailableHeight == rhs.bigLineAvailableHeight
            && lhs.compact == rhs.compact
            && lhs.preferences == rhs.preferences
            && lhs.language == rhs.language
            && lhs.trackStableKey == rhs.trackStableKey
            && lhs.artistDisplay == rhs.artistDisplay
            && lhs.scriptConversion == rhs.scriptConversion
            && lhs.dictionaryRevision == rhs.dictionaryRevision
            && lhs.presentationScale == rhs.presentationScale
            && lhs.textAlignment == rhs.textAlignment
            // Only active word-timed rows consume the clock. Refresh them for
            // same-line pause/seek/offset changes without rebuilding static rows.
            && (!lhs.isActive || lhs.line.timedSpans?.isEmpty != false
                || lhs.presentationClock == rhs.presentationClock)
    }

    private var layerCount: Int {
        let hasPinyin = isPinyinProjection && preferences.showPinyin
        let hasReading = hasPinyin ? true : preferences.showRomaji
        return 1 + (hasReading ? 1 : 0) + (preferences.showTranslation && line.translationText != nil ? 1 : 0)
    }

    private var activeBaseSize: CGFloat {
        let sizeScale = max(0.7, preferences.fontSize / 18)
        let upperBound = (compact ? 34 : 42) * sizeScale
        let lowerBound: CGFloat = compact ? 22 : 28
        // Long lyrics keep their reading size and gain visual lines instead.
        let layerPenalty = CGFloat(max(0, layerCount - 2)) * 1.7
        return max(lowerBound, CGFloat(upperBound) - layerPenalty) * presentationScale
    }

    private var preferredBaseSize: CGFloat {
        guard isSynchronized else {
            return min((compact ? 30 : 36) * presentationScale, activeBaseSize)
        }
        return activeBaseSize
    }

    private var preferredRubySize: CGFloat {
        max(compact ? 12 : 14, min(22, preferredBaseSize * 0.44 * preferences.rubyFontSize / 10))
    }
    private var preferredAuxiliarySize: CGFloat {
        min(compact ? 16 : 18, max(12, preferredBaseSize * 0.44 * preferences.assistantFontSize / 14))
    }
    private static let bigLineSizeCache: NSCache<NSString, NSNumber> = {
        let cache = NSCache<NSString, NSNumber>(); cache.countLimit = 256; return cache
    }()
    private var baseSize: CGFloat {
        guard let height = bigLineAvailableHeight else { return preferredBaseSize }
        let key = "\(line.id)|\(effectiveOriginalText)|\(displayKanaText ?? "")|\(distinctRomaji ?? "")|\(line.translationText ?? "")|\(preferences)|\(height)|\(readableLineWidth)|\(preferredBaseSize)|\(dictionaryRevision)" as NSString
        if let size = Self.bigLineSizeCache.object(forKey: key) { return CGFloat(size.doubleValue) }
        let fitted = V3BigLineLayout.fit(preferredSize: preferredBaseSize, maxHeight: height) { size in
            let ratio = size / preferredBaseSize
            var main = V3BigLineLayout.Measurement(lines: 0, height: 0, width: 0)
            if shouldRenderInlineRuby || (preferences.showOriginal && preferences.kanaDisplayMode == .kanaReplacement && shouldShowKana) {
                let base = TimedTextComposer.makeSystemFont(size: size, weight: NSFont.Weight(V3LyricMotionPolicy.layoutNSWeight))
                let ruby = TimedTextComposer.makeSystemFont(size: preferredRubySize * ratio, weight: .regular)
                let groups = rubyTokenGroups(inlineRubyTokens ?? [LyricRubyToken(id: 0, surface: effectiveOriginalText, ruby: displayKanaText)])
                var rowWidth: CGFloat = 0
                for group in groups {
                    let reserve: CGFloat = group.count > 1 && group.filter { $0.ruby != nil }.count == 1 ? 10 : 0
                    let width = group.reduce(reserve) { total, token in
                        let text = NSAttributedString(string: token.surface, attributes: [.font: base])
                        let annotation = NSAttributedString(string: token.ruby ?? "", attributes: [.font: ruby])
                        return total + CGFloat(max(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(text), nil, nil, nil),
                            CTLineGetTypographicBounds(CTLineCreateWithAttributedString(annotation), nil, nil, nil)))
                    }
                    if main.lines == 0 || rowWidth + width > readableLineWidth { main.lines += 1; rowWidth = 0 }
                    rowWidth += width
                    main.width = max(main.width, rowWidth)
                }
                main.height = CGFloat(main.lines) * (ceil(CTFontGetAscent(base) + CTFontGetDescent(base)) + ceil(CTFontGetAscent(ruby) + CTFontGetDescent(ruby)) + 4)
                if main.width > readableLineWidth { main.lines = 3 }
            } else if preferences.showOriginal || shouldShowKana {
                main = V3BigLineLayout.text(preferences.showOriginal ? effectiveOriginalText : (displayKanaText ?? ""), size: size, width: readableLineWidth)
            }
            var auxiliary: [(String, CGFloat)] = []
            if preferences.showOriginal && preferences.kanaDisplayMode == .independentLine && shouldShowKana && !readingRepeatsOriginal {
                auxiliary.append((displayKanaText ?? "", preferredAuxiliarySize * ratio))
            }
            if shouldShowRomaji, let romaji = distinctRomaji { auxiliary.append((romaji, preferredAuxiliarySize * ratio)) }
            if preferences.showTranslation, let translation = line.translationText {
                auxiliary.append((translation, max(14, preferredAuxiliarySize * 0.94) * ratio))
            }
            for (text, fontSize) in auxiliary where !text.isEmpty {
                main.height += 8 + V3BigLineLayout.text(text, size: fontSize, width: readableLineWidth).height
            }
            return main
        }
        Self.bigLineSizeCache.setObject(NSNumber(value: Double(fitted)), forKey: key)
        return fitted
    }
    private var fittedRatio: CGFloat { bigLineAvailableHeight == nil ? 1 : baseSize / preferredBaseSize }
    private var rubySize: CGFloat { preferredRubySize * fittedRatio }
    private var auxiliarySize: CGFloat { preferredAuxiliarySize * fittedRatio }
    private var translationSize: CGFloat { max(14, preferredAuxiliarySize * 0.94) * fittedRatio }

    private var shouldShowRuby: Bool {
        preferences.kanaDisplayMode == .inlineRuby
    }

    private var shouldShowKana: Bool {
        preferences.kanaDisplayMode != .hidden && displayKanaText?.isEmpty == false
    }

    private var storedKanaText: String? {
        guard let kana = line.kanaText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !kana.isEmpty else {
            return nil
        }
        return JapaneseRomanizer.displayKana(kana)
    }

    private var rubyPresentation: JapaneseRubyPresentation {
        guard !effectiveOriginalText.isEmpty,
              LyricsLanguageGate.containsJapaneseSurface(effectiveOriginalText) || isPinyinProjection else {
            return JapaneseRubyPresentation(originalText: effectiveOriginalText, reading: nil)
        }
        return V3JapaneseReadingCache.resolvedPresentation(
            for: line,
            language: language,
            userEntries: settings.readingUserDictionary.load(),
            trackStableKey: trackStableKey,
            artistDisplay: artistDisplay,
            scriptConversion: scriptConversion
        )
    }

    private var displayKanaText: String? { rubyPresentation.kanaText }

    private var effectiveOriginalText: String {
        let base = line.readingSurfaceText ?? line.originalText
        if scriptConversion != .none {
            return ReadingScriptConverter.convert(base, using: scriptConversion)
        }
        return base
    }

    private var readableLineWidth: CGFloat {
        min(bigLineAvailableHeight == nil ? max(240, availableWidth) : max(1, availableWidth), LyricsDesignTokens.readableLyricLineMaxWidth * presentationScale)
    }

    fileprivate static let balancedTextCache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 1024
        return cache
    }()

    private var semanticDisplayText: String {
        let key = V3TimedLayoutCache.key(
            kind: "balancedPlain",
            line: line,
            fontSize: baseSize,
            weight: V3LyricMotionPolicy.layoutNSWeight,
            availableWidth: readableLineWidth,
            scriptConversion: scriptConversion
        )
        if let cached = Self.balancedTextCache.object(forKey: key as NSString) { return cached as String }
        let text = V3LyricDisplayLineBreaker.breakText(effectiveOriginalText, fontSize: baseSize, weight: V3LyricMotionPolicy.layoutNSWeight, availableWidth: readableLineWidth)
        Self.balancedTextCache.setObject(text as NSString, forKey: key as NSString)
        return text
    }

    private var isPinyinProjection: Bool {
        guard let representation = line.readingRepresentationID else { return false }
        return representation.hasPrefix("readingRepresentation.pinyin")
    }

    private var inlineRubyTokens: [LyricRubyToken]? { rubyPresentation.rubyTokens }

    private var shouldRenderInlineRuby: Bool {
        preferences.showOriginal && shouldShowRuby && rubyPresentation.hasRuby
            && (isPinyinProjection ? preferences.showPinyin : true)
            && !readingRepeatsOriginal
    }

    /// An all-kana line already reads as its own reading. A second kana row
    /// would repeat the line verbatim, so the reading layer stays hidden.
    private var readingRepeatsOriginal: Bool {
        guard let kana = displayKanaText, !kana.isEmpty else { return false }
        return normalizedDisplayText(kana) == normalizedDisplayText(effectiveOriginalText)
    }

    private var distinctRomaji: String? {
        if isPinyinProjection {
            guard preferences.showPinyin,
                  preferences.kanaDisplayMode != .inlineRuby,
                  let pinyin = (line.romajiText ?? rubyPresentation.romajiText)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !pinyin.isEmpty else { return nil }
            return pinyin
        }

        guard preferences.showRomaji,
              LyricsLanguageGate.allowsJapaneseReadings(language: language, text: effectiveOriginalText),
              let romaji = (line.romajiText ?? rubyPresentation.romajiText)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !romaji.isEmpty else { return nil }
        // A malformed provider payload sometimes repeats the kana layer in
        // `romajiText`. Do not show the same reading twice in independent-line
        // mode; legitimate Latin Hepburn remains unchanged.
        if let kana = displayKanaText,
           normalizedDisplayText(romaji) == normalizedDisplayText(kana) {
            return nil
        }
        return romaji
    }

    private func normalizedDisplayText(_ text: String) -> String {
        JapaneseRomanizer.displayKana(text)
            .split(whereSeparator: { $0.isWhitespace })
            .joined()
    }

    private var shouldShowRomaji: Bool {
        preferences.listeningLayerPreset != .translationOnly
            && (isPinyinProjection ? preferences.showPinyin : preferences.showRomaji)
    }

    private var rubyOpacity: Double {
        let factor = max(0.15, min(1, preferences.opacity / 0.85))
        if preferences.hideDistantAuxiliary && isSynchronized && !isNearActive { return 0 }
        if isActive { return 0.88 * factor }
        if !isSynchronized || isAdjacent { return 0.68 * factor }
        return 0.48 * factor
    }

    private var romajiOpacity: Double {
        let factor = max(0.15, min(1, preferences.opacity / 0.85))
        if preferences.hideDistantAuxiliary && isSynchronized && !isNearActive { return 0 }
        guard isSynchronized, isAdjacent else { return 0.65 * factor }
        return 0.48 * factor
    }

    private var rowWeight: Font.Weight {
        guard isSynchronized else { return .regular }
        return V3LyricMotionPolicy.layoutWeight
    }

    private var isInstrumentalLine: Bool {
        hasExplicitInstrumentalMark
            && (effectiveOriginalText.contains("纯音乐") || effectiveOriginalText.contains("没有填词"))
    }

    var body: some View {
        VStack(alignment: textAlignment.lyricHorizontalAlignment, spacing: 8) {
            if isInstrumentalLine {
                HStack(spacing: 8) {
                    Image(systemName: "music.note")
                        .font(.system(size: 14, weight: .medium))
                    Text("纯音乐 · 请您欣赏")
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                }
                .foregroundStyle(.white.opacity(0.88))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(0.20), lineWidth: 0.8)
                )
                .shadow(color: Color.black.opacity(0.2), radius: 8, x: 0, y: 3)
            } else if shouldRenderInlineRuby {
                let kana = displayKanaText ?? ""
                #if DEBUG
                let _ = Self.logRubyDecisionIfNeeded(
                    isActive: isActive,
                    line: line,
                    shouldRenderInlineRuby: true,
                    storedKana: storedKanaText,
                    displayKana: displayKanaText,
                    rubyTokens: inlineRubyTokens,
                    layout: line.timedSpans.flatMap { precomputedTimedRubyLayout(for: line, spans: $0) }
                )
                #endif
                if let timedSpans = line.timedSpans, !timedSpans.isEmpty,
                   let rubyLayout = precomputedTimedRubyLayout(for: line, spans: timedSpans) {
                    #if DEBUG
                    let _ = Self.logRowModeIfNeeded(mode: "timedRuby", width: readableLineWidth, lineWidth: 0)
                    #endif
                    timedRubyView(
                        kana: kana,
                        rubyLayout: rubyLayout
                    )
                } else {
                    #if DEBUG
                    if isActive {
                        let _ = Self.logRowModeIfNeeded(mode: "staticRuby", width: readableLineWidth, lineWidth: 0)
                    }
                    #endif
                    RubyLineView(
                        originalText: effectiveOriginalText,
                        kanaText: kana,
                        tokens: inlineRubyTokens,
                        baseFont: .system(size: baseSize, weight: rowWeight, design: .rounded),
                        rubyFont: .system(size: rubySize, weight: .regular, design: .rounded),
                        baseColor: isActive ? coverAccent : .white,
                        rubyColor: .white.opacity(rubyOpacity),
                        rubySpacing: 1,
                        tokenVerticalSpacing: 3,
                        maxWidth: readableLineWidth, highlightColor: coverAccent
                    )
                    .environment(\.rubyCorrectionAction, isPinyinProjection ? nil : correctRuby)
                }
            } else if preferences.showOriginal, preferences.kanaDisplayMode == .kanaReplacement, shouldShowKana,
                      let kana = displayKanaText {
                KanaReplacementLineView(
                    originalText: effectiveOriginalText,
                    kanaText: kana,
                    tokens: inlineRubyTokens,
                    showsOriginalAnnotation: true,
                    baseFont: .system(size: baseSize, weight: rowWeight, design: .rounded),
                    annotationFont: .system(size: rubySize, weight: .regular, design: .rounded),
                    baseColor: isActive ? coverAccent : .white,
                    annotationColor: .white.opacity(rubyOpacity),
                    maxWidth: readableLineWidth
                )
            } else if preferences.showOriginal {
                #if DEBUG
                let _ = Self.logRubyDecisionIfNeeded(
                    isActive: isActive,
                    line: line,
                    shouldRenderInlineRuby: false,
                    storedKana: storedKanaText,
                    displayKana: displayKanaText,
                    rubyTokens: inlineRubyTokens,
                    layout: nil
                )
                #endif
                if let timedSpans = line.timedSpans, !timedSpans.isEmpty,
                   let layout = precomputedTimedMultilineLayout(for: line, spans: timedSpans) {
                    #if DEBUG
                    let modeName = layout.isSingleLine ? "fineTiming" : "fineTimingMultiline"
                    let _ = Self.logRowModeIfNeeded(mode: modeName, width: readableLineWidth, lineWidth: layout.maxLineWidth)
                    #endif
                    timedOriginalView(layout: layout)
                } else {
                    #if DEBUG
                    if isActive {
                        let _ = Self.logRowModeIfNeeded(mode: "fallbackWrap", width: readableLineWidth, lineWidth: 0)
                    }
                    #endif
                    Text(semanticDisplayText)
                        .font(.system(size: baseSize, weight: rowWeight, design: .rounded))
                        .foregroundStyle(isActive ? coverAccent : .white)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if preferences.kanaDisplayMode == .independentLine, shouldShowKana,
                   !readingRepeatsOriginal, let kana = displayKanaText {
                    Text(kana)
                        .font(.system(size: auxiliarySize, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(rubyOpacity))
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }
            } else if shouldShowKana, !readingRepeatsOriginal, let kana = displayKanaText {
                Text(kana)
                    .font(.system(size: baseSize, weight: rowWeight, design: .rounded))
                    .foregroundStyle(isActive ? coverAccent : .white)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if shouldShowRomaji, let romaji = distinctRomaji {
                Text(romaji)
                    .font(.system(size: auxiliarySize, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(romajiOpacity))
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }

            if preferences.showTranslation, let translation = line.translationText, !translation.isEmpty {
                Text(translation)
                    .font(.system(size: translationSize, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(isActive ? 0.86 : ((previewPresentation ?? settings.v3ArtworkPresentation) == .ambientFeathered ? 0.76 : 0.54)))
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
        .lineLimit(nil)
        .multilineTextAlignment(textAlignment)
        .frame(width: readableLineWidth, alignment: textAlignment.lyricFrameAlignment)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func timedOriginalView(layout: TimedMultilineLayout) -> some View {
        let font = Font.system(size: baseSize, weight: rowWeight, design: .rounded)
        if isActive {
            TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !presentationClock.isPlaying)) { _ in
                let presentationTime = presentationClock.presentationTime(at: ProcessInfo.processInfo.systemUptime)
                AppleMusicImmersiveV3TimedRowView(
                    layout: layout,
                    currentTime: presentationTime,
                    font: font,
                    showsFill: isActive
                )
            }
            .fixedSize(horizontal: false, vertical: true)
        } else {
            AppleMusicImmersiveV3TimedRowView(
                layout: layout,
                currentTime: 0,
                font: font,
                showsFill: isActive
            )
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func timedRubyView(kana: String, rubyLayout: TimedRubyLayout) -> some View {
        let baseFont = Font.system(size: baseSize, weight: rowWeight, design: .rounded)
        let rubyFont = Font.system(size: rubySize, weight: .regular, design: .rounded)
        if isActive {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !presentationClock.isPlaying)) { _ in
                let presentationTime = presentationClock.presentationTime(at: ProcessInfo.processInfo.systemUptime)
                RubyLineView(
                    originalText: effectiveOriginalText,
                    kanaText: kana,
                    tokens: inlineRubyTokens,
                    timedLayout: rubyLayout,
                    currentTime: presentationTime,
                    baseFont: baseFont,
                    rubyFont: rubyFont,
                    baseColor: isActive ? coverAccent : .white,
                    rubyColor: .white.opacity(rubyOpacity),
                    rubySpacing: 1,
                    tokenVerticalSpacing: 3,
                    maxWidth: readableLineWidth, highlightColor: coverAccent
                )
                .environment(\.rubyCorrectionAction, isPinyinProjection ? nil : correctRuby)
            }
            .fixedSize(horizontal: false, vertical: true)
        } else {
            RubyLineView(
                originalText: effectiveOriginalText,
                kanaText: kana,
                tokens: inlineRubyTokens,
                timedLayout: rubyLayout,
                currentTime: 0,
                baseFont: baseFont,
                rubyFont: rubyFont,
                baseColor: isActive ? coverAccent : .white,
                rubyColor: .white.opacity(rubyOpacity),
                rubySpacing: 1,
                tokenVerticalSpacing: 3,
                maxWidth: readableLineWidth,
                unplayedOpacity: 1
            )
            .environment(\.rubyCorrectionAction, isPinyinProjection ? nil : correctRuby)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func precomputedTimedMultilineLayout(for line: LyricLine, spans: [TimedTextSpan]) -> TimedMultilineLayout? {
        let fontSize = baseSize
        let weight = V3LyricMotionPolicy.layoutNSWeight
        let width = readableLineWidth
        let key = V3TimedLayoutCache.key(
            kind: "multiline",
            line: line,
            fontSize: fontSize,
            weight: weight,
            availableWidth: width,
            scriptConversion: scriptConversion
        )
        return V3TimedLayoutCache.multiline(for: key) {
            let effectiveSpans = ReadingScriptConverter.convertSpans(
                spans,
                originalText: line.originalText,
                convertedText: effectiveOriginalText,
                using: scriptConversion
            ) ?? spans
            return TimedTextComposer.computeMultilineLayout(
                originalText: effectiveOriginalText,
                spans: effectiveSpans,
                fontSize: fontSize,
                weight: weight,
                design: "rounded",
                availableWidth: width,
                balanced: true
            )
        }
    }

    private func precomputedTimedRubyLayout(for line: LyricLine, spans: [TimedTextSpan]) -> TimedRubyLayout? {
        let fontSize = baseSize
        let weight = V3LyricMotionPolicy.layoutNSWeight
        let rubyTokens = inlineRubyTokens
        let key = V3TimedLayoutCache.key(
            kind: "ruby",
            line: line,
            fontSize: fontSize,
            weight: weight,
            rubyTokens: rubyTokens,
            scriptConversion: scriptConversion
        )
        return V3TimedLayoutCache.ruby(for: key) {
            let effectiveSpans = ReadingScriptConverter.convertSpans(
                spans,
                originalText: line.originalText,
                convertedText: effectiveOriginalText,
                using: scriptConversion
            ) ?? spans
            return rubyPresentation.timedLayout(spans: effectiveSpans, fontSize: fontSize, weight: weight)
        }
    }

    #if DEBUG
    private static var lastDecisionLogTime: TimeInterval = 0
    private static func logRubyDecisionIfNeeded(
        isActive: Bool,
        line: LyricLine,
        shouldRenderInlineRuby: Bool,
        storedKana: String?,
        displayKana: String?,
        rubyTokens: [LyricRubyToken]?,
        layout: TimedRubyLayout?
    ) {
        guard isActive else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastDecisionLogTime >= 0.5 {
            lastDecisionLogTime = now
            let layoutStr = shouldRenderInlineRuby ? (layout != nil ? "ok" : "nil") : "bypassed_shouldRenderInlineRuby_false"
            LyricsE2ELog.log("[V3TimedRubyDecision] text=\(line.originalText) shouldRenderInlineRuby=\(shouldRenderInlineRuby) storedKana=\(storedKana ?? "nil") displayKana=\(displayKana ?? "nil") rubyTokens=\(rubyTokens?.count.description ?? "nil") timedSpans=\(line.timedSpans?.count.description ?? "nil") readingSurfaceText=\(line.readingSurfaceText ?? "nil") timedRubyLayout=\(layoutStr)")
        }
    }

    private static var lastModeLogTime: TimeInterval = 0
    private static func logRowModeIfNeeded(mode: String, width: CGFloat, lineWidth: CGFloat) {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastModeLogTime >= 0.5 {
            lastModeLogTime = now
            LyricsE2ELog.log("[V3TimedRow] mode=\(mode) width=\(String(format: "%.1f", width)) lineWidth=\(String(format: "%.1f", lineWidth))")
        }
    }
    #endif
}

private struct AppleMusicImmersiveV3TimedRowView: View {
    @Environment(\.v3CoverAccent) private var coverAccent
    @Environment(\.lyricTextAlignment) private var textAlignment
    let layout: TimedMultilineLayout
    let currentTime: TimeInterval
    let font: Font
    var showsFill: Bool = true

    var body: some View {
        #if DEBUG
        let firstFrac = layout.lines.first?.fillFraction(at: currentTime) ?? 0
        let _ = Self.logTimedRowIfNeeded(text: layout.originalText, time: currentTime, fraction: firstFrac)
        #endif

        if layout.isSingleLine, let singleLine = layout.lines.first {
            timedVisualLine(singleLine.text, fraction: singleLine.fillFraction(at: currentTime))
        } else {
            VStack(alignment: textAlignment.lyricHorizontalAlignment, spacing: 0) {
                ForEach(layout.lines, id: \.lineIndex) { visualLine in
                    timedVisualLine(visualLine.text, fraction: visualLine.fillFraction(at: currentTime))
                }
            }
        }
    }

    @ViewBuilder
    private func timedVisualLine(_ text: String, fraction: Double) -> some View {
        if showsFill {
            Text(text)
                .font(font)
                .foregroundColor(.white.opacity(0.42))
                .overlay(
                    GeometryReader { geo in
                        Text(text)
                            .font(font)
                            .foregroundColor(coverAccent)
                            .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
                            .mask(alignment: .leading) {
                                Rectangle()
                                    .frame(
                                        width: max(0, geo.size.width * CGFloat(fraction)),
                                        height: geo.size.height
                                    )
                            }
                    }
                )
        } else {
            Text(text)
                .font(font)
                .foregroundColor(.white)
        }
    }

    #if DEBUG
    private static var lastLogTime: TimeInterval = 0
    private static func logTimedRowIfNeeded(text: String, time: TimeInterval, fraction: Double) {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastLogTime >= 0.5 {
            lastLogTime = now
            LyricsE2ELog.log("[V3TimedRow] active=true text=\(text.prefix(16)) time=\(String(format: "%.3f", time)) frac=\(String(format: "%.3f", fraction))")
        }
    }
    #endif
}

private extension Font.Weight {
    var nsWeightValue: CGFloat {
        switch self {
        case .heavy, .black: return 0.56
        case .bold: return 0.4
        case .semibold: return 0.3
        case .medium: return 0.23
        default: return 0.0
        }
    }
}
