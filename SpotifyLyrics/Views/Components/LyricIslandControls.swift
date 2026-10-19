import AppKit
import SwiftUI

/// One interaction for numbers throughout the app. Playback seek bars do not use this.
/// Text editing commits once, clamps to a finite range, and never writes a partial string.
struct V3NumericSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0.01
    var unit: String = ""
    var displayScale: Double = 1
    var onEditingChanged: (Bool) -> Void = { _ in }
    @State private var draft = ""
    @FocusState private var editing: Bool

    init(value: Binding<Double>, in range: ClosedRange<Double>, step: Double = 0.01,
         unit: String = "", displayScale: Double = 1,
         onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        _value = value; self.range = range; self.step = step; self.unit = unit
        self.displayScale = displayScale; self.onEditingChanged = onEditingChanged
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Slider(value: $value, in: range, step: step, onEditingChanged: onEditingChanged)
            HStack(spacing: 6) {
                Text(formatted(range.lowerBound) + " — " + formatted(range.upperBound))
                    .font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                TextField("数值", text: $draft)
                    .font(.system(size: 11).monospacedDigit())
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 66)
                    .focused($editing)
                    .onSubmit { commit(); editing = false }
                    .onChange(of: editing) { _, active in
                        if !active { commit() }
                        onEditingChanged(active)
                    }
                    .accessibilityLabel(unit.isEmpty ? "精确数值" : "精确数值（\(unit)）")
                if !unit.isEmpty { Text(unit).font(.system(size: 10)).foregroundStyle(.secondary) }
            }
        }
        .onAppear { draft = formatted(value) }
        .onChange(of: value) { _, next in if !editing { draft = formatted(next) } }
    }

    private func formatted(_ number: Double) -> String {
        // Foundation's value-style formatting reuses its internals instead of
        // allocating several NumberFormatters on every slider redraw.
        let digits = step * displayScale >= 1 ? 0 : 2
        return (number * displayScale).formatted(.number.grouping(.never)
            .precision(.fractionLength(0...digits)))
    }
    private func commit() {
        let separator = Locale.current.decimalSeparator ?? "."
        let input = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: separator, with: ".")
        // Consume the whole string: "12oops" must not commit a partial 12.
        let number = Double(input)
        guard let number, number.isFinite, displayScale.isFinite, displayScale > 0 else {
            draft = formatted(value); return
        }
        let candidate = number / displayScale
        let bounded = min(range.upperBound, max(range.lowerBound, candidate))
        let snapped = step.isFinite && step > 0
            ? range.lowerBound + ((bounded - range.lowerBound) / step).rounded() * step : bounded
        let next = min(range.upperBound, max(range.lowerBound, snapped))
        if next != value { value = next }
        draft = formatted(next)
    }
}

/// Shares the existing, once-per-cover sampler with all listening surfaces.
/// Nothing here is called from a TimelineView or from a lyric row.
@MainActor
enum LyricIslandArtworkColors {
    private static var palettes: [URL: BackdropPalette] = [:]
    private static var order: [URL] = []
    private static var inFlight: [URL: Task<BackdropPalette, Never>] = [:]

    static func palette(for url: URL?) async -> BackdropPalette {
        guard let url else { return .neutral }
        if let value = palettes[url] { return value }
        if let task = inFlight[url] { return await task.value }
        let task = Task<BackdropPalette, Never> {
            let key = AppleMusicImmersiveV3BackdropKey.make(artworkURL: url)
            if let cached = await AppleMusicImmersiveV3BackdropCache.shared.cachedPalette(for: key) { return cached }
            guard let image = await ArtworkImageLoader.shared.image(for: url),
                  let data = image.tiffRepresentation else { return .neutral }
            return await AppleMusicImmersiveV3BackdropCache.shared.snapshot(for: key, artworkData: data).palette
        }
        inFlight[url] = task
        let value = await task.value
        inFlight[url] = nil
        palettes[url] = value
        order.removeAll { $0 == url }; order.append(url)
        if order.count > 48 { palettes[order.removeFirst()] = nil }
        return value
    }

    static func edgeAccent(_ palette: BackdropPalette) -> Color {
        // A near-white/black album must still yield a visible, quiet progress line.
        let source = palette.saturation > 0.08 ? palette.primary : palette.glow
        let ns = source.nsColor.usingColorSpace(.sRGB) ?? NSColor.systemTeal
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        ns.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return Color(hue: Double(h), saturation: Double(min(0.70, max(0.22, s))),
                     brightness: Double(min(0.95, max(0.76, b))))
    }
}

private struct LyricIslandReadingProtection: ViewModifier {
    let artworkURL: URL?
    let policy: V3ReadingProtection
    @State private var luminance: Double = 0.14
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    private var opacity: Double {
        if policy == .off && contrast != .increased && !reduceTransparency { return 0 }
        if reduceTransparency { return 0.88 }
        if policy == .enhanced || contrast == .increased { return 0.64 }
        // Local reading field; no full-screen veil and no frame-by-frame sampling.
        return min(0.62, max(0.12, (luminance - 0.16) * 0.90 + 0.12))
    }
    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(Color.black.opacity(opacity))
                    .mask {
                        LinearGradient(stops: [.init(color: .clear, location: 0),
                                               .init(color: .white, location: 0.10),
                                               .init(color: .white, location: 0.90),
                                               .init(color: .clear, location: 1)],
                                       startPoint: .top, endPoint: .bottom)
                    }
                    .allowsHitTesting(false)
            }
            .task(id: artworkURL) {
                let next = await LyricIslandArtworkColors.palette(for: artworkURL).luminance
                guard !Task.isCancelled else { return }
                if luminance != next { luminance = next }
            }
    }
}

extension View {
    func lyricIslandReadingProtection(artworkURL: URL?, policy: V3ReadingProtection) -> some View {
        modifier(LyricIslandReadingProtection(artworkURL: artworkURL, policy: policy))
    }
}

/// Tiny *layout* previews, sharing one decoded cover. They do not mount five apps,
/// start timers, generate lyrics, or evaluate the actual background renderers.
struct LyricIslandSceneThumbnail: View {
    let scene: V3ListeningScene
    let image: NSImage?
    let accent: Color
    private var lines: some View {
        VStack(alignment: .leading, spacing: 5) {
            Capsule().fill(.white.opacity(0.88)).frame(height: 3)
            Capsule().fill(.white.opacity(0.46)).frame(height: 2).padding(.trailing, 5)
            Capsule().fill(.white.opacity(0.28)).frame(height: 2).padding(.trailing, 9)
        }
    }
    @ViewBuilder private var artwork: some View {
        if let image { Image(nsImage: image).resizable().scaledToFill() }
        else { Rectangle().fill(accent.opacity(0.45)).overlay(Image(systemName: "music.note").font(.caption)) }
    }
    var body: some View {
        GeometryReader { geometry in
            let w = geometry.size.width
            ZStack {
                LinearGradient(colors: [accent.opacity(0.40), .black.opacity(0.62)], startPoint: .topLeading, endPoint: .bottomTrailing)
                switch scene {
                case .originalAmbient:
                    HStack(spacing: 10) {
                        artwork.frame(width: w * 0.36, height: 44).clipShape(RoundedRectangle(cornerRadius: 4))
                        lines
                    }.padding(10)
                case .flowingField:
                    Circle().fill(accent.opacity(0.55)).frame(width: 72, height: 72).blur(radius: 14).offset(x: -24, y: 7)
                    Circle().fill(.white.opacity(0.10)).frame(width: 48, height: 48).blur(radius: 12).offset(x: 28, y: -12)
                    HStack(spacing: 12) {
                        artwork.frame(width: w * 0.30, height: 38).clipShape(RoundedRectangle(cornerRadius: 8))
                        lines
                    }.padding(12)
                case .coverPhoto:
                    artwork.frame(width: w, height: 72).clipped().opacity(0.70)
                    Color.black.opacity(0.24)
                    lines.frame(width: w * 0.44).padding(10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                case .linerNotes:
                    VStack(alignment: .leading, spacing: 8) {
                        Rectangle().fill(.white.opacity(0.60)).frame(width: w * 0.65, height: 2)
                        HStack(spacing: 10) {
                            artwork.frame(width: 28, height: 28).clipped()
                            VStack(spacing: 5) { lines; lines }
                        }
                    }.padding(12)
                case .focusedLyrics:
                    Color.black.opacity(0.38)
                    VStack(alignment: .leading, spacing: 8) { lines; lines }.padding(.horizontal, 28).padding(.vertical, 10)
                }
            }
        }
        .frame(height: 72)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .accessibilityHidden(true)
    }
}

// BEGIN EXTERNAL PANEL GEOMETRY
/// AppKit screen coordinates (points, bottom-left origin). Never changes the owner frame.
enum LyricIslandPanelPlacement {
    static func frame(owner: CGRect, visible: CGRect, requested: CGSize,
                      gap: CGFloat = 12) -> CGRect {
        guard visible.width > 0, visible.height > 0 else {
            return CGRect(origin: owner.origin, size: requested)
        }
        let margin: CGFloat = 8
        let width = min(max(280, requested.width), max(1, visible.width - margin * 2))
        let height = min(max(320, requested.height), max(1, visible.height - margin * 2))
        let right = owner.maxX + gap
        let left = owner.minX - gap - width
        let x: CGFloat
        if right + width <= visible.maxX - margin { x = right }
        else if left >= visible.minX + margin { x = left }
        else { x = min(visible.maxX - width - margin, max(visible.minX + margin, owner.maxX - width)) }
        let y = min(visible.maxY - height - margin, max(visible.minY + margin, owner.maxY - height))
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
/// Deterministic space budgets for the two document-like scenes. A hidden
/// player creates neither an empty footer nor its surrounding stack spacing.
/// No GeometryPreference feedback, runtime text measurement, or extra timers.
enum LyricIslandSceneBudget {
    static func fieldReadingHeight(canvasHeight: CGFloat, footerHeight: CGFloat) -> CGFloat {
        let footer = footerHeight > 0 ? footerHeight + 16 : 0
        return max(1, canvasHeight - 84 - 24 - 28 - 16 - footer)
    }
    static func linerReadingHeight(canvasHeight: CGFloat, headerHeight: CGFloat,
                                   footerHeight: CGFloat) -> CGFloat {
        let footer = footerHeight > 0 ? footerHeight + 18 : 0
        // 76/24 outer padding, header, 1pt rule, and two 18pt gaps.
        return max(1, canvasHeight - 76 - 24 - headerHeight - 1 - 36 - footer)
    }
}
// END EXTERNAL PANEL GEOMETRY

private struct LyricIslandSceneEnvironmentKey: EnvironmentKey {
    static let defaultValue: V3ListeningScene? = nil
}
private struct LyricIslandCompactToolsKey: EnvironmentKey {
    static let defaultValue = false
}
extension EnvironmentValues {
    var lyricIslandScene: V3ListeningScene? {
        get { self[LyricIslandSceneEnvironmentKey.self] }
        set { self[LyricIslandSceneEnvironmentKey.self] = newValue }
    }
    var lyricIslandCompactTools: Bool {
        get { self[LyricIslandCompactToolsKey.self] }
        set { self[LyricIslandCompactToolsKey.self] = newValue }
    }
}
struct LyricIslandToolbarLabelStyle: LabelStyle {
    @Environment(\.lyricIslandCompactTools) private var compact
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon
            if !compact { configuration.title }
        }
    }
}

/// Global settings uses the same finite scene mapping as the external inspector.
struct LyricIslandSceneSettingsPicker: View {
    @ObservedObject var settings: AppSettingsStore
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("听歌场景", selection: Binding(
                get: { settings.v3ListeningSceneRawValue },
                set: { value in
                    if let scene = V3ListeningScene(rawValue: value) { settings.selectV3Scene(scene) }
                }
            )) {
                if settings.v3ListeningScene == nil {
                    Text("旧预设 · " + settings.v3ArtworkPresentation.title).tag("")
                }
                ForEach(V3ListeningScene.allCases) { scene in Text(scene.title).tag(scene.rawValue) }
            }
            if let scene = settings.v3ListeningScene {
                Text(scene.detail).font(.caption).foregroundStyle(.secondary)
                if scene.renderers.count > 1 {
                    Picker("背景风格", selection: Binding(
                        get: { settings.v3ArtworkPresentation },
                        set: { settings.selectV3Scene(scene, renderer: $0) }
                    )) {
                        ForEach(scene.renderers) { style in Text(scene.rendererTitle(style)).tag(style) }
                    }
                }
            }
            Toggle("悬停预览场景", isOn: $settings.v3SceneHoverPreviewEnabled)
            DisclosureGroup("旧预设（保留原有设置）") {
                ForEach(V3ArtworkPresentation.allCases) { style in
                    Button(style.title) { settings.selectLegacyV3Presentation(style) }
                        .buttonStyle(.borderless)
                }
            }.font(.caption)
        }
    }
}
