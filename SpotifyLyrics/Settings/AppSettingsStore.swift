import Combine
import Foundation

/// Persistent user-facing interaction mode for the shared floating lyrics
/// panel. It lives beside the settings boundary so lightweight contract
/// builds that compile AppSettingsStore without AppKit window code keep the
/// same model dependency as the production target.
public enum FloatingLyricsInteractionMode: String, CaseIterable, Codable, Sendable {
    case interactive
    case locked
    case passThrough

    public var title: String {
        switch self {
        case .interactive: return "可编辑 / 可拖动"
        case .locked: return "锁定展示"
        case .passThrough: return "鼠标穿透"
        }
    }

    public var detail: String {
        switch self {
        case .interactive: return "可以移动、缩放并操作窗口"
        case .locked: return "保持位置和尺寸，仍可响应窗口事件"
        case .passThrough: return "不接收普通鼠标事件，可从 App 菜单恢复"
        }
    }
}

/// Listening themes are independent of the stable IDs of their renderers.
public enum V3ArtworkTheme: String, CaseIterable, Identifiable, Sendable {
    case stage, lyricsOnly, albumPoster, ambient, enlarged
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .stage: return "封面舞台"
        case .lyricsOnly: return "纯净歌词"
        case .albumPoster: return "封面海报"
        case .ambient: return "环境光"
        case .enlarged: return "放大"
        }
    }
    public var symbolName: String {
        switch self {
        case .stage: return "rectangle.inset.filled"
        case .lyricsOnly: return "text.alignleft"
        case .albumPoster: return "photo.artframe"
        case .ambient: return "sun.max"
        case .enlarged: return "square.dashed.inset.filled"
        }
    }
}

/// Stable V3 artwork compositions. These are presentation choices only and
/// do not create separate playback or lyrics runtimes.
public enum V3ArtworkPresentation: String, CaseIterable, Codable, Identifiable, Sendable {
    case authenticAmbient = "v3ArtworkPresentation.authenticAmbient.v1"
    case ambient = "v3ArtworkPresentation.ambient.v1"
    case stage = "v3ArtworkPresentation.stage.v1"
    case classic = "v3ArtworkPresentation.classic.v1"
    case classicGaussian = "v3ArtworkPresentation.gaussian.v1"
    case ambientFeathered = "v3ArtworkPresentation.feathered.v1"
    case lyricsOnly = "v3ArtworkPresentation.lyricsOnly.v1"
    case albumPoster = "v3ArtworkPresentation.albumPoster.v1"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .authenticAmbient: return "原版环境光"
        case .ambient: return "封面柔焦"
        case .stage: return "封面舞台"
        case .classic: return "柔和光晕"
        case .classicGaussian: return "纯高斯"
        case .ambientFeathered: return "柔光羽化"
        case .lyricsOnly: return "纯净歌词"
        case .albumPoster: return "封面海报"
        }
    }

    public var detail: String {
        switch self {
        case .authenticAmbient: return "忠实复现 v0.1.2 正式版环境光：全幅封面底图与独立色彩扩散光晕"
        case .ambient: return "放大封面随模糊柔化，保留封面的色彩和纹理"
        case .stage: return "完整封面居中显示，模糊背景补齐空余区域"
        case .classic: return "柔和、偏暗的封面光晕，随专辑色彩扩散"
        case .classicGaussian: return "只柔化放大的封面，不叠加彩色光晕；背景与前景尺寸独立"
        case .ambientFeathered: return "封面边缘渐隐融入光晕；0%也保留羽化，前景封面清晰"
        case .lyricsOnly: return "安静的专辑色背景，把更多空间留给歌词和译文"
        case .albumPoster: return "完整封面与歌曲信息组成海报，歌词在一旁清楚呈现"
        }
    }

    public static var ambientVariants: [Self] { [.authenticAmbient, .classic, .ambientFeathered] }
    public static var enlargedVariants: [Self] { [.ambient, .classicGaussian] }

    public var theme: V3ArtworkTheme {
        switch self {
        case .authenticAmbient, .classic, .ambientFeathered: return .ambient
        case .ambient, .classicGaussian: return .enlarged
        case .stage: return .stage
        case .lyricsOnly: return .lyricsOnly
        case .albumPoster: return .albumPoster
        }
    }
    public var themeTitle: String { theme.title }
    public var variantTitle: String { title }

    public var symbolName: String {
        switch self {
        case .authenticAmbient: return "sun.max.fill"
        case .ambient: return "sun.max"
        case .stage: return "rectangle.inset.filled"
        case .classic, .classicGaussian: return "square.dashed.inset.filled"
        case .ambientFeathered: return "circle.lefthalf.filled"
        case .lyricsOnly: return "text.alignleft"
        case .albumPoster: return "photo.artframe"
        }
    }

    public var blurControlTitle: String {
        switch self {
        case .authenticAmbient: return "环境光柔化程度"
        case .ambient: return "背景封面模糊"
        case .stage: return "补边背景柔化"
        case .classic: return "光晕柔化程度"
        case .classicGaussian: return "背景高斯模糊度"
        case .ambientFeathered: return "柔光扩散程度"
        case .lyricsOnly: return "背景色彩柔和度"
        case .albumPoster: return "海报背景柔化"
        }
    }

    public var artworkSizeControlTitle: String {
        switch self {
        case .authenticAmbient, .ambient: return "前景封面尺寸"
        case .stage: return "封面背景缩放"
        case .classic, .classicGaussian: return "前景封面尺寸"
        case .ambientFeathered: return "前景封面尺寸"
        case .lyricsOnly: return "封面尺寸"
        case .albumPoster: return "海报封面尺寸"
        }
    }

    public var artworkPositionControlTitle: String {
        switch self {
        case .authenticAmbient, .ambient: return "封面与光源位置"
        case .stage: return "封面背景取景"
        case .classic: return "封面与光源位置"
        case .classicGaussian: return "封面与裁切位置"
        case .ambientFeathered: return "封面与光源位置"
        case .lyricsOnly: return "背景光源位置"
        case .albumPoster: return "海报位置"
        }
    }
}


/// Product scenes are not renderer IDs. Legacy presets remain separately addressable.
/// Only the selected renderer is constructed; this catalog owns no playback runtime.
public enum V3ListeningScene: String, CaseIterable, Codable, Identifiable, Sendable {
    case originalAmbient = "scene.originalAmbient.v1"
    case flowingField = "scene.flowingField.v1"
    case coverPhoto = "scene.coverPhoto.v1"
    case linerNotes = "scene.linerNotes.v1"
    case focusedLyrics = "scene.focusedLyrics.v1"
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .originalAmbient: return "原版环境光"
        case .flowingField: return "流动光场"
        case .coverPhoto: return "封面写真"
        case .linerNotes: return "唱片内页"
        case .focusedLyrics: return "专注歌词"
        }
    }
    public var detail: String {
        switch self {
        case .originalAmbient: return "完整封面，保留已认可的自然光色"
        case .flowingField: return "独立色场，或保留完整的柔光羽化"
        case .coverPhoto: return "画面成为舞台，歌词落在局部阅读区域"
        case .linerNotes: return "歌曲题头、版心与段落，像打开唱片内页"
        case .focusedLyrics: return "安静底色与受控行宽，连续阅读优先"
        }
    }
    public var symbolName: String {
        switch self {
        case .originalAmbient: return "sun.max"
        case .flowingField: return "sparkles"
        case .coverPhoto: return "photo.fill"
        case .linerNotes: return "book.pages"
        case .focusedLyrics: return "text.alignleft"
        }
    }
    public var renderers: [V3ArtworkPresentation] {
        switch self {
        case .originalAmbient: return [.authenticAmbient]
        case .flowingField: return [.classic, .ambientFeathered]
        case .coverPhoto: return [.ambient, .classicGaussian, .stage]
        case .linerNotes: return [.albumPoster]
        case .focusedLyrics: return [.lyricsOnly]
        }
    }
    public var defaultRenderer: V3ArtworkPresentation { renderers[0] }
    public func rendererTitle(_ renderer: V3ArtworkPresentation) -> String {
        if self == .flowingField && renderer == .classic { return "独立色场" }
        if self == .coverPhoto && renderer == .stage { return "完整舞台" }
        return renderer.title
    }
}

public enum V3ReadingProtection: String, CaseIterable, Identifiable, Codable, Sendable {
    case off, shadow, glow
    public var id: String { rawValue }
    public var title: String {
        switch self { case .off: return "关闭"; case .shadow: return "文字阴影"; case .glow: return "柔和光晕" }
    }

    static func restored(_ value: String?) -> Self {
        if value == "enhanced" { return .glow }
        return Self(rawValue: value ?? "off") ?? .off
    }

    func effective(reduceTransparency: Bool, increasedContrast: Bool) -> Self {
        reduceTransparency || increasedContrast ? .glow : self
    }
}

/// Finite, independent scene+renderer presets. Does not mutate any of the eight old keys.
public struct V3ScenePreset: Codable, Equatable, Sendable {
    public var blur: Double
    public var foregroundScale: Double
    public var foregroundPosition: String
    public var foregroundVisible: Bool
    public var backdropScale: Double
    public var completeArtwork: Bool
    public var lyricsPosition: String
    public var atmosphere: Int
    /// 背景明暗 for 原版环境光: 1 keeps the established look, higher lifts the
    /// background so the old lighter 封面柔焦 entry stays reachable.
    public var backgroundBrightness: Double
    public static func initial(scene: V3ListeningScene, renderer: V3ArtworkPresentation) -> Self {
        Self(blur: renderer == .authenticAmbient ? 25 : renderer == .stage ? 0 : renderer == .classicGaussian ? 58 : 36,
             foregroundScale: 1, foregroundPosition: "left",
             foregroundVisible: scene == .originalAmbient || scene == .flowingField || scene == .linerNotes,
             backdropScale: 1, completeArtwork: renderer == .stage || renderer == .ambientFeathered,
             lyricsPosition: scene == .coverPhoto ? "right" : "automatic",
             atmosphere: scene == .flowingField && renderer == .classic ? 1 : 0,
             backgroundBrightness: 1)
    }
    public func normalized() -> Self {
        var p = self
        p.blur = blur.isFinite ? min(100, max(0, blur)) : 25
        p.foregroundScale = foregroundScale.isFinite ? min(1.4, max(0.8, foregroundScale)) : 1
        p.backdropScale = backdropScale.isFinite ? min(1.4, max(0.8, backdropScale)) : 1
        p.foregroundPosition = ["left", "center", "right"].contains(foregroundPosition) ? foregroundPosition : "left"
        p.lyricsPosition = ["automatic", "left", "center", "right"].contains(lyricsPosition) ? lyricsPosition : "automatic"
        p.atmosphere = min(2, max(0, atmosphere))
        p.backgroundBrightness = backgroundBrightness.isFinite
            ? min(1.4, max(0.6, backgroundBrightness)) : 1
        return p
    }
}

extension V3ScenePreset {
    /// Presets written before 背景明暗 existed decode with the neutral value.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        blur = try container.decode(Double.self, forKey: .blur)
        foregroundScale = try container.decode(Double.self, forKey: .foregroundScale)
        foregroundPosition = try container.decode(String.self, forKey: .foregroundPosition)
        foregroundVisible = try container.decode(Bool.self, forKey: .foregroundVisible)
        backdropScale = try container.decode(Double.self, forKey: .backdropScale)
        completeArtwork = try container.decode(Bool.self, forKey: .completeArtwork)
        lyricsPosition = try container.decode(String.self, forKey: .lyricsPosition)
        atmosphere = try container.decode(Int.self, forKey: .atmosphere)
        backgroundBrightness = try container.decodeIfPresent(Double.self, forKey: .backgroundBrightness) ?? 1
    }
}

/// Active playback provider source mode.
public enum PlaybackSourceMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case auto = "auto"
    case spotify = "spotify"
    case appleMusic = "appleMusic"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .auto: return "自动检测 (推荐)"
        case .spotify: return "Spotify Desktop"
        case .appleMusic: return "Apple Music (音乐)"
        }
    }

    public var detail: String {
        switch self {
        case .auto: return "自动检测当前正在播放的播放器（Spotify 或 Apple Music 优先）"
        case .spotify: return "仅连接 Spotify Desktop 桌面客户端"
        case .appleMusic: return "仅连接系统自带 Apple Music (音乐.app)"
        }
    }
}

/// The single UserDefaults boundary for user-facing configuration. Views bind
/// to this object; PlaybackState mirrors the display value and turns provider
/// IDs into the existing provider instances.
public final class AppSettingsStore: ObservableObject {
    public static let shared = AppSettingsStore()

    public enum Key {
        public static let settingsVersion = "settings.version"
        public static let v3ListeningScene = "v3.scene.selected.v1"
        public static let v3ScenePresets = "v3.scene.presets.v1"
        public static let v3SceneRenderers = "v3.scene.renderers.v1"
        public static let v3SceneHoverPreviewEnabled = "v3.scene.hoverPreview.v1"
        /// One-shot marker for the R3 entry merge (16 entries → 4 categories / 9 styles).
        public static let v3SceneEntriesMerged = "v3.scene.entriesMerged.v1"
        public static let v3BigLineModeEnabled = "v3.bigLineMode.enabled.v1"
        public static let v3NightGentleEnabled = "v3.nightGentle.enabled.v1"
        public static let v3PictureAdvancedExpanded = "v3.picture.advancedExpanded.v1"
        public static let v3ReadingProtection = "v3.readingProtection.v2"
        public static let v3BrightCoverShadowEnabled = "v3.brightCoverShadow.enabled.v1"
        public static let menuBarWidthMode = "menuBar.widthMode.v1"
        public static let menuBarWidth = "menuBar.width.v1"
        public static let menuBarOverflow = "menuBar.overflow.v1"
        public static let mainWindowLayoutStyle = "mainWindowLayoutStyle"
        public static let automaticCompactLyricsFocus = "general.automaticCompactLyricsFocus"
        public static let menuBarLyricsEnabled = "menuBar.lyricsEnabled"
        public static let menuBarLyricsShowsFullLine = "menuBar.showsFullLine.v1"
        public static let menuBarLyricsShowsOriginal = "menuBar.showsOriginal.v1"
        public static let menuBarLyricsShowsTranslation = "menuBar.showsTranslation.v1"
        public static let menuBarLyricsShowsKana = "menuBar.showsKana.v1"
        public static let menuBarLyricsShowsRomaji = "menuBar.showsRomaji.v1"
        public static let menuBarLyricsReadingsAbove = "menuBar.readingsAbove.v1"
        public static let menuBarLyricsFontSize = "menuBar.fontSize.v1"
        public static let connectSpotifyOnLaunch = "general.connectSpotifyOnLaunch"
        public static let playbackSourceMode = "playback.sourceMode"
        public static let autoSearchLyricsOnTrackChange = "general.autoSearchLyricsOnTrackChange"
        public static let preloadUpcomingLyrics = "general.preloadUpcomingLyrics"
        /// Product zero-operation automatic alignment (default off).
        public static let automaticAlignmentEnabled = "automaticAlignment.enabled.v1"
        public static let keepMainWindowOnTop = "general.keepMainWindowOnTop"
        public static let restoreWindowState = "general.restoreWindowState"
        public static let mainWindowFrame = "general.mainWindowFrame"
        public static let floatingWindowFrame = "general.floatingWindowFrame"
        public static let floatingWindowScreenID = "general.floatingWindowScreenID"
        public static let floatingWindowAlwaysOnTop = "general.floatingWindowAlwaysOnTop"
        public static let floatingWindowInteractionMode = "general.floatingWindowInteractionMode"
        public static let floatingWindowWasVisible = "general.floatingWindowWasVisible"
        public static let floatingDesktopFontSize = "desktopLyrics.fontSize"
        public static let floatingDesktopLineMode = "desktopLyrics.lineMode"
        public static let floatingDesktopTheme = "desktopLyrics.theme"
        public static let floatingDesktopCompanion = "desktopLyrics.companion"
        public static let floatingDesktopOriginalColorHex = "desktopLyrics.originalColorHex"
        public static let floatingDesktopHighlightColorHex = "desktopLyrics.highlightColorHex"
        public static let floatingDesktopRubyColorHex = "desktopLyrics.rubyColorHex"
        public static let floatingDesktopTranslationColorHex = "desktopLyrics.translationColorHex"
        public static let floatingDesktopOutlineColorHex = "desktopLyrics.outlineColorHex"
        public static let floatingDesktopOutlineWidth = "desktopLyrics.outlineWidth"
        public static let floatingDesktopKeepsTextOpaque = "desktopLyrics.keepsTextOpaque"
        public static let floatingWindowOpacity = "general.floatingWindowOpacity"
        public static let floatingLyricsPresentation = "general.floatingLyricsPresentation"
        public static let floatingLyricsSurfaceStyle = "general.floatingLyricsSurfaceStyle"
        public static let capsuleWindowHorizontalOffset = "general.capsuleWindowHorizontalOffset"
        public static let capsuleWindowScreenID = "general.capsuleWindowScreenID"
        public static let capsuleWindowWasVisible = "general.capsuleWindowWasVisible"
        public static let showOriginal = "display.showOriginal"
        public static let showTranslation = "display.showTranslation"
        public static let showRomaji = "display.showRomaji"
        public static let showPinyin = "display.showPinyin"
        public static let kanaDisplayMode = "display.kanaDisplayMode"
        public static let fontSize = "display.fontSize"
        public static let assistantFontSize = "display.assistantFontSize"
        public static let inactiveOpacity = "display.inactiveOpacity"
        public static let rubyFontSize = "display.rubyFontSize"
        public static let hideDistantAuxiliary = "display.hideDistantAuxiliary"
        public static let providerEnabled = "lyrics.providers.enabled"
        public static let providerOrder = "lyrics.providers.order"
        /// Single free lyrics source mode. Stable values:
        /// `lyricsSourceMode.standardFree.v1` / `lyricsSourceMode.experimentalFree.v1`.
        public static let lyricsSourceMode = "lyrics.sourceMode"
        public static let aiBaseURL = "ai.baseURL"
        public static let aiModel = "ai.model"
        public static let aiTargetLanguage = "ai.targetLanguage"
        public static let aiStyle = "ai.style"
        public static let aiCustomSystemPrompt = "ai.customSystemPrompt"
        public static let aiTemperature = "ai.temperature"
        public static let aiTimeout = "ai.timeout"
        public static let aiAutoTranslateNewLyrics = "ai.autoTranslateNewLyrics"
        public static let aiAPIKeyConfigured = "ai.apiKeyConfigured"
        public static let aiModelDirectoryCache = "ai.modelDirectory.cache"
        public static let aiModelDirectoryRefreshedAt = "ai.modelDirectory.refreshedAt"
        public static let aiEngineID = "ai.engineID"
        public static let aiPromptPresetID = "ai.promptPresetID"
        public static let aiProfileID = "ai.profileID"
        public static let aiProfileSnapshot = "ai.profileSnapshot"
        public static let aiFallbackStrategy = "ai.fallbackStrategy"
        public static let aiWorkflowID = "ai.workflowID"
        public static let aiCodexReasoningEffort = "ai.codexReasoningEffort"
        public static let settingsCenterPresentation = "settings.centerPresentation"
        public static let readingPreferences = "reading.preferences.v1"
        public static let v3PlaybackDetailsOnHover = "v3.playbackDetailsOnHover"
        public static let v3ExpandArtworkWhenDetailsHidden = "v3.expandArtworkWhenDetailsHidden.v1"
        public static let v3ShowForegroundArtwork = "v3.showForegroundArtwork.v1"
        public static let v3EdgeProgressEnabled = "v3.edgeProgress.enabled.v1"
        public static let v3EdgeProgressColorHex = "v3.edgeProgress.colorHex.v1"
        public static let v3EdgeProgressColorMode = "v3.edgeProgress.colorMode.v1"
        public static let v3AmbientBackgroundShowsCompleteArtwork = "v3.ambientBackgroundShowsCompleteArtwork.v1"
        /// Preserved historical global offset. New runtime reads/writes use
        /// `lyricsOffsetStore`; this key is never migrated or overwritten.
        public static let lyricsPresentationOffset = "lyrics.presentationOffset.v1"
        public static let v3LyricsPositions = "v3.lyricsPositions.v1"
        public static let v3AtmosphereLevels = "v3.atmosphere.levels.v1"
        public static let v3StageReadabilityEnabled = "v3.stageReadabilityEnabled"
        public static let v3BackdropBlurRadius = "v3.backdropBlurRadius"
        public static let v3BackdropBlurAuthenticAmbient = "v3.backdropBlur.authenticAmbient.v1"
        public static let v3BackdropBlurAmbient = "v3.backdropBlur.ambient.v1"
        public static let v3BackdropBlurStage = "v3.backdropBlur.stage.v1"
        public static let v3BackdropBlurClassic = "v3.backdropBlur.classic.v1"
        public static let v3BackdropBlurFeathered = "v3.backdropBlur.feathered.v1"
        public static let v3BackdropBlurLyricsOnly = "v3.backdropBlur.lyricsOnly.v1"
        public static let v3BackdropBlurAlbumPoster = "v3.backdropBlur.albumPoster.v1"
        public static let v3GaussianBlur = "v3.gaussian.blur.v1"
        public static let v3GaussianPosition = "v3.gaussian.position.v1"
        public static let v3GaussianArtworkScale = "v3.gaussian.artworkScale.v1"
        public static let v3EnlargedVariant = "v3.enlargedVariant.v1"
        public static let v3ZoomBackdropSizeScale = "v3.zoomBackdropScale.v1"
        public static let v3AmbientVariant = "v3.ambientVariant.v1"
        public static let v3ArtworkPresentation = "v3.artworkPresentation.v1"
        /// Legacy migration input. Do not use as the current presentation state.
        public static let v3AmbientBackdropEnabled = "v3.ambientBackdropEnabled"
        public static let v3ArtworkPosition = "v3.artworkPosition"
        public static let v3ArtworkSizeScale = "v3.artworkSizeScale"
        public static let v3ClassicBackdropSizeScale = "v3.classicBackdropSizeScale.v1"
        public static let v3AmbientBackdropSizeScale = "v3.ambientBackdropScale.v1"
        public static let v3GaussianBackdropSizeScale = "v3.gaussianBackdropScale.v1"
        public static let v3AuthenticAmbientBackdropSizeScale = "v3.authenticAmbientBackdropScale.v1"
        public static let v3ArtworkPositionAuthenticAmbient = "v3.artworkPosition.authenticAmbient.v1"
        public static let v3ArtworkSizeScaleAuthenticAmbient = "v3.artworkSizeScale.authenticAmbient.v1"
        public static let v3ArtworkPositionClassic = "v3.artworkPosition.classic.v1"
        public static let v3ArtworkSizeScaleClassic = "v3.artworkSizeScale.classic.v1"
        public static let v3ArtworkPositionAmbient = "v3.artworkPosition.ambient.v1"
        public static let v3ArtworkSizeScaleAmbient = "v3.artworkSizeScale.ambient.v1"
        public static let v3ArtworkPositionStage = "v3.artworkPosition.stage.v1"
        public static let v3ArtworkSizeScaleStage = "v3.artworkSizeScale.stage.v1"
        // The fourth presentation does not overwrite the existing three modes'
        // shared artwork position/size preferences.
        public static let v3ArtworkPositionFeathered = "v3.artworkPosition.feathered.v1"
        public static let v3ArtworkSizeScaleFeathered = "v3.artworkSizeScale.feathered.v1"
        public static let v3ArtworkPositionLyricsOnly = "v3.artworkPosition.lyricsOnly.v1"
        public static let v3ArtworkSizeScaleLyricsOnly = "v3.artworkSizeScale.lyricsOnly.v1"
        public static let v3ArtworkPositionAlbumPoster = "v3.artworkPosition.albumPoster.v1"
        public static let v3ArtworkSizeScaleAlbumPoster = "v3.artworkSizeScale.albumPoster.v1"
        public static let v3InstrumentalPureImmersion = "v3.instrumentalPureImmersion"
        public static let classicCompanionPresentation = "mainWindow.classicCompanionPresentation.v1"
    }

    public static let currentSettingsVersion = 1

    @Published public private(set) var v3ListeningSceneRawValue = "" {
        didSet { defaults.set(v3ListeningSceneRawValue, forKey: Key.v3ListeningScene) }
    }
    @Published private var scenePresets: [String: V3ScenePreset] = [:] {
        didSet {
            guard oldValue != scenePresets, let data = try? JSONEncoder().encode(scenePresets) else { return }
            defaults.set(data, forKey: Key.v3ScenePresets)
        }
    }
    private var sceneRenderers: [String: String] = [:]
    private var isProjectingScene = false
    @Published public var v3SceneHoverPreviewEnabled = false {
        didSet { defaults.set(v3SceneHoverPreviewEnabled, forKey: Key.v3SceneHoverPreviewEnabled) }
    }
    @Published public var v3BigLineModeEnabled = false {
        didSet { defaults.set(v3BigLineModeEnabled, forKey: Key.v3BigLineModeEnabled) }
    }
    @Published public var v3NightGentleEnabled = false {
        didSet { defaults.set(v3NightGentleEnabled, forKey: Key.v3NightGentleEnabled) }
    }
    @Published public var v3PictureAdvancedExpanded = true {
        didSet { defaults.set(v3PictureAdvancedExpanded, forKey: Key.v3PictureAdvancedExpanded) }
    }
    @Published public var v3ReadingProtection: V3ReadingProtection = .off {
        didSet { defaults.set(v3ReadingProtection.rawValue, forKey: Key.v3ReadingProtection) }
    }
    /// On by default: a bright cover with 清晰度 off still gets a text shadow.
    @Published public var v3BrightCoverShadowEnabled = true {
        didSet { defaults.set(v3BrightCoverShadowEnabled, forKey: Key.v3BrightCoverShadowEnabled) }
    }
    @Published public var menuBarWidthMode = "adaptive" {
        didSet { defaults.set(menuBarWidthMode, forKey: Key.menuBarWidthMode) }
    }
    @Published public var menuBarWidth: Double = 240 {
        didSet {
            let bounded = menuBarWidth.isFinite ? min(480, max(120, menuBarWidth)) : 240
            if bounded != menuBarWidth { menuBarWidth = bounded; return }
            defaults.set(bounded, forKey: Key.menuBarWidth)
        }
    }
    @Published public var menuBarOverflow = "scroll" {
        didSet { defaults.set(menuBarOverflow, forKey: Key.menuBarOverflow) }
    }

    public var v3ListeningScene: V3ListeningScene? { V3ListeningScene(rawValue: v3ListeningSceneRawValue) }
    private static func sceneKey(_ scene: V3ListeningScene, _ renderer: V3ArtworkPresentation) -> String {
        scene.rawValue + "/" + renderer.rawValue
    }
    public func v3Renderer(for scene: V3ListeningScene) -> V3ArtworkPresentation {
        if let raw = sceneRenderers[scene.rawValue], let renderer = V3ArtworkPresentation(rawValue: raw),
           scene.renderers.contains(renderer) { return renderer }
        return scene.defaultRenderer
    }
    public func v3Preset(for scene: V3ListeningScene, renderer: V3ArtworkPresentation? = nil) -> V3ScenePreset {
        let renderer = renderer ?? v3Renderer(for: scene)
        return (scenePresets[Self.sceneKey(scene, renderer)] ?? .initial(scene: scene, renderer: renderer)).normalized()
    }
    private func updateScenePreset(_ change: (inout V3ScenePreset) -> Void) {
        guard !isProjectingScene, let scene = v3ListeningScene else { return }
        let renderer = v3ArtworkPresentation
        var preset = v3Preset(for: scene, renderer: renderer)
        change(&preset)
        let key = Self.sceneKey(scene, renderer)
        let next = preset.normalized()
        if scenePresets[key] != next { scenePresets[key] = next }
    }
    public func selectV3Scene(_ scene: V3ListeningScene, renderer: V3ArtworkPresentation? = nil) {
        let renderer = renderer.flatMap { scene.renderers.contains($0) ? $0 : nil } ?? v3Renderer(for: scene)
        sceneRenderers[scene.rawValue] = renderer.rawValue
        defaults.set(sceneRenderers, forKey: Key.v3SceneRenderers)
        if v3ListeningSceneRawValue != scene.rawValue { v3ListeningSceneRawValue = scene.rawValue }
        applySceneProjection(scene, renderer: renderer)
    }
    private func applySceneProjection(_ scene: V3ListeningScene, renderer: V3ArtworkPresentation) {
        let p = v3Preset(for: scene, renderer: renderer)
        isProjectingScene = true
        defer { isProjectingScene = false }
        if v3ArtworkPresentationRawValue != renderer.rawValue { v3ArtworkPresentationRawValue = renderer.rawValue }
        if v3BackdropBlurRadius != p.blur { v3BackdropBlurRadius = p.blur }
        if v3ArtworkSizeScale != p.foregroundScale { v3ArtworkSizeScale = p.foregroundScale }
        if v3ArtworkPosition != p.foregroundPosition { v3ArtworkPosition = p.foregroundPosition }
        if v3ShowForegroundArtwork != p.foregroundVisible { v3ShowForegroundArtwork = p.foregroundVisible }
    }
    public func selectLegacyV3Presentation(_ renderer: V3ArtworkPresentation) {
        // Restore original proxy values WITHOUT writing the active new scene into old keys.
        isProjectingScene = true
        v3ListeningSceneRawValue = ""
        v3ArtworkPresentationRawValue = renderer.rawValue
        v3BackdropBlurRadius = v3BlurByPresentation[renderer] ?? 36
        v3ArtworkSizeScale = v3PreviewScale(for: renderer, scene: nil)
        v3ArtworkPosition = v3PreviewPosition(for: renderer, scene: nil)
        v3ShowForegroundArtwork = defaults.object(forKey: Key.v3ShowForegroundArtwork) as? Bool ?? true
        isProjectingScene = false
        defaults.set(renderer.rawValue, forKey: Key.v3ArtworkPresentation)
    }
    public func resetCurrentV3Scene() {
        guard let scene = v3ListeningScene else { return }
        let renderer = v3ArtworkPresentation
        scenePresets[Self.sceneKey(scene, renderer)] = .initial(scene: scene, renderer: renderer)
        applySceneProjection(scene, renderer: renderer)
    }
    public func v3ShowsForegroundArtwork(scene: V3ListeningScene?, renderer: V3ArtworkPresentation) -> Bool {
        if let scene { return v3Preset(for: scene, renderer: renderer).foregroundVisible }
        return defaults.object(forKey: Key.v3ShowForegroundArtwork) as? Bool ?? true
    }

    /// Bright-cover readability for 封面 (静止 and 流动) and 舞台 only. An
    /// explicit 文字阴影 or 柔和光晕 choice is never overridden, and turning
    /// the switch off keeps 关闭 truly off.
    public func v3EffectiveReadingProtection(scene: V3ListeningScene?,
                                             renderer: V3ArtworkPresentation,
                                             coverLuminance: Double) -> V3ReadingProtection {
        guard v3BrightCoverShadowEnabled,
              v3ReadingProtection == .off,
              scene == .coverPhoto,
              renderer == .ambient || renderer == .classicGaussian || renderer == .stage,
              coverLuminance > 0.6 else { return v3ReadingProtection }
        return .shadow
    }


    private let defaults: UserDefaults
    private var providerModelSettings: TranslationModelSettingsStore?
    private var providerModelObservers: Set<AnyCancellable> = []

    public var translationModelSettings: TranslationModelSettingsStore {
        if let providerModelSettings { return providerModelSettings }
        let store = TranslationModelSettingsStore(defaults: defaults, configuration: aiTranslationConfiguration)
        providerModelSettings = store
        store.$models.sink { [weak self] in self?.aiCachedModels = $0 }
            .store(in: &providerModelObservers)
        store.$status.sink { [weak self] in self?.aiModelDirectoryStatus = $0 }
            .store(in: &providerModelObservers)
        store.$selectionNotice.sink { [weak self] in self?.aiModelSelectionNotice = $0 }
            .store(in: &providerModelObservers)
        let restored = store.restored(aiTranslationConfiguration)
        if restored != aiTranslationConfiguration { aiTranslationConfiguration = restored }
        return store
    }

    /// Configuration-only: switching providers never refreshes a directory or
    /// starts a model request. Each backend retains its own model and options.
    public func selectTranslationProvider(_ engineID: String) {
        let store = translationModelSettings
        let current = aiTranslationConfiguration.engineID
        var target = engineID
        if engineID == TranslationEngineID.geminiCLI.rawValue,
           TranslationEngineCatalog.topLevelID(for: current) != engineID {
            target = defaults.string(forKey: "ai.lastGeminiBackend.v1") ?? engineID
        } else if engineID == TranslationEngineID.openAICompatible.rawValue,
                  TranslationEngineCatalog.topLevelID(for: current) != engineID {
            target = store.preferredAPIBackend
        }
        guard TranslationEngineCatalog.metadata(for: target) != nil, current != target else { return }
        aiTranslationConfiguration = store.selectProvider(from: aiTranslationConfiguration, to: target)
        if TranslationEngineCatalog.topLevelID(for: target) == TranslationEngineID.geminiCLI.rawValue {
            defaults.set(target, forKey: "ai.lastGeminiBackend.v1")
        }
    }

    /// Translation choices use the same injected preferences scope as settings.
    var translationSelectionDefaults: UserDefaults { defaults }
    private var v3BlurByPresentation: [V3ArtworkPresentation: Double] = [:]
    private var isApplyingStoredV3Blur = false

    /// Presentation choices share this UserDefaults boundary with the rest
    /// of the settings store. The selection object is metadata/selection
    /// only; it never owns a playback or lyrics runtime.
    public let presentationSelections: PresentationSelectionStore
    public let translationProfiles: TranslationProfileStore
    public let readingUserDictionary: ReadingUserDictionaryStore
    public let lyricsOffsetStore: ScopedLyricsOffsetStore

    @Published public var settingsCenterPresentationRawValue: String {
        didSet { defaults.set(settingsCenterPresentationRawValue, forKey: Key.settingsCenterPresentation) }
    }

    @Published public var mainWindowLayoutStyleRawValue: String {
        didSet { defaults.set(mainWindowLayoutStyleRawValue, forKey: Key.mainWindowLayoutStyle) }
    }

    @Published public var classicCompanionPresentationRawValue: String {
        didSet {
            defaults.set(
                classicCompanionPresentationRawValue,
                forKey: Key.classicCompanionPresentation
            )
        }
    }

    @Published public var automaticCompactLyricsFocus: Bool {
        didSet { defaults.set(automaticCompactLyricsFocus, forKey: Key.automaticCompactLyricsFocus) }
    }

    @Published public var menuBarLyricsEnabled: Bool {
        didSet { defaults.set(menuBarLyricsEnabled, forKey: Key.menuBarLyricsEnabled) }
    }
    @Published public var menuBarLyricsShowsFullLine: Bool {
        didSet { defaults.set(menuBarLyricsShowsFullLine, forKey: Key.menuBarLyricsShowsFullLine) }
    }
    @Published public var menuBarLyricsShowsOriginal: Bool {
        didSet { defaults.set(menuBarLyricsShowsOriginal, forKey: Key.menuBarLyricsShowsOriginal) }
    }
    @Published public var menuBarLyricsShowsTranslation: Bool {
        didSet { defaults.set(menuBarLyricsShowsTranslation, forKey: Key.menuBarLyricsShowsTranslation) }
    }
    @Published public var menuBarLyricsShowsKana: Bool {
        didSet { defaults.set(menuBarLyricsShowsKana, forKey: Key.menuBarLyricsShowsKana) }
    }
    @Published public var menuBarLyricsShowsRomaji: Bool {
        didSet { defaults.set(menuBarLyricsShowsRomaji, forKey: Key.menuBarLyricsShowsRomaji) }
    }
    @Published public var menuBarLyricsReadingsAbove: Bool {
        didSet { defaults.set(menuBarLyricsReadingsAbove, forKey: Key.menuBarLyricsReadingsAbove) }
    }
    @Published public var menuBarLyricsFontSize: Double {
        didSet { defaults.set(menuBarLyricsFontSize, forKey: Key.menuBarLyricsFontSize) }
    }

    @Published public var connectSpotifyOnLaunch: Bool {
        didSet { defaults.set(connectSpotifyOnLaunch, forKey: Key.connectSpotifyOnLaunch) }
    }

    @Published public var playbackSourceMode: PlaybackSourceMode {
        didSet { defaults.set(playbackSourceMode.rawValue, forKey: Key.playbackSourceMode) }
    }

    @Published public var autoSearchLyricsOnTrackChange: Bool {
        didSet { defaults.set(autoSearchLyricsOnTrackChange, forKey: Key.autoSearchLyricsOnTrackChange) }
    }

    @Published public var preloadUpcomingLyrics: Bool {
        didSet { defaults.set(preloadUpcomingLyrics, forKey: Key.preloadUpcomingLyrics) }
    }

    /// When enabled, playing an unsynced plain-lyrics track may auto-capture and align.
    @Published public var automaticAlignmentEnabled: Bool {
        didSet { defaults.set(automaticAlignmentEnabled, forKey: Key.automaticAlignmentEnabled) }
    }

    @Published public var keepMainWindowOnTop: Bool {
        didSet { defaults.set(keepMainWindowOnTop, forKey: Key.keepMainWindowOnTop) }
    }

    @Published public var restoreWindowState: Bool {
        didSet { defaults.set(restoreWindowState, forKey: Key.restoreWindowState) }
    }

    @Published public var floatingWindowAlwaysOnTop: Bool {
        didSet { defaults.set(floatingWindowAlwaysOnTop, forKey: Key.floatingWindowAlwaysOnTop) }
    }

    @Published public var floatingWindowInteractionModeRawValue: String {
        didSet { defaults.set(floatingWindowInteractionModeRawValue, forKey: Key.floatingWindowInteractionMode) }
    }

    @Published public var floatingWindowWasVisible: Bool {
        didSet { defaults.set(floatingWindowWasVisible, forKey: Key.floatingWindowWasVisible) }
    }

    @Published public var floatingDesktopFontSize: Double {
        didSet { defaults.set(floatingDesktopFontSize, forKey: Key.floatingDesktopFontSize) }
    }
    @Published public var floatingDesktopLineMode: String {
        didSet { defaults.set(floatingDesktopLineMode, forKey: Key.floatingDesktopLineMode) }
    }
    @Published public var floatingDesktopTheme: String {
        didSet { defaults.set(floatingDesktopTheme, forKey: Key.floatingDesktopTheme) }
    }
    @Published public var floatingDesktopCompanion: String {
        didSet { defaults.set(floatingDesktopCompanion, forKey: Key.floatingDesktopCompanion) }
    }

    @Published public var floatingDesktopOriginalColorHex: String {
        didSet { defaults.set(floatingDesktopOriginalColorHex, forKey: Key.floatingDesktopOriginalColorHex) }
    }
    @Published public var floatingDesktopHighlightColorHex: String {
        didSet { defaults.set(floatingDesktopHighlightColorHex, forKey: Key.floatingDesktopHighlightColorHex) }
    }
    @Published public var floatingDesktopRubyColorHex: String {
        didSet { defaults.set(floatingDesktopRubyColorHex, forKey: Key.floatingDesktopRubyColorHex) }
    }
    @Published public var floatingDesktopTranslationColorHex: String {
        didSet { defaults.set(floatingDesktopTranslationColorHex, forKey: Key.floatingDesktopTranslationColorHex) }
    }
    @Published public var floatingDesktopOutlineColorHex: String {
        didSet { defaults.set(floatingDesktopOutlineColorHex, forKey: Key.floatingDesktopOutlineColorHex) }
    }
    @Published public var floatingDesktopOutlineWidth: Double {
        didSet { defaults.set(floatingDesktopOutlineWidth, forKey: Key.floatingDesktopOutlineWidth) }
    }
    @Published public var floatingDesktopKeepsTextOpaque: Bool {
        didSet { defaults.set(floatingDesktopKeepsTextOpaque, forKey: Key.floatingDesktopKeepsTextOpaque) }
    }

    @Published public var floatingWindowOpacity: Double {
        didSet { defaults.set(floatingWindowOpacity, forKey: Key.floatingWindowOpacity) }
    }

    @Published public var floatingLyricsPresentationRawValue: String {
        didSet { defaults.set(floatingLyricsPresentationRawValue, forKey: Key.floatingLyricsPresentation) }
    }

    @Published public var floatingLyricsSurfaceStyleRawValue: String {
        didSet { defaults.set(floatingLyricsSurfaceStyleRawValue, forKey: Key.floatingLyricsSurfaceStyle) }
    }

    /// Top-capsule state is intentionally internal persistence rather than a
    /// second user-facing settings store.  Only the horizontal offset and
    /// target display are restored; hover/expanded are transient.
    @Published public var capsuleWindowHorizontalOffset: Double {
        didSet { defaults.set(capsuleWindowHorizontalOffset, forKey: Key.capsuleWindowHorizontalOffset) }
    }

    @Published public var capsuleWindowScreenID: String? {
        didSet {
            if let capsuleWindowScreenID, !capsuleWindowScreenID.isEmpty {
                defaults.set(capsuleWindowScreenID, forKey: Key.capsuleWindowScreenID)
            } else {
                defaults.removeObject(forKey: Key.capsuleWindowScreenID)
            }
        }
    }

    @Published public var capsuleWindowWasVisible: Bool {
        didSet { defaults.set(capsuleWindowWasVisible, forKey: Key.capsuleWindowWasVisible) }
    }

    @Published public var displayPreferences: DisplayPreferences {
        didSet { persistDisplayPreferences(displayPreferences) }
    }

    @Published public var readingPreferences: ReadingPreferences {
        didSet { persistReadingPreferences(readingPreferences) }
    }

    @Published public var lyricsProviderConfiguration: LyricsProviderConfiguration {
        didSet { persistProviderConfiguration(lyricsProviderConfiguration) }
    }

    /// Free lyrics source mode (standard vs experimental). Defaults to
    /// standard free. Changing this rebuilds the online provider chain without
    /// touching SQLite versions or TrackIdentity.
    @Published public var lyricsSourceModeRawValue: String {
        didSet { defaults.set(lyricsSourceModeRawValue, forKey: Key.lyricsSourceMode) }
    }

    public var lyricsSourceMode: LyricsSourceMode {
        get { LyricsSourceMode(rawValue: lyricsSourceModeRawValue) ?? .default }
        set { lyricsSourceModeRawValue = newValue.rawValue }
    }

    @Published public var aiTranslationConfiguration: AITranslationConfiguration {
        didSet {
            persistAITranslationConfiguration(aiTranslationConfiguration)
            providerModelSettings?.remember(aiTranslationConfiguration)
        }
    }

    /// This is only a non-secret status flag. The key material itself remains
    /// exclusively in Keychain and is never mirrored into UserDefaults.
    @Published public var aiTranslationAPIKeyConfigured: Bool {
        didSet { defaults.set(aiTranslationAPIKeyConfigured, forKey: Key.aiAPIKeyConfigured) }
    }

    @Published public var v3PlaybackDetailsOnHover: Bool {
        didSet { defaults.set(v3PlaybackDetailsOnHover, forKey: Key.v3PlaybackDetailsOnHover) }
    }

    @Published public var v3ExpandArtworkWhenDetailsHidden: Bool {
        didSet { defaults.set(v3ExpandArtworkWhenDetailsHidden, forKey: Key.v3ExpandArtworkWhenDetailsHidden) }
    }

    @Published public var v3ShowForegroundArtwork: Bool {
        didSet {
            guard !isProjectingScene else { return }
            if v3ListeningScene != nil { updateScenePreset { $0.foregroundVisible = v3ShowForegroundArtwork } }
            else { defaults.set(v3ShowForegroundArtwork, forKey: Key.v3ShowForegroundArtwork) }
        }
    }

    @Published public var v3EdgeProgressEnabled: Bool {
        didSet { defaults.set(v3EdgeProgressEnabled, forKey: Key.v3EdgeProgressEnabled) }
    }

    @Published public var v3EdgeProgressColorHex: String {
        didSet { defaults.set(v3EdgeProgressColorHex, forKey: Key.v3EdgeProgressColorHex) }
    }

    @Published public var v3EdgeProgressColorMode: String {
        didSet { defaults.set(v3EdgeProgressColorMode, forKey: Key.v3EdgeProgressColorMode) }
    }

    /// Ambient background framing is independent of foreground cover size.
    @Published public var v3AmbientBackgroundShowsCompleteArtwork: Bool {
        didSet { defaults.set(v3AmbientBackgroundShowsCompleteArtwork, forKey: Key.v3AmbientBackgroundShowsCompleteArtwork) }
    }

    @Published private var v3BackgroundFraming: [String: Bool] = [:] {
        didSet { defaults.set(v3BackgroundFraming, forKey: "v3.backgroundFramingByPresentation.v1") }
    }
    @Published private var v3AdditionalBackdropScales: [String: Double] = [:] {
        didSet { defaults.set(v3AdditionalBackdropScales, forKey: "v3.additionalBackdropScales.v1") }
    }

    public func v3BackgroundShowsCompleteArtwork(for style: V3ArtworkPresentation) -> Bool {
        v3BackgroundShowsCompleteArtwork(for: style, scene: v3ListeningScene)
    }
    public func v3BackgroundShowsCompleteArtwork(for style: V3ArtworkPresentation, scene: V3ListeningScene?) -> Bool {
        if let scene { return v3Preset(for: scene, renderer: style).completeArtwork }
        if style == .ambient { return v3AmbientBackgroundShowsCompleteArtwork }
        return v3BackgroundFraming[style.rawValue] ?? (style == .stage || style == .ambientFeathered)
    }

    public func setV3BackgroundShowsCompleteArtwork(_ value: Bool, for style: V3ArtworkPresentation) {
        if v3ListeningScene != nil { updateScenePreset { $0.completeArtwork = value }; return }
        if style == .ambient { v3AmbientBackgroundShowsCompleteArtwork = value }
        else { v3BackgroundFraming[style.rawValue] = value }
    }

    /// Old global setting remains available only for an explicit history note.
    /// Reading this value never assigns it to a song or lyrics version.
    public var legacyLyricsPresentationOffset: Double? {
        (defaults.object(forKey: Key.lyricsPresentationOffset) as? NSNumber)?.doubleValue
    }

    @Published public var v3StageReadabilityEnabled: Bool {
        didSet { defaults.set(v3StageReadabilityEnabled, forKey: Key.v3StageReadabilityEnabled) }
    }

    @Published public var v3BackdropBlurRadius: Double {
        didSet {
            guard !isProjectingScene else { return }
            if v3ListeningScene != nil { updateScenePreset { $0.blur = v3BackdropBlurRadius }; return }
            let presentation = V3ArtworkPresentation(rawValue: v3ArtworkPresentationRawValue) ?? .ambient
            if presentation != .lyricsOnly && presentation != .albumPoster {
                defaults.set(v3BackdropBlurRadius, forKey: Key.v3BackdropBlurRadius)
            }
            guard !isApplyingStoredV3Blur else { return }
            v3BlurByPresentation[presentation] = v3BackdropBlurRadius
            defaults.set(v3BackdropBlurRadius, forKey: Self.v3BlurDefaultsKey(for: presentation))
        }
    }

    @Published public var v3ArtworkPresentationRawValue: String {
        didSet {
            guard !isProjectingScene else { return }
            if let scene = v3ListeningScene, let renderer = V3ArtworkPresentation(rawValue: v3ArtworkPresentationRawValue) {
                if scene.renderers.contains(renderer) { selectV3Scene(scene, renderer: renderer) }
                else { selectLegacyV3Presentation(renderer) }
                return
            }
            defaults.set(v3ArtworkPresentationRawValue, forKey: Key.v3ArtworkPresentation)
            guard let presentation = V3ArtworkPresentation(rawValue: v3ArtworkPresentationRawValue) else { return }

            if presentation.theme == .ambient {
                defaults.set(presentation.rawValue, forKey: Key.v3AmbientVariant)
            } else if presentation.theme == .enlarged {
                defaults.set(presentation.rawValue, forKey: Key.v3EnlargedVariant)
            }

            // Every style has its own keys, with fallbacks to shared keys for migration.
            let previousPresentation = V3ArtworkPresentation(rawValue: oldValue) ?? .ambient
            let positionKey = Self.v3PositionDefaultsKey(for: presentation)
            if Self.v3PositionDefaultsKey(for: previousPresentation) != positionKey {
                let scaleKey = Self.v3ScaleDefaultsKey(for: presentation)
                let isNewComposition = presentation == .lyricsOnly || presentation == .albumPoster
                let nextPosition = defaults.string(forKey: positionKey)
                    ?? defaults.string(forKey: Key.v3ArtworkPosition)
                    ?? (isNewComposition ? "left" : "left")
                let nextScale = defaults.object(forKey: scaleKey) as? Double
                    ?? defaults.object(forKey: Key.v3ArtworkSizeScale) as? Double
                    ?? (isNewComposition ? 1.0 : 1.0)
                if v3ArtworkPosition != nextPosition { v3ArtworkPosition = nextPosition }
                if abs(v3ArtworkSizeScale - nextScale) > 0.001 { v3ArtworkSizeScale = nextScale }
            }

            if let rememberedBlur = v3BlurByPresentation[presentation],
               abs(rememberedBlur - v3BackdropBlurRadius) > 0.001 {
                isApplyingStoredV3Blur = true
                v3BackdropBlurRadius = rememberedBlur
                isApplyingStoredV3Blur = false
            }
        }
    }

    public var v3ArtworkPresentation: V3ArtworkPresentation {
        get { V3ArtworkPresentation(rawValue: v3ArtworkPresentationRawValue) ?? .ambient }
        set { v3ArtworkPresentationRawValue = newValue.rawValue }
    }

    public func v3RememberedPresentation(for theme: V3ArtworkTheme) -> V3ArtworkPresentation {
        if v3ArtworkPresentation.theme == theme { return v3ArtworkPresentation }
        switch theme {
        case .ambient:
            let saved = defaults.string(forKey: Key.v3AmbientVariant).flatMap(V3ArtworkPresentation.init(rawValue:))
            return saved?.theme == .ambient ? saved! : .classic
        case .enlarged:
            let saved = defaults.string(forKey: Key.v3EnlargedVariant).flatMap(V3ArtworkPresentation.init(rawValue:))
            return saved?.theme == .enlarged ? saved! : .ambient
        case .stage: return .stage
        case .lyricsOnly: return .lyricsOnly
        case .albumPoster: return .albumPoster
        }
    }

    // Hover previews read stored style values without changing preferences.
    public func v3PreviewBlur(for style: V3ArtworkPresentation) -> Double {
        v3PreviewBlur(for: style, scene: v3ListeningScene)
    }
    public func v3PreviewBlur(for style: V3ArtworkPresentation, scene: V3ListeningScene?) -> Double {
        if let scene { return v3Preset(for: scene, renderer: style).blur }
        return v3BlurByPresentation[style] ?? 36
    }

    public func v3PreviewPosition(for style: V3ArtworkPresentation) -> String {
        v3PreviewPosition(for: style, scene: v3ListeningScene)
    }
    public func v3PreviewPosition(for style: V3ArtworkPresentation, scene: V3ListeningScene?) -> String {
        if let scene { return v3Preset(for: scene, renderer: style).foregroundPosition }
        let isNewComposition = style == .lyricsOnly || style == .albumPoster
        return defaults.string(forKey: Self.v3PositionDefaultsKey(for: style))
            ?? defaults.string(forKey: Key.v3ArtworkPosition)
            ?? (isNewComposition ? "left" : "left")
    }

    public func v3PreviewScale(for style: V3ArtworkPresentation) -> Double {
        v3PreviewScale(for: style, scene: v3ListeningScene)
    }
    public func v3PreviewScale(for style: V3ArtworkPresentation, scene: V3ListeningScene?) -> Double {
        if let scene { return v3Preset(for: scene, renderer: style).foregroundScale }
        let isNewComposition = style == .lyricsOnly || style == .albumPoster
        return defaults.object(forKey: Self.v3ScaleDefaultsKey(for: style)) as? Double
            ?? defaults.object(forKey: Key.v3ArtworkSizeScale) as? Double
            ?? (isNewComposition ? 1.0 : 1.0)
    }

    public func v3PreviewBackdropScale(for style: V3ArtworkPresentation) -> Double {
        v3PreviewBackdropScale(for: style, scene: v3ListeningScene)
    }
    public func v3PreviewBackdropScale(for style: V3ArtworkPresentation, scene: V3ListeningScene?) -> Double {
        if let scene { return v3Preset(for: scene, renderer: style).backdropScale }
        switch style {
        case .authenticAmbient:
            return v3AuthenticAmbientBackdropSizeScale
        case .classic:
            return v3ClassicBackdropSizeScale
        case .ambient:
            return v3AmbientBackdropSizeScale
        case .classicGaussian:
            return v3GaussianBackdropSizeScale
        default:
            return v3AdditionalBackdropScales[style.rawValue] ?? 1
        }
    }

    public func v3BackdropScale(for presentation: V3ArtworkPresentation) -> Double {
        v3PreviewBackdropScale(for: presentation, scene: v3ListeningScene)
    }

    public func setV3BackdropScale(_ value: Double, for presentation: V3ArtworkPresentation) {
        let value = value.isFinite ? min(1.4, max(0.8, value)) : 1
        if v3ListeningScene != nil { updateScenePreset { $0.backdropScale = value }; return }
        switch presentation {
        case .authenticAmbient: v3AuthenticAmbientBackdropSizeScale = value
        case .classic: v3ClassicBackdropSizeScale = value
        case .ambient: v3AmbientBackdropSizeScale = value
        case .classicGaussian: v3GaussianBackdropSizeScale = value
        default: v3AdditionalBackdropScales[presentation.rawValue] = value
        }
    }

    public func v3PreviewLyricsPosition(for style: V3ArtworkPresentation) -> String {
        v3PreviewLyricsPosition(for: style, scene: v3ListeningScene)
    }
    public func v3PreviewLyricsPosition(for style: V3ArtworkPresentation, scene: V3ListeningScene?) -> String {
        if let scene { return v3Preset(for: scene, renderer: style).lyricsPosition }
        return v3LyricsPositions[style.rawValue] ?? "automatic"
    }

    @Published private var v3LyricsPositions: [String: String] = [:]
    @Published private var v3AtmosphereLevels: [String: Int] = [:] {
        didSet { defaults.set(v3AtmosphereLevels, forKey: Key.v3AtmosphereLevels) }
    }

    public func v3AtmosphereLevel(for presentation: V3ArtworkPresentation) -> Int {
        v3AtmosphereLevel(for: presentation, scene: v3ListeningScene)
    }
    public func v3AtmosphereLevel(for presentation: V3ArtworkPresentation, scene: V3ListeningScene?) -> Int {
        if let scene { return v3Preset(for: scene, renderer: presentation).atmosphere }
        return min(2, max(0, v3AtmosphereLevels[presentation.rawValue] ?? 0))
    }

    /// 背景明暗 belongs to 原版环境光's scene preset; legacy renderers keep
    /// their established look.
    public func v3BackgroundBrightness(for presentation: V3ArtworkPresentation,
                                       scene: V3ListeningScene?) -> Double {
        guard let scene else { return 1 }
        return v3Preset(for: scene, renderer: presentation).backgroundBrightness
    }

    public func setV3BackgroundBrightness(_ value: Double, for presentation: V3ArtworkPresentation) {
        guard v3ListeningScene != nil else { return }
        let next = value.isFinite ? min(1.4, max(0.6, value)) : 1
        updateScenePreset { $0.backgroundBrightness = next }
    }

    public func setV3AtmosphereLevel(_ level: Int, for presentation: V3ArtworkPresentation) {
        let storedLevel = min(2, max(0, level))
        if v3ListeningScene != nil { updateScenePreset { $0.atmosphere = storedLevel }; return }
        guard v3AtmosphereLevels[presentation.rawValue] != storedLevel else { return }
        v3AtmosphereLevels[presentation.rawValue] = storedLevel
    }

    /// Reading placement is remembered per composition, independently of artwork.
    public var v3LyricsPosition: String {
        get { v3PreviewLyricsPosition(for: v3ArtworkPresentation) }
        set {
            let value = ["automatic", "left", "center", "right"].contains(newValue) ? newValue : "automatic"
            if v3ListeningScene != nil { updateScenePreset { $0.lyricsPosition = value }; return }
            v3LyricsPositions[v3ArtworkPresentation.rawValue] = value
            defaults.set(v3LyricsPositions, forKey: Key.v3LyricsPositions)
        }
    }

    private static func v3BlurDefaultsKey(for presentation: V3ArtworkPresentation) -> String {
        switch presentation {
        case .authenticAmbient: return Key.v3BackdropBlurAuthenticAmbient
        case .ambient: return Key.v3BackdropBlurAmbient
        case .stage: return Key.v3BackdropBlurStage
        case .classic: return Key.v3BackdropBlurClassic
        case .classicGaussian: return Key.v3GaussianBlur
        case .ambientFeathered: return Key.v3BackdropBlurFeathered
        case .lyricsOnly: return Key.v3BackdropBlurLyricsOnly
        case .albumPoster: return Key.v3BackdropBlurAlbumPoster
        }
    }

    private static func v3PositionDefaultsKey(for presentation: V3ArtworkPresentation) -> String {
        switch presentation {
        case .authenticAmbient: return Key.v3ArtworkPositionAuthenticAmbient
        case .ambient: return Key.v3ArtworkPositionAmbient
        case .stage: return Key.v3ArtworkPositionStage
        case .classic: return Key.v3ArtworkPositionClassic
        case .classicGaussian: return Key.v3GaussianPosition
        case .ambientFeathered: return Key.v3ArtworkPositionFeathered
        case .lyricsOnly: return Key.v3ArtworkPositionLyricsOnly
        case .albumPoster: return Key.v3ArtworkPositionAlbumPoster
        }
    }

    private static func v3ScaleDefaultsKey(for presentation: V3ArtworkPresentation) -> String {
        switch presentation {
        case .authenticAmbient: return Key.v3ArtworkSizeScaleAuthenticAmbient
        case .ambient: return Key.v3ArtworkSizeScaleAmbient
        case .stage: return Key.v3ArtworkSizeScaleStage
        case .classic: return Key.v3ArtworkSizeScaleClassic
        case .classicGaussian: return Key.v3GaussianArtworkScale
        case .ambientFeathered: return Key.v3ArtworkSizeScaleFeathered
        case .lyricsOnly: return Key.v3ArtworkSizeScaleLyricsOnly
        case .albumPoster: return Key.v3ArtworkSizeScaleAlbumPoster
        }
    }

    @Published public var v3ArtworkPosition: String {
        didSet {
            guard !isProjectingScene else { return }
            if v3ListeningScene != nil { updateScenePreset { $0.foregroundPosition = v3ArtworkPosition }; return }
            let key = Self.v3PositionDefaultsKey(for: v3ArtworkPresentation)
            defaults.set(v3ArtworkPosition, forKey: key)
        }
    }

    @Published public var v3ArtworkSizeScale: Double {
        didSet {
            guard !isProjectingScene else { return }
            if v3ListeningScene != nil { updateScenePreset { $0.foregroundScale = v3ArtworkSizeScale }; return }
            let key = Self.v3ScaleDefaultsKey(for: v3ArtworkPresentation)
            defaults.set(v3ArtworkSizeScale, forKey: key)
        }
    }

    @Published public var v3ZoomBackdropSizeScale: Double {
        didSet { defaults.set(v3ZoomBackdropSizeScale, forKey: Key.v3ZoomBackdropSizeScale) }
    }

    @Published public var v3ClassicBackdropSizeScale: Double {
        didSet { defaults.set(v3ClassicBackdropSizeScale, forKey: Key.v3ClassicBackdropSizeScale) }
    }

    @Published public var v3AuthenticAmbientBackdropSizeScale: Double {
        didSet { defaults.set(v3AuthenticAmbientBackdropSizeScale, forKey: Key.v3AuthenticAmbientBackdropSizeScale) }
    }

    @Published public var v3AmbientBackdropSizeScale: Double {
        didSet { defaults.set(v3AmbientBackdropSizeScale, forKey: Key.v3AmbientBackdropSizeScale) }
    }

    @Published public var v3GaussianBackdropSizeScale: Double {
        didSet { defaults.set(v3GaussianBackdropSizeScale, forKey: Key.v3GaussianBackdropSizeScale) }
    }

    @Published public var v3InstrumentalPureImmersion: Bool {
        didSet { defaults.set(v3InstrumentalPureImmersion, forKey: Key.v3InstrumentalPureImmersion) }
    }

    /// Model names are non-secret metadata. The directory is cached so the
    /// settings page can be browsed without touching Keychain.
    @Published public private(set) var aiModelDirectoryStatus: TranslationModelDirectoryStatus
    @Published public private(set) var aiCachedModels: [TranslationModelDescriptor]
    @Published public private(set) var aiModelSelectionNotice = ""

    public init(defaults: UserDefaults = .lyricsQ) {
        self.defaults = defaults
        self.lyricsOffsetStore = ScopedLyricsOffsetStore(defaults: defaults)
        self.v3LyricsPositions = (defaults.dictionary(forKey: Key.v3LyricsPositions) as? [String: String] ?? [:])
            .filter { ["automatic", "left", "center", "right"].contains($0.value) }
        self.v3AtmosphereLevels = (defaults.dictionary(forKey: Key.v3AtmosphereLevels) as? [String: Int] ?? [:])
            .filter { V3ArtworkPresentation(rawValue: $0.key) != nil }
            .mapValues { min(2, max(0, $0)) }
        let legacyBlur = defaults.object(forKey: Key.v3BackdropBlurRadius) as? Double ?? 36.0
        let selectedPresentation: V3ArtworkPresentation
        if let storedPresentation = defaults.string(forKey: Key.v3ArtworkPresentation),
           let presentation = V3ArtworkPresentation(rawValue: storedPresentation) {
            self.v3ArtworkPresentationRawValue = storedPresentation
            selectedPresentation = presentation
        } else {
            let legacyAmbient = defaults.object(forKey: Key.v3AmbientBackdropEnabled) as? Bool ?? true
            selectedPresentation = legacyAmbient ? .ambient : .classic
            self.v3ArtworkPresentationRawValue = selectedPresentation.rawValue
        }
        let blurDefaults: [V3ArtworkPresentation: Double] = [
            .authenticAmbient: 25.0,
            .ambient: 58.0,
            .stage: 0.0,
            .classic: 36.0,
            // First selection of the fourth mode starts at the user's existing
            // ambient setting, then remembers its own slider value.
            .classicGaussian: 58.0,
            .ambientFeathered: defaults.object(forKey: Key.v3BackdropBlurAmbient) as? Double ?? 58.0,
            .lyricsOnly: 72.0,
            .albumPoster: 65.0
        ]
        for presentation in V3ArtworkPresentation.allCases {
            let stored = defaults.object(forKey: Self.v3BlurDefaultsKey(for: presentation)) as? Double
            let hasLegacyBlur = presentation != .lyricsOnly && presentation != .albumPoster
            self.v3BlurByPresentation[presentation] = stored
                ?? (presentation == selectedPresentation && hasLegacyBlur ? legacyBlur : blurDefaults[presentation] ?? legacyBlur)
        }
        self.v3PlaybackDetailsOnHover = defaults.bool(forKey: Key.v3PlaybackDetailsOnHover)
        self.v3ExpandArtworkWhenDetailsHidden = defaults.object(forKey: Key.v3ExpandArtworkWhenDetailsHidden) as? Bool ?? true
        self.v3ShowForegroundArtwork = defaults.object(forKey: Key.v3ShowForegroundArtwork) as? Bool ?? true
        self.v3EdgeProgressEnabled = defaults.object(forKey: Key.v3EdgeProgressEnabled) as? Bool ?? false
        self.v3EdgeProgressColorHex = defaults.string(forKey: Key.v3EdgeProgressColorHex) ?? "FFFFFF"
        let edgeColorMode = defaults.string(forKey: Key.v3EdgeProgressColorMode) ?? "randomSong"
        self.v3EdgeProgressColorMode = ["manual", "flow", "randomSong", "artwork"].contains(edgeColorMode) ? edgeColorMode : "randomSong"
        self.v3AmbientBackgroundShowsCompleteArtwork = defaults.bool(forKey: Key.v3AmbientBackgroundShowsCompleteArtwork)
        self.v3BackgroundFraming = defaults.dictionary(forKey: "v3.backgroundFramingByPresentation.v1") as? [String: Bool] ?? [:]
        var backgroundScales = defaults.dictionary(forKey: "v3.additionalBackdropScales.v1") as? [String: Double] ?? [:]
        for mode in [V3ArtworkPresentation.stage, .ambientFeathered, .lyricsOnly, .albumPoster] {
            let previous = backgroundScales[mode.rawValue]
                ?? (defaults.object(forKey: Self.v3ScaleDefaultsKey(for: mode)) as? Double)
                ?? (defaults.object(forKey: Key.v3ArtworkSizeScale) as? Double) ?? 1
            backgroundScales[mode.rawValue] = previous.isFinite ? min(1.4, max(0.8, previous)) : 1
        }
        self.v3AdditionalBackdropScales = backgroundScales
        defaults.set(backgroundScales, forKey: "v3.additionalBackdropScales.v1")
        self.v3StageReadabilityEnabled = defaults.bool(forKey: Key.v3StageReadabilityEnabled)
        self.v3BackdropBlurRadius = self.v3BlurByPresentation[selectedPresentation] ?? legacyBlur
        let positionKey = Self.v3PositionDefaultsKey(for: selectedPresentation)
        let scaleKey = Self.v3ScaleDefaultsKey(for: selectedPresentation)
        let isNewComposition = selectedPresentation == .lyricsOnly || selectedPresentation == .albumPoster
        self.v3ArtworkPosition = defaults.string(forKey: positionKey)
            ?? (isNewComposition ? "left" : defaults.string(forKey: Key.v3ArtworkPosition) ?? "left")
        self.v3ArtworkSizeScale = defaults.object(forKey: scaleKey) as? Double
            ?? (isNewComposition ? 1.0 : defaults.object(forKey: Key.v3ArtworkSizeScale) as? Double ?? 1.0)
        let storedClassicBackdropScale = defaults.object(forKey: Key.v3ClassicBackdropSizeScale) as? Double
        let classicBackdropScale = storedClassicBackdropScale
            ?? defaults.object(forKey: Key.v3ArtworkSizeScale) as? Double ?? 1.0
        self.v3ClassicBackdropSizeScale = classicBackdropScale
        let zoomScale = defaults.object(forKey: Key.v3ZoomBackdropSizeScale) as? Double ?? 1
        self.v3ZoomBackdropSizeScale = zoomScale.isFinite ? min(1.4, max(0.8, zoomScale)) : 1
        let storedAmbientBackdropScale = defaults.object(forKey: Key.v3AmbientBackdropSizeScale) as? Double
        let ambientBackdropScale = storedAmbientBackdropScale
            ?? (zoomScale.isFinite ? min(1.4, max(0.8, zoomScale)) : 1.12)
        self.v3AmbientBackdropSizeScale = ambientBackdropScale
        let storedGaussianBackdropScale = defaults.object(forKey: Key.v3GaussianBackdropSizeScale) as? Double
        let gaussianBackdropScale = storedGaussianBackdropScale
            ?? (zoomScale.isFinite ? min(1.4, max(0.8, zoomScale)) : 1.0)
        self.v3GaussianBackdropSizeScale = gaussianBackdropScale
        let storedAuthenticAmbientBackdropScale = defaults.object(forKey: Key.v3AuthenticAmbientBackdropSizeScale) as? Double
        let authenticAmbientBackdropScale = storedAuthenticAmbientBackdropScale ?? 1.0
        self.v3AuthenticAmbientBackdropSizeScale = authenticAmbientBackdropScale
        if storedClassicBackdropScale == nil {
            defaults.set(classicBackdropScale, forKey: Key.v3ClassicBackdropSizeScale)
        }
        if storedAmbientBackdropScale == nil {
            defaults.set(ambientBackdropScale, forKey: Key.v3AmbientBackdropSizeScale)
        }
        if storedGaussianBackdropScale == nil {
            defaults.set(gaussianBackdropScale, forKey: Key.v3GaussianBackdropSizeScale)
        }
        if storedAuthenticAmbientBackdropScale == nil {
            defaults.set(authenticAmbientBackdropScale, forKey: Key.v3AuthenticAmbientBackdropSizeScale)
        }
        self.v3InstrumentalPureImmersion = defaults.object(forKey: Key.v3InstrumentalPureImmersion) as? Bool ?? true
        let storedLayout = defaults.string(forKey: Key.mainWindowLayoutStyle)
            ?? MainWindowLayoutStyle.appleMusicImmersiveV3.rawValue
        let storedClassicPresentation = defaults.string(forKey: Key.classicCompanionPresentation)
        let classicPresentation = storedClassicPresentation
            ?? Self.migratedClassicCompanionPresentation(
                defaults: defaults,
                storedLayout: storedLayout
            )
        if storedClassicPresentation == nil {
            defaults.set(classicPresentation, forKey: Key.classicCompanionPresentation)
        }
        // The old focus surface is now the narrow projection of the adaptive
        // classic family. Preserve the maintained split stable ID while
        // migrating the obsolete raw selection without touching source data.
        let layout = storedLayout == MainWindowLayoutStyle.lyricsFocus.rawValue
            ? MainWindowLayoutStyle.immersiveSplit.rawValue
            : storedLayout
        if layout != storedLayout {
            defaults.set(layout, forKey: Key.mainWindowLayoutStyle)
            defaults.set(classicPresentation, forKey: Key.classicCompanionPresentation)
            defaults.set(
                MainWindowLayoutStyle.immersiveSplit.presentationStableID,
                forKey: PresentationSelectionStore.runtimeKey(for: .mainWindow)
            )
        }
        self.presentationSelections = PresentationSelectionStore(defaults: defaults)
        self.translationProfiles = TranslationProfileStore(defaults: defaults)
        self.readingUserDictionary = ReadingUserDictionaryStore(defaults: defaults)
        settingsCenterPresentationRawValue = defaults.string(forKey: Key.settingsCenterPresentation)
            ?? SettingsCenterPresentationID.recommended.rawValue
        mainWindowLayoutStyleRawValue = layout
        classicCompanionPresentationRawValue = classicPresentation
        automaticCompactLyricsFocus = defaults.object(forKey: Key.automaticCompactLyricsFocus) as? Bool ?? false
        menuBarLyricsEnabled = defaults.object(forKey: Key.menuBarLyricsEnabled) as? Bool ?? false
        menuBarLyricsShowsFullLine = defaults.object(forKey: Key.menuBarLyricsShowsFullLine) as? Bool ?? false
        menuBarLyricsShowsOriginal = defaults.object(forKey: Key.menuBarLyricsShowsOriginal) as? Bool ?? true
        menuBarLyricsShowsTranslation = defaults.object(forKey: Key.menuBarLyricsShowsTranslation) as? Bool ?? false
        menuBarLyricsShowsKana = defaults.object(forKey: Key.menuBarLyricsShowsKana) as? Bool ?? false
        menuBarLyricsShowsRomaji = defaults.object(forKey: Key.menuBarLyricsShowsRomaji) as? Bool ?? false
        menuBarLyricsReadingsAbove = defaults.object(forKey: Key.menuBarLyricsReadingsAbove) as? Bool ?? true
        menuBarLyricsFontSize = defaults.object(forKey: Key.menuBarLyricsFontSize) as? Double ?? 13
        connectSpotifyOnLaunch = defaults.object(forKey: Key.connectSpotifyOnLaunch) as? Bool ?? true
        if let rawMode = defaults.string(forKey: Key.playbackSourceMode),
           let mode = PlaybackSourceMode(rawValue: rawMode) {
            playbackSourceMode = mode
        } else {
            playbackSourceMode = .auto
        }
        autoSearchLyricsOnTrackChange = defaults.object(forKey: Key.autoSearchLyricsOnTrackChange) as? Bool ?? true
        preloadUpcomingLyrics = defaults.object(forKey: Key.preloadUpcomingLyrics) as? Bool ?? true
        automaticAlignmentEnabled = defaults.object(forKey: Key.automaticAlignmentEnabled) as? Bool ?? false
        // Keep the normal window behavior by default. Users can opt into
        // always-on-top explicitly in Settings; existing saved choices are
        // preserved because the fallback is only used when the key is absent.
        let keepOnTop = defaults.object(forKey: Key.keepMainWindowOnTop) as? Bool ?? false
        keepMainWindowOnTop = keepOnTop
        restoreWindowState = defaults.object(forKey: Key.restoreWindowState) as? Bool ?? true
        floatingWindowAlwaysOnTop = defaults.object(forKey: Key.floatingWindowAlwaysOnTop) as? Bool ?? true
        floatingWindowInteractionModeRawValue = defaults.string(forKey: Key.floatingWindowInteractionMode)
            ?? "interactive"
        floatingWindowWasVisible = defaults.object(forKey: Key.floatingWindowWasVisible) as? Bool ?? false
        floatingDesktopFontSize = FloatingDesktopTypography.fontSize(defaults.object(forKey: Key.floatingDesktopFontSize) as? Double ?? 34)
        floatingDesktopLineMode = defaults.string(forKey: Key.floatingDesktopLineMode) ?? "double"
        floatingDesktopTheme = defaults.string(forKey: Key.floatingDesktopTheme) ?? "mint"
        let savedCompanion = defaults.string(forKey: Key.floatingDesktopCompanion) ?? "translation"
        floatingDesktopCompanion = savedCompanion == "next" ? "translation" : savedCompanion
        floatingDesktopOriginalColorHex = defaults.object(forKey: Key.floatingDesktopOriginalColorHex) as? String ?? ""
        floatingDesktopHighlightColorHex = defaults.object(forKey: Key.floatingDesktopHighlightColorHex) as? String ?? ""
        floatingDesktopRubyColorHex = defaults.object(forKey: Key.floatingDesktopRubyColorHex) as? String ?? ""
        floatingDesktopTranslationColorHex = defaults.object(forKey: Key.floatingDesktopTranslationColorHex) as? String ?? ""
        floatingDesktopOutlineColorHex = defaults.object(forKey: Key.floatingDesktopOutlineColorHex) as? String ?? ""
        floatingDesktopOutlineWidth = defaults.object(forKey: Key.floatingDesktopOutlineWidth) as? Double ?? 1.25
        floatingDesktopKeepsTextOpaque = defaults.object(forKey: Key.floatingDesktopKeepsTextOpaque) as? Bool ?? true
        floatingWindowOpacity = defaults.object(forKey: Key.floatingWindowOpacity) as? Double ?? 0.96
        floatingLyricsPresentationRawValue = defaults.string(forKey: Key.floatingLyricsPresentation)
            ?? FloatingLyricsPresentationVersion.current.rawValue
        floatingLyricsSurfaceStyleRawValue = defaults.string(forKey: Key.floatingLyricsSurfaceStyle)
            ?? FloatingLyricsSurfaceStyle.ultraTransparent.rawValue
        capsuleWindowHorizontalOffset = defaults.object(forKey: Key.capsuleWindowHorizontalOffset) as? Double ?? 0
        capsuleWindowScreenID = defaults.string(forKey: Key.capsuleWindowScreenID)
        capsuleWindowWasVisible = defaults.object(forKey: Key.capsuleWindowWasVisible) as? Bool ?? false
        displayPreferences = Self.loadDisplayPreferences(defaults: defaults, keepOnTop: keepOnTop)
        readingPreferences = Self.loadReadingPreferences(defaults: defaults)
        lyricsProviderConfiguration = Self.loadProviderConfiguration(defaults: defaults)
        lyricsSourceModeRawValue = defaults.string(forKey: Key.lyricsSourceMode)
            ?? LyricsSourceMode.default.rawValue
        aiTranslationConfiguration = Self.loadAITranslationConfiguration(defaults: defaults)
        aiTranslationAPIKeyConfigured = defaults.object(forKey: Key.aiAPIKeyConfigured) as? Bool ?? false
        let cachedModels = Self.loadCachedModels(defaults: defaults)
        aiCachedModels = cachedModels
        aiModelDirectoryStatus = cachedModels.isEmpty ? .idle : .loaded(cachedModels)

        if defaults.object(forKey: Key.settingsVersion) == nil {
            defaults.set(Self.currentSettingsVersion, forKey: Key.settingsVersion)
        }

        // Upgrade never rewrites the last selected legacy renderer. New scenes are opt-in.
        self.v3SceneHoverPreviewEnabled = defaults.object(forKey: Key.v3SceneHoverPreviewEnabled) as? Bool
            ?? (defaults.object(forKey: Key.v3ArtworkPresentation) != nil)
        self.v3BigLineModeEnabled = defaults.bool(forKey: Key.v3BigLineModeEnabled)
        self.v3NightGentleEnabled = defaults.bool(forKey: Key.v3NightGentleEnabled)
        self.v3PictureAdvancedExpanded = defaults.object(forKey: Key.v3PictureAdvancedExpanded) as? Bool ?? true
        self.v3ReadingProtection = V3ReadingProtection.restored(defaults.string(forKey: Key.v3ReadingProtection))
        defaults.set(v3ReadingProtection.rawValue, forKey: Key.v3ReadingProtection)
        self.v3BrightCoverShadowEnabled = defaults.object(forKey: Key.v3BrightCoverShadowEnabled) as? Bool ?? true
        self.menuBarWidthMode = defaults.string(forKey: Key.menuBarWidthMode) == "fixed" ? "fixed" : "adaptive"
        let requestedWidth = defaults.object(forKey: Key.menuBarWidth) as? Double ?? 240
        self.menuBarWidth = requestedWidth.isFinite ? min(480, max(120, requestedWidth)) : 240
        self.menuBarOverflow = defaults.string(forKey: Key.menuBarOverflow) == "ellipsis" ? "ellipsis" : "scroll"
        if let data = defaults.data(forKey: Key.v3ScenePresets),
           let stored = try? JSONDecoder().decode([String: V3ScenePreset].self, from: data) {
            self.scenePresets = stored.mapValues { $0.normalized() }
        }
        self.sceneRenderers = defaults.dictionary(forKey: Key.v3SceneRenderers) as? [String: String] ?? [:]
        if let raw = defaults.string(forKey: Key.v3ListeningScene), let scene = V3ListeningScene(rawValue: raw) {
            self.v3ListeningSceneRawValue = scene.rawValue
            applySceneProjection(scene, renderer: v3Renderer(for: scene))
        }
        migrateMergedSceneEntriesIfNeeded()
    }

    /// The R3 entry merge removes six 经典版 entries. Anyone sitting on one of
    /// them moves to the merged entry that draws the same picture, carrying the
    /// old parameters into the target so the first frame matches what they had.
    /// 经典·柔和光晕 and 经典·封面海报 stay as entries and are left alone.
    private func migrateMergedSceneEntriesIfNeeded() {
        guard !defaults.bool(forKey: Key.v3SceneEntriesMerged) else { return }
        defaults.set(true, forKey: Key.v3SceneEntriesMerged)
        guard v3ListeningScene == nil,
              let legacy = V3ArtworkPresentation(rawValue: v3ArtworkPresentationRawValue) else { return }
        switch legacy {
        case .authenticAmbient:
            adoptMergedEntry(scene: .originalAmbient, renderer: .authenticAmbient, legacy: legacy)
        case .ambient:
            adoptMergedEntry(scene: .originalAmbient, renderer: .authenticAmbient, legacy: legacy)
        case .ambientFeathered:
            adoptMergedEntry(scene: .flowingField, renderer: .ambientFeathered, legacy: legacy)
        case .stage:
            adoptMergedEntry(scene: .coverPhoto, renderer: .stage, legacy: legacy)
        case .lyricsOnly:
            adoptMergedEntry(scene: .focusedLyrics, renderer: .lyricsOnly, legacy: legacy)
        case .classicGaussian:
            copyLegacyParameters(from: .classicGaussian, to: .classic)
            selectLegacyV3Presentation(.classic)
        case .classic, .albumPoster:
            break
        }
    }

    private func adoptMergedEntry(scene: V3ListeningScene,
                                  renderer: V3ArtworkPresentation,
                                  legacy: V3ArtworkPresentation) {
        var preset = V3ScenePreset.initial(scene: scene, renderer: renderer)
        preset.blur = v3BlurByPresentation[legacy] ?? preset.blur
        preset.foregroundScale = v3PreviewScale(for: legacy, scene: nil)
        preset.foregroundPosition = v3PreviewPosition(for: legacy, scene: nil)
        preset.foregroundVisible = defaults.object(forKey: Key.v3ShowForegroundArtwork) as? Bool
            ?? preset.foregroundVisible
        preset.backdropScale = v3PreviewBackdropScale(for: legacy, scene: nil)
        preset.completeArtwork = v3BackgroundShowsCompleteArtwork(for: legacy)
        preset.lyricsPosition = v3PreviewLyricsPosition(for: legacy, scene: nil)
        preset.atmosphere = v3AtmosphereLevel(for: legacy, scene: nil)
        scenePresets[Self.sceneKey(scene, renderer)] = preset.normalized()
        selectV3Scene(scene, renderer: renderer)
    }

    private func copyLegacyParameters(from source: V3ArtworkPresentation, to target: V3ArtworkPresentation) {
        if let blur = defaults.object(forKey: Self.v3BlurDefaultsKey(for: source)) as? Double {
            v3BlurByPresentation[target] = blur
            defaults.set(blur, forKey: Self.v3BlurDefaultsKey(for: target))
        }
        if let scale = defaults.object(forKey: Self.v3ScaleDefaultsKey(for: source)) as? Double {
            defaults.set(scale, forKey: Self.v3ScaleDefaultsKey(for: target))
        }
        if let position = defaults.string(forKey: Self.v3PositionDefaultsKey(for: source)) {
            defaults.set(position, forKey: Self.v3PositionDefaultsKey(for: target))
        }
        if let framing = v3BackgroundFraming[source.rawValue] {
            v3BackgroundFraming[target.rawValue] = framing
        }
        if let atmosphere = v3AtmosphereLevels[source.rawValue] {
            v3AtmosphereLevels[target.rawValue] = atmosphere
        }
        if let backdrop = v3AdditionalBackdropScales[source.rawValue] {
            v3AdditionalBackdropScales[target.rawValue] = backdrop
        }
        if source == .classicGaussian, target == .classic {
            v3ClassicBackdropSizeScale = v3GaussianBackdropSizeScale
        }
    }

    /// Recovers the old focus choice from either its legacy layout value or
    /// the presentation catalog. The latter matters for users who already ran
    /// the earlier V1 fusion migration, which rewrote the runtime layout to
    /// immersiveSplit while retaining the catalog selection.
    private static func migratedClassicCompanionPresentation(
        defaults: UserDefaults,
        storedLayout: String
    ) -> String {
        if storedLayout == MainWindowLayoutStyle.lyricsFocus.rawValue {
            return ClassicCompanionPresentation.lyricsFocus.rawValue
        }

        if let data = defaults.data(forKey: PresentationSelectionStore.storageKey),
           let selections = try? JSONDecoder().decode([String: String].self, from: data),
           selections[PresentationCategory.mainWindow.rawValue] == "mainWindow.lyricsFocus.v1" {
            return ClassicCompanionPresentation.lyricsFocus.rawValue
        }

        return ClassicCompanionPresentation.automatic.rawValue
    }

    var mainWindowLayoutStyle: MainWindowLayoutStyle {
        MainWindowLayoutStyle(rawValue: mainWindowLayoutStyleRawValue) ?? .appleMusicImmersiveV3
    }

    var classicCompanionPresentation: ClassicCompanionPresentation {
        get {
            ClassicCompanionPresentation(rawValue: classicCompanionPresentationRawValue)
                ?? .automatic
        }
        set { classicCompanionPresentationRawValue = newValue.rawValue }
    }

    public var settingsCenterPresentation: SettingsCenterPresentationID {
        get {
            SettingsCenterPresentationID(rawValue: settingsCenterPresentationRawValue)
                ?? SettingsCenterPresentationID.recommended
        }
        set { settingsCenterPresentationRawValue = newValue.rawValue }
    }

    public var floatingWindowInteractionMode: FloatingLyricsInteractionMode {
        get { FloatingLyricsInteractionMode(rawValue: floatingWindowInteractionModeRawValue) ?? .interactive }
        set { floatingWindowInteractionModeRawValue = newValue.rawValue }
    }

    public var floatingLyricsPresentation: FloatingLyricsPresentationVersion {
        get {
            FloatingLyricsPresentationVersion(rawValue: floatingLyricsPresentationRawValue)
                ?? .current
        }
        set { floatingLyricsPresentationRawValue = newValue.rawValue }
    }

    public var floatingLyricsSurfaceStyle: FloatingLyricsSurfaceStyle {
        get {
            FloatingLyricsSurfaceStyle(rawValue: floatingLyricsSurfaceStyleRawValue)
                ?? .ultraTransparent
        }
        set { floatingLyricsSurfaceStyleRawValue = newValue.rawValue }
    }

    public var savedFloatingWindowFrame: String? {
        defaults.string(forKey: Key.floatingWindowFrame)
    }

    public var savedFloatingWindowScreenID: String? {
        defaults.string(forKey: Key.floatingWindowScreenID)
    }

    public func saveFloatingWindowFrame(_ frame: String, screenID: String?) {
        defaults.set(frame, forKey: Key.floatingWindowFrame)
        if let screenID, !screenID.isEmpty {
            defaults.set(screenID, forKey: Key.floatingWindowScreenID)
        } else {
            defaults.removeObject(forKey: Key.floatingWindowScreenID)
        }
    }

    public var schemaVersion: Int { DatabaseMigrator.currentVersion }

    /// A manually entered model remains usable even when `/models` is empty,
    /// unsupported, or temporarily unavailable. The raw status is retained
    /// for diagnostics; this presentation status tells the settings UI that
    /// the current model is intentionally being kept as a manual fallback.
    public var aiModelDirectoryDisplayStatus: TranslationModelDirectoryStatus {
        let model = aiTranslationConfiguration.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return aiModelDirectoryStatus }
        switch aiModelDirectoryStatus {
        case .idle, .empty, .unauthorized, .endpointUnsupported, .unavailable:
            return .manualFallback
        case .loading, .loaded, .manualFallback:
            return aiModelDirectoryStatus
        }
    }

    /// Explicit user action only. Reading model names is the only operation
    /// here that touches the API-key store; opening or browsing settings does
    /// not call this method.
    public func refreshAIModelDirectory() {
        translationModelSettings.refresh(aiTranslationConfiguration)
    }

    /// Returns whether a catalog item can be applied to a live runtime
    /// setting. Design-only entries remain browseable but do not become
    /// formal selections. Debug-only entries are likewise rejected by their
    /// catalog availability; v4 is intentionally Release-capable.
    public func canApplyPresentation(
        category: PresentationCategory,
        stableID: String
    ) -> Bool {
        guard let metadata = presentationSelections.catalog.metadata(for: stableID),
              metadata.category == category,
              metadata.availability == .release else {
            return false
        }

        switch category {
        case .mainWindow:
            return [
                "mainWindow.lyricsFocus.v1",
                "mainWindow.immersiveSplit.v2",
                "mainWindow.appleMusicImmersiveV3.v3",
                "mainWindow.directionD.v4"
            ].contains(stableID)
        case .capsule:
            return CapsuleLyricsPresentationVersion(rawValue: stableID) != nil
        case .floatingLyrics:
            return FloatingLyricsPresentationVersion(rawValue: stableID) != nil
        case .backdrop, .lyricsTransition, .lyricsState, .progress, .responsiveLayout:
            return true
        case .fullscreen:
            // The current fullscreen controller has one maintained runtime
            // surface. Its catalog entry remains previewable, but there is no
            // second user-selectable fullscreen implementation yet.
            return false
        }
    }

    /// Applies a catalog selection to the existing runtime settings. This is
    /// the only bridge between the selection catalog and maintained runtime
    /// settings; it does not create a second state source.
    @discardableResult
    public func applyPresentationSelection(
        category: PresentationCategory,
        stableID: String
    ) -> Bool {
        guard canApplyPresentation(category: category, stableID: stableID),
              presentationSelections.apply(category: category, stableID: stableID) else {
            return false
        }

        switch category {
        case .mainWindow:
            let rawValue: String
            switch stableID {
            case "mainWindow.lyricsFocus.v1":
                rawValue = MainWindowLayoutStyle.immersiveSplit.rawValue
                classicCompanionPresentation = .lyricsFocus
            case "mainWindow.immersiveSplit.v2": rawValue = MainWindowLayoutStyle.immersiveSplit.rawValue
            case "mainWindow.appleMusicImmersiveV3.v3": rawValue = MainWindowLayoutStyle.appleMusicImmersiveV3.rawValue
            case "mainWindow.directionD.v4": rawValue = MainWindowLayoutStyle.directionDV4.rawValue
            default: return false
            }
            mainWindowLayoutStyleRawValue = rawValue
        case .capsule:
            defaults.set(stableID, forKey: PresentationSelectionStore.runtimeKey(for: category))
        case .floatingLyrics:
            floatingLyricsPresentationRawValue = stableID
        case .backdrop, .lyricsTransition, .lyricsState, .progress, .responsiveLayout:
            defaults.set(stableID, forKey: PresentationSelectionStore.runtimeKey(for: category))
        case .fullscreen:
            break
        }
        return true
    }

    @discardableResult
    public func restoreRecommendedPresentation(for category: PresentationCategory) -> String {
        let stableID = presentationSelections.restoreRecommended(for: category)
        guard canApplyPresentation(category: category, stableID: stableID) else {
            return stableID
        }
        _ = applyRuntimePresentation(category: category, stableID: stableID)
        return stableID
    }

    private func applyRuntimePresentation(category: PresentationCategory, stableID: String) -> Bool {
        switch category {
        case .mainWindow:
            let rawValue: String
            switch stableID {
            case "mainWindow.lyricsFocus.v1":
                rawValue = MainWindowLayoutStyle.immersiveSplit.rawValue
                classicCompanionPresentation = .lyricsFocus
            case "mainWindow.immersiveSplit.v2": rawValue = MainWindowLayoutStyle.immersiveSplit.rawValue
            case "mainWindow.appleMusicImmersiveV3.v3": rawValue = MainWindowLayoutStyle.appleMusicImmersiveV3.rawValue
            case "mainWindow.directionD.v4": rawValue = MainWindowLayoutStyle.directionDV4.rawValue
            default: return false
            }
            mainWindowLayoutStyleRawValue = rawValue
        case .floatingLyrics:
            guard FloatingLyricsPresentationVersion(rawValue: stableID) != nil else { return false }
            floatingLyricsPresentationRawValue = stableID
        case .capsule, .backdrop, .lyricsTransition, .lyricsState, .progress, .responsiveLayout:
            defaults.set(stableID, forKey: PresentationSelectionStore.runtimeKey(for: category))
        case .fullscreen:
            return false
        }
        return true
    }

    public func setProviderEnabled(_ id: LyricsProviderID, enabled: Bool) {
        guard !id.isLocal else { return }
        // Experimental providers cannot be "armed" while standard free is
        // selected — mode is the single gate. Preferences still keep order.
        if id.isExperimental, !lyricsSourceMode.allowsExperimentalProviders, enabled {
            return
        }
        var configuration = lyricsProviderConfiguration
        if enabled {
            configuration.enabled.insert(id)
        } else {
            configuration.enabled.remove(id)
        }
        configuration.normalize()
        lyricsProviderConfiguration = configuration
    }

    public func isProviderEnabled(_ id: LyricsProviderID) -> Bool {
        lyricsProviderConfiguration.enabled.contains(id)
    }

    /// Preference toggle on, and allowed by the active source mode.
    public func isProviderActiveInCurrentMode(_ id: LyricsProviderID) -> Bool {
        isProviderEnabled(id) && id.isAllowed(in: lyricsSourceMode)
    }

    public func moveProvider(_ id: LyricsProviderID, offset: Int) {
        var configuration = lyricsProviderConfiguration
        guard let index = configuration.order.firstIndex(of: id) else { return }
        let nextIndex = index + offset
        guard configuration.order.indices.contains(nextIndex) else { return }
        configuration.order.swapAt(index, nextIndex)
        lyricsProviderConfiguration = configuration
    }

    /// Restores the recommended personal-use mode. Does not wipe SQLite,
    /// provider order, or individual enable flags.
    public func restoreDefaultLyricsSourceMode() {
        lyricsSourceMode = .default
    }

    public func resetWindowState() {
        defaults.removeObject(forKey: Key.mainWindowFrame)
        defaults.removeObject(forKey: Key.floatingWindowFrame)
        defaults.removeObject(forKey: Key.floatingWindowScreenID)
        defaults.removeObject(forKey: Key.capsuleWindowHorizontalOffset)
        defaults.removeObject(forKey: Key.capsuleWindowScreenID)
        floatingWindowWasVisible = false
        capsuleWindowHorizontalOffset = 0
        capsuleWindowScreenID = nil
        capsuleWindowWasVisible = false
        WindowStatePersistence.shared.resetWindowFrame()
    }

    public var savedWindowFrame: String? {
        defaults.string(forKey: Key.mainWindowFrame)
    }

    private func persistDisplayPreferences(_ preferences: DisplayPreferences) {
        defaults.set(preferences.showOriginal, forKey: Key.showOriginal)
        defaults.set(preferences.showTranslation, forKey: Key.showTranslation)
        defaults.set(preferences.showRomaji, forKey: Key.showRomaji)
        defaults.set(preferences.showPinyin, forKey: Key.showPinyin)
        defaults.set(preferences.kanaDisplayMode.rawValue, forKey: Key.kanaDisplayMode)
        defaults.set(Double(preferences.fontSize), forKey: Key.fontSize)
        defaults.set(Double(preferences.assistantFontSize), forKey: Key.assistantFontSize)
        defaults.set(preferences.opacity, forKey: Key.inactiveOpacity)
        defaults.set(Double(preferences.rubyFontSize), forKey: Key.rubyFontSize)
        defaults.set(preferences.hideDistantAuxiliary, forKey: Key.hideDistantAuxiliary)
    }

    private static func loadDisplayPreferences(defaults: UserDefaults, keepOnTop: Bool) -> DisplayPreferences {
        let rawMode = defaults.string(forKey: Key.kanaDisplayMode)
        let mode = rawMode.flatMap(KanaDisplayMode.init(rawValue:)) ?? .hidden
        return DisplayPreferences(
            showOriginal: defaults.object(forKey: Key.showOriginal) as? Bool ?? true,
            showTranslation: defaults.object(forKey: Key.showTranslation) as? Bool ?? true,
            showRomaji: defaults.object(forKey: Key.showRomaji) as? Bool ?? true,
            showPinyin: defaults.object(forKey: Key.showPinyin) as? Bool ?? true,
            kanaDisplayMode: mode,
            fontSize: CGFloat(defaults.object(forKey: Key.fontSize) as? Double ?? 18),
            opacity: defaults.object(forKey: Key.inactiveOpacity) as? Double ?? 0.85,
            alwaysOnTop: keepOnTop,
            assistantFontSize: CGFloat(defaults.object(forKey: Key.assistantFontSize) as? Double ?? 14),
            rubyFontSize: CGFloat(defaults.object(forKey: Key.rubyFontSize) as? Double ?? 10),
            hideDistantAuxiliary: defaults.object(forKey: Key.hideDistantAuxiliary) as? Bool ?? true
        )
    }

    private static func loadReadingPreferences(defaults: UserDefaults) -> ReadingPreferences {
        let value = ReadingPreferences.persistedOrDefault(from: defaults.data(forKey: Key.readingPreferences))
        let normalized = value.normalizedForCurrentEngines()
        if normalized != value,
           let normalizedData = try? JSONEncoder().encode(normalized) {
            defaults.set(normalizedData, forKey: Key.readingPreferences)
        }
        return normalized
    }

    private func persistReadingPreferences(_ preferences: ReadingPreferences) {
        if let data = try? JSONEncoder().encode(preferences) {
            defaults.set(data, forKey: Key.readingPreferences)
        }
    }

    private static func loadProviderConfiguration(defaults: UserDefaults) -> LyricsProviderConfiguration {
        let order = (defaults.array(forKey: Key.providerOrder) as? [String] ?? [])
            .compactMap(LyricsProviderID.init(rawValue:))
        let enabled = (defaults.array(forKey: Key.providerEnabled) as? [String] ?? [])
            .compactMap(LyricsProviderID.init(rawValue:))
        if order.isEmpty && enabled.isEmpty {
            return .default
        }
        return LyricsProviderConfiguration(
            enabled: enabled.isEmpty ? Set(LyricsProviderID.allCases) : Set(enabled),
            order: order.isEmpty ? LyricsProviderConfiguration.default.order : order
        )
    }

    private func persistProviderConfiguration(_ configuration: LyricsProviderConfiguration) {
        defaults.set(configuration.order.map(\.rawValue), forKey: Key.providerOrder)
        defaults.set(configuration.enabled.map(\.rawValue).sorted(), forKey: Key.providerEnabled)
    }

    private static func loadAITranslationConfiguration(defaults: UserDefaults) -> AITranslationConfiguration {
        AITranslationConfiguration(
            baseURL: defaults.string(forKey: Key.aiBaseURL) ?? "",
            model: defaults.string(forKey: Key.aiModel) ?? "",
            targetLanguage: defaults.string(forKey: Key.aiTargetLanguage) ?? "zh-Hans",
            style: defaults.string(forKey: Key.aiStyle) ?? "natural_song",
            customSystemPrompt: defaults.string(forKey: Key.aiCustomSystemPrompt) ?? "",
            temperature: defaults.object(forKey: Key.aiTemperature) as? Double ?? 0.2,
            timeout: defaults.object(forKey: Key.aiTimeout) as? Double ?? 60,
            autoTranslateNewLyrics: defaults.object(forKey: Key.aiAutoTranslateNewLyrics) as? Bool ?? true,
            engineID: defaults.string(forKey: Key.aiEngineID) ?? TranslationEngineID.openAICompatible.rawValue,
            promptPresetID: defaults.string(forKey: Key.aiPromptPresetID) ?? TranslationPromptPresetID.naturalSong.rawValue,
            profileID: defaults.string(forKey: Key.aiProfileID).flatMap(UUID.init(uuidString:)),
            profileSnapshot: defaults.string(forKey: Key.aiProfileSnapshot) ?? "",
            fallbackStrategy: TranslationFallbackStrategy(rawValue: defaults.string(forKey: Key.aiFallbackStrategy) ?? "none") ?? .none,
            workflowID: defaults.string(forKey: Key.aiWorkflowID) ?? TranslationWorkflowID.contextualV2.rawValue,
            codexReasoningEffort: defaults.string(forKey: Key.aiCodexReasoningEffort) ?? ""
        )
    }

    private func persistAITranslationConfiguration(_ configuration: AITranslationConfiguration) {
        defaults.set(configuration.baseURL, forKey: Key.aiBaseURL)
        defaults.set(configuration.model, forKey: Key.aiModel)
        defaults.set(configuration.targetLanguage, forKey: Key.aiTargetLanguage)
        defaults.set(configuration.style, forKey: Key.aiStyle)
        defaults.set(configuration.customSystemPrompt, forKey: Key.aiCustomSystemPrompt)
        defaults.set(configuration.temperature, forKey: Key.aiTemperature)
        defaults.set(configuration.timeout, forKey: Key.aiTimeout)
        defaults.set(configuration.autoTranslateNewLyrics, forKey: Key.aiAutoTranslateNewLyrics)
        defaults.set(configuration.engineID, forKey: Key.aiEngineID)
        defaults.set(configuration.promptPresetID, forKey: Key.aiPromptPresetID)
        if let profileID = configuration.profileID {
            defaults.set(profileID.uuidString, forKey: Key.aiProfileID)
        } else {
            defaults.removeObject(forKey: Key.aiProfileID)
        }
        defaults.set(configuration.profileSnapshot, forKey: Key.aiProfileSnapshot)
        defaults.set(configuration.fallbackStrategy.rawValue, forKey: Key.aiFallbackStrategy)
        defaults.set(configuration.workflowID, forKey: Key.aiWorkflowID)
        defaults.set(configuration.codexReasoningEffort, forKey: Key.aiCodexReasoningEffort)
    }

    private static func loadCachedModels(defaults: UserDefaults) -> [TranslationModelDescriptor] {
        guard let data = defaults.data(forKey: Key.aiModelDirectoryCache),
              let models = try? JSONDecoder().decode([TranslationModelDescriptor].self, from: data) else { return [] }
        return models
    }
}
