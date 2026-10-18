import Foundation
import SwiftUI
import AppKit

private struct V3PreviewPresentationKey: EnvironmentKey {
    static let defaultValue: V3ArtworkPresentation? = nil
}

private struct V3ExplicitInstrumentalMarkKey: EnvironmentKey {
    static let defaultValue = false
}

private extension EnvironmentValues {
    var v3PreviewPresentation: V3ArtworkPresentation? {
        get { self[V3PreviewPresentationKey.self] }
        set { self[V3PreviewPresentationKey.self] = newValue }
    }

    var v3ExplicitInstrumentalMark: Bool {
        get { self[V3ExplicitInstrumentalMarkKey.self] }
        set { self[V3ExplicitInstrumentalMarkKey.self] = newValue }
    }
}

private struct V3PlaybackInteractionKey: EnvironmentKey {
    static let defaultValue: (Bool) -> Void = { _ in }
}

private struct V3PlaybackRegionPreferenceKey: PreferenceKey {
    static let defaultValue: CGRect = .null

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

private struct V3PlaybackRegionAnchorPreferenceKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

private extension View {
    func reportsV3PlaybackRegion() -> some View {
        anchorPreference(
            key: V3PlaybackRegionAnchorPreferenceKey.self,
            value: .bounds
        ) { anchor in
            anchor
        }
    }
}

extension EnvironmentValues {
    var v3PlaybackInteractionChanged: (Bool) -> Void {
        get { self[V3PlaybackInteractionKey.self] }
        set { self[V3PlaybackInteractionKey.self] = newValue }
    }
}

private struct V3PlaybackVisibility: ViewModifier {
    let visible: Bool
    let reduceMotion: Bool
    func body(content: Content) -> some View {
        content.opacity(visible ? 1 : 0)
            .allowsHitTesting(visible)
            .accessibilityHidden(!visible)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: visible)
    }
}

enum MainWindowResponsiveThresholds {
    static let technicalMinimumSize = LyricsDesignTokens.technicalMinimumMainWindowSize
    static let comfortableMinimumSize = LyricsDesignTokens.comfortableMainWindowSize
    // Compatibility aliases for callers and older contracts.
    static let minimumWidth: CGFloat = technicalMinimumSize.width
    static let minimumHeight: CGFloat = technicalMinimumSize.height
    static let wideBreakpoint: CGFloat = 1_080
    static let compactLyricsFocusWidth: CGFloat = 900
    static let compactLyricsFocusHeight: CGFloat = 640
    static let toolbarRevealHeight: CGFloat = 96
}

private final class V3PointerLocationBox {
    var location: CGPoint?
}

/// Independent Apple Music-inspired main canvas. V2 and Lyrics Focus remain
/// separate layouts; this view owns only the V3 canvas and its transient tools.
struct AppleMusicImmersiveV3WindowView: View {
    @ObservedObject var state: PlaybackState
    @ObservedObject var settings: AppSettingsStore
    @Binding var layoutStyleRawValue: String
    var liveOnly: Bool = false
    @Environment(\.lyricPresentationScale) private var presentationScale
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isSearchPresented = false
    @State private var isWindowMenuPresented = false
    @State private var showsAIReadingControls = false
    @State private var hoveredAIReadingControls: Bool?
    private var displaysAIReadingControls: Bool { hoveredAIReadingControls ?? showsAIReadingControls }
    @State private var confirmsAIReadingRequest = false
    @State private var isTranslationComparisonPresented = false
    @State private var isVersionPickerPresented = false
    @State private var hoveredStyle: V3ArtworkPresentation?
    private var compositionStyle: V3ArtworkPresentation { hoveredStyle ?? settings.v3ArtworkPresentation }
    private var compositionArtworkPosition: String { settings.v3PreviewPosition(for: compositionStyle) }
    private var compositionLyricsPosition: String { settings.v3PreviewLyricsPosition(for: compositionStyle) }
    private var compositionArtworkScale: Double { settings.v3PreviewScale(for: compositionStyle) }
    private enum ToolbarPopover: Equatable { case translation, lyricsTime, appearance, display }
    @State private var activeToolbarPopover: ToolbarPopover?
    @State private var hoveredToolbarTrigger: ToolbarPopover?
    @State private var hoveredToolbarPanel: ToolbarPopover?
    @State private var confirmedToolbarPanel: ToolbarPopover?
    @State private var toolbarDismissTask: Task<Void, Never>?
    // Keep listening unobstructed. Tools reveal at the top edge and stay
    // available while their popover is open.
    @State private var toolsVisible = false
    @State private var isPointerInToolbarRegion = false
    @State private var interactionToken = 0
    @State private var isAlignmentDetailsPresented = false
    @State private var isPointerInsideCanvas = false
    @State private var isPointerInsidePlaybackRegion = false
    @State private var pointerLocationBox = V3PointerLocationBox()
    @State private var playbackRegion = CGRect.null
    @State private var isPlaybackInteracting = false
    @State private var lastWindowExitPoint: CGPoint?

    private var playbackDetailsVisible: Bool {
        guard !settings.v3EdgeProgressEnabled else { return false }
        return V3ResponsiveGeometry.playbackDetailsVisible(
            hoverOnly: settings.v3PlaybackDetailsOnHover,
            pointerInRegion: pointerRevealsPlayback,
            interacting: isPlaybackInteracting,
            panelPresented: false
        )
    }

    private var pointerRevealsPlayback: Bool {
        if compositionStyle == .stage {
            return isPointerInsidePlaybackRegion
        }
        guard !playbackRegion.isNull, !playbackRegion.isEmpty else {
            // Compact lyrics-focus has no separate cover/player region, so
            // preserve its established canvas hover behavior.
            return isPointerInsideCanvas && !isPointerInToolbarRegion
        }
        return isPointerInsidePlaybackRegion
    }

    private var playbackVisibility: V3PlaybackVisibility {
        V3PlaybackVisibility(visible: playbackDetailsVisible, reduceMotion: reduceMotion)
    }

    private var expandsHiddenArtwork: Bool {
        settings.v3ExpandArtworkWhenDetailsHidden && !playbackDetailsVisible
    }

    private func immersiveCoverScale(
        size: CGFloat,
        availableWidth: CGFloat,
        availableHeight: CGFloat,
        compact: Bool,
        portrait: Bool = false
    ) -> CGFloat {
        // Every theme with this control uses the same bounded expansion.
        guard compositionStyle != .albumPoster else { return 1 }
        guard expandsHiddenArtwork else { return 1 }
        return V3ResponsiveGeometry.ambientHiddenCoverScale(
            coverSize: size,
            availableWidth: availableWidth,
            availableHeight: availableHeight,
            compact: compact,
            portrait: portrait
        )
    }

    private var showsForegroundArtwork: Bool {
        settings.v3ShowForegroundArtwork
            && compositionStyle != .stage
            && compositionStyle != .lyricsOnly
    }

    /// Stage has no foreground cover, so its size slider is consumed only by
    /// the backdrop. Ambient and Classic keep the complete foreground cover
    /// responsive to the same user control.
    private var foregroundArtworkScale: CGFloat {
        compositionStyle == .stage
            ? 1.0
            : min(1.4, max(0.8, compositionArtworkScale))
    }

    private var usesDocumentComposition: Bool {
        compositionStyle == .lyricsOnly || compositionStyle == .albumPoster
    }

    private var compositionTrack: Track { liveOnly ? state.currentTrack : state.displayedTrack }
    private var isCompositionPreview: Bool { !liveOnly && state.isShowingSearchPreview }

    private var compositionPreviewLabel: some View {
        Label("歌词预览", systemImage: "doc.text.magnifyingglass")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(0.68))
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topTrailing) {
                let isInst = !state.isShowingSearchPreview && state.liveTrackIsMarkedInstrumental
                AppleMusicImmersiveV3BackdropView(
                    track: usesDocumentComposition ? compositionTrack : state.currentTrack,
                    identity: usesDocumentComposition && isCompositionPreview ? nil : state.currentTrackIdentity,
                    isInstrumental: isInst,
                    settings: settings,
                    presentationOverride: hoveredStyle
                )
                // An aspect-fill album image can report the square image's
                // width in a tall window. Keep that drawing overflow inside
                // the canvas so it cannot shift the top-trailing foreground.
                .frame(width: geometry.size.width, height: geometry.size.height)

                layout(for: geometry)

                if settings.v3EdgeProgressEnabled {
                    V3WindowEdgePlaybackOverlay(
                        state: state,
                        colorHex: settings.v3EdgeProgressColorHex,
                        exitPoint: lastWindowExitPoint
                    )
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }

                HStack(spacing: 16) {
                    Spacer(minLength: 0)
                    toolBar(for: geometry.size)
                        .opacity(toolsVisible || toolbarPanelIsPresented ? 1 : 0)
                        .allowsHitTesting(toolsVisible || toolbarPanelIsPresented)
                        .accessibilityHidden(!(toolsVisible || toolbarPanelIsPresented))
                        .animation(
                            LyricsDesignTokens.Motion.animation(reduceMotion: reduceMotion),
                            value: toolsVisible || toolbarPanelIsPresented
                        )
                }
                .padding(.horizontal, 24)
                .padding(.top, 18)

            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let location):
                    pointerLocationBox.location = location
                    if !isPointerInsideCanvas {
                        isPointerInsideCanvas = true
                    }
                    let pointerInRegion: Bool
                    if compositionStyle == .stage {
                        pointerInRegion = V3ResponsiveGeometry.stagePlaybackDetailsVisible(
                            pointerY: location.y,
                            canvasHeight: geometry.size.height,
                            previousVisible: isPointerInsidePlaybackRegion
                        )
                    } else {
                        pointerInRegion = V3ResponsiveGeometry.playbackRevealRect(
                            region: playbackRegion,
                            canvas: CGRect(origin: .zero, size: geometry.size)
                        ).contains(location)
                    }
                    if isPointerInsidePlaybackRegion != pointerInRegion {
                        isPointerInsidePlaybackRegion = pointerInRegion
                    }
                    let inToolbar = location.y <= MainWindowResponsiveThresholds.toolbarRevealHeight
                    if isPointerInToolbarRegion != inToolbar {
                        isPointerInToolbarRegion = inToolbar
                    }
                    if inToolbar || toolbarPanelIsPresented {
                        if !toolsVisible {
                            revealTools()
                        }
                    } else if !toolbarPanelIsPresented {
                        if toolsVisible {
                            toolsVisible = false
                        }
                    }
                case .ended:
                    lastWindowExitPoint = pointerLocationBox.location
                    pointerLocationBox.location = nil
                    if isPointerInsideCanvas {
                        isPointerInsideCanvas = false
                    }
                    if isPointerInsidePlaybackRegion {
                        isPointerInsidePlaybackRegion = false
                    }
                    if isPointerInToolbarRegion {
                        isPointerInToolbarRegion = false
                    }
                    if !toolbarPanelIsPresented && toolsVisible {
                        toolsVisible = false
                    }
                }
            }
            .onChange(of: toolbarPanelIsPresented) { _, presented in
                if !presented && !isPointerInToolbarRegion { toolsVisible = false }
            }
            .task(id: interactionToken) {
                guard interactionToken > 0 else { return }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled, !isPointerInToolbarRegion, !toolbarPanelIsPresented else { return }
                withAnimation(LyricsDesignTokens.Motion.animation(reduceMotion: reduceMotion)) {
                    toolsVisible = false
                }
            }
            .overlayPreferenceValue(V3PlaybackRegionAnchorPreferenceKey.self) { anchor in
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: V3PlaybackRegionPreferenceKey.self,
                        value: anchor.map { proxy[$0] } ?? .null
                    )
                }
            }
            .onPreferenceChange(V3PlaybackRegionPreferenceKey.self) { region in
                playbackRegion = region
                guard compositionStyle != .stage else { return }
                guard let pointerLocation = pointerLocationBox.location else {
                    if isPointerInsidePlaybackRegion {
                        isPointerInsidePlaybackRegion = false
                    }
                    return
                }
                let inRegion = V3ResponsiveGeometry.playbackRevealRect(
                    region: region,
                    canvas: CGRect(origin: .zero, size: geometry.size)
                ).contains(pointerLocation)
                if isPointerInsidePlaybackRegion != inRegion {
                    isPointerInsidePlaybackRegion = inRegion
                }
            }
        }
        .frame(
            minWidth: MainWindowResponsiveThresholds.technicalMinimumSize.width,
            minHeight: MainWindowResponsiveThresholds.technicalMinimumSize.height
        )
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .environment(\.lyricAgentPresentationMap, LyricAgentPresentationMap(lines: liveOnly ? state.liveLyrics : state.lyrics))
        .environment(\.v3PlaybackInteractionChanged, { isPlaybackInteracting = $0 })
        .sheet(isPresented: $isAlignmentDetailsPresented) {
            if let report = state.liveLyricsState.alignmentReport {
                AlignmentPreviewView(report: report)
            }
        }
        .sheet(isPresented: $isTranslationComparisonPresented) {
            V3TranslationComparisonSheet(
                sourceLines: state.originalLiveLyrics,
                versions: state.translationVersions,
                selectedVersionID: state.selectedTranslation?.record.id
            ) { versionID in
                guard !state.isShowingSearchPreview,
                      state.liveLyricsDocumentMatchesCurrentTrack,
                      state.translationVersions.contains(where: { $0.record.id == versionID })
                else { return }
                state.selectTranslation(versionID: versionID)
            }
        }
        // Close the comparison rather than showing a former song's versions.
        .onChange(of: state.currentTrackIdentity) { _, _ in
            isTranslationComparisonPresented = false
        }
        .onChange(of: state.liveLyricsVersionID) { _, _ in
            isTranslationComparisonPresented = false
        }
    }

    @ViewBuilder
    private func layout(for geometry: GeometryProxy) -> some View {
        if compositionStyle == .lyricsOnly {
            lyricsOnlyLayout(in: geometry, hidesArtwork: !settings.v3ShowForegroundArtwork)
        } else if compositionStyle == .stage {
            stageTheaterLayout(in: geometry)
        } else {
            Group {
                if settings.v3ShowForegroundArtwork {
                    foregroundArtworkLayout(in: geometry)
                        .transition(reduceMotion ? .identity : .opacity)
                } else {
                    lyricsOnlyLayout(in: geometry, hidesArtwork: true)
                        .transition(reduceMotion ? .identity : .opacity)
                }
            }
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 0.22),
                value: settings.v3ShowForegroundArtwork
            )
        }
    }

    @ViewBuilder
    private func foregroundArtworkLayout(in geometry: GeometryProxy) -> some View {
        if compositionStyle == .albumPoster {
            if isAutomaticCompactLyricsFocus(in: geometry) {
                lyricsOnlyLayout(in: geometry)
            } else if V3ResponsiveGeometry.foregroundLayout(
                canvasSize: geometry.size, automaticLyricsFocus: false
            ) == .portrait {
                portraitLayout(in: geometry, usesDisplayedTrack: true)
            } else {
                albumPosterLayout(in: geometry)
            }
        } else if isAutomaticCompactLyricsFocus(in: geometry) {
            compactLyricsFocusLayout(in: geometry)
        } else if V3ResponsiveGeometry.foregroundLayout(
            canvasSize: geometry.size, automaticLyricsFocus: false
        ) == .portrait {
            portraitLayout(in: geometry)
        } else if (compositionStyle == .classic || compositionStyle == .classicGaussian) {
            classicExpandedLayout(in: geometry)
        } else {
            switch MainWindowResponsiveMode.resolve(
                width: geometry.size.width,
                height: geometry.size.height,
                automaticLyricsFocus: settings.automaticCompactLyricsFocus,
                wideBreakpoint: MainWindowResponsiveThresholds.wideBreakpoint,
                comfortableSize: MainWindowResponsiveThresholds.comfortableMinimumSize,
                compactFocusWidth: MainWindowResponsiveThresholds.compactLyricsFocusWidth,
                compactFocusHeight: MainWindowResponsiveThresholds.compactLyricsFocusHeight
            ) {
            case .wide, .medium:
                adaptiveSplitLayout(in: geometry)
            case .small:
                // Keep the legacy enum value decodable for saved preview state,
                // but render it through the same bounded split geometry. A second
                // vertical poster composition makes live window resizing jump
                // between unrelated coordinate systems.
                adaptiveSplitLayout(in: geometry)
            case .lyricsFocus:
                compactLyricsFocusLayout(in: geometry)
            }
        }
    }

    // Compatibility helpers retained for the Phase 2.2 contract and for
    // diagnostics that name the automatic projection explicitly. The actual
    // layout selection is centralized in MainWindowResponsiveMode.resolve.
    private func isAutomaticCompactLyricsFocus(in geometry: GeometryProxy) -> Bool {
        MainWindowResponsiveMode.resolve(
            width: geometry.size.width,
            height: geometry.size.height,
            automaticLyricsFocus: settings.automaticCompactLyricsFocus,
            wideBreakpoint: MainWindowResponsiveThresholds.wideBreakpoint,
            comfortableSize: MainWindowResponsiveThresholds.comfortableMinimumSize,
            compactFocusWidth: MainWindowResponsiveThresholds.compactLyricsFocusWidth,
            compactFocusHeight: MainWindowResponsiveThresholds.compactLyricsFocusHeight
        ) == .lyricsFocus
    }

    private func compactLyricsFocus(in geometry: GeometryProxy) -> Bool {
        isAutomaticCompactLyricsFocus(in: geometry)
    }

    private func compactLyricsFocusLayout(in geometry: GeometryProxy) -> some View {
        ZStack(alignment: .topTrailing) {
            lyricsColumn(
                width: max(1, geometry.size.width - 48),
                compact: true,
                lyricsFocus: true,
                onSearch: { isSearchPresented = true }
            )
            .padding(.horizontal, LyricsDesignTokens.Spacing.windowSmall)
            .padding(.top, 76)
            .padding(.bottom, LyricsDesignTokens.Spacing.xl + 22)

            VStack(spacing: 0) {
                Spacer()

                AppleMusicImmersiveV3FocusTransportControls(
                    state: state,
                    reduceMotion: reduceMotion
                )
                .padding(.bottom, LyricsDesignTokens.Spacing.md)
                .modifier(playbackVisibility)
            }
        }
    }

    private func lyricsOnlyLayout(in geometry: GeometryProxy, hidesArtwork: Bool = false) -> some View {
        let compact = isCompact(for: geometry.size)
        let readingWidth = min(940, max(1, geometry.size.width - (compact ? 56 : 112)))
        let headerHeight: CGFloat = hidesArtwork ? (compact ? 48 : 56) : (compact ? 64 : 76)
        let footerHeight: CGFloat = settings.v3EdgeProgressEnabled && !isCompositionPreview ? 0 : 68
        let lyricHeight = max(1, geometry.size.height - 100 - headerHeight - footerHeight - 28)

        return VStack(spacing: 14) {
            HStack(spacing: 14) {
                if !hidesArtwork {
                    ArtworkView(track: compositionTrack, size: compact ? 44 : 52,
                                showsAlbumLabel: false, cornerRadiusRatio: 0.12,
                                preservesCompleteArtwork: true)
                }
                TrackMetadataView(track: compositionTrack, titleSize: compact ? 19 : 22,
                                  presentation: .v3Immersive)
                Spacer(minLength: 0)
            }
            .frame(width: readingWidth, height: headerHeight, alignment: .leading)

            lyricsColumn(width: readingWidth, compact: compact, lyricsFocus: true,
                         onSearch: { isSearchPresented = true })
                .frame(width: readingWidth, height: lyricHeight)

            Group {
                if isCompositionPreview {
                    compositionPreviewLabel
                } else {
                    AppleMusicImmersiveV3FocusTransportControls(state: state, reduceMotion: reduceMotion)
                }
            }
                .frame(width: min(460, readingWidth), height: footerHeight)
                .reportsV3PlaybackRegion()
                .modifier(V3PlaybackVisibility(visible: isCompositionPreview || playbackDetailsVisible, reduceMotion: reduceMotion))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 76)
        .padding(.bottom, 24)
    }

    private func albumPosterLayout(in geometry: GeometryProxy) -> some View {
        let compact = isCompact(for: geometry.size)
        let metrics = V3ResponsiveGeometry.adaptiveSplitMetrics(
            canvasSize: CGSize(width: geometry.size.width, height: max(1, geometry.size.height - 48)),
            artworkScale: foregroundArtworkScale
        )
        let cardInset: CGFloat = compact ? 18 : 26
        let coverSize = min(metrics.coverSize, max(1, metrics.artworkWidth - cardInset * 2))
        let card = VStack(alignment: .leading, spacing: compact ? 18 : 24) {
            HStack {
                ArtworkView(track: compositionTrack, size: coverSize,
                            showsAlbumLabel: false, cornerRadiusRatio: 0.025,
                            preservesCompleteArtwork: true)
                    .shadow(color: .black.opacity(0.24), radius: 14, y: 8)
            }
            .frame(maxWidth: .infinity)

            trackPlaybackDetails(width: max(1, metrics.artworkWidth - cardInset * 2),
                                 titleSize: compact ? 22 : 28, alignment: .leading,
                                 progressDensity: compact ? .small : .medium, usesDisplayedTrack: true)
                .modifier(V3PlaybackVisibility(visible: isCompositionPreview || playbackDetailsVisible, reduceMotion: reduceMotion))
        }
        .padding(cardInset)
        .frame(width: metrics.artworkWidth)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.10), lineWidth: 1))
        .reportsV3PlaybackRegion()
        let reading = lyricsColumn(width: metrics.lyricsWidth, compact: compact)
            .frame(width: metrics.lyricsWidth, height: metrics.availableHeight)

        return HStack(spacing: metrics.gap) {
            if compositionArtworkPosition == "right" {
                reading
                card
            } else {
                card
                reading
            }
        }
        .frame(width: metrics.contentWidth, height: metrics.availableHeight)
        .padding(.horizontal, metrics.horizontalPadding)
        .padding(.top, metrics.verticalPadding + 48)
        .padding(.bottom, metrics.verticalPadding)
    }

    private func portraitLayout(in geometry: GeometryProxy, usesDisplayedTrack: Bool = false) -> some View {
        let metrics = V3ResponsiveGeometry.portraitMetrics(
            canvasSize: geometry.size, artworkScale: foregroundArtworkScale
        )
        let cover = ArtworkView(
            track: usesDisplayedTrack ? compositionTrack : state.currentTrack, size: metrics.coverSize,
            showsAlbumLabel: false, cornerRadiusRatio: 0.06,
            preservesCompleteArtwork: true
        )
        .scaleEffect(
            immersiveCoverScale(
                size: metrics.coverSize,
                availableWidth: metrics.coverColumnWidth,
                availableHeight: metrics.headerHeight - metrics.headerInset * 2,
                compact: false,
                portrait: true
            )
        )
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.32), value: playbackDetailsVisible)
        .frame(width: metrics.coverColumnWidth, height: metrics.headerHeight - metrics.headerInset * 2)
        let details = trackPlaybackDetails(
            width: metrics.metadataWidth, titleSize: 26,
            alignment: .leading, progressDensity: .medium, usesDisplayedTrack: usesDisplayedTrack
        )
        .modifier(V3PlaybackVisibility(visible: (usesDisplayedTrack && isCompositionPreview) || playbackDetailsVisible, reduceMotion: reduceMotion))

        return VStack(spacing: metrics.gap) {
            HStack(spacing: metrics.headerGap) {
                if compositionArtworkPosition == "right" {
                    details
                    cover
                } else {
                    cover
                    details
                }
            }
            .padding(metrics.headerInset)
            .frame(width: metrics.contentWidth, height: metrics.headerHeight)
            .reportsV3PlaybackRegion()
            .background(V3PlaybackSurface().opacity(playbackDetailsVisible ? 1 : 0)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: playbackDetailsVisible))

            lyricsColumn(width: metrics.contentWidth, compact: false)
                .frame(width: metrics.contentWidth, height: metrics.lyricsHeight)
        }
        .padding(.horizontal, metrics.horizontalPadding)
        .padding(.top, metrics.topPadding)
        .padding(.bottom, metrics.bottomPadding)
    }

    private func trackPlaybackDetails(
        width: CGFloat, titleSize: CGFloat, alignment: HorizontalAlignment,
        progressDensity: AppleMusicImmersiveV3ProgressDensity,
        usesDisplayedTrack: Bool = false
    ) -> some View {
        VStack(alignment: alignment, spacing: 10) {
            TrackMetadataView(
                track: usesDisplayedTrack ? compositionTrack : state.currentTrack, titleSize: titleSize,
                alignment: alignment, presentation: .v3Immersive
            )
            if usesDisplayedTrack && isCompositionPreview {
                compositionPreviewLabel
            } else {
                AppleMusicImmersiveV3TransportControls(
                    state: state, alignment: alignment,
                    progressDensity: progressDensity, progressMaxWidth: nil
                )
            }
        }
        .frame(width: width, alignment: alignment == .center ? .center : .leading)
    }

    private func adaptiveSplitLayout(in geometry: GeometryProxy) -> some View {
        let metrics = V3ResponsiveGeometry.adaptiveSplitMetrics(
            canvasSize: CGSize(width: geometry.size.width, height: max(1, geometry.size.height - 44)),
            artworkScale: foregroundArtworkScale
        )
        let regime = V3ResponsiveGeometry.layoutRegime(canvasSize: geometry.size)
        let position = compositionArtworkPosition.isEmpty ? settings.v3ArtworkPosition : compositionArtworkPosition
        let trackAlignment: HorizontalAlignment = position == "center" ? .center : .leading
        let isWide = regime == .wide
        let isCompact = regime == .compact
        let progressDensity: AppleMusicImmersiveV3ProgressDensity = isWide
            ? .wide
            : (isCompact ? .small : .medium)

        let trackCol = Group {
            trackColumn(
                width: metrics.artworkWidth,
                availableHeight: metrics.availableHeight,
                coverSize: metrics.coverSize,
                alignment: trackAlignment,
                compact: isCompact,
                topChromeInset: 44,
                progressDensity: progressDensity
            )
        }
        .frame(width: metrics.artworkWidth)
        .frame(maxHeight: .infinity)

        let lyricsCol = lyricsColumn(width: metrics.lyricsWidth, compact: isCompact)
            .frame(width: metrics.lyricsWidth)
            .frame(maxHeight: .infinity)

        return HStack(spacing: 0) {
            if position == "right" {
                lyricsCol
                Spacer().frame(width: metrics.gap)
                trackCol
            } else {
                trackCol
                Spacer().frame(width: metrics.gap)
                lyricsCol
            }
        }
        .frame(
            width: metrics.contentWidth,
            height: metrics.availableHeight,
            alignment: .center
        )
        .padding(.horizontal, metrics.horizontalPadding)
        .padding(.top, metrics.verticalPadding + 44)
        .padding(.bottom, metrics.verticalPadding)
    }

    @ViewBuilder
    private func classicExpandedLayout(in geometry: GeometryProxy) -> some View {
        switch V3ResponsiveGeometry.layoutRegime(canvasSize: geometry.size) {
        case .compact:
            adaptiveSplitLayout(in: geometry)
        case .regular, .wide:
            classicSplitLayout(
                in: geometry,
                regime: V3ResponsiveGeometry.layoutRegime(canvasSize: geometry.size)
            )
        }
    }

    private func classicCompactLayout(in geometry: GeometryProxy) -> some View {
        let horizontalPadding = LyricsDesignTokens.Spacing.windowSmall
        let availableWidth = max(1, geometry.size.width - horizontalPadding * 2)
        let canvasHeight = max(1, geometry.size.height)
        let coverSize = V3ResponsiveGeometry.boundedCoverSize(
            availableWidth: availableWidth - 20,
            availableHeight: min(200, canvasHeight * 0.32),
            desiredSize: min(availableWidth * 0.42, canvasHeight * 0.28),
            minimum: min(136, availableWidth - 20),
            maximum: 200
        )
        let trackHeight = coverSize + 140

        return ScrollView(.vertical) {
            VStack(spacing: LyricsDesignTokens.Spacing.xs + 2) {
                trackColumn(
                    width: availableWidth,
                    availableHeight: trackHeight,
                    coverSize: coverSize,
                    alignment: .center,
                    compact: true,
                    progressDensity: .small
                )

                lyricsColumn(width: availableWidth, compact: true)
                    .frame(minHeight: max(220, canvasHeight * 0.50))
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.top, LyricsDesignTokens.Spacing.xs + 2)
            .padding(.bottom, LyricsDesignTokens.Spacing.md)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func classicSplitLayout(
        in geometry: GeometryProxy,
        regime: V3ResponsiveGeometry.LayoutRegime
    ) -> some View {
        let horizontalPadding: CGFloat = regime == .wide ? 56 : 32
        let verticalPadding: CGFloat = regime == .wide ? 34 : 28
        let gap: CGFloat = regime == .wide ? 32 : 26
        let contentWidth = max(1, geometry.size.width - horizontalPadding * 2)
        let availableHeight = max(1, geometry.size.height - verticalPadding * 2 - 44)
        let split = V3ResponsiveGeometry.splitColumns(
            containerWidth: contentWidth,
            requestedArtworkRatio: regime == .wide ? 0.40 : 0.38,
            gap: gap,
            minimumArtworkWidth: regime == .wide ? 320 : 260,
            minimumLyricsWidth: regime == .wide ? 480 : 400
        )
        let coverSize = V3ResponsiveGeometry.boundedCoverSize(
            availableWidth: max(1, split.artwork - 28),
            availableHeight: max(1, availableHeight - 280),
            desiredSize: min(split.artwork - 28, availableHeight - 280)
                * (0.70 + (foregroundArtworkScale - 0.8) * 0.5),
            minimum: 1,
            maximum: regime == .wide ? 560 : 460
        )
        let trackCol = trackColumn(
            width: split.artwork,
            availableHeight: availableHeight,
            coverSize: coverSize,
            alignment: .center,
            compact: false,
            topChromeInset: 44,
            progressDensity: regime == .wide ? .wide : .medium
        )
        let lyricsCol = lyricsColumn(width: split.lyrics, compact: false)

        return HStack(spacing: gap) {
            if compositionArtworkPosition == "right" {
                lyricsCol
                    .frame(width: split.lyrics, height: availableHeight)

                trackCol
                    .frame(width: split.artwork, height: availableHeight)
            } else {
                trackCol
                    .frame(width: split.artwork, height: availableHeight)

                lyricsCol
                    .frame(width: split.lyrics, height: availableHeight)
            }
        }
        .frame(width: contentWidth, height: availableHeight)
        .padding(.horizontal, horizontalPadding)
        .padding(.top, verticalPadding + 44)
        .padding(.bottom, verticalPadding)
    }

    private func stageTheaterLayout(in geometry: GeometryProxy) -> some View {
        let canvasWidth = max(1, geometry.size.width)
        let canvasHeight = max(1, geometry.size.height)
        let compact = V3ResponsiveGeometry.layoutRegime(canvasSize: geometry.size) == .compact
        let reading = V3ResponsiveGeometry.stageReadingRect(
            canvasSize: geometry.size,
            artworkAspectRatio: 1,
            position: compositionArtworkPosition,
            lyricPosition: compositionLyricsPosition,
            readingScale: presentationScale
        )
        let hudWidth = max(1, min(960, canvasWidth - (compact ? 40 : 80)))

        return ZStack(alignment: .topLeading) {
            lyricsColumn(width: reading.width, compact: compact, stage: true)
                .shadow(color: .black.opacity(0.55), radius: 5, y: 2)
                .frame(width: reading.width, height: reading.height)
                .position(x: reading.midX, y: reading.midY)
            StageHUDView(state: state, width: hudWidth)
                .modifier(playbackVisibility)
                .frame(width: hudWidth, height: 96)
                .position(x: canvasWidth / 2, y: canvasHeight - 60)
        }
        .frame(width: canvasWidth, height: canvasHeight)
    }

    private func instrumentalPosterLayout(in geometry: GeometryProxy) -> some View {
        let availableHeight = max(1, geometry.size.height - 60)
        let coverSize = V3ResponsiveGeometry.boundedCoverSize(
            availableWidth: geometry.size.width * 0.72,
            availableHeight: availableHeight * 0.62,
            desiredSize: min(geometry.size.width * 0.38, availableHeight * 0.46)
                * min(1.3, foregroundArtworkScale),
            minimum: min(180, geometry.size.width * 0.72)
        )

        return ScrollView(.vertical) {
            VStack(alignment: .center, spacing: 14) {
                ArtworkView(
                    track: state.currentTrack,
                    size: coverSize,
                    showsAlbumLabel: false,
                    cornerRadiusRatio: 0.06,
                    preservesCompleteArtwork: true
                )
                .shadow(color: Color.black.opacity(0.32), radius: 20, x: 0, y: 8)

                VStack(spacing: 4) {
                    Text(state.currentTrack.title)
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    Text(state.currentTrack.artist)
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                }

                AppleMusicImmersiveV3TransportControls(
                    state: state,
                    alignment: .center,
                    progressDensity: .wide,
                    progressMaxWidth: min(400, geometry.size.width * 0.60)
                )
            }
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func smallLayout(in geometry: GeometryProxy) -> some View {
        let horizontalPadding = LyricsDesignTokens.Spacing.windowSmall
        let availableWidth = max(1, geometry.size.width - horizontalPadding * 2)
        let coverSize = V3ResponsiveGeometry.boundedCoverSize(
            availableWidth: availableWidth,
            availableHeight: max(1, geometry.size.height * 0.34),
            desiredSize: min(availableWidth * 0.62, geometry.size.height * 0.34),
            minimum: min(180, availableWidth)
        )

        return ScrollView(.vertical) {
            VStack(alignment: .center, spacing: LyricsDesignTokens.Spacing.lg) {
                trackColumn(
                    width: availableWidth,
                    availableHeight: showsForegroundArtwork ? coverSize + 190 : 210,
                    coverSize: coverSize,
                    alignment: .center,
                    compact: true,
                    progressDensity: .small
                )
                .frame(maxWidth: .infinity)

                lyricsColumn(
                    width: availableWidth,
                    compact: true
                )
                .frame(minHeight: max(420, geometry.size.height * 0.62))
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, LyricsDesignTokens.Spacing.xl + LyricsDesignTokens.Spacing.xxs)
        }
        .scrollIndicators(.hidden)
    }

    private func trackColumn(
        width: CGFloat,
        availableHeight: CGFloat,
        coverSize: CGFloat,
        alignment: HorizontalAlignment,
        compact: Bool,
        topChromeInset: CGFloat = 0,
        progressDensity: AppleMusicImmersiveV3ProgressDensity = .medium
    ) -> some View {
        let visualScale = immersiveCoverScale(
            size: coverSize,
            availableWidth: width,
            availableHeight: max(1, availableHeight - (compact ? 20 : 48)),
            compact: compact
        )
        let alignmentKey = alignment == .center ? "center" : (alignment == .trailing ? "right" : "left")
        let centersHiddenCover = expandsHiddenArtwork
        let verticalOffset = centersHiddenCover ? V3ResponsiveGeometry.hiddenCoverVerticalOffset(
            containerHeight: availableHeight,
            compositionHeight: playbackRegion.isNull ? 0 : playbackRegion.height,
            coverSize: coverSize,
            scale: visualScale,
            compact: compact,
            topChromeInset: topChromeInset
        ) : 0
        return VStack(alignment: alignment, spacing: 0) {
            if showsForegroundArtwork {
                ArtworkView(
                    track: state.currentTrack,
                    size: coverSize,
                    showsAlbumLabel: false,
                    cornerRadiusRatio: 0.06,
                    preservesCompleteArtwork: true
                )
                // Scale the artwork itself, preserving the column's bounds.
                .scaleEffect(visualScale)
                .frame(maxWidth: width, alignment: alignment == .center ? .center : .leading)
                .offset(x: centersHiddenCover ? V3ResponsiveGeometry.ambientHiddenCoverOffset(
                    containerWidth: width,
                    coverSize: coverSize,
                    scale: visualScale,
                    alignment: alignmentKey
                ) : 0, y: verticalOffset)
                .shadow(color: .black.opacity(0.22), radius: compact ? 14 : 24, y: 10)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.32), value: playbackDetailsVisible)

                Spacer().frame(height: compact ? LyricsDesignTokens.Spacing.lg - 2 : LyricsDesignTokens.Spacing.xl)

                trackPlaybackDetails(
                    width: max(1, width - 28),
                    titleSize: min(compact ? 26 : 30, max(compact ? 18 : 22, coverSize * 0.075)),
                    alignment: alignment, progressDensity: progressDensity
                )
                .padding(.horizontal, compact ? 14 : 16)
                .padding(.vertical, compact ? 12 : 14)
                .background(V3PlaybackSurface(cornerRadius: 18))
                .modifier(playbackVisibility)
            } else {
                Spacer(minLength: 0)

                VStack(alignment: alignment, spacing: compact ? 10 : 14) {
                    TrackMetadataView(
                        track: state.currentTrack,
                        titleSize: compact ? 22 : 26,
                        alignment: alignment,
                        presentation: .v3Immersive
                    )

                    AppleMusicImmersiveV3TransportControls(
                        state: state,
                        alignment: alignment,
                        progressDensity: progressDensity,
                        progressMaxWidth: progressDensity == .small
                            ? min(width, LyricsDesignTokens.Progress.smallMaxWidth)
                            : nil
                    )
                }
                .padding(.horizontal, compact ? 14 : 16)
                .padding(.vertical, compact ? 12 : 14)
                .frame(maxWidth: width, alignment: alignment == .center ? .center : .leading)
                .background(V3PlaybackSurface(cornerRadius: 18))
                .modifier(playbackVisibility)
            }
        }
        // Report only the intrinsic cover/player composition. The enclosing
        // fixed-height frame below centers that content in the track column;
        // the empty column margins must not become hover targets.
        .reportsV3PlaybackRegion()
        // Give the column the actual content height. Without an explicit
        // proposal, the two flexible spacers can resolve against the
        // intrinsic height of the lyrics column and push metadata/transport
        // below the window on a 760pt-tall canvas.
        .frame(
            width: width,
            height: max(1, availableHeight),
            alignment: .center
        )
    }

    private func lyricsColumn(
        width: CGFloat,
        compact: Bool,
        lyricsFocus: Bool = false,
        onSearch: (() -> Void)? = nil,
        stage: Bool = false
    ) -> some View {
        AppleMusicImmersiveV3LyricsViewport(
            state: state,
            availableWidth: max(1, width - (compact ? 22 : 34)),
            compact: compact,
            lyricsFocus: lyricsFocus,
            onSearch: liveOnly ? nil : onSearch,
            liveOnly: liveOnly,
            stage: stage
        )
        .environmentObject(settings)
        .environment(\.v3PreviewPresentation, hoveredStyle)
        .environment(\.lyricTextAlignment, compositionLyricsPosition == "center" ? .center : compositionLyricsPosition == "right" ? .trailing : .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func isCompact(for size: CGSize) -> Bool {
        size.width <= MainWindowResponsiveThresholds.comfortableMinimumSize.width
            || size.height <= MainWindowResponsiveThresholds.comfortableMinimumSize.height
    }

    private var allowsModelRequests: Bool {
#if DEBUG
        if DebugAcceptanceDataIsolation.isRequested { return DebugAcceptanceDataIsolation.allowsExplicitTranslation }
#endif
        return true
    }

    private var usesSystemTranslation: Bool {
        settings.aiTranslationConfiguration.engineID == TranslationEngineID.appleSystem.rawValue
    }

    private var allowsTranslationRequests: Bool { usesSystemTranslation || allowsModelRequests }

    private var allowsAutomaticTranslation: Bool {
        if usesSystemTranslation { return true }
#if DEBUG
        if DebugAcceptanceDataIsolation.isRequested && !DebugAcceptanceDataIsolation.isDailyUse { return false }
#endif
        return allowsModelRequests
    }

    private var translationPanel: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 12) {
            Label("AI 与读音", systemImage: "sparkles").font(.headline)
            HStack(spacing: 8) {
                Text("功能").font(.subheadline)
                HStack(spacing: 2) {
                    aiFeatureTab("翻译", reading: false)
                    aiFeatureTab("读音", reading: true)
                }
                .padding(2)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                Spacer()
            }
            TranslationProviderControls(settings: settings)
            Divider()
            if displaysAIReadingControls {
                aiReadingControls
            } else {
            Toggle("新歌词自动翻译", isOn: Binding(
                get: { settings.aiTranslationConfiguration.autoTranslateNewLyrics },
                set: { enabled in
                    var next = settings.aiTranslationConfiguration
                    next.autoTranslateNewLyrics = enabled
                    settings.aiTranslationConfiguration = next
                }
            ))
            .disabled(!allowsAutomaticTranslation || !settings.aiTranslationConfiguration.isConfigured)
            Text("优先复用已保存译文；自动翻译完整后使用，人工稿与锁定版本保留。新候选可手动采用，所有窗口共用。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Toggle("原文", isOn: displayBinding(\.showOriginal))
                Toggle("中文", isOn: displayBinding(\.showTranslation))
                Toggle("读音", isOn: displayBinding(\.showKana))
            }
            Divider()
            if let current = state.selectedTranslation {
                Text("当前译文 · " + current.record.translationSourceTitle)
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !state.translationProgressMessage.isEmpty {
                Text(state.translationProgressMessage).font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !state.translationState.userFacingMessage.isEmpty {
                Text(state.translationState.userFacingMessage).font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(state.selectedTranslation != nil ? "正在显示已采用译文" : "尚未采用译文")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if case .loading = state.translationState {
                HStack { ProgressView().controlSize(.small)
                    Button("取消") { state.cancelTranslation() } }
            } else {
                HStack {
                    Button("翻译整首") { state.translateCurrentLyrics() }
                    Button("重新翻译") { state.retranslateCurrentLyrics() }
                }
                .disabled(!allowsTranslationRequests || !settings.aiTranslationConfiguration.isConfigured || state.liveLyrics.isEmpty)
            }
            if !allowsTranslationRequests {
                Text("没有剩余模型请求预算；苹果系统翻译及已保存版本仍可使用。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let candidate = state.translationSessionPendingCandidate {
                HStack {
                    Text("新候选已保存，待采用").font(.caption)
                    Spacer()
                    Button("采用") { state.adoptTranslation(versionID: candidate.record.id) }
                }
            }
            Menu("已保存的译文") {
                Button("无译文") { state.selectNoTranslationVersion() }
                ForEach(state.translationVersions, id: \.record.id) { version in
                    Button((version.record.id == state.selectedTranslation?.record.id ? "✓ " : "")
                           + version.record.translationSourceTitle + " · "
                           + version.record.createdAt.formatted(date: .numeric, time: .shortened)) {
                        state.selectTranslation(versionID: version.record.id)
                    }
                }
                Button("恢复推荐") { state.restoreRecommendedTranslation() }
            }
            Button {
                isTranslationComparisonPresented = true
            } label: {
                Label("并排对比已保存译文", systemImage: "rectangle.split.3x1")
            }
            .disabled(state.translationVersions.count < 2 || state.originalLiveLyrics.isEmpty)
            .help("仅查看当前歌词的不同译文；采用时才改变当前显示，不调用翻译 AI")
            }
        }
        .toggleStyle(.switch)
        .padding(18)
        }
        .frame(width: 380)
        .frame(maxHeight: 620)
        .confirmationDialog("优化当前歌曲读音？", isPresented: $confirmsAIReadingRequest, titleVisibility: .visible) {
            Button("生成候选（可能收费）") {
                guard aiReadingRequestDisabledReason == nil else { return }
                state.requestAIReadingCandidate()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("使用所选模型「\(settings.aiTranslationConfiguration.model)」优化当前歌词的不确定读音。此处生成的候选可手动采用。")
        }
        .onChange(of: state.liveLyricsVersionID) { _, _ in confirmsAIReadingRequest = false }
        .onChange(of: state.liveTrackIdentity) { _, _ in confirmsAIReadingRequest = false }
    }

    private func aiFeatureTab(_ title: String, reading: Bool) -> some View {
        Button {
            showsAIReadingControls = reading
            hoveredAIReadingControls = nil
            confirmToolbarPopover(.translation)
        } label: {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(displaysAIReadingControls == reading ? Color.white : Color.primary)
                .frame(width: 48, height: 24)
                .background(displaysAIReadingControls == reading ? Color.accentColor : .clear,
                            in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { hoveredAIReadingControls = reading }
            else if hoveredAIReadingControls == reading { hoveredAIReadingControls = nil }
        }
        .accessibilityAddTraits(showsAIReadingControls == reading ? .isSelected : [])
    }

    private var aiReadingControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("本地自动生成读音", isOn: Binding(
                get: { settings.readingPreferences.automaticGeneration },
                set: { enabled in
                    var next = settings.readingPreferences
                    next.automaticGeneration = enabled
                    settings.readingPreferences = next
                }
            ))
            Text("本地生成不调用 AI。可在设置 → 读音调整自动生成与人工词典。")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("使用 AI 优化读音", isOn: Binding(
                get: { settings.readingPreferences.aiAssistedCandidate },
                set: { enabled in
                    var next = settings.readingPreferences
                    next.aiAssistedCandidate = enabled
                    settings.readingPreferences = next
                }
            ))
            Text("关闭恢复本地读音；人工修改、锁定读音和已保存版本保留。")
                .font(.caption).foregroundStyle(.secondary)
            if settings.readingPreferences.aiAssistedCandidate {
                Toggle("新歌词自动优化", isOn: readingBinding(\.automaticAIOptimization))
                    .disabled(!allowsAutomaticTranslation || !settings.aiTranslationConfiguration.isConfigured
                        || !AIReadingCandidateService.supports(engineID: settings.aiTranslationConfiguration.engineID))
                Text("新歌词就绪后自动优化并使用；优先复用已保存的 AI 读音，保留人工修改和锁定读音。仅处理不确定读音，可能产生模型费用。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("本地生成") { state.generateCurrentReading() }
                    .disabled(!canGenerateReadingHere || state.isReadingGenerating)
                Button("AI 优化当前歌词…", systemImage: "sparkles") { confirmsAIReadingRequest = true }
                    .disabled(aiReadingRequestDisabledReason != nil)
            }
            if let reason = aiReadingRequestDisabledReason {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
            if state.isReadingGenerating {
                ProgressView("正在生成读音…").controlSize(.small)
            } else if !state.readingMessage.isEmpty {
                Text(state.readingMessage).font(.caption).foregroundStyle(.secondary)
            }
            Menu("已保存的读音") {
                ForEach(state.readingVersions.filter { !$0.record.isArchived }, id: \.record.id) { version in
                    let name = ReadingRepresentationID(rawValue: version.record.representationID)?.displayName ?? "读音"
                    let isAI = version.record.warningMetadata.contains(.aiCandidateOnly)
                    let kind = version.record.isManuallyEdited ? "人工" : (isAI ? "AI 候选" : "本地")
                    Button((state.selectedReadingVersion?.record.id == version.record.id ? "✓ " : "") + name + " · " + kind) {
                        state.selectReadingVersion(versionID: version.record.id)
                    }
                    .disabled(isAI && !settings.readingPreferences.aiAssistedCandidate)
                }
            }
            .disabled(state.readingVersions.isEmpty)
        }
    }

    private var canGenerateReadingHere: Bool {
        state.hasLiveTrack && !state.isMockPreviewMode && !state.isShowingSearchPreview
            && state.liveLyricsDocumentMatchesCurrentTrack && state.readingSession.hasSource
    }

    private var aiReadingRequestDisabledReason: String? {
        guard settings.readingPreferences.aiAssistedCandidate else { return "开启 AI 优化后，可明确生成候选。" }
        guard canGenerateReadingHere else { return "载入当前播放歌曲的已保存歌词后可生成。" }
        guard AIReadingCandidateService.supports(engineID: settings.aiTranslationConfiguration.engineID) else {
            return "请选择兼容 API、GPT / ChatGPT 或 Gemini CLI 来优化读音。"
        }
        guard settings.aiTranslationConfiguration.isConfigured else { return "请先在设置中配置所选引擎与模型。" }
        guard LyricsLanguageGate.allowsJapaneseReadings(language: state.liveLyricsLanguage, text: state.liveLyrics.map(\.originalText).joined(separator: "\n")) else {
            return "AI 优化仅处理日语不确定读音，请先确认歌词语言。"
        }
        if state.isReadingGenerating { return "请等待当前读音生成完成。" }
        if !allowsModelRequests { return "当前没有新请求预算；可继续使用本地读音。" }
        return nil
    }

    private var toolbarPanelIsPresented: Bool {
        isWindowMenuPresented || isSearchPresented || isVersionPickerPresented || activeToolbarPopover != nil
    }

    private func presentToolbarPopover(_ panel: ToolbarPopover) {
        toolbarDismissTask?.cancel()
        guard activeToolbarPopover != panel else { return }
        confirmedToolbarPanel = nil
        hoveredToolbarPanel = nil
        isWindowMenuPresented = false
        isSearchPresented = false
        if panel != .appearance { hoveredStyle = nil }
        activeToolbarPopover = panel
    }

    private func confirmToolbarPopover(_ panel: ToolbarPopover) {
        // A click confirms the hover-opened panel. Repeated clicks remain
        // idempotent instead of turning confirmation into a close action.
        presentToolbarPopover(panel)
        confirmedToolbarPanel = panel
    }

    private func toolbarTriggerHover(_ panel: ToolbarPopover, inside: Bool) {
        if inside {
            hoveredToolbarTrigger = panel
            presentToolbarPopover(panel)
        } else {
            if hoveredToolbarTrigger == panel { hoveredToolbarTrigger = nil }
            scheduleToolbarDismissal(panel)
        }
    }

    private func scheduleToolbarDismissal(_ panel: ToolbarPopover) {
        toolbarDismissTask?.cancel()
        toolbarDismissTask = Task { @MainActor in
            // Allow the pointer to cross the small popover arrow/gap.
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, activeToolbarPopover == panel,
                  hoveredToolbarTrigger != panel, hoveredToolbarPanel != panel,
                  confirmedToolbarPanel != panel else { return }
            hoveredStyle = nil
            activeToolbarPopover = nil
        }
    }

    private func hoverTrackedPanel<Content: View>(_ panel: ToolbarPopover, @ViewBuilder content: () -> Content) -> some View {
        content()
            .buttonStyle(.automatic)
            .onHover { inside in
                if inside {
                    hoveredToolbarPanel = panel
                    toolbarDismissTask?.cancel()
                } else {
                    if hoveredToolbarPanel == panel { hoveredToolbarPanel = nil }
                    scheduleToolbarDismissal(panel)
                }
            }
            .simultaneousGesture(TapGesture().onEnded {
                if activeToolbarPopover == panel { confirmedToolbarPanel = panel }
            })
            .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
                // Clicking a native menu is an explicit interaction; keep its
                // parent available while the pointer moves into that menu.
                if activeToolbarPopover == panel { confirmedToolbarPanel = panel }
            }
    }

    private func toolbarPopoverBinding(_ panel: ToolbarPopover) -> Binding<Bool> {
        Binding(get: { activeToolbarPopover == panel }, set: { presented in
            if presented { presentToolbarPopover(panel) }
            else if activeToolbarPopover == panel { activeToolbarPopover = nil }
        })
    }

    private func toolBar(for size: CGSize) -> some View {
        HStack(spacing: 4) {
            Button { activeToolbarPopover = nil; isWindowMenuPresented.toggle() } label: {
                iconLabel("macwindow", description: "窗口模式")
            }
            .help("窗口模式")
            .popover(isPresented: $isWindowMenuPresented, arrowEdge: .top) {
                windowModePanel
            }
            searchButton
            Rectangle()
                .fill(.white.opacity(0.18))
                .frame(width: 1, height: 18)
                .padding(.horizontal, 3)
                .accessibilityHidden(true)
            Button {
                if liveOnly { MenuBarLyricsController.shared.openLibrary() }
                else { openWindow(id: "personal-library-activity") }
            } label: {
                iconLabel("books.vertical", description: "歌词库")
            }
            .help("歌词库")
            if liveOnly || !state.isShowingSearchPreview {
                CurrentSongOperationsView(state: state, versionShortcutOnly: true, iconOnly: true,
                    onVersionPickerPresentationChange: { presented in
                        isVersionPickerPresented = presented
                        if presented { activeToolbarPopover = nil }
                    },
                    onOpenEditor: liveOnly ? { MenuBarLyricsController.shared.openEditor() } : nil)
                    .environmentObject(settings)
                    .help("歌词版本")
            }
            if liveOnly || !state.isShowingSearchPreview {
                Button { confirmToolbarPopover(.translation) } label: {
                    iconLabel("sparkles", description: "AI 翻译与读音")
                }
                .keyboardShortcut("t", modifiers: [.command, .option])
                .accessibilityIdentifier("translation.shortcut")
                .help("AI 翻译与读音")
                .onHover { inside in toolbarTriggerHover(.translation, inside: inside) }
                .v3ToolPopover(isPresented: toolbarPopoverBinding(.translation), onAnchorPress: { confirmToolbarPopover(.translation) }) {
                    hoverTrackedPanel(.translation) { translationPanel }
                }
            }
            Button { confirmToolbarPopover(.lyricsTime) } label: {
                iconLabel("clock.arrow.2.circlepath", description: lyricsTimeToolbarLabel)
            }
            .accessibilityIdentifier("lyrics.time")
            .help("歌词时间")
            .onHover { inside in toolbarTriggerHover(.lyricsTime, inside: inside) }
            .v3ToolPopover(isPresented: toolbarPopoverBinding(.lyricsTime), onAnchorPress: { confirmToolbarPopover(.lyricsTime) }) {
                hoverTrackedPanel(.lyricsTime) { V3LyricsTimePopover(settings: settings) }
            }
            Button { confirmToolbarPopover(.appearance) } label: {
                iconLabel("slider.horizontal.3", description: "外观")
            }
            .accessibilityIdentifier("appearance.shortcut")
            .help("外观背景")
            .onHover { inside in toolbarTriggerHover(.appearance, inside: inside) }
            .v3ToolPopover(isPresented: toolbarPopoverBinding(.appearance), onAnchorPress: { confirmToolbarPopover(.appearance) }) {
                hoverTrackedPanel(.appearance) {
                    V3VisualTuningPopoverView(settings: settings, layoutStyleRawValue: $layoutStyleRawValue, preview: $hoveredStyle) {
                        activeToolbarPopover = nil
                    }
                }
            }
            Button { confirmToolbarPopover(.display) } label: {
                iconLabel("character.bubble", description: "歌词显示")
            }
            .help("歌词显示")
            .onHover { inside in toolbarTriggerHover(.display, inside: inside) }
            .v3ToolPopover(isPresented: toolbarPopoverBinding(.display), onAnchorPress: { confirmToolbarPopover(.display) }) {
                hoverTrackedPanel(.display) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("歌词显示").font(.headline)
                        Toggle("显示假名", isOn: displayBinding(\.showKana))
                        Toggle("显示罗马音", isOn: displayBinding(\.showRomaji))
                        Toggle("显示拼音", isOn: displayBinding(\.showPinyin))
                        Toggle("显示翻译", isOn: displayBinding(\.showTranslation))
                        if settings.displayPreferences.showKana || settings.displayPreferences.showPinyin {
                            Picker("注音排版", selection: displayBinding(\.kanaDisplayMode)) {
                                Text("汉字上方注音").tag(KanaDisplayMode.inlineRuby)
                                Text("独立注音行").tag(KanaDisplayMode.independentLine)
                                Text("注音替换").tag(KanaDisplayMode.kanaReplacement)
                            }
                        }
                        Divider()
                        Picker("繁简转换", selection: readingBinding(\.scriptConversionID)) {
                            Text("不转换").tag(ScriptConversionID.none.rawValue)
                            Text("繁体转简体").tag(ScriptConversionID.traditionalToSimplified.rawValue)
                            Text("简体转繁体").tag(ScriptConversionID.simplifiedToTraditional.rawValue)
                        }
                    }
                    .padding(18)
                    .frame(width: 300)
                }
            }
            if liveOnly {
                Button { MenuBarLyricsController.shared.openSettings() } label: {
                    iconLabel("gearshape", description: "设置")
                }
                .help("设置")
            } else {
                SettingsLink { iconLabel("gearshape", description: "设置") }
                    .help("设置")
            }

        }
        .buttonStyle(QuietToolbarButtonStyle())
        .padding(5)
        .background(.regularMaterial.opacity(0.78), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 0.7))
        .shadow(color: Color.black.opacity(0.12), radius: 12, x: 0, y: 4)
        .onChange(of: activeToolbarPopover) { _, panel in
            if panel != .appearance { hoveredStyle = nil }
            if panel != .translation { hoveredAIReadingControls = nil }
            if panel == nil {
                toolbarDismissTask?.cancel()
                hoveredToolbarTrigger = nil
                hoveredToolbarPanel = nil
                confirmedToolbarPanel = nil
            }
        }
        .onDisappear { toolbarDismissTask?.cancel(); hoveredStyle = nil }

    }

    private func displayBinding<Value>(_ keyPath: WritableKeyPath<DisplayPreferences, Value>) -> Binding<Value> {
        Binding(get: { settings.displayPreferences[keyPath: keyPath] }, set: { value in
            var next = settings.displayPreferences
            next[keyPath: keyPath] = value
            settings.displayPreferences = next
        })
    }

    private func readingBinding<Value>(_ keyPath: WritableKeyPath<ReadingPreferences, Value>) -> Binding<Value> {
        Binding(get: { settings.readingPreferences[keyPath: keyPath] }, set: { value in
            var next = settings.readingPreferences
            next[keyPath: keyPath] = value
            settings.readingPreferences = next
        })
    }

    private var lyricsTimeToolbarLabel: String {
        "歌词时间"
    }

    private var windowModePanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("窗口模式")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            toolbarAction("主窗口", symbol: "macwindow") {
                state.currentMode = .mainWindow
                if liveOnly { WindowManager.shared.exitFullScreenToMainWindow() }
                isWindowMenuPresented = false
            }
            if !liveOnly {
                toolbarAction("桌面歌词", symbol: "rectangle.on.rectangle") {
                    WindowManager.shared.toggleFloatingLyrics(state: state)
                    isWindowMenuPresented = false
                }
                toolbarAction("顶部胶囊", symbol: "capsule") {
                    WindowManager.shared.toggleCapsule(state: state)
                    isWindowMenuPresented = false
                }
                Toggle(isOn: $settings.menuBarLyricsEnabled) {
                    Label("菜单栏歌词", systemImage: "menubar.rectangle")
                        .font(.system(size: 13, weight: .medium))
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .padding(10)
                .accessibilityIdentifier("menubar.lyrics.toggle")
                .help("直接开启或关闭菜单栏歌词；播放面板仍可从菜单栏图标打开。")
            }
            toolbarAction(liveOnly ? "退出全屏" : "全屏歌词", symbol: "arrow.up.left.and.arrow.down.right") {
                WindowManager.shared.toggleFullScreen(state: state, settings: settings)
                isWindowMenuPresented = false
            }
            if !liveOnly {
                Divider().padding(.vertical, 4)
                Text("桌面歌词交互")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                ForEach(FloatingLyricsInteractionMode.allCases, id: \.rawValue) { mode in
                    toolbarAction(mode.title, symbol: settings.floatingWindowInteractionMode == mode ? "checkmark.circle.fill" : "circle") {
                        WindowManager.shared.setFloatingInteractionMode(mode, state: state)
                    }
                    .help(mode.detail)
                    .accessibilityAddTraits(settings.floatingWindowInteractionMode == mode ? .isSelected : [])
                }
            }
        }
        .padding(8)
        .frame(width: 244)
    }

    private func toolbarAction(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .buttonStyle(QuietToolbarButtonStyle())
    }

    @ViewBuilder private var searchButton: some View {
        if !liveOnly {
            Button { activeToolbarPopover = nil; isSearchPresented.toggle() } label: {
                iconLabel("magnifyingglass", description: "搜索")
            }
            .help("搜索")
            .popover(isPresented: $isSearchPresented, arrowEdge: .top) {
                SongSearchPopover(manager: state.songSearchManager, playbackState: state)
            }
        }
    }

    private var preferencesButton: some View {
        SettingsLink { iconLabel("gearshape", description: "显示设置") }
            .buttonStyle(.plain)
            .accessibilityLabel("显示设置")
    }

    private func iconLabel(_ systemImage: String, description: String) -> some View {
        Image(systemName: systemImage)
            .foregroundStyle(.white.opacity(0.92))
            .font(.system(size: 15, weight: .medium))
            .frame(width: 36, height: 36)
            .contentShape(Rectangle())
            .accessibilityLabel(description)
    }

    private func revealTools() {
        if !toolsVisible {
            withAnimation(LyricsDesignTokens.Motion.animation(reduceMotion: reduceMotion)) {
                toolsVisible = true
            }
        }
        interactionToken &+= 1
    }
}

/// Unlike a transient system popover, an application-defined popover does
/// not swallow the first click on its own toolbar anchor. Hover lifetime is
/// owned by the existing hover state; outside clicks and Escape still dismiss.
private extension View {
    func v3ToolPopover<Content: View>(isPresented: Binding<Bool>, onAnchorPress: @escaping () -> Void, @ViewBuilder content: () -> Content) -> some View {
        background(
            V3ToolPopoverAnchor(
                isPresented: isPresented,
                onAnchorPress: onAnchorPress,
                content: content()
                    .preferredColorScheme(.dark)
                    .environment(\.colorScheme, .dark)
            )
        )
    }
}

private final class V3ToolAnchorView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct V3ToolPopoverAnchor<Content: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    let onAnchorPress: () -> Void
    let content: Content

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeNSView(context: Context) -> V3ToolAnchorView { V3ToolAnchorView() }

    func updateNSView(_ anchor: V3ToolAnchorView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.anchor = anchor
        guard isPresented, anchor.window != nil else {
            coordinator.close()
            return
        }
        if let hosting = coordinator.hosting {
            hosting.rootView = content
            hosting.view.appearance = coordinator.popover.appearance
        } else {
            let hosting = NSHostingController(rootView: content)
            hosting.sizingOptions = []
            hosting.view.appearance = coordinator.popover.appearance
            coordinator.hosting = hosting
            coordinator.popover.contentViewController = hosting
        }
        let height = min(700, max(260, (anchor.window?.screen?.visibleFrame.height ?? 800) - 100))
        if let size = coordinator.hosting?.sizeThatFits(in: CGSize(width: 420, height: height)) {
            let rounded = CGSize(width: ceil(size.width), height: ceil(size.height))
            if coordinator.popover.contentSize != rounded { coordinator.popover.contentSize = rounded }
        }
        if !coordinator.popover.isShown {
            coordinator.popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
            coordinator.startMonitoring()
        }
    }

    static func dismantleNSView(_ nsView: V3ToolAnchorView, coordinator: Coordinator) {
        coordinator.close()
    }

    final class Coordinator: NSObject, NSPopoverDelegate {
        var parent: V3ToolPopoverAnchor
        weak var anchor: NSView?
        let popover = NSPopover()
        var hosting: NSHostingController<Content>?
        private var localMonitor: Any?
        private var observers: [NSObjectProtocol] = []
        private var trackingMenus = 0

        init(parent: V3ToolPopoverAnchor) {
            self.parent = parent
            super.init()
            popover.behavior = .applicationDefined
            popover.animates = false
            popover.appearance = NSAppearance(named: .darkAqua)
            popover.delegate = self
        }

        func startMonitoring() {
            guard localMonitor == nil else { return }
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
                guard let self else { return event }
                return self.handle(event)
            }
            let center = NotificationCenter.default
            observers = [
                center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                    self?.trackingMenus += 1
                },
                center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                    guard let self else { return }
                    self.trackingMenus = max(0, self.trackingMenus - 1)
                },
                center.addObserver(forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main) { [weak self] _ in
                    self?.dismiss()
                }
            ]
        }

        func handle(_ event: NSEvent) -> NSEvent? {
            guard trackingMenus == 0 else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { dismiss(); return nil }
                return event
            }
            // Let the anchor receive its FIRST click and confirm the panel.
            // A content click (including its native menus) stays in place too.
            if let anchor, event.window === anchor.window,
               anchor.bounds.contains(anchor.convert(event.locationInWindow, from: nil)) {
                if event.type == .leftMouseDown { parent.onAnchorPress() }
                return event
            }
            if let contentView = popover.contentViewController?.view,
               event.window === contentView.window { return event }
            dismiss()
            return event
        }

        private func dismiss() {
            if parent.isPresented { parent.isPresented = false }
            close()
        }

        func close() {
            stopMonitoring()
            popover.performClose(nil)
        }

        func popoverDidClose(_ notification: Notification) { stopMonitoring() }

        private func stopMonitoring() {
            if let localMonitor { NSEvent.removeMonitor(localMonitor) }
            localMonitor = nil
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            trackingMenus = 0
        }
    }
}

private struct QuietToolbarButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.60 : hovering ? 1 : 0.86)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onHover { hovering = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hovering)
    }
}

private enum AppleMusicImmersiveV3ProgressDensity: Equatable {
    case wide
    case medium
    case small
    case focus

    var containerHeight: CGFloat {
        switch self {
        case .wide: return 24
        case .medium: return 22
        case .small: return 20
        case .focus: return 20
        }
    }

    /// The visible rail stays thin; this is the stable pointer and keyboard
    /// target used while the window is being resized or the pointer is near
    /// the controls. Keeping the hit target independent from rail thickness
    /// prevents tiny controls from changing the surrounding composition.
    var interactionHeight: CGFloat { containerHeight }

    var trackHeight: CGFloat {
        switch self {
        case .wide, .medium: return LyricsDesignTokens.Progress.trackHeight
        case .small, .focus: return LyricsDesignTokens.Progress.compactTrackHeight
        }
    }

    var isFocus: Bool { self == .focus }
}

/// A restrained playback rail shared by every V3 size projection. It owns no
/// clock and only sends an explicit seek after the user finishes editing.
private struct AppleMusicImmersiveV3PlaybackProgress: View {
    @ObservedObject var state: PlaybackState
    let density: AppleMusicImmersiveV3ProgressDensity
    let maxWidth: CGFloat?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Environment(\.v3PlaybackInteractionChanged) private var interactionChanged

    @State private var isHovered = false
    @State private var isEditing = false
    @State private var draftPosition: Double?

    private var duration: Double {
        max(0.1, state.currentTrack.duration)
    }

    private var playbackPosition: Double {
        let rawValue = draftPosition ?? state.presentationClock.playbackTime(
            at: ProcessInfo.processInfo.systemUptime
        )
        return min(max(rawValue, 0), duration)
    }

    private var progressFraction: Double {
        min(max(playbackPosition / duration, 0), 1)
    }

    private var isEmphasized: Bool { isHovered || isEditing }

    private var progressActiveGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color.white.opacity(isEmphasized ? 0.96 : 0.86),
                Color.white.opacity(isEmphasized ? 0.82 : 0.68)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    var body: some View {
        TimelineView(.animation(
            minimumInterval: 1.0 / 30.0,
            paused: !state.isPlaying || isEditing || reduceMotion
        )) { _ in
            progressRail
        }
    }

    private var progressRail: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width)
            let trackHeight = isEmphasized
                ? LyricsDesignTokens.Progress.hoverTrackHeight
                : density.trackHeight
            let activeWidth = max(0, width * progressFraction)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(
                        isEmphasized
                            ? LyricsDesignTokens.Progress.hoverInactiveOpacity
                            : LyricsDesignTokens.Progress.inactiveOpacity
                    ))
                    .frame(height: trackHeight)

                Capsule()
                    .fill(progressActiveGradient)
                    .frame(width: activeWidth, height: trackHeight)

                if isEmphasized {
                    Circle()
                        .fill(.white)
                        .frame(
                            width: LyricsDesignTokens.Progress.hoverThumbSize,
                            height: LyricsDesignTokens.Progress.hoverThumbSize
                        )
                        .offset(x: min(
                            max(activeWidth - LyricsDesignTokens.Progress.hoverThumbSize / 2, 0),
                            max(0, width - LyricsDesignTokens.Progress.hoverThumbSize)
                        ))
                }

                // The native control remains the accessibility and input
                // surface; the custom rail above keeps the resting visual
                // quiet without introducing a second seek implementation.
                V3PlaybackInputSlider(
                    value: Binding(
                        get: { playbackPosition },
                        set: { draftPosition = min(max($0, 0), duration) }
                    ),
                    duration: duration,
                    onEditingChanged: handleEditingChanged
                )
                .frame(height: density.interactionHeight)
            }
            .contentShape(Rectangle())
            .onHover { hovering in
                withAnimation(LyricsDesignTokens.Motion.animation(reduceMotion: reduceMotion, duration: 0.14)) {
                    isHovered = hovering
                }
            }
        }
        .frame(
            width: density.isFocus ? LyricsDesignTokens.Progress.focusWidth : nil,
            height: density.interactionHeight
        )
        .frame(maxWidth: density.isFocus ? nil : (maxWidth ?? .infinity))
        .animation(
            LyricsDesignTokens.Motion.animation(reduceMotion: reduceMotion, duration: 0.14),
            value: isEmphasized
        )
    }

    private func handleEditingChanged(_ editing: Bool) {
        isEditing = editing
        interactionChanged(editing)
        // A native Slider may write its binding before beginning tracking.
        // Preserve that target rather than replacing it with the live clock.
        guard !editing, let draftPosition else { return }
        self.draftPosition = nil
        state.seek(to: min(max(draftPosition, 0), duration), source: "v3-progress-slider")
    }
}

/// Keep the native accessibility/keyboard control fully hit-testable. A
/// translucent SwiftUI Slider can let its hosting window claim the drag.
private struct V3PlaybackInputSlider: NSViewRepresentable {
    @Binding var value: Double
    let duration: Double
    let onEditingChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> V3PlaybackNativeSlider {
        let slider = V3PlaybackNativeSlider()
        slider.cell = V3PlaybackSliderCell()
        slider.minValue = 0
        slider.maxValue = duration
        slider.isContinuous = true
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.changed(_:))
        slider.setAccessibilityLabel("播放进度")
        slider.onTrackingChanged = { [weak coordinator = context.coordinator] editing in
            coordinator?.parent.onEditingChanged(editing)
        }
        return slider
    }

    func updateNSView(_ slider: V3PlaybackNativeSlider, context: Context) {
        context.coordinator.parent = self
        slider.maxValue = duration
        if !slider.isTrackingInteraction { slider.doubleValue = value }
    }

    final class Coordinator: NSObject {
        var parent: V3PlaybackInputSlider
        init(parent: V3PlaybackInputSlider) { self.parent = parent }

        @objc func changed(_ sender: V3PlaybackNativeSlider) {
            // Keyboard and accessibility changes need the same single commit
            // as pointer tracking, even when AppKit skips mouseDown entirely.
            let standalone = !sender.isTrackingInteraction
            if standalone { parent.onEditingChanged(true) }
            parent.value = sender.doubleValue
            if standalone { parent.onEditingChanged(false) }
        }
    }
}

private final class V3PlaybackNativeSlider: NSSlider {
    var onTrackingChanged: ((Bool) -> Void)?
    private(set) var isTrackingInteraction = false

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        isTrackingInteraction = true
        onTrackingChanged?(true)
        defer {
            isTrackingInteraction = false
            onTrackingChanged?(false)
        }
        applyPointerPosition(event)
        // AppKit's cell tracker can miss a sparse final jump. Apply mouseUp
        // too, so the committed draft always reflects where tracking ended.
        while let next = window?.nextEvent(
            matching: [.leftMouseDragged, .leftMouseUp],
            until: .distantFuture, inMode: .eventTracking, dequeue: true
        ) {
            applyPointerPosition(next)
            if next.type == .leftMouseUp { break }
        }
    }

    private func applyPointerPosition(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        doubleValue = Self.pointerPosition(x: point.x, width: bounds.width, duration: maxValue)
        _ = sendAction(action, to: target)
    }

    static func pointerPosition(x: CGFloat, width: CGFloat, duration: Double) -> Double {
        guard x.isFinite, width.isFinite, width > 0,
              duration.isFinite, duration > 0 else { return 0 }
        return min(1, max(0, Double(x / width))) * duration
    }
}

private final class V3PlaybackSliderCell: NSSliderCell {
    override func drawBar(inside rect: NSRect, flipped: Bool) {}
    override func drawKnob(_ knobRect: NSRect) {}
}

private struct AppleMusicImmersiveV3TransportControls: View {
    @ObservedObject var state: PlaybackState
    let alignment: HorizontalAlignment
    let progressDensity: AppleMusicImmersiveV3ProgressDensity
    let progressMaxWidth: CGFloat?

    var body: some View {
        VStack(alignment: alignment, spacing: 5) {
            AppleMusicImmersiveV3PlaybackProgress(
                state: state,
                density: progressDensity,
                maxWidth: progressMaxWidth
            )

            HStack {
                V3TransportClockLabel(clock: state.presentationClock, isPlaying: state.isPlaying)
                Spacer()
                Text(formatTime(state.currentTrack.duration))
            }
            .font(.system(size: 10.5, weight: .medium, design: .rounded).monospacedDigit())
            .foregroundStyle(.white.opacity(0.68))
            .frame(maxWidth: progressMaxWidth ?? .infinity)
            .padding(.horizontal, 2)

            V3PlaybackButtons(state: state)
                .frame(maxWidth: progressMaxWidth ?? .infinity, alignment: .center)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: alignment == .center ? .center : .leading)
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        let remainder = Int(seconds) % 60
        return String(format: "%02d:%02d", minutes, remainder)
    }
}

private struct V3TransportClockLabel: View {
    let clock: LyricsPresentationClock
    let isPlaying: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.25, paused: !isPlaying)) { _ in
            Text(Self.formatTime(clock.playbackTime(at: ProcessInfo.processInfo.systemUptime)))
        }
    }

    private static func formatTime(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        let remainder = Int(seconds) % 60
        return String(format: "%02d:%02d", minutes, remainder)
    }
}

/// One shared surface keeps the player legible over detailed artwork without
/// turning every individual action into a separate floating object.
private struct V3PlaybackSurface: View {
    var cornerRadius: CGFloat = 18

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.black.opacity(0.24))
    }
}

private struct StageHUDView: View {
    @ObservedObject var state: PlaybackState
    let width: CGFloat

    var body: some View {
        HStack(spacing: 20) {
            TrackMetadataView(
                track: state.currentTrack, titleSize: 16,
                alignment: .leading, presentation: .v3Immersive
            )
            .frame(width: max(1, (width - 32) * 0.38), alignment: .leading)

            V3PlaybackButtons(state: state)

            VStack(spacing: 0) {
                AppleMusicImmersiveV3PlaybackProgress(state: state, density: .small, maxWidth: nil)
                HStack {
                    V3TransportClockLabel(clock: state.presentationClock, isPlaying: state.isPlaying)
                    Spacer()
                    Text(formatTime(state.currentTrack.duration))
                }
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.72))
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(width: width, height: 96)
        .background(V3PlaybackSurface())
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        let remainder = Int(seconds) % 60
        return String(format: "%02d:%02d", minutes, remainder)
    }
}

private struct V3PlaybackButtons: View {
    @ObservedObject var state: PlaybackState

    var body: some View {
        HStack(spacing: 8) {
            V3TransportIconButton(systemImage: "backward.fill", label: "上一首", enabled: state.canControlSpotify) {
                state.previousTrack()
            }
            V3TransportIconButton(
                systemImage: state.isPlaying ? "pause.fill" : "play.fill",
                label: state.isPlaying ? "暂停" : "播放",
                enabled: state.canInteractWithPlayback, prominent: true
            ) {
                state.togglePlayPause()
            }
            V3TransportIconButton(systemImage: "forward.fill", label: "下一首", enabled: state.canControlSpotify) {
                state.nextTrack()
            }
        }
        .fixedSize()
    }
}

private struct V3TransportIconButton: View {
    let systemImage: String
    let label: String
    let enabled: Bool
    var prominent = false
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: prominent ? 20 : 15, weight: .semibold))
                .foregroundStyle(.white.opacity(enabled ? (isHovered || prominent ? 1.0 : 0.88) : 0.35))
                .frame(width: prominent ? 40 : 34, height: prominent ? 40 : 34)
                .contentShape(Circle())
        }
        .buttonStyle(V3BounceButtonStyle())
        .disabled(!enabled)
        .accessibilityLabel(label)
        .help(label)
        .onHover { hovering in
            withAnimation(LyricsDesignTokens.Motion.animation(
                reduceMotion: reduceMotion, duration: 0.14
            )) {
                isHovered = hovering
            }
        }
    }
}

struct V3BounceButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1.0)
            .opacity(configuration.isPressed ? 0.72 : 1.0)
            .animation(
                LyricsDesignTokens.Motion.animation(
                    reduceMotion: reduceMotion,
                    duration: LyricsDesignTokens.Motion.quickDuration
                ),
                value: configuration.isPressed
            )
    }
}

private struct AppleMusicImmersiveV3FocusTransportControls: View {
    @ObservedObject var state: PlaybackState
    let reduceMotion: Bool

    var body: some View {
        HStack(spacing: LyricsDesignTokens.Spacing.sm) {
            Button {
                state.togglePlayPause()
            } label: {
                Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.white.opacity(0.10)))
            }
            .buttonStyle(.plain)
            .disabled(!state.canInteractWithPlayback)
            .opacity(state.canInteractWithPlayback ? 1 : 0.42)
            .accessibilityLabel(state.isPlaying ? "暂停" : "播放")

            Text(state.isPlaying ? "正在播放" : "已暂停")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.62))

            AppleMusicImmersiveV3PlaybackProgress(
                state: state,
                density: .focus,
                maxWidth: nil
            )

            HStack(spacing: 4) {
                V3TransportClockLabel(clock: state.presentationClock, isPlaying: state.isPlaying)
                Text("/ \(formatTime(state.currentTrack.duration))")
            }
                .font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(.white.opacity(0.46))
        }
        .padding(.horizontal, LyricsDesignTokens.Spacing.sm)
        .padding(.vertical, LyricsDesignTokens.Spacing.xs)
        .background(Color.black.opacity(0.16), in: Capsule())
        .animation(
            LyricsDesignTokens.Motion.animation(reduceMotion: reduceMotion, duration: 0.16),
            value: state.isPlaying
        )
        .accessibilityElement(children: .contain)
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        let remainder = Int(seconds) % 60
        return String(format: "%02d:%02d", minutes, remainder)
    }
}

private struct AppleMusicImmersiveV3LyricProgressStatus: View {
    enum Mode: Equatable {
        case synchronized
        case plainText
    }

    let mode: Mode
    let currentIndex: Int?
    var isInstrumental: Bool = false
    var pureImmersion: Bool = false

    private var title: String {
        if isInstrumental {
            return pureImmersion ? "纯音乐 · 极简通透沉浸" : "纯音乐"
        }
        switch mode {
        case .synchronized:
            return currentIndex == nil ? "同步歌词 · 前奏" : "同步歌词"
        case .plainText:
            return "纯文本 · 未排轴"
        }
    }

    private var icon: String {
        if isInstrumental { return "music.note" }
        switch mode {
        case .synchronized: return "waveform"
        case .plainText: return "text.alignleft"
        }
    }

    var body: some View {
        Label(title, systemImage: icon)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(
                isInstrumental
                    ? 0.75
                    : (mode == .synchronized
                        ? LyricsDesignTokens.Material.secondaryTextOpacity
                        : LyricsDesignTokens.Material.mutedTextOpacity)
            ))
            .accessibilityLabel(title)
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

private struct AppleMusicImmersiveV3LyricsViewport: View {
    @Environment(\.lyricTextAlignment) private var textAlignment
    @ObservedObject var state: PlaybackState
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
        .environment(\.v3ExplicitInstrumentalMark, hasExplicitInstrumentalMark)
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
                let scrollAnchor = V3ResponsiveGeometry.lyricScrollAnchor(
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
                        verticalPadding: verticalPadding,
                        isPreview: isPreview,
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
                    if synchronized {
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

        Task(priority: .utility) {
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
        if animated {
            // Defer so wrap/opacity from this index change commit first.
            // withAnimation around scrollTo otherwise interpolates layout.
            DispatchQueue.main.async {
                withAnimation(v3LineFollowAnimation, action)
            }
        } else {
            action()
        }
    }
}

/// Keep the environment callback stable across playback ticks. Updating its
/// target must not invalidate every ruby token in an otherwise unchanged song.
private final class V3RubyActionRelay {
    var action: ((String, String) -> Void)?
    lazy var handler: (String, String) -> Void = { [weak self] surface, reading in
        self?.action?(surface, reading)
    }
}

private struct AppleMusicImmersiveV3LyricsDocumentView: View, Equatable {
    @State private var rubyActionRelay = V3RubyActionRelay()
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
    let isPreview: Bool
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
            && lhs.isPreview == rhs.isPreview
    }

    private var needsWordClock: Bool {
        guard synchronized, let currentIndex, lines.indices.contains(currentIndex) else { return false }
        return lines[currentIndex].timedSpans?.isEmpty == false
    }

    private var rowSpacing: CGFloat {
        let layerCount = (preferences.showRomaji ? 1 : 0)
            + (preferences.showTranslation ? 1 : 0)
        if !synchronized {
            return max(18, (compact ? 21 : 24) - CGFloat(max(0, layerCount - 1)))
        }
        return max(20, (compact ? 24 : 28) - CGFloat(max(0, layerCount - 1)) * 2)
    }

    var body: some View {
        let _ = rubyActionRelay.action = onRuby
        VStack(alignment: textAlignment.lyricHorizontalAlignment, spacing: rowSpacing) {
            ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                row(for: line, index: index)
                    .id(line.id)
            }
        }
        .frame(maxWidth: .infinity, alignment: textAlignment.lyricFrameAlignment)
        .padding(.top, verticalPadding)
        .padding(.bottom, verticalPadding)
        .padding(.leading, textAlignment == .leading ? 0 : (compact ? 10 : 18) * (textAlignment == .center ? 0.5 : 1))
        .padding(.trailing, textAlignment == .trailing ? 0 : (compact ? 10 : 18) * (textAlignment == .center ? 0.5 : 1))
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
            distance: distance,
            isSynchronized: synchronized,
            availableWidth: availableWidth,
            compact: compact,
            preferences: preferences,
            language: language,
            trackStableKey: trackStableKey,
            artistDisplay: artistDisplay,
            presentationClock: presentationClock
        )
        .equatable()
        .environmentObject(settings)
        .environment(\.rubyCorrectionAction, onRuby == nil ? nil : rubyActionRelay.handler)
        .contextMenu {
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
enum V3JapaneseReadingCache {
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
            lock.unlock()
            return cached
        }
        lock.unlock()

        let result = providerKana.map { JapaneseReadingPipeline.analyze(originalText: normalizedText, providerKana: $0) } ?? JapaneseContextualReadingEngine.analyze(
            text: normalizedText,
            userEntries: applicableEntries,
            trackStableKey: trackStableKey,
            artistDisplay: artistDisplay
        )

        lock.lock()
        values[key] = result
        if values.count > 256, let oldestKey = values.keys.first {
            values.removeValue(forKey: oldestKey)
        }
        lock.unlock()
        return result
    }

    private static var resolvedCache: [String: JapaneseRubyPresentation] = [:]

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
        let hash = "\(line.timestamp)-\(original)"
        let key = "\(line.id.uuidString)-\(hash)-\(language ?? "")-\(scriptConversion.rawValue)-\(userEntries.count)-\(trackStableKey ?? "")"
        lock.lock()
        if let cached = resolvedCache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

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
        if resolvedCache.count > 512, let oldest = resolvedCache.keys.first {
            resolvedCache.removeValue(forKey: oldest)
        }
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
    @EnvironmentObject private var settings: AppSettingsStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.lyricAgentPresentationMap) private var agentPresentationMap

    static func == (lhs: AppleMusicImmersiveV3LyricRow, rhs: AppleMusicImmersiveV3LyricRow) -> Bool {
        lhs.line == rhs.line
            && lhs.isActive == rhs.isActive
            && lhs.clampedDistance == rhs.clampedDistance
            && lhs.isSynchronized == rhs.isSynchronized
            && lhs.availableWidth == rhs.availableWidth
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
            presentationScale: presentationScale,
            textAlignment: textAlignment
        )
        .equatable()
        .offset(x: CGFloat(agentPresentationMap.horizontalOffset(for: line.performerID)))
        .opacity(rowOpacity)
        .blur(radius: reduceMotion ? 0 : rowBlur)
        .animation(nil, value: isActive)
        .animation(nil, value: layoutSignature)
    }
}

private struct AppleMusicImmersiveV3LyricRowContent: View, Equatable {
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

    private var baseSize: CGFloat {
        guard isSynchronized else {
            return min((compact ? 30 : 36) * presentationScale, activeBaseSize)
        }
        return activeBaseSize
    }

    private var rubySize: CGFloat {
        // baseSize * 0.44 provides readable 15-17pt ruby annotations for active lines
        max(compact ? 12 : 14, min(22, baseSize * 0.44 * preferences.rubyFontSize / 10))
    }
    private var auxiliarySize: CGFloat {
        min(compact ? 16 : 18, max(12, baseSize * 0.44 * preferences.assistantFontSize / 14))
    }

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
        min(max(240, availableWidth), LyricsDesignTokens.readableLyricLineMaxWidth * presentationScale)
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
        preferences.showOriginal && shouldShowRuby && rubyPresentation.hasRuby && (isPinyinProjection ? preferences.showPinyin : true)
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
        isPinyinProjection ? preferences.showPinyin : preferences.showRomaji
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
                        baseColor: .white,
                        rubyColor: .white.opacity(rubyOpacity),
                        rubySpacing: 1,
                        tokenVerticalSpacing: 3,
                        maxWidth: readableLineWidth
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
                    baseColor: .white,
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
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if preferences.kanaDisplayMode == .independentLine, shouldShowKana,
                   let kana = displayKanaText {
                    Text(kana)
                        .font(.system(size: auxiliarySize, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(rubyOpacity))
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }
            } else if shouldShowKana, let kana = displayKanaText {
                Text(kana)
                    .font(.system(size: baseSize, weight: rowWeight, design: .rounded))
                    .foregroundStyle(.white)
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
                    .font(.system(size: max(14, auxiliarySize * 0.94), weight: .medium, design: .rounded))
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
                    baseColor: .white,
                    rubyColor: .white.opacity(rubyOpacity),
                    rubySpacing: 1,
                    tokenVerticalSpacing: 3,
                    maxWidth: readableLineWidth
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
                baseColor: .white,
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
                            .foregroundColor(.white)
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

private struct V3LyricsTimePopover: View {
    @ObservedObject var settings: AppSettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("歌词时间")
                .font(.headline)

            LyricsPresentationOffsetControl(settings: settings)

            Button("恢复默认") {
                settings.lyricsOffsetStore.resetActiveValue()
            }
            .accessibilityIdentifier("lyrics.time.reset")
            .font(.system(size: 11, design: .rounded))
            .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(width: 340)
    }
}

/// Shared theme navigation; existing style IDs and per-style preferences stay intact.
private struct V3ThemeSelectorView: View {
    @ObservedObject var settings: AppSettingsStore
    @Binding var preview: V3ArtworkPresentation?
    var onConfirm: () -> Void
    @State private var browsedTheme: V3ArtworkTheme?
    private var displayedTheme: V3ArtworkTheme { browsedTheme ?? settings.v3ArtworkPresentation.theme }

    private var displayedStyle: V3ArtworkPresentation { preview ?? settings.v3ArtworkPresentation }
    private var variants: [V3ArtworkPresentation] {
        switch displayedTheme {
        case .ambient: return V3ArtworkPresentation.ambientVariants
        case .enlarged: return V3ArtworkPresentation.enlargedVariants
        default: return []
        }
    }

    private func choose(_ style: V3ArtworkPresentation, closePanel: Bool = false) {
        settings.v3ArtworkPresentation = style
        preview = nil
        if closePanel { onConfirm() }
    }

    private func themeButton(_ theme: V3ArtworkTheme, height: CGFloat = 64) -> some View {
        let style = settings.v3RememberedPresentation(for: theme)
        return Button { choose(style, closePanel: false) } label: {
            VStack(spacing: 7) {
                Image(systemName: theme.symbolName).font(.system(size: 22))
                Text(theme.title).font(.system(size: 12, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(settings.v3ArtworkPresentation.theme == theme ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .topTrailing) {
                if settings.v3ArtworkPresentation.theme == theme {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor).padding(6)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside {
                browsedTheme = theme
                if preview != style { preview = style }
            } else if preview == style { preview = nil }
        }
        .help(style.detail)
        .accessibilityIdentifier("v3.theme." + theme.rawValue)
        .accessibilityAddTraits(settings.v3ArtworkPresentation.theme == theme ? .isSelected : [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                themeButton(.stage)
                themeButton(.lyricsOnly)
            }
            themeButton(.albumPoster, height: 46)
            Divider().padding(.vertical, 3)
            HStack(spacing: 8) {
                themeButton(.ambient)
                themeButton(.enlarged)
            }
            ZStack(alignment: .leading) {
                if !variants.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(displayedTheme.title + "方案").font(.caption).foregroundStyle(.secondary)
                        HStack(spacing: 5) {
                            ForEach(variants) { style in
                                Button { choose(style, closePanel: false) } label: {
                                    Text(style.variantTitle)
                                        .font(.system(size: 11, weight: .medium))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 9)
                                        .background(settings.v3ArtworkPresentation == style ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                                }
                                .buttonStyle(.plain)
                                .onHover { inside in
                                    if inside { if preview != style { preview = style } }
                                    else if preview == style { preview = nil }
                                }
                                .help(style.detail)
                                .accessibilityIdentifier("v3.style." + style.rawValue)
                                .accessibilityAddTraits(settings.v3ArtworkPresentation == style ? .isSelected : [])
                            }
                        }
                    }
                } else {
                    Text(displayedStyle.detail)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(height: 64)
        }
        .onHover { inside in
            if !inside { preview = nil; browsedTheme = nil }
        }
    }
}

private struct V3VisualTuningPopoverView: View {
    @ObservedObject var settings: AppSettingsStore
    @Binding var layoutStyleRawValue: String
    @Binding var preview: V3ArtworkPresentation?
    var onStyleConfirmed: () -> Void

    private var blurPresetName: String {
        let r = settings.v3BackdropBlurRadius
        if r <= 5 { return "清晰" }
        if r <= 35 { return "轻柔" }
        if r <= 75 { return "柔和" }
        return "弥散"
    }

    private var sizePresetName: String {
        let s = settings.v3ArtworkSizeScale
        if s <= 0.90 { return "精巧" }
        if s <= 1.10 { return "标准" }
        if s <= 1.30 { return "大图" }
        return "巨幕"
    }

    private var backdropScalePresetName: String {
        let s = settings.v3BackdropScale(for: settings.v3ArtworkPresentation)
        if s <= 0.90 { return "精巧" }
        if s <= 1.10 { return "标准" }
        if s <= 1.30 { return "大图" }
        return "巨幕"
    }

    var body: some View {
        ScrollView {
            tuningControls
        }
        .frame(width: 340)
        .frame(maxHeight: 680)
        .preferredColorScheme(.dark)
        .environment(\.colorScheme, .dark)
        .onDisappear { preview = nil }
    }

    private var tuningControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("外观与布局")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                V3ThemeSelectorView(settings: settings, preview: $preview, onConfirm: onStyleConfirmed)

                Text(settings.v3ArtworkPresentation.detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            // 1. 背景封面：取景方式、背景缩放、模糊／光效
            VStack(alignment: .leading, spacing: 10) {
                Text(settings.v3ArtworkPresentation == .lyricsOnly ? "背景光场" : "背景封面")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.primary)

                if settings.v3ArtworkPresentation != .lyricsOnly {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("取景方式")
                            .font(.system(size: 12, weight: .medium))
                        Picker("取景方式", selection: Binding(
                            get: { settings.v3BackgroundShowsCompleteArtwork(for: settings.v3ArtworkPresentation) },
                            set: { settings.setV3BackgroundShowsCompleteArtwork($0, for: settings.v3ArtworkPresentation) }
                        )) {
                            Text("铺满").tag(false)
                            Text("尽量完整").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .accessibilityLabel("取景方式")
                        .accessibilityIdentifier("v3.ambient.backgroundFraming")

                        Text(settings.v3BackgroundShowsCompleteArtwork(for: settings.v3ArtworkPresentation)
                            ? "优先展示更多画面并柔和补边；前景封面单独调整。"
                            : "允许裁切以铺满背景空间；前景封面单独调整。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Group {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(settings.v3ArtworkPresentation == .lyricsOnly ? "背景光场缩放" : "背景缩放")
                                .font(.system(size: 12, weight: .medium))
                            Spacer()
                            Text("\(backdropScalePresetName) · \(Int((settings.v3BackdropScale(for: settings.v3ArtworkPresentation) * 100).rounded()))%")
                                .font(.system(size: 11, weight: .bold).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: Binding(
                            get: { settings.v3BackdropScale(for: settings.v3ArtworkPresentation) },
                            set: { settings.setV3BackdropScale($0, for: settings.v3ArtworkPresentation) }
                        ), in: 0.8...1.4, step: 0.05)
                            .accessibilityLabel("背景缩放")
                            .accessibilityIdentifier("v3.classic.backgroundScale")

                        HStack(spacing: 0) {
                            backdropScalePresetButton("精巧 80%", val: 0.80)
                            Spacer()
                            backdropScalePresetButton("标准 100%", val: 1.00)
                            Spacer()
                            backdropScalePresetButton("大图 120%", val: 1.20)
                            Spacer()
                            backdropScalePresetButton("巨幕 140%", val: 1.40)
                        }

                        Text("只改变背景取景，不改变前景封面大小。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(settings.v3ArtworkPresentation.blurControlTitle)
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        Text("\(blurPresetName) · \(Int(settings.v3BackdropBlurRadius))%")
                            .font(.system(size: 11, weight: .bold).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $settings.v3BackdropBlurRadius, in: 0...100, step: 1)
                        .accessibilityLabel(settings.v3ArtworkPresentation.blurControlTitle)

                    HStack(spacing: 0) {
                        blurPresetButton("清晰 0%", val: 0)
                        Spacer()
                        blurPresetButton("轻柔 25%", val: 25)
                        Spacer()
                        blurPresetButton("柔和 60%", val: 60)
                        Spacer()
                        blurPresetButton("弥散 100%", val: 100)
                    }
                }

                if settings.v3ArtworkPresentation == .stage {
                    VStack(alignment: .leading, spacing: 5) {
                        Toggle("增强歌词对比度", isOn: $settings.v3StageReadabilityEnabled)
                        Text("为亮色封面增加柔和暗层，让白色歌词更清楚。")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Toggle("纯音乐极简通透沉浸", isOn: $settings.v3InstrumentalPureImmersion)
                    .font(.system(size: 12, weight: .medium))
            }

            // 2. 前景封面：尺寸、位置、隐藏播放信息时舒展
            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("前景封面")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.primary)

                Toggle("显示前景封面", isOn: $settings.v3ShowForegroundArtwork)
                    .help("关闭后，有前景封面的主题会展开歌词布局；舞台与纯净歌词保持原布局。")
                    .accessibilityIdentifier("v3.artwork.showForeground")

                if settings.v3ArtworkPresentation != .lyricsOnly && settings.v3ArtworkPresentation != .stage {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(settings.v3ArtworkPresentation.artworkSizeControlTitle)
                                .font(.system(size: 12, weight: .medium))
                            Spacer()
                            Text("\(sizePresetName) · \(Int(settings.v3ArtworkSizeScale * 100))%")
                                .font(.system(size: 11, weight: .bold).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $settings.v3ArtworkSizeScale, in: 0.8...1.4, step: 0.05)
                            .accessibilityLabel(settings.v3ArtworkPresentation.artworkSizeControlTitle)

                        HStack(spacing: 0) {
                            sizePresetButton("精巧 80%", val: 0.80)
                            Spacer()
                            sizePresetButton("标准 100%", val: 1.00)
                            Spacer()
                            sizePresetButton("大图 120%", val: 1.20)
                            Spacer()
                            sizePresetButton("巨幕 140%", val: 1.40)
                        }
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Text(settings.v3ArtworkPresentation.artworkPositionControlTitle)
                            .font(.system(size: 12, weight: .medium))
                        Picker(settings.v3ArtworkPresentation.artworkPositionControlTitle, selection: $settings.v3ArtworkPosition) {
                            Text("居左").tag("left")
                            if settings.v3ArtworkPresentation != .albumPoster {
                                Text("居中").tag("center")
                            }
                            Text("居右").tag("right")
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .accessibilityLabel(settings.v3ArtworkPresentation.artworkPositionControlTitle)
                    }

                    if settings.v3ArtworkPresentation == .authenticAmbient
                        || settings.v3ArtworkPresentation == .ambient
                        || settings.v3ArtworkPresentation == .classicGaussian
                        || settings.v3ArtworkPresentation == .classic
                        || settings.v3ArtworkPresentation == .ambientFeathered {
                        Toggle("隐藏播放信息时舒展封面", isOn: $settings.v3ExpandArtworkWhenDetailsHidden)
                            .disabled(!settings.v3PlaybackDetailsOnHover && !settings.v3EdgeProgressEnabled)
                            .help("隐藏播放信息后，统一放大封面并按窗口画布居中；关闭后保持设定的尺寸与位置。")
                            .accessibilityIdentifier("v3.artwork.expandWhenDetailsHidden")
                    }
                }
            }

            Divider()

            // 3. 歌词：位置和对齐
            VStack(alignment: .leading, spacing: 10) {
                Text("歌词")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.primary)

                VStack(alignment: .leading, spacing: 6) {
                    Text("位置与对齐").font(.system(size: 12, weight: .medium))
                    Picker("歌词位置与对齐", selection: Binding(
                        get: { settings.v3LyricsPosition },
                        set: { settings.v3LyricsPosition = $0 }
                    )) {
                        Text("自动").tag("automatic")
                        Text("左侧").tag("left")
                        Text("居中").tag("center")
                        Text("右侧").tag("right")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityLabel("歌词位置与对齐")

                    Text("每种模式单独记住选择，假名和译文一起对齐。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Divider()

            // 4. 播放：播放信息显隐等选项
            VStack(alignment: .leading, spacing: 10) {
                Text("播放")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.primary)

                V3WindowEdgeProgressSettings(
                    enabled: $settings.v3EdgeProgressEnabled,
                    colorHex: $settings.v3EdgeProgressColorHex
                )

                VStack(alignment: .leading, spacing: 5) {
                    Toggle("悬停时显示播放信息", isOn: $settings.v3PlaybackDetailsOnHover)
                    Text("移入封面或播放区域时显示播放控制；移到顶部可打开工具。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("主窗口布局")
                        .font(.system(size: 12, weight: .medium))
                    Picker("主窗口布局", selection: $layoutStyleRawValue) {
                        ForEach(MainWindowLayoutStyle.userSelectableCases) { style in
                            Text(style.title).tag(style.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .accessibilityLabel("主窗口布局")
                }
            }
        }
        .padding(14)
    }

    @ViewBuilder
    private func blurPresetButton(_ title: String, val: Double) -> some View {
        Button(title) {
            settings.v3BackdropBlurRadius = val
        }
        .buttonStyle(.plain)
        .font(.system(size: 10, weight: abs(settings.v3BackdropBlurRadius - val) < 5 ? .bold : .regular))
        .foregroundStyle(abs(settings.v3BackdropBlurRadius - val) < 5 ? Color.blue : Color.secondary)
    }

    @ViewBuilder
    private func sizePresetButton(_ title: String, val: Double) -> some View {
        Button(title) {
            settings.v3ArtworkSizeScale = val
        }
        .buttonStyle(.plain)
        .font(.system(size: 10, weight: abs(settings.v3ArtworkSizeScale - val) < 0.04 ? .bold : .regular))
        .foregroundStyle(abs(settings.v3ArtworkSizeScale - val) < 0.04 ? Color.blue : Color.secondary)
    }

    @ViewBuilder
    private func backdropScalePresetButton(_ title: String, val: Double) -> some View {
        let currentScale = settings.v3BackdropScale(for: settings.v3ArtworkPresentation)
        Button(title) {
            settings.setV3BackdropScale(val, for: settings.v3ArtworkPresentation)
        }
        .buttonStyle(.plain)
        .font(.system(size: 10, weight: abs(currentScale - val) < 0.04 ? .bold : .regular))
        .foregroundStyle(abs(currentScale - val) < 0.04 ? Color.blue : Color.secondary)
    }
}

// A read-only, line-index-aligned view of already persisted translations.
// It never starts translation, mutates source lyrics or treats draft rows as complete.
private struct V3TranslationComparisonSheet: View {
    let sourceLines: [LyricLine]
    let versions: [StoredTranslationVersion]
    let selectedVersionID: UUID?
    let onSelect: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var leftID: UUID
    @State private var rightID: UUID

    init(
        sourceLines: [LyricLine],
        versions: [StoredTranslationVersion],
        selectedVersionID: UUID?,
        onSelect: @escaping (UUID) -> Void
    ) {
        self.sourceLines = sourceLines
        self.versions = versions
        self.selectedVersionID = selectedVersionID
        self.onSelect = onSelect
        let first = versions.first(where: { $0.record.id == selectedVersionID })?.record.id
            ?? versions.first?.record.id ?? UUID()
        _leftID = State(initialValue: first)
        _rightID = State(initialValue: versions.first(where: { $0.record.id != first })?.record.id ?? first)
    }

    private var left: StoredTranslationVersion? { versions.first { $0.record.id == leftID } }
    private var right: StoredTranslationVersion? { versions.first { $0.record.id == rightID } }

    private func title(_ version: StoredTranslationVersion) -> String {
        let record = version.record
        let name = record.translationSourceTitle
        let status = version.isArchived ? " · 已归档"
            : version.isDraft ? " · 待采用" : (!version.isComplete ? " · 不完整" : "")
        let locked = record.isLocked ? " · 已锁定" : ""
        return "\(name)\(status)\(locked) · \(record.createdAt.formatted(date: .abbreviated, time: .shortened))"
    }

    private func textByIndex(_ version: StoredTranslationVersion?) -> [Int: String] {
        guard let version else { return [:] }
        var result: [Int: String] = [:]
        for line in version.lines where line.lineIndex >= 0 && line.lineIndex < sourceLines.count {
            result[line.lineIndex] = line.translatedText
        }
        return result
    }

    private func canSelect(_ version: StoredTranslationVersion?) -> Bool {
        guard let version else { return false }
        return version.isComplete && !version.isDraft && !version.isArchived
    }

    private func columnText(_ text: String?) -> some View {
        Text(text.flatMap { $0.isEmpty ? nil : $0 } ?? "— 本行无译文 —")
            .font(.system(size: 13))
            .foregroundStyle(text?.isEmpty == false ? .primary : .secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    var body: some View {
        let leftLines = textByIndex(left)
        let rightLines = textByIndex(right)
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("译文对比").font(.system(size: 20, weight: .semibold))
                    Text("仅比较当前歌曲已保存的版本；切换对比不会重新翻译，也不会改变当前采用稿。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(20)
            Divider()
            HStack(spacing: 14) {
                Text("原文 · \(sourceLines.count) 行")
                    .font(.callout.weight(.medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Picker("左侧", selection: $leftID) {
                    ForEach(versions, id: \.record.id) { version in
                        Text(title(version)).tag(version.record.id)
                    }
                }
                .labelsHidden().frame(maxWidth: .infinity)
                .accessibilityLabel("左侧译文版本")
                Picker("右侧", selection: $rightID) {
                    ForEach(versions, id: \.record.id) { version in
                        Text(title(version)).tag(version.record.id)
                    }
                }
                .labelsHidden().frame(maxWidth: .infinity)
                .accessibilityLabel("右侧译文版本")
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(sourceLines.indices, id: \.self) { index in
                        HStack(alignment: .top, spacing: 14) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("\(index + 1)")
                                    .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                                Text(sourceLines[index].originalText)
                                    .font(.system(size: 13, weight: .medium))
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            columnText(leftLines[index])
                            columnText(rightLines[index])
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .background(index.isMultiple(of: 2) ? Color.primary.opacity(0.025) : .clear)
                        Divider().opacity(0.30)
                    }
                }
            }
            Divider()
            HStack(spacing: 12) {
                Text("\(versions.count) 份已存译文 · 按原文行号对齐，不拼接缺失行")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let left {
                    Button(left.record.id == selectedVersionID ? "左侧已采用" : "采用左侧") {
                        onSelect(left.record.id)
                        dismiss()
                    }
                    .disabled(!canSelect(left) || left.record.id == selectedVersionID)
                }
                if let right {
                    Button(right.record.id == selectedVersionID ? "右侧已采用" : "采用右侧") {
                        onSelect(right.record.id)
                        dismiss()
                    }
                    .disabled(!canSelect(right) || right.record.id == selectedVersionID || rightID == leftID)
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(16)
        }
        .frame(minWidth: 760, idealWidth: 960, minHeight: 480, idealHeight: 650)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
