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
    @AppStorage(V3SceneFamily.ambientAutomaticKey, store: .lyricsQ) private var ambientAutomatic = true
    /// Which of 环境光's lights was used last, so its card returns to it.
    @AppStorage("v3.ambient.lastLook.v1", store: .lyricsQ) private var lastAmbientLook = ""
    @AppStorage("v3.reading.lastLook.v1", store: .lyricsQ) private var lastReadingLook = ""

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

    private func isCurrent(_ entry: V3SceneFamily.Entry) -> Bool {
        V3SceneFamily.inUse(entry, settings: settings)
    }

    /// The renderer a click adopts. 封面 keeps the side of 静止 / 流动 last used.
    private func renderer(for entry: V3SceneFamily.Entry) -> V3ArtworkPresentation {
        if isCurrent(entry) { return settings.v3ArtworkPresentation }
        if let scene = entry.scene, entry.isCoverPair {
            let stored = settings.v3Renderer(for: scene)
            if entry.renderers.contains(stored) { return stored }
        }
        return entry.renderer
    }

    var body: some View {
        let cards = V3SceneFamily.cards
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("场景").font(.system(size: 13, weight: .semibold))
                Spacer()
                Toggle("悬停预览", isOn: $settings.v3SceneHoverPreviewEnabled)
                    .toggleStyle(.switch).controlSize(.mini)
                    .font(.system(size: 11))
                    .help("停留后临时预览，移开恢复，点击才采用；预览不会保存设置或调用 AI")
            }
            // One row, nothing behind a menu. Each card is an existing scene
            // + renderer pair and keeps its saved values.
            HStack(alignment: .top, spacing: 6) {
                ForEach(cards) { card in lookCard(card) }
            }
            if let card = cards.first(where: { $0.entries.count > 1 && $0.entries.contains(where: isCurrent) }) {
                styleRow(card)
                if card.automatic {
                    V3SegmentedPicker("光随歌曲", selection: $settings.v3AmbientLyricMotion,
                                      options: V3AmbientLyricMotion.allCases.map { ($0.title, $0) })
                    .help("换行呼吸：每换一句歌词，光轻轻亮一下。随曲推移：背景颜色随播放进度从封面主色走到副色。系统减少动态效果时不动。")
                }
            }
            if !compact, settings.v3ListeningScene != nil {
                Button("恢复此场景的默认值", role: .destructive) {
                    clearPreview(); settings.resetCurrentV3Scene()
                }.font(.system(size: 12)).buttonStyle(.borderless)
                .help("只重置当前场景的画面数值；其他场景不受影响")
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
        .onDisappear { clearPreview() }
    }

    /// Selection always matches scene + renderer: the same renderer draws
    /// differently inside a scene and as a legacy preset.
    /// The entry a card stands for: the one in use, else the one last used
    /// on that card, else its first.
    private func entry(of card: V3SceneFamily.Card) -> V3SceneFamily.Entry {
        card.entries.first(where: isCurrent)
            ?? card.entries.first { $0.id == (card.automatic ? lastAmbientLook : lastReadingLook) }
            ?? card.entries[0]
    }

    /// The looks inside one card, as an ordinary row under the cards.
    /// 环境光 has two lights that really differ: 原版 (the whole cover, dark
    /// and even) and 羽化 (the cover as a round source of light). Which
    /// suits depends on the song, so the app chooses unless one is picked.
    private func styleRow(_ card: V3SceneFamily.Card) -> some View {
        let current = card.entries.firstIndex(where: isCurrent) ?? 0
        var options: [(String, Int)] = card.automatic ? [("自动", -1)] : []
        for (index, entry) in card.entries.enumerated() {
            options.append((V3SceneFamily.shortTitle(entry), index))
        }
        let selection = Binding<Int>(
            get: { card.automatic && ambientAutomatic ? -1 : current },
            set: { choice in
                if card.automatic { ambientAutomatic = choice < 0 }
                if choice < 0 { applyAutomaticAmbient() } else { adopt(card.entries[choice]) }
            })
        let details = card.entries.map { $0.title + "：" + ($0.detail ?? "") }.joined(separator: "\n")
        return V3SegmentedPicker(card.rowTitle, selection: selection, options: options)
            .accessibilityIdentifier("v3.card.style." + card.id)
            .help(card.automatic ? "自动：按每首歌的封面选择。细节很多或两种颜色分明的用双色，亮的用原版，暗的用羽化。\n" + details : details)
    }

    private func applyAutomaticAmbient() {
        Task { @MainActor in
            let palette = await LyricIslandArtworkColors.palette(for: artworkURL)
            let detail = await V3CoverDetail.detail(for: artworkURL) ?? 0
            V3SceneFamily.applyAutomaticAmbient(settings: settings, palette: palette, detail: detail)
        }
    }

    private func lookCard(_ card: V3SceneFamily.Card) -> some View {
        let entry = entry(of: card)
        let selected = isCurrent(entry)
        let target = renderer(for: entry)
        let previewing = !selected && preview == target && previewScene == entry.scene
        return Button {
            adopt(entry)
            if card.automatic, ambientAutomatic { applyAutomaticAmbient() }
        } label: {
            VStack(spacing: 4) {
                // The thumbnail is drawn at its design size and scaled down,
                // so its inner proportions stay as designed.
                Color.clear.aspectRatio(150.0 / 72.0, contentMode: .fit)
                    .overlay(alignment: .topLeading) {
                        GeometryReader { geometry in
                            LyricIslandSceneThumbnail(scene: entry.scene ?? .originalAmbient, image: thumbnail,
                                accent: tint,
                                variant: entry.renderer == .stage ? .stage : .standard)
                                .frame(width: 150, height: 72)
                                .scaleEffect(geometry.size.width / 150, anchor: .topLeading)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                Text(card.title)
                    .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected || previewing ? Color.primary : Color.secondary)
                    .lineLimit(1).minimumScaleFactor(0.85)
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
        .onHover { hovering($0, scene: entry.scene, renderer: target) }
        .help(entry.detail ?? entry.title)
        .accessibilityLabel(card.title)
        .accessibilityIdentifier("v3.scene." + (entry.scene?.rawValue ?? "legacy") + "." + target.rawValue)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func adopt(_ entry: V3SceneFamily.Entry) {
        let target = renderer(for: entry)
        clearPreview()
        if let card = V3SceneFamily.cards.first(where: { $0.entries.count > 1 && $0.entries.contains(entry) }) {
            if card.automatic { lastAmbientLook = entry.id } else { lastReadingLook = entry.id }
        }
        if entry.scene == .originalAmbient { settings.v3AmbientTreatment = entry.treatment }
        if let scene = entry.scene { settings.selectV3Scene(scene, renderer: target) }
        else { settings.selectLegacyV3Presentation(target) }
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
        /// 双色 and 窗光 are drawn over 原版环境光's scene and renderer.
        var treatment: V3AmbientTreatment = .none
        var id: String {
            (scene?.rawValue ?? "legacy") + "/" + renderers.map(\.rawValue).joined(separator: "+")
                + (treatment == .none ? "" : "#" + treatment.rawValue)
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

    /// One card in the 画面 panel. A card with several entries shows them
    /// in a row under the cards.
    struct Card: Identifiable {
        let title: String
        /// The label of the row that lists the entries.
        let rowTitle: String
        let entries: [Entry]
        /// The app may choose between the entries for each song.
        var automatic = false
        var id: String { title }
    }

    /// The 画面 panel shows four cards in one row, none behind a menu.
    /// - 环境光: 原版环境光 and 柔光羽化, chosen by the app for each song
    ///   unless one is picked. 柔和光晕 is not listed: it differs from 原版
    ///   in cover size and darkness, and both have their own controls.
    /// - 阅读: 内页, 唱片卡 and 专注, the pages on a quiet background. 内页
    ///   has the colour field that 独立色场 had, so 独立色场 is not listed.
    /// A saved 柔和光晕 or 独立色场 choice keeps drawing until a card is picked.
    static var cards: [Card] {
        let all = allCases.flatMap(\.entries)
        func entries(_ titles: [String]) -> [Entry] { titles.compactMap { title in all.first { $0.title == title } } }
        let duotone = Entry(scene: .originalAmbient, renderers: [.authenticAmbient], title: "双色",
                            detail: "封面用自己的两种颜色重印，没有细节干扰歌词", treatment: .duotone)
        let window = Entry(scene: .originalAmbient, renderers: [.authenticAmbient], title: "窗光",
                           detail: "封面像一扇窗，几道光斜斜照过歌词", treatment: .windowLight)
        return [Card(title: "环境光", rowTitle: "光", entries: entries(["原版环境光", "柔光羽化"]) + [duotone, window],
                     automatic: true),
                Card(title: "封面", rowTitle: "封面", entries: entries(["封面"])),
                Card(title: "舞台", rowTitle: "舞台", entries: entries(["舞台"])),
                Card(title: "阅读", rowTitle: "版式", entries: entries(["内页", "唱片卡", "专注"]))]
    }

    static let ambientAutomaticKey = "v3.ambient.automatic.v1"

    /// 原版 keeps lyrics readable over a bright cover; 羽化 lets a dark cover
    /// give off light. The boundary is a first setting from two real songs.
    /// A busy cover (much fine detail) gets 双色, which keeps no detail
    /// behind the lyrics; a bright one 原版; a dark one 羽化. 窗光 is a
    /// matter of taste and is never chosen by the app. The boundaries are
    /// first settings from the user's own covers.
    /// A cover with two strong colours (`CoverColorRoute.duet`) also gets
    /// 双色: it reprints the cover in exactly those two.
    static func automaticAmbient(luminance: Double, detail: Double = 0, route: CoverColorRoute = .structural) -> Entry {
        let lights = cards[0].entries
        if detail >= busyCoverDetail || route == .duet { return lights[2] }
        return luminance >= 0.42 ? lights[0] : lights[1]
    }
    static let busyCoverDetail = 0.072

    /// The entry is the look on screen: scene, renderer and, for 原版环境光,
    /// the light drawn over it.
    @MainActor
    static func inUse(_ entry: Entry, settings: AppSettingsStore) -> Bool {
        guard settings.v3ListeningScene == entry.scene,
              entry.renderers.contains(settings.v3ArtworkPresentation) else { return false }
        if entry.scene == .originalAmbient { return settings.v3AmbientTreatment == entry.treatment }
        return true
    }

    /// Moves between 环境光's lights for a new cover. It acts only while 环境光
    /// is the scene in use, the choice is left to the app, and the cover's
    /// colours are known.
    @MainActor
    static func applyAutomaticAmbient(settings: AppSettingsStore, palette: BackdropPalette, detail: Double = 0,
                                      defaults: UserDefaults = .lyricsQ) {
        guard defaults.object(forKey: ambientAutomaticKey) as? Bool ?? true, palette != .neutral else { return }
        guard cards[0].entries.contains(where: { inUse($0, settings: settings) }) else { return }
        let target = automaticAmbient(luminance: palette.luminance, detail: detail, route: palette.route)
        guard !inUse(target, settings: settings), let scene = target.scene else { return }
        if scene == .originalAmbient { settings.v3AmbientTreatment = target.treatment }
        settings.selectV3Scene(scene, renderer: target.renderer)
    }

    static func shortTitle(_ entry: Entry) -> String {
        switch entry.title {
        case "原版环境光": return "原版"
        case "柔和光晕": return "光晕"
        case "柔光羽化": return "羽化"
        case "唱片卡": return "唱片"
        default: return entry.title
        }
    }

    /// 4 categories, 9 styles. 经典·柔和光晕 and 经典·封面海报 survive as the
    /// 柔和光晕 and 唱片卡 entries.

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
        VStack(spacing: 2) {
            V3SegmentedPicker("播放呈现", selection: $settings.v3PlaybackPresentation,
                              options: V3PlaybackPresentation.established.map { ($0.title, $0) })
            // The six newer presentations, one click away like the first three.
            V3SegmentedPicker("新呈现", selection: $settings.v3PlaybackPresentation,
                              options: V3PlaybackPresentation.additions.map { ($0.title, $0) })
                .help(V3PlaybackPresentation.additions.map { $0.title + "：" + $0.detail }.joined(separator: "\n"))
            // The player card's own options, while the scene shows its card.
            if !settings.v3ScenePlayerHidden {
                V3SegmentedPicker("进度条", selection: $settings.v3ProgressStyle,
                                  options: V3ProgressStyle.allCases.map { ($0.title, $0) })
                    .help("歌词刻度：每句歌词的位置，悬停看那句。波形：按歌词疏密画出的起伏，Spotify 不提供音频数据。")
                HStack(spacing: 12) {
                    Color.clear.frame(width: V3PanelMetrics.labelWidth, height: 1)
                    V3InlineSwitch(title: "悬停出按钮", isOn: $settings.v3PlayerButtonsOnHover)
                    V3InlineSwitch(title: "歌名滚动", isOn: $settings.v3PlayerTitleMarquee)
                    V3InlineSwitch(title: "进度贴封面", isOn: $settings.v3PlayerProgressOnCover)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: V3PanelMetrics.rowHeight)
            }
        }
    }

    /// 歌词呈现: seven looks in two rows, all one click away.
    var lyricStyleControls: some View {
        let first = Array(V3LyricStyle.allCases.prefix(4)), second = Array(V3LyricStyle.allCases.dropFirst(4))
        return VStack(spacing: 2) {
            V3SegmentedPicker("歌词呈现", selection: $settings.v3LyricStyle, options: first.map { ($0.title, $0) })
            V3SegmentedPicker("", selection: $settings.v3LyricStyle, options: second.map { ($0.title, $0) })
        }
        .help(V3LyricStyle.allCases.map { $0.title + "：" + $0.detail }.joined(separator: "\n"))
    }

    /// 工具栏: six ways to show the same tools.
    var toolbarStyleControls: some View {
        V3SegmentedPicker("工具栏", selection: $settings.v3ToolbarStyle,
                          options: V3ToolbarStyle.allCases.map { ($0.title, $0) })
            .help(V3ToolbarStyle.allCases.map { $0.title + "：" + $0.detail }.joined(separator: "\n"))
    }

    /// 封面 has two renderers behind one card: 纯高斯 is the still picture
    /// and 封面柔焦 the moving one. 背景动态 chooses between them, so there is
    /// no separate 静止 / 流动 switch.
    @ViewBuilder var backgroundMotionControls: some View {
        let renderer = settings.v3ArtworkPresentation
        if settings.v3ListeningScene == .coverPhoto, renderer == .ambient || renderer == .classicGaussian {
            V3SegmentedPicker("背景动态", selection: Binding(
                get: { renderer == .classicGaussian ? 0 : settings.v3AtmosphereLevel(for: .ambient) },
                set: { level in
                    if level == 0 {
                        settings.selectV3Scene(.coverPhoto, renderer: .classicGaussian)
                    } else {
                        settings.selectV3Scene(.coverPhoto, renderer: .ambient)
                        settings.setV3AtmosphereLevel(level, for: .ambient)
                    }
                }
            ), options: [("关闭", 0), ("轻柔", 1), ("鲜明", 2)])
            .accessibilityIdentifier("v3.cover.motion")
            .help("关闭为静止的封面；轻柔和鲜明让背景缓慢流动。暂停、窗口隐藏或系统减少动态效果时停止。")
        } else if settings.v3ListeningScene != .focusedLyrics && renderer != .classicGaussian {
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
                    V3SegmentedPicker("背景素材", selection: $settings.v3BackdropSource,
                                      options: V3BackdropSource.allCases.map { ($0.title, $0) })
                        .accessibilityIdentifier("v3.backdrop.source")
                        .help("视频：歌曲有 Spotify Canvas 短片时循环播放它，没有就用封面；只读本机 Spotify 已缓存的地址，可能在歌曲开始几秒后才出现，暂停、窗口隐藏或系统减少动态效果时停住。\n歌手照片：像 Spotify 电视版那样用主唱歌手的照片，取不到时用封面。\n前景封面不变。")
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
            V3MusicMotionRow(settings: settings)
            Toggle("暂停时褪色", isOn: $settings.v3PauseFadesColor)
                .help("暂停一会儿后，背景慢慢褪成接近黑白；继续播放时颜色很快回来。")
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
            lyricStyleControls
            V3NumericSlider("字号", value: displayDoubleBinding(\.fontSize), in: 14...42, step: 1, unit: "pt")
                .help("原文与译文字号；在歌词上双指捏合也可调整")
            Toggle("大字模式", isOn: $settings.v3BigLineModeEnabled)
                .help("当前句约两倍大，其他行缩小变淡，适合远处跟唱")
            Toggle("副歌加强", isOn: $settings.v3ChorusEmphasis)
                .help("从歌词里找出重复的段落当作副歌：进度条上标成浅色段，唱到副歌时画面亮一档、当前句带封面色的光。")
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
            Toggle("还原被星号遮住的词", isOn: $settings.lyricsRestoreCensoredWords)
                .help("来源把脏话写成 f**k、sh*t 时显示完整的词，方便跟唱。只改显示，不改保存的歌词。")
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


/// 随音乐律动 and what it is doing. It needs screen and audio recording
/// permission and shows the system's recording mark while it listens.
struct V3MusicMotionRow: View {
    @ObservedObject var settings: AppSettingsStore
    @ObservedObject private var pulse = V3MusicPulse.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle("随音乐律动", isOn: $settings.v3MusicMotionEnabled)
                .accessibilityIdentifier("v3.musicMotion")
                .help("听 Spotify 的声音：鼓点时封面处的光一亮一胀，歌词换行的快慢跟着歌曲速度。只采 Spotify 的声音、不录麦克风、不保存；需要屏幕与系统录音权限，听的时候菜单栏会有录制标志。暂停或窗口隐藏时停止。")
            if settings.v3MusicMotionEnabled {
                Text(statusText).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var statusText: String {
        switch pulse.status {
        case .off: return "播放时开始听"
        case .starting: return "正在连接 Spotify 的声音…"
        case .running:
            let _ = pulse.analysisRevision
            let analysis = V3MusicPulse.analysis
            if let bpm = analysis.bpm {
                let key = analysis.key.map { " · \($0) 调" + (analysis.camelot.map { "（\($0)）" } ?? "") } ?? ""
                let beats = analysis.beats.isEmpty ? "" : " · 按 Spotify 的节拍"
                return "正在听，\(Int(bpm.rounded())) BPM\(key)\(beats)，来自 Spotify"
            }
            if let bpm = V3MusicPulse.currentBPM { return "正在听，约 \(Int(bpm.rounded())) BPM（估算）" }
            return "正在听"
        case .failed(let message): return message
        }
    }
}
