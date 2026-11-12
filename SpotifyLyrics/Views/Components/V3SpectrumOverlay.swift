import SwiftUI

/// 频谱: the 24 bands of 随音乐律动 drawn in the song's colour — a thin
/// strip along the bottom (B9) or fanned around the foreground cover (B11).
public enum V3SpectrumStyle: String, CaseIterable, Identifiable, Sendable {
    case off = "", bottom, ring
    public var id: String { rawValue }
    public var title: String {
        switch self { case .off: return "关闭"; case .bottom: return "底部细条"; case .ring: return "环绕封面" }
    }
}

/// Bars rise at once and fall back slowly, like a meter, so the picture
/// reads as music rather than noise. Kept in a reference object so the
/// 30 fps redraw does not churn SwiftUI state.
final class V3SpectrumSmoother {
    private(set) var values: [Float] = []
    private var lastTime: TimeInterval?

    func step(_ target: [Float], now: TimeInterval) -> [Float] {
        let dt = Float(min(0.1, max(0, now - (lastTime ?? now))))
        lastTime = now
        if values.count != target.count { values = target.map { _ in 0 } }
        for i in values.indices {
            values[i] = target[i] > values[i] ? target[i] : max(target[i], values[i] - dt * 1.4)
        }
        return values
    }
}

struct V3SpectrumOverlay: View {
    let style: V3SpectrumStyle
    let running: Bool
    let accent: Color
    let cover: CGRect?
    @State private var smoother = V3SpectrumSmoother()
    @State private var visible = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if style != .off, !reduceMotion {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !running || !visible)) { context in
                Canvas { ctx, size in
                    let levels = V3MusicPulse.levels
                    let fresh = running && ProcessInfo.processInfo.systemUptime - levels.updatedAt < 1
                    let target = fresh ? levels.spectrum : levels.spectrum.map { _ in 0 }
                    let values = smoother.step(target.isEmpty ? Array(repeating: 0, count: 24) : target,
                                               now: context.date.timeIntervalSinceReferenceDate)
                    switch style {
                    case .bottom: drawBottom(&ctx, size: size, values: values)
                    case .ring: if let cover { drawRing(&ctx, cover: cover, values: values) }
                    case .off: break
                    }
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .background(alignment: .topLeading) {
                V3WindowVisibilityProbe(isVisible: $visible).frame(width: 0, height: 0)
            }
        }
    }

    private func drawBottom(_ ctx: inout GraphicsContext, size: CGSize, values: [Float]) {
        let count = values.count
        guard count > 0 else { return }
        let gap: CGFloat = 4
        let width = (size.width - gap * CGFloat(count + 1)) / CGFloat(count)
        let maxHeight: CGFloat = 34
        for (i, v) in values.enumerated() {
            let h = max(2, maxHeight * CGFloat(v))
            let rect = CGRect(x: gap + CGFloat(i) * (width + gap), y: size.height - 6 - h, width: width, height: h)
            ctx.fill(Path(roundedRect: rect, cornerRadius: min(3, width / 2)),
                     with: .linearGradient(Gradient(colors: [accent.opacity(0.6), accent.opacity(0.08)]),
                                           startPoint: CGPoint(x: rect.midX, y: rect.minY),
                                           endPoint: CGPoint(x: rect.midX, y: rect.maxY)))
        }
    }

    /// Low notes at the top centre, rising clockwise to the highs and back
    /// round on the other side, so the fan is symmetric. Bars stand out from
    /// a loop just outside the cover (the same loop as 声纹圈), so none starts
    /// inside the cover's corners.
    private func drawRing(_ ctx: inout GraphicsContext, cover: CGRect, values: [Float]) {
        let loop = cover.insetBy(dx: -12, dy: -12)
        let reach: CGFloat = 30
        let mirrored = values + values.reversed()
        let count = mirrored.count
        for (i, v) in mirrored.enumerated() {
            let (p, n) = V3SpectrumOverlay.loopPoint((Double(i) + 0.5) / Double(count), around: loop)
            let length = 3 + reach * CGFloat(v)
            var bar = Path()
            bar.move(to: p)
            bar.addLine(to: CGPoint(x: p.x + n.dx * length, y: p.y + n.dy * length))
            ctx.stroke(bar, with: .color(accent.opacity(0.35 + 0.5 * Double(v))),
                       style: StrokeStyle(lineWidth: 3, lineCap: .round))
        }
    }

    /// Same walk as `V3SoundprintRing.loopPoint`: top centre, clockwise.
    static func loopPoint(_ t: Double, around rect: CGRect) -> (point: CGPoint, normal: CGVector) {
        let w = Double(rect.width), h = Double(rect.height)
        var d = (t - floor(t)) * 2 * (w + h)
        if d < w / 2 { return (CGPoint(x: rect.midX + d, y: rect.minY), CGVector(dx: 0, dy: -1)) }
        d -= w / 2
        if d < h { return (CGPoint(x: rect.maxX, y: rect.minY + d), CGVector(dx: 1, dy: 0)) }
        d -= h
        if d < w { return (CGPoint(x: rect.maxX - d, y: rect.maxY), CGVector(dx: 0, dy: 1)) }
        d -= w
        if d < h { return (CGPoint(x: rect.minX, y: rect.maxY - d), CGVector(dx: -1, dy: 0)) }
        d -= h
        return (CGPoint(x: rect.minX + d, y: rect.minY), CGVector(dx: 0, dy: -1))
    }
}
