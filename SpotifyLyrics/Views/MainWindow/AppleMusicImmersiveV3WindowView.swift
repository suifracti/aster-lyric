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
    /// Siblings that do not report still pass the default to reduce; letting
    /// them overwrite the toolbar's frame left the edge player seeing an
    /// empty toolbar, so it could sit on top of it.
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if !next.isEmpty { value = next }
    }
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
    /// 侧拉: how close to the right edge opens the column (and keeps it open).
    static let sideToolbarRevealWidth: CGFloat = 76
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
/// Holds the library service without republishing its changes.
@MainActor
final class V3LibraryOwner: ObservableObject {
    let service = PersonalLyricsLibraryService()
    let browsing = PersonalLibraryBrowsing()
}

/// separate layouts; this view owns only the V3 canvas and its transient tools.
struct AppleMusicImmersiveV3WindowView: View, Equatable {
    let state: PlaybackState
    /// The window owns the library service but does not observe it: none of
    /// its body reads the service, and observing it re-evaluated the whole
    /// window (lyrics included) on every library list, status or selection
    /// change. The panels that show library data observe it themselves.
    @StateObject private var libraryOwner = V3LibraryOwner()
    private var library: PersonalLyricsLibraryService { libraryOwner.service }
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
    private var displaysAIReadingControls: Bool { showsAIReadingControls }
    @State private var confirmsAIReadingRequest = false
    @State private var openingTranslationComparison = false
    @State private var isVersionPickerPresented = false
    @State private var pinchStartFontSize: CGFloat?
    private struct CoverColors {
        let url: URL
        let accent: Color?
        let luminance: Double
        var automaticAmbient: V3SceneFamily.Entry?
    }
    @State private var coverColors: CoverColors?
    private var displayedCoverColors: CoverColors? { coverColors?.url == compositionTrack.artworkURL ? coverColors : nil }
    private var coverAccent: Color? { displayedCoverColors?.accent }
    private var coverLuminance: Double { displayedCoverColors?.luminance ?? 0 }
    @ObservedObject private var backdropBrightness = V3BackdropBrightness.shared
    /// How bright the picture behind the lyrics is: a playing Canvas clip (under its
    /// own 26% veil) when one is shown, else the cover.
    private var backgroundLuminance: Double {
        backdropBrightness.clipLuminance.map { $0 * 0.74 } ?? coverLuminance
    }
    /// 亮背景: a quiet darkening of a bright picture so white and coloured lyrics both read.
    private var brightBackgroundScrim: Double {
        guard settings.v3BrightCoverShadowEnabled, !isCompositionPreview else { return 0 }
        return min(0.45, max(0, (backgroundLuminance - 0.35) * 1.1))
    }
    @State private var analyzedCover: (url: URL, subject: V3ArtworkSubject.Analysis)?
    private var subjectArtworkURL: URL? { usesArtworkSubjectPlacement ? compositionTrack.artworkURL : nil }
    @State private var showsListeningKeys = false
    @State private var windowVisible = false
    @State private var isFocusMode = false
    @State private var librarySearch = V3LibrarySearchPresentation()
    @State private var toolbarBounds = CGRect.zero
    @State private var foregroundCover: V3ForegroundCoverFrame?
    /// 情境 being tried from its panel; the saved scene otherwise.
    @State private var scenePreview: V3Room?
    @State private var sceneBPM: Double?
    @ObservedObject private var sceneWeather = V3WeatherWatcher.shared
    @State private var lyricNotice: String?
    @State private var lyricNoticeTask: Task<Void, Never>?
    /// Visual-host preview only; real playback fills this from the session.
    @State private var previewAutomaticSelection: LyricsAutomaticSelection?
    @State private var hoveredStyle: V3ArtworkPresentation?
    @State private var hoveredScene: V3ListeningScene?
    private var presentation: V3ListeningPresentation { resolvedPresentation() }

    private func resolvedPresentation(includeArtworkPreview: Bool = true) -> V3ListeningPresentation {
        V3ListeningPresentation(settings: settings, room: activeScene, accent: coverAccent ?? .white,
                                usesSavedRoomChoices: scenePreview == nil || scenePreview == settings.v3Room,
                                artworkPreview: includeArtworkPreview ? hoveredStyle : nil, previewScene: hoveredScene,
                                automaticAmbient: displayedCoverColors?.automaticAmbient)
    }
    private var compositionScene: V3ListeningScene? { presentation.scene }
    private var compositionStyle: V3ArtworkPresentation { presentation.renderer }
    private var compositionPlayback: V3PlaybackPresentation { presentation.playback }
    private var scenePlayerHidden: Bool { compositionPlayback.hidesScenePlayer }
    private var lyricWidthScale: CGFloat { CGFloat(presentation.lyricWidth) }
    private var compositionLyricsPosition: String { presentation.lyricsPosition }
    /// 环境光's two scenes, where 光随歌曲 applies.
    private var usesAmbientLight: Bool {
        compositionScene == .originalAmbient || (compositionScene == .flowingField && compositionStyle == .ambientFeathered)
    }
    private var compositionShowsCover: Bool {
        !compositionPlayback.replacesSceneCover
            && settings.v3ShowsForegroundArtwork(scene: compositionScene, renderer: compositionStyle)
    }
    private var compositionArtworkPosition: String { settings.v3PreviewPosition(for: compositionStyle, scene: compositionScene) }
    private var usesArtworkSubjectPlacement: Bool {
        compositionScene == .coverPhoto || (compositionScene == nil && compositionStyle == .stage)
    }
    private var compositionArtworkScale: Double { settings.v3PreviewScale(for: compositionStyle, scene: compositionScene) }
    /// 清晰度 resolved once per composition so the bright-cover automatic
    /// shadow (封面 and 舞台 with a bright cover) applies everywhere at once.
    private var compositionReadingProtection: V3ReadingProtection {
        settings.v3EffectiveReadingProtection(scene: compositionScene,
                                              renderer: compositionStyle,
                                              coverLuminance: backgroundLuminance)
    }
    private typealias ToolbarPopover = V3ToolbarModel.Panel
    private enum InspectorSurfaceStyle: Equatable { case hoverGlass, pinnedGlass }
    /// All toolbar/panel decisions live in this value; see V3ToolbarModel.
    @State private var toolbar = V3ToolbarModel()
    @State private var toolbarDismissTask: Task<Void, Never>?
    private var activeToolbarPopover: ToolbarPopover? { toolbar.hoverPanel }
    private var pinnedToolbarPanel: ToolbarPopover? { toolbar.pinnedPanel }
    private var toolbarStyle: V3ToolbarStyle {
        let saved = settings.v3ToolbarStyle
        return liveOnly && saved == .outside ? .standard : saved
    }
    // Keep listening unobstructed. Tools reveal at the top edge and stay
    // available while their popover is open.
    @State private var toolsVisible = false
    @State private var radialToolbarOpen = false
    @State private var radialToolbarCloseTask: Task<Void, Never>?
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
        guard !scenePlayerHidden else { return false }
        return V3ResponsiveGeometry.playbackDetailsVisible(
            hoverOnly: compositionPlayback == .onHover,
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
        V3PlaybackVisibility(visible: isCompositionPreview || playbackDetailsVisible, reduceMotion: reduceMotion)
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

    private var compositionTrack: Track { liveOnly ? state.currentTrack : state.displayedTrack }
    private var isCompositionPreview: Bool { !liveOnly && state.isShowingSearchPreview }
    private var lyricsOffsetTarget: LyricsPresentationOffsetTarget { .listening(isPreview: isCompositionPreview) }
    private var compositionLyrics: [LyricLine] { liveOnly ? state.liveLyrics : state.lyrics }
    private var compositionIndex: Int? { liveOnly ? state.liveCurrentLineIndex : state.currentLineIndex }
    private var compositionSynchronized: Bool { liveOnly ? state.liveLyricsAreSynchronized : state.lyricsAreSynchronized }

    private var liveVocalOnsets: [TimeInterval] {
        guard !liveOnly, settings.v3MusicMotionEnabled, state.liveLyricsAreSynchronized,
              let index = state.liveCurrentLineIndex, state.liveLyrics.indices.contains(index) else { return [] }
        return V3VocalOnsets.onsets(of: state.liveLyrics[index])
    }

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
                let isInst = !isCompositionPreview && state.liveTrackIsMarkedInstrumental
                AppleMusicImmersiveV3BackdropView(
                    track: compositionTrack,
                    identity: isCompositionPreview ? nil : state.currentTrackIdentity,
                    isInstrumental: isInst,
                    isPlaying: state.isPlaying,
                    settings: settings,
                    artworkPresentation: compositionStyle,
                    listeningScene: compositionScene,
                    ambientTreatment: presentation.ambientTreatment,
                    isArtworkPreview: hoveredStyle != nil,
                    isDocumentPreview: isCompositionPreview,
                    clock: state.presentationClock,
                    inChorus: settings.v3ChorusEmphasis && chorusNow,
                    chorusSwapsMaterial: settings.v3ChorusSwapsMaterial && chorusNow
                )
                // An aspect-fill album image can report the square image's
                // width in a tall window. Keep that drawing overflow inside
                // the canvas so it cannot shift the top-trailing foreground.
                .frame(width: geometry.size.width, height: geometry.size.height)
                .modifier(V3BackdropAmbience(parallax: settings.v3BackdropParallax && !isFocusMode,
                                             dayTint: settings.v3DayTint))
                .blur(radius: librarySearch.isPresented ? 5 : 0)

                // 亮背景: darken a bright picture just enough for the lyrics; the foreground cover is untouched.
                Color.black.opacity(brightBackgroundScrim)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .allowsHitTesting(false)
                    .animation(.easeInOut(duration: 0.8), value: brightBackgroundScrim)

                if settings.v3AmbientLyricMotion != .off, usesAmbientLight, !isFocusMode, !isCompositionPreview {
                    V3AmbientMotionLayer(state: state, motion: settings.v3AmbientLyricMotion,
                                         artworkURL: compositionTrack.artworkURL)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
                // A 情境 brings its own weather; the two never stack.
                if (settings.v3GlassWeather != .off || settings.v3LyricImagery), hoveredStyle == nil, activeScene == .off {
                    V3GlassWeatherLayer(weather: settings.v3GlassWeather,
                                        imagery: settings.v3LyricImagery ? currentLyricImagery : nil,
                                        playing: state.isPlaying)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .blur(radius: librarySearch.isPresented ? 5 : 0)
                }
                if settings.v3EdgeLights, settings.v3MusicMotionEnabled, hoveredStyle == nil, !reduceMotion {
                    V3EdgeLights(accent: coverAccent ?? .white, running: state.isPlaying && windowVisible)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
                if settings.v3SpectrumStyle != .off, hoveredStyle == nil, !isFocusMode {
                    V3SpectrumOverlay(style: settings.v3SpectrumStyle,
                                      running: state.isPlaying && settings.v3MusicMotionEnabled,
                                      accent: coverAccent ?? .white,
                                      cover: foregroundCover.flatMap { $0.isLargeEnough ? $0.frame : nil })
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .blur(radius: librarySearch.isPresented ? 5 : 0)
                }
                if compositionPlayback == .vinyl, !isFocusMode, let cover = foregroundCover, cover.isLargeEnough {
                    V3VinylDiscLayer(state: state, cover: cover.frame, accent: coverAccent ?? .white)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .blur(radius: librarySearch.isPresented ? 5 : 0)
                }
                if activeScene != .off {
                    V3SceneBackLayer(scene: activeScene, context: roomContext, playing: state.isPlaying,
                                     speed: (sceneBPM ?? 110) / 110)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .blur(radius: librarySearch.isPresented ? 5 : 0)
                        .id(activeScene)
                        .transition(.opacity.animation(.easeInOut(duration: 0.8)))
                }

                GeometryReader { canvasGeometry in
                    layout(for: canvasGeometry)
                        .frame(width: canvasGeometry.size.width, height: canvasGeometry.size.height)
                }
                // 起雾的窗 and 水面 follow the pointer; nothing re-renders for it.
                .onContinuousHover(coordinateSpace: .local) { phase in
                    guard activeScene == .fog || activeScene == .water else { return }
                    if case .active(let point) = phase { V3SceneInput.shared.pointer(point, scene: activeScene) }
                }
                .frame(width: canvasWidth, height: geometry.size.height)
                .frame(maxWidth: .infinity, alignment: .leading)
                .blur(radius: librarySearch.isPresented ? 5 : 0)
                .allowsHitTesting(!librarySearch.isPresented)

                if V3PlaybackPresentation.additions.contains(compositionPlayback),
                   !isFocusMode, !librarySearch.isPresented, !isCompositionPreview {
                    V3PlaybackStyleOverlay(state: state, settings: settings,
                                           presentation: compositionPlayback,
                                           cover: foregroundCover, accent: uiAccent)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }

                if settings.v3CoverRimLight, settings.v3MusicMotionEnabled, hoveredStyle == nil, !reduceMotion,
                   let cover = foregroundCover, cover.isLargeEnough {
                    V3CoverRimLight(cover: cover, accent: coverAccent ?? .white, running: state.isPlaying && windowVisible)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
                if settings.v3CoverCaption, hoveredStyle == nil, !librarySearch.isPresented,
                   let cover = foregroundCover, cover.isLargeEnough {
                    let index = compositionSynchronized ? compositionIndex : nil
                    V3CoverCaption(cover: cover,
                                   text: index.flatMap { compositionLyrics.indices.contains($0) ? compositionLyrics[$0].originalText : nil },
                                   lineIndex: index)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }

                if activeScene != .off, !librarySearch.isPresented {
                    Group {
                        V3SceneCoverLayer(scene: activeScene, context: roomContext,
                                          cover: foregroundCover.flatMap { $0.isLargeEnough ? $0.frame : nil },
                                          player: playbackRegion)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                        V3SceneGlassLayer(scene: activeScene, context: roomContext, playing: state.isPlaying,
                                          cover: foregroundCover.flatMap { $0.isLargeEnough ? $0.frame : nil })
                            .frame(width: geometry.size.width, height: geometry.size.height)
                    }
                    .id(activeScene)
                    .transition(.opacity.animation(.easeInOut(duration: 0.8)))
                }

                if settings.v3PlayerProgressOnCover, !scenePlayerHidden, !isFocusMode, !isCompositionPreview,
                   let cover = foregroundCover, cover.isLargeEnough {
                    V3CoverEdgeProgress(state: state, cover: cover, accent: uiAccent ?? .white)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .blur(radius: librarySearch.isPresented ? 5 : 0)
                }

                if compositionPlayback == .windowEdge && !isFocusMode && !librarySearch.isPresented && !isCompositionPreview {
                    V3WindowEdgePlaybackOverlay(
                        state: state,
                        colorHex: settings.v3EdgeProgressColorHex,
                        colorMode: settings.v3EdgeProgressColorMode,
                        coverLuminance: coverLuminance,
                        coverAccent: coverAccent ?? .white,
                        exitPoint: lastWindowExitPoint,
                        pointerInsideWindow: isPointerInsideCanvas,
                        // Priority: an open panel, then the toolbar, then the edge.
                        suppressControls: toolbar.suppressesEdgeControls(nearTop: false, otherPanelOpen: toolbarPanelIsPresented),
                        toolbarBounds: toolbarBounds,
                        haloTarget: foregroundCover
                    )
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }

                if librarySearch.isPresented {
                    V3LibrarySearchPanel(presentation: $librarySearch, state: state, library: library,
                                         search: state.songSearchManager, browsing: libraryOwner.browsing)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }

                if toolbarStyle == .outside {
                    // 窗外: the bar lives in its own small window above this
                    // one; nothing of it is drawn over the listening view.
                    V3OutsideToolbarHost(
                        keepVisible: toolbarPanelIsPresented || pinnedToolbarPanel != nil,
                        content: toolBar(for: geometry.size))
                        .frame(width: 0, height: 0)
                }
                if toolbarStyle == .sidePull {
                    // 侧拉: a column at the right edge, centred, sliding in from outside.
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        toolBar(for: geometry.size)
                            .opacity(toolbarOpacity)
                            .offset(x: toolbarOpacity < 1 ? 72 : 0)
                            .allowsHitTesting(toolbarOpacity > 0)
                            .accessibilityHidden(toolbarOpacity == 0)
                            .animation(LyricsDesignTokens.Motion.animation(reduceMotion: reduceMotion), value: toolbarOpacity)
                    }
                    .padding(.trailing, 14)
                    .frame(maxHeight: .infinity)
                }
                if toolbarStyle != .outside && toolbarStyle != .sidePull {
                HStack(spacing: 16) {
                    if toolbarStyle != .titleBar { Spacer(minLength: 0) }
                    toolBar(for: geometry.size)
                        .opacity(toolbarOpacity)
                        .offset(y: toolbarStyle == .pullDown && toolbarOpacity < 1 ? -64 : 0)
                        .allowsHitTesting(toolbarOpacity > 0)
                        .accessibilityHidden(toolbarOpacity == 0)
                        .animation(
                            LyricsDesignTokens.Motion.animation(reduceMotion: reduceMotion),
                            value: toolbarOpacity
                        )
                    if toolbarStyle == .titleBar { Spacer(minLength: 0) }
                }
                // 标题栏 sits beside the window buttons; the others at the top right.
                .padding(.leading, toolbarStyle == .titleBar ? 76 : 24)
                .padding(.trailing, toolbarStyle == .radial ? 12 : 24)
                .padding(.top, toolbarStyle == .titleBar ? 3 : toolbarStyle == .radial ? 10 : 18)
                }

                if let pinned = pinnedToolbarPanel {
                    if liveOnly {
                        let side = toolbarStyle == .sidePull
                        inspectorSurface(for: pinned, style: .hoverGlass)
                            .modifier(V3SystemAppearanceModifier())
                            .padding(.top, side ? 0 : toolbarBounds.maxY + 8)
                            .padding(.trailing, side ? toolbarBounds.width + 24 : 24)
                            .frame(maxWidth: .infinity, maxHeight: .infinity,
                                   alignment: side ? .trailing : .topTrailing)
                    } else {
                        V3PinnedInspectorPanelHost(
                            isPresented: Binding(
                                get: { pinnedToolbarPanel != nil },
                                set: { presented in
                                    if !presented { dismissPinnedToolbarPanel() }
                                }
                            ),
                            title: pinned.title,
                            content: inspectorSurface(for: pinned, style: .pinnedGlass)
                        )
                        .frame(width: 0, height: 0)
                    }
                }

            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .coordinateSpace(name: "v3-window-canvas")
            .onPreferenceChange(V3ToolbarFramePreferenceKey.self) { frame in
                if toolbarBounds != frame { toolbarBounds = frame }
            }
            .onPreferenceChange(V3ForegroundCoverPreferenceKey.self) { cover in
                if foregroundCover != cover { foregroundCover = cover }
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
                    // 侧拉 opens from the right edge; every other style from the top.
                    let inToolbar = toolbarStyle == .sidePull
                        ? location.x >= geometry.size.width - MainWindowResponsiveThresholds.sideToolbarRevealWidth
                        : location.y <= MainWindowResponsiveThresholds.toolbarRevealHeight
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
            .modifier(V3SceneDriver(scene: settings.v3Room, context: roomContext,
                                    weatherVisible: windowVisible && !isFocusMode && !isCompositionPreview,
                                    bpm: $sceneBPM))
            .environment(\.v3WindowVisible, windowVisible)
            .environment(\.v3SceneChrome, presentation.chrome)
            .onChange(of: liveVocalOnsets, initial: true) { _, onsets in
                if !liveOnly { V3VocalOnsets.current = onsets }
            }
            .onChange(of: toolbarPanelIsPresented) { _, presented in
                if !presented && !isPointerInToolbarRegion { toolsVisible = false }
            }
            .onExitCommand(perform: handleExitCommand)
            .onChange(of: settingsRoute.requestedToolbarPanel, initial: true) { _, panel in
                guard !liveOnly, let panel else { return }
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
            .background(alignment: .topLeading) {
                V3WindowVisibilityProbe(isVisible: $windowVisible).frame(width: 0, height: 0)
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
        .modifier(PersonalLibrarySheets(service: library))
        .v3NightGentle(enabled: settings.v3NightGentleEnabled)
        // The cover's colour, lightened where needed to stay clear of the picture behind.
        .environment(\.v3CoverAccent, uiAccent.map {
            V3ReadableAccent.color($0, background: backgroundLuminance * (1 - brightBackgroundScrim))
        } ?? .white)
        .tint(.primary)
        .task(id: state.liveTrackIdentity) {
            library.prefetchCurrentTrack(stableKey: state.liveTrackIdentity?.stableKey)
        }
        .task(id: compositionTrack.artworkURL) {
            guard let url = compositionTrack.artworkURL else { coverColors = nil; return }
            let palette = await LyricIslandArtworkColors.palette(for: url)
            guard !Task.isCancelled else { return }
            coverColors = CoverColors(url: url, accent: LyricIslandArtworkColors.listeningAccent(palette), luminance: palette.luminance)
            guard palette != .neutral else { return }
            let detail = await V3CoverDetail.detail(for: url) ?? 0
            guard !Task.isCancelled, coverColors?.url == url else { return }
            coverColors?.automaticAmbient = V3SceneFamily.automaticAmbient(luminance: palette.luminance, detail: detail, route: palette.route)
        }
        .task(id: subjectArtworkURL) {
            analyzedCover = nil
            guard let url = subjectArtworkURL,
                  let subject = await V3ArtworkSubject.analysis(for: url), !Task.isCancelled else { return }
            analyzedCover = (url, subject)
        }
        .environment(\.lyricAgentPresentationMap, LyricAgentPresentationMap(lines: compositionLyrics))
        .environment(\.v3PlaybackInteractionChanged, playbackInteractionRelay)
        .environment(\.lyricIslandScene, compositionScene)
        .environment(\.v3PlayerBarOptions, V3PlayerBarOptions(
            progress: presentation.progress, chorusEmphasis: settings.v3ChorusEmphasis,
            buttonsOnHover: settings.v3PlayerButtonsOnHover,
            titleMarquee: settings.v3PlayerTitleMarquee,
            progressOnCover: settings.v3PlayerProgressOnCover && foregroundCover?.isLargeEnough == true))
        .environment(\.v3TitleMarquee, settings.v3PlayerTitleMarquee)
        .onReceive(state.objectWillChange) { _ in refreshForContentChange() }
        .sheet(isPresented: $isAlignmentDetailsPresented) {
            if let report = state.liveLyricsState.alignmentReport {
                AlignmentPreviewView(report: report)
            }
        }
        .onChange(of: state.currentTrackIdentity) { _, _ in closeStalePlayingComparison() }
        .onChange(of: state.isShowingSearchPreview) { _, _ in closeStalePlayingComparison() }
        .onChange(of: state.liveLyricsVersionID) { _, _ in
            closeStalePlayingComparison()
            library.prefetchCurrentTrack(stableKey: state.liveTrackIdentity?.stableKey, force: true)
        }
        .onChange(of: state.translationVersions.map { $0.record.id }) { _, _ in
            library.prefetchCurrentTrack(stableKey: state.liveTrackIdentity?.stableKey, force: true)
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
        let footerHeight: CGFloat = isCompositionPreview || !scenePlayerHidden ? 44 : 0
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
        if let analyzedCover, analyzedCover.url == subjectArtworkURL {
            let coverSubject = analyzedCover.subject
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
        let readingWidth = min(760 * lyricWidthScale, max(1, geometry.size.width * (compact ? 0.90 : min(0.94, placement.widthFraction * lyricWidthScale))))
        let playerHeight: CGFloat = scenePlayerHidden ? 0 : 44
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
                    Text(compositionTrack.artist).font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.82)).lineLimit(1)
                }
                // The name sits on the picture itself, so it carries its own shadow.
                .shadow(color: .black.opacity(0.45), radius: 6, y: 1)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: min(600, geometry.size.width - 48), alignment: .leading)
            .padding(.leading, compact ? 24 : 40).padding(.top, 76)
            VStack(spacing: 12) {
                lyricsColumn(width: readingWidth, compact: compact, stage: true)
                    .frame(width: readingWidth, height: readingHeight)
                    .clipped()
                    .background { photographicReadingShade }
                sceneTransport(width: min(440, readingWidth))
            }
            .padding(.horizontal, compact ? 20 : 40).padding(.bottom, 32)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        }
    }

    /// A soft shade under the lyrics on 封面 and 舞台, deeper the brighter
    /// the cover. It follows 清晰度: only while that is left on 关闭 with the
    /// bright-cover help on; an explicit choice is drawn as chosen.
    @ViewBuilder private var photographicReadingShade: some View {
        let depth = min(0.44, max(0, (coverLuminance - 0.18) * 0.85))
        if settings.v3ReadingProtection == .off, settings.v3BrightCoverShadowEnabled, depth > 0.02 {
            EllipticalGradient(stops: [
                .init(color: .black.opacity(depth), location: 0),
                .init(color: .black.opacity(depth * 0.6), location: 0.55),
                .init(color: .clear, location: 1)
            ])
            .scaleEffect(x: 1.25, y: 1.2)
            .allowsHitTesting(false)
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
        // With the cover in view the song's name sits under it, in the same
        // column, and the lyrics start at the top of the page. Without the
        // cover, or in a small window, the name is a heading above a rule.
        let headingInColumn = !compact && compositionShowsCover
        let headerHeight: CGFloat = headingInColumn ? 0 : compact ? 104 : 80
        let footerHeight: CGFloat = isCompositionPreview || !scenePlayerHidden ? 44 : 0
        let readingHeight = LyricIslandSceneBudget.linerReadingHeight(
            canvasHeight: geometry.size.height, headerHeight: headerHeight, footerHeight: footerHeight)
        let heading = VStack(alignment: .leading, spacing: 6) {
            Text(compositionTrack.title)
                .font(.system(size: compact ? 24 : headingInColumn ? 26 : 32, weight: .medium, design: .serif))
                .lineLimit(2).minimumScaleFactor(0.8)
            Text(compositionTrack.artist)
                .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            Text(compositionTrack.album)
                .font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
        }
        return VStack(alignment: .leading, spacing: 18) {
            if !headingInColumn {
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
            }
            HStack(alignment: .top, spacing: 36) {
                if !compact && compositionShowsCover {
                    VStack(alignment: .leading, spacing: 16) {
                        ArtworkView(track: compositionTrack, size: coverSize,
                                    showsAlbumLabel: false, cornerRadiusRatio: 0.025, preservesCompleteArtwork: true)
                        heading
                    }.frame(width: coverColumnWidth, alignment: .leading)
                }
                lyricsColumn(width: compositionShowsCover ? textWidth : min(840 * lyricWidthScale, contentWidth),
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
            else if !scenePlayerHidden {
                AppleMusicImmersiveV3FocusTransportControls(state: state, reduceMotion: reduceMotion)
                    .reportsV3PlaybackRegion()
                    .modifier(playbackVisibility)
            }
        }.frame(width: max(1, width), height: isCompositionPreview || !scenePlayerHidden ? 44 : 0)
    }

    @ViewBuilder
    private func foregroundArtworkLayout(in geometry: GeometryProxy) -> some View {
        if compositionStyle == .albumPoster {
            if isAutomaticCompactLyricsFocus(in: geometry) {
                lyricsOnlyLayout(in: geometry)
            } else if V3ResponsiveGeometry.foregroundLayout(
                canvasSize: geometry.size, automaticLyricsFocus: false
            ) == .portrait {
                portraitLayout(in: geometry)
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

                Group {
                    if isCompositionPreview {
                        compositionPreviewLabel
                    } else {
                        AppleMusicImmersiveV3FocusTransportControls(state: state, reduceMotion: reduceMotion)
                            .modifier(playbackVisibility)
                    }
                }
                .padding(.bottom, LyricsDesignTokens.Spacing.md)
            }
        }
    }

    private func lyricsOnlyLayout(in geometry: GeometryProxy, hidesArtwork: Bool = false) -> some View {
        let compact = isCompact(for: geometry.size)
        let readingWidth = min((compositionScene == .focusedLyrics ? 760 : 940) * lyricWidthScale, max(1, geometry.size.width - (compact ? 56 : 112)))
        let headerHeight: CGFloat = hidesArtwork ? (compact ? 48 : 56) : (compact ? 64 : 76)
        let footerHeight: CGFloat = scenePlayerHidden && !isCompositionPreview ? 0 : 68
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
            // The card holds what the song has: its cover, its name and
            // the controls. No masthead or footer text that says nothing.
            HStack {
                ArtworkView(track: compositionTrack, size: coverSize,
                            showsAlbumLabel: false, cornerRadiusRatio: 0.025,
                            preservesCompleteArtwork: true, reportsForegroundFrame: true)
                    .shadow(color: .black.opacity(0.24), radius: 14, y: 8)
            }
            .frame(maxWidth: .infinity)

            trackPlaybackDetails(width: max(1, metrics.artworkWidth - cardInset * 2),
                                 titleSize: compact ? 22 : 28, alignment: .leading,
                                 progressDensity: compact ? .small : .medium)
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

    private func portraitLayout(in geometry: GeometryProxy) -> some View {
        let metrics = V3ResponsiveGeometry.portraitMetrics(
            canvasSize: geometry.size, artworkScale: foregroundArtworkScale
        )
        let cover = ArtworkView(
            track: compositionTrack, size: metrics.coverSize,
            showsAlbumLabel: false, cornerRadiusRatio: foregroundArtworkCornerRadiusRatio,
            preservesCompleteArtwork: true, reportsForegroundFrame: true
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
            alignment: .leading, progressDensity: .medium
        )
        .modifier(V3PlaybackVisibility(visible: isCompositionPreview || playbackDetailsVisible, reduceMotion: reduceMotion))

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
        progressMaxWidth: CGFloat? = nil
    ) -> some View {
        VStack(alignment: alignment, spacing: 10) {
            TrackMetadataView(
                track: compositionTrack, titleSize: titleSize,
                alignment: alignment, presentation: .v3Immersive
            )
            if isCompositionPreview {
                compositionPreviewLabel
            } else {
                AppleMusicImmersiveV3TransportControls(
                    state: state, alignment: alignment,
                    progressDensity: progressDensity, progressMaxWidth: progressMaxWidth
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
        let trackAlignment: HorizontalAlignment = position == "center" ? .center : position == "right" ? .trailing : .leading
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
            alignment: compositionArtworkPosition == "center" ? .center : compositionArtworkPosition == "right" ? .trailing : .leading,
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
            Group {
                if isCompositionPreview {
                    compositionPreviewLabel
                } else {
                    StageHUDView(state: state, width: hudWidth)
                        .modifier(playbackVisibility)
                }
            }
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
                    preservesCompleteArtwork: true, reportsForegroundFrame: true
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
        let cardWidth = showsForegroundArtwork ? V3ResponsiveGeometry.foregroundCardWidth(coverSize: coverSize) : width
        let textAlignment: HorizontalAlignment = alignment == .center ? .center : .leading
        let columnAlignment: Alignment = alignment == .center ? .center : alignment == .trailing ? .trailing : .leading
        let centersHiddenCover = expandsHiddenArtwork
        let verticalOffset = centersHiddenCover ? V3ResponsiveGeometry.hiddenCoverVerticalOffset(
            containerHeight: availableHeight,
            compositionHeight: playbackRegion.isNull ? 0 : playbackRegion.height,
            coverSize: coverSize,
            scale: visualScale,
            compact: compact,
            topChromeInset: topChromeInset
        ) : 0
        return VStack(alignment: .center, spacing: 0) {
            if showsForegroundArtwork {
                ArtworkView(
                    track: compositionTrack,
                    size: coverSize,
                    showsAlbumLabel: false,
                    cornerRadiusRatio: 0.06,
                    preservesCompleteArtwork: true, reportsForegroundFrame: true
                )
                // Scale the artwork itself, preserving the column's bounds.
                .scaleEffect(visualScale)
                .frame(width: cardWidth, alignment: .center)
                .offset(x: centersHiddenCover ? V3ResponsiveGeometry.ambientHiddenCoverOffset(
                    containerWidth: cardWidth,
                    coverSize: coverSize,
                    scale: visualScale,
                    alignment: alignmentKey
                ) : 0, y: verticalOffset)
                .shadow(color: .black.opacity(0.22), radius: compact ? 14 : 24, y: 10)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.32), value: playbackDetailsVisible)

                Spacer().frame(height: compact ? LyricsDesignTokens.Spacing.lg - 2 : LyricsDesignTokens.Spacing.xl)

                trackPlaybackDetails(
                    width: max(1, cardWidth - (compact ? 28 : 32)),
                    titleSize: min(compact ? 26 : 30, max(compact ? 18 : 22, coverSize * 0.075)),
                    alignment: textAlignment, progressDensity: progressDensity
                )
                .padding(.horizontal, compact ? 14 : 16)
                .padding(.vertical, compact ? 12 : 14)
                .frame(width: cardWidth)
                .background(V3PlaybackSurface(cornerRadius: 18))
                .modifier(playbackVisibility)
            } else {
                Spacer(minLength: 0)

                trackPlaybackDetails(width: width, titleSize: compact ? 22 : 26, alignment: textAlignment,
                                     progressDensity: progressDensity, progressMaxWidth: progressDensity == .small
                                        ? min(width, LyricsDesignTokens.Progress.smallMaxWidth) : nil)
                .padding(.horizontal, compact ? 14 : 16)
                .padding(.vertical, compact ? 12 : 14)
                .frame(maxWidth: width, alignment: columnAlignment)
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
            alignment: columnAlignment
        )
    }

    private func lyricsColumn(
        width: CGFloat,
        compact: Bool,
        lyricsFocus: Bool = false,
        onSearch: (() -> Void)? = nil,
        stage: Bool = false
    ) -> some View {
        // Rows read 行宽 when they lay out; set it before they do, and rebuild them when it changes.
        return VStack(spacing: 8) {
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
        .environment(\.v3LyricWidthScale, lyricWidthScale)
        .environment(\.v3LyricStyle, presentation.lyricStyle)
        .environmentObject(settings)
        .environment(\.v3PreviewPresentation, compositionStyle)
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
        case .previousLine: showLyricNotice(state.stepLyricLine(forward: false) ? "上一句" : "这份歌词没有时间，不能按句跳")
        case .nextLine: showLyricNotice(state.stepLyricLine(forward: true) ? "下一句" : "没有下一句可跳")
        case .offset(let delta):
            showLyricNotice(V3LyricActions(settings: settings).calibrateLyrics(by: delta, target: lyricsOffsetTarget))
        case .resetOffset:
            showLyricNotice(V3LyricActions(settings: settings).calibrateLyrics(by: nil, target: lyricsOffsetTarget))
        case .blurFine(let delta):
            let blur = visualControls.blur
            blur.wrappedValue = min(100, max(0, blur.wrappedValue + delta))
            showLyricNotice("模糊 \(Int(blur.wrappedValue))%")
        case .blurCycle:
            let blur = visualControls.blur
            blur.wrappedValue = V3LyricActions.nextBlurPreset(after: blur.wrappedValue)
            showLyricNotice("模糊 \(Int(blur.wrappedValue))%")
        case .focus:
            isFocusMode.toggle(); dismissPinnedToolbarPanel()
            showLyricNotice(isFocusMode ? "专注模式" : "退出专注模式")
        case .help: showsListeningKeys.toggle(); showLyricNotice(showsListeningKeys ? "全部按键" : "关闭按键说明")
        case .escape:
            handleExitCommand()
            if !liveOnly { showLyricNotice("返回听歌") }
        }
    }

    private func handleExitCommand() {
        if liveOnly && !showsListeningKeys && !isFocusMode && !toolbarPanelIsPresented {
            WindowManager.shared.hideFullScreen()
            return
        }
        showsListeningKeys = false
        isFocusMode = false
        dismissPinnedToolbarPanel()
    }

    private var listeningKeyList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("听歌按键").font(.headline); Spacer(); Button("关闭") { showsListeningKeys = false } }
            ForEach(["空格 · 播放 / 暂停", "A / D · 上一首 / 下一首", "Q / E · 上一句 / 下一句", "S · 喜欢，再按移除", "Z / C · 偏移 −0.1s / +0.1s", "X · 偏移归零", "/ · 模糊 0 / 25 / 50 / 75 / 100%", ", / . · 模糊 −5% / +5%", "F · 专注模式", "Shift + / · 全部按键", "Esc · 关闭面板 / 退出专注"], id: \.self) { Text($0) }
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
        TranslationAutomationToggle.isAllowed(settings.aiTranslationConfiguration)
    }

    private func translationControls(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if !compact { Label("AI 与读音", systemImage: "sparkles").font(.headline) }
            V3SegmentedPicker("内容", selection: $showsAIReadingControls,
                              options: [("翻译", false), ("读音", true)])
            if !displaysAIReadingControls {
                V3PanelRow(title: "当前译文") {
                    Menu {
                        Button("自动（推荐）") { state.restoreRecommendedTranslation() }
                        Button("AI 翻译（没有就不显示）") { state.preferAITranslation() }
                        ForEach(state.translationVersions, id: \.record.id) { version in
                            Button(translationVersionTitle(version)) {
                                state.selectTranslation(versionID: version.record.id)
                            }
                        }
                        Button("不显示") { state.selectNoTranslationVersion() }
                    } label: {
                        Text(state.prefersAITranslation && state.selectedTranslation == nil ? "AI 翻译 · 这首还没有" :
                             state.translationVersions.isEmpty ? "暂无译文" :
                             state.selectedTranslation.map(translationVersionTitle) ?? "不显示")
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                }
            }
            V3PanelSection(title: "服务")
            TranslationServicePanelRows(settings: settings, openSettings: openAISettings)
            if displaysAIReadingControls {
                aiReadingControls(compact: compact)
            } else {
            TranslationAutomationToggle(settings: settings)
            V3PanelSection(title: "这首歌")
            if case .loading = state.translationState {
                V3PanelRow(title: "翻译中…") {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Button("取消") { state.cancelTranslation() }.controlSize(.small)
                    }
                }
            } else {
                HStack(spacing: 6) {
                    Button("翻译整首") { state.translateCurrentLyrics() }
                    Button("重新翻译") { state.retranslateCurrentLyrics() }
                    Spacer()
                    compareTranslationsButton
                }
                .controlSize(.small)
                .frame(minHeight: V3PanelMetrics.rowHeight)
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
            }
        }
        .modifier(V3ToggleStyleUnlessPanel(inPanel: compact))
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

    private var compareTranslationsButton: some View {
        Button {
            guard !openingTranslationComparison, !state.isShowingSearchPreview, state.liveLyricsDocumentMatchesCurrentTrack,
                  let identity = state.liveTrackIdentity, let sourceID = state.liveLyricsVersionID else { return }
            openingTranslationComparison = true
            Task { @MainActor in
                defer { openingTranslationComparison = false }
                do {
                    let request = try await library.playingComparison(identity: identity, lyricsID: sourceID,
                        selected: state.selectedTranslation?.record.id, versions: state.translationVersions)
                    guard state.liveTrackIdentity == identity, state.liveLyricsVersionID == sourceID, !state.isShowingSearchPreview else { return }
                    guard let request else { state.showNotice("这版原词还没有两份可对读的译文"); return }
                    dismissPinnedToolbarPanel()
                    library.comparison = request
                } catch { state.showNotice("暂时读不到这两份译文") }
            }
        } label: {
            Label("逐句对读", systemImage: "rectangle.split.2x1")
        }
        .buttonStyle(.borderless)
        .disabled(openingTranslationComparison || state.isShowingSearchPreview || !state.liveLyricsDocumentMatchesCurrentTrack ||
                  state.liveLyricsVersionID == nil || state.translationVersions.count < 2)
        .help("对读已存译文、挑句修订或采用一稿")
    }

    private func closeStalePlayingComparison() {
        if let playing = library.comparison?.playing,
           !playing.matches(identity: state.liveTrackIdentity, lyricsID: state.liveLyricsVersionID, preview: state.isShowingSearchPreview) {
            library.comparison = nil
        }
    }

    private func translationVersionTitle(_ version: StoredTranslationVersion) -> String {
        let name = version.record.translationSourceTitle
        guard state.translationVersions.filter({ $0.record.translationSourceTitle == name }).count > 1 else { return name }
        return name + " · " + version.record.createdAt.formatted(date: .abbreviated, time: .shortened)
    }

    private func aiReadingControls(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
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
            HStack(spacing: 6) {
                Button("本地生成") { state.generateCurrentReading() }
                    .disabled(!canGenerateReadingHere || state.isReadingGenerating)
                Button("AI 优化…", systemImage: "sparkles") { confirmsAIReadingRequest = true }
                    .disabled(aiReadingRequestDisabledReason != nil)
                    .help(aiReadingRequestDisabledReason ?? "用所选模型优化当前歌词的不确定读音")
            }
            .controlSize(.small)
            .frame(minHeight: V3PanelMetrics.rowHeight)
            if !compact, let reason = aiReadingRequestDisabledReason {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
            if state.isReadingGenerating {
                ProgressView("正在生成读音…").controlSize(.small)
            } else if !state.readingMessage.isEmpty {
                Text(state.readingMessage).font(.caption).foregroundStyle(.secondary)
            }
            V3PanelRow(title: "已保存的读音") {
            Menu(state.selectedReadingVersion.map { ReadingRepresentationID(rawValue: $0.record.representationID)?.displayName ?? "读音" } ?? "选择") {
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
            .menuStyle(.borderlessButton).fixedSize()
            .disabled(state.readingVersions.isEmpty)
            }
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
    /// The 情境 drawn now: the one being tried, else the saved one; none in focus mode.
    private var activeScene: V3Room {
        guard !isFocusMode, !isCompositionPreview else { return .off }
        return (scenePreview ?? settings.v3Room).resolved(sceneWeather)
    }

    /// What the 情境 scene needs from the song; built only while one is chosen.
    private var roomContext: V3RoomContext {
        guard settings.v3Room != .off || scenePreview != nil else { return V3RoomContext() }
        let index = compositionSynchronized ? compositionIndex : nil
        let text = index.flatMap { compositionLyrics.indices.contains($0) ? compositionLyrics[$0].originalText : nil } ?? ""
        return V3RoomContext(chorus: chorusNow, lineIndex: index, lineCount: compositionLyrics.count,
                             stanza: activeScene == .book ? V3RoomContext.stanza(of: index, in: compositionLyrics) : 0,
                             currentLine: activeScene == .polaroid ? text : "",
                             trackKey: TrackIdentity(track: compositionTrack).stableKey,
                             spotifyTrackID: compositionTrack.spotifyId.flatMap(SpotifyPublicArtwork.trackID(from:)),
                             opensOnChorus: settings.v3RoomOpensOnChorus,
                             accent: coverAccent ?? .white, luminance: coverLuminance,
                             artworkURL: compositionTrack.artworkURL,
                             song: [.polaroid, .stars].contains(activeScene) ? roomSong : nil)
    }

    private var roomSong: V3RoomContext.Song {
        let track = compositionTrack
        let hook = V3RoomContext.hook(in: compositionLyrics)
        return V3RoomContext.Song(trackKey: TrackIdentity(track: track).stableKey, title: track.title, artist: track.artist,
                                  artworkURL: track.artworkURL, lineCount: compositionLyrics.count,
                                  hookLine: hook?.originalText ?? "", hookTranslation: hook?.translationText)
    }

    /// The line being sung is in a chorus (repeated lyrics).
    private var chorusNow: Bool {
        compositionSynchronized
            && LyricsChorus.contains(compositionIndex, lines: compositionLyrics, duration: compositionTrack.duration)
    }

    /// 歌词意象 for the line being sung (original and translation).
    private var currentLyricImagery: V3LyricImagery? {
        guard compositionSynchronized, let index = compositionIndex, compositionLyrics.indices.contains(index) else { return nil }
        let line = compositionLyrics[index]
        return V3LyricImagery.detect([line.originalText, line.translationText])
    }

    private var toolbarOpacity: Double {
        let value = isFocusMode ? 0 : toolbar.opacity(pointerInside: isPointerInsideCanvas && !liveOnly, nearTop: toolsVisible,
                        otherPanelOpen: toolbarPanelIsPresented)
        // 下拉: nothing at all until the pointer reaches the top edge.
        let hidesUntilEdge = toolbarStyle == .pullDown || toolbarStyle == .sidePull
        return hidesUntilEdge && value < 1 ? 0 : value
    }

#if DEBUG
    private func applyToolbarDebugCommand(_ info: [AnyHashable: Any]) {
        let panel = (info["panel"] as? String).flatMap(ToolbarPopover.init(rawValue:))
        switch info["command"] as? String {
        case "navigation":
            librarySearch.open(V3LibrarySearchPresentation.Tab(rawValue: info["panel"] as? String ?? "") ?? .library)
        case "translation-delete-close": library.translationDeletionCandidate = nil
        case "translation-delete-confirm":
            guard let detail = library.selectedTrackDetail, let version = detail.translationVersions.first else { return }
            dismissPinnedToolbarPanel()
            DispatchQueue.main.async {
                library.translationDeletionCandidate = .init(version: version, trackStableKey: detail.entry.trackStableKey)
            }
        case "version-preview-close": library.versionPreview = nil
        case "version-preview":
            toolbarDismissTask?.cancel()
            toolbar.dismiss()
            DispatchQueue.main.async {
                library.versionPreview = .init(title: state.currentTrack.title,
                    text: state.liveLyrics.map(\.originalText).joined(separator: "\n"))
            }
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
        if panel == .library || panel == .search || panel == .playlists {
            toolbar.dismiss()
            librarySearch.toggle(V3LibrarySearchPresentation.Tab(rawValue: panel.rawValue) ?? .library)
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
        // 窗外 opens panels on a click, pinned beside the window, so nothing
        // hovers over the listening view.
        guard !librarySearch.isPresented, toolbarStyle != .outside else { return }
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
        let style = toolbarStyle
        return Group {
            switch style {
            case .grouped:
                HStack(spacing: 10) {
                    toolbarGroup([.library, .search, .playlists], showsSettings: false)
                    toolbarGroup([.translation, .text, .picture, .scene, .more], showsSettings: true)
                }
            case .radial:
                radialToolbar
            default:
                toolbarGroup(ToolbarPopover.allCases, showsSettings: true)
            }
        }
        .buttonStyle(QuietToolbarButtonStyle())
        // The window's first focusable control otherwise wears a focus ring
        // whenever the window becomes key, which reads as a stuck selection.
        .focusEffectDisabled()
        .environment(\.lyricIslandCompactTools,
                     (size.width < 720 && style != .outside) || style == .iconOnly || style == .titleBar || style == .radial
                        || style == .sidePull)
        .background(GeometryReader { geometry in
            Color.clear.preference(key: V3ToolbarFramePreferenceKey.self,
                value: geometry.frame(in: .named("v3-window-canvas")))
        })
        .modifier(V3SystemAppearanceModifier())
        .onChange(of: toolbar.mode) { old, new in toolbarModeChanged(from: old, to: new) }
        .onDisappear { toolbarDismissTask?.cancel(); hoveredStyle = nil }
    }

    private func toolbarGroup(_ panels: [ToolbarPopover], showsSettings: Bool) -> some View {
        let vertical = toolbarStyle == .sidePull
        let layout = vertical ? AnyLayout(VStackLayout(spacing: 3)) : AnyLayout(HStackLayout(spacing: 3))
        return layout {
            ForEach(panels, id: \.rawValue) { panel in
                toolbarPanelButton(panel)
            }
            if showsSettings {
                // Global, low-frequency settings sit at the trailing end, apart
                // from the listening tools.
                Rectangle().fill(Color.primary.opacity(0.18))
                    .frame(width: vertical ? 18 : 1, height: vertical ? 1 : 18)
                    .padding(vertical ? .vertical : .horizontal, 2)
                settingsToolbarButton
            }
        }
        .padding(toolbarStyle == .titleBar ? 2 : 5)
        .modifier(V3ControlBarSurface())
    }

    private var settingsToolbarButton: some View {
        Button(action: openAppSettings) {
            toolbarEntry("设置", symbol: "gearshape")
        }
        .v3FirstClick(openAppSettings)
        .help("应用设置与 AI 服务")
    }

    /// 环形: one round button at the top right. Coming near it fans the
    /// tools out along a quarter circle; they stay out while a panel is open.
    private var radialToolbar: some View {
        let panels = ToolbarPopover.allCases
        let count = panels.count + 1
        let side: CGFloat = 236, radius: CGFloat = 186
        let hub = CGPoint(x: side - 22, y: 22)
        let open = radialToolbarOpen || toolbar.isPresented || toolbarPanelIsPresented
        func point(_ index: Int) -> CGPoint {
            guard open else { return hub }
            let angle = Double.pi / 2 * Double(index) / Double(count - 1)
            return CGPoint(x: hub.x - radius * CGFloat(cos(angle)), y: hub.y + radius * CGFloat(sin(angle)))
        }
        return ZStack(alignment: .topLeading) {
            if open {
                // Keeps the fan open while the pointer travels between tools.
                Path { path in
                    path.move(to: hub)
                    path.addArc(center: hub, radius: radius + 26, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
                    path.closeSubpath()
                }
                .fill(Color.white.opacity(0.001))
            }
            ForEach(Array(panels.enumerated()), id: \.element.rawValue) { index, panel in
                toolbarPanelButton(panel)
                    .modifier(V3ControlBarSurface())
                    .scaleEffect(open ? 1 : 0.4)
                    .opacity(open ? 1 : 0)
                    .allowsHitTesting(open)
                    .position(point(index))
            }
            settingsToolbarButton
                .modifier(V3ControlBarSurface())
                .scaleEffect(open ? 1 : 0.4)
                .opacity(open ? 1 : 0)
                .allowsHitTesting(open)
                .position(point(count - 1))
            Image(systemName: open ? "xmark" : "circle.grid.cross")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 38, height: 38)
                .modifier(V3ControlBarSurface())
                .contentShape(Circle())
                .position(hub)
                .help("工具")
        }
        .frame(width: side, height: side, alignment: .topLeading)
        .animation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.82), value: open)
        .onHover { inside in
            radialToolbarCloseTask?.cancel()
            if inside { radialToolbarOpen = true }
            else {
                radialToolbarCloseTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled else { return }
                    radialToolbarOpen = false
                }
            }
        }
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
        .v3ToolPopover(isPresented: toolbarPopoverBinding(panel), onAnchorPress: { clickToolbarPanel(panel) }, width: panel == .playlists ? 300 : 360) {
            hoverTrackedPanel(panel) { inspectorSurface(for: panel, style: .hoverGlass) }
        }
    }

    private func toolbarPanel(for panel: ToolbarPopover) -> some View {
        V3ToolbarQuickControls(panel: panel, state: state, search: state.songSearchManager, library: library,
            beforePresentSheet: { dismissPinnedToolbarPanel() },
            openLibrary: { clickToolbarPanel(.library) }, openSearch: { clickToolbarPanel(.search) },
            openPlaylists: { clickToolbarPanel(.playlists) }) {
            switch panel {
            case .translation: translationControls(compact: true)
            case .text: visualControls.textPage
            case .picture:
                V3ThemeSelectorView(settings: settings, artworkURL: compositionTrack.artworkURL,
                    displayedPresentation: resolvedPresentation(includeArtworkPreview: false),
                    preview: $hoveredStyle, previewScene: $hoveredScene,
                    onConfirm: {}, compact: true)
                visualControls.blurControls
                visualControls.foregroundArtworkControl
                visualControls.playbackPresentationControls
                visualControls.backgroundMotionControls
                V3DisclosureRow(title: "更多画面选项", isExpanded: $settings.v3PictureAdvancedExpanded) {
                    visualControls.pictureAdvancedControls(showsExplanations: false)
                }
            case .scene:
                V3ScenePicker(settings: settings, preview: $scenePreview)
            case .more:
                visualControls.toolbarStyleControls
                // 恢复歌词时间 was the same action as 归零 on the offset row, which stays.
                LyricsPresentationOffsetControl(settings: settings, target: lyricsOffsetTarget, showsLegacyNotice: false,
                                                showsExplanations: false, rowStyle: true)
                SleepTimerControls(timer: state.sleepTimer, select: state.configureSleepTimer)
                windowModePanel
                desktopInteractionPanel
            case .library, .search, .playlists: EmptyView()
            }
        }
    }

    private var visualControls: V3VisualControls { V3VisualControls(settings: settings, displayedPresentation: presentation) }

    /// The cover colour for text and controls, or nil when the user keeps them white.
    private var uiAccent: Color? { settings.v3FollowCoverColor ? coverAccent : nil }

    private func toolbarEntry(_ title: String, symbol: String, selected: Bool = false) -> some View {
        Label(title, systemImage: symbol)
            .labelStyle(LyricIslandToolbarLabelStyle())
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.primary.opacity(0.94))
            .padding(.horizontal, 10)
            .frame(height: toolbarStyle == .titleBar ? 26 : 36)
            // The open tool wears the same cover colour as the sung line; the label stays
            // primary so it reads on both the light and the dark bar.
            .background(selected ? (uiAccent.map { $0.opacity(0.34) } ?? Color.primary.opacity(0.14)) : .clear, in: Capsule())
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
        VStack(alignment: .leading, spacing: 2) {
            V3PanelSection(title: "窗口")
            if !liveOnly {
                V3PanelRow(title: "工作台") {
                    Button("打开") { MenuBarLyricsController.shared.openWorkspace() }
                        .controlSize(.small).accessibilityLabel("打开工作台")
                }
                Toggle("桌面歌词", isOn: Binding(get: { state.showFloatingWindow }, set: { _ in
                    WindowManager.shared.toggleFloatingLyrics(state: state)
                }))
                Toggle("灵动岛", isOn: Binding(get: { state.showCapsulePlayer }, set: { _ in
                    WindowManager.shared.toggleCapsule(state: state)
                }))
                Toggle("菜单栏歌词", isOn: $settings.menuBarLyricsEnabled)
                    .accessibilityIdentifier("menubar.lyrics.toggle")
                    .help("直接开启或关闭菜单栏歌词；播放面板仍可从菜单栏图标打开。")
            }
            V3PanelRow(title: "全屏歌词") {
                Button(liveOnly ? "退出" : "打开") {
                    if liveOnly {
                        dismissPinnedToolbarPanel()
                        WindowManager.shared.hideFullScreen()
                    } else {
                        WindowManager.shared.showFullScreen(state: state, settings: settings)
                    }
                    isWindowMenuPresented = false
                }
                .controlSize(.small)
                .accessibilityLabel(liveOnly ? "退出全屏歌词" : "打开全屏歌词")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var desktopInteractionPanel: some View {
        if !liveOnly {
            V3SegmentedPicker("桌面交互", selection: Binding(
                get: { settings.floatingWindowInteractionMode },
                set: { WindowManager.shared.setFloatingInteractionMode($0, state: state) }
            ), options: FloatingLyricsInteractionMode.allCases.map { ($0.title, $0) })
            .help(FloatingLyricsInteractionMode.allCases.map { $0.title + "：" + $0.detail }.joined(separator: "\n"))
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
        .frame(width: panel == .playlists ? 300 : 360, alignment: .topLeading)
        .tint(.primary)
        .background {
            if style == .hoverGlass { V3PanelGlass() }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(style == .hoverGlass ? 0.10 : 0), lineWidth: 0.5))
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
