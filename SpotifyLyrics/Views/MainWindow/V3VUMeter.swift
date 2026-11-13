import SwiftUI

/// VU 表: a two-needle meter card at the bottom left. The needles follow the
/// low and the high band of 随音乐律动 (Spotify's sound is not split into
/// left and right here, so they are labelled 低 / 高, not L / R).
/// Each needle is a damped spring (ζ 0.8, ω 16.7): it reaches a new reading
/// in about 0.3 s and overshoots by about 1.5 %, like a real VU movement.
struct V3VUMeterPresentation: View {
    let state: PlaybackState
    @ObservedObject var settings: AppSettingsStore
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            V3VUMeterFace(running: state.isPlaying && settings.v3MusicMotionEnabled, accent: accent)
                .frame(height: 92)
            HStack(spacing: 10) {
                V3MiniCoverForVU(track: state.currentTrack)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.currentTrack.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(state.currentTrack.artist).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            V3PlaybackButtons(state: state, compact: true)
            if !settings.v3MusicMotionEnabled {
                Text("打开「随音乐律动」后指针才会动")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            } else if state.isPlaying, V3MusicPulse.hearsSilence {
                Text("没有听到声音：Spotify 自己的音量是 0 吗？")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(width: 292)
        .background(V3PlaybackSurface(cornerRadius: 16))
        .environment(\.colorScheme, .dark)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .padding(.leading, 24).padding(.bottom, 24)
    }
}

private struct V3MiniCoverForVU: View {
    let track: Track
    var body: some View {
        ArtworkView(track: track, size: 40, showsAlbumLabel: false, cornerRadiusRatio: 0.1)
    }
}

/// The needle physics lives in a reference object so the 30 fps redraw does
/// not churn SwiftUI state.
final class V3VUNeedles {
    var position = [0.0, 0.0]
    var velocity = [0.0, 0.0]
    var lastTime: TimeInterval?

    func step(targets: [Double], now: TimeInterval) {
        let dt = min(0.05, max(0, now - (lastTime ?? now)))
        lastTime = now
        let omega = 16.7, zeta = 0.8
        for i in 0..<2 {
            // Semi-implicit Euler, two sub-steps for stability at 30 fps.
            for _ in 0..<2 {
                let h = dt / 2
                let accel = omega * omega * (targets[i] - position[i]) - 2 * zeta * omega * velocity[i]
                velocity[i] += accel * h
                position[i] += velocity[i] * h
            }
        }
    }
}

struct V3VUMeterFace: View {
    let running: Bool
    let accent: Color
    @State private var needles = V3VUNeedles()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// A self-normalised band level (1 = the song's own average) as a needle
    /// position 0…1; the song's average reads at about −3 on the scale.
    static func reading(_ ratio: Double) -> Double {
        min(1.04, max(0, 0.6 + 0.24 * log2(max(0.05, ratio))))
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !running || reduceMotion)) { context in
            Canvas { ctx, size in
                let levels = V3MusicPulse.levels
                let fresh = running && ProcessInfo.processInfo.systemUptime - levels.updatedAt < 1
                let targets = fresh ? [Self.reading((levels.bass + levels.mid) / 2),
                                       Self.reading((levels.mid + levels.treble) / 2)] : [0, 0]
                needles.step(targets: targets, now: context.date.timeIntervalSinceReferenceDate)
                let half = CGSize(width: (size.width - 10) / 2, height: size.height)
                for i in 0..<2 {
                    let origin = CGPoint(x: CGFloat(i) * (half.width + 10), y: 0)
                    drawDial(&ctx, in: CGRect(origin: origin, size: half), value: needles.position[i], label: i == 0 ? "低" : "高")
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("VU 表")
        .accessibilityValue(running ? "随音乐摆动" : "静止")
    }

    private func drawDial(_ ctx: inout GraphicsContext, in rect: CGRect, value: Double, label: String) {
        let face = Path(roundedRect: rect, cornerRadius: 8)
        ctx.fill(face, with: .color(Color(red: 0.98, green: 0.93, blue: 0.8).opacity(0.92)))
        let pivot = CGPoint(x: rect.midX, y: rect.maxY + rect.height * 0.32)
        let radius = rect.height * 1.02
        let sweep = 0.78 // radians either side of vertical
        func angle(_ v: Double) -> Double { -Double.pi / 2 - sweep + 2 * sweep * v }
        func point(_ v: Double, _ r: CGFloat) -> CGPoint {
            CGPoint(x: pivot.x + r * CGFloat(cos(angle(v))), y: pivot.y + r * CGFloat(sin(angle(v))))
        }
        // Scale: black to 0 VU (at 0.8), red above.
        var black = Path(); var red = Path()
        black.addArc(center: pivot, radius: radius * 0.86, startAngle: .radians(angle(0)), endAngle: .radians(angle(0.8)), clockwise: false)
        red.addArc(center: pivot, radius: radius * 0.86, startAngle: .radians(angle(0.8)), endAngle: .radians(angle(1)), clockwise: false)
        ctx.stroke(black, with: .color(.black.opacity(0.75)), lineWidth: 1.2)
        ctx.stroke(red, with: .color(Color(red: 0.8, green: 0.12, blue: 0.1)), lineWidth: 3)
        for tick in stride(from: 0.0, through: 1.0, by: 0.1) {
            var t = Path()
            t.move(to: point(tick, radius * 0.86))
            t.addLine(to: point(tick, radius * (tick.truncatingRemainder(dividingBy: 0.2) < 0.01 ? 0.78 : 0.81)))
            ctx.stroke(t, with: .color(tick > 0.8 ? Color(red: 0.8, green: 0.12, blue: 0.1) : .black.opacity(0.7)), lineWidth: 1)
        }
        ctx.draw(Text("VU").font(.system(size: 10, weight: .semibold, design: .serif)).foregroundColor(.black.opacity(0.7)),
                 at: CGPoint(x: rect.midX, y: rect.maxY - 18))
        ctx.draw(Text(label).font(.system(size: 9, weight: .medium)).foregroundColor(.black.opacity(0.55)),
                 at: CGPoint(x: rect.minX + 12, y: rect.minY + 11))
        // The needle, clipped to the face.
        ctx.drawLayer { layer in
            layer.clip(to: face)
            var needle = Path()
            needle.move(to: pivot)
            needle.addLine(to: point(min(1.04, max(-0.02, value)), radius * 0.95))
            layer.stroke(needle, with: .color(.black.opacity(0.85)), lineWidth: 1.4)
        }
        ctx.stroke(face, with: .color(accent.opacity(0.35)), lineWidth: 1)
    }
}
