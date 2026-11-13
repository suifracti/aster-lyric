import AppKit
import QuartzCore
import SwiftUI

/// 窗上天气: a layer between the picture and the lyrics, as if the window
/// were a pane of glass with weather on the other side.
public enum V3GlassWeather: String, CaseIterable, Identifiable, Sendable {
    case off = "", rain, snow, fog
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .off: return "关闭"; case .rain: return "雨"; case .snow: return "雪"; case .fog: return "雾"
        }
    }
}

/// 歌词意象: a short burst of particles while a line sings of rain, snow,
/// stars or flowers. Only plain keywords; no model, no network.
enum V3LyricImagery: Equatable {
    case rain, snow, stars, petals

    private static let table: [(V3LyricImagery, [String], [String])] = [
        // (imagery, CJK substrings, English words)
        (.rain, ["雨", "빗물", "비가"], ["rain", "raining", "rainy", "raindrop", "raindrops"]),
        (.snow, ["雪", "눈송이"], ["snow", "snowing", "snowflake", "snowflakes"]),
        (.stars, ["星", "銀河", "银河", "별"], ["star", "stars", "starlight", "galaxy"]),
        (.petals, ["花", "桜", "櫻", "樱", "꽃"], ["flower", "flowers", "blossom", "blossoms", "petal", "petals"]),
    ]

    static func detect(_ texts: [String?]) -> V3LyricImagery? {
        let joined = texts.compactMap { $0 }.joined(separator: " ")
        guard !joined.isEmpty else { return nil }
        let words = Set(joined.lowercased().split { !$0.isLetter }.map(String.init))
        for (imagery, cjk, english) in table {
            if cjk.contains(where: { joined.contains($0) }) || english.contains(where: words.contains) {
                return imagery
            }
        }
        return nil
    }
}

/// The weather and the lyric imagery, stacked. Nothing is built while both
/// are off; emitters stop (and let their particles finish) while paused or
/// hidden, and the layer is absent under 减少动态效果.
struct V3GlassWeatherLayer: View {
    let weather: V3GlassWeather
    let imagery: V3LyricImagery?
    let playing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false

    var body: some View {
        if !reduceMotion, weather != .off || imagery != nil {
            ZStack {
                if weather == .fog {
                    // Condensation: a pale veil heavier toward the bottom of the pane.
                    LinearGradient(colors: [.white.opacity(0.02), .white.opacity(0.1)], startPoint: .top, endPoint: .bottom)
                }
                if weather != .off {
                    V3ParticleView(kind: V3ParticleKind(weather), running: playing && visible)
                }
                V3ParticleView(kind: imagery.map(V3ParticleKind.init), running: playing && visible && imagery != nil)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .background(alignment: .topLeading) {
                V3WindowVisibilityProbe(isVisible: $visible).frame(width: 0, height: 0)
            }
        }
    }
}

enum V3ParticleKind: Equatable {
    case rain, snow, fog, stars, petals

    init?(_ weather: V3GlassWeather) {
        switch weather {
        case .off: return nil
        case .rain: self = .rain
        case .snow: self = .snow
        case .fog: self = .fog
        }
    }

    init(_ imagery: V3LyricImagery) {
        switch imagery {
        case .rain: self = .rain
        case .snow: self = .snow
        case .stars: self = .stars
        case .petals: self = .petals
        }
    }
}

struct V3ParticleView: NSViewRepresentable {
    let kind: V3ParticleKind?
    let running: Bool

    func makeNSView(context: Context) -> V3ParticleHostView { V3ParticleHostView() }
    func updateNSView(_ view: V3ParticleHostView, context: Context) {
        view.configure(kind: kind, running: running)
    }
}

final class V3ParticleHostView: NSView {
    /// Falling particles enter from above the top edge.
    private let falling = CAEmitterLayer()
    /// Particles that appear in place, anywhere on the pane.
    private let surface = CAEmitterLayer()
    private var kind: V3ParticleKind?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(falling)
        layer?.addSublayer(surface)
        falling.emitterShape = .line
        surface.emitterShape = .rectangle
        surface.emitterMode = .surface
        falling.birthRate = 0
        surface.birthRate = 0
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for emitter in [falling, surface] { emitter.frame = bounds }
        // Unflipped layer: y grows upward, so the top edge is maxY.
        falling.emitterPosition = CGPoint(x: bounds.midX, y: bounds.maxY + 12)
        falling.emitterSize = CGSize(width: bounds.width * 1.2, height: 1)
        surface.emitterPosition = CGPoint(x: bounds.midX, y: bounds.midY)
        surface.emitterSize = bounds.size
        CATransaction.commit()
    }

    func configure(kind: V3ParticleKind?, running: Bool) {
        if kind != self.kind {
            self.kind = kind
            build(kind)
        }
        let rate: Float = running && kind != nil ? 1 : 0
        if rate != falling.birthRate {
            LyricsE2ELog.log("WEATHER kind=\(String(describing: kind)) running=\(running) bounds=\(bounds) flipped=\(isFlipped) geometryFlipped=\(layer?.isGeometryFlipped ?? false) superFlipped=\(superview?.isFlipped ?? false)")
        }
        falling.birthRate = rate
        surface.birthRate = rate
    }

    private func build(_ kind: V3ParticleKind?) {
        falling.emitterCells = nil
        surface.emitterCells = nil
        guard let kind else { return }
        let scale: CGFloat = 2  // the sprites are drawn at 2×
        switch kind {
        case .rain:
            let streak = cell(V3ParticleImages.streak, scale: scale)
            streak.birthRate = 190
            streak.lifetime = 1.5
            // Falls under gravity: a cell with no acceleration never showed
            // on screen here (checked frame by frame), whatever its velocity.
            streak.velocity = 200; streak.velocityRange = 60
            streak.emissionLongitude = -.pi / 2
            streak.emissionRange = 0.04
            streak.yAcceleration = -1700; streak.xAcceleration = -90
            streak.scale = 0.8; streak.scaleRange = 0.3
            streak.alphaRange = 0.15
            streak.color = NSColor.white.withAlphaComponent(0.38).cgColor
            falling.emitterCells = [streak]
            // Drops that land on the glass, sit, and slide a little.
            let drop = cell(V3ParticleImages.drop, scale: scale)
            drop.birthRate = 5
            drop.lifetime = 5; drop.lifetimeRange = 2
            drop.scale = 0.65; drop.scaleRange = 0.2
            drop.yAcceleration = -7
            drop.alphaSpeed = -0.16
            drop.color = NSColor.white.withAlphaComponent(0.75).cgColor
            surface.emitterCells = [drop]
        case .snow:
            let flake = cell(V3ParticleImages.dot, scale: scale)
            flake.birthRate = 34
            flake.lifetime = 16
            flake.velocity = 55; flake.velocityRange = 30
            flake.emissionLongitude = -.pi / 2
            flake.emissionRange = .pi / 7
            flake.yAcceleration = -4; flake.xAcceleration = 3
            flake.scale = 0.28; flake.scaleRange = 0.17
            flake.spin = 0.4; flake.spinRange = 1
            flake.color = NSColor.white.withAlphaComponent(0.75).cgColor
            flake.alphaRange = 0.3
            falling.emitterCells = [flake]
        case .fog:
            let blob = cell(V3ParticleImages.blob, scale: scale)
            blob.birthRate = 0.5
            blob.lifetime = 26
            blob.velocity = 9; blob.velocityRange = 5
            blob.emissionRange = .pi * 2
            blob.scale = 2.8; blob.scaleRange = 1.2
            blob.color = NSColor.white.withAlphaComponent(0.07).cgColor
            blob.alphaRange = 0.03
            surface.emitterCells = [blob]
        case .stars:
            let star = cell(V3ParticleImages.sparkle, scale: scale)
            star.birthRate = 12
            star.lifetime = 2.6; star.lifetimeRange = 1
            star.scale = 0.7; star.scaleRange = 0.25
            star.alphaSpeed = -0.35
            star.spin = 0.3; star.spinRange = 0.6
            star.color = NSColor(red: 1, green: 0.96, blue: 0.86, alpha: 0.9).cgColor
            surface.emitterCells = [star]
        case .petals:
            let petal = cell(V3ParticleImages.petal, scale: scale)
            petal.birthRate = 9
            petal.lifetime = 13
            petal.velocity = 48; petal.velocityRange = 22
            petal.emissionLongitude = -.pi / 2
            petal.emissionRange = .pi / 5
            petal.yAcceleration = -6; petal.xAcceleration = 9
            petal.scale = 0.55; petal.scaleRange = 0.25
            petal.spin = 0.9; petal.spinRange = 1.6
            petal.color = NSColor(red: 1, green: 0.8, blue: 0.86, alpha: 0.85).cgColor
            petal.alphaRange = 0.2
            falling.emitterCells = [petal]
        }
    }

    private func cell(_ image: CGImage?, scale: CGFloat) -> CAEmitterCell {
        let cell = CAEmitterCell()
        cell.contents = image
        cell.contentsScale = scale
        return cell
    }
}

/// Small white sprites, drawn once; the cells tint them.
enum V3ParticleImages {
    static let streak = draw(CGSize(width: 3, height: 44)) { ctx, size in
        let colors = [CGColor(gray: 1, alpha: 0), CGColor(gray: 1, alpha: 1)] as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(), colors: colors, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size.height), end: .zero, options: [])
    }
    static let dot = draw(CGSize(width: 16, height: 16)) { ctx, size in
        radial(ctx, size, inner: 1, outer: 0)
    }
    static let blob = draw(CGSize(width: 128, height: 128)) { ctx, size in
        radial(ctx, size, inner: 1, outer: 0)
    }
    static let drop = draw(CGSize(width: 24, height: 24)) { ctx, size in
        let rect = CGRect(origin: .zero, size: size).insetBy(dx: 3, dy: 3)
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.18)); ctx.fillEllipse(in: rect)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.7)); ctx.setLineWidth(1.2); ctx.strokeEllipse(in: rect)
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.9))
        ctx.fillEllipse(in: CGRect(x: rect.minX + 4, y: rect.maxY - 8, width: 4, height: 3))
    }
    static let sparkle = draw(CGSize(width: 20, height: 20)) { ctx, size in
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        let path = CGMutablePath()
        path.move(to: CGPoint(x: c.x, y: 0))
        path.addQuadCurve(to: CGPoint(x: size.width, y: c.y), control: c)
        path.addQuadCurve(to: CGPoint(x: c.x, y: size.height), control: c)
        path.addQuadCurve(to: CGPoint(x: 0, y: c.y), control: c)
        path.addQuadCurve(to: CGPoint(x: c.x, y: 0), control: c)
        ctx.addPath(path); ctx.fillPath()
    }
    static let petal = draw(CGSize(width: 16, height: 11)) { ctx, size in
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fillEllipse(in: CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1))
    }

    private static func radial(_ ctx: CGContext, _ size: CGSize, inner: CGFloat, outer: CGFloat) {
        let colors = [CGColor(gray: 1, alpha: inner), CGColor(gray: 1, alpha: outer)] as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(), colors: colors, locations: [0, 1])!
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        ctx.drawRadialGradient(gradient, startCenter: c, startRadius: 0, endCenter: c, endRadius: size.width / 2, options: [])
    }

    private static func draw(_ size: CGSize, _ body: (CGContext, CGSize) -> Void) -> CGImage? {
        let scale: CGFloat = 2
        guard let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        body(ctx, size)
        return ctx.makeImage()
    }
}
