import SwiftUI

enum AppearanceSurface: String, CaseIterable, Identifiable {
    case main, desktop, island, menuBar

    var id: Self { self }
    var title: String {
        switch self {
        case .main: "主窗口"
        case .desktop: "桌面歌词"
        case .island: "灵动岛"
        case .menuBar: "菜单栏歌词"
        }
    }

    var symbol: String {
        switch self {
        case .main: "macwindow"
        case .desktop: "text.bubble"
        case .island: "capsule.fill"
        case .menuBar: "menubar.rectangle"
        }
    }

    var detail: String {
        switch self {
        case .main: "背景、布局与窗口行为"
        case .desktop: "文字、配色与屏幕停靠"
        case .island: "顶边读句、展开与呈现方式"
        case .menuBar: "文字层、占用宽度与滚动"
        }
    }

    func matches(_ query: String) -> Bool {
        let keywords: String = switch self {
        case .main: "封面 场景 环境光 模糊 羽化 置顶 小窗口 恢复 主界面 全屏歌词 第二块屏幕 外接显示器 副屏"
        case .desktop: "悬浮歌词 悬浮窗 字号 描边 第二行 透明度 鼠标穿透 程序坞 暂停 全屏 截图 录屏"
        case .island: "顶部胶囊 刘海 摄像头 定住这句 跟回演唱 截图 录屏"
        case .menuBar: "状态栏歌词 双行 原文 翻译 译文 假名 罗马音 拼音 注音 长句 固定宽度"
        }
        let words = query.split(whereSeparator: { $0.isWhitespace })
        let text = "\(title) \(detail) \(keywords)"
        let names: [String] = switch self {
        case .main: [title]
        case .desktop: [title, "悬浮歌词", "悬浮窗"]
        case .island: [title, "顶部胶囊"]
        case .menuBar: [title, "状态栏歌词", "菜单栏", "状态栏"]
        }
        return !words.isEmpty && words.allSatisfy { word in
            if text.localizedStandardContains(String(word)) { return true }
            return names.contains { name in
                word.hasPrefix(name) && text.localizedStandardContains(String(word.dropFirst(name.count)))
            }
        }
    }
}

struct AppearanceSettingsView: View {
    let surface: AppearanceSurface
    let select: (AppearanceSurface) -> Void
    let openVersions: () -> Void
    @EnvironmentObject private var settings: AppSettingsStore
    @EnvironmentObject private var playback: PlaybackState

    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("外观").font(.system(size: 26, weight: .semibold, design: .serif))
                        Spacer()
                        Button(action: openVersions) { Label("体验版本库", systemImage: "square.stack") }
                            .buttonStyle(.borderless).foregroundStyle(WorkspacePalette.ink)
                    }
                    if geometry.size.height >= 430 && geometry.size.width >= 385 {
                        AppearanceSurfaceMap(selected: surface, select: select, settings: settings,
                                             desktopShown: playback.showFloatingWindow, islandShown: playback.showCapsulePlayer)
                    } else {
                        Picker("歌词位置", selection: Binding(get: { surface }, set: select)) {
                            ForEach(AppearanceSurface.allCases) { Text($0.title).tag($0) }
                        }.pickerStyle(.segmented).labelsHidden()
                    }
                }
                .padding(.horizontal, 22).padding(.top, 14).padding(.bottom, 12)
                Divider()
                Form {
                    switch surface {
                    case .main: mainControls
                    case .desktop: desktopControls
                    case .island: IslandAppearanceControls(selections: settings.presentationSelections)
                    case .menuBar: menuBarControls
                    }
                }
                .formStyle(.grouped).scrollContentBackground(.hidden)
                .id(surface)
            }
            .background(WorkspacePalette.paper)
        }
    }

    @ViewBuilder private var mainControls: some View {
        Section("主窗口") {
            AppearanceLayoutPicker(settings: settings)
            if settings.mainWindowLayoutStyle == .appleMusicImmersiveV3 {
                ToolbarPanelLink(title: "调整封面、背景与布局", panel: .picture)
            }
            ToolbarPanelLink(title: "调整歌词字体与排版", panel: .text)
            Toggle("小窗口自动进入歌词专注", isOn: $settings.automaticCompactLyricsFocus)
                .help("窗口缩小时让出封面的位置，放大后恢复原布局。")
            Toggle("主窗口保持置顶", isOn: $settings.keepMainWindowOnTop)
            Toggle("启动时恢复上次窗口状态", isOn: $settings.restoreWindowState)
        }
        Section {
            DisclosureGroup("经典伴随布局") {
                Picker("呈现方式", selection: $settings.classicCompanionPresentationRawValue) {
                    ForEach(ClassicCompanionPresentation.allCases) { Text($0.title).tag($0.rawValue) }
                }
            }
            Toggle("全屏歌词开在另一块屏幕", isOn: $settings.fullScreenPrefersOtherScreen)
                .help("接入第二块屏幕时，主窗口留在原处。")
        }
    }

    @ViewBuilder private var desktopControls: some View {
        Section("桌面歌词") {
            Toggle("显示桌面歌词", isOn: Binding(get: { playback.showFloatingWindow }, set: { shown in
                if shown { WindowManager.shared.showFloatingLyrics(state: playback) }
                else { WindowManager.shared.hideFloatingLyrics() }
            })).disabled(playback.showFullScreen)
            Picker("呈现方式", selection: $settings.floatingLyricsPresentation) {
                ForEach(FloatingLyricsPresentationVersion.allCases, id: \.rawValue) { Text($0.title).tag($0) }
            }
            Picker("交互方式", selection: $settings.floatingWindowInteractionMode) {
                ForEach(FloatingLyricsInteractionMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            HStack {
                Text("停靠位置")
                Spacer()
                Button("屏幕顶部") { WindowManager.shared.dockFloatingLyrics(.top, state: playback) }
                Button("程序坞上方") { WindowManager.shared.dockFloatingLyrics(.bottom, state: playback) }
            }
            .disabled(playback.showFullScreen)
            .help("在当前歌词屏幕上显示并移动桌面歌词。")
        }
        Section("文字与底色") {
            Picker("行数", selection: $settings.floatingDesktopLineMode) {
                ForEach(FloatingDesktopLineMode.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
            }
            FloatingDesktopCompanionPicker(settings: settings)
            LabeledContent("字号") {
                V3NumericSlider(value: $settings.floatingDesktopFontSize, in: 22...64, step: 1, unit: "pt")
                    .accessibilityLabel("桌面歌词字号")
            }
            Picker("底色", selection: $settings.floatingLyricsSurfaceStyleRawValue) {
                ForEach(FloatingLyricsSurfaceStyle.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
            }
            LabeledContent(settings.floatingLyricsPresentation == .transparentV2 && settings.floatingDesktopKeepsTextOpaque ? "背景不透明度" : "整个窗口不透明度") {
                V3NumericSlider(value: $settings.floatingWindowOpacity, in: 0.45...1, step: 0.01, unit: "%", displayScale: 100)
                    .accessibilityLabel("桌面歌词透明度")
            }
            DisclosureGroup("配色与描边") { FloatingDesktopColorControls(settings: settings) }
        }
        Section("显示时机") {
            Toggle("桌面歌词保持置顶", isOn: $settings.floatingWindowAlwaysOnTop)
            Toggle("暂停时隐藏", isOn: $settings.floatingHidesWhenPaused).help("暂停三秒后淡出，继续播放时回来。")
            Toggle("其他应用全屏时隐藏", isOn: $settings.floatingHidesOverFullScreen)
            CaptureVisibilityToggle(settings: settings)
        }
    }

    private var menuBarControls: some View {
        Section("菜单栏歌词") {
            Toggle("在系统菜单栏显示歌词", isOn: $settings.menuBarLyricsEnabled)
            MenuBarAppearancePreview(settings: settings, controller: .shared)
            MenuBarLyricsAppearanceControls(settings: settings)
        }
    }
}

struct AppearanceLayoutPicker: View {
    @ObservedObject var settings: AppSettingsStore

    var body: some View {
        Picker("主窗口布局", selection: Binding(get: { settings.mainWindowLayoutStyle }, set: { style in
            _ = settings.applyPresentationSelection(category: .mainWindow, stableID: style.presentationStableID)
        })) {
            ForEach(MainWindowLayoutStyle.userSelectableCases) { Text($0.title).tag($0) }
        }
    }
}

private struct CaptureVisibilityToggle: View {
    @ObservedObject var settings: AppSettingsStore
    var body: some View {
        Toggle("截图和录屏时隐藏", isOn: $settings.floatingHiddenFromCapture)
            .help("桌面歌词和灵动岛共用此选项。")
    }
}

private struct AppearanceSurfaceMap: View {
    let selected: AppearanceSurface
    let select: (AppearanceSurface) -> Void
    @ObservedObject var settings: AppSettingsStore
    let desktopShown: Bool
    let islandShown: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "display").font(.caption).foregroundStyle(.white.opacity(0.65)).accessibilityHidden(true)
                Spacer()
                choice(.island, dark: true, enabled: islandShown)
                Spacer()
                choice(.menuBar, enabled: settings.menuBarLyricsEnabled)
            }
            .padding(.horizontal, 12).frame(height: 34)
            .background(.black.opacity(0.18))
            HStack(alignment: .bottom, spacing: 14) {
                choice(.main) {
                    HStack(spacing: 5) {
                        Image(systemName: "opticaldisc").font(.system(size: 23, weight: .thin))
                        Text(settings.mainWindowLayoutStyle.title).font(.caption2)
                    }
                }
                Spacer()
                choice(.desktop, enabled: desktopShown)
            }
            .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 12)
        }
        .foregroundStyle(.white)
        .background(LinearGradient(colors: [WorkspacePalette.sleeve, Color(red: 0.22, green: 0.38, blue: 0.38)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain).accessibilityLabel("选择歌词显示位置")
    }

    private func choice(_ surface: AppearanceSurface, dark: Bool = false, enabled: Bool) -> some View {
        choice(surface, dark: dark, enabled: enabled) { EmptyView() }
    }

    private func choice<Content: View>(_ surface: AppearanceSurface, dark: Bool = false, enabled: Bool? = nil,
                                       @ViewBuilder content: () -> Content) -> some View {
        let active = selected == surface
        return Button { select(surface) } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 4) {
                    Label(surface.title, systemImage: surface.symbol)
                        .font(.system(size: 12, weight: active ? .bold : .medium))
                    if let enabled { Text(enabled ? "开" : "关").font(.caption2).opacity(0.78) }
                }
                content()
            }
            .padding(.horizontal, surface == .main ? 14 : 9)
            .padding(.vertical, surface == .main ? 6 : 3)
            .background(dark ? Color.black : .white.opacity(active ? 0.18 : 0.07),
                        in: RoundedRectangle(cornerRadius: dark ? 12 : 6))
            .overlay {
                RoundedRectangle(cornerRadius: dark ? 12 : 6)
                    .strokeBorder(.white.opacity(active ? 0.93 : 0.20), lineWidth: active ? 1.5 : 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(surface.detail).accessibilityLabel(surface.title)
        .accessibilityValue(enabled.map { $0 ? "已显示" : "已关闭" } ?? settings.mainWindowLayoutStyle.title)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

private struct IslandAppearanceControls: View {
    @ObservedObject var selections: PresentationSelectionStore
    @EnvironmentObject private var settings: AppSettingsStore
    @EnvironmentObject private var playback: PlaybackState
    @State private var pose = PresentationPreviewCapsuleState.collapsed

    private var current: String { selections.currentStableID(for: .capsule) }
    var body: some View {
        Section("灵动岛") {
            Toggle("在屏幕顶边显示", isOn: Binding(get: { playback.showCapsulePlayer }, set: { shown in
                if shown { WindowManager.shared.showCapsule(state: playback) }
                else { WindowManager.shared.hideCapsule() }
            })).disabled(playback.showFullScreen)
            Picker("呈现方式", selection: Binding(get: { current }, set: { value in
                _ = settings.applyPresentationSelection(category: .capsule, stableID: value)
            })) {
                ForEach(selections.catalog.entries(for: .capsule).filter {
                    settings.canApplyPresentation(category: .capsule, stableID: $0.stableID)
                }) { entry in Text(entry.displayName).tag(entry.stableID) }
            }
            CaptureVisibilityToggle(settings: settings)
        }
        if let entry = selections.catalog.metadata(for: current) {
            Section("试读") {
                Picker("岛的状态", selection: $pose) {
                    Text("收起").tag(PresentationPreviewCapsuleState.collapsed)
                    Text("展开").tag(PresentationPreviewCapsuleState.expanded)
                }.pickerStyle(.segmented)
                GeometryReader { geometry in
                    let width = max(1, geometry.size.width)
                    let scale = min(1, width / 640)
                    PresentationPreviewAdapterView(entry: entry, context: .mock(surface: .capsule,
                        windowSize: .init(width: 640, height: 168), capsuleState: pose))
                        .frame(width: 640, height: 168).scaleEffect(scale)
                        .frame(width: width, height: 150).clipped().allowsHitTesting(false)
                }.frame(height: 150).accessibilityLabel("所选灵动岛的示例歌词")
            }
        }
    }
}
