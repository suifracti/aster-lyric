import Foundation

/// The presentation catalog is metadata only.  It describes the rendering
/// choices that already exist in the app without owning playback, lyric
/// sessions, timers, caches, persistence, or user settings.
public enum PresentationCategory: String, CaseIterable, Identifiable, Sendable {
    case mainWindow
    case fullscreen
    case capsule
    case floatingLyrics
    case backdrop
    case lyricsTransition
    case lyricsState
    case progress
    case responsiveLayout

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .mainWindow: return "主窗口"
        case .fullscreen: return "全屏歌词"
        case .capsule: return "顶部胶囊"
        case .floatingLyrics: return "桌面歌词"
        case .backdrop: return "背景"
        case .lyricsTransition: return "歌词过渡"
        case .lyricsState: return "歌词状态"
        case .progress: return "进度呈现"
        case .responsiveLayout: return "响应式布局"
        }
    }
}

public enum PresentationStatus: String, CaseIterable, Sendable {
    case recommended
    case current
    case classic
    case archived
    case experimental

    public var displayName: String {
        switch self {
        case .recommended: return "推荐"
        case .current: return "当前"
        case .classic: return "经典"
        case .archived: return "归档"
        case .experimental: return "实验"
        }
    }
}

public enum PresentationAvailability: String, CaseIterable, Sendable {
    case release
    case debugOnly
    case designOnly
    case archived

    public var displayName: String {
        switch self {
        case .release: return "可运行"
        case .debugOnly: return "仅 Debug"
        case .designOnly: return "仅设计记录"
        case .archived: return "已归档"
        }
    }
}

public enum PresentationSurface: String, CaseIterable, Hashable, Identifiable, Sendable {
    case mainWindow
    case fullscreen
    case capsule
    case floatingLyrics
    case preview

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .mainWindow: return "主窗口"
        case .fullscreen: return "全屏歌词"
        case .capsule: return "顶部胶囊"
        case .floatingLyrics: return "桌面歌词"
        case .preview: return "预览"
        }
    }
}

public struct PresentationMetadata: Identifiable, Hashable, Sendable {
    public let stableID: String
    public let displayName: String
    public let category: PresentationCategory
    public let version: String
    public let status: PresentationStatus
    public let availability: PresentationAvailability
    public let supportsLivePreview: Bool
    public let supportsMockPreview: Bool
    public let accessibilityNotes: String
    public let compatibleSurfaces: [PresentationSurface]

    public init(
        stableID: String,
        displayName: String,
        category: PresentationCategory,
        version: String,
        status: PresentationStatus,
        availability: PresentationAvailability,
        supportsLivePreview: Bool,
        supportsMockPreview: Bool,
        accessibilityNotes: String,
        compatibleSurfaces: [PresentationSurface]
    ) {
        self.stableID = stableID
        self.displayName = displayName
        self.category = category
        self.version = version
        self.status = status
        self.availability = availability
        self.supportsLivePreview = supportsLivePreview
        self.supportsMockPreview = supportsMockPreview
        self.accessibilityNotes = accessibilityNotes
        self.compatibleSurfaces = compatibleSurfaces
    }

    public var id: String { stableID }

    public var isPreviewable: Bool {
        supportsLivePreview || supportsMockPreview
    }
}

/// A strategy is intentionally only a metadata contract in Phase 2.3G.
/// Concrete renderers remain in their existing surfaces; this protocol does
/// not ask them to acquire a second state owner or a second window.
public protocol PresentationStrategy: Sendable {
    var metadata: PresentationMetadata { get }
}

public struct CatalogPresentationStrategy: PresentationStrategy, Hashable, Sendable {
    public let metadata: PresentationMetadata

    public init(metadata: PresentationMetadata) {
        self.metadata = metadata
    }
}

public struct PresentationCatalog: Sendable {
    public static let shared = PresentationCatalog()

    public let entries: [PresentationMetadata]

    public init(entries: [PresentationMetadata]? = nil) {
        self.entries = entries ?? Self.defaultEntries
    }

    public func entries(for category: PresentationCategory) -> [PresentationMetadata] {
        entries.filter { $0.category == category }
    }

    public func metadata(for stableID: String) -> PresentationMetadata? {
        entries.first { $0.stableID == stableID }
    }

    public func recommended(for category: PresentationCategory) -> PresentationMetadata? {
        entries.first { $0.category == category && $0.status == .recommended }
            ?? entries.first { $0.category == category && $0.status == .current }
            ?? entries.first { $0.category == category }
    }

    /// Unknown IDs fail closed to the selected category's recommended/current
    /// entry.  The fallback never crosses category boundaries.
    public func resolve(
        stableID: String,
        category: PresentationCategory
    ) -> PresentationMetadata {
        if let exact = metadata(for: stableID), exact.category == category {
            return exact
        }
        return recommended(for: category)
            ?? PresentationMetadata.unavailableFallback(category: category)
    }

    /// Returns structural catalog problems without crashing a release build.
    /// Contracts and the Debug Preview Lab can surface these diagnostics.
    public func validationIssues() -> [String] {
        var issues: [String] = []
        let groupedIDs = Dictionary(grouping: entries, by: \.stableID)
        for (stableID, matches) in groupedIDs where matches.count > 1 {
            issues.append("duplicate stableID: \(stableID)")
        }
        for category in PresentationCategory.allCases {
            let recommendedCount = entries(for: category).filter { $0.status == .recommended }.count
            if recommendedCount > 1 {
                issues.append("multiple recommended presentations: \(category.rawValue)")
            }
        }
        return issues.sorted()
    }

    private static let defaultEntries: [PresentationMetadata] = [
        // Main window mappings are deliberately separate from the existing
        // persisted layout raw values.  They give those maintainable paths a
        // catalog identity without changing AppSettingsStore.
        entry("mainWindow.lyricsFocus.v1", "歌词专注（已融合）", .mainWindow, "旧", .archived, .archived, true, true, "历史身份仅用于兼容；运行时迁移到经典伴随 V1。", [.mainWindow, .preview]),
        entry("mainWindow.immersiveSplit.v2", "经典伴随 V1", .mainWindow, "1", .classic, .release, true, true, "宽窗口使用沉浸分栏，窄窗口自动收束为歌词优先，不再作为两个版本暴露。", [.mainWindow, .preview]),
        entry("mainWindow.appleMusicImmersiveV3.v3", "专辑沉浸 V3", .mainWindow, "3", .recommended, .release, true, true, "歌词前景必须保持可读；支持 Reduce Transparency 与 Increase Contrast。", [.mainWindow, .preview]),
        entry("mainWindow.directionD.v4", "实验工作台 V0", .mainWindow, "0", .experimental, .release, true, true, "实验主窗口；使用共享实时播放和歌词投影。专辑沉浸 V3 仍为默认。", [.mainWindow, .preview]),

        entry("fullscreen.borderlessPanel.v1", "无边框全屏歌词", .fullscreen, "1", .current, .release, true, true, "支持键盘退出和高对比文字；不依赖额外计时器。", [.fullscreen, .preview]),

        entry("capsule.legacy.v1", "经典胶囊（旧）", .capsule, "1", .archived, .archived, true, true, "旧版仅用于回退和对照。", [.capsule, .preview]),
        entry("capsule.controlFocused.v2", "控制器胶囊", .capsule, "2", .classic, .release, true, true, "控制图标需要保持清晰；不以颜色传达唯一状态。", [.capsule, .preview]),
        // v3 exists as a frozen design/library identity, not as a separate
        // runtime renderer in the current source tree.
        entry("capsule.immersiveCompact.v3", "彩色沉浸胶囊（设计记录）", .capsule, "3", .classic, .designOnly, false, false, "仅保留设计身份；当前没有可运行 Preview Renderer。", [.capsule, .preview]),
        // The restored island is the default. Explicit v2 selections remain runnable.
        entry("capsule.dynamicIslandDark.v4", "灵动岛", .capsule, "4", .current, .release, true, true, "顶边读当句与下一句，展开可定住或收藏。摄像头下留出歌词位置。", [.capsule, .preview]),

        entry("floatingLyrics.legacyPanel.v1", "桌面歌词旧面板", .floatingLyrics, "1", .archived, .release, true, true, "锁定和鼠标穿透状态必须有外部恢复入口。", [.floatingLyrics, .preview]),
        entry("floatingLyrics.transparent.v2", "透明桌面歌词", .floatingLyrics, "2", .current, .release, true, true, "透明模式不依赖背景色；相邻行仍需保持可读。", [.floatingLyrics, .preview]),

        entry("backdrop.legacyV3.v1", "V3 背景兼容层", .backdrop, "1", .archived, .archived, true, true, "只作为兼容身份；继续复用现有快照缓存。", [.mainWindow, .fullscreen, .preview]),
        entry("backdrop.default.v1", "默认背景", .backdrop, "1", .recommended, .release, true, true, "歌词前景优先；不随播放进度重新生成快照。", [.mainWindow, .fullscreen, .preview]),
        entry("backdrop.clear.v1", "清透背景", .backdrop, "1", .classic, .release, true, true, "降低纹理和饱和度；保持稳定歌词暗幕。", [.mainWindow, .fullscreen, .preview]),
        entry("backdrop.immersive.v1", "沉浸背景", .backdrop, "1", .experimental, .release, true, true, "增强封面纹理和局部柔光；不牺牲文字可读性。", [.mainWindow, .fullscreen, .preview]),
        entry("backdrop.highContrast.v1", "高对比背景", .backdrop, "1", .classic, .release, true, true, "增强暗幕和文字对比，适合复杂封面。", [.mainWindow, .fullscreen, .preview]),
        entry("backdrop.custom.v1", "自定义背景（预留）", .backdrop, "1", .experimental, .designOnly, false, false, "尚无用户参数编辑器和可运行 Preview Renderer；仅保留目录身份。", [.mainWindow, .fullscreen, .preview]),

        entry("lyricsTransition.system.v1", "系统歌词过渡", .lyricsTransition, "1", .classic, .release, true, true, "Reduce Motion 下不使用弹簧和明显位移。", [.mainWindow, .fullscreen, .floatingLyrics, .capsule, .preview]),
        entry("lyricsTransition.smoothRelayout.v1", "平滑重排", .lyricsTransition, "1", .recommended, .release, true, true, "以行容器稳定 ID 进行布局变化，不由播放 tick 驱动。", [.mainWindow, .fullscreen, .floatingLyrics, .capsule, .preview]),
        entry("lyricsTransition.none.v1", "无动画", .lyricsTransition, "1", .experimental, .release, true, true, "直接切换布局，适合明确关闭动画的场景。", [.mainWindow, .fullscreen, .floatingLyrics, .capsule, .preview]),

        entry("lyricsStatePresentation.system.v1", "系统状态呈现", .lyricsState, "1", .classic, .release, true, true, "状态文案仍来自共享 LyricsLoadState。", [.mainWindow, .fullscreen, .floatingLyrics, .capsule, .preview]),
        entry("lyricsStatePresentation.contentFirst.v1", "内容优先状态", .lyricsState, "1", .recommended, .release, true, true, "保留一个高频主操作，技术细节不进入主视觉。", [.mainWindow, .fullscreen, .floatingLyrics, .capsule, .preview]),

        entry("progress.standard.v1", "标准进度", .progress, "1", .current, .release, true, true, "只反映播放位置，不把纯文本歌词伪装成同步进度。", [.mainWindow, .capsule, .preview]),
        entry("progress.compact.v1", "紧凑进度", .progress, "1", .classic, .release, true, true, "窄窗口默认弱化轨道，Hover 才增强交互。", [.mainWindow, .capsule, .preview]),
        entry("progress.focus.v1", "歌词专注进度", .progress, "1", .classic, .release, true, true, "歌词阅读优先；保持最小播放状态。", [.mainWindow, .preview]),

        entry("responsiveLayout.wide.v1", "宽窗口", .responsiveLayout, "1", .current, .release, true, true, "完整显示主要内容和控制。", [.mainWindow, .preview]),
        entry("responsiveLayout.medium.v1", "中等窗口", .responsiveLayout, "1", .current, .release, true, true, "缩小非核心区域，保留阅读节奏。", [.mainWindow, .preview]),
        entry("responsiveLayout.small.v1", "小窗口", .responsiveLayout, "1", .current, .release, true, true, "限制进度和辅助层宽度，避免横向撑满。", [.mainWindow, .preview]),
        entry("responsiveLayout.lyricsFocus.v1", "歌词专注布局", .responsiveLayout, "1", .current, .release, true, true, "优先保留当前歌词和必要上下文，不改变用户布局选择。", [.mainWindow, .preview]),

        // Historical Direction D identities remain in the catalog so an old
        // persisted/debug reference is diagnosable, but they are not separate
        // user-selectable releases.  The formal selectable surface is the
        // single independent V4 identity above.
        entry("mainWindow.directionDQuiet.v1", "方向 D 安静伴侣（历史）", .mainWindow, "1", .archived, .archived, false, false, "历史设计身份；请使用 Direction D V4。", [.mainWindow, .preview]),
        entry("mainWindow.directionDWorkbenchInspector.v1", "方向 D 工作台 Inspector（历史）", .mainWindow, "1", .archived, .archived, false, false, "历史设计身份；请使用 Direction D V4。", [.mainWindow, .preview]),
        entry("lyricsStatePresentation.directionDUserLanguage.v1", "方向 D 用户任务语言状态（历史）", .lyricsState, "1", .archived, .archived, false, false, "历史状态身份；不作为独立运行时版本。", [.mainWindow, .fullscreen, .floatingLyrics, .capsule, .preview]),
        entry("responsiveLayout.directionDInspector.v1", "方向 D 响应式 Inspector 布局（历史）", .responsiveLayout, "1", .archived, .archived, false, false, "历史布局身份；不作为独立运行时版本。", [.mainWindow, .preview])
    ]

    private static func entry(
        _ stableID: String,
        _ displayName: String,
        _ category: PresentationCategory,
        _ version: String,
        _ status: PresentationStatus,
        _ availability: PresentationAvailability,
        _ supportsLivePreview: Bool,
        _ supportsMockPreview: Bool,
        _ accessibilityNotes: String,
        _ compatibleSurfaces: [PresentationSurface]
    ) -> PresentationMetadata {
        PresentationMetadata(
            stableID: stableID,
            displayName: displayName,
            category: category,
            version: version,
            status: status,
            availability: availability,
            supportsLivePreview: supportsLivePreview,
            supportsMockPreview: supportsMockPreview,
            accessibilityNotes: accessibilityNotes,
            compatibleSurfaces: compatibleSurfaces
        )
    }
}

private extension PresentationMetadata {
    static func unavailableFallback(category: PresentationCategory) -> PresentationMetadata {
        PresentationMetadata(
            stableID: "\(category.rawValue).unavailable.v0",
            displayName: "暂不可用",
            category: category,
            version: "0",
            status: .archived,
            availability: .archived,
            supportsLivePreview: false,
            supportsMockPreview: false,
            accessibilityNotes: "此版本不可预览。",
            compatibleSurfaces: [.preview]
        )
    }
}
