import Foundation
import SwiftUI
import AppKit
import Combine
import os

struct V3SegmentedPicker<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(title: String, value: Value)]
    var showsLabel = true
    var height: CGFloat = 26
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoveredIndex: Int?

    init(_ title: String, selection: Binding<Value>, options: [(String, Value)],
         showsLabel: Bool = true, height: CGFloat = 26) {
        self.title = title
        self._selection = selection
        self.options = options
        self.showsLabel = showsLabel
        self.height = height
    }

    var body: some View {
        HStack(spacing: 8) {
            if showsLabel {
                Text(title).font(.system(size: 12.5)).lineLimit(1)
                    .frame(width: V3PanelMetrics.labelWidth, alignment: .leading)
            }
            GeometryReader { geometry in
                let segmentWidth = max(0, (geometry.size.width - 4) / CGFloat(max(1, options.count)))
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.08))
                    if let selected = options.firstIndex(where: { $0.value == selection }) {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.primary.opacity(0.16))
                            .frame(width: segmentWidth, height: height - 4)
                            .offset(x: 2 + CGFloat(selected) * segmentWidth)
                            .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: selection)
                    }
                    HStack(spacing: 0) {
                        ForEach(options.indices, id: \.self) { index in
                            Button { selection = options[index].value } label: {
                                Text(options[index].title)
                                    .font(.system(size: 11, weight: selection == options[index].value ? .semibold : .regular))
                                    .lineLimit(1).minimumScaleFactor(0.75)
                                    .frame(width: segmentWidth, height: height - 4)
                                    .background(hoveredIndex == index ? Color.primary.opacity(0.06) : .clear,
                                                in: RoundedRectangle(cornerRadius: 5))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .onKeyPress(.leftArrow) {
                                let current = options.firstIndex { $0.value == selection } ?? index
                                if current > 0 { selection = options[current - 1].value }
                                return .handled
                            }
                            .onKeyPress(.rightArrow) {
                                let current = options.firstIndex { $0.value == selection } ?? index
                                if current + 1 < options.count { selection = options[current + 1].value }
                                return .handled
                            }
                            .onHover { hovering in
                                if hovering { hoveredIndex = index }
                                else if hoveredIndex == index { hoveredIndex = nil }
                            }
                            .accessibilityAddTraits(selection == options[index].value ? .isSelected : [])
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
            .frame(height: height)
        }
        .frame(minHeight: showsLabel ? V3PanelMetrics.rowHeight : nil)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
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
        return V3SceneFamily.family(ofLegacy: settings.v3ArtworkPresentation)
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
            // Four families in one row; the chosen family's styles sit in one
            // row underneath, so the sliders below stay on screen. Entries
            // only — every style is an existing scene + renderer pair and
            // keeps its saved values.
            HStack(alignment: .top, spacing: 6) {
                ForEach(V3SceneFamily.allCases) { family in
                    familyCard(family)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center) {
                    Text(shownFamily.title + " · 风格").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    if shownFamily == .cover, shownFamily == currentFamily,
                       shownFamily.entries.contains(where: { $0.isCoverPair && shownFamily.isSelected($0, settings: settings) }) {
                        // Outside the style buttons: inside a plain button's
                        // label the segmented control never receives the click.
                        V3SegmentedPicker("背景", selection: Binding(
                            get: { settings.v3ArtworkPresentation == .classicGaussian ? 1 : 0 },
                            set: { chooseCoverMotion($0 == 1 ? .classicGaussian : .ambient) }
                        ), options: [("静止", 1), ("流动", 0)], showsLabel: false, height: 22)
                        .frame(width: 84)
                        .accessibilityIdentifier("v3.cover.motion")
                    } else if !compact {
                        Text(shownFamily.detail).font(.system(size: 11)).foregroundStyle(Color.secondary).lineLimit(1)
                    }
                }
                .frame(minHeight: 22)
                HStack(spacing: 4) {
                    ForEach(shownFamily.entries) { entry in
                        entryRow(entry, in: shownFamily)
                    }
                }
            }
            .padding(8)
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
            VStack(spacing: 4) {
                // The thumbnail is drawn at its design size and scaled down,
                // so its inner proportions stay as designed.
                Color.clear.aspectRatio(150.0 / 72.0, contentMode: .fit)
                    .overlay(alignment: .topLeading) {
                        GeometryReader { geometry in
                            LyricIslandSceneThumbnail(scene: family.primaryScene, image: thumbnail, accent: tint)
                                .frame(width: 150, height: 72)
                                .scaleEffect(geometry.size.width / 150, anchor: .topLeading)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                Text(family.title)
                    .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected || previewing ? Color.primary : Color.secondary)
                    .lineLimit(1)
            }
            .padding(4)
            .frame(maxWidth: .infinity)
            .background(selected ? tint.opacity(0.14) : Color.primary.opacity(0.035),
                        in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9)
                .strokeBorder(selected ? tint.opacity(0.75) : previewing ? tint.opacity(0.45) : .clear,
                              style: StrokeStyle(lineWidth: 1, dash: previewing ? [3, 3] : [])))
            .contentShape(RoundedRectangle(cornerRadius: 9))
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
    /// differently inside a scene and as a legacy preset.
    private func entryRow(_ entry: V3SceneFamily.Entry, in family: V3SceneFamily) -> some View {
        let selected = family.isSelected(entry, settings: settings)
        let renderer = family.adoptRenderer(for: entry, settings: settings)
        let previewing = !selected && preview == renderer && previewScene == entry.scene
        return Button { adopt(entry, in: family) } label: {
            Text(entry.title)
                .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected || previewing ? Color.primary : Color.secondary)
                .lineLimit(1).minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, minHeight: 26)
                .background(selected ? tint.opacity(0.16) : Color.primary.opacity(0.04),
                            in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(selected ? tint.opacity(0.7) : previewing ? tint.opacity(0.45) : .clear,
                                  style: StrokeStyle(lineWidth: 1, dash: previewing ? [3, 3] : [])))
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .onHover { hovering($0, scene: entry.scene, renderer: renderer) }
        .help(entry.detail ?? entry.title)
        .accessibilityLabel(entry.title)
        .accessibilityIdentifier(entry.scene == nil ? "v3.style." + renderer.rawValue
                                 : "v3.scene." + entry.scene!.rawValue + "." + renderer.rawValue)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func adopt(_ entry: V3SceneFamily.Entry, in family: V3SceneFamily) {
        clearPreview()
        if let scene = entry.scene {
            settings.selectV3Scene(scene, renderer: family.adoptRenderer(for: entry, settings: settings))
        } else {
            settings.selectLegacyV3Presentation(entry.renderer)
        }
    }

    /// 静止 = 纯高斯, 流动 = 封面柔焦. Picking 流动 turns its background motion
    /// on when it was still; an existing 轻柔/鲜明 choice is kept.
    private func chooseCoverMotion(_ renderer: V3ArtworkPresentation) {
        clearPreview()
        settings.selectV3Scene(.coverPhoto, renderer: renderer)
        if renderer == .ambient,
           settings.v3AtmosphereLevel(for: .ambient, scene: .coverPhoto) == 0 {
            settings.setV3AtmosphereLevel(1, for: .ambient)
        }
    }
}

/// Entry grouping only. Families map onto existing scene + renderer pairs and
/// the two remaining classic presets; nothing here is persisted.
enum V3SceneFamily: String, CaseIterable, Identifiable {
    case ambient, cover, linerNotes, focus
    var id: String { rawValue }

    /// One visible row. `renderers` holds one ID, or the 静止 / 流动 pair for
    /// 封面. Merging changes rows only: every renderer keeps its raw ID and
    /// its own stored parameters.
    struct Entry: Hashable, Identifiable {
        let scene: V3ListeningScene?
        let renderers: [V3ArtworkPresentation]
        let title: String
        let detail: String?
        var id: String {
            (scene?.rawValue ?? "legacy") + "/" + renderers.map(\.rawValue).joined(separator: "+")
        }
        var renderer: V3ArtworkPresentation { renderers[0] }
        var isCoverPair: Bool { renderers.count > 1 }
        var isLegacy: Bool { scene == nil }
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

    /// 4 categories, 9 styles. 经典·柔和光晕 and 经典·封面海报 survive as the
    /// 柔和光晕 and 唱片卡 rows.
    var entries: [Entry] {
        switch self {
        case .ambient:
            return [
                Entry(scene: .originalAmbient, renderers: [.authenticAmbient],
                      title: "原版环境光", detail: "完整封面；背景明暗可调"),
                Entry(scene: nil, renderers: [.classic],
                      title: "柔和光晕", detail: "柔和偏暗的封面光晕，随专辑色彩扩散"),
                Entry(scene: .flowingField, renderers: [.classic],
                      title: "独立色场", detail: "独立色场，背景动态可调"),
                Entry(scene: .flowingField, renderers: [.ambientFeathered],
                      title: "柔光羽化", detail: "封面边缘渐隐融入光晕"),
            ]
        case .cover:
            return [
                Entry(scene: .coverPhoto, renderers: [.ambient, .classicGaussian],
                      title: "封面", detail: nil),
                Entry(scene: .coverPhoto, renderers: [.stage],
                      title: "舞台", detail: "完整封面居中，模糊背景补齐"),
            ]
        case .linerNotes:
            return [
                Entry(scene: .linerNotes, renderers: [.albumPoster],
                      title: "内页", detail: "题头、版心与段落"),
                Entry(scene: nil, renderers: [.albumPoster],
                      title: "唱片卡", detail: "完整封面与歌曲信息组成海报"),
            ]
        case .focus:
            return [
                Entry(scene: .focusedLyrics, renderers: [.lyricsOnly],
                      title: "专注", detail: "安静底色与受控行宽，连续阅读优先"),
            ]
        }
    }

    func isSelected(_ entry: Entry, settings: AppSettingsStore) -> Bool {
        settings.v3ListeningScene == entry.scene
            && entry.renderers.contains(settings.v3ArtworkPresentation)
    }

    /// The renderer a click adopts. 封面 keeps whichever side of the
    /// 静止 / 流动 switch is already in use.
    func adoptRenderer(for entry: Entry, settings: AppSettingsStore) -> V3ArtworkPresentation {
        if entry.renderers.contains(settings.v3ArtworkPresentation) {
            return settings.v3ArtworkPresentation
        }
        return entry.renderer
    }

    func contains(scene: V3ListeningScene?, renderer: V3ArtworkPresentation) -> Bool {
        entries.contains { $0.scene == scene && $0.renderers.contains(renderer) }
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

    static func family(ofLegacy renderer: V3ArtworkPresentation) -> V3SceneFamily {
        allCases.first { family in
            family.entries.contains { $0.isLegacy && $0.renderers.contains(renderer) }
        } ?? .ambient
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

    private var usesQuietBackground: Bool {
        settings.v3ListeningScene == .focusedLyrics || settings.v3ListeningScene == .linerNotes
    }

    @ViewBuilder var blurControls: some View {
        if settings.v3ArtworkPresentation != .stage || settings.v3BackgroundShowsCompleteArtwork(for: .stage) {
        // The / key steps through 0 · 25 · 50 · 75 · 100; the slider covers the rest.
        V3NumericSlider("背景模糊", value: $settings.v3BackdropBlurRadius, in: 0...100, step: 1, unit: "%")
            .accessibilityLabel(settings.v3ArtworkPresentation.blurControlTitle)
            .help("按 / 在 0 · 25 · 50 · 75 · 100 之间切换，, 和 . 每次 ±5")
        }
    }

    private var backdropScaleControls: some View {
        V3NumericSlider("背景缩放", value: Binding(
            get: { settings.v3BackdropScale(for: settings.v3ArtworkPresentation) },
            set: { settings.setV3BackdropScale($0, for: settings.v3ArtworkPresentation) }
        ), in: 0.8...1.4, step: 0.05, unit: "%", displayScale: 100)
            .accessibilityLabel("背景缩放")
            .accessibilityIdentifier("v3.classic.backgroundScale")
    }

    var pictureAdvancedControls: some View {
        pictureAdvancedControls(showsExplanations: true)
    }

    var playbackPresentationControls: some View {
        V3SegmentedPicker("播放呈现", selection: $settings.v3PlaybackPresentation,
                          options: V3PlaybackPresentation.allCases.map { ($0.title, $0) })
    }

    @ViewBuilder var backgroundMotionControls: some View {
        if !usesQuietBackground && settings.v3ArtworkPresentation != .classicGaussian {
            V3SegmentedPicker("背景动态", selection: Binding(
                get: { settings.v3AtmosphereLevel(for: settings.v3ArtworkPresentation) },
                set: { settings.setV3AtmosphereLevel($0, for: settings.v3ArtworkPresentation) }
            ), options: [("关闭", 0), ("轻柔", 1), ("鲜明", 2)])
            .help("暂停、窗口隐藏或系统减少动态效果时停止装饰运动。")
        }
    }

    func pictureAdvancedControls(showsExplanations: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle("夜间柔和", isOn: $settings.v3NightGentleEnabled)
                .help("20:00–07:00 降低亮度15%，背景动态最高为轻柔。")
            let renderer = settings.v3ArtworkPresentation
            let scene = settings.v3ListeningScene
            if scene != .focusedLyrics && scene != .linerNotes {
                V3PanelSection(title: "背景")
                if !(scene == .flowingField && renderer == .classic) {
                    V3SegmentedPicker("取景", selection: Binding(
                        get: { settings.v3BackgroundShowsCompleteArtwork(for: renderer) },
                        set: { settings.setV3BackgroundShowsCompleteArtwork($0, for: renderer) }
                    ), options: [("铺满", false), ("尽量完整", true)])
                    .help("背景取景不改变前景封面；可铺满裁切或保留完整内容。")
                    backdropScaleControls
                }
                if scene == .originalAmbient && renderer == .authenticAmbient {
                    V3NumericSlider("背景明暗", value: Binding(
                        get: { settings.v3BackgroundBrightness(for: renderer, scene: scene) },
                        set: { settings.setV3BackgroundBrightness($0, for: renderer) }
                    ), in: 0.6...1.4, step: 0.05, unit: "%", displayScale: 100)
                        .accessibilityLabel("背景明暗")
                        .accessibilityIdentifier("v3.backgroundBrightness")
                        .help("100% 保持现有观感；调高让偏暗的封面更接近旧的轻盈版。")
                }
                if showsExplanations { backgroundMotionControls }
            }
            if scene != .focusedLyrics && scene != .coverPhoto && settings.v3ShowForegroundArtwork {
                V3PanelSection(title: "前景封面")
                V3NumericSlider("尺寸", value: $settings.v3ArtworkSizeScale, in: 0.8...1.4, step: 0.05,
                                unit: "%", displayScale: 100)
                    .accessibilityLabel("前景封面尺寸")
                if scene != .linerNotes {
                    V3SegmentedPicker("位置", selection: $settings.v3ArtworkPosition,
                                      options: [("居左", "left"), ("居中", "center"), ("居右", "right")])
                }
                if scene == nil && renderer != .albumPoster && renderer != .stage && renderer != .lyricsOnly {
                    Toggle("隐藏播放信息时舒展封面", isOn: $settings.v3ExpandArtworkWhenDetailsHidden)
                        .accessibilityIdentifier("v3.artwork.expandWhenDetailsHidden")
                }
            }
            V3PanelSection(title: "播放")
            if settings.v3EdgeProgressEnabled {
                V3WindowEdgeProgressSettings(enabled: $settings.v3EdgeProgressEnabled,
                    colorHex: $settings.v3EdgeProgressColorHex,
                    colorMode: $settings.v3EdgeProgressColorMode, showsModeToggle: false,
                    showsExplanation: showsExplanations)
            }
            Toggle("确认纯音乐时使用简洁画面", isOn: $settings.v3InstrumentalPureImmersion)
                .help("仅对已确认纯音乐生效；找不到歌词不代表纯音乐。")
            V3PanelRow(title: "旧版布局", help: "早期主窗口布局，仅为兼容保留") {
                Picker("主窗口布局", selection: $settings.mainWindowLayoutStyleRawValue) {
                    ForEach(MainWindowLayoutStyle.userSelectableCases) { style in Text(style.title).tag(style.rawValue) }
                }.pickerStyle(.menu).labelsHidden().fixedSize()
            }
        }
    }

    /// 文字: what is shown and how big first; reading details fold.
    var textPage: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("当前：\((settings.activeReadingLanguage ?? .other).title)设置")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .help("读音与显示开关按歌词语言分别记住")
            V3SegmentedPicker("显示", selection: displayBinding(\.listeningLayerPreset),
                options: DisplayPreferences.ListeningLayerPreset.allCases.filter {
                    $0 != .custom || settings.displayPreferences.listeningLayerPreset == .custom
                }.map { ($0.title, $0) })
            // Under the 显示 choice, aligned with it: the three switches it sets.
            HStack(spacing: 14) {
                Color.clear.frame(width: V3PanelMetrics.labelWidth, height: 1)
                V3InlineSwitch(title: "原文", isOn: displayBinding(\.showOriginal))
                V3InlineSwitch(title: "译文", isOn: displayBinding(\.showTranslation))
                V3InlineSwitch(title: "读音", isOn: displayBinding(\.showKana))
                Spacer(minLength: 0)
            }
            .frame(minHeight: V3PanelMetrics.rowHeight)
            V3NumericSlider("字号", value: displayDoubleBinding(\.fontSize), in: 14...42, step: 1, unit: "pt")
                .help("原文与译文字号；在歌词上双指捏合也可调整")
            Toggle("大字模式", isOn: $settings.v3BigLineModeEnabled)
                .help("当前句约两倍大，其他行缩小变淡，适合远处跟唱")
            V3SegmentedPicker("对齐", selection: $settings.v3LyricsPosition,
                              options: [("跟随场景", "automatic"), ("左", "left"), ("居中", "center"), ("右", "right")])
                .help("跟随场景：当前使用" + (settings.v3ListeningScene == .coverPhoto ? "右侧阅读区" : settings.v3ArtworkPresentation == .stage ? "居中阅读区" : "左对齐"))
            V3SegmentedPicker("清晰度", selection: $settings.v3ReadingProtection,
                              options: V3ReadingProtection.allCases.map { ($0.title, $0) })
                .help("文字阴影只作用于歌词；柔和光晕随封面明暗调整。")
            Toggle("亮封面自动加阴影", isOn: $settings.v3BrightCoverShadowEnabled)
                .help("封面、舞台遇亮封面且清晰度为关闭时自动加文字阴影；关闭后「关闭」保持完全不加。")
            V3DisclosureRow(title: "读音与更多", isExpanded: $settings.v3TextAdvancedExpanded) {
                V3PanelRow(title: "辅助读音") {
                    HStack(spacing: 14) {
                        V3InlineSwitch(title: "罗马音", isOn: displayBinding(\.showRomaji))
                        V3InlineSwitch(title: "拼音", isOn: displayBinding(\.showPinyin))
                    }
                }
                V3PanelRow(title: "注音排版") {
                    Picker("注音排版", selection: displayBinding(\.kanaDisplayMode)) {
                        Text("汉字上方").tag(KanaDisplayMode.inlineRuby)
                        Text("独立一行").tag(KanaDisplayMode.independentLine)
                        Text("替换汉字").tag(KanaDisplayMode.kanaReplacement)
                        Text("隐藏").tag(KanaDisplayMode.hidden)
                    }
                    .pickerStyle(.menu).labelsHidden().fixedSize()
                    .accessibilityIdentifier("v3.display.kanaMode")
                }
                V3NumericSlider("读音字号", value: displayDoubleBinding(\.assistantFontSize), in: 10...24, step: 1, unit: "pt")
                    .help("读音、罗马音与辅助字")
                V3NumericSlider("假名字号", value: displayDoubleBinding(\.rubyFontSize), in: 8...18, step: 1, unit: "pt")
                V3NumericSlider("当前句光", value: $settings.v3CurrentLineGlow, in: 0...1, step: 0.01, unit: "%", displayScale: 100)
                    .help("当前句发光强度")
                textAdvancedControls
            }
        }
    }

    var textAdvancedControls: some View {
        VStack(alignment: .leading, spacing: 2) {
            V3PanelRow(title: "繁简转换") {
                Picker("繁简转换", selection: readingBinding(\.scriptConversionID)) {
                    Text("不转换").tag(ScriptConversionID.none.rawValue)
                    Text("繁体转简体").tag(ScriptConversionID.traditionalToSimplified.rawValue)
                    Text("简体转繁体").tag(ScriptConversionID.simplifiedToTraditional.rawValue)
                }
                .pickerStyle(.menu).labelsHidden().fixedSize()
            }
            Toggle("远处歌词隐藏辅助读音", isOn: displayBinding(\.hideDistantAuxiliary))
            V3NumericSlider("其他行", value: displayBinding(\.opacity), in: 0.15...1, step: 0.05, unit: "%", displayScale: 100)
                .help("非当前歌词的透明度")
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        IslandSectionHeader(title: title)
    }

    func atmosphereButton(_ title: String, level: Int) -> some View {
        let selected = settings.v3AtmosphereLevel(for: settings.v3ArtworkPresentation) == level
        return Button {
            settings.setV3AtmosphereLevel(level, for: settings.v3ArtworkPresentation)
        } label: {
            Text(title)
                .font(.system(size: 11, weight: selected ? .semibold : .regular))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(selected ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }
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
        Button {
            settings.v3BackdropBlurRadius = val
        } label: {
            Text(title)
                .font(.system(size: 11, weight: abs(settings.v3BackdropBlurRadius - val) < 5 ? .bold : .regular))
                .foregroundStyle(abs(settings.v3BackdropBlurRadius - val) < 5 ? Color.blue : Color.secondary)
                .frame(minWidth: 40, minHeight: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func sizePresetButton(_ title: String, val: Double) -> some View {
        Button {
            settings.v3ArtworkSizeScale = val
        } label: {
            Text(title)
                .font(.system(size: 11, weight: abs(settings.v3ArtworkSizeScale - val) < 0.04 ? .bold : .regular))
                .foregroundStyle(abs(settings.v3ArtworkSizeScale - val) < 0.04 ? Color.blue : Color.secondary)
                .frame(minWidth: 40, minHeight: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func backdropScalePresetButton(_ title: String, val: Double) -> some View {
        let currentScale = settings.v3BackdropScale(for: settings.v3ArtworkPresentation)
        Button {
            settings.setV3BackdropScale(val, for: settings.v3ArtworkPresentation)
        } label: {
            Text(title)
                .font(.system(size: 11, weight: abs(currentScale - val) < 0.04 ? .bold : .regular))
                .foregroundStyle(abs(currentScale - val) < 0.04 ? Color.blue : Color.secondary)
                .frame(minWidth: 40, minHeight: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
