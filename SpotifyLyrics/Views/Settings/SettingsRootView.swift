import SwiftUI
import AppKit

private enum SettingsCategory: String, CaseIterable, Identifiable {
    // 5 个正式偏好一级入口 (Primary Sidebar Cases)
    case general = "通用"
    case lyricsAndText = "歌词与文字"
    case servicesAndSources = "服务与来源"
    case aiTranslation = "AI 翻译"
    case advancedAndData = "高级与数据"

    // 过渡桥接隐藏目标 (Hidden Bridge Destinations, 不在侧边栏显示)
    case library = "我的歌词库"
    case history = "最近播放"
    case statistics = "听歌统计"
    case experienceLibrary = "体验版本库"

    static var primaryCases: [SettingsCategory] {
        [.general, .lyricsAndText, .servicesAndSources, .aiTranslation, .advancedAndData]
    }

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .lyricsAndText: return "text.quote"
        case .servicesAndSources: return "waveform.circle"
        case .aiTranslation: return "sparkles"
        case .advancedAndData: return "wrench.and.screwdriver"
        case .library: return "music.note.list"
        case .history: return "clock.arrow.circlepath"
        case .statistics: return "chart.bar"
        case .experienceLibrary: return "rectangle.on.rectangle"
        }
    }
}

struct SettingsRootView: View {
    @EnvironmentObject private var settings: AppSettingsStore
    @State private var selection: SettingsCategory = .general

    var body: some View {
        Group {
            switch settings.settingsCenterPresentation {
            case .classicNavigationV1:
                settingsShell(includeExperienceLibrary: false, title: "经典设置")
            case .experienceIntegratedV2:
                settingsShell(includeExperienceLibrary: true, title: "设置")
            }
        }
        .frame(minWidth: 780, idealWidth: 860, minHeight: 500, idealHeight: 580)
        .background(SettingsWindowBehavior())
    }

    @ViewBuilder
    private func settingsShell(includeExperienceLibrary: Bool, title: String) -> some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(SettingsCategory.primaryCases) { category in
                    Label(category.rawValue, systemImage: category.systemImage)
                        .tag(category)
                }
                if !includeExperienceLibrary {
                    Section {
                        Button {
                            settings.settingsCenterPresentation = .experienceIntegratedV2
                        } label: {
                            Label("恢复推荐设置中心", systemImage: "arrow.uturn.backward.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("返回带体验版本库的推荐设置中心")
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationTitle(title)
            .accessibilityIdentifier(settings.settingsCenterPresentation.rawValue)
            .frame(minWidth: 180)
        } detail: {
            SettingsDetailView(selection: $selection)
                .environmentObject(settings)
        }
        .onAppear {
            if !includeExperienceLibrary, selection == .experienceLibrary {
                selection = .general
            }
        }
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
                GeneralSettingsView()
                    .padding(28)
            case .lyricsAndText:
                LyricsAndTextSettingsView()
                    .padding(28)
            case .servicesAndSources:
                ServicesAndSourcesSettingsView()
                    .padding(28)
            case .aiTranslation:
                AISettingsView()
                    .padding(28)
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
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 25, weight: .semibold, design: .rounded))
            Text(detail)
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 10)
    }
}

private struct GeneralSettingsView: View {
    @EnvironmentObject private var settings: AppSettingsStore

    var body: some View {
        Form {
            SettingsPageHeader(title: "通用", detail: "控制启动、切歌和主窗口的默认行为。")

            Section("主窗口") {
                Picker("默认主窗口布局", selection: mainWindowLayoutSelection) {
                    ForEach(MainWindowLayoutStyle.userSelectableCases) { layout in
                        Text(layout.title).tag(layout.rawValue)
                    }
                }
                Picker("经典伴随呈现", selection: $settings.classicCompanionPresentationRawValue) {
                    ForEach(ClassicCompanionPresentation.allCases) { presentation in
                        Text(presentation.title).tag(presentation.rawValue)
                    }
                }
                Text("经典伴随 V1 可按窗口宽度自适应，也可固定为沉浸分栏或歌词专注。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("小窗口自动进入歌词专注", isOn: $settings.automaticCompactLyricsFocus)
                Text("仅在 V3 主窗口达到保守的小窗口阈值时临时隐藏封面与次要信息；恢复窗口尺寸后自动返回原布局。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("启动时恢复上次窗口状态", isOn: $settings.restoreWindowState)
                Toggle("主窗口保持置顶", isOn: $settings.keepMainWindowOnTop)
                LyricsPresentationOffsetControl(settings: settings)
            }

            Section("悬浮歌词") {
                Picker("默认呈现", selection: $settings.floatingLyricsPresentationRawValue) {
                    ForEach(FloatingLyricsPresentationVersion.allCases, id: \.rawValue) { version in
                        Text(version.title).tag(version.rawValue)
                    }
                }
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

            Section("启动与切歌") {
                Toggle("启动时自动连接 Spotify Desktop", isOn: $settings.connectSpotifyOnLaunch)
                Toggle("切歌后自动搜索歌词", isOn: $settings.autoSearchLyricsOnTrackChange)
            }

            Section("自动排轴") {
                Toggle("自动为未排轴歌词生成时间轴", isOn: $settings.automaticAlignmentEnabled)
                Text("自动实时捕获仅支持 Spotify Desktop 播放源；Apple Music、未知来源不会启动。捕获音频会临时写入本机 WAV 分段，任务结束后清理。默认关闭。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
                title: "服务与来源",
                detail: "管理音乐播放源（Spotify / Apple Music）、在线曲库授权与多源歌词检索。"
            )

            Section("播放源 (Playback Source)") {
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

            Section("Spotify Desktop") {
                LabeledContent("连接状态", value: playbackState.providerStatus.userFacingMessage)
                Text("桌面播放控制不依赖 Spotify Web OAuth。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Spotify Web 在线曲库") {
                LabeledContent("授权状态", value: authorization.state.userFacingMessage)
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

                HStack {
                    Text("稳定 ID")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(settings.lyricsSourceMode.rawValue)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }

                Button("恢复默认模式（扩展免费）") {
                    settings.restoreDefaultLyricsSourceMode()
                }
                .accessibilityIdentifier("lyricsSourceMode.restoreDefault")
            }

            Section("Provider 顺序") {
                ForEach(Array(settings.lyricsProviderConfiguration.order.enumerated()), id: \.element) { index, id in
                    providerRow(id: id, index: index)
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

            Section("服务配置") {
                Picker("翻译引擎", selection: configurationBinding(\.engineID)) {
                    ForEach(TranslationEngineCatalog.all, id: \.stableID) { engine in
                        Text(engine.displayName).tag(engine.stableID)
                    }
                }
                let selectedEngine = TranslationEngineRegistry.make(stableID: settings.aiTranslationConfiguration.engineID).metadata
                Text(engineAvailabilityText(selectedEngine))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if selectedEngine.stableID == TranslationEngineID.codexChatGPT.rawValue {
                    Label("由本机 Codex app-server 管理 ChatGPT 登录；不会读取或保存 auth.json / OAuth 原始凭据。首次使用会打开浏览器登录。", systemImage: "lock.shield")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                TextField("兼容接口地址（Base URL）", text: configurationBinding(\.baseURL))
                    .textFieldStyle(.roundedBorder)
                    .disabled(selectedEngine.stableID == TranslationEngineID.codexChatGPT.rawValue)
                TextField("模型（Model）", text: configurationBinding(\.model))
                    .textFieldStyle(.roundedBorder)
                    .disabled(selectedEngine.stableID == TranslationEngineID.codexChatGPT.rawValue)
                HStack {
                    Text("模型目录")
                    Spacer()
                    Text(settings.aiModelDirectoryDisplayStatus.userFacingTitle)
                        .foregroundStyle(.secondary)
                    Button("刷新") { settings.refreshAIModelDirectory() }
                }
                if !settings.aiTranslationConfiguration.model.isEmpty,
                   !settings.aiCachedModels.contains(where: { $0.id == settings.aiTranslationConfiguration.model }) {
                    Text("当前模型未出现在最近目录中，仍保留手动输入的模型 ID。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !settings.aiCachedModels.isEmpty {
                    Picker("手动选择模型", selection: configurationBinding(\.model)) {
                        Text("保留当前输入").tag(settings.aiTranslationConfiguration.model)
                        ForEach(settings.aiCachedModels, id: \.id) { model in
                            Text(model.displayName).tag(model.id)
                        }
                    }
                }
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
                    Button("测试连接") {
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

            Section("翻译默认行为") {
                TextField("目标语言", text: configurationBinding(\.targetLanguage))
                    .textFieldStyle(.roundedBorder)
                Picker("默认提示词预设", selection: configurationBinding(\.promptPresetID)) {
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
                Text("默认关闭。失败不会循环重试，也不会创建半成品数据库版本。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                        TextField("翻译风格（兼容旧设置）", text: configurationBinding(\.style))
                            .textFieldStyle(.roundedBorder)
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
                return "可用：翻译请求通过本机 Codex app-server，登录和令牌由 Codex 管理。"
            }
            return "可用：请确认 Base URL、模型和 API Key。"
        case .requiresConfiguration:
            return "需要配置：Base URL、模型和 API Key。"
        case .requiresSystemSupport:
            return "需要系统支持：当前系统或语言组合可能不可用。"
        case .unavailable:
            return "当前引擎不可用。"
        }
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
                LabeledContent("路径", value: data.statistics?.databaseURL.path ?? SQLiteLyricsRepository.defaultDatabaseURL.path)
                    .textSelection(.enabled)
                LabeledContent("Migration", value: "v\(data.statistics?.schemaVersion ?? DatabaseMigrator.currentVersion)")
                LabeledContent("Track 数量", value: "\(data.statistics?.trackCount ?? 0)")
                LabeledContent("LyricsVersion 数量", value: "\(data.statistics?.lyricsVersionCount ?? 0)")
                LabeledContent("LyricLine 数量", value: "\(data.statistics?.lyricLineCount ?? 0)")
                LabeledContent("数据库大小", value: data.statistics.map { ByteCountFormatter.string(fromByteCount: $0.fileSize, countStyle: .file) } ?? "未知")
                HStack {
                    Button("刷新统计") { data.refreshStatistics() }
                    Button("在 Finder 中显示") { data.revealDatabase() }
                    Button("创建备份") { data.createBackup() }
                }

                Button("重建本地歌词索引") { data.rebuildLocalIndex() }
                Text("只扫描 ~/Music/SpotifyLyrics/Lyrics、应用支持目录和 Debug 兼容目录，不写入或修改用户文件。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("诊断") {
                LabeledContent("App Build", value: appVersion)
                LabeledContent("数据库 Schema", value: "v\(DatabaseMigrator.currentVersion)")
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
