import SwiftUI
import AppKit
import Combine

// MARK: - Shared pieces

/// Playback position for the presentations below, read from the same clock
/// as the edge player. Each reader refreshes only itself, a few times a
/// second, and stops while playback is paused.
struct V3PlaybackFractionReader<Content: View>: View {
    let state: PlaybackState
    var interval: TimeInterval = 0.5
    @ViewBuilder let content: (Double) -> Content

    var body: some View {
        TimelineView(.animation(minimumInterval: interval, paused: !state.isPlaying)) { _ in
            content(Self.fraction(state))
        }
    }

    @MainActor
    static func fraction(_ state: PlaybackState) -> Double {
        let duration = state.currentTrack.duration
        guard duration.isFinite, duration > 0 else { return 0 }
        let position = state.presentationClock.playbackTime(at: ProcessInfo.processInfo.systemUptime)
        guard position.isFinite else { return 0 }
        return min(1, max(0, position / duration))
    }

    @MainActor
    static func position(_ state: PlaybackState) -> TimeInterval {
        fraction(state) * max(0, state.currentTrack.duration)
    }
}

@MainActor
private func v3CanSeek(_ state: PlaybackState) -> Bool {
    state.currentTrackIdentity != nil && state.canInteractWithPlayback
        && state.currentTrack.duration.isFinite && state.currentTrack.duration > 0
}

/// A small cover that shows the cover's own image, never a placeholder box
/// that jumps when the image arrives.
private struct V3MiniCover: View {
    let track: Track
    let size: CGFloat
    var radius: CGFloat = 0.12
    var body: some View {
        ArtworkView(track: track, size: size, showsAlbumLabel: false, cornerRadiusRatio: radius,
                    preservesCompleteArtwork: true)
            .frame(width: size, height: size)
    }
}

private struct V3ThinProgress: View {
    let fraction: Double
    var vertical = false
    var color: Color = .white
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: vertical ? .top : .leading) {
                Capsule().fill(Color.white.opacity(0.16))
                Capsule().fill(color.opacity(0.85))
                    .frame(width: vertical ? nil : geometry.size.width * fraction,
                           height: vertical ? geometry.size.height * fraction : nil)
            }
        }
    }
}

// MARK: - 光随歌曲

/// 换行呼吸 brightens the light a little at each new lyric line; 随曲推移
/// moves the light's colour from the cover's main colour to its second one
/// over the song. Neither moves while the system asks for less motion.
struct V3AmbientMotionLayer: View {
    let state: PlaybackState
    let motion: V3AmbientLyricMotion
    let artworkURL: URL?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var palette = BackdropPalette.neutral
    @State private var flash = 0.0
    @State private var flashTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            switch motion {
            case .pulse:
                RadialGradient(colors: [color(palette.glow).opacity(0.30 * flash), .clear],
                               center: UnitPoint(x: 0.32, y: 0.42), startRadius: 10, endRadius: 760)
                    .blendMode(.screen)
            case .drift:
                V3PlaybackFractionReader(state: state, interval: 2) { fraction in
                    LinearGradient(colors: [mixed(fraction).opacity(0.26), mixed(min(1, fraction + 0.25)).opacity(0.10)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                        .blendMode(.overlay)
                        .animation(.easeInOut(duration: 2), value: fraction)
                }
            case .off:
                EmptyView()
            }
        }
        .allowsHitTesting(false)
        .task(id: artworkURL) {
            let next = await LyricIslandArtworkColors.palette(for: artworkURL)
            guard !Task.isCancelled else { return }
            palette = next
        }
        .onReceive(state.$liveCurrentLineIndex.removeDuplicates().dropFirst()) { _ in
            guard motion == .pulse, state.isPlaying, !reduceMotion else { return }
            flashTask?.cancel()
            withAnimation(.easeIn(duration: 0.18)) { flash = 1 }
            flashTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 1.2)) { flash = 0 }
            }
        }
        .onDisappear { flashTask?.cancel() }
    }

    private func color(_ value: BackdropColor) -> Color { Color(nsColor: value.nsColor) }

    private func mixed(_ fraction: Double) -> Color {
        let a = palette.primary, b = palette.secondary
        let t = reduceMotion ? 0 : fraction
        return Color(red: a.red + (b.red - a.red) * t, green: a.green + (b.green - a.green) * t,
                     blue: a.blue + (b.blue - a.blue) * t)
    }
}

// MARK: - The six presentations

/// Draws the playback presentation chosen in 画面 → 播放呈现 when it is one
/// of the 2026-11-12 additions. The scene hides its own player card for all
/// of them, and its cover for 侧脊, 唱片架, 角落 and 幕间.
struct V3PlaybackStyleOverlay: View {
    @V3ContentPlaybackState var state: PlaybackState
    @ObservedObject var settings: AppSettingsStore
    let presentation: V3PlaybackPresentation
    let cover: V3ForegroundCoverFrame?
    let accent: Color?

    var body: some View {
        GeometryReader { geometry in
            switch presentation {
            case .spine: V3SpinePresentation(state: state, accent: accent ?? .white, canvas: geometry.size)
            case .corner: V3CornerPresentation(state: state, settings: settings, accent: accent ?? .white, canvas: geometry.size)
            case .shelf: V3ShelfPresentation(state: state, browser: state.playlistBrowser, accent: accent ?? .white)
            case .interlude: V3InterludePresentation(state: state, browser: state.playlistBrowser)
            case .coverProgress:
                if let cover, cover.isLargeEnough {
                    V3CoverProgressPresentation(state: state, cover: cover)
                }
            case .vinyl:
                if let cover, cover.isLargeEnough {
                    V3VinylControl(state: state, cover: cover.frame)
                }
            default: EmptyView()
            }
        }
    }
}

/// 侧脊: a narrow spine at the window's left edge, like the spine of a
/// record sleeve. Coming near opens it into the full card.
private struct V3SpinePresentation: View {
    let state: PlaybackState
    let accent: Color
    let canvas: CGSize
    @State private var open = false
    @State private var closeTask: Task<Void, Never>?

    var body: some View {
        let top: CGFloat = 70
        let height = max(160, canvas.height - top - 28)
        ZStack(alignment: .topLeading) {
            if open {
                VStack(alignment: .leading, spacing: 14) {
                    V3MiniCover(track: state.currentTrack, size: 252, radius: 0.04)
                    TrackMetadataView(track: state.currentTrack, titleSize: 20, alignment: .leading, presentation: .v3Immersive)
                    AppleMusicImmersiveV3TransportControls(state: state, alignment: .leading,
                                                           progressDensity: .small, progressMaxWidth: nil)
                }
                .frame(width: 252)
                .padding(16)
                .modifier(V3ControlBarSurface())
                .transition(.opacity.combined(with: .move(edge: .leading)))
            } else {
                VStack(spacing: 12) {
                    V3MiniCover(track: state.currentTrack, size: 30, radius: 0.1)
                    Text(state.currentTrack.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize()
                        .rotationEffect(.degrees(90))
                        .frame(width: 20, height: max(40, height - 120))
                        .clipped()
                    V3PlaybackFractionReader(state: state, interval: 1) { fraction in
                        V3ThinProgress(fraction: fraction, vertical: true, color: accent)
                    }
                    .frame(width: 3, height: 48)
                }
                .padding(.vertical, 12)
                .frame(width: 44, height: height)
                .modifier(V3ControlBarSurface())
                .transition(.opacity)
            }
        }
        .padding(.leading, 12)
        .padding(.top, top)
        .onHover { inside in
            closeTask?.cancel()
            if inside {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { open = true }
            } else {
                closeTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(600))
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeOut(duration: 0.24)) { open = false }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// 角落: a small record card in one corner. Drag it to another corner.
private struct V3CornerPresentation: View {
    let state: PlaybackState
    @ObservedObject var settings: AppSettingsStore
    let accent: Color
    let canvas: CGSize
    @State private var drag = CGSize.zero
    @State private var hovering = false

    private var alignment: Alignment {
        switch settings.v3CornerCardCorner {
        case "topLeading": return .topLeading
        case "topTrailing": return .topTrailing
        case "bottomLeading": return .bottomLeading
        default: return .bottomTrailing
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                V3MiniCover(track: state.currentTrack, size: 52, radius: 0.1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.currentTrack.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(state.currentTrack.artist).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            V3PlaybackButtons(state: state, compact: true)
            V3PlaybackFractionReader(state: state, interval: 1) { fraction in
                V3ThinProgress(fraction: fraction, color: accent)
            }
            .frame(height: 3)
        }
        .padding(12)
        .frame(width: 292)
        .modifier(V3ControlBarSurface())
        .opacity(hovering ? 1 : 0.82)
        .offset(drag)
        .onHover { hovering = $0 }
        .gesture(DragGesture(minimumDistance: 6)
            .onChanged { drag = $0.translation }
            .onEnded { value in
                // The corner nearest to where the card was let go.
                let x = (alignment == .topLeading || alignment == .bottomLeading ? 0 : canvas.width) + value.translation.width
                let y = (alignment == .topLeading || alignment == .topTrailing ? 0 : canvas.height) + value.translation.height
                let left = x < canvas.width / 2, top = y < canvas.height / 2
                withAnimation(.spring(response: 0.34, dampingFraction: 0.84)) {
                    settings.v3CornerCardCorner = (top ? "top" : "bottom") + (left ? "Leading" : "Trailing")
                    drag = .zero
                }
            })
        .padding(.horizontal, 20)
        .padding(.top, 72)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        .help("拖到其他角落")
    }
}

/// 唱片架: the previous, current and next covers along the bottom. Click a
/// side cover to change song, the middle one to pause or play.
private struct V3ShelfPresentation: View {
    let state: PlaybackState
    @ObservedObject var browser: PlaylistBrowserModel
    let accent: Color
    @State private var previous: Track?
    @State private var lastTrack: Track?

    var body: some View {
        let upcoming = Array(browser.queue.prefix(2))
        HStack(alignment: .center, spacing: 14) {
            sideCover(previous, size: 40, label: "上一首") { state.previousTrack() }
            Button { state.togglePlayPause() } label: {
                V3MiniCover(track: state.currentTrack, size: 60, radius: 0.08)
                    .overlay {
                        Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                            .shadow(radius: 4).opacity(0.0)
                    }
            }
            .buttonStyle(.plain).help(state.isPlaying ? "暂停" : "播放")
            VStack(alignment: .leading, spacing: 4) {
                Text(state.currentTrack.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(state.currentTrack.artist).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                V3PlaybackFractionReader(state: state, interval: 1) { fraction in
                    V3ThinProgress(fraction: fraction, color: accent)
                }
                .frame(height: 3).padding(.top, 4)
            }
            .frame(width: 170, alignment: .leading)
            sideCover(upcoming.first, size: 40, label: "下一首") { state.nextTrack() }
            if upcoming.count > 1 {
                V3MiniCover(track: upcoming[1], size: 30, radius: 0.12).opacity(0.55)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .modifier(V3ControlBarSurface())
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 22)
        .onAppear {
            lastTrack = state.currentTrack
            if !browser.hasLoadedQueue { browser.loadQueue() }
        }
        .onChange(of: state.currentTrack.id) { _, _ in
            if let lastTrack, lastTrack.id != state.currentTrack.id { previous = lastTrack }
            lastTrack = state.currentTrack
            browser.loadQueue()
        }
    }

    @ViewBuilder
    private func sideCover(_ track: Track?, size: CGFloat, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if let track {
                V3MiniCover(track: track, size: size, radius: 0.12).opacity(0.8)
            } else {
                RoundedRectangle(cornerRadius: size * 0.12).fill(Color.white.opacity(0.08))
                    .frame(width: size, height: size)
                    .overlay(Image(systemName: label == "上一首" ? "backward.fill" : "forward.fill")
                        .font(.system(size: 11)).foregroundStyle(.secondary))
            }
        }
        .buttonStyle(.plain)
        .disabled(!state.canControlSpotify)
        .help(track.map { label + "：" + $0.title } ?? label)
    }
}

/// 幕间: nothing while the song plays. Its name appears for the first eight
/// seconds, and the next song for the last fifteen.
private struct V3InterludePresentation: View {
    let state: PlaybackState
    @ObservedObject var browser: PlaylistBrowserModel

    var body: some View {
        V3PlaybackFractionReader(state: state, interval: 0.5) { fraction in
            let position = fraction * max(0, state.currentTrack.duration)
            let remaining = max(0, state.currentTrack.duration - position)
            let next = browser.queue.first
            ZStack(alignment: .bottom) {
                if position < 8 {
                    card(caption: nil, track: state.currentTrack, coverSize: 64, titleSize: 20)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                } else if remaining < 15, let next {
                    card(caption: "下一首", track: next, coverSize: 44, titleSize: 15)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .animation(.easeInOut(duration: 0.6), value: position < 8)
            .animation(.easeInOut(duration: 0.6), value: remaining < 15)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, 34)
        }
        .onAppear { if !browser.hasLoadedQueue { browser.loadQueue() } }
        .onChange(of: state.currentTrack.id) { _, _ in browser.loadQueue() }
    }

    private func card(caption: String?, track: Track, coverSize: CGFloat, titleSize: CGFloat) -> some View {
        HStack(spacing: 14) {
            V3MiniCover(track: track, size: coverSize, radius: 0.08)
            VStack(alignment: .leading, spacing: 3) {
                if let caption {
                    Text(caption).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                }
                Text(track.title).font(.system(size: titleSize, weight: .semibold)).lineLimit(1)
                Text(track.artist).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .modifier(V3ControlBarSurface())
        .allowsHitTesting(false)
    }
}

/// 封面进度: the part of the cover not yet played is grey; colour fills in
/// from the left as the song plays. Click or drag on the cover to seek.
private struct V3CoverProgressPresentation: View {
    let state: PlaybackState
    let cover: V3ForegroundCoverFrame
    @State private var draft: Double?
    @State private var hover: Double?

    var body: some View {
        let rect = cover.frame
        V3PlaybackFractionReader(state: state, interval: 0.5) { live in
            let fraction = draft ?? live
            ZStack(alignment: .leading) {
                // Unplayed part: the cover's colour is taken out, not dimmed.
                Rectangle()
                    .fill(Color(white: 0.5))
                    .frame(width: rect.width * (1 - fraction))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .blendMode(.saturation)
                Rectangle()
                    .fill(Color.black.opacity(0.18))
                    .frame(width: rect.width * (1 - fraction))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                Rectangle()
                    .fill(Color.white.opacity(0.85))
                    .frame(width: 2)
                    .offset(x: rect.width * fraction - 1)
                    .shadow(color: .white.opacity(0.6), radius: 4)
                if let hover {
                    Text(v3EdgeTimeText(hover * state.currentTrack.duration))
                        .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .modifier(V3ControlBarSurface())
                        .position(x: rect.width * hover, y: rect.height - 18)
                }
            }
            .animation(.linear(duration: 0.5), value: draft == nil ? live : fraction)
            .frame(width: rect.width, height: rect.height)
            .clipShape(RoundedRectangle(cornerRadius: cover.cornerRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: cover.cornerRadius, style: .continuous))
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hover = min(1, max(0, point.x / rect.width))
                case .ended: hover = nil
                }
            }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard v3CanSeek(state) else { return }
                    draft = min(1, max(0, value.location.x / rect.width))
                    hover = draft
                }
                .onEnded { value in
                    defer { draft = nil }
                    guard v3CanSeek(state) else { return }
                    let target = min(1, max(0, value.location.x / rect.width))
                    state.seek(to: target * state.currentTrack.duration, source: "v3-cover-progress")
                })
            .accessibilityElement()
            .accessibilityLabel("播放进度")
            .accessibilityValue("\(Int(fraction * 100))%")
        }
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
    }
}

// MARK: - 黑胶

/// The record behind the cover. It turns while the song plays and stops
/// when it pauses; its outer ring is the progress. Drawn under the scene so
/// the cover sits in front of it.
struct V3VinylDiscLayer: View {
    let state: PlaybackState
    let cover: CGRect
    let accent: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func discFrame(for cover: CGRect) -> CGRect {
        let diameter = cover.height * 0.94
        let center = CGPoint(x: cover.midX + cover.width * 0.24, y: cover.midY)
        return CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter)
    }

    var body: some View {
        let disc = Self.discFrame(for: cover)
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !state.isPlaying || reduceMotion)) { context in
            let angle = Angle.degrees((context.date.timeIntervalSinceReferenceDate * 48).truncatingRemainder(dividingBy: 360))
            ZStack {
                Circle().fill(RadialGradient(colors: [Color(white: 0.16), Color(white: 0.05)],
                                             center: .center, startRadius: 0, endRadius: disc.width / 2))
                ForEach(0..<9, id: \.self) { ring in
                    Circle()
                        .stroke(Color.white.opacity(ring % 2 == 0 ? 0.05 : 0.025), lineWidth: 1)
                        .padding(disc.width * (0.06 + Double(ring) * 0.035))
                }
                // A soft sheen that stays still while the record turns.
                Circle().fill(AngularGradient(colors: [.clear, .white.opacity(0.10), .clear, .white.opacity(0.06), .clear],
                                              center: .center))
                    .rotationEffect(-angle)
                ArtworkView(track: state.currentTrack, size: disc.width * 0.36, showsAlbumLabel: false,
                            cornerRadiusRatio: 0.5, preservesCompleteArtwork: false)
                    .clipShape(Circle())
                Circle().fill(Color.black).frame(width: disc.width * 0.035, height: disc.width * 0.035)
            }
            .rotationEffect(angle)
            .frame(width: disc.width, height: disc.height)
            .overlay {
                V3PlaybackFractionReader(state: state, interval: 1) { fraction in
                    Circle()
                        .trim(from: 0, to: fraction)
                        .stroke(accent.opacity(0.9), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .padding(-5)
                }
            }
            .shadow(color: .black.opacity(0.35), radius: 16, x: 6, y: 8)
            .position(x: disc.midX, y: disc.midY)
        }
        .allowsHitTesting(false)
    }
}

/// The visible part of the record pauses or plays on a click.
private struct V3VinylControl: View {
    let state: PlaybackState
    let cover: CGRect

    var body: some View {
        let disc = V3VinylDiscLayer.discFrame(for: cover)
        let shape = V3CrescentShape(disc: disc, cover: cover)
        shape
            .fill(Color.clear, style: FillStyle(eoFill: true))
            .contentShape(shape, eoFill: true)
            .onTapGesture { state.togglePlayPause() }
            .help(state.isPlaying ? "暂停" : "播放")
            .accessibilityLabel(state.isPlaying ? "暂停" : "播放")
            .accessibilityAddTraits(.isButton)
    }
}

private struct V3CrescentShape: Shape {
    let disc: CGRect
    let cover: CGRect
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addEllipse(in: disc)
        path.addRect(cover.intersection(disc))
        return path
    }
}


// MARK: - 播放栏 options

struct V3PlayerBarOptions: Equatable {
    var progress: V3ProgressStyle = .standard
    var buttonsOnHover = false
    var titleMarquee = false
    var progressOnCover = false
}

private struct V3PlayerBarOptionsKey: EnvironmentKey { static let defaultValue = V3PlayerBarOptions() }
extension EnvironmentValues {
    var v3PlayerBarOptions: V3PlayerBarOptions {
        get { self[V3PlayerBarOptionsKey.self] }
        set { self[V3PlayerBarOptionsKey.self] = newValue }
    }
}

/// 波形: bars whose height follows how much is sung in that part of the
/// song. Spotify gives no audio, so lyric density stands in for loudness;
/// a song without timed lyrics shows an even, gentle shape.
struct V3LyricWaveform: View {
    let lines: [LyricLine]
    let duration: Double
    let fraction: Double
    let accent: Color
    let height: CGFloat

    private static let count = 56

    private var levels: [Double] {
        var buckets = Array(repeating: 0.0, count: Self.count)
        guard duration > 0 else { return buckets.map { _ in 0.4 } }
        for line in lines where line.timestamp >= 0 && line.timestamp < duration {
            let index = min(Self.count - 1, Int(line.timestamp / duration * Double(Self.count)))
            buckets[index] += Double(line.originalText.count)
        }
        // Smooth over neighbours so single lines do not spike.
        let smooth = buckets.indices.map { i in
            (buckets[max(0, i - 1)] + buckets[i] * 2 + buckets[min(Self.count - 1, i + 1)]) / 4
        }
        let peak = max(1, smooth.max() ?? 1)
        return smooth.enumerated().map { index, value in
            value == 0 ? 0.22 + 0.06 * sin(Double(index)) : 0.28 + 0.72 * value / peak
        }
    }

    var body: some View {
        let values = levels
        GeometryReader { geometry in
            let step = geometry.size.width / CGFloat(Self.count)
            HStack(alignment: .center, spacing: max(1, step * 0.35)) {
                ForEach(values.indices, id: \.self) { index in
                    Capsule()
                        .fill(Double(index) / Double(Self.count) < fraction ? accent.opacity(0.92) : Color.white.opacity(0.26))
                        .frame(height: max(3, height * values[index]))
                }
            }
            .frame(width: geometry.size.width, height: height)
        }
        .frame(height: height)
        .allowsHitTesting(false)
    }
}

/// 进度贴封面: the progress is a thin glowing line along the cover's
/// bottom edge; the card under the cover keeps the buttons.
struct V3CoverEdgeProgress: View {
    let state: PlaybackState
    let cover: V3ForegroundCoverFrame
    let accent: Color

    var body: some View {
        let rect = cover.frame
        V3PlaybackFractionReader(state: state, interval: 0.5) { fraction in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.22))
                Capsule().fill(accent)
                    .frame(width: max(3, (rect.width - 24) * fraction))
                    .shadow(color: accent.opacity(0.8), radius: 6)
            }
            .frame(width: rect.width - 24, height: 3)
            .animation(.linear(duration: 0.5), value: fraction)
        }
        .position(x: rect.midX, y: rect.maxY - 12)
        .allowsHitTesting(false)
    }
}

/// 长歌名滚动: a title wider than its room scrolls slowly back and forth.
struct V3MarqueeTitle: View {
    let text: String
    let font: Font
    @State private var textWidth: CGFloat = 0
    @State private var boxWidth: CGFloat = 0
    @State private var shifted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let overflow = max(0, textWidth - boxWidth)
        Text(text).font(font).lineLimit(1).fixedSize()
            .background(GeometryReader { proxy in Color.clear.onAppear { textWidth = proxy.size.width }
                .onChange(of: proxy.size.width) { _, width in textWidth = width } })
            .offset(x: shifted ? -overflow : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GeometryReader { proxy in Color.clear.onAppear { boxWidth = proxy.size.width }
                .onChange(of: proxy.size.width) { _, width in boxWidth = width } })
            .clipped()
            .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: overflow > 0 ? 0.92 : 1),
                                         .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing))
            .onChange(of: overflow > 0) { _, scrolls in start(scrolls, overflow: overflow) }
            .onChange(of: text) { _, _ in shifted = false }
            .onAppear { start(overflow > 0, overflow: overflow) }
    }

    private func start(_ scrolls: Bool, overflow: CGFloat) {
        guard scrolls, !reduceMotion else { shifted = false; return }
        withAnimation(.linear(duration: Double(overflow) / 28).delay(1.5).repeatForever(autoreverses: true)) {
            shifted = true
        }
    }
}

private struct V3MarqueeEnabledKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var v3TitleMarquee: Bool {
        get { self[V3MarqueeEnabledKey.self] }
        set { self[V3MarqueeEnabledKey.self] = newValue }
    }
}
