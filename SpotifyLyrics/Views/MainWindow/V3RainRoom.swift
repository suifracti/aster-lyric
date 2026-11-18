import SwiftUI

/// 房间 (A13, after Tauon's room, reworked 2026-11-18): the listening view seen
/// through a window inside a small scene. The first version drew it at 62% as a
/// monitor on a desk, which left the lyrics tiny. Now the listening view stays
/// close to full size and *is* the window glass: the room lives in a thin margin
/// (frame, wall, light) and on the glass (rain, frost, passing lights), never
/// under the pointer. Layout and hit-testing inside are unchanged, and switching
/// rooms only redraws the surroundings.
enum V3Room: String, CaseIterable, Identifiable, Sendable {
    case off = "", rain, train, snow, film
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: return "关闭"
        case .rain: return "雨夜窗边"
        case .train: return "夜行列车"
        case .snow: return "雪夜小屋"
        case .film: return "老电影"
        }
    }
    /// Rooms put the view behind a window; the others change the material it is shown on.
    var isRoom: Bool { self == .rain || self == .train || self == .snow }
    var detail: String {
        switch self {
        case .off: return "只有听歌画面"
        case .rain: return "画面是一扇夜里的木窗：雨顺着玻璃往下淌，台灯的暖光从右下角漫进来"
        case .train: return "画面是夜车的车窗：窗外的灯一串串掠过，每隔一会儿有一盏路灯扫过玻璃"
        case .snow: return "画面是雪夜小屋的窗：窗外落雪，玻璃四角结霜，炉火在下方轻轻跳动"
        case .film: return "画面放在一条胶片上：两侧齿孔，颗粒、偶尔的划痕和放映机的轻微闪烁"
        }
    }
}

struct V3RoomModifier: ViewModifier {
    let room: V3Room
    let playing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The margin the room takes around the glass, in points.
    static func margin(for size: CGSize) -> CGFloat {
        min(54, max(22, min(size.width, size.height) * 0.06))
    }

    /// The glass keeps 85–92% of the window, so lyrics stay readable.
    static func glass(in size: CGSize, room: V3Room) -> CGRect {
        guard room != .off, size.width > 0, size.height > 0 else { return CGRect(origin: .zero, size: size) }
        let m = margin(for: size)
        let side = room == .film ? max(m, 34) : m
        let top = room == .film ? m * 0.45 : m
        let bottom = room == .train ? m : room == .film ? m * 0.45 : m * 1.35
        let scale = min((size.width - 2 * side) / size.width, (size.height - top - bottom) / size.height)
        let width = size.width * scale, height = size.height * scale
        return CGRect(x: (size.width - width) / 2, y: top + (size.height - top - bottom - height) / 2, width: width, height: height)
    }

    static func cornerRadius(_ room: V3Room) -> CGFloat {
        switch room {
        case .off: return 0
        case .train: return 30
        case .rain, .snow: return 6
        case .film: return 3
        }
    }

    func body(content: Content) -> some View {
        GeometryReader { geometry in
            let size = geometry.size
            let glass = Self.glass(in: size, room: room)
            let scale = glass.width / max(1, size.width)
            let radius = Self.cornerRadius(room)
            ZStack(alignment: .topLeading) {
                V3RoomWall(room: room, size: size, glass: glass)
                content
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: radius / max(scale, 0.01), style: .continuous))
                    .scaleEffect(scale, anchor: .topLeading)
                    .offset(x: glass.minX, y: glass.minY)
                V3RoomGlass(room: room, playing: playing && !reduceMotion, glass: glass, radius: radius)
                V3RoomFrame(room: room, size: size, glass: glass, radius: radius)
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.6, dampingFraction: 0.92), value: room)
        }
    }
}

// MARK: - Wall: what is seen around the window

private struct V3RoomWall: View {
    let room: V3Room
    let size: CGSize
    let glass: CGRect

    var body: some View {
        ZStack {
            switch room {
            case .off:
                Color.clear
            case .rain:
                LinearGradient(colors: [Color(red: 0.10, green: 0.10, blue: 0.13), Color(red: 0.05, green: 0.045, blue: 0.05)],
                               startPoint: .top, endPoint: .bottom)
                // The lamp is just out of view at the lower right; its light pools on the wall.
                RadialGradient(colors: [Color(red: 1, green: 0.70, blue: 0.40).opacity(0.55), .clear],
                               center: UnitPoint(x: 1.02, y: 0.98), startRadius: 0, endRadius: max(size.width, size.height) * 0.55)
                // Cold light from the window spills a little onto the wall above it.
                RadialGradient(colors: [Color(red: 0.45, green: 0.58, blue: 0.85).opacity(0.18), .clear],
                               center: UnitPoint(x: 0.3, y: 0.0), startRadius: 0, endRadius: size.width * 0.5)
            case .train:
                LinearGradient(colors: [Color(red: 0.13, green: 0.14, blue: 0.17), Color(red: 0.07, green: 0.075, blue: 0.09)],
                               startPoint: .top, endPoint: .bottom)
                // The carriage's long ceiling light.
                LinearGradient(colors: [Color(red: 0.9, green: 0.92, blue: 1).opacity(0.14), .clear], startPoint: .top, endPoint: .init(x: 0.5, y: 0.08))
            case .snow:
                LinearGradient(colors: [Color(red: 0.20, green: 0.12, blue: 0.08), Color(red: 0.09, green: 0.055, blue: 0.04)],
                               startPoint: .top, endPoint: .bottom)
                // Log seams.
                Canvas { context, canvas in
                    var y: CGFloat = 0
                    while y < canvas.height {
                        context.fill(Path(CGRect(x: 0, y: y, width: canvas.width, height: 1)), with: .color(.black.opacity(0.35)))
                        context.fill(Path(CGRect(x: 0, y: y + 1, width: canvas.width, height: 1)), with: .color(.white.opacity(0.04)))
                        y += 26
                    }
                }
                V3Firelight(size: size)
            case .film:
                Color(red: 0.05, green: 0.04, blue: 0.03)
            }
        }
        .frame(width: size.width, height: size.height)
        .opacity(room == .off ? 0 : 1)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The fire is out of view below the window; only its moving light is seen.
private struct V3Firelight: View {
    let size: CGSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12.0, paused: reduceMotion)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let flicker = 0.42 + 0.08 * sin(t * 7.1) + 0.06 * sin(t * 12.7 + 1.3) + 0.04 * sin(t * 3.3)
            RadialGradient(colors: [Color(red: 1, green: 0.55, blue: 0.22).opacity(flicker), .clear],
                           center: UnitPoint(x: 0.5, y: 1.08), startRadius: 0, endRadius: max(size.width, size.height) * 0.6)
        }
    }
}

// MARK: - Glass: drawn over the listening view, never catching the pointer

private struct V3RoomGlass: View {
    let room: V3Room
    let playing: Bool
    let glass: CGRect
    let radius: CGFloat

    var body: some View {
        ZStack {
            switch room {
            case .off:
                Color.clear
            case .rain:
                V3ParticleView(kind: .rain, running: playing).opacity(0.75)
                // Breath on the cold glass along its edges.
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 26).blur(radius: 18)
                // The lamp's warmth reaching the lower right of the pane.
                RadialGradient(colors: [Color(red: 1, green: 0.72, blue: 0.42).opacity(0.16), .clear],
                               center: UnitPoint(x: 1, y: 1), startRadius: 0, endRadius: glass.width * 0.45)
                    .blendMode(.screen)
            case .train:
                V3PassingLights(playing: playing, size: glass.size)
                // The double glazing's faint reflection of the carriage.
                LinearGradient(colors: [.white.opacity(0.07), .clear, .clear, .white.opacity(0.04)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .blendMode(.screen)
            case .snow:
                V3ParticleView(kind: .snow, running: playing).opacity(0.85)
                V3Frost(size: glass.size)
            case .film:
                V3FilmGrain(playing: playing, size: glass.size)
            }
        }
        .frame(width: glass.width, height: glass.height)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .offset(x: glass.minX, y: glass.minY)
        .opacity(room == .off ? 0 : 1)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Lights outside the train window: blurred dots streaming past near the top and
/// bottom of the pane, and every few seconds a street lamp sweeping across it.
/// The middle of the pane, where the lyrics are, stays clear.
private struct V3PassingLights: View {
    let playing: Bool
    let size: CGSize

    private static let lamps: [(lane: CGFloat, phase: CGFloat, radius: CGFloat, warm: Bool, speed: CGFloat)] = {
        var generator = SeededRandom(seed: 11)
        return (0..<34).map { _ in
            let top = generator.next() < 0.55
            let lane = top ? 0.02 + 0.13 * generator.next() : 0.86 + 0.12 * generator.next()
            return (lane, generator.next(), 2 + 6 * generator.next(), generator.next() > 0.3, 0.6 + 0.8 * generator.next())
        }
    }()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !playing)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, canvas in
                let travel = canvas.width + 80
                for lamp in Self.lamps {
                    let distance = (CGFloat(t) * 140 * lamp.speed + lamp.phase * travel).truncatingRemainder(dividingBy: travel)
                    let x = canvas.width + 40 - distance
                    let y = canvas.height * lamp.lane
                    let color = lamp.warm ? Color(red: 1, green: 0.76, blue: 0.42) : Color(red: 0.62, green: 0.78, blue: 1)
                    // Out-of-focus lights, a little smeared by speed.
                    let r = lamp.radius * 2.2
                    let streak = r * (1.4 + 0.8 * lamp.speed)
                    context.fill(Path(ellipseIn: CGRect(x: x - streak / 2, y: y - r / 2, width: streak, height: r)),
                                 with: .color(color.opacity(0.32)))
                }
                // A street lamp sweeping across every 9 seconds.
                let cycle = CGFloat(t.truncatingRemainder(dividingBy: 9) / 9)
                if cycle < 0.28 {
                    let x = canvas.width * (1.15 - cycle / 0.28 * 1.3)
                    let band = CGRect(x: x - canvas.width * 0.12, y: 0, width: canvas.width * 0.24, height: canvas.height)
                    context.fill(Path(band), with: .linearGradient(Gradient(colors: [.clear, Color(red: 1, green: 0.85, blue: 0.6).opacity(0.10), .clear]),
                        startPoint: CGPoint(x: band.minX, y: 0), endPoint: CGPoint(x: band.maxX, y: 0)))
                }
            }
            .blur(radius: 9)
            .blendMode(.screen)
            // Only the upper and lower edges of the pane; the lyrics in the middle stay clear.
            .mask(LinearGradient(stops: [.init(color: .white, location: 0), .init(color: .clear, location: 0.2),
                                         .init(color: .clear, location: 0.8), .init(color: .white, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
        }
        .frame(width: size.width, height: size.height)
    }
}

/// Frost grows in from the corners and leaves the middle clear.
private struct V3Frost: View {
    let size: CGSize
    var body: some View {
        let reach = min(size.width, size.height) * 0.42
        ZStack {
            ForEach(Array([UnitPoint.topLeading, .topTrailing, .bottomLeading, .bottomTrailing].enumerated()), id: \.offset) { _, corner in
                RadialGradient(colors: [Color.white.opacity(0.42), Color.white.opacity(0.12), .clear],
                               center: corner, startRadius: 0, endRadius: reach)
            }
            Canvas { context, canvas in
                // Feathery grains clustered toward the corners, so the frost has texture
                // instead of reading as a flat fog.
                var generator = SeededRandom(seed: 23)
                for _ in 0..<900 {
                    let corner = Int(generator.next() * 4)
                    let angle = generator.next() * .pi / 2
                    let distance = pow(generator.next(), 2.2) * reach
                    let cx = corner % 2 == 0 ? distance * cos(angle) : canvas.width - distance * cos(angle)
                    let cy = corner < 2 ? distance * sin(angle) : canvas.height - distance * sin(angle)
                    let r = 0.6 + 2.2 * generator.next() * (1 - distance / reach)
                    context.fill(Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)),
                                 with: .color(.white.opacity(0.10 + 0.22 * (1 - distance / reach))))
                }
            }
            .blur(radius: 1.2)
        }
        .frame(width: size.width, height: size.height)
    }
}

// MARK: - Frame: the window's own edge

private struct V3RoomFrame: View {
    let room: V3Room
    let size: CGSize
    let glass: CGRect
    let radius: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            switch room {
            case .off:
                Color.clear
            case .rain:
                woodenFrame(dark: Color(red: 0.16, green: 0.10, blue: 0.07), light: Color(red: 0.32, green: 0.21, blue: 0.13))
            case .snow:
                woodenFrame(dark: Color(red: 0.72, green: 0.70, blue: 0.66), light: Color(red: 0.93, green: 0.92, blue: 0.89))
            case .film:
                V3FilmStrip(size: size, glass: glass, radius: radius)
            case .train:
                // Rubber seal and a brushed-metal surround with large rounded corners.
                RoundedRectangle(cornerRadius: radius + 10, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [Color(white: 0.42), Color(white: 0.22)], startPoint: .top, endPoint: .bottom), lineWidth: 10)
                    .frame(width: glass.width + 20, height: glass.height + 20)
                    .offset(x: glass.minX - 10, y: glass.minY - 10)
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.85), lineWidth: 3)
                    .frame(width: glass.width, height: glass.height)
                    .offset(x: glass.minX, y: glass.minY)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .opacity(room == .off ? 0 : 1)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// A painted or stained wooden casement, with a deeper sill below it.
    @ViewBuilder private func woodenFrame(dark: Color, light: Color) -> some View {
        let border: CGFloat = 12
        let wood = LinearGradient(colors: [light, dark], startPoint: .top, endPoint: .bottom)
        RoundedRectangle(cornerRadius: radius + 4, style: .continuous)
            .strokeBorder(wood, lineWidth: border)
            .frame(width: glass.width + border * 2, height: glass.height + border * 2)
            .offset(x: glass.minX - border, y: glass.minY - border)
        // A thin inner shadow where the glass sits in the frame.
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(Color.black.opacity(0.55), lineWidth: 2)
            .frame(width: glass.width, height: glass.height)
            .offset(x: glass.minX, y: glass.minY)
        // The sill.
        let sillTop = glass.maxY + border - 2
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(LinearGradient(colors: [light, dark], startPoint: .top, endPoint: .bottom))
            .frame(width: glass.width + border * 5, height: 9)
            .shadow(color: .black.opacity(0.5), radius: 6, y: 4)
            .offset(x: glass.minX - border * 2.5, y: sillTop)
    }
}

/// Grain, a projector's flicker, the odd scratch and a dark vignette. Drawn at
/// 12 frames a second, like a hand-cranked reel, and frozen while paused.
private struct V3FilmGrain: View {
    let playing: Bool
    let size: CGSize

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12.0, paused: !playing)) { timeline in
            let frame = UInt64(timeline.date.timeIntervalSinceReferenceDate * 12)
            ZStack {
                Canvas { context, canvas in
                    var generator = SeededRandom(seed: frame)
                    for _ in 0..<520 {
                        let x = generator.next() * canvas.width, y = generator.next() * canvas.height
                        let light = generator.next() > 0.5
                        context.fill(Path(CGRect(x: x, y: y, width: 1.4, height: 1.4)),
                                     with: .color((light ? Color.white : .black).opacity(0.10 + 0.12 * generator.next())))
                    }
                    // A scratch now and then, in roughly the same place for a few frames.
                    var scratch = SeededRandom(seed: frame / 5)
                    if scratch.next() < 0.35 {
                        let x = scratch.next() * canvas.width
                        var path = Path()
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x + 6 * (scratch.next() - 0.5), y: canvas.height))
                        context.stroke(path, with: .color(.white.opacity(0.16)), lineWidth: 0.8)
                    }
                    // Dust.
                    for _ in 0..<3 where generator.next() < 0.4 {
                        let r = 1 + 2.5 * generator.next()
                        context.fill(Path(ellipseIn: CGRect(x: generator.next() * canvas.width, y: generator.next() * canvas.height, width: r * 2, height: r)),
                                     with: .color(.black.opacity(0.45)))
                    }
                }
                Color.white.opacity(Double(SeededRandom(seed: frame &+ 99).peek()) * 0.035)
                RadialGradient(colors: [.clear, .black.opacity(0.42)], center: .center,
                               startRadius: min(size.width, size.height) * 0.35, endRadius: max(size.width, size.height) * 0.72)
                // Sepia in the highlights, as on a print.
                Color(red: 1, green: 0.85, blue: 0.62).opacity(0.07).blendMode(.multiply)
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

/// Both edges of a 35 mm strip: sprocket holes, and the frame line between frames.
private struct V3FilmStrip: View {
    let size: CGSize
    let glass: CGRect
    let radius: CGFloat

    var body: some View {
        Canvas { context, canvas in
            let lane = glass.minX
            let hole = CGSize(width: min(14, lane * 0.38), height: min(10, lane * 0.28))
            let pitch = hole.height * 2.1
            var y = pitch / 2
            while y < canvas.height {
                for x in [lane / 2, canvas.width - lane / 2] {
                    let rect = CGRect(x: x - hole.width / 2, y: y - hole.height / 2, width: hole.width, height: hole.height)
                    context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(Color(red: 0.86, green: 0.82, blue: 0.72).opacity(0.85)))
                }
                y += pitch
            }
            // Edge print, the kind of code stamped along real stock.
            let code = Text("ASTER 400  ▸ 17  ▸ 18  ▸ 19").font(.system(size: 7, weight: .semibold, design: .monospaced))
                .foregroundColor(Color(red: 1, green: 0.62, blue: 0.25).opacity(0.7))
            context.draw(code, at: CGPoint(x: glass.minX + 60, y: glass.minY / 2 + 1), anchor: .leading)
        }
        .frame(width: size.width, height: size.height)
    }
}

/// Positions stay put from frame to frame.
private struct SeededRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 | 1 }
    mutating func next() -> CGFloat {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return CGFloat(state % 10_000) / 10_000
    }
    func peek() -> CGFloat { var copy = self; return copy.next() }
}
