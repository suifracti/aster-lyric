import Foundation
import SwiftUI
import AppKit
import Combine
import os

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
struct V3ThemeSelectorView: View {
    @ObservedObject var settings: AppSettingsStore
    let artworkURL: URL?
    @Binding var preview: V3ArtworkPresentation?
    @Binding var previewScene: V3ListeningScene?
    var onConfirm: () -> Void
    var compact = false
    @State private var thumbnail: NSImage?
    @State private var tint = Color.accentColor
    @State private var previewTask: Task<Void, Never>?
    /// Hovering another family shows its styles without adopting anything.
    @State private var browsedFamily: V3SceneFamily?

    private func clearPreview() {
        previewTask?.cancel(); previewTask = nil
        preview = nil; previewScene = nil
    }
    private func hovering(_ inside: Bool, scene: V3ListeningScene?, renderer: V3ArtworkPresentation) {
        clearPreview()
        guard inside, settings.v3SceneHoverPreviewEnabled else { return }
        previewTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, settings.v3SceneHoverPreviewEnabled else { return }
            previewScene = scene
            preview = renderer
        }
    }
    private func adopt(_ scene: V3ListeningScene?, renderer: V3ArtworkPresentation) {
        clearPreview()
        if let scene { settings.selectV3Scene(scene, renderer: renderer) }
        else { settings.selectLegacyV3Presentation(renderer) }
    }

    /// The family that owns the current selection, new scene or classic preset.
    private var currentFamily: V3SceneFamily {
        if let scene = settings.v3ListeningScene { return V3SceneFamily.family(of: scene) }
        return V3SceneFamily.family(ofClassic: settings.v3ArtworkPresentation)
    }

    private var shownFamily: V3SceneFamily { browsedFamily ?? currentFamily }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("场景").font(.system(size: 13, weight: .semibold))
                Spacer()
                Toggle("悬停预览", isOn: $settings.v3SceneHoverPreviewEnabled)
                    .toggleStyle(.switch).controlSize(.mini)
                    .font(.system(size: 11))
                    .help("停留后临时预览，移开恢复，点击才采用；预览不会保存设置或调用 AI")
            }
            // Four families as large cards; the chosen family's styles sit
            // underneath. Entries only — every style is an existing
            // scene + renderer pair and keeps its saved values.
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(V3SceneFamily.allCases) { family in
                    familyCard(family)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(shownFamily.title + " · 风格").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    if !compact { Text(shownFamily.detail).font(.system(size: 11)).foregroundStyle(Color.secondary)
                        .lineLimit(1) }
                }
                .padding(.bottom, 4)
                ForEach(shownFamily.styles, id: \.self) { style in
                    styleRow(scene: style.scene, renderer: style.renderer,
                             title: style.scene.rendererTitle(style.renderer),
                             detail: style.renderer == style.scene.defaultRenderer && style.scene.renderers.count == 1
                                ? style.scene.detail : nil)
                }
                Text("经典版").font(.system(size: 11, weight: .medium)).foregroundStyle(Color.secondary)
                    .padding(.top, 8).padding(.bottom, 2)
                ForEach(shownFamily.classics) { renderer in
                    styleRow(scene: nil, renderer: renderer, title: "经典 · " + renderer.title, detail: nil)
                }
            }
            .padding(10)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
            if !compact, settings.v3ListeningScene != nil {
                Button("恢复此风格的默认值", role: .destructive) {
                    clearPreview(); settings.resetCurrentV3Scene()
                }.font(.system(size: 12)).buttonStyle(.borderless)
                .help("只重置当前场景风格的画面数值；经典版与其他风格不受影响")
            }
        }
        .task(id: artworkURL) {
            let image = await ArtworkImageLoader.shared.image(for: artworkURL)
            let colors = await LyricIslandArtworkColors.palette(for: artworkURL)
            guard !Task.isCancelled else { return }
            thumbnail = image
            tint = LyricIslandArtworkColors.listeningAccent(colors) ?? .accentColor
        }
        .onChange(of: settings.v3SceneHoverPreviewEnabled) { _, _ in clearPreview() }
        .onChange(of: settings.v3ListeningSceneRawValue) { _, _ in browsedFamily = nil }
        .onHover { inside in if !inside { browsedFamily = nil } }
        .onDisappear { clearPreview() }
    }

    private func familyCard(_ family: V3SceneFamily) -> some View {
        let selected = family == currentFamily
        let target = family.target(settings: settings)
        let previewing = preview != nil && family.contains(scene: previewScene, renderer: preview!) && !selected
        return Button {
            browsedFamily = nil
            adopt(target.0, renderer: target.1)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                LyricIslandSceneThumbnail(scene: family.primaryScene, image: thumbnail, accent: tint)
                HStack(spacing: 4) {
                    Image(systemName: family.symbolName).font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(selected ? tint : Color.secondary)
                    Text(family.title).font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 0)
                    if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(tint) }
                    else if previewing { Text("预览").font(.system(size: 11)).foregroundStyle(tint) }
                }
            }
            .padding(6)
            .background(selected ? tint.opacity(0.14) : Color.primary.opacity(0.035),
                        in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(selected ? tint.opacity(0.75) : previewing ? tint.opacity(0.45) : .clear,
                              style: StrokeStyle(lineWidth: 1, dash: previewing ? [3, 3] : [])))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside && !compact && family != currentFamily { browsedFamily = family }
            hovering(inside, scene: target.0, renderer: target.1)
        }
        .help(family.detail)
        .accessibilityLabel(family.title)
        .accessibilityIdentifier("v3.family." + family.rawValue)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Selection always matches scene + renderer: the same renderer draws
    /// differently inside a scene and as a classic preset.
    private func styleRow(scene: V3ListeningScene?, renderer: V3ArtworkPresentation,
                          title: String, detail: String?) -> some View {
        let selected = settings.v3ListeningScene == scene && settings.v3ArtworkPresentation == renderer
        let previewing = !selected && preview == renderer && previewScene == scene
        return Button { adopt(scene, renderer: renderer) } label: {
            HStack(spacing: 8) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? tint : Color.secondary.opacity(0.6))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                    if !compact, let detail {
                        Text(detail).font(.system(size: 11)).foregroundStyle(Color.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if previewing { Text("预览").font(.system(size: 11)).foregroundStyle(tint) }
            }
            .padding(.horizontal, 6).padding(.vertical, 5)
            .background(selected ? tint.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(previewing ? tint.opacity(0.45) : .clear, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovering($0, scene: scene, renderer: renderer) }
        .accessibilityIdentifier(scene == nil ? "v3.style." + renderer.rawValue
                                 : "v3.scene." + scene!.rawValue + "." + renderer.rawValue)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Entry grouping only. Families map onto existing scene + renderer pairs and
/// the eight classic presets; nothing here is persisted.
enum V3SceneFamily: String, CaseIterable, Identifiable {
    case ambient, cover, linerNotes, focus
    var id: String { rawValue }

    struct Style: Hashable {
        let scene: V3ListeningScene
        let renderer: V3ArtworkPresentation
    }

    var title: String {
        switch self {
        case .ambient: return "环境光"
        case .cover: return "封面"
        case .linerNotes: return "内页"
        case .focus: return "专注"
        }
    }

    var detail: String {
        switch self {
        case .ambient: return "封面化作光色，环绕歌词"
        case .cover: return "画面成为舞台"
        case .linerNotes: return "题头、版心与段落"
        case .focus: return "安静底色，连续阅读"
        }
    }

    var symbolName: String {
        switch self {
        case .ambient: return "sun.max"
        case .cover: return "photo.fill"
        case .linerNotes: return "book.pages"
        case .focus: return "text.alignleft"
        }
    }

    var scenes: [V3ListeningScene] {
        switch self {
        case .ambient: return [.originalAmbient, .flowingField]
        case .cover: return [.coverPhoto]
        case .linerNotes: return [.linerNotes]
        case .focus: return [.focusedLyrics]
        }
    }

    var primaryScene: V3ListeningScene { scenes[0] }

    var styles: [Style] {
        scenes.flatMap { scene in scene.renderers.map { Style(scene: scene, renderer: $0) } }
    }

    /// Classic presets keep their own rawIDs and values.
    var classics: [V3ArtworkPresentation] {
        switch self {
        case .ambient: return [.authenticAmbient, .classic, .ambientFeathered]
        case .cover: return [.ambient, .classicGaussian, .stage]
        case .linerNotes: return [.albumPoster]
        case .focus: return [.lyricsOnly]
        }
    }

    func contains(scene: V3ListeningScene?, renderer: V3ArtworkPresentation) -> Bool {
        if let scene { return scenes.contains(scene) }
        return classics.contains(renderer)
    }

    /// Shared by the full selector and its four hover shortcuts.
    @MainActor
    func target(settings: AppSettingsStore) -> (V3ListeningScene?, V3ArtworkPresentation) {
        if contains(scene: settings.v3ListeningScene, renderer: settings.v3ArtworkPresentation) {
            return (settings.v3ListeningScene, settings.v3ArtworkPresentation)
        }
        return (primaryScene, settings.v3Renderer(for: primaryScene))
    }

    static func family(of scene: V3ListeningScene) -> V3SceneFamily {
        allCases.first { $0.scenes.contains(scene) } ?? .ambient
    }

    static func family(ofClassic renderer: V3ArtworkPresentation) -> V3SceneFamily {
        allCases.first { $0.classics.contains(renderer) } ?? .ambient
    }
}

/// Shared settings controls used by the toolbar panel and the settings window.
struct V3VisualControls {
    @ObservedObject var settings: AppSettingsStore

    private var blurPresetName: String {
        let r = settings.v3BackdropBlurRadius
        if r <= 5 { return "清晰" }
        if r <= 35 { return "轻柔" }
        if r <= 75 { return "柔和" }
        return "弥散"
    }

    private var sizePresetName: String {
        let value = settings.v3ArtworkSizeScale
        if abs(value - 0.8) < 0.001 { return "精巧" }
        if abs(value - 1.0) < 0.001 { return "标准" }
        if abs(value - 1.2) < 0.001 { return "大图" }
        if abs(value - 1.4) < 0.001 { return "巨幕" }
        return "自定"
    }

    private var backdropScalePresetName: String {
        let value = settings.v3BackdropScale(for: settings.v3ArtworkPresentation)
        if abs(value - 0.8) < 0.001 { return "精巧" }
        if abs(value - 1.0) < 0.001 { return "标准" }
        if abs(value - 1.2) < 0.001 { return "大图" }
        if abs(value - 1.4) < 0.001 { return "巨幕" }
        return "自定"
    }

    var blurControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("背景封面模糊")
                .font(.system(size: 12, weight: .medium))
            V3NumericSlider(value: $settings.v3BackdropBlurRadius, in: 0...100, step: 1, unit: "%")
                .accessibilityLabel(settings.v3ArtworkPresentation.blurControlTitle)
            HStack {
                blurPresetButton("0%", val: 0); Spacer()
                blurPresetButton("25%", val: 25); Spacer()
                blurPresetButton("60%", val: 60); Spacer()
                blurPresetButton("100%", val: 100)
            }
        }
    }

    private var backdropScaleControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("背景缩放").font(.system(size: 12, weight: .medium))
            V3NumericSlider(value: Binding(
                get: { settings.v3BackdropScale(for: settings.v3ArtworkPresentation) },
                set: { settings.setV3BackdropScale($0, for: settings.v3ArtworkPresentation) }
            ), in: 0.8...1.4, step: 0.05, unit: "%", displayScale: 100)
                .accessibilityLabel("背景缩放")
                .accessibilityIdentifier("v3.classic.backgroundScale")
            HStack {
                backdropScalePresetButton("80%", val: 0.8); Spacer()
                backdropScalePresetButton("100%", val: 1); Spacer()
                backdropScalePresetButton("120%", val: 1.2); Spacer()
                backdropScalePresetButton("140%", val: 1.4)
            }
        }
    }

    var pictureAdvancedControls: some View {
        pictureAdvancedControls(showsExplanations: true)
    }

    var playbackPresentationControls: some View {
        Picker("播放呈现", selection: $settings.v3EdgeProgressEnabled) {
            Text("标准播放栏").tag(false)
            Text("窗口边缘").tag(true)
        }.pickerStyle(.segmented)
    }

    @ViewBuilder var backgroundMotionControls: some View {
        if settings.v3ArtworkPresentation != .classicGaussian {
            HStack {
                Text("背景动态")
                Spacer()
                atmosphereButton("关闭", level: 0)
                atmosphereButton("轻柔", level: 1)
                atmosphereButton("鲜明", level: 2)
            }
            .help("暂停、窗口隐藏或系统减少动态效果时停止装饰运动。")
        } else {
            Label("纯高斯保持静态", systemImage: "circle.lefthalf.filled")
                .font(.system(size: 12)).foregroundStyle(Color.secondary)
        }
    }

    func pictureAdvancedControls(showsExplanations: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("夜间柔和", isOn: $settings.v3NightGentleEnabled)
                .help("20:00–07:00 降低亮度15%，背景动态最高为轻柔。")
            let renderer = settings.v3ArtworkPresentation
            let scene = settings.v3ListeningScene
            if scene != .focusedLyrics && scene != .linerNotes {
                sectionLabel("背景")
                if !(scene == .flowingField && renderer == .classic) {
                    Picker("取景方式", selection: Binding(
                        get: { settings.v3BackgroundShowsCompleteArtwork(for: renderer) },
                        set: { settings.setV3BackgroundShowsCompleteArtwork($0, for: renderer) }
                    )) {
                        Text("铺满").tag(false)
                        Text("尽量完整").tag(true)
                    }.pickerStyle(.segmented)
                    .help("背景取景不改变前景封面；可铺满裁切或保留完整内容。")
                    if showsExplanations {
                        Text(settings.v3BackgroundShowsCompleteArtwork(for: renderer)
                             ? "优先保留封面内容并补边；前景封面单独调整。"
                             : "允许裁切以铺满背景；前景封面单独调整。")
                            .font(.system(size: 11)).foregroundStyle(Color.secondary)
                    }
                    backdropScaleControls
                }
                if showsExplanations {
                    backgroundMotionControls
                    if renderer != .classicGaussian {
                        Text("暂停、窗口隐藏或系统减少动态效果时停止装饰运动。")
                            .font(.system(size: 11)).foregroundStyle(Color.secondary)
                    }
                }
                Divider()
            }
            if scene != .focusedLyrics && scene != .coverPhoto && settings.v3ShowForegroundArtwork {
                sectionLabel("前景封面")
                V3NumericSlider(value: $settings.v3ArtworkSizeScale, in: 0.8...1.4, step: 0.05,
                                unit: "%", displayScale: 100)
                    .accessibilityLabel("前景封面尺寸")
                HStack {
                    sizePresetButton("80%", val: 0.8); Spacer()
                    sizePresetButton("100%", val: 1); Spacer()
                    sizePresetButton("120%", val: 1.2); Spacer()
                    sizePresetButton("140%", val: 1.4)
                }
                if scene != .linerNotes {
                    Picker("位置", selection: $settings.v3ArtworkPosition) {
                        Text("居左").tag("left")
                        Text("居中").tag("center")
                        Text("居右").tag("right")
                    }.pickerStyle(.segmented)
                }
                if scene == nil && renderer != .albumPoster && renderer != .stage && renderer != .lyricsOnly {
                    Toggle("隐藏播放信息时舒展封面", isOn: $settings.v3ExpandArtworkWhenDetailsHidden)
                        .accessibilityIdentifier("v3.artwork.expandWhenDetailsHidden")
                }
                Divider()
            }
            sectionLabel("播放")
            if settings.v3EdgeProgressEnabled {
                V3WindowEdgeProgressSettings(enabled: $settings.v3EdgeProgressEnabled,
                    colorHex: $settings.v3EdgeProgressColorHex,
                    colorMode: $settings.v3EdgeProgressColorMode, showsModeToggle: false,
                    showsExplanation: showsExplanations)
            } else {
                Toggle("悬停时显示播放信息", isOn: $settings.v3PlaybackDetailsOnHover)
                    .help("移入封面或播放区域显示；关闭后播放栏保持可见。")
                if showsExplanations {
                    Text("移入封面或播放区域显示；关闭后播放栏保持可见。")
                        .font(.system(size: 11)).foregroundStyle(Color.secondary)
                }
            }
            Toggle("确认纯音乐时使用简洁画面", isOn: $settings.v3InstrumentalPureImmersion)
                .help("仅对已确认纯音乐生效；找不到歌词不代表纯音乐。")
            DisclosureGroup("旧版布局兼容") {
                Picker("主窗口布局", selection: $settings.mainWindowLayoutStyleRawValue) {
                    ForEach(MainWindowLayoutStyle.userSelectableCases) { style in Text(style.title).tag(style.rawValue) }
                }.pickerStyle(.menu)
            }.font(.system(size: 12))
        }.font(.system(size: 12))
    }

    var textPage: some View {
        VStack(alignment: .leading, spacing: 13) {
            Toggle("大字模式", isOn: $settings.v3BigLineModeEnabled)
            HStack {
                Text("显示")
                Picker("显示方式", selection: displayBinding(\.listeningLayerPreset)) {
                    ForEach(DisplayPreferences.ListeningLayerPreset.allCases.filter {
                        $0 != .custom || settings.displayPreferences.listeningLayerPreset == .custom
                    }) { preset in Text(preset.title).tag(preset) }
                }.labelsHidden().pickerStyle(.segmented)
            }
            HStack {
                Toggle("原文", isOn: displayBinding(\.showOriginal))
                Toggle("译文", isOn: displayBinding(\.showTranslation))
                Toggle("读音", isOn: displayBinding(\.showKana))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("原文与译文字号")
                V3NumericSlider(value: displayDoubleBinding(\.fontSize), in: 14...42, step: 1, unit: "pt")
            }
            Picker("对齐", selection: $settings.v3LyricsPosition) {
                Text("跟随场景").tag("automatic")
                Text("左").tag("left")
                Text("居中").tag("center")
                Text("右").tag("right")
            }.pickerStyle(.segmented)
                .help("跟随场景：当前使用" + (settings.v3ListeningScene == .coverPhoto ? "右侧阅读区" : settings.v3ArtworkPresentation == .stage ? "居中阅读区" : "左对齐"))
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("清晰度").font(.system(size: 12, weight: .medium))
                    Image(systemName: "info.circle").help("文字阴影只作用于歌词；柔和光晕随封面明暗调整。")
                }
                Picker("清晰度", selection: $settings.v3ReadingProtection) {
                    ForEach(V3ReadingProtection.allCases) { value in Text(value.title).tag(value) }
                }.pickerStyle(.segmented).labelsHidden()
                Toggle("亮封面自动加阴影", isOn: $settings.v3BrightCoverShadowEnabled)
                    .font(.system(size: 12))
                    .help("封面、舞台遇亮封面且清晰度为关闭时自动加文字阴影；关闭后「关闭」保持完全不加。")
            }
            HStack(spacing: 10) {
                Toggle("罗马音", isOn: displayBinding(\.showRomaji))
                Toggle("拼音", isOn: displayBinding(\.showPinyin))
            }
            Picker("注音排版", selection: displayBinding(\.kanaDisplayMode)) {
                Text("汉字上方").tag(KanaDisplayMode.inlineRuby)
                Text("独立一行").tag(KanaDisplayMode.independentLine)
                Text("替换汉字").tag(KanaDisplayMode.kanaReplacement)
                Text("隐藏").tag(KanaDisplayMode.hidden)
            }
            .accessibilityIdentifier("v3.display.kanaMode")

            Divider()
            sectionLabel("字号")
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("读音与辅助字")
                    Spacer()
                    Text("\(Int(settings.displayPreferences.assistantFontSize.rounded())) pt").monospacedDigit()
                }
                V3NumericSlider(value: displayDoubleBinding(\.assistantFontSize), in: 10...24, step: 1, unit: "pt")
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("假名字号")
                    Spacer()
                    Text("\(Int(settings.displayPreferences.rubyFontSize.rounded())) pt").monospacedDigit()
                }
                V3NumericSlider(value: displayDoubleBinding(\.rubyFontSize), in: 8...18, step: 1, unit: "pt")
            }
            DisclosureGroup("更多文字选项") { textAdvancedControls }
        }
    }

    var textAdvancedControls: some View {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("繁简转换", selection: readingBinding(\.scriptConversionID)) {
                        Text("不转换").tag(ScriptConversionID.none.rawValue)
                        Text("繁体转简体").tag(ScriptConversionID.traditionalToSimplified.rawValue)
                        Text("简体转繁体").tag(ScriptConversionID.simplifiedToTraditional.rawValue)
                    }
                    Toggle("远处歌词隐藏辅助读音", isOn: displayBinding(\.hideDistantAuxiliary))
                    HStack {
                        Text("非当前歌词透明度")
                        Spacer()
                        Text("\(Int(settings.displayPreferences.opacity * 100))%").monospacedDigit()
                    }
                    V3NumericSlider(value: displayBinding(\.opacity), in: 0.15...1, step: 0.05, unit: "%", displayScale: 100)
                }
    }

    private func sectionLabel(_ title: String) -> some View {
        IslandSectionHeader(title: title)
    }

    private func atmosphereButton(_ title: String, level: Int) -> some View {
        let selected = settings.v3AtmosphereLevel(for: settings.v3ArtworkPresentation) == level
        return Button(title) {
            settings.setV3AtmosphereLevel(level, for: settings.v3ArtworkPresentation)
        }
        .font(.system(size: 11, weight: selected ? .semibold : .regular))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(selected ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func displayBinding<Value>(_ keyPath: WritableKeyPath<DisplayPreferences, Value>) -> Binding<Value> {
        Binding(get: { settings.displayPreferences[keyPath: keyPath] }, set: { value in
            var next = settings.displayPreferences
            next[keyPath: keyPath] = value
            settings.displayPreferences = next
        })
    }

    private func displayDoubleBinding(_ keyPath: WritableKeyPath<DisplayPreferences, CGFloat>) -> Binding<Double> {
        Binding(
            get: { Double(settings.displayPreferences[keyPath: keyPath]) },
            set: { value in
                var next = settings.displayPreferences
                next[keyPath: keyPath] = CGFloat(value)
                settings.displayPreferences = next
            }
        )
    }

    private func readingBinding<Value>(_ keyPath: WritableKeyPath<ReadingPreferences, Value>) -> Binding<Value> {
        Binding(get: { settings.readingPreferences[keyPath: keyPath] }, set: { value in
            var next = settings.readingPreferences
            next[keyPath: keyPath] = value
            settings.readingPreferences = next
        })
    }

    @ViewBuilder
    private func blurPresetButton(_ title: String, val: Double) -> some View {
        Button(title) {
            settings.v3BackdropBlurRadius = val
        }
        .buttonStyle(.plain)
        .font(.system(size: 11, weight: abs(settings.v3BackdropBlurRadius - val) < 5 ? .bold : .regular))
        .foregroundStyle(abs(settings.v3BackdropBlurRadius - val) < 5 ? Color.blue : Color.secondary)
    }

    @ViewBuilder
    private func sizePresetButton(_ title: String, val: Double) -> some View {
        Button(title) {
            settings.v3ArtworkSizeScale = val
        }
        .buttonStyle(.plain)
        .font(.system(size: 11, weight: abs(settings.v3ArtworkSizeScale - val) < 0.04 ? .bold : .regular))
        .foregroundStyle(abs(settings.v3ArtworkSizeScale - val) < 0.04 ? Color.blue : Color.secondary)
    }

    @ViewBuilder
    private func backdropScalePresetButton(_ title: String, val: Double) -> some View {
        let currentScale = settings.v3BackdropScale(for: settings.v3ArtworkPresentation)
        Button(title) {
            settings.setV3BackdropScale(val, for: settings.v3ArtworkPresentation)
        }
        .buttonStyle(.plain)
        .font(.system(size: 11, weight: abs(currentScale - val) < 0.04 ? .bold : .regular))
        .foregroundStyle(abs(currentScale - val) < 0.04 ? Color.blue : Color.secondary)
    }
}

// A read-only, line-index-aligned view of already persisted translations.
// It never starts translation, mutates source lyrics or treats draft rows as complete.
struct V3TranslationComparisonSheet: View {
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
