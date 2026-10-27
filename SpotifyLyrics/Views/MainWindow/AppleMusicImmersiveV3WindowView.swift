import Foundation
import SwiftUI
import AppKit
import Combine
import os

private struct V3PreviewPresentationKey: EnvironmentKey {
    static let defaultValue: V3ArtworkPresentation? = nil
}

private struct V3ExplicitInstrumentalMarkKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var v3PreviewPresentation: V3ArtworkPresentation? {
        get { self[V3PreviewPresentationKey.self] }
        set { self[V3PreviewPresentationKey.self] = newValue }
    }

    var v3ExplicitInstrumentalMark: Bool {
        get { self[V3ExplicitInstrumentalMarkKey.self] }
        set { self[V3ExplicitInstrumentalMarkKey.self] = newValue }
    }
}

private struct V3PlaybackVisibilityKey: EnvironmentKey {
    static let defaultValue = true
}

private struct V3PlaybackInteractionKey: EnvironmentKey {
    static let defaultValue = V3PlaybackInteractionRelay()
}

private struct V3ToolbarFramePreferenceKey: PreferenceKey {
    static let defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
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
    var v3PlaybackVisible: Bool {
        get { self[V3PlaybackVisibilityKey.self] }
        set { self[V3PlaybackVisibilityKey.self] = newValue }
    }

    var v3PlaybackInteractionChanged: V3PlaybackInteractionRelay {
        get { self[V3PlaybackInteractionKey.self] }
        set { self[V3PlaybackInteractionKey.self] = newValue }
    }
}

private struct V3PlaybackVisibility: ViewModifier {
    let visible: Bool
    let reduceMotion: Bool
    func body(content: Content) -> some View {
        content.environment(\.v3PlaybackVisible, visible)
            .opacity(visible ? 1 : 0)
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

final class V3PlaybackInteractionRelay: Equatable {
    var action: ((Bool) -> Void)?
    static func == (lhs: V3PlaybackInteractionRelay, rhs: V3PlaybackInteractionRelay) -> Bool { lhs === rhs }
    func callAsFunction(_ value: Bool) { action?(value) }
}

/// Player controls use the independently advancing presentation clock. Observe
/// content changes without subscribing their whole layouts to the coarse time tick.
@MainActor
final class V3PlaybackContentObserver: ObservableObject {
    @Published private var revision: UInt64 = 0
    let state: PlaybackState
    private var subscription: AnyCancellable?
    init(_ state: PlaybackState) {
        self.state = state
        subscription = state.objectWillChange.sink { [weak self, weak state] _ in
            guard let self, let state, !state.isPublishingPlaybackClockTick else { return }
            self.revision &+= 1
        }
    }
}

@MainActor
@propertyWrapper
struct V3ContentPlaybackState: DynamicProperty {
    @StateObject private var observer: V3PlaybackContentObserver
    init(wrappedValue: PlaybackState) {
        _observer = StateObject(wrappedValue: V3PlaybackContentObserver(wrappedValue))
    }
    var wrappedValue: PlaybackState { observer.state }
}

private final class V3ContentRefreshQueue { var scheduled = false }

private final class V3PointerLocationBox {
    var location: CGPoint?
}

/// Independent Apple Music-inspired main canvas. V2 and Lyrics Focus remain
/// separate layouts; this view owns only the V3 canvas and its transient tools.
struct AppleMusicImmersiveV3WindowView: View, Equatable {
    let state: PlaybackState
    @State private var contentRevision: UInt64 = 0
    @State private var contentRefreshQueue = V3ContentRefreshQueue()

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.state === rhs.state && lhs.settings === rhs.settings && lhs.liveOnly == rhs.liveOnly
    }

    private func refreshForContentChange() {
        guard !state.isPublishingPlaybackClockTick, !contentRefreshQueue.scheduled else { return }
        contentRefreshQueue.scheduled = true
        DispatchQueue.main.async {
            contentRefreshQueue.scheduled = false
            contentRevision &+= 1
        }
    }
    @ObservedObject var settings: AppSettingsStore
    @ObservedObject private var settingsRoute = SettingsNavigationRoute.shared
    @Binding var layoutStyleRawValue: String
    var liveOnly: Bool = false
    @Environment(\.lyricPresentationScale) private var presentationScale
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isWindowMenuPresented = false
    @State private var showsAIReadingControls = false
    @State private var hoveredAIReadingControls: Bool?
    private var displaysAIReadingControls: Bool { hoveredAIReadingControls ?? showsAIReadingControls }
    @State private var confirmsAIReadingRequest = false
    @State private var isTranslationComparisonPresented = false
    @State private var isVersionPickerPresented = false
    @State private var pinchStartFontSize: CGFloat?
    @State private var coverAccent: Color?
    @State private var coverLuminance: Double = 0
    @State private var coverSubject: V3ArtworkSubject.Analysis?
    @State private var showsListeningKeys = false
    @State private var isFocusMode = false
    @State private var librarySearch = V3LibrarySearchPresentation()
    @State private var toolbarBounds = CGRect.zero
    @State private var lyricNotice: String?
    @State private var lyricNoticeTask: Task<Void, Never>?
    /// Visual-host preview only; real playback fills this from the session.
    @State private var previewAutomaticSelection: LyricsAutomaticSelection?
    @State private var hoveredStyle: V3ArtworkPresentation?
    @State private var hoveredScene: V3ListeningScene?
    private var compositionScene: V3ListeningScene? { hoveredStyle == nil ? settings.v3ListeningScene : hoveredScene }
    private var compositionShowsCover: Bool { settings.v3ShowsForegroundArtwork(scene: compositionScene, renderer: compositionStyle) }
    private var compositionStyle: V3ArtworkPresentation { hoveredStyle ?? settings.v3ArtworkPresentation }
    private var compositionArtworkPosition: String { settings.v3PreviewPosition(for: compositionStyle, scene: compositionScene) }
    private var compositionLyricsPosition: String { settings.v3PreviewLyricsPosition(for: compositionStyle, scene: compositionScene) }
    private var usesArtworkSubjectPlacement: Bool {
        compositionScene == .coverPhoto || (compositionScene == nil && compositionStyle == .stage)
    }
    private var compositionArtworkScale: Double { settings.v3PreviewScale(for: compositionStyle, scene: compositionScene) }
    /// 清晰度 resolved once per composition so the bright-cover automatic
    /// shadow (封面 and 舞台 with a bright cover) applies everywhere at once.
    private var compositionReadingProtection: V3ReadingProtection {
        settings.v3EffectiveReadingProtection(scene: compositionScene,
                                              renderer: compositionStyle,
                                              coverLuminance: coverLuminance)
    }
    private typealias ToolbarPopover = V3ToolbarModel.Panel
    private enum InspectorSurfaceStyle: Equatable { case hoverGlass, pinnedSolid }
    /// All toolbar/panel decisions live in this value; see V3ToolbarModel.
    @State private var toolbar = V3ToolbarModel()
    @State private var toolbarDismissTask: Task<Void, Never>?
    private var activeToolbarPopover: ToolbarPopover? { toolbar.hoverPanel }
    private var pinnedToolbarPanel: ToolbarPopover? { toolbar.pinnedPanel }
    // Keep listening unobstructed. Tools reveal at the top edge and stay
    // available while their popover is open.
    @State private var toolsVisible = false
    @State private var isPointerInToolbarRegion = false
    @State private var interactionToken = 0
    @State private var isAlignmentDetailsPresented = false
    @State private var isPointerInsideCanvas = false
    @State private var isPointerInsidePlaybackRegion = false
    @State private var pointerLocationBox = V3PointerLocationBox()
    @State private var playbackInteractionRelay = V3PlaybackInteractionRelay()
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
        compositionScene == nil && settings.v3ExpandArtworkWhenDetailsHidden && !playbackDetailsVisible
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
        compositionShowsCover
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

    private var foregroundArtworkCornerRadiusRatio: CGFloat {
        switch compositionStyle {
        case .authenticAmbient: return 0.075
        case .classic: return 0.12
        case .ambientFeathered: return 0.18
        case .ambient: return 0.015
        case .classicGaussian: return 0.025
        case .stage: return 0.035
        case .lyricsOnly: return 0.12
        case .albumPoster: return 0.02
        }
    }

    private var usesDocumentComposition: Bool {
        compositionScene != nil || compositionStyle == .lyricsOnly || compositionStyle == .albumPoster
    }

    private var compositionTrack: Track { liveOnly ? state.currentTrack : state.displayedTrack }
    private var isCompositionPreview: Bool { !liveOnly && state.isShowingSearchPreview }

    private var compositionPreviewLabel: some View {
        Label("歌词预览", systemImage: "doc.text.magnifyingglass")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(0.68))
    }

    var body: some View {
        let _ = contentRevision
        let _ = playbackInteractionRelay.action = { isPlaybackInteracting = $0 }
        GeometryReader { geometry in
            // Tools never alter the artwork or lyric measurement canvas.
            let canvasWidth = max(1, geometry.size.width)
            ZStack(alignment: .topTrailing) {
                let isInst = !state.isShowingSearchPreview && state.liveTrackIsMarkedInstrumental
                AppleMusicImmersiveV3BackdropView(
                    track: usesDocumentComposition ? compositionTrack : state.currentTrack,
                    identity: usesDocumentComposition && isCompositionPreview ? nil : state.currentTrackIdentity,
                    isInstrumental: isInst,
                    isPlaying: state.isPlaying,
                    settings: settings,
                    presentationOverride: hoveredStyle,
                    sceneOverride: compositionScene
                )
                // An aspect-fill album image can report the square image's
                // width in a tall window. Keep that drawing overflow inside
                // the canvas so it cannot shift the top-trailing foreground.
                .frame(width: geometry.size.width, height: geometry.size.height)
                .blur(radius: librarySearch.isPresented ? 3 : 0)

                GeometryReader { canvasGeometry in
                    layout(for: canvasGeometry)
                        .frame(width: canvasGeometry.size.width, height: canvasGeometry.size.height)
                }
                .frame(width: canvasWidth, height: geometry.size.height)
                .frame(maxWidth: .infinity, alignment: .leading)
                .blur(radius: librarySearch.isPresented ? 3 : 0)
                .allowsHitTesting(!librarySearch.isPresented)

                if settings.v3EdgeProgressEnabled && !isFocusMode && !librarySearch.isPresented {
                    V3WindowEdgePlaybackOverlay(
                        state: state,
                        colorHex: settings.v3EdgeProgressColorHex,
                        colorMode: settings.v3EdgeProgressColorMode,
                        coverLuminance: coverLuminance,
                        exitPoint: lastWindowExitPoint,
                        pointerInsideWindow: isPointerInsideCanvas,
                        // Priority: an open panel, then the toolbar, then the edge.
                        suppressControls: toolbar.suppressesEdgeControls(nearTop: false, otherPanelOpen: toolbarPanelIsPresented),
                        toolbarBounds: toolbarBounds
                    )
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }

                if librarySearch.isPresented {
                    V3LibrarySearchPanel(presentation: $librarySearch, state: state)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }

                HStack(spacing: 16) {
                    Spacer(minLength: 0)
                    toolBar(for: geometry.size)
                        .opacity(toolbarOpacity)
                        .allowsHitTesting(toolbarOpacity > 0)
                        .accessibilityHidden(toolbarOpacity == 0)
                        .animation(
                            LyricsDesignTokens.Motion.animation(reduceMotion: reduceMotion),
                            value: toolbarOpacity
                        )
                }
                .padding(.horizontal, 24)
                .padding(.top, 18)

                // Hover shows the temporary panel inside the app; a click pins
                // it as a separate tool window to the right of the main window.
                if let pinned = pinnedToolbarPanel {
                    V3PinnedInspectorPanelHost(
                        isPresented: Binding(
                            get: { pinnedToolbarPanel != nil },
                            set: { presented in
                                if !presented {
                                    dismissPinnedToolbarPanel()
                                }
                            }
                        ),
                        title: pinned.title,
                        content: inspectorSurface(for: pinned, style: .pinnedSolid)
                    )
                    .frame(width: 0, height: 0)
                }

            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .coordinateSpace(name: "v3-window-canvas")
            .onPreferenceChange(V3ToolbarFramePreferenceKey.self) { frame in
                if toolbarBounds != frame { toolbarBounds = frame }
            }
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
            .onExitCommand {
                showsListeningKeys = false
                isFocusMode = false
                dismissPinnedToolbarPanel()
            }
            .onChange(of: settingsRoute.requestedToolbarPanel, initial: true) { _, panel in
                guard let panel else { return }
                isFocusMode = false
                toolsVisible = true
                if pinnedToolbarPanel != panel { clickToolbarPanel(panel) }
                settingsRoute.requestedToolbarPanel = nil
            }
            .onReceive(state.$playbackNotice.compactMap { $0 }) { showLyricNotice($0) }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                state.refreshPlayerModes()
            }
            .overlay { if showsListeningKeys { listeningKeyList } }
#if DEBUG
            // Lets the offscreen visual host (Tools/experience_visual_host)
            // render toolbar states that otherwise need a real pointer.
            .onReceive(NotificationCenter.default.publisher(for: .v3ToolbarDebugCommand)) { note in
                applyToolbarDebugCommand(note.userInfo ?? [:])
            }
#endif
            .task(id: interactionToken) {
                guard interactionToken > 0 else { return }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled, !isPointerInToolbarRegion, !toolbarPanelIsPresented else { return }
                withAnimation(LyricsDesignTokens.Motion.animation(reduceMotion: reduceMotion)) {
                    toolsVisible = false
                }
            }
            .background {
                V3CanvasSceneSwipe(enabled: !toolbarPanelIsPresented, onKey: handleListeningKey) { direction in
                    showLyricNotice(V3LyricActions(settings: settings).scene(direction))
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
        .v3NightGentle(enabled: settings.v3NightGentleEnabled)
        .environment(\.v3CoverAccent, coverAccent ?? .white)
        .tint(coverAccent)
        .accentColor(coverAccent)
        .task(id: compositionTrack.artworkURL) {
            guard let url = compositionTrack.artworkURL else { coverAccent = nil; coverLuminance = 0; return }
            let palette = await LyricIslandArtworkColors.palette(for: url)
            guard !Task.isCancelled else { return }
            coverAccent = LyricIslandArtworkColors.listeningAccent(palette)
            coverLuminance = palette.luminance
        }
        .task(id: "\(usesArtworkSubjectPlacement)|\(compositionTrack.artworkURL?.absoluteString ?? "none")") {
            coverSubject = nil
            guard usesArtworkSubjectPlacement else { return }
            let subject = await V3ArtworkSubject.analysis(for: compositionTrack.artworkURL)
            guard !Task.isCancelled else { return }
            coverSubject = subject
        }
        .environment(\.lyricAgentPresentationMap, LyricAgentPresentationMap(lines: liveOnly ? state.liveLyrics : state.lyrics))
        .environment(\.v3PlaybackInteractionChanged, playbackInteractionRelay)
        .environment(\.lyricIslandScene, compositionScene)
        .onReceive(state.objectWillChange) { _ in refreshForContentChange() }
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
        if isFocusMode {
            lyricsColumn(width: max(1, geometry.size.width - 64),
                         compact: isCompact(for: geometry.size), lyricsFocus: true)
                .padding(32)
        } else if let scene = compositionScene {
            switch scene {
            case .originalAmbient:
                if compositionShowsCover { foregroundArtworkLayout(in: geometry) }
                else { lyricsOnlyLayout(in: geometry, hidesArtwork: true) }
            case .flowingField:
                if compositionShowsCover { foregroundArtworkLayout(in: geometry) }
                else { fieldReadingLayout(in: geometry) }
            case .coverPhoto:
                photographicLayout(in: geometry)
            case .linerNotes:
                linerNotesLayout(in: geometry)
            case .focusedLyrics:
                lyricsOnlyLayout(in: geometry, hidesArtwork: !compositionShowsCover)
            }
        } else if compositionStyle == .lyricsOnly {
            lyricsOnlyLayout(in: geometry, hidesArtwork: !compositionShowsCover)
        } else if compositionStyle == .stage {
            stageTheaterLayout(in: geometry)
        } else {
            Group {
                if compositionShowsCover {
                    foregroundArtworkLayout(in: geometry)
                        .transition(reduceMotion ? .identity : .opacity)
                } else {
                    lyricsOnlyLayout(in: geometry, hidesArtwork: true)
                        .transition(reduceMotion ? .identity : .opacity)
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: compositionShowsCover)
        }
    }

    // Each new scene retains its reading architecture when its cover is hidden.
    // Only the selected branch is constructed: there are no five hidden lyric trees.
    private func fieldReadingLayout(in geometry: GeometryProxy) -> some View {
        let width = min(820, max(1, geometry.size.width - (geometry.size.width < 760 ? 48 : 80)))
        let footerHeight: CGFloat = isCompositionPreview || !settings.v3EdgeProgressEnabled ? 44 : 0
        let height = LyricIslandSceneBudget.fieldReadingHeight(canvasHeight: geometry.size.height,
                                                               footerHeight: footerHeight)
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text(compositionTrack.title).font(.system(size: 20, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 12)
                Text(compositionTrack.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: width, height: 28)
            lyricsColumn(width: width, compact: isCompact(for: geometry.size), lyricsFocus: false)
                .frame(width: width, height: height)
            if footerHeight > 0 { sceneTransport(width: min(420, width)) }
        }
        .padding(.top, 84).padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func photographicReadingPlacement(canvas: CGSize) -> V3ArtworkSubjectLayout.Placement {
        var subjects: [CGRect]?
        if let coverSubject {
            let complete = settings.v3BackgroundShowsCompleteArtwork(for: compositionStyle, scene: compositionScene)
            let scale = settings.v3PreviewBackdropScale(for: compositionStyle, scene: compositionScene)
            let effectiveScale = V3BackdropArtworkGeometry.imageScale(requested: scale, complete: complete)
            var rect: CGRect
            if compositionStyle == .stage && complete {
                rect = V3ResponsiveGeometry.stageArtworkRect(canvasSize: canvas,
                    artworkAspectRatio: coverSubject.imageSize.width / coverSubject.imageSize.height)
            } else {
                rect = V3BackdropArtworkGeometry.rect(canvas: canvas, artwork: coverSubject.imageSize,
                    scale: effectiveScale, complete: complete)
                if compositionStyle == .classicGaussian && !complete {
                    let offset = V3BackdropArtworkGeometry.horizontalOffset(width: canvas.width,
                        scale: scale, effectiveScale: effectiveScale, position: compositionArtworkPosition)
                    let overscan = max(0, (rect.width - canvas.width) / 2)
                    rect.origin.x += min(overscan, max(-overscan, offset))
                }
            }
            subjects = coverSubject.subjects(in: rect)
        }
        return V3ArtworkSubjectLayout.placement(subjects: subjects, canvas: canvas, manualPosition: compositionLyricsPosition)
    }

    private func photographicLayout(in geometry: GeometryProxy) -> some View {
        let compact = geometry.size.width < 760
        let placement = photographicReadingPlacement(canvas: geometry.size)
        let readingWidth = min(760, max(1, geometry.size.width * (compact ? 0.90 : placement.widthFraction)))
        let playerHeight: CGFloat = settings.v3EdgeProgressEnabled ? 0 : 44
        let readingHeight = max(1, min(geometry.size.height * 0.66 - 56,
            geometry.size.height - 76 - 32 - playerHeight - 12))
        let alignment: Alignment = placement.position == "left" ? .bottomLeading
            : placement.position == "center" ? .bottom : .bottomTrailing
        return ZStack(alignment: .topLeading) {
            HStack(spacing: 12) {
                if compositionShowsCover {
                    ArtworkView(track: compositionTrack, size: 44, showsAlbumLabel: false,
                                cornerRadiusRatio: 0.10, preservesCompleteArtwork: true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(compositionTrack.title).font(.system(size: 20, weight: .semibold)).lineLimit(1)
                    Text(compositionTrack.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: min(600, geometry.size.width - 48), alignment: .leading)
            .padding(.leading, compact ? 24 : 40).padding(.top, 76)
            VStack(spacing: 12) {
                lyricsColumn(width: readingWidth, compact: compact, stage: true)
                    .frame(width: readingWidth, height: readingHeight)
                    .clipped()
                sceneTransport(width: min(440, readingWidth))
            }
            .padding(.horizontal, compact ? 20 : 40).padding(.bottom, 32)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        }
    }

    private func linerNotesLayout(in geometry: GeometryProxy) -> some View {
        let compact = geometry.size.width < 840 || geometry.size.height < 640
        let margin: CGFloat = compact ? 24 : 46
        let contentWidth = max(1, geometry.size.width - margin * 2)
        let coverColumnWidth = min(290, contentWidth * 0.30)
        let textWidth = compact ? min(760, contentWidth) : max(1, contentWidth - coverColumnWidth - 36)
        // Keep the reading column stable while the cover changes, including 100–140%.
        // Reserving the maximum size avoids a slider dead zone or clipped artwork.
        let coverScale = min(1.4, max(0.8, CGFloat(compositionArtworkScale)))
        let coverSize = compact ? 64 * coverScale : coverColumnWidth / 1.4 * coverScale
        let headerHeight: CGFloat = compact ? 104 : 80
        let footerHeight: CGFloat = isCompositionPreview || !settings.v3EdgeProgressEnabled ? 44 : 0
        let readingHeight = LyricIslandSceneBudget.linerReadingHeight(
            canvasHeight: geometry.size.height, headerHeight: headerHeight, footerHeight: footerHeight)
        let heading = VStack(alignment: .leading, spacing: 6) {
            Text(compositionTrack.title)
                .font(.system(size: compact ? 24 : 32, weight: .medium, design: .serif))
                .lineLimit(2).minimumScaleFactor(0.8)
            Text(compositionTrack.artist)
                .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            Text(compositionTrack.album)
                .font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
        }
        return VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 18) {
                if compact && compositionShowsCover {
                    ArtworkView(track: compositionTrack, size: coverSize, showsAlbumLabel: false,
                                cornerRadiusRatio: 0.025, preservesCompleteArtwork: true)
                        .frame(width: 90, height: 90)
                }
                heading
                Spacer(minLength: 0)
            }
            .frame(height: headerHeight, alignment: .leading)
            Divider().frame(height: 1).overlay(Color.white.opacity(0.16))
            HStack(alignment: .top, spacing: 36) {
                if !compact && compositionShowsCover {
                    VStack(alignment: .leading, spacing: 16) {
                        ArtworkView(track: compositionTrack, size: coverSize,
                                    showsAlbumLabel: false, cornerRadiusRatio: 0.025, preservesCompleteArtwork: true)
                        Text("原文 · 译文 · 读音")
                            .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    }.frame(width: coverColumnWidth, alignment: .leading)
                }
                lyricsColumn(width: compositionShowsCover ? textWidth : min(840, contentWidth),
                             compact: compact, lyricsFocus: false)
                    .frame(maxWidth: compositionShowsCover ? textWidth : 840, maxHeight: .infinity)
                    .environment(\.lyricTextAlignment, .leading)
            }
            .frame(maxWidth: .infinity, minHeight: readingHeight, maxHeight: readingHeight, alignment: .leading)
            if footerHeight > 0 {
                sceneTransport(width: min(460, contentWidth))
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(width: contentWidth)
        .padding(.top, 76).padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func sceneTransport(width: CGFloat) -> some View {
        Group {
            if isCompositionPreview { compositionPreviewLabel }
            else if !settings.v3EdgeProgressEnabled {
                AppleMusicImmersiveV3FocusTransportControls(state: state, reduceMotion: reduceMotion)
                    .reportsV3PlaybackRegion()
                    .modifier(playbackVisibility)
            }
        }.frame(width: max(1, width), height: isCompositionPreview || !settings.v3EdgeProgressEnabled ? 44 : 0)
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
                onSearch: { librarySearch.open(.search) }
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
        let readingWidth = min(compositionScene == .focusedLyrics ? 760 : 940, max(1, geometry.size.width - (compact ? 56 : 112)))
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
                         onSearch: { librarySearch.open(.search) })
                .frame(width: readingWidth, height: lyricHeight)

            if footerHeight > 0 {
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
            HStack(alignment: .firstTextBaseline) {
                Text("ASTER · LYRIC · LISTENING EDITION")
                    .font(.system(size: 9, weight: .medium, design: .serif))
                    .tracking(1.1)
                    .foregroundStyle(.white.opacity(0.72))
                Spacer(minLength: 8)
                Text("SIDE A")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.58))
            }
            Rectangle().fill(.white.opacity(0.28)).frame(height: 1)

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

            Rectangle().fill(.white.opacity(0.18)).frame(height: 1)
            HStack(spacing: 6) {
                Capsule().fill(Color.accentColor.opacity(0.9)).frame(width: 18, height: 2)
                Capsule().fill(Color.accentColor.opacity(0.45)).frame(width: 10, height: 2)
                Text("ORIGINAL · TRANSLATION · READING")
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .tracking(0.4)
                    .foregroundStyle(.white.opacity(0.52))
            }
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
            showsAlbumLabel: false, cornerRadiusRatio: foregroundArtworkCornerRadiusRatio,
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
            lyricPosition: photographicReadingPlacement(canvas: geometry.size).position,
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
                    cornerRadiusRatio: foregroundArtworkCornerRadiusRatio,
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
        VStack(spacing: 8) {
        AppleMusicImmersiveV3LyricsViewport(
            state: state,
            availableWidth: max(1, width - (compact ? 22 : 34)),
            compact: compact,
            lyricsFocus: lyricsFocus,
            onSearch: liveOnly ? nil : onSearch,
            liveOnly: liveOnly,
            stage: stage
        )
        .equatable()
        .environmentObject(settings)
        .environment(\.v3PreviewPresentation, hoveredStyle)
        .environment(\.lyricIslandScene, compositionScene)
        .simultaneousGesture(MagnifyGesture()
            .onChanged { value in
                if pinchStartFontSize == nil { pinchStartFontSize = settings.displayPreferences.fontSize }
                let size = min(42, max(14, ((pinchStartFontSize! * value.magnification) / 2).rounded() * 2))
                if size != settings.displayPreferences.fontSize {
                    showLyricNotice(V3LyricActions(settings: settings).fontSize(size - settings.displayPreferences.fontSize))
                }
            }
            .onEnded { _ in pinchStartFontSize = nil })
        .v3ReadingGlow(artworkURL: compositionTrack.artworkURL, policy: compositionReadingProtection)
        .environment(\.v3ResolvedReadingProtection, compositionReadingProtection)
        .environment(\.lyricsCandidateBrightCover, coverLuminance > 0.6)
        .environment(\.lyricTextAlignment, compositionLyricsPosition == "center" ? .center : compositionLyricsPosition == "right" ? .trailing : .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay(alignment: .bottomLeading) {
            if let lyricNotice {
                HStack {
                    Text(lyricNotice)
                    if lyricNotice == "需要连接 Spotify" {
                        Button("打开连接设置") {
                            SettingsNavigationRoute.shared.requestConnectionSettings()
                            openAppSettings()
                        }
                    }
                }
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .fixedSize()
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !isFocusMode, let selection = previewAutomaticSelection ?? state.liveLyricsAutomaticSelection,
               selection.durationDelta >= 0.5 {
                let seconds = Int(selection.durationDelta.rounded())
                Button {
                    openLyricsLibrary()
                } label: {
                    Text("自动选择 · 时长与 Spotify 相差 \(seconds) 秒")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                        .shadow(color: .black.opacity(0.35), radius: 2, y: 0.5)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("查看这首歌的其他版本")
                .accessibilityLabel("自动选择，时长与 Spotify 相差 \(seconds) 秒；打开版本列表")
            }
        }
    }

    private func openLyricsLibrary() {
        librarySearch.open(.library)
    }

    private func handleListeningKey(_ key: V3ListeningKey) {
        switch key {
        case .playPause: state.togglePlayPause(); showLyricNotice(state.isPlaying ? "播放" : "暂停")
        case .previous: state.previousTrack(); showLyricNotice("上一首")
        case .next: state.nextTrack(); showLyricNotice("下一首")
        case .like: state.toggleTrackLike(fromKeyboard: true)
        case .offset(let delta):
            let store = settings.lyricsOffsetStore
            if store.setActiveValue(store.activeOffset + delta) {
                showLyricNotice(String(format: "偏移 %+.1fs", store.activeOffset))
            } else { showLyricNotice("当前没有已保存歌词") }
        case .resetOffset:
            _ = settings.lyricsOffsetStore.resetActiveValue(); showLyricNotice("偏移归零")
        case .blurFine(let delta):
            settings.v3BackdropBlurRadius = min(100, max(0, settings.v3BackdropBlurRadius + delta))
            showLyricNotice("模糊 \(Int(settings.v3BackdropBlurRadius))%")
        case .blurCycle:
            settings.v3BackdropBlurRadius = V3LyricActions.nextBlurPreset(after: settings.v3BackdropBlurRadius)
            showLyricNotice("模糊 \(Int(settings.v3BackdropBlurRadius))%")
        case .focus:
            isFocusMode.toggle(); dismissPinnedToolbarPanel()
            showLyricNotice(isFocusMode ? "专注模式" : "退出专注模式")
        case .help: showsListeningKeys.toggle(); showLyricNotice(showsListeningKeys ? "全部按键" : "关闭按键说明")
        case .escape:
            showsListeningKeys = false; isFocusMode = false; dismissPinnedToolbarPanel()
            showLyricNotice("返回听歌")
        }
    }

    private var listeningKeyList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("听歌按键").font(.headline); Spacer(); Button("关闭") { showsListeningKeys = false } }
            ForEach(["空格 · 播放 / 暂停", "A / D · 上一首 / 下一首", "S · 喜欢，再按移除", "Z / C · 偏移 −0.1s / +0.1s", "X · 偏移归零", "/ · 模糊 0 / 25 / 50 / 75 / 100%", ", / . · 模糊 −5% / +5%", "F · 专注模式", "Shift + / · 全部按键", "Esc · 关闭面板 / 退出专注"], id: \.self) { Text($0) }
        }
        .padding(22).frame(width: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private func showLyricNotice(_ message: String?) {
        guard let message else { return }
        lyricNoticeTask?.cancel()
        withAnimation(.easeOut(duration: 0.15)) { lyricNotice = message }
        lyricNoticeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { lyricNotice = nil }
        }
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

    private func translationControls(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if !compact { Label("AI 与读音", systemImage: "sparkles").font(.headline) }
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
            Divider()
            TranslationProviderControls(settings: settings).modelPicker
            TranslationProviderControls(settings: settings).reasoningPicker
            if displaysAIReadingControls {
                aiReadingControls(compact: compact)
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
            if case .loading = state.translationState {
                HStack {
                    ProgressView("翻译中…").controlSize(.small)
                    Button("取消") { state.cancelTranslation() }
                }
            } else {
                HStack {
                    Button("翻译整首") { state.translateCurrentLyrics() }
                    Button("重新翻译") { state.retranslateCurrentLyrics() }
                }
                .disabled(!allowsTranslationRequests || !settings.aiTranslationConfiguration.isConfigured || state.liveLyrics.isEmpty)
            }
            if case .failed = state.translationState {
                Label(state.translationState.userFacingMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            } else if !state.translationProgressMessage.isEmpty {
                Text(state.translationProgressMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !compact && !allowsTranslationRequests {
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
        .frame(maxWidth: .infinity, alignment: .leading)
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

    private func aiReadingControls(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("本地自动生成读音", isOn: Binding(
                get: { settings.readingPreferences.automaticGeneration },
                set: { enabled in
                    var next = settings.readingPreferences
                    next.automaticGeneration = enabled
                    settings.readingPreferences = next
                }
            ))
            if !compact { Text("本地生成不调用 AI。可在设置 → 读音调整自动生成与人工词典。")
                .font(.caption).foregroundStyle(.secondary) }
            Toggle("使用 AI 优化读音", isOn: Binding(
                get: { settings.readingPreferences.aiAssistedCandidate },
                set: { enabled in
                    var next = settings.readingPreferences
                    next.aiAssistedCandidate = enabled
                    settings.readingPreferences = next
                }
            ))
            if !compact { Text("关闭恢复本地读音；人工修改、锁定读音和已保存版本保留。")
                .font(.caption).foregroundStyle(.secondary) }
            if settings.readingPreferences.aiAssistedCandidate {
                Toggle("新歌词自动优化", isOn: readingBinding(\.automaticAIOptimization))
                    .disabled(!allowsAutomaticTranslation || !settings.aiTranslationConfiguration.isConfigured
                        || !AIReadingCandidateService.supports(engineID: settings.aiTranslationConfiguration.engineID))
                if !compact { Text("新歌词就绪后自动优化并使用；优先复用已保存的 AI 读音，保留人工修改和锁定读音。仅处理不确定读音，可能产生模型费用。")
                    .font(.caption).foregroundStyle(.secondary) }
            }
            HStack {
                Button("本地生成") { state.generateCurrentReading() }
                    .disabled(!canGenerateReadingHere || state.isReadingGenerating)
                Button("AI 优化当前歌词…", systemImage: "sparkles") { confirmsAIReadingRequest = true }
                    .disabled(aiReadingRequestDisabledReason != nil)
            }
            if !compact, let reason = aiReadingRequestDisabledReason {
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

    /// Three quiet levels: gone while the pointer is outside the window, a
    /// faint resting toolbar while it is inside (so tools are discoverable
    /// without covering the lyrics), and full contrast near the top edge or
    /// while a panel is open. Positions never change between levels.
    private var toolbarOpacity: Double {
        isFocusMode ? 0 : toolbar.opacity(pointerInside: isPointerInsideCanvas && !liveOnly, nearTop: toolsVisible,
                        otherPanelOpen: toolbarPanelIsPresented)
    }

#if DEBUG
    private func applyToolbarDebugCommand(_ info: [AnyHashable: Any]) {
        let panel = (info["panel"] as? String).flatMap(ToolbarPopover.init(rawValue:))
        switch info["command"] as? String {
        case "navigation":
            librarySearch.open(info["panel"] as? String == "search" ? .search : .library)
        case "notice": lyricNotice = "字号 22"
        case "auto-selection": previewAutomaticSelection = LyricsAutomaticSelection(sourceCount: 3, durationDelta: 25)
        case "faint": isPointerInsideCanvas = true
        case "full": isPointerInsideCanvas = true; toolsVisible = true
        case "hover": if let panel { toolsVisible = true; apply(toolbar.pointerOnTrigger(panel, inside: true)) }
        case "pin": if let panel { toolsVisible = true; clickToolbarPanel(panel) }
        default: break
        }
    }
#endif

    private var toolbarPanelIsPresented: Bool {
        isWindowMenuPresented || isVersionPickerPresented
            || activeToolbarPopover != nil || pinnedToolbarPanel != nil || librarySearch.isPresented
    }

    /// Every panel-button click, whichever path delivered it.
    private func clickToolbarPanel(_ panel: ToolbarPopover) {
        V3ToolbarLog.logger.notice("click \(panel.description, privacy: .public) mode-before=\(String(describing: toolbar.mode), privacy: .public)")
        toolbarDismissTask?.cancel()
        isWindowMenuPresented = false
        if panel == .library || panel == .search {
            toolbar.dismiss()
            librarySearch.toggle(panel == .library ? .library : .search)
        } else {
            librarySearch.dismiss()
            toolbar.click(panel)
        }
    }

    private func dismissPinnedToolbarPanel() {
        librarySearch.dismiss()
        toolbarDismissTask?.cancel()
        toolbar.dismiss()
    }

    private func toolbarTriggerHover(_ panel: ToolbarPopover, inside: Bool) {
        guard !librarySearch.isPresented else { return }
        apply(toolbar.pointerOnTrigger(panel, inside: inside))
    }

    private func apply(_ effect: V3ToolbarModel.Effect) {
        switch effect {
        case .none: break
        case .cancelHoverDismissal: toolbarDismissTask?.cancel()
        case .scheduleHoverDismissal(let panel):
            toolbarDismissTask?.cancel()
            toolbarDismissTask = Task { @MainActor in
                try? await Task.sleep(for: V3ToolbarModel.hoverGrace)
                guard !Task.isCancelled else { return }
                toolbar.dismissTimerFired(panel)
            }
        }
    }

    /// Side effects of any toolbar mode change, kept in one place.
    private func toolbarModeChanged(from old: V3ToolbarModel.Mode, to new: V3ToolbarModel.Mode) {
        hoveredStyle = nil
        if toolbar.hoverPanel == nil || toolbar.hoverPanel == .more { hoveredAIReadingControls = nil }
        if new != .idle {
            isWindowMenuPresented = false
            librarySearch.dismiss()
        } else {
            toolbarDismissTask?.cancel()
        }
    }

    private func hoverTrackedPanel<Content: View>(_ panel: ToolbarPopover, @ViewBuilder content: () -> Content) -> some View {
        content()
            .buttonStyle(.automatic)
            .onHover { inside in apply(toolbar.pointerInPanel(panel, inside: inside)) }
            .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
                if activeToolbarPopover == panel { apply(toolbar.menuTrackingBegan()) }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in
                apply(toolbar.menuTrackingEnded())
            }
    }

    private func toolbarPopoverBinding(_ panel: ToolbarPopover) -> Binding<Bool> {
        Binding(get: { activeToolbarPopover == panel }, set: { presented in
            if presented { apply(toolbar.pointerOnTrigger(panel, inside: true)) }
            else { toolbar.hoverClosed(panel) }
        })
    }

    private func toolBar(for size: CGSize) -> some View {
        HStack(spacing: 3) {
            ForEach(ToolbarPopover.allCases, id: \.rawValue) { panel in
                toolbarPanelButton(panel)
            }

            // Global, low-frequency settings sit at the trailing end, apart
            // from the listening tools.
            Rectangle().fill(Color.white.opacity(0.18)).frame(width: 1, height: 18)
                .padding(.horizontal, 2)
            Button(action: openAppSettings) {
                toolbarEntry("设置", symbol: "gearshape")
            }
            .v3FirstClick(openAppSettings)
            .help("应用设置与 AI 服务")
        }
        .buttonStyle(QuietToolbarButtonStyle())
        // The window's first focusable control otherwise wears a focus ring
        // whenever the window becomes key, which reads as a stuck selection.
        .focusEffectDisabled()
        .environment(\.lyricIslandCompactTools, size.width < 720)
        .padding(5)
        .background(.regularMaterial.opacity(0.78), in: Capsule())
        .background(GeometryReader { geometry in
            Color.clear.preference(key: V3ToolbarFramePreferenceKey.self,
                value: geometry.frame(in: .named("v3-window-canvas")))
        })
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 0.7))
        .shadow(color: Color.black.opacity(0.12), radius: 12, x: 0, y: 4)
        .onChange(of: toolbar.mode) { old, new in toolbarModeChanged(from: old, to: new) }
        .onDisappear { toolbarDismissTask?.cancel(); hoveredStyle = nil }
    }

    private func openAppSettings() {
        toolbar.click()
        librarySearch.dismiss()
        if liveOnly { MenuBarLyricsController.shared.openSettings() }
        else { openSettings() }
    }

    private func toolbarPanelButton(_ panel: ToolbarPopover) -> some View {
        toolbarPanelTrigger(panel)
    }

    private func toolbarPanelTrigger(_ panel: ToolbarPopover) -> some View {
        Button { clickToolbarPanel(panel) } label: {
            toolbarEntry(panel.title, symbol: panel.symbol, selected: toolbar.isSelected(panel) || librarySearch.tab?.rawValue == panel.rawValue)
        }
        .v3FirstClick { clickToolbarPanel(panel) }
        .help(panel == .picture ? "画面 · / 五档模糊，, / . 微调模糊" : panel == .more ? "更多 · Z / C 调整偏移，X 归零" : panel.title)
        .onHover { inside in
            toolbarTriggerHover(panel, inside: inside)
        }
        .v3ToolPopover(isPresented: toolbarPopoverBinding(panel), onAnchorPress: { clickToolbarPanel(panel) }) {
            hoverTrackedPanel(panel) { inspectorSurface(for: panel, style: .hoverGlass) }
        }
    }

    private func toolbarPanel(for panel: ToolbarPopover) -> some View {
        V3ToolbarQuickControls(panel: panel, state: state, search: state.songSearchManager,
            openLibrary: { clickToolbarPanel(.library) }, openSearch: { clickToolbarPanel(.search) }) {
            switch panel {
            case .translation: translationControls(compact: true)
            case .text: visualControls.textPage
            case .picture:
                V3ThemeSelectorView(settings: settings, artworkURL: state.currentTrack.artworkURL,
                    preview: $hoveredStyle, previewScene: $hoveredScene,
                    onConfirm: {}, compact: true)
                visualControls.blurControls
                Toggle(settings.v3ListeningScene == .focusedLyrics || settings.v3ListeningScene == .coverPhoto
                       ? "显示歌曲缩略图" : "显示前景封面", isOn: $settings.v3ShowForegroundArtwork)
                visualControls.playbackPresentationControls
                visualControls.backgroundMotionControls
                DisclosureGroup("更多画面选项", isExpanded: $settings.v3PictureAdvancedExpanded) {
                    visualControls.pictureAdvancedControls(showsExplanations: false)
                }
            case .more:
                LyricsPresentationOffsetControl(settings: settings, showsLegacyNotice: false, showsExplanations: false)
                Divider()
                windowModePanel
                Divider()
                desktopInteractionPanel
                Button("恢复歌词时间") { settings.lyricsOffsetStore.resetActiveValue() }
            case .library, .search: EmptyView()
            }
        }
    }

    private var visualControls: V3VisualControls { V3VisualControls(settings: settings) }

    private func toolbarEntry(_ title: String, symbol: String, selected: Bool = false) -> some View {
        Label(title, systemImage: symbol)
            .labelStyle(LyricIslandToolbarLabelStyle())
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(0.94))
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(selected ? Color.white.opacity(0.14) : .clear, in: Capsule())
            .contentShape(Capsule())
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
            if !liveOnly {
                Toggle("桌面歌词", isOn: Binding(get: { state.showFloatingWindow }, set: { _ in
                    WindowManager.shared.toggleFloatingLyrics(state: state)
                }))
                Toggle("顶部胶囊", isOn: Binding(get: { state.showCapsulePlayer }, set: { _ in
                    WindowManager.shared.toggleCapsule(state: state)
                }))
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
            Divider()
            toolbarAction(liveOnly ? "退出全屏" : "全屏歌词", symbol: "arrow.up.left.and.arrow.down.right") {
                WindowManager.shared.toggleFullScreen(state: state, settings: settings)
                isWindowMenuPresented = false
            }

        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var desktopInteractionPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !liveOnly {
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

    private func inspectorSurface(for panel: ToolbarPopover, style: InspectorSurfaceStyle) -> some View {
        VStack(spacing: 0) {
            toolbarPanel(for: panel)
        }
        .frame(width: 360, alignment: .topLeading)
        .tint(coverAccent)
        .accentColor(coverAccent)
        .background {
            switch style {
            case .hoverGlass:
                Rectangle().fill(.regularMaterial)
            case .pinnedSolid:
                Color(nsColor: .windowBackgroundColor)
            }
        }
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(style == .hoverGlass ? Color.white.opacity(0.12) : Color.primary.opacity(0.10))
                .frame(width: 1)
        }
        .onExitCommand { dismissPinnedToolbarPanel() }
    }

    private func sectionEyebrow(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .tracking(1.1)
            .foregroundStyle(.secondary)
    }

    private func openAISettings() {
        SettingsNavigationRoute.shared.requestAISettings()
        if liveOnly { MenuBarLyricsController.shared.openSettings() }
        else { openSettings() }
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
