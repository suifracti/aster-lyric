import SwiftUI
import AppKit

extension Notification.Name {
    static let lyricIslandOpenAISettings = Notification.Name("lyricIslandOpenAISettings")
}

@MainActor
final class SettingsNavigationRoute: ObservableObject {
    static let shared = SettingsNavigationRoute()

    @Published private(set) var pendingAISettings = false

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

private enum SettingsCategory: String, CaseIterable, Identifiable {
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

    static var primaryCases: [SettingsCategory] {
        [.general, .lyricsAndText, .aiTranslation, .appearance, .reading, .advancedAndData]
    }

    var id: String { rawValue }

    var systemImage: String {
        switch self {
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
        case .lyricsAndText: return "显示翻译 显示原文 字号 字体 透明度 繁简 转换 自动搜索 自动排轴 时间轴"
        case .appearance: return "布局 背景 模糊 环境光 封面舞台 经典放大 柔光羽化 纯净歌词 封面海报 菜单栏 置顶 悬浮 透明 颜色 窗口状态"
        case .reading: return "日语 中文 注音 Ruby 声调 本地引擎 自动生成 人工词典 优先级 读音候选"
        case .advancedAndData: return "数据库 存储 索引 重置 日志 导出 清除"
        case .servicesAndSources: return "Provider 免费 实验 LRCLIB 本地 Uta-Net UtaTime AWA"
        case .aiTranslation: return "API Key Keychain Base URL Codex ChatGPT GPT 目标语言 自动翻译 提示词 Prompt 超时 Temperature 连接测试"
        case .library, .history, .statistics, .experienceLibrary: return ""
        }
    }

    func matches(_ query: String) -> Bool {
        let searchable = "\(rawValue) \(detail) \(searchTerms)"
        return query.split(whereSeparator: { $0.isWhitespace }).allSatisfy {
            searchable.localizedStandardContains(String($0))
        }
    }
}

struct SettingsRootView: View {
    @EnvironmentObject private var settings: AppSettingsStore
    @StateObject private var navigationRoute = SettingsNavigationRoute.shared
    @State private var selection: SettingsCategory = .general
    @State private var searchText = ""

    private var visibleCategories: [SettingsCategory] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty { return SettingsCategory.allCases.filter { $0.matches(query) } }
        return SettingsCategory.primaryCases
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("搜索设置", text: $searchText)
                        .textFieldStyle(.plain)
                        .accessibilityIdentifier("settings.search")
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("清除搜索")
                        .accessibilityLabel("清除搜索")
                    }
                }
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                .padding(12)

                List(selection: $selection) {
                    ForEach(visibleCategories) { category in
                        Label {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(category.rawValue)
                                Text(category.detail)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        } icon: {
                            Image(systemName: category.systemImage)
                        }
                        .padding(.vertical, 4)
                        .tag(category)
                    }
                    if visibleCategories.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("没有匹配的设置")
                            Text("试试“翻译”“字体”或“Spotify”。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("显示全部设置") { searchText = "" }
                                .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 8)
                    }
                    if settings.settingsCenterPresentation == .classicNavigationV1 {
                        Section {
                            Button {
                                settings.settingsCenterPresentation = .experienceIntegratedV2
                            } label: {
                                Label("恢复推荐设置中心", systemImage: "arrow.uturn.backward.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                .listStyle(.sidebar)
            }
            .navigationTitle("设置")
            .accessibilityIdentifier(settings.settingsCenterPresentation.rawValue)
            .navigationSplitViewColumnWidth(min: 205, ideal: 215, max: 250)
        } detail: {
            SettingsDetailView(selection: $selection)
                .environmentObject(settings)
        }
        .frame(minWidth: 800, idealWidth: 920, minHeight: 540, idealHeight: 650)
        .background(SettingsWindowBehavior())
        .onReceive(NotificationCenter.default.publisher(for: .lyricIslandOpenAISettings)) { _ in
            navigateToAISettings()
        }
        .onAppear {
            if navigationRoute.consumePendingAISettingsRequest() {
                navigateToAISettings()
            }
        }
    }

    private func navigateToAISettings() {
        _ = navigationRoute.consumePendingAISettingsRequest()
        searchText = ""
        selection = .aiTranslation
    }
}

private struct TransitionalBridgeContainer<Content: View>: View {
    let title: String
    let onBack: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button(action: onBack) {
                    Label(title, systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("transitional_bridge_back_button")
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            Divider()

            content()
        }
    }
}

private struct SettingsDetailView: View {
    @EnvironmentObject private var settings: AppSettingsStore
    @Binding var selection: SettingsCategory

    var body: some View {
        Group {
            switch selection {
            case .general:
                ServicesAndSourcesSettingsView(scope: .playback)
                    .padding(16)
            case .lyricsAndText:
                LyricsAndTextSettingsView(
                    onOpenSources: { selection = .servicesAndSources },
                    onOpenTranslation: { selection = .aiTranslation },
                    onOpenReading: { selection = .reading }
                )
                .padding(16)
            case .appearance:
                AppearanceSettingsView()
                    .padding(16)
            case .reading:
                ReadingSettingsView()
                    .padding(16)
            case .servicesAndSources:
                TransitionalBridgeContainer(title: "返回歌词与翻译", onBack: { selection = .lyricsAndText }) {
                    ServicesAndSourcesSettingsView(scope: .lyrics)
                        .padding(16)
                }
            case .aiTranslation:
                TransitionalBridgeContainer(title: "返回歌词与翻译", onBack: { selection = .lyricsAndText }) {
                    AISettingsView()
                        .padding(16)
                }
            case .advancedAndData:
                AdvancedAndDataSettingsView(
                    onOpenTool: { tool in selection = tool }
                )
                .padding(28)

            // Hidden Bridge Destinations
            case .library:
                TransitionalBridgeContainer(title: "返回高级与数据", onBack: { selection = .advancedAndData }) {
                    PersonalLyricsLibraryView()
                }
            case .history:
                TransitionalBridgeContainer(title: "返回高级与数据", onBack: { selection = .advancedAndData }) {
                    ListeningHistoryView()
                }
            case .statistics:
                TransitionalBridgeContainer(title: "返回高级与数据", onBack: { selection = .advancedAndData }) {
                    ListeningStatisticsView()
                }
            case .experienceLibrary:
                TransitionalBridgeContainer(title: "返回高级与数据", onBack: { selection = .advancedAndData }) {
                    ExperienceLibrarySettingsView(selectionStore: settings.presentationSelections)
                        .padding(28)
                }
            }
        }
        .id(selection)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct SettingsPageHeader: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                SettingsRecordMark()
                Text("LYRIC ISLAND · SETTINGS")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(1.1)
                    .foregroundStyle(.secondary)
            }
            Text(title)
                .font(.system(size: 25, weight: .semibold))
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 10)
    }
}

private struct SettingsRecordMark: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Capsule().frame(width: 16, height: 2)
            Capsule().frame(width: 11, height: 2)
        }
        .frame(width: 16, height: 7)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
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

private struct AppearanceSettingsView: View {
    @EnvironmentObject private var settings: AppSettingsStore

    var body: some View {
        Form {
            SettingsPageHeader(title: "外观", detail: "选择适合自己的歌词画面，并调整主窗口、桌面歌词和菜单栏。")

            Section("主窗口") {
                Picker("默认主窗口布局", selection: mainWindowLayoutSelection) {
                    ForEach(MainWindowLayoutStyle.userSelectableCases) { layout in
                        Text(layout.title).tag(layout.rawValue)
                    }
                }
                if settings.mainWindowLayoutStyleRawValue == MainWindowLayoutStyle.directionDV4.rawValue {
                    Text("Direction D 为实验布局；歌曲工作台的部分信息与操作尚未接入。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if settings.mainWindowLayoutStyleRawValue == MainWindowLayoutStyle.appleMusicImmersiveV3.rawValue {
                    Picker("画面风格", selection: $settings.v3ArtworkPresentationRawValue) {
                        ForEach(V3ArtworkPresentation.allCases) { presentation in
                            Text(presentation.title).tag(presentation.rawValue)
                        }
                    }
                    Text(settings.v3ArtworkPresentation.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                DisclosureGroup("经典伴随布局") {
                    Picker("经典伴随呈现", selection: $settings.classicCompanionPresentationRawValue) {
                        ForEach(ClassicCompanionPresentation.allCases) { presentation in
                            Text(presentation.title).tag(presentation.rawValue)
                        }
                    }
                    Text("经典伴随 V1 可按窗口宽度自适应，也可固定为沉浸分栏或歌词专注。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle("小窗口自动进入歌词专注", isOn: $settings.automaticCompactLyricsFocus)
                Text("仅在 V3 主窗口达到保守的小窗口阈值时临时隐藏封面与次要信息；恢复窗口尺寸后自动返回原布局。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("启动时恢复上次窗口状态", isOn: $settings.restoreWindowState)
                Toggle("主窗口保持置顶", isOn: $settings.keepMainWindowOnTop)
            }

            Section("悬浮歌词") {
                Picker("默认呈现", selection: $settings.floatingLyricsPresentationRawValue) {
                    ForEach(FloatingLyricsPresentationVersion.allCases, id: \.rawValue) { version in
                        Text(version.title).tag(version.rawValue)
                    }
                }
                DisclosureGroup("桌面歌词样式与交互") {
                    Picker("透明样式", selection: $settings.floatingLyricsSurfaceStyleRawValue) {
                        ForEach(FloatingLyricsSurfaceStyle.allCases, id: \.rawValue) { style in
                            Text(style.title).tag(style.rawValue)
                        }
                    }
                    Picker("桌面歌词行数", selection: $settings.floatingDesktopLineMode) {
                        ForEach(FloatingDesktopLineMode.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                    }
                    HStack {
                        Text("桌面歌词字号")
                        Slider(value: $settings.floatingDesktopFontSize, in: 22...64, step: 1)
                        Text("\(Int(settings.floatingDesktopFontSize))").monospacedDigit().frame(width: 30)
                    }
                    FloatingDesktopColorControls(settings: settings)
                    Toggle("悬浮歌词保持置顶", isOn: $settings.floatingWindowAlwaysOnTop)
                    Picker("默认交互状态", selection: floatingModeBinding) {
                        ForEach(FloatingLyricsInteractionMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    HStack {
                        Text(settings.floatingLyricsPresentation == .transparentV2 && settings.floatingDesktopKeepsTextOpaque ? "背景不透明度" : "整个悬浮窗透明度")
                        Slider(value: $settings.floatingWindowOpacity, in: 0.45...1, step: 0.01)
                        Text(String(format: "%.0f%%", settings.floatingWindowOpacity * 100))
                            .font(.system(.caption, design: .monospaced))
                            .frame(width: 48, alignment: .trailing)
                    }
                }
                Text("悬浮歌词复用主播放状态和歌词显示设置；关闭后不会退出 App。启用“启动时恢复上次窗口状态”时，会恢复上次可见的悬浮窗位置和尺寸。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("菜单栏") {
                Toggle("在菜单栏显示歌词", isOn: $settings.menuBarLyricsEnabled)
                Text("关闭后仅显示播放状态图标，点击图标仍可打开歌词与播放控制。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        }
        .formStyle(.grouped)
    }

    private var floatingModeBinding: Binding<FloatingLyricsInteractionMode> {
        Binding(
            get: { settings.floatingWindowInteractionMode },
            set: { settings.floatingWindowInteractionMode = $0 }
        )
    }

    private var mainWindowLayoutSelection: Binding<String> {
        Binding(
            get: { settings.mainWindowLayoutStyleRawValue },
            set: { rawValue in
                guard let style = MainWindowLayoutStyle(rawValue: rawValue) else { return }
                _ = settings.applyPresentationSelection(
                    category: .mainWindow,
                    stableID: style.presentationStableID
                )
            }
        )
    }
}

private struct ServicesAndSourcesSettingsView: View {
    enum Scope { case playback, lyrics }
    let scope: Scope
    @EnvironmentObject private var playbackState: PlaybackState
    @EnvironmentObject private var settings: AppSettingsStore
    @State private var clientIDDraft = ""
    @State private var discoveryQuery = ""
    @State private var isExternalDiscoveryExpanded = false

    private var authorization: SpotifyAuthorizationManager {
        playbackState.spotifyAuthorizationManager
    }

    var body: some View {
        Form {
            SettingsPageHeader(
                title: scope == .playback ? "播放" : "歌词来源",
                detail: scope == .playback ? "选择正在使用的音乐 App，查看连接状态与启动行为。" : "选择歌词搜索范围，调整来源顺序或在浏览器中继续查找。"
            )

            if scope == .playback {
                Section("播放来源") {
                    Picker("播放源模式", selection: $settings.playbackSourceMode) {
                        ForEach(PlaybackSourceMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.radioGroup)

                    Text(settings.playbackSourceMode.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    LabeledContent("当前状态", value: playbackState.providerStatusMessage)
                }

                Section("启动行为") {
                    Toggle("启动时自动连接 Spotify Desktop", isOn: $settings.connectSpotifyOnLaunch)
                    Text("播放状态会显示在上方；连接失败时，可在主窗口重新连接。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("桌面播放控制") {
                    LabeledContent("当前播放连接", value: playbackState.providerStatus.userFacingMessage)
                    Text("Spotify Desktop 播放控制不需要下方的在线曲库授权。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Spotify Web 在线曲库") {
                    LabeledContent("授权状态", value: authorization.state.userFacingMessage)
                    DisclosureGroup("配置在线曲库授权") {
                        HStack {
                            TextField("Client ID", text: $clientIDDraft)
                                .textFieldStyle(.roundedBorder)
                            Button("保存") { authorization.updateClientID(clientIDDraft) }
                                .buttonStyle(.bordered)
                        }
                        Text("只填写 Spotify Developer Dashboard 中的 Client ID，不需要 Client Secret。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("授权 Spotify") { authorize() }
                                .buttonStyle(.borderedProminent)
                            Button("刷新授权状态") { authorization.refreshAuthorizationState() }
                        }
                        HStack {
                            Button("断开授权") { authorization.disconnect() }
                                .disabled(!authorization.state.isAuthorized)
                            Button("清除 Keychain Token") { authorization.disconnect() }
                                .disabled(!authorization.state.isAuthorized)
                        }
                        LabeledContent("Dashboard 注册地址") {
                            Text(authorization.dashboardRedirectURI)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        LabeledContent("当前本地监听地址") {
                            Text(authorization.localRedirectURI ?? "未启动（授权时动态分配端口）")
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        Text("Dashboard 只需注册不带端口的回环地址；授权时应用会临时监听一个动态端口，并在请求和换取 Token 时使用同一个完整地址。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("授权失败不会影响 Spotify Desktop 当前播放和本地歌词链路。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
        .onAppear { clientIDDraft = authorization.clientID ?? "" }
    }

    private func authorize() {
        authorization.updateClientID(clientIDDraft)
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

struct TranslationProviderControls: View {
    @ObservedObject var settings: AppSettingsStore

    private var provider: String { settings.aiTranslationConfiguration.engineID }
    private var family: String { TranslationEngineCatalog.topLevelID(for: provider) }
    private var modelBinding: Binding<String> {
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

    private var reasoningBinding: Binding<String> {
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
         TranslationEngineID.deepSeekAPI.rawValue].contains(provider)
    }

    private var advertisedReasoningOptions: [String]? {
        let descriptor = settings.aiCachedModels.first(where: {
            $0.id == settings.aiTranslationConfiguration.model
        })
        let values: [String]?
        if let cached = descriptor?.reasoningEfforts {
            values = cached
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
        guard !value.isEmpty else { return "待选择" }
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
                    Text("自定义兼容 API").tag(TranslationEngineID.openAICompatible.rawValue)
                    Text("DeepSeek API").tag(TranslationEngineID.deepSeekAPI.rawValue)
                }
            }
            if provider != TranslationEngineID.appleSystem.rawValue {
                TextField("此服务的模型 ID", text: modelBinding)
                    .textFieldStyle(.roundedBorder)
                if !settings.aiCachedModels.isEmpty {
                    Picker("已读取的模型", selection: modelBinding) {
                        Text(settings.aiTranslationConfiguration.model.isEmpty ? "选择模型" : "保留当前输入")
                            .tag(settings.aiTranslationConfiguration.model)
                        ForEach(settings.aiCachedModels.filter { $0.id != settings.aiTranslationConfiguration.model }, id: \.id) { model in
                            Text(model.displayName).tag(model.id)
                        }
                    }
                }
                if supportsReasoningControl {
                    Menu {
                        ForEach(advertisedReasoningOptions ?? [], id: \.self) { effort in
                            Button(reasoningLabel(effort)) {
                                reasoningBinding.wrappedValue = effort
                            }
                        }
                    } label: {
                        Text("思考强度：\(reasoningSelectionLabel)")
                    }
                    .disabled((advertisedReasoningOptions ?? []).isEmpty)
                    .accessibilityIdentifier("ai.reasoningEffort")
                    Text("选项只来自当前模型明确公布的推理强度。当前没有已验证的选项时，请先刷新模型目录或检查此服务的能力说明。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if [TranslationEngineID.codexChatGPT.rawValue, TranslationEngineID.grokBuild.rawValue,
                    TranslationEngineID.geminiCLI.rawValue, TranslationEngineID.antigravityCLI.rawValue].contains(provider) {
                    ProviderConversationControls(provider: provider)
                }
                if provider == TranslationEngineID.geminiCLI.rawValue {
                    Text("Gemini CLI 暂无可读取的模型目录，请填写此连接支持的 Gemini 模型 ID。切换服务会保留各自配置。")
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
                        guard let id = AIConversationStore.shared.threadID(for: provider),
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

    private var keyStore: KeychainAITranslationAPIKeyStore { KeychainAITranslationAPIKeyStore() }

    var body: some View {
        Form {
            SettingsPageHeader(
                title: "AI 翻译",
                detail: "对当前已加载的整首歌词做上下文翻译。原文、假名、罗马音和时间轴不会被 AI 修改。"
            )

            Section("翻译默认行为") {
                TextField("目标语言", text: configurationBinding(\.targetLanguage))
                    .textFieldStyle(.roundedBorder)
                Picker("翻译风格", selection: stylePresetBinding) {
                    ForEach(TranslationPromptPresetCatalog.all, id: \.id) { preset in
                        Text(preset.displayName).tag(preset.id.rawValue)
                    }
                }
                Picker("个人翻译风格", selection: profileBinding) {
                    Text("不使用个人档案").tag("")
                    ForEach(settings.translationProfiles.list(), id: \.id) { profile in
                        Text(profile.name).tag(profile.id.uuidString)
                    }
                }
                Toggle("自动翻译新歌词", isOn: configurationBinding(\.autoTranslateNewLyrics))
                Text(settings.aiTranslationConfiguration.autoTranslateNewLyrics
                    ? "当前已开启：新歌词可能触发所选翻译服务的请求。失败不会循环重试。"
                    : "当前已关闭：需要在歌曲操作中主动翻译，已有译文仍可显示。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("当前服务与模型") {
                TranslationProviderControls(settings: settings)
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
                                settings.aiTranslationAPIKeyConfigured = true
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
                                settings.aiTranslationAPIKeyConfigured = false
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

            Section {
                DisclosureGroup("高级模型参数与提示词", isExpanded: $isAdvancedAIExpanded) {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text("随机度（Temperature）")
                            Slider(value: configurationDoubleBinding(\.temperature), in: 0...2, step: 0.1)
                            Text(String(format: "%.1f", settings.aiTranslationConfiguration.temperature))
                                .monospacedDigit()
                                .frame(width: 40, alignment: .trailing)
                        }
                        HStack {
                            Text("请求超时")
                            Slider(value: configurationDoubleBinding(\.timeout), in: 5...600, step: 5)
                            Text("\(Int(settings.aiTranslationConfiguration.timeout)) 秒")
                                .monospacedDigit()
                                .frame(width: 70, alignment: .trailing)
                        }
                        Picker("失败后的策略", selection: fallbackBinding) {
                            ForEach(TranslationFallbackStrategy.allCases, id: \.self) { strategy in
                                Text(strategy.title).tag(strategy)
                            }
                        }
                        if settings.aiTranslationConfiguration.promptPresetID == TranslationPromptPresetID.custom.rawValue {
                            TextField("自定义风格说明", text: configurationBinding(\.style))
                                .textFieldStyle(.roundedBorder)
                        }
                        Button("管理个人翻译风格", systemImage: "person.crop.circle.badge.pencil") {
                            showProfileManager = true
                        }
                        VStack(alignment: .leading, spacing: 5) {
                            Text("自定义系统提示词（可选）")
                            TextEditor(text: configurationBinding(\.customSystemPrompt))
                                .frame(minHeight: 70)
                                .font(.system(size: 12))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Button("查看当前 Prompt 内容", systemImage: "doc.text.magnifyingglass") {
                                do {
                                    let preset = TranslationPromptPresetID(rawValue: settings.aiTranslationConfiguration.promptPresetID) ?? .naturalSong
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
            hasStoredKey = settings.aiTranslationAPIKeyConfigured
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

    @State private var showClearConfirmation = false
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

            Section("数据与存储") {
                LabeledContent("数据库位置", value: data.statistics?.databaseURL.path ?? "尚未读取")
                    .textSelection(.enabled)
                LabeledContent("数据格式版本", value: data.statistics.map { "v\($0.schemaVersion)" } ?? "尚未读取")
                LabeledContent("歌曲", value: data.statistics.map { String($0.trackCount) } ?? "尚未读取")
                LabeledContent("歌词版本", value: data.statistics.map { String($0.lyricsVersionCount) } ?? "尚未读取")
                LabeledContent("歌词行", value: data.statistics.map { String($0.lyricLineCount) } ?? "尚未读取")
                LabeledContent("数据库大小", value: data.statistics.map { ByteCountFormatter.string(fromByteCount: $0.fileSize, countStyle: .file) } ?? "未知")
                HStack {
                    Button("刷新统计") { data.refreshStatistics() }
                    Button("在 Finder 中显示") { data.revealDatabase() }
                    Button("创建备份") { data.createBackup() }
                }
                .disabled(data.isBusy)

                Button("重建本地歌词索引") { data.rebuildLocalIndex() }
                Text("只扫描 ~/Music/SpotifyLyrics/Lyrics、应用支持目录和 Debug 兼容目录，不写入或修改用户文件。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("诊断") {
                LabeledContent("应用版本", value: appVersion)
                LabeledContent("支持的数据格式", value: "v\(DatabaseMigrator.currentVersion)")
                Button("打开日志目录") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/tmp"))
                }
                Button("导出脱敏诊断摘要") { data.exportDiagnostics() }
            }

            Section("重置与危险操作") {
                Button("重置窗口状态") { settings.resetWindowState() }
                Text("会删除保存的窗口位置，下次打开使用系统默认位置。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("清除所有歌词缓存", role: .destructive) { showClearConfirmation = true }
                    .disabled(data.isBusy)
                Text("只删除 SQLite 中的歌词版本和行，保留歌曲元数据；操作前应先创建备份。")
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

            if !data.statusMessage.isEmpty {
                Text(data.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { data.refreshStatistics() }
        .confirmationDialog("清除所有歌词缓存？", isPresented: $showClearConfirmation, titleVisibility: .visible) {
            Button("创建备份并清除", role: .destructive) {
                data.backupAndClearLyricsCache()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这会删除 SQLite 中的 LyricsVersion 和 LyricLine，不会修改本地 LRC 文件。")
        }
    }

    private var settingsCenterPresentationBinding: Binding<String> {
        Binding(
            get: { settings.settingsCenterPresentationRawValue },
            set: { settings.settingsCenterPresentationRawValue = $0 }
        )
    }
}
