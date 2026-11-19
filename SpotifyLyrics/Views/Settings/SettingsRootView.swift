import SwiftUI
import AppKit

extension Notification.Name {
    static let lyricIslandOpenConnectionSettings = Notification.Name("lyricIslandOpenConnectionSettings")
    static let lyricIslandOpenAISettings = Notification.Name("lyricIslandOpenAISettings")
}

@MainActor
final class SettingsNavigationRoute: ObservableObject {
    static let shared = SettingsNavigationRoute()

    @Published private(set) var pendingAISettings = false
    @Published var pendingConnectionSettings = false
    @Published var requestedLocation: SettingsLocation?
    @Published var requestedToolbarPanel: V3ToolbarModel.Panel?
    func requestConnectionSettings() {
        pendingConnectionSettings = true
        NotificationCenter.default.post(name: .lyricIslandOpenConnectionSettings, object: nil)
    }

    func requestAISettings() {
        pendingAISettings = true
        NotificationCenter.default.post(name: .lyricIslandOpenAISettings, object: nil)
    }

    @discardableResult
    func consumePendingAISettingsRequest() -> Bool {
        guard pendingAISettings else { return false }
        pendingAISettings = false
        return true
    }
}

struct ToolbarPanelLink: View {
    enum Target {
        case text, translation, picture

        var panel: V3ToolbarModel.Panel {
            switch self {
            case .text: .text
            case .translation: .translation
            case .picture: .picture
            }
        }
    }

    let title: String
    let panel: Target
    @EnvironmentObject private var settings: AppSettingsStore
    @Environment(\.openWindow) private var openWindow
    @State private var showControls = false

    var body: some View {
        Button {
            if settings.mainWindowLayoutStyle == .appleMusicImmersiveV3 {
                SettingsNavigationRoute.shared.requestedToolbarPanel = panel.panel
                openWindow(id: "main-window")
            } else {
                showControls = true
            }
        } label: {
            HStack {
                Text(title)
                Spacer(minLength: 6)
                Image(systemName: "arrow.up.right").font(.caption)
            }
            .foregroundStyle(WorkspacePalette.ink).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showControls) {
            VStack(alignment: .leading, spacing: 9) {
                switch panel {
                case .text:
                    V3VisualControls(settings: settings).sharedTextControls
                case .translation:
                    TranslationServicePanelRows(settings: settings) {
                        showControls = false
                        MenuBarLyricsController.shared.openSettings(at: .init(.aiTranslation))
                    }
                    TranslationAutomationToggle(settings: settings)
                case .picture:
                    AppearanceLayoutPicker(settings: settings)
                    if settings.mainWindowLayoutStyle == .immersiveSplit {
                        Picker("经典伴随布局", selection: $settings.classicCompanionPresentationRawValue) {
                            ForEach(ClassicCompanionPresentation.allCases) { Text($0.title).tag($0.rawValue) }
                        }
                    }
                }
            }.padding(16).frame(width: 340)
        }
    }
}

enum SettingsCategory: String, CaseIterable, Identifiable {
    case workspace = "工作台"
    case favorites = "收藏的金句"
    case missingLyrics = "缺歌词"
    case general = "播放"
    case lyricsAndText = "歌词与翻译"
    case appearance = "外观"
    case reading = "读音"
    case advancedAndData = "高级与数据"

    // Secondary pages keep existing tools reachable without crowding the sidebar.
    case servicesAndSources = "歌词来源"
    case aiTranslation = "AI 翻译"
    case library = "我的歌词库"
    case history = "最近播放"
    case statistics = "听歌统计"
    case experienceLibrary = "体验版本库"

    static var sidebarGroups: [(title: String, categories: [SettingsCategory])] {
        [("资料", [.workspace, .library, .favorites, .history]),
         ("偏好", [.general, .lyricsAndText, .aiTranslation, .reading, .appearance, .advancedAndData])]
    }

    static var primaryCases: [SettingsCategory] {
        sidebarGroups.flatMap(\.categories)
    }

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .workspace: return "square.grid.2x2"
        case .favorites: return "quote.opening"
        case .missingLyrics: return "text.badge.plus"
        case .general: return "play.circle"
        case .lyricsAndText: return "text.quote"
        case .appearance: return "paintpalette"
        case .reading: return "character.phonetic"
        case .servicesAndSources: return "waveform.circle"
        case .aiTranslation: return "sparkles"
        case .advancedAndData: return "wrench.and.screwdriver"
        case .library: return "music.note.list"
        case .history: return "clock.arrow.circlepath"
        case .statistics: return "chart.bar"
        case .experienceLibrary: return "rectangle.on.rectangle"
        }
    }

    var detail: String {
        switch self {
        case .workspace: return "浏览本机收藏，整理歌曲档案"
        case .favorites: return "重读收藏的歌词，找到出处"
        case .missingLyrics: return "查看并补全缺少歌词的歌曲"
        case .general: return "播放来源、连接与启动"
        case .lyricsAndText: return "原文、中文、字体与找词"
        case .appearance: return "主窗口、封面与桌面歌词"
        case .reading: return "假名、罗马音、拼音与词典"
        case .advancedAndData: return "备份、缓存与诊断"
        case .servicesAndSources: return "搜索模式、来源顺序与外部发现"
        case .aiTranslation: return "翻译引擎、模型与个人风格"
        case .library: return "已保存的歌词与译文"
        case .history: return "浏览最近听过的歌曲"
        case .statistics: return "查看听歌记录统计"
        case .experienceLibrary: return "预览与恢复界面版本"
        }
    }

    private var searchTerms: String {
        switch self {
        case .general: return "Spotify Apple Music 自动连接 Client ID 授权 在线曲库"
        case .lyricsAndText: return "显示翻译 显示原文 字号 字体 透明度 繁简 转换 自动搜索 提前加载 预加载 下一首 自动排轴 时间轴"
        case .appearance: return "布局 背景 模糊 环境光 封面舞台 经典放大 柔光羽化 纯净歌词 封面海报 菜单栏 置顶 悬浮 透明 颜色 窗口状态 桌面歌词 停靠 程序坞 全屏歌词 第二块屏幕 外接显示器 暂停时隐藏 全屏 截图 录屏"
        case .reading: return "日语 中文 注音 Ruby 声调 本地引擎 自动生成 人工词典 优先级 读音候选"
        case .advancedAndData: return "数据库 存储 空间 硬盘 磁盘 备份 缓存 清理 索引 重置 日志 导出 清除"
        case .servicesAndSources: return "Provider 免费 实验 LRCLIB 本地 Uta-Net UtaTime AWA"
        case .aiTranslation: return "API Key Keychain Base URL Codex ChatGPT GPT 目标语言 自动翻译 提示词 Prompt 超时 Temperature 连接测试"
        case .workspace: return "首页 工作台 资料"
        case .library: return "档案 本地 原词 版本 导入 锁定"
        case .favorites: return "收藏 摘录 喜欢的句子 句册 翻阅 接下一句"
        case .missingLyrics: return "找词 补全 缺词 无歌词"
        case .history: return "封面墙 回顾卡"
        case .statistics, .experienceLibrary: return ""
        }
    }

    func matches(_ query: String) -> Bool {
        let searchable = "\(rawValue) \(detail) \(searchTerms)"
        return query.split(whereSeparator: { $0.isWhitespace }).allSatisfy {
            searchable.localizedStandardContains(String($0))
        }
    }
}

struct SettingsLocation: Equatable {
    let page: SettingsCategory
    var trackKey: String?
    var query: String
    var resultID: String?
    var archivePassage: LibraryPassageTarget?
    var passage: LibraryPassageTarget?
    var appearanceSurface: AppearanceSurface = .main
    var appearanceControl: AppearanceControl?
    var presentationCategory: PresentationCategory?
    var opensSpotifyOnline = false
    var opensTranslationCache = false

    var navigationTitle: String {
        if !query.isEmpty { return "搜索本机资料" }
        if passage != nil { return "阅读歌词" }
        if opensSpotifyOnline { return "Spotify 在线曲库" }
        if opensTranslationCache { return "翻译缓存" }
        if page == .appearance {
            return [page.rawValue, appearanceSurface.title, appearanceControl?.title].compactMap { $0 }.joined(separator: " › ")
        }
        if let presentationCategory { return "\(page.rawValue) › \(presentationCategory.displayName)" }
        return page.rawValue
    }

    init(appearance surface: AppearanceSurface, control: AppearanceControl? = nil) {
        self.init(.appearance)
        appearanceSurface = surface
        appearanceControl = control
    }

    init(versionsFor surface: AppearanceSurface) {
        self.init(.experienceLibrary)
        presentationCategory = surface.presentationCategory
    }

    init(reading passage: LibraryPassageTarget) {
        self.init(.library, trackKey: passage.trackKey)
        self.passage = passage
    }

    init(archive target: LibraryPassageTarget) {
        self.init(.library, trackKey: target.trackKey)
        archivePassage = target
    }

    init(_ page: SettingsCategory, trackKey: String? = nil, query: String = "", opensSpotifyOnline: Bool = false) {
        self.page = page
        self.trackKey = trackKey
        self.query = query
        self.opensSpotifyOnline = opensSpotifyOnline
    }
}

struct SettingsHistory {
    private(set) var current: SettingsLocation
    private var earlier: [SettingsLocation] = []
    private var later: [SettingsLocation] = []

    init(_ page: SettingsCategory = .workspace, surface: AppearanceSurface = .main) {
        current = page == .appearance ? SettingsLocation(appearance: surface) : SettingsLocation(page)
    }
    var canGoBack: Bool { !earlier.isEmpty }
    var canGoForward: Bool { !later.isEmpty }

    mutating func open(_ location: SettingsLocation) {
        guard current != location else { return }
        earlier.append(current)
        later.removeAll()
        current = location
    }

    mutating func openArchive(fromReading passage: LibraryPassageTarget) {
        if current.passage != nil, passage.readingPosition != nil { current = .init(reading: passage) }
        open(.init(archive: passage))
    }

    mutating func back() {
        guard let previous = earlier.popLast() else { return }
        later.append(current)
        current = previous
    }

    mutating func forward() {
        guard let next = later.popLast() else { return }
        earlier.append(current)
        current = next
    }

    mutating func search(_ text: String) {
        if text.isEmpty {
            if !current.query.isEmpty { back() }
        } else if current.query.isEmpty {
            open(.init(.workspace, query: text))
        } else {
            if current.query != text { current.resultID = nil }
            current.query = text
            later.removeAll()
        }
    }

    mutating func rememberSearchResult(_ id: String) {
        if !current.query.isEmpty { current.resultID = id }
    }

    mutating func rememberLibrarySelection(_ key: String?) {
        guard current.page == .library || current.page == .missingLyrics else { return }
        if current.trackKey != key { current.archivePassage = nil }
        current.trackKey = key
    }
}

struct SettingsRootView: View {
    @EnvironmentObject private var settings: AppSettingsStore
    @ObservedObject private var navigationRoute = SettingsNavigationRoute.shared
    @State private var history: SettingsHistory
    @State private var library = PersonalLyricsLibraryService()
    @State private var favoriteQuery = ""
    @State private var statisticsTimeRange: ListeningStatisticsTimeRange = .allTime
    @State private var libraryScope = PersonalLibraryScope.initial
    @State private var missingLibraryScope = PersonalLibraryScope(filter: .missing)
    @FocusState private var searchFocused: Bool

    init(initialPage: String? = nil, initialSurface: AppearanceSurface = .main) {
        _history = State(initialValue: SettingsHistory(initialPage.flatMap(SettingsCategory.init(rawValue:)) ?? .workspace,
                                                      surface: initialSurface))
    }

    private func navigate(_ destination: SettingsLocation) {
        if destination.opensTranslationCache {
            libraryScope = .init(query: "", filter: .translations)
        }
        searchFocused = false
        history.open(destination)
    }

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(WorkspacePalette.ink)
                    TextField("搜索设置、歌曲、歌词", text: Binding(
                        get: { history.current.query },
                        set: { history.search($0) }
                    ))
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .accessibilityIdentifier("settings.search")
                    if !history.current.query.isEmpty {
                        Button { history.search("") } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).accessibilityLabel("清除搜索")
                    }
                }
                .font(.system(size: 12))
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 12).padding(.vertical, 10)

                ScrollView {
                    VStack(alignment: .leading, spacing: 15) {
                        ForEach(SettingsCategory.sidebarGroups, id: \.title) { section in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(section.title).font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary).padding(.leading, 10).padding(.bottom, 3)
                                ForEach(section.categories) { category in sidebarRow(category) }
                            }
                        }
                        if settings.settingsCenterPresentation == .classicNavigationV1 {
                            Button("恢复推荐设置中心") { settings.settingsCenterPresentation = .experienceIntegratedV2 }
                                .buttonStyle(.borderless)
                        }
                    }
                    .padding(.horizontal, 10).padding(.bottom, 12)
                }
            }
            .navigationTitle("Aster · Lyric")
            .accessibilityIdentifier(settings.settingsCenterPresentation.rawValue)
            .navigationSplitViewColumnWidth(min: 190, ideal: 206, max: 245)
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 5) {
                    Button { history.back() } label: { Image(systemName: "chevron.left") }
                        .disabled(!history.canGoBack).keyboardShortcut("[", modifiers: .command)
                        .help("后退 (⌘[)").accessibilityLabel("后退")
                    Button { history.forward() } label: { Image(systemName: "chevron.right") }
                        .disabled(!history.canGoForward).keyboardShortcut("]", modifiers: .command)
                        .help("前进 (⌘])").accessibilityLabel("前进")
                    Divider().frame(height: 12).padding(.horizontal, 5)
                    Text(history.current.navigationTitle)
                        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    Spacer()
                    Button { searchFocused = true } label: { Image(systemName: "magnifyingglass") }
                        .keyboardShortcut("f", modifiers: .command).help("搜索 (⌘F)").accessibilityLabel("搜索")
                }
                .buttonStyle(.borderless).padding(.horizontal, 18).frame(height: 36)
                .background(WorkspacePalette.paper)
                Divider()
                if history.current.query.isEmpty {
                    SettingsDetailView(selection: Binding(get: { history.current.page }, set: { navigate(.init($0)) }),
                                       trackKey: history.current.trackKey, passage: history.current.passage,
                                       archivePassage: history.current.archivePassage, favoriteQuery: $favoriteQuery,
                                       statisticsTimeRange: $statisticsTimeRange,
                                       libraryScope: $libraryScope, missingLibraryScope: $missingLibraryScope,
                                       backFromReading: history.canGoBack ? { history.back() } : nil,
                                       openArchiveFromReading: { history.openArchive(fromReading: $0) },
                                       appearanceSurface: history.current.appearanceSurface, appearanceControl: history.current.appearanceControl,
                                       presentationCategory: history.current.presentationCategory,
                                       opensSpotifyOnline: history.current.opensSpotifyOnline,
                                       library: library, navigate: navigate,
                                       rememberSelection: { history.rememberLibrarySelection($0) })
                } else {
                    SettingsLocalSearch(query: history.current.query, resultID: history.current.resultID, library: library) { row in
                        history.rememberSearchResult(row.id)
                        navigate(row.location)
                    }
                }
            }
        }
        .frame(minWidth: 800, idealWidth: 940, minHeight: 540, idealHeight: 650)
        .background(SettingsWindowBehavior())
        .onReceive(NotificationCenter.default.publisher(for: .lyricIslandOpenAISettings)) { _ in consumeRoutes() }
        .onReceive(NotificationCenter.default.publisher(for: .lyricIslandOpenConnectionSettings)) { _ in consumeRoutes() }
        .onChange(of: navigationRoute.requestedLocation, initial: true) { _, request in
            guard let location = request else { return }
            navigate(location)
            navigationRoute.requestedLocation = nil
        }
        .onAppear { consumeRoutes() }
    }

    private func sidebarRow(_ category: SettingsCategory) -> some View {
        let selected = history.current.page == category && history.current.query.isEmpty
        return Button { navigate(.init(category)) } label: {
            HStack(spacing: 10) {
                Image(systemName: category.systemImage)
                    .renderingMode(.template).symbolRenderingMode(.monochrome)
                    .font(.system(size: 14, weight: .medium)).foregroundStyle(WorkspacePalette.ink).frame(width: 20)
                Text(category.rawValue).font(.system(size: 13, weight: selected ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? WorkspacePalette.ink : Color.primary)
            .padding(.horizontal, 10).frame(height: 30)
            .background(selected ? WorkspacePalette.selection : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(category.detail)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func consumeRoutes() {
        if navigationRoute.pendingConnectionSettings {
            navigate(.init(.general))
            navigationRoute.pendingConnectionSettings = false
        }
        if navigationRoute.consumePendingAISettingsRequest() { navigate(.init(.aiTranslation)) }
    }
}

private struct SettingsDetailView: View {
    @EnvironmentObject private var settings: AppSettingsStore
    @Binding var selection: SettingsCategory
    let trackKey: String?
    let passage: LibraryPassageTarget?
    let archivePassage: LibraryPassageTarget?
    @Binding var favoriteQuery: String
    @Binding var statisticsTimeRange: ListeningStatisticsTimeRange
    @Binding var libraryScope: PersonalLibraryScope
    @Binding var missingLibraryScope: PersonalLibraryScope
    let backFromReading: (() -> Void)?
    let openArchiveFromReading: (LibraryPassageTarget) -> Void
    let appearanceSurface: AppearanceSurface
    let appearanceControl: AppearanceControl?
    let presentationCategory: PresentationCategory?
    let opensSpotifyOnline: Bool
    let library: PersonalLyricsLibraryService
    let navigate: (SettingsLocation) -> Void
    let rememberSelection: (String?) -> Void

    var body: some View {
        Group {
            switch selection {
            case .workspace:
                SettingsWorkspace(navigate: navigate)
            case .general:
                ServicesAndSourcesSettingsView(scope: .playback, opensSpotifyOnline: opensSpotifyOnline).padding(16)
            case .lyricsAndText:
                LyricsAndTextSettingsView(
                    onOpenSources: { selection = .servicesAndSources },
                    onOpenTranslation: { selection = .aiTranslation },
                    onOpenReading: { selection = .reading }
                ).padding(16)
            case .appearance:
                AppearanceSettingsView(surface: appearanceSurface, focused: appearanceControl,
                                       select: { navigate(.init(appearance: $0)) },
                                       openVersions: { navigate(.init(versionsFor: appearanceSurface)) })
            case .reading: ReadingSettingsView().padding(16)
            case .servicesAndSources: ServicesAndSourcesSettingsView(scope: .lyrics).padding(16)
            case .aiTranslation: AISettingsView().padding(16)
            case .advancedAndData:
                AdvancedAndDataSettingsView(onOpenTool: { tool in selection = tool }).padding(24)
            case .library, .missingLyrics:
                if let passage {
                    LibraryPassageReader(target: passage, library: library,
                                        openArchive: openArchiveFromReading, close: backFromReading)
                        .id(passage)
                } else {
                    PersonalLyricsLibraryView(embeddedInSettings: true, initialTrackKey: trackKey,
                                              scope: selection == .missingLyrics ? $missingLibraryScope : $libraryScope,
                                              initialPassage: archivePassage, service: library,
                                              onSelection: rememberSelection, readPassage: { navigate(.init(reading: $0)) },
                                              openArchive: { navigate(.init(archive: $0)) })
                }
            case .history: ListeningHistoryView(openTrack: { navigate(.init(.library, trackKey: $0)) })
            case .statistics:
                ListeningStatisticsView(timeRange: $statisticsTimeRange, openTrack: { navigate(.init(.library, trackKey: $0)) })
            case .favorites: FavoriteLinesView(savedQuery: $favoriteQuery, openTrack: { navigate(.init(.library, trackKey: $0)) },
                                              readPassage: { navigate(.init(reading: $0)) })
            case .experienceLibrary:
                ExperienceLibrarySettingsView(selectionStore: settings.presentationSelections,
                                              initialCategory: presentationCategory ?? .mainWindow)
                    .id(presentationCategory)
                    .padding(24)
            }
        }
        .id(selection)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(WorkspacePalette.paper)
    }
}

struct SettingsPageHeader: View {
    let title: String
    let detail: String

    var body: some View {
        // A page heading, not a banner: the sidebar already names the page.
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 20, weight: .semibold))
            Text(detail)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.bottom, 4)
    }
}

/// Left-aligned status line used by the Spotify connection block.
private struct SpotifyStatusRow: View {
    let title: String
    let value: String
    let tone: Color

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(tone)
                .frame(width: 6, height: 6)
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            Text(value)
                .fontWeight(.medium)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

struct SettingsDestinationRow: View {
    let title: String
    let detail: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct LyricsSearchSettingsSections: View {
    @EnvironmentObject private var settings: AppSettingsStore

    var body: some View {
        Section("切歌与同步") {
            Toggle("切歌后自动搜索歌词", isOn: $settings.autoSearchLyricsOnTrackChange)
            Toggle("提前加载下一首歌词", isOn: $settings.preloadUpcomingLyrics)
            LyricsPresentationOffsetControl(settings: settings)
        }
        Section("自动排轴") {
            DisclosureGroup("为没有时间轴的歌词生成同步时间") {
                Toggle("自动为未排轴歌词生成时间轴", isOn: $settings.automaticAlignmentEnabled)
                Text("实验功能，默认关闭。自动音频捕获仅支持已就绪的 Spotify Desktop；Apple Music、未知来源不会启动。捕获音频临时写入本机 WAV 分段，任务结束后清理。选择本地音频排轴不依赖播放来源。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct ServicesAndSourcesSettingsView: View {
    enum Scope { case playback, lyrics }
    let scope: Scope
    var opensSpotifyOnline = false
    @EnvironmentObject private var playbackState: PlaybackState
    @EnvironmentObject private var settings: AppSettingsStore
    @State private var clientIDDraft = ""
    @State private var discoveryQuery = ""
    @State private var isExternalDiscoveryExpanded = false
    @State private var isDeveloperConfigExpanded = false
    @State private var isAdvancedExpanded = false
    @State private var isSpotifyOnlineExpanded = false
    @State private var accountName: String?

    private var authorization: SpotifyAuthorizationManager {
        playbackState.spotifyAuthorizationManager
    }

    var body: some View {
        Form {
            SettingsPageHeader(
                title: opensSpotifyOnline ? "Spotify 在线曲库" : scope == .playback ? "播放来源" : "歌词来源",
                detail: opensSpotifyOnline ? "管理搜索和歌单使用的账号授权。"
                    : scope == .playback ? "在 Spotify 和 Apple Music 之间切换，查看各自的连接状态。"
                    : "选择歌词搜索范围，调整来源顺序或在浏览器中继续查找。"
            )

            if scope == .playback {
                if opensSpotifyOnline { Section { spotifyOnlineControls } }
                else {
                    Section { PlaybackConnectionCards(state: playbackState, settings: settings) }
                    Section {
                        DisclosureGroup(isExpanded: $isSpotifyOnlineExpanded) { spotifyOnlineControls } label: {
                            HStack {
                                Label("Spotify 在线曲库", systemImage: "globe")
                                Spacer()
                                Text(accountAuthorizationLabel).font(.caption).foregroundStyle(accountAuthorizationTone)
                            }
                        }
                    }
                }
            } else {
                Section("歌词来源模式") {
                    Picker("模式", selection: Binding(
                        get: { settings.lyricsSourceMode },
                        set: { settings.lyricsSourceMode = $0 }
                    )) {
                        ForEach(LyricsSourceMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .accessibilityIdentifier("lyricsSourceMode.picker")

                    Text(settings.lyricsSourceMode.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if settings.lyricsSourceMode.isExperimental {
                        Label(
                            "实验模式：可能随时失效，不保证覆盖率，不建议用于正式商业发行。不含任何付费歌词 API。",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("lyricsSourceMode.experimentalBanner")
                    }

                    Button("恢复默认模式（扩展免费）") {
                        settings.restoreDefaultLyricsSourceMode()
                    }
                    .accessibilityIdentifier("lyricsSourceMode.restoreDefault")
                }

                Section {
                    DisclosureGroup("调整歌词来源与搜索顺序") {
                        ForEach(Array(settings.lyricsProviderConfiguration.order.enumerated()), id: \.element) { index, id in
                            providerRow(id: id, index: index)
                        }
                    }
                }

                Section {
                    DisclosureGroup("外部发现（仅浏览器）", isExpanded: $isExternalDiscoveryExpanded) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Uta-Net、UtaTime、AWA 只用于「可能存在歌词」时的外链与复制检索词，不会自动提取、缓存或再分发歌词正文。")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            TextField("歌曲名 艺人（可选）", text: $discoveryQuery)
                                .textFieldStyle(.roundedBorder)

                            HStack {
                                Button("复制检索词") {
                                    let text = discoveryQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                                    guard !text.isEmpty else { return }
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(text, forType: .string)
                                }
                                .disabled(discoveryQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                                ForEach(LyricsDiscoverySite.allCases) { site in
                                    Button(site.title) {
                                        if let url = site.browserURL(query: discoveryQuery) {
                                            NSWorkspace.shared.open(url)
                                        }
                                    }
                                    .help(site.detail)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            guard scope == .playback else { return }
            clientIDDraft = authorization.clientID ?? ""
            if !authorization.isConfigured { isDeveloperConfigExpanded = true }
        }
        .task(id: scope == .playback && (opensSpotifyOnline || isSpotifyOnlineExpanded) && authorization.state.isAuthorized) {
            guard scope == .playback, opensSpotifyOnline || isSpotifyOnlineExpanded, authorization.state.isAuthorized else {
                accountName = nil
                return
            }
            let name = await authorization.authorizedAccountName()
            if !Task.isCancelled { accountName = name }
        }
    }

    @ViewBuilder
    private var spotifyOnlineControls: some View {
        SpotifyStatusRow(title: "账号授权", value: accountAuthorizationLabel, tone: accountAuthorizationTone)
        if authorization.state.isAuthorized {
            SpotifyStatusRow(title: "账号", value: accountName ?? "Spotify 账号", tone: .secondary)
        }

        spotifyPrimaryAction

        DisclosureGroup("开发者配置", isExpanded: $isDeveloperConfigExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    TextField("Client ID", text: $clientIDDraft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { saveClientID() }
                    Button("保存") { saveClientID() }
                        .disabled(clientIDDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                            == (authorization.clientID ?? ""))
                }
                Text("只填 Client ID，不需要 Client Secret。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        }

        DisclosureGroup("高级", isExpanded: $isAdvancedExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                advancedAddressRow("Dashboard 回调地址", value: authorization.dashboardRedirectURI)
                advancedAddressRow("当前监听地址", value: authorization.localRedirectURI ?? "未启动")
                HStack(spacing: 10) {
                    Button("刷新授权状态") { authorization.refreshAuthorizationState() }
                    Button("清除授权凭据") { authorization.disconnect() }
                        .disabled(!authorization.state.isAuthorized)
                }
            }
            .padding(.top, 4)
        }
    }

    private var accountAuthorizationLabel: String {
        guard authorization.isConfigured else { return "未配置" }
        switch authorization.state {
        case .authorized:
            return authorization.needsSupplementaryAuthorization ? "需要补充授权" : "已连接"
        case .authorizing:
            return "等待授权…"
        case .notConfigured:
            return "未配置"
        default:
            return "未连接"
        }
    }

    private var accountAuthorizationTone: Color {
        guard authorization.isConfigured else { return .secondary }
        switch authorization.state {
        case .authorized:
            return authorization.needsSupplementaryAuthorization ? .orange : .green
        case .authorizing:
            return .orange
        case .failed:
            return .red
        default:
            return .secondary
        }
    }

    @ViewBuilder
    private var spotifyPrimaryAction: some View {
        if !authorization.isConfigured {
            VStack(alignment: .leading, spacing: 6) {
                Button("填写 Client ID") { isDeveloperConfigExpanded = true }
                    .buttonStyle(.borderedProminent)
                Text("先在开发者配置中填写 Client ID，才能连接 Spotify。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 2)
        } else if authorization.needsSupplementaryAuthorization {
            VStack(alignment: .leading, spacing: 6) {
                Button("补充授权") { authorize() }
                    .buttonStyle(.borderedProminent)
                Text("重新授权以读取随机与循环状态。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 2)
        } else if !authorization.state.isAuthorized {
            VStack(alignment: .leading, spacing: 6) {
                Button(authorization.state == .authorizing ? "等待授权…" : "连接 Spotify") { authorize() }
                    .buttonStyle(.borderedProminent)
                    .disabled(authorization.state == .authorizing)
                Text("授权后可查在线曲库、管理歌单与待播列表。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if case .failed(let message) = authorization.state, !message.isEmpty {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.top, 2)
        }
    }

    private func advancedAddressRow(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    private func saveClientID() {
        let trimmed = clientIDDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        authorization.updateClientID(trimmed)
        clientIDDraft = trimmed
        isDeveloperConfigExpanded = trimmed.isEmpty
    }

    private func authorize() {
        let trimmed = clientIDDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != authorization.clientID {
            authorization.updateClientID(trimmed)
        }
        authorization.authorize()
    }

    private func providerRow(id: LyricsProviderID, index: Int) -> some View {
        let activeInMode = settings.isProviderActiveInCurrentMode(id)
        let blockedByMode = id.isExperimental && !settings.lyricsSourceMode.allowsExperimentalProviders
        return HStack(spacing: 10) {
            Image(systemName: id.systemImage)
                .frame(width: 22)
                .foregroundStyle(id.isExperimental ? .orange : .accentColor)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(id.title)
                        .fontWeight(.medium)
                    Text(id.stabilityLabel)
                        .font(.caption2)
                        .foregroundStyle(id.isExperimental ? .orange : .secondary)
                    if blockedByMode {
                        Text("当前模式未启用")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else if activeInMode {
                        Text("参与搜索")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                }
                Text(id.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("启用", isOn: Binding(
                get: { settings.isProviderEnabled(id) },
                set: { settings.setProviderEnabled(id, enabled: $0) }
            ))
            .labelsHidden()
            .disabled(id.isLocal || blockedByMode)
            Button { settings.moveProvider(id, offset: -1) } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .disabled(index == 0)
            Button { settings.moveProvider(id, offset: 1) } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .disabled(index == settings.lyricsProviderConfiguration.order.count - 1)
        }
        .help(id.detail)
        .opacity(blockedByMode ? 0.55 : 1)
    }
}

/// The 译文 panel's service, key, model and effort rows as a view of their
/// own. It observes the settings itself: the panel lives in a separate
/// hosting window, and rows borrowed from the parent's body kept showing the
/// old service after a new one was chosen (2026-11-15).
struct TranslationServicePanelRows: View {
    @ObservedObject var settings: AppSettingsStore
    let openSettings: () -> Void

    var body: some View {
        let controls = TranslationProviderControls(settings: settings)
        VStack(alignment: .leading, spacing: 2) {
            controls.serviceRows
            if controls.needsConnectionSettings {
                V3PanelRow(title: controls.keyOnly ? "密钥"
                           : (settings.aiTranslationConfiguration.isConfigured ? "接口与密钥" : "未填接口或模型")) {
                    Button(controls.keyOnly ? "填写密钥…" : "在设置中填写…", action: openSettings)
                        .buttonStyle(.borderless).controlSize(.small)
                }
            }
            controls.modelRow
            controls.reasoningRow
        }
        // A new service, model or effort rebuilds the menus, so their labels
        // can never keep showing the previous choice.
        .id([settings.aiTranslationConfiguration.engineID, settings.aiTranslationConfiguration.model,
             TranslationReasoningPolicy.value(settings.aiTranslationConfiguration)].joined(separator: "|"))
    }
}

struct TranslationAutomationToggle: View {
    @ObservedObject var settings: AppSettingsStore

    static func isAllowed(_ configuration: AITranslationConfiguration) -> Bool {
        if configuration.engineID == TranslationEngineID.appleSystem.rawValue { return true }
#if DEBUG
        if DebugAcceptanceDataIsolation.isRequested {
            return DebugAcceptanceDataIsolation.isDailyUse && DebugAcceptanceDataIsolation.allowsExplicitTranslation
        }
#endif
        return true
    }

    var body: some View {
        Toggle("新歌词自动翻译", isOn: $settings.aiTranslationConfiguration.autoTranslateNewLyrics)
            .disabled(!Self.isAllowed(settings.aiTranslationConfiguration) || !settings.aiTranslationConfiguration.isConfigured)
    }
}

struct TranslationProviderControls: View {
    @ObservedObject var settings: AppSettingsStore

    /// Shared with the listening panel; changing a model uses the same provider policy.
    var modelPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Picker("AI 模型", selection: modelBinding) {
                    if !settings.aiCachedModels.contains(where: { $0.id == settings.aiTranslationConfiguration.model }) {
                        Text(settings.aiTranslationConfiguration.model.isEmpty ? "选择模型" : settings.aiTranslationConfiguration.model)
                            .tag(settings.aiTranslationConfiguration.model)
                    }
                    ForEach(settings.aiCachedModels, id: \.id) { model in
                        Text(model.displayName).tag(model.id)
                    }
                }
                .disabled(provider == TranslationEngineID.appleSystem.rawValue)
                .onAppear { _ = settings.translationModelSettings }
                .accessibilityIdentifier("ai.model")
                Button(settings.aiModelDirectoryStatus == .loading ? "刷新中…" : "刷新") {
                    settings.refreshAIModelDirectory()
                }
                .disabled(settings.aiModelDirectoryStatus == .loading || provider == TranslationEngineID.appleSystem.rawValue)
                .accessibilityLabel("刷新 AI 模型")
            }
            switch settings.aiModelDirectoryStatus {
            case .unauthorized, .endpointUnsupported, .empty:
                Text(settings.aiModelDirectoryStatus.userFacingTitle).font(.caption).foregroundStyle(.orange)
            case .unavailable(let error):
                Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            default: EmptyView()
            }
            DisclosureGroup("手动填写模型 ID") {
                TextField("此服务的模型 ID", text: modelBinding)
                    .textFieldStyle(.roundedBorder)
            }
            .font(.caption)
            .disabled(provider == TranslationEngineID.appleSystem.rawValue)
        }
    }

    /// Tool-panel form: one row, the menu at the right, refresh as an icon.
    var modelRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            V3PanelRow(title: "AI 模型") {
                HStack(spacing: 4) {
                    choiceMenu(current: settings.aiCachedModels.first { $0.id == settings.aiTranslationConfiguration.model }?.displayName
                                   ?? (settings.aiTranslationConfiguration.model.isEmpty ? "选择模型" : settings.aiTranslationConfiguration.model),
                               options: settings.aiCachedModels.map { ($0.displayName, $0.id) },
                               selected: settings.aiTranslationConfiguration.model) { modelBinding.wrappedValue = $0 }
                    .disabled(provider == TranslationEngineID.appleSystem.rawValue)
                    .onAppear { _ = settings.translationModelSettings }
                    .accessibilityIdentifier("ai.model")
                    Button { settings.refreshAIModelDirectory() } label: {
                        Image(systemName: "arrow.clockwise")
                            .rotationEffect(.degrees(settings.aiModelDirectoryStatus == .loading ? 180 : 0))
                    }
                    .buttonStyle(.borderless)
                    .disabled(settings.aiModelDirectoryStatus == .loading || provider == TranslationEngineID.appleSystem.rawValue)
                    .help(settings.aiModelDirectoryStatus == .loading ? "刷新中…" : "刷新模型列表")
                    .accessibilityLabel("刷新 AI 模型")
                }
            }
            switch settings.aiModelDirectoryStatus {
            case .unauthorized, .endpointUnsupported, .empty:
                Text(settings.aiModelDirectoryStatus.userFacingTitle).font(.caption).foregroundStyle(.orange)
            case .unavailable(let error):
                Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            default: EmptyView()
            }
        }
    }

    /// Tool-panel form of the service choice. Switching keeps each service's
    /// own model and settings; keys and endpoints stay in Settings.
    var serviceRows: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Menus of buttons, not menu-style Pickers: inside the hover panel
            // a Picker kept showing the old choice after a new one was made.
            V3PanelRow(title: "翻译服务") {
                choiceMenu(current: TranslationEngineCatalog.selectable.first { $0.stableID == family }?.displayName ?? "选择",
                           options: TranslationEngineCatalog.selectable.map { ($0.displayName, $0.stableID) },
                           selected: family) { settings.selectTranslationProvider($0) }
                    .accessibilityIdentifier("ai.service")
            }
            if family == TranslationEngineID.openAICompatible.rawValue {
                V3PanelRow(title: "API") {
                    choiceMenu(current: Self.apiBackends.first { $0.1 == provider }?.0 ?? "选择",
                               options: Self.apiBackends, selected: provider) { id in
                        settings.selectTranslationProvider(id)
                        // A saved key: list the account's models straight away.
                        if id != TranslationEngineID.openAICompatible.rawValue, settings.aiCachedModels.isEmpty {
                            settings.refreshAIModelDirectory()
                        }
                    }
                }
            } else if family == TranslationEngineID.geminiCLI.rawValue {
                V3PanelRow(title: "连接方式") {
                    choiceMenu(current: Self.geminiBackends.first { $0.1 == provider }?.0 ?? "选择",
                               options: Self.geminiBackends, selected: provider) { settings.selectTranslationProvider($0) }
                }
            }
        }
    }

    static let apiBackends: [(String, String)] = [
        ("OpenAI API", TranslationEngineID.openAIAPI.rawValue),
        ("DeepSeek API", TranslationEngineID.deepSeekAPI.rawValue),
        ("自定义兼容 API", TranslationEngineID.openAICompatible.rawValue)
    ]
    static let geminiBackends: [(String, String)] = [
        ("Gemini CLI", TranslationEngineID.geminiCLI.rawValue),
        ("Antigravity CLI", TranslationEngineID.antigravityCLI.rawValue)
    ]

    private func choiceMenu(current: String, options: [(String, String)], selected: String,
                            choose: @escaping (String) -> Void) -> some View {
        Menu {
            ForEach(options, id: \.1) { option in
                Button { choose(option.1) } label: {
                    if option.1 == selected { Label(option.0, systemImage: "checkmark") } else { Text(option.0) }
                }
            }
        } label: {
            Text(current)
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    /// API services need an endpoint and a key, which only Settings holds.
    var needsConnectionSettings: Bool {
        family == TranslationEngineID.openAICompatible.rawValue
    }

    var keyOnly: Bool {
        [TranslationEngineID.openAIAPI.rawValue, TranslationEngineID.deepSeekAPI.rawValue].contains(provider)
    }

    var reasoningRow: some View {
        V3PanelRow(title: "思考强度") {
            let options = advertisedReasoningOptions ?? []
            let value = reasoningBinding.wrappedValue
            choiceMenu(current: options.contains(value) ? reasoningLabel(value) : reasoningSelectionLabel,
                       options: (provider == TranslationEngineID.openAIAPI.rawValue ? [("模型默认", "")] : [])
                            + options.map { (reasoningLabel($0), $0) },
                       selected: value) { reasoningBinding.wrappedValue = $0 }
                .disabled(!supportsReasoningControl || options.isEmpty)
                .accessibilityIdentifier("ai.reasoningEffort")
        }
    }

    var reasoningPicker: some View {
        Picker("思考强度", selection: reasoningBinding) {
            if !(advertisedReasoningOptions ?? []).contains(reasoningBinding.wrappedValue) {
                Text(reasoningSelectionLabel).tag(reasoningBinding.wrappedValue)
            }
            ForEach(advertisedReasoningOptions ?? [], id: \.self) { effort in
                Text(reasoningLabel(effort)).tag(effort)
            }
        }
        .disabled(!supportsReasoningControl || (advertisedReasoningOptions ?? []).isEmpty)
        .accessibilityIdentifier("ai.reasoningEffort")
    }

    private var provider: String { settings.aiTranslationConfiguration.engineID }
    private var family: String { TranslationEngineCatalog.topLevelID(for: provider) }
    var modelBinding: Binding<String> {
        Binding(get: { settings.aiTranslationConfiguration.model }, set: { model in
            settings.aiTranslationConfiguration = settings.translationModelSettings.selectingModel(
                model, in: settings.aiTranslationConfiguration)
        })
    }
    private var backendBinding: Binding<String> {
        Binding(get: { provider }, set: { settings.selectTranslationProvider($0) })
    }

    // Legacy native overrides must not appear as "automatic" while still sent.
    private var customReasoningOverride: (value: String, label: String)? {
        let configuration = settings.aiTranslationConfiguration
        if provider == TranslationEngineID.geminiCLI.rawValue,
           configuration.geminiThinkingLevel.isEmpty, let budget = configuration.geminiThinkingBudget {
            return ("thinkingBudget=\(budget)", "自定义预算 · \(budget)")
        }
        if provider == TranslationEngineID.deepSeekAPI.rawValue,
           configuration.deepSeekReasoningEffort.isEmpty {
            switch configuration.deepSeekThinkingMode {
            case "enabled": return ("thinking=enabled", "已开启思考 · 默认强度")
            case "disabled": return ("thinking=disabled", "已关闭思考")
            default: break
            }
        }
        return nil
    }

    var reasoningBinding: Binding<String> {
        Binding(get: { customReasoningOverride?.value ?? TranslationReasoningPolicy.value(settings.aiTranslationConfiguration) }, set: { value in
            guard value != customReasoningOverride?.value else { return }
            var next = TranslationReasoningPolicy.setting(value, in: settings.aiTranslationConfiguration)
            if provider == TranslationEngineID.deepSeekAPI.rawValue {
                next.deepSeekThinkingMode = value.isEmpty ? "model-default" : (value == "none" ? "disabled" : "enabled")
            }
            settings.translationModelSettings.acknowledgeReasoningSelection()
            settings.aiTranslationConfiguration = next
        })
    }

    private var supportsReasoningControl: Bool {
        [TranslationEngineID.codexChatGPT.rawValue, TranslationEngineID.grokBuild.rawValue,
         TranslationEngineID.geminiCLI.rawValue, TranslationEngineID.antigravityCLI.rawValue,
         TranslationEngineID.deepSeekAPI.rawValue, TranslationEngineID.openAIAPI.rawValue].contains(provider)
    }

    private var advertisedReasoningOptions: [String]? {
        let descriptor = settings.aiCachedModels.first(where: {
            $0.id == settings.aiTranslationConfiguration.model
        })
        let values: [String]?
        if let cached = descriptor?.reasoningEfforts {
            values = cached
        } else if provider == TranslationEngineID.openAIAPI.rawValue {
            values = settings.translationModelSettings.knownReasoningEfforts(model: settings.aiTranslationConfiguration.model)
                ?? OpenAIAPIDefaults.reasoningEfforts
        } else if provider == TranslationEngineID.grokBuild.rawValue {
            // Older model directories contain IDs only; the local Grok cache
            // carries the provider's per-model capability fields.
            values = GrokBuildTranslationService.cachedReasoningEfforts(
                for: settings.aiTranslationConfiguration.model)
        } else {
            values = nil
        }
        guard let values else { return nil }
        var seen = Set<String>()
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private var reasoningSelectionLabel: String {
        let value = reasoningBinding.wrappedValue
        guard !value.isEmpty else { return provider == TranslationEngineID.openAIAPI.rawValue ? "模型默认" : "待选择" }
        if let custom = customReasoningOverride, custom.value == value { return custom.label }
        if advertisedReasoningOptions?.contains(value) == true { return reasoningLabel(value) }
        let status: String
        switch advertisedReasoningOptions {
        case nil: status = "能力未核实"
        case .some(let values) where values.isEmpty: status = "模型未公布此能力"
        default: status = "当前模型未支持"
        }
        return "已保存 · \(reasoningLabel(value))（\(status)）"
    }

    private func reasoningLabel(_ value: String) -> String {
        ["none": "不思考", "minimal": "极低", "low": "低", "medium": "中", "high": "高",
         "xhigh": "很高", "max": "最高", "ultra": "超高"][value] ?? value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("服务", selection: Binding(get: { family }, set: { settings.selectTranslationProvider($0) })) {
                ForEach(TranslationEngineCatalog.selectable, id: \.stableID) { engine in
                    Text(engine.displayName).tag(engine.stableID)
                }
            }
            if family == TranslationEngineID.geminiCLI.rawValue {
                Picker("连接方式", selection: backendBinding) {
                    Text("Gemini CLI").tag(TranslationEngineID.geminiCLI.rawValue)
                    Text("Antigravity CLI").tag(TranslationEngineID.antigravityCLI.rawValue)
                }
            } else if family == TranslationEngineID.openAICompatible.rawValue {
                Picker("API 服务", selection: backendBinding) {
                    Text("OpenAI API").tag(TranslationEngineID.openAIAPI.rawValue)
                    Text("DeepSeek API").tag(TranslationEngineID.deepSeekAPI.rawValue)
                    Text("自定义兼容 API").tag(TranslationEngineID.openAICompatible.rawValue)
                }
            }
            if provider != TranslationEngineID.appleSystem.rawValue {
                if [TranslationEngineID.codexChatGPT.rawValue, TranslationEngineID.grokBuild.rawValue,
                    TranslationEngineID.geminiCLI.rawValue, TranslationEngineID.antigravityCLI.rawValue].contains(provider) {
                    ProviderConversationControls(provider: provider)
                }
                if provider == TranslationEngineID.geminiCLI.rawValue {
                    Text("Gemini CLI 暂无可读取的模型目录，请在工具栏 → 译文选择此连接支持的模型。切换服务会保留各自配置。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    HStack {
                        Text(settings.aiModelDirectoryStatus.userFacingTitle)
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("刷新模型") { settings.refreshAIModelDirectory() }
                            .disabled(settings.aiModelDirectoryStatus == .loading)
                    }
                    if case .unavailable(let reason) = settings.aiModelDirectoryStatus {
                        Text(reason).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if settings.aiTranslationConfiguration.model.isEmpty {
                    Text("尚未选择此服务的模型，不会沿用其他服务的模型。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !settings.aiModelSelectionNotice.isEmpty {
                    Text(settings.aiModelSelectionNotice)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { _ = settings.translationModelSettings }
    }
}

private struct ProviderConversationControls: View {
    private let provider: String
    @AppStorage private var reuseConversation: Bool
    @AppStorage private var showConversation: Bool
    @AppStorage private var continuationNotice: String
    @State private var conversationNotice = ""

    init(provider: String) {
        self.provider = provider
        _reuseConversation = AppStorage(wrappedValue: true,
            "ai.conversationReuse.v1." + provider, store: .lyricsQ)
        _showConversation = AppStorage(wrappedValue: true,
            "ai.conversationVisible.v1." + provider, store: .lyricsQ)
        _continuationNotice = AppStorage(wrappedValue: "",
            "ai.conversationNotice.v1." + provider, store: .lyricsQ)
    }

    private var canControlVisibility: Bool { provider == TranslationEngineID.codexChatGPT.rawValue }
    private var providerName: String {
        switch TranslationEngineID(rawValue: provider) {
        case .codexChatGPT: return "Codex"
        case .grokBuild: return "Grok CLI"
        case .geminiCLI: return "Gemini CLI"
        case .antigravityCLI: return "Antigravity CLI"
        default: return "此服务"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("复用同一对话", isOn: $reuseConversation)
            if canControlVisibility {
                Toggle("在服务中显示对话", isOn: $showConversation)
            } else {
                Text("\(providerName) 的会话记录由 CLI 自身管理；应用不提供隐藏或删除服务记录的功能。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button("新建对话") {
                    AIConversationStore.shared.startNew(for: provider)
                    conversationNotice = "下次翻译会开启新对话；已有服务记录会保留。"
                }
                .buttonStyle(.borderless)
                .help("下一次翻译会开启新对话；已有服务记录会保留。")
                if canControlVisibility {
                    Button("查看对话") {
                        guard let id = AIConversationStore.shared.latestConversationID(for: provider),
                              let url = URL(string: "codex://threads/\(id)") else {
                            conversationNotice = "尚未建立 Codex 对话。"
                            return
                        }
                        Task {
                            await Task.detached {
                                AIConversationStore.shared.releaseCodexClient()
                            }.value
                            _ = NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.borderless)
                }
            }
            if !conversationNotice.isEmpty {
                Text(conversationNotice).font(.caption).foregroundStyle(.secondary)
            }
            if !continuationNotice.isEmpty {
                Text(continuationNotice).font(.caption).foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }
}

private struct PersonalTranslationStyleEditor: View {
    @EnvironmentObject private var settings: AppSettingsStore
    @State private var draft: String?
    @FocusState private var editing: Bool

    private var guidance: String { settings.aiTranslationConfiguration.personalStyleGuidance }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            TextEditor(text: Binding(get: { draft ?? guidance }, set: { draft = $0 }))
                .focused($editing)
                .font(.system(size: 13))
                .frame(height: 248)
                .padding(5)
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(.quaternary))
                .accessibilityLabel("我的翻译风格")
            HStack {
                Text(draft == nil ? "新翻译会使用上面的风格说明。" : "完成编辑后保存，留空会恢复内置风格。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("恢复默认") {
                    draft = nil
                    settings.aiTranslationConfiguration.personalStyleOverride = ""
                }
                .disabled(settings.aiTranslationConfiguration.personalStyleOverride.isEmpty && draft == nil)
                if draft != nil {
                    Button("完成") { saveDraft(); editing = false }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .onChange(of: editing) { focused in if !focused { saveDraft() } }
        .onDisappear { saveDraft() }
    }

    private func saveDraft() {
        guard let draft else { return }
        let value = TranslationPromptPresetCatalog.normalizePersonalOverride(draft)
        if value != settings.aiTranslationConfiguration.personalStyleOverride {
            settings.aiTranslationConfiguration.personalStyleOverride = value
        }
        self.draft = nil
    }
}

private struct AISettingsView: View {
    @EnvironmentObject private var settings: AppSettingsStore
    @EnvironmentObject private var playback: PlaybackState
    @State private var apiKeyDraft = ""
    @State private var hasStoredKey = false
    @State private var statusMessage = ""
    @State private var promptPreview: AITranslationPrompt?
    @State private var showPromptPreview = false
    @State private var showProfileManager = false
    @State private var isAdvancedAIExpanded = false
    private var engineID: String { settings.aiTranslationConfiguration.engineID }
    /// OpenAI and DeepSeek need nothing but a key: fixed endpoint, model
    /// picked automatically, each key in its own Keychain item.
    private var isKeyOnlyEngine: Bool {
        [TranslationEngineID.openAIAPI.rawValue, TranslationEngineID.deepSeekAPI.rawValue].contains(engineID)
    }
    private var keyStore: KeychainAITranslationAPIKeyStore {
        switch TranslationEngineID(rawValue: engineID) {
        case .openAIAPI: return KeychainAITranslationAPIKeyStore(account: OpenAIAPIDefaults.keychainAccount)
        case .deepSeekAPI: return KeychainAITranslationAPIKeyStore(account: DeepSeekTranslationService.keychainAccount)
        default: return KeychainAITranslationAPIKeyStore()
        }
    }
    /// Whether a key was saved, remembered without reading the Keychain.
    private var storedKeyFlag: Bool {
        get {
            isKeyOnlyEngine ? UserDefaults.lyricsQ.bool(forKey: "ai.apiKeyConfigured.v1." + engineID)
                : settings.aiTranslationAPIKeyConfigured
        }
        nonmutating set {
            if isKeyOnlyEngine { UserDefaults.lyricsQ.set(newValue, forKey: "ai.apiKeyConfigured.v1." + engineID) }
            else { settings.aiTranslationAPIKeyConfigured = newValue }
        }
    }

    private var keyOnlySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SecureField(engineID == TranslationEngineID.openAIAPI.rawValue ? "OpenAI API Key（sk-…）" : "DeepSeek API Key（sk-…）",
                        text: $apiKeyDraft)
                .textFieldStyle(.roundedBorder)
                .onSubmit(saveKey)
            HStack {
                Button(hasStoredKey ? "替换密钥" : "保存密钥", action: saveKey)
                    .disabled(apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if hasStoredKey {
                    Button("清除密钥", role: .destructive, action: clearKey)
                }
                Text(hasStoredKey ? "已保存（Keychain）" : "未填写").font(.caption).foregroundStyle(.secondary)
            }
            if !statusMessage.isEmpty {
                Text(statusMessage).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Text("只需要填密钥，接口地址不用管。保存后会列出这个账号能用的模型，在 工具栏 → 译文 里选模型和思考强度。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func saveKey() {
        let value = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        do {
            try keyStore.save(value)
            apiKeyDraft = ""
            hasStoredKey = true
            storedKeyFlag = true
            statusMessage = "密钥已保存到 Keychain（不会显示或写入日志）。"
            if isKeyOnlyEngine { settings.refreshAIModelDirectory() }
        } catch {
            statusMessage = "保存失败：\(error.localizedDescription)"
        }
    }

    private func clearKey() {
        do {
            try keyStore.delete()
            hasStoredKey = false
            apiKeyDraft = ""
            storedKeyFlag = false
            statusMessage = "密钥已清除。"
        } catch {
            statusMessage = "清除失败：\(error.localizedDescription)"
        }
    }

    var body: some View {
        Form {
            SettingsPageHeader(
                title: "AI 翻译",
                detail: "对当前已加载的整首歌词做上下文翻译。原文、假名、罗马音和时间轴不会被 AI 修改。"
            )

            Section("翻译默认行为") {
                TextField("目标语言", text: configurationBinding(\.targetLanguage))
                    .textFieldStyle(.roundedBorder)
                // Two choices only (2026-11-15): the user's own style, or text
                // they write. Older presets stay readable for saved settings.
                Picker("翻译风格", selection: stylePresetBinding) {
                    Text("我的风格").tag(TranslationPromptPresetID.personalV2.rawValue)
                    Text("自定义").tag(TranslationPromptPresetID.custom.rawValue)
                    if let legacy = TranslationPromptPresetCatalog.all.first(where: {
                        $0.id.rawValue == settings.aiTranslationConfiguration.promptPresetID
                            && $0.id != .personalV2 && $0.id != .custom
                    }) {
                        Text("\(legacy.displayName)（旧设置）").tag(legacy.id.rawValue)
                    }
                }
                if settings.aiTranslationConfiguration.promptPresetID == TranslationPromptPresetID.custom.rawValue {
                    VStack(alignment: .leading, spacing: 5) {
                        TextEditor(text: configurationBinding(\.customSystemPrompt))
                            .frame(minHeight: 90)
                            .font(.system(size: 12))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                        Text("写下你想要的译法，例如语气、用词、要保留的东西。只在选「自定义」时使用。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else if settings.aiTranslationConfiguration.promptPresetID == TranslationPromptPresetID.personalV2.rawValue {
                    PersonalTranslationStyleEditor()
                }
                ToolbarPanelLink(title: "调整新歌词自动翻译", panel: .translation)
            }

            Section("翻译服务") {
                TranslationProviderControls(settings: settings)
                ToolbarPanelLink(title: "调整模型与思考强度", panel: .translation)
                let selectedEngine = TranslationEngineRegistry.make(stableID: settings.aiTranslationConfiguration.engineID).metadata
                Text(engineAvailabilityText(selectedEngine))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if selectedEngine.stableID == TranslationEngineID.codexChatGPT.rawValue {
                    Label("由本机 Codex app-server 管理 ChatGPT 登录；不会读取或保存 auth.json / OAuth 原始凭据。复用既有登录；未登录时请先在 Codex 中完成登录，再刷新模型。", systemImage: "lock.shield")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if isKeyOnlyEngine {
                    keyOnlySection
                } else {
                DisclosureGroup("API 地址、Key 与连接测试") {
                    TextField("兼容接口地址（Base URL）", text: configurationBinding(\.baseURL))
                        .textFieldStyle(.roundedBorder)
                        .disabled(selectedEngine.stableID == TranslationEngineID.codexChatGPT.rawValue)
                    SecureField("API Key（只保存到 Keychain）", text: $apiKeyDraft)
                        .textFieldStyle(.roundedBorder)
                        .disabled(selectedEngine.stableID == TranslationEngineID.codexChatGPT.rawValue)
                    HStack {
                        Button(hasStoredKey ? "替换 API Key" : "保存 API Key") {
                            let value = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !value.isEmpty else { return }
                            do {
                                try keyStore.save(value)
                                apiKeyDraft = ""
                                hasStoredKey = true
                                storedKeyFlag = true
                                statusMessage = "API Key 已保存到 Keychain（不会显示或写入日志）。"
                            } catch {
                                statusMessage = "保存失败：\(error.localizedDescription)"
                            }
                        }
                        .disabled(selectedEngine.stableID == TranslationEngineID.codexChatGPT.rawValue)
                        Button("清除 API Key", role: .destructive) {
                            do {
                                try keyStore.delete()
                                hasStoredKey = false
                                apiKeyDraft = ""
                                storedKeyFlag = false
                                statusMessage = "API Key 已清除。"
                            } catch {
                                statusMessage = "清除失败：\(error.localizedDescription)"
                            }
                        }
                        .disabled(selectedEngine.stableID == TranslationEngineID.codexChatGPT.rawValue)
                        Text(hasStoredKey ? "已配置（Keychain）" : "未配置")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("测试连接（发送请求）") {
                            statusMessage = "正在发送最小测试请求…"
                            let configuration = settings.aiTranslationConfiguration
                            let engine = TranslationEngineRegistry.make(stableID: configuration.engineID)
                            Task {
                                do {
                                    try await engine.testConnection(configuration: configuration)
                                    await MainActor.run { statusMessage = "连接成功。测试请求未使用当前歌词。" }
                                } catch {
                                    await MainActor.run { statusMessage = error.localizedDescription }
                                }
                            }
                        }
                        if !statusMessage.isEmpty {
                            Text(statusMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    Text("macOS 可能在首次保存、替换或清除时请求 Keychain 鉴权；仅浏览此页面不会读取 Key。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Base URL 支持已包含 /v1、完整 /v1/chat/completions 和自定义反代路径；应用不会重复拼接 /v1。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                }
            }

            Section {
                DisclosureGroup("高级模型参数与提示词", isExpanded: $isAdvancedAIExpanded) {
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("随机度（Temperature）")
                            V3NumericSlider(value: configurationDoubleBinding(\.temperature), in: 0...2, step: 0.1)
                                .accessibilityLabel("模型随机度")
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("请求超时")
                            V3NumericSlider(value: configurationDoubleBinding(\.timeout), in: 5...600, step: 5, unit: "秒")
                                .accessibilityLabel("模型请求超时")
                        }
                        Picker("失败后的策略", selection: fallbackBinding) {
                            ForEach(TranslationFallbackStrategy.allCases, id: \.self) { strategy in
                                Text(strategy.title).tag(strategy)
                            }
                        }
                        Picker("个人翻译风格档案", selection: profileBinding) {
                            Text("不使用个人档案").tag("")
                            ForEach(settings.translationProfiles.list(), id: \.id) { profile in
                                Text(profile.name).tag(profile.id.uuidString)
                            }
                        }
                        Button("管理个人翻译风格", systemImage: "person.crop.circle.badge.pencil") {
                            showProfileManager = true
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Button("查看当前 Prompt 内容", systemImage: "doc.text.magnifyingglass") {
                                do {
                                    let preset = TranslationPromptPresetID(rawValue: settings.aiTranslationConfiguration.promptPresetID) ?? .personalV2
                                    promptPreview = try AITranslationPromptBuilder().preview(
                                        context: promptContext,
                                        configuration: settings.aiTranslationConfiguration,
                                        presetID: preset,
                                        profile: selectedProfile
                                    )
                                    showPromptPreview = true
                                } catch {
                                    statusMessage = "查看当前 Prompt 内容失败：\(error.localizedDescription)"
                                }
                            }
                            Text("只读检查当前将发送给 LLM 的完整 Prompt，不会发送请求，不代表设置未保存。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showPromptPreview) {
            if let promptPreview {
                TranslationPromptPreviewView(prompt: promptPreview)
            }
        }
        .sheet(isPresented: $showProfileManager) {
            TranslationProfilesView()
                .environmentObject(settings)
        }
        .onAppear {
            hasStoredKey = storedKeyFlag
        }
        .onChange(of: engineID) { _, _ in
            hasStoredKey = storedKeyFlag
            apiKeyDraft = ""
            statusMessage = ""
        }
    }

    private var selectedProfile: TranslationStyleProfile? {
        guard let id = settings.aiTranslationConfiguration.profileID else { return nil }
        return settings.translationProfiles.list(includeArchived: true).first { $0.id == id }
    }

    private func engineAvailabilityText(_ engine: TranslationEngineMetadata) -> String {
        switch engine.availability {
        case .available:
            if engine.stableID == TranslationEngineID.appleSystem.rawValue {
                return "可用：系统翻译优先隐私与速度，歌词语境和文学性可能弱于 AI。"
            }
            if engine.stableID == TranslationEngineID.codexChatGPT.rawValue {
                return "通过本机 Codex app-server 翻译；登录状态与服务连接以实际请求结果为准。"
            }
            return "支持此引擎；请配置服务地址、模型和 API Key，连接状态以测试结果为准。"
        case .requiresConfiguration:
            return "需要配置：Base URL、模型和 API Key。"
        case .requiresSystemSupport:
            return "需要系统支持：当前系统或语言组合可能不可用。"
        case .unavailable:
            return "当前引擎不可用。"
        }
    }

    private var stylePresetBinding: Binding<String> {
        Binding(get: { settings.aiTranslationConfiguration.promptPresetID }, set: { rawValue in
            guard let preset = TranslationPromptPresetID(rawValue: rawValue) else { return }
            var next = settings.aiTranslationConfiguration
            next.promptPresetID = rawValue
            next.style = preset.legacyStyle
            settings.aiTranslationConfiguration = next
        })
    }

    private var profileBinding: Binding<String> {
        Binding(
            get: { settings.aiTranslationConfiguration.profileID?.uuidString ?? "" },
            set: { value in
                var next = settings.aiTranslationConfiguration
                next.profileID = UUID(uuidString: value)
                if let profile = settings.translationProfiles.list(includeArchived: true).first(where: { $0.id.uuidString == value }) {
                    next.profileSnapshot = profile.snapshotString
                    next.promptPresetID = profile.basePresetID.rawValue
                    next.style = profile.basePresetID.legacyStyle
                    next.targetLanguage = profile.targetLanguage
                    if let temperature = profile.temperatureOverride { next.temperature = temperature }
                } else {
                    next.profileSnapshot = ""
                }
                settings.aiTranslationConfiguration = next
            }
        )
    }

    private var promptContext: AITranslationContext {
        let lines = playback.liveLyrics.enumerated().map { index, line in
            AITranslationSourceLine(
                index: index,
                original: line.originalText,
                kana: line.kanaText,
                romaji: line.romajiText,
                lineID: line.id,
                timestamp: line.timestamp
            )
        }
        let profile = selectedProfile
        return AITranslationContext(
            title: playback.currentTrack.title,
            artist: playback.currentTrack.artist,
            album: playback.currentTrack.album,
            sourceLanguage: playback.liveLyricsLanguage ?? "und",
            targetLanguage: settings.aiTranslationConfiguration.targetLanguage,
            style: settings.aiTranslationConfiguration.style,
            lines: lines.isEmpty ? [AITranslationSourceLine(index: 0, original: "")] : lines,
            styleSummary: profile?.styleSummary ?? "",
            styleExamples: profile?.examples ?? []
        )
    }

    private func configurationBinding<Value>(_ keyPath: WritableKeyPath<AITranslationConfiguration, Value>) -> Binding<Value> {
        Binding(
            get: { settings.aiTranslationConfiguration[keyPath: keyPath] },
            set: { value in
                var next = settings.aiTranslationConfiguration
                next[keyPath: keyPath] = value
                settings.aiTranslationConfiguration = next
            }
        )
    }

    private func configurationDoubleBinding(_ keyPath: WritableKeyPath<AITranslationConfiguration, TimeInterval>) -> Binding<Double> {
        Binding(
            get: { settings.aiTranslationConfiguration[keyPath: keyPath] },
            set: { value in
                var next = settings.aiTranslationConfiguration
                next[keyPath: keyPath] = value
                settings.aiTranslationConfiguration = next
            }
        )
    }

    private var fallbackBinding: Binding<TranslationFallbackStrategy> {
        Binding(
            get: { settings.aiTranslationConfiguration.fallbackStrategy },
            set: { value in
                var next = settings.aiTranslationConfiguration
                next.fallbackStrategy = value
                settings.aiTranslationConfiguration = next
            }
        )
    }
}

private struct TranslationProfilesView: View {
    @EnvironmentObject private var settings: AppSettingsStore
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var editingID: UUID?
    @State private var editingName = ""
    @State private var deleteCandidate: TranslationStyleProfile?

    private var profiles: [TranslationStyleProfile] {
        settings.translationProfiles.list(includeArchived: true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("个人翻译风格").font(.title3.weight(.semibold))
                    Text("内置预设不会被修改；档案变更不会回写已有翻译版本。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { dismiss() }
            }

            HStack {
                TextField("新风格名称", text: $newName)
                    .textFieldStyle(.roundedBorder)
                Button("创建", systemImage: "plus") {
                    let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return }
                    _ = settings.translationProfiles.create(name: name)
                    newName = ""
                    notifySettingsChanged()
                }
                .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            List(profiles) { profile in
                HStack(spacing: 10) {
                    if editingID == profile.id {
                        TextField("名称", text: $editingName)
                            .textFieldStyle(.roundedBorder)
                        Button("保存") {
                            let name = editingName.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !name.isEmpty else { return }
                            settings.translationProfiles.update(profile.with(name: name))
                            editingID = nil
                            notifySettingsChanged()
                        }
                        Button("取消") { editingID = nil }
                    } else {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.name)
                            Text(profile.basePresetID.displayName + (profile.isArchived ? " · 已归档" : ""))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(profile.styleSummary.isEmpty ? "尚无已确认人工样例" : profile.styleSummary)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Spacer()
                        Button("复制", systemImage: "plus.square.on.square") {
                            _ = settings.translationProfiles.copy(profile)
                            notifySettingsChanged()
                        }
                        Button("重命名", systemImage: "pencil") {
                            editingID = profile.id
                            editingName = profile.name
                        }
                        Button("重建摘要", systemImage: "arrow.clockwise") {
                            settings.translationProfiles.regenerateSummary(profileID: profile.id)
                            notifySettingsChanged()
                        }
                        Menu {
                            Button(profile.isArchived ? "恢复" : "归档") {
                                settings.translationProfiles.archive(id: profile.id, archived: !profile.isArchived)
                                notifySettingsChanged()
                            }
                            Divider()
                            Button("删除", role: .destructive) { deleteCandidate = profile }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                    }
                }
                .padding(.vertical, 3)
            }
            .frame(minHeight: 220)
        }
        .padding(20)
        .frame(width: 640, height: 470)
        .confirmationDialog(
            "删除个人翻译风格？",
            isPresented: Binding(
                get: { deleteCandidate != nil },
                set: { if !$0 { deleteCandidate = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                guard let profile = deleteCandidate else { return }
                settings.translationProfiles.delete(id: profile.id)
                if settings.aiTranslationConfiguration.profileID == profile.id {
                    var configuration = settings.aiTranslationConfiguration
                    configuration.profileID = nil
                    configuration.profileSnapshot = ""
                    settings.aiTranslationConfiguration = configuration
                }
                deleteCandidate = nil
                notifySettingsChanged()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("不会删除已经生成的翻译版本。")
        }
    }

    private func notifySettingsChanged() {
        // ProfileStore is shared by the settings center and current-song
        // entry. Reassigning the existing value only nudges the owning
        // AppSettingsStore to refresh its bindings; it does not create a
        // second settings store or alter the current playback session.
        settings.aiTranslationConfiguration = settings.aiTranslationConfiguration
    }
}

private struct TranslationPromptPreviewView: View {
    let prompt: AITranslationPrompt
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("查看当前 Prompt 内容").font(.title3.weight(.semibold))
                Spacer()
                Button("关闭") { dismiss() }
            }
            Text("只读检查 · 展示当前将发送给 LLM 的请求/Prompt 内容，不会请求 API、写数据库或改变播放状态。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Prompt Hash: \(prompt.promptHash)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            GroupBox("System") {
                ScrollView { Text(prompt.system).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                    .frame(minHeight: 110)
            }
            GroupBox("Input JSON") {
                ScrollView { Text(prompt.user).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                    .frame(minHeight: 110)
            }
        }
        .padding(20)
        .frame(width: 680, height: 540)
    }
}

private struct AdvancedAndDataSettingsView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var playback: PlaybackState
    @EnvironmentObject private var settings: AppSettingsStore
    @EnvironmentObject private var data: SettingsDataController
    let onOpenTool: (SettingsCategory) -> Void

    @State private var isExperienceExpanded = false

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发构建"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "未指定"
        return "\(version) (\(build))"
    }

    var body: some View {
        Form {
            SettingsPageHeader(
                title: "高级与数据",
                detail: "数据库维护、系统诊断、窗口状态与实用工具。"
            )

            LibraryStorageSettingsView(data: data)

            Section("诊断") {
                LabeledContent("应用版本", value: appVersion)
                LabeledContent("支持的数据格式", value: "v\(DatabaseMigrator.currentVersion)")
                Button("在 Finder 中显示日志") {
                    let url = LyricsE2ELog.fileURL
                    if FileManager.default.fileExists(atPath: url.path) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    else { NSWorkspace.shared.open(url.deletingLastPathComponent()) }
                }
                Button("导出脱敏诊断摘要") { data.exportDiagnostics() }
            }

            Section("窗口") {
                Button("重置窗口状态") { settings.resetWindowState() }
                Text("会删除保存的窗口位置，下次打开使用系统默认位置。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

            }

            Section("实用工具") {
                Button {
                    playback.selectedLibraryToolTab = .library
                    openWindow(id: "personal-library-activity")
                } label: {
                    HStack {
                        Label("打开我的歌词库", systemImage: "music.note.list")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("btn_enter_library")

                Button {
                    playback.selectedLibraryToolTab = .history
                    openWindow(id: "personal-library-activity")
                } label: {
                    HStack {
                        Label("查看最近播放", systemImage: "clock.arrow.circlepath")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("btn_enter_history")

                Button {
                    playback.selectedLibraryToolTab = .statistics
                    openWindow(id: "personal-library-activity")
                } label: {
                    HStack {
                        Label("查看听歌统计", systemImage: "chart.bar")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("btn_enter_statistics")
            }

            Section {
                DisclosureGroup("深入体验", isExpanded: $isExperienceExpanded) {
                    VStack(alignment: .leading, spacing: 14) {
                        Button {
                            onOpenTool(.experienceLibrary)
                        } label: {
                            HStack {
                                Label("打开体验版本库", systemImage: "rectangle.on.rectangle")
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("btn_enter_experience_library")

                        Text("预览、应用或恢复主窗口、桌面歌词和其他呈现版本。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Divider()

                        VStack(alignment: .leading, spacing: 6) {
                            Picker("设置中心版本", selection: settingsCenterPresentationBinding) {
                                Text("体验版本库集成（推荐）")
                                    .tag(SettingsCenterPresentationID.experienceIntegratedV2.rawValue)
                                Text("经典导航")
                                    .tag(SettingsCenterPresentationID.classicNavigationV1.rawValue)
                            }
                            Text("两个设置中心共用同一份设置和 Keychain；切换不会删除体验版本库或重置已有设置。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if settings.settingsCenterPresentation == .classicNavigationV1 {
                                Button("恢复推荐设置中心", systemImage: "arrow.uturn.backward.circle") {
                                    settings.settingsCenterPresentation = .experienceIntegratedV2
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

        }
        .formStyle(.grouped)
        .onAppear { data.refreshStatistics() }
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !data.statusMessage.isEmpty {
                HStack {
                    if data.isBusy { ProgressView().controlSize(.small) }
                    Text(data.statusMessage).font(.callout).textSelection(.enabled)
                    Spacer()
                    if !data.isBusy {
                        Button { data.dismissNotice() } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless).accessibilityLabel("收起提示")
                    }
                }
                .padding(.horizontal, 18).padding(.vertical, 8).background(.bar)
            }
        }
    }

    private var settingsCenterPresentationBinding: Binding<String> {
        Binding(
            get: { settings.settingsCenterPresentationRawValue },
            set: { settings.settingsCenterPresentationRawValue = $0 }
        )
    }
}
