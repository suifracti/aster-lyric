import SwiftUI

/// 雨夜房间 (A13, after Tauon's room): the listening view drawn smaller, as
/// the screen of a monitor on a desk in a dark room, rain on the window
/// behind it and a lamp to one side. Layout and hit-testing inside the screen
/// are unchanged — the view is only drawn smaller — and turning it off zooms
/// back without rebuilding anything.
struct V3RainRoomModifier: ViewModifier {
    let enabled: Bool
    let playing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let screenScale: CGFloat = 0.62
    /// The screen's centre, as a share of the window height.
    static let screenCenterY: CGFloat = 0.44

    func body(content: Content) -> some View {
        GeometryReader { geometry in
            let size = geometry.size
            let scale = enabled ? Self.screenScale : 1
            let lift = enabled ? size.height * (0.5 - Self.screenCenterY) : 0
            ZStack {
                if enabled {
                    V3RainRoomScene(size: size, playing: playing)
                        .transition(.opacity)
                }
                content
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: enabled ? 14 : 0, style: .continuous))
                    .scaleEffect(scale)
                    .offset(y: -lift)
                if enabled {
                    // The bezel, over the screen's edge.
                    RoundedRectangle(cornerRadius: 14 * scale + 10, style: .continuous)
                        .strokeBorder(Color(white: 0.05), lineWidth: 12)
                        .frame(width: size.width * scale + 22, height: size.height * scale + 22)
                        .offset(y: -lift)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.7, dampingFraction: 0.9), value: enabled)
        }
    }
}

private struct V3RainRoomScene: View {
    let size: CGSize
    let playing: Bool

    var body: some View {
        let w = size.width, h = size.height
        let window = CGRect(x: w * 0.07, y: h * 0.05, width: w * 0.86, height: h * 0.56)
        let screenBottom = h * (V3RainRoomModifier.screenCenterY + V3RainRoomModifier.screenScale / 2)
        ZStack(alignment: .topLeading) {
            // The wall.
            LinearGradient(colors: [Color(red: 0.06, green: 0.07, blue: 0.11), Color(red: 0.02, green: 0.02, blue: 0.04)],
                           startPoint: .top, endPoint: .bottom)
            // The window: night outside, a few far lights, rain on the glass.
            ZStack {
                LinearGradient(colors: [Color(red: 0.08, green: 0.1, blue: 0.18), Color(red: 0.14, green: 0.12, blue: 0.2)],
                               startPoint: .top, endPoint: .bottom)
                Canvas { ctx, canvas in
                    var generator = SeededRandom(seed: 7)
                    for _ in 0..<46 {
                        let x = generator.next() * canvas.width
                        let y = canvas.height * (0.55 + 0.45 * generator.next())
                        let r = 2 + 5 * generator.next()
                        let warm = generator.next() > 0.35
                        let color = warm ? Color(red: 1, green: 0.78, blue: 0.45) : Color(red: 0.6, green: 0.75, blue: 1)
                        ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                                 with: .color(color.opacity(0.35 + 0.4 * generator.next())))
                    }
                }
                .blur(radius: 5)
                V3ParticleView(kind: .rain, running: playing)
            }
            .frame(width: window.width, height: window.height)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay {
                // Frame and mullions.
                ZStack {
                    RoundedRectangle(cornerRadius: 4).strokeBorder(Color(white: 0.12), lineWidth: 10)
                    Rectangle().fill(Color(white: 0.12)).frame(width: 8)
                    Rectangle().fill(Color(white: 0.12)).frame(height: 8)
                }
            }
            .offset(x: window.minX, y: window.minY)
            // The desk.
            LinearGradient(colors: [Color(red: 0.2, green: 0.13, blue: 0.09), Color(red: 0.09, green: 0.06, blue: 0.05)],
                           startPoint: .top, endPoint: .bottom)
                .frame(width: w, height: h - screenBottom - 22)
                .offset(y: screenBottom + 22)
            // The monitor's stand.
            Path { path in
                let cx = w / 2
                path.move(to: CGPoint(x: cx - 18, y: screenBottom + 10))
                path.addLine(to: CGPoint(x: cx + 18, y: screenBottom + 10))
                path.addLine(to: CGPoint(x: cx + 26, y: screenBottom + 30))
                path.addLine(to: CGPoint(x: cx - 26, y: screenBottom + 30))
                path.closeSubpath()
            }
            .fill(Color(white: 0.08))
            Capsule().fill(Color(white: 0.07))
                .frame(width: 150, height: 9)
                .offset(x: w / 2 - 75, y: screenBottom + 27)
            // The lamp's warm light from the right.
            RadialGradient(colors: [Color(red: 1, green: 0.72, blue: 0.4).opacity(0.32), .clear],
                           center: UnitPoint(x: 0.92, y: 0.78), startRadius: 4, endRadius: max(w, h) * 0.45)
                .blendMode(.screen)
        }
        .frame(width: w, height: h)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The far lights stay put from frame to frame.
private struct SeededRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 | 1 }
    mutating func next() -> CGFloat {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return CGFloat(state % 10_000) / 10_000
    }
}
