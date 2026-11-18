import CoreLocation
import SwiftUI

/// 情境 (A13, after Tauon's room; rebuilt 2026-11-18). The listening view is
/// never shrunk or framed. A scene adds three layers to the existing picture:
/// - back: between the backdrop and the lyrics (passing lights, stars, lamp and fire light);
/// - cover: around the foreground cover (a polaroid mount, a film frame, a book plate);
/// - glass: on top of everything, never catching the pointer (rain, frost, grain).
/// Each scene also has its own chorus moment, and nothing it does is saved into
/// the user's other picture settings.
enum V3Room: String, CaseIterable, Identifiable, Sendable {
    case off = "", rain, train, snow, weather, book, polaroid, stars, film, fog, aurora, water
    /// 跟随天气 on a dry night: the rain room's window without rain.
    case clearNight
    var id: String { rawValue }

    /// What the picker offers, in groups: rooms, then materials.
    static let rooms: [V3Room] = [.rain, .fog, .snow, .train, .weather]
    static let lights: [V3Room] = [.aurora, .water]
    static let materials: [V3Room] = [.book, .polaroid, .stars, .film]

    var title: String {
        switch self {
        case .off: return "关闭"
        case .rain: return "雨滴玻璃"
        case .fog: return "起雾的窗"
        case .aurora: return "极光"
        case .water: return "水面"
        case .train: return "夜行列车"
        case .snow: return "雪夜小屋"
        case .weather: return "跟随天气"
        case .book: return "书页"
        case .polaroid: return "拍立得"
        case .stars: return "星座"
        case .film: return "老电影"
        case .clearNight: return "晴夜窗边"
        }
    }
    /// Rooms are windows: the time of day colours them and a chorus opens them.
    var isRoom: Bool { [.rain, .fog, .train, .snow, .weather, .clearNight].contains(self) }
    var detail: String {
        switch self {
        case .off: return "只有听歌画面"
        case .rain: return "玻璃上挂满水珠，每颗都倒映着封面，大的会顺着玻璃滑下来。副歌时雨更大，远处闪电"
        case .fog: return "整扇窗起了雾，用鼠标划过就能擦出一道，过一会儿又慢慢雾回去。副歌时雾散开一些"
        case .aurora: return "封面的颜色化成极光，在歌词后面缓缓飘动。每唱一句亮一下，副歌时铺满天空"
        case .water: return "画面像隔着一层水：光纹在底下游动，每唱一句、鼠标划过都会荡开水波"
        case .train: return "窗外的灯从歌词后面掠过，快慢跟着这首歌的节拍。副歌时开上一座桥，城市灯火铺开"
        case .snow: return "窗外落雪，玻璃四角结霜，炉火的光在下方跳动。副歌时雪下得更密"
        case .weather: return "按你所在地现在的天气，在雨、雪和晴夜之间切换；需要大致位置"
        case .book: return "画面像一页旧书：纸纹、台灯，封面成了插图。唱完一段翻一页，副歌那段会被标出来"
        case .polaroid: return "封面成了一张拍立得，正在唱的一句手写在白边上。副歌时按一下快门；歌放完冲洗一张"
        case .stars: return "每句歌词是一颗星，唱过的星连成线。副歌时划过流星；歌唱完留下它的星图"
        case .film: return "封面嵌在胶片里，整幅画面带颗粒、划痕和放映机的闪烁。副歌时放映灯亮一下"
        case .clearNight: return "晴夜的窗"
        }
    }
}

/// What the scene knows about the song. Kept small so the scene is only redrawn
/// when one of these changes.
struct V3RoomContext: Equatable {
    var chorus = false
    var lineIndex: Int?
    var lineCount = 0
    var stanza = 0
    var currentLine = ""
    var trackKey = ""
    var spotifyTrackID: String?
    var opensOnChorus = true
    /// The cover's colour and brightness, so every scene's light belongs to this song.
    var accent: Color = .white
    var luminance: Double = 0.3
    var artworkURL: URL?
    /// The playing song, for the print made when it ends (拍立得, 星座).
    var song: Song?

    struct Song: Equatable {
        var trackKey: String
        var title: String
        var artist: String
        var artworkURL: URL?
        var lineCount: Int
        var hookLine: String
        var hookTranslation: String?
    }

    /// The line a print keeps: the most repeated one (the hook), else the one a third of the way in.
    static func hook(in lines: [LyricLine]) -> LyricLine? {
        let sung = lines.filter { !$0.originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !sung.isEmpty else { return nil }
        var counts: [String: Int] = [:]
        for line in sung { counts[line.originalText, default: 0] += 1 }
        if let best = counts.max(by: { $0.value == $1.value ? $0.key.count > $1.key.count : $0.value < $1.value }), best.value > 1 {
            return sung.first { $0.originalText == best.key }
        }
        return sung[sung.count / 3]
    }

    /// A new stanza starts after an empty line or a pause of seven seconds or more.
    static func stanza(of index: Int?, in lines: [LyricLine]) -> Int {
        guard let index, lines.indices.contains(index) else { return 0 }
        var count = 0
        for i in 1...max(1, index) where i <= index {
            let gap = lines[i].timestamp - lines[i - 1].timestamp
            if lines[i - 1].originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || gap >= 7 { count += 1 }
        }
        return count
    }
}

/// The hour colours a room's wall: cool at dawn, plain by day, amber at dusk,
/// deep blue at night. Read once a minute.
private struct V3DaylightTint: View {
    let room: V3Room
    var body: some View {
        TimelineView(.everyMinute) { timeline in
            let hour = Double(Calendar.current.component(.hour, from: timeline.date))
                + Double(Calendar.current.component(.minute, from: timeline.date)) / 60
            Self.tint(hour: hour).blendMode(.softLight)
        }
        .allowsHitTesting(false)
    }

    static func tint(hour: Double) -> some View {
        let color: Color, strength: Double
        switch hour {
        case 5..<8: (color, strength) = (Color(red: 0.75, green: 0.70, blue: 0.95), 0.55)
        case 8..<16.5: (color, strength) = (Color(red: 0.95, green: 0.93, blue: 0.86), 0.45)
        case 16.5..<19.5: (color, strength) = (Color(red: 1, green: 0.62, blue: 0.30), 0.6)
        default: (color, strength) = (Color(red: 0.20, green: 0.28, blue: 0.62), 0.55)
        }
        return LinearGradient(colors: [color.opacity(strength), color.opacity(strength * 0.4)], startPoint: .top, endPoint: .bottom)
    }
}

/// 跟随天气: the weather where the user is, from Open-Meteo (no account). Only
/// the location rounded to 0.1° (about 10 km) is sent, every 30 minutes while
/// the scene is chosen. Without permission or a reply it shows the rain window.
@MainActor
final class V3WeatherWatcher: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = V3WeatherWatcher()
    @Published private(set) var room: V3Room = .rain
    private var manager: CLLocationManager?
    private var active = false
    private var lastFetch: Date?
    private var refresh: Task<Void, Never>?

    func setActive(_ value: Bool) {
        guard value != active else { return }
        active = value
        refresh?.cancel()
        guard value else { manager?.stopUpdatingLocation(); return }
        let manager = self.manager ?? CLLocationManager()
        self.manager = manager
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyReduced
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        manager.requestLocation()
        refresh = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1800))
                guard let self, self.active else { return }
                self.manager?.requestLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        let lat = (location.coordinate.latitude * 10).rounded() / 10
        let lon = (location.coordinate.longitude * 10).rounded() / 10
        Task { @MainActor in await self.fetch(latitude: lat, longitude: lon) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        LyricsE2ELog.log("WEATHER location failed error=\(error.localizedDescription)")
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in if self.active { self.manager?.requestLocation() } }
    }

    private func fetch(latitude: Double, longitude: Double) async {
        if let lastFetch, Date().timeIntervalSince(lastFetch) < 600 { return }
        var parts = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        parts.queryItems = [URLQueryItem(name: "latitude", value: String(format: "%.1f", latitude)),
                            URLQueryItem(name: "longitude", value: String(format: "%.1f", longitude)),
                            URLQueryItem(name: "current", value: "weather_code")]
        guard let url = parts.url else { return }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.httpShouldHandleCookies = false
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = object["current"] as? [String: Any],
              let code = current["weather_code"] as? Int else { return }
        lastFetch = Date()
        room = Self.room(forWeatherCode: code)
        LyricsE2ELog.log("WEATHER code=\(code) room=\(room.rawValue)")
    }

    /// WMO weather codes: drizzle, rain and storms → rain; snow → snow; the rest → a clear night window.
    static func room(forWeatherCode code: Int) -> V3Room {
        switch code {
        case 45, 48: return .fog
        case 51...67, 80...82, 95...99: return .rain
        case 71...77, 85, 86: return .snow
        default: return .clearNight
        }
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

/// Lights outside the train window, streaming past behind the lyrics: more of
/// them low down, as a city seen from a train, and every few seconds a street
/// lamp sweeping across the whole window.
private struct V3PassingLights: View {
    let playing: Bool
    let size: CGSize
    var speed: Double = 1
    /// 2 during the chorus: twice as many lights.
    var density = 1

    private static let lamps: [(lane: CGFloat, phase: CGFloat, radius: CGFloat, warm: Bool, speed: CGFloat)] = {
        var generator = SeededRandom(seed: 11)
        return (0..<48).map { _ in
            let lane = 0.1 + 0.88 * sqrt(generator.next())
            return (lane, generator.next(), 2 + 6 * generator.next(), generator.next() > 0.3, 0.6 + 0.8 * generator.next())
        }
    }()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !playing)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, canvas in
                let travel = canvas.width + 80
                for (index, lamp) in Self.lamps.enumerated() where density > 1 || index % 2 == 0 {
                    let distance = (CGFloat(t) * 140 * CGFloat(speed) * lamp.speed + lamp.phase * travel).truncatingRemainder(dividingBy: travel)
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
            .blur(radius: 10)
            .blendMode(.screen)
        }
        .frame(width: size.width, height: size.height)
    }
}

/// Frost grows in from the corners and leaves the middle clear.
private struct V3Frost: View {
    let size: CGSize
    var body: some View {
        let reach = max(1, min(size.width, size.height) * 0.42)
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
                    let angle = CGFloat(generator.next()) * .pi / 2
                    let distance = CGFloat(pow(generator.next(), 2.2)) * reach
                    let cx = corner % 2 == 0 ? distance * cos(angle) : canvas.width - distance * cos(angle)
                    let cy = corner < 2 ? distance * sin(angle) : canvas.height - distance * sin(angle)
                    let r = 0.6 + 2.2 * CGFloat(generator.next()) * (1 - distance / reach)
                    context.fill(Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)),
                                 with: .color(.white.opacity(0.10 + 0.22 * Double(1 - distance / reach))))
                }
            }
            .blur(radius: 1.2)
        }
        .frame(width: size.width, height: size.height)
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

/// Fixed specks: dust on a corkboard, faint stars around the sky's frame.
struct V3Speckle: View {
    let seed: UInt64
    let count: Int
    let color: Color
    let opacity: Double
    var body: some View {
        Canvas { context, canvas in
            var generator = SeededRandom(seed: seed)
            for _ in 0..<count {
                let r = 0.4 + 1.1 * generator.next()
                context.fill(Path(ellipseIn: CGRect(x: generator.next() * canvas.width, y: generator.next() * canvas.height, width: r * 2, height: r * 2)),
                             with: .color(color.opacity(opacity * (0.3 + 0.7 * Double(generator.next())))))
            }
        }
    }
}

/// The shadow and bright edge of a page passing from right to left.
private struct V3PageSweep: View {
    let progress: Double
    var body: some View {
        GeometryReader { geometry in
            let w = geometry.size.width
            let eased = 1 - pow(1 - progress, 2.2)
            let x = w * (1.05 - 1.15 * eased)
            ZStack(alignment: .leading) {
                LinearGradient(colors: [.black.opacity(0.0), .black.opacity(0.22)], startPoint: .leading, endPoint: .trailing)
                    .frame(width: w * 0.18)
                    .offset(x: x - w * 0.18)
                LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0.0)], startPoint: .leading, endPoint: .trailing)
                    .frame(width: w * 0.08)
                    .offset(x: x)
            }
            .blendMode(.overlay)
        }
    }
}

/// 星座: one star per lyric line, laid out as a wandering path so neighbouring
/// lines sit near each other. Sung stars brighten and join up; the line being
/// sung twinkles. Each song keeps the same chart.
private struct V3Constellation: View {
    let size: CGSize
    let seed: String
    let count: Int
    let current: Int?
    let playing: Bool

    static func points(seed: String, count: Int) -> [CGPoint] {
        var hash: UInt64 = 1469598103934665603
        for byte in seed.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        var generator = SeededRandom(seed: hash)
        var point = CGPoint(x: 0.15 + 0.7 * generator.next(), y: 0.15 + 0.7 * generator.next())
        var angle = generator.next() * 2 * .pi
        return (0..<count).map { _ in
            defer {
                angle += (generator.next() - 0.5) * 1.6
                let step = 0.05 + 0.06 * generator.next()
                var next = CGPoint(x: point.x + cos(angle) * step, y: point.y + sin(angle) * step * 1.4)
                if next.x < 0.04 || next.x > 0.96 { angle = .pi - angle; next.x = min(0.96, max(0.04, next.x)) }
                if next.y < 0.05 || next.y > 0.95 { angle = -angle; next.y = min(0.95, max(0.05, next.y)) }
                point = next
            }
            return point
        }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !playing)) { timeline in
            V3ConstellationChart(size: size, seed: seed, count: count, lit: current ?? -1,
                                 twinkle: timeline.date.timeIntervalSinceReferenceDate)
        }
        .blendMode(.screen)
        .frame(width: size.width, height: size.height)
    }
}

/// One drawing of a song's stars, shared by the live scene and the saved chart.
struct V3ConstellationChart: View {
    let size: CGSize
    let seed: String
    let count: Int
    /// The last sung line; stars up to it are lit and joined.
    let lit: Int
    /// The clock for the current star's twinkle; 0 draws it still.
    let twinkle: TimeInterval

    var body: some View {
        let points = V3Constellation.points(seed: seed, count: count)
        Canvas { context, canvas in
            let place = { (p: CGPoint) in CGPoint(x: p.x * canvas.width, y: p.y * canvas.height) }
            let sung = min(lit, points.count - 1)
            if sung > 0 {
                var path = Path()
                path.move(to: place(points[0]))
                for index in 1...sung { path.addLine(to: place(points[index])) }
                context.stroke(path, with: .color(.white.opacity(0.35)), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
            }
            for (index, point) in points.enumerated() {
                let p = place(point)
                let isLit = index <= sung
                let isNow = index == sung && twinkle != 0
                let r: CGFloat = isNow ? 4 + 1.2 * CGFloat(sin(twinkle * 4)) : isLit ? 2.4 : 1.3
                if isLit {
                    context.fill(Path(ellipseIn: CGRect(x: p.x - r * 3, y: p.y - r * 3, width: r * 6, height: r * 6)),
                                 with: .radialGradient(Gradient(colors: [.white.opacity(isNow ? 0.45 : 0.22), .clear]),
                                                       center: p, startRadius: 0, endRadius: r * 3))
                }
                context.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                             with: .color(.white.opacity(isLit ? 0.95 : 0.28)))
            }
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

// MARK: - 冲洗台: keepsakes left behind by 拍立得 and 星座

/// When a song played in 拍立得 or 星座 ends, a print is made: the polaroid
/// with its line written on it, or the song's finished star chart. Prints are
/// kept as PNG files next to the favourite lines, never in the lyrics database,
/// and can be put into a songbook or saved elsewhere.
@MainActor
final class V3Keepsakes: ObservableObject {
    struct Print: Codable, Identifiable, Equatable {
        enum Kind: String, Codable { case polaroid, stars }
        var id = UUID()
        let kind: Kind
        let title: String
        let artist: String
        let trackKey: String
        let line: String
        var translation: String?
        var artworkURL: URL?
        var createdAt = Date()
        var fileName: String { id.uuidString + ".png" }

        /// As a songbook quote: the line, with where it came from.
        var quote: V3FavoriteLines.Entry {
            V3FavoriteLines.Entry(text: line.isEmpty ? title : line, translation: translation, title: title,
                                  artist: artist, trackKey: trackKey, artworkURL: artworkURL)
        }
    }

    static let shared = V3Keepsakes(folder: defaultFolder)
    static var defaultFolder: URL? {
        V3FavoriteLines.defaultURL?.deletingLastPathComponent().appendingPathComponent("Keepsakes", isDirectory: true)
    }

    @Published private(set) var prints: [Print] = []
    /// The newest print not yet looked at, for the tray's dot.
    @Published var unseen = false
    let folder: URL?

    init(folder: URL?) {
        self.folder = folder
        guard let index = folder?.appendingPathComponent("index.json"),
              let data = try? Data(contentsOf: index),
              let saved = try? JSONDecoder().decode([Print].self, from: data) else { return }
        prints = saved.filter { url(for: $0).map { FileManager.default.fileExists(atPath: $0.path) } ?? false }
    }

    func url(for print: Print) -> URL? { folder?.appendingPathComponent(print.fileName) }

    func add(_ print: Print, png: Data) {
        guard let folder, let url = url(for: print) else { return }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try png.write(to: url, options: .atomic)
            let next = [print] + prints
            try JSONEncoder().encode(next).write(to: folder.appendingPathComponent("index.json"), options: .atomic)
            prints = next
            unseen = true
        } catch {
            LyricsE2ELog.log("KEEPSAKE save failed error=\(error.localizedDescription)")
        }
    }

    func remove(_ print: Print) {
        guard let folder else { return }
        let next = prints.filter { $0.id != print.id }
        guard (try? JSONEncoder().encode(next).write(to: folder.appendingPathComponent("index.json"), options: .atomic)) != nil else { return }
        if let url = url(for: print) { try? FileManager.default.removeItem(at: url) }
        prints = next
    }

    /// Renders and keeps the print for a song that just finished.
    func develop(kind: Print.Kind, song: V3RoomContext.Song) async {
        let artwork: NSImage? = kind == .polaroid ? await song.artworkURL.asyncMap { await ArtworkImageLoader.shared.image(for: $0) } ?? nil : nil
        let print = Print(kind: kind, title: song.title, artist: song.artist, trackKey: song.trackKey,
                          line: song.hookLine, translation: song.hookTranslation, artworkURL: song.artworkURL)
        let view: AnyView = kind == .polaroid
            ? AnyView(V3PolaroidPrint(print: print, artwork: artwork))
            : AnyView(V3StarChartPrint(print: print, lineCount: song.lineCount))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        add(print, png: png)
    }
}

private extension Optional {
    func asyncMap<T>(_ transform: (Wrapped) async -> T) async -> T? {
        guard let value = self else { return nil }
        return await transform(value)
    }
}

/// The developed polaroid: cover, the song's line in handwriting, title and date.
struct V3PolaroidPrint: View {
    let print: V3Keepsakes.Print
    let artwork: NSImage?
    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let artwork { Image(nsImage: artwork).resizable().scaledToFill() }
                else { LinearGradient(colors: [Color(white: 0.3), Color(white: 0.15)], startPoint: .top, endPoint: .bottom) }
            }
            .frame(width: 420, height: 420).clipped()
            .overlay(Color(red: 1, green: 0.9, blue: 0.75).opacity(0.10).blendMode(.multiply))
            Text(print.line.isEmpty ? print.title : print.line)
                .font(V3SceneHand.font(size: 24))
                .foregroundStyle(Color(red: 0.16, green: 0.17, blue: 0.24))
                .lineLimit(2).multilineTextAlignment(.center).minimumScaleFactor(0.6)
                .frame(width: 400, height: 76)
            Text([print.title, print.artist, print.createdAt.formatted(date: .abbreviated, time: .omitted)]
                .filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.system(size: 11, weight: .medium)).foregroundStyle(Color(white: 0.45))
                .lineLimit(1).frame(width: 400)
        }
        .padding(EdgeInsets(top: 26, leading: 26, bottom: 30, trailing: 26))
        .background(Color(red: 0.97, green: 0.96, blue: 0.93))
    }
}

/// The finished star chart: every line lit and joined, with the song's name.
struct V3StarChartPrint: View {
    let print: V3Keepsakes.Print
    let lineCount: Int
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [Color(red: 0.03, green: 0.04, blue: 0.10), Color(red: 0.07, green: 0.05, blue: 0.16)],
                           startPoint: .top, endPoint: .bottom)
            V3Speckle(seed: 9, count: 420, color: .white, opacity: 0.5)
            V3ConstellationChart(size: CGSize(width: 760, height: 620), seed: print.trackKey, count: lineCount,
                                 lit: lineCount - 1, twinkle: 0)
                .padding(.top, 40).padding(.horizontal, 40)
                .frame(maxHeight: .infinity, alignment: .top)
            VStack(alignment: .leading, spacing: 4) {
                Text(print.title).font(.system(size: 26, weight: .semibold, design: .serif)).foregroundStyle(.white)
                Text([print.artist, print.createdAt.formatted(date: .abbreviated, time: .omitted)].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
            }
            .padding(36)
        }
        .frame(width: 840, height: 840)
    }
}

/// The tray in the scene's margin: the prints made so far.
struct V3KeepsakeTray: View {
    @ObservedObject var store = V3Keepsakes.shared
    let kind: V3Keepsakes.Print.Kind
    @State private var open = false

    var body: some View {
        Button { open.toggle(); store.unseen = false } label: {
            Image(systemName: kind == .polaroid ? "photo.stack" : "sparkles")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(kind == .polaroid ? Color(white: 0.35) : .white.opacity(0.8))
                .frame(width: 28, height: 24)
                .overlay(alignment: .topTrailing) {
                    if store.unseen { Circle().fill(Color.orange).frame(width: 7, height: 7).offset(x: -2, y: 2) }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(kind == .polaroid ? "冲洗好的拍立得" : "保存的星图")
        .accessibilityLabel(kind == .polaroid ? "冲洗好的拍立得" : "保存的星图")
        .popover(isPresented: $open, arrowEdge: .top) { V3KeepsakeList(store: store, kind: kind) }
    }
}

private struct V3KeepsakeList: View {
    @ObservedObject var store: V3Keepsakes
    let kind: V3Keepsakes.Print.Kind

    var body: some View {
        let prints = store.prints.filter { $0.kind == kind }
        VStack(alignment: .leading, spacing: 8) {
            Text(kind == .polaroid ? "冲洗好的拍立得" : "星图").font(.headline)
            if prints.isEmpty {
                Text(kind == .polaroid ? "一首歌放完后，这里会冲洗出一张拍立得。" : "一首歌唱完后，它的星图会留在这里。")
                    .font(.callout).foregroundStyle(.secondary).frame(width: 260, alignment: .leading)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 10)], spacing: 10) {
                        ForEach(prints) { print in
                            V3KeepsakeThumb(store: store, print: print)
                        }
                    }
                }
                .frame(width: 360, height: min(420, CGFloat((prints.count + 2) / 3) * 150 + 10))
            }
        }
        .padding(14)
    }
}

private struct V3KeepsakeThumb: View {
    let store: V3Keepsakes
    let print: V3Keepsakes.Print

    var body: some View {
        VStack(spacing: 4) {
            Group {
                if let url = store.url(for: print), let image = NSImage(contentsOf: url) {
                    Image(nsImage: image).resizable().scaledToFit()
                } else { Color.secondary.opacity(0.2) }
            }
            .frame(height: 112)
            .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
            Text(print.title).font(.caption).lineLimit(1)
            HStack(spacing: 6) {
                LyricBookOffer(label: "收进歌本", title: print.title, compact: true) { [LyricBook.Chapter(quote: print.quote)] }
                    .buttonStyle(.borderless).menuStyle(.borderlessButton).fixedSize()
                Button { save() } label: { Image(systemName: "square.and.arrow.down") }
                    .buttonStyle(.borderless).help("存为图片…").accessibilityLabel("存为图片")
                Menu {
                    Button("在 Finder 中显示") { if let url = store.url(for: print) { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
                    Button("删除", role: .destructive) { store.remove(print) }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            .font(.system(size: 12))
        }
    }

    private func save() {
        guard let source = store.url(for: print) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(print.title)\(print.kind == .polaroid ? " 拍立得" : " 星图").png"
        guard panel.runModal() == .OK, let target = panel.url else { return }
        try? FileManager.default.removeItem(at: target)
        try? FileManager.default.copyItem(at: source, to: target)
    }
}

// MARK: - The three layers

/// Handwriting for the polaroid: Klee, then 手札体, then 楷体, else an italic serif.
enum V3SceneHand {
    private static let name: String? = ["Klee-Medium", "HannotateSC-W5", "KaitiSC-Regular", "BradleyHandITCTT-Bold"]
        .first { NSFont(name: $0, size: 20) != nil }
    static func font(size: CGFloat) -> Font {
        name.map { .custom($0, size: size) } ?? .system(size: size, weight: .regular, design: .serif).italic()
    }
}

extension V3Room {
    /// The look drawn for this choice: 跟随天气 becomes the window the weather picks.
    @MainActor func resolved(_ weather: V3WeatherWatcher? = nil) -> V3Room { self == .weather ? (weather ?? .shared).room : self }
}

/// Between the backdrop and the lyrics: the scene's light and what is behind the glass.
struct V3SceneBackLayer: View {
    let scene: V3Room
    let context: V3RoomContext
    let playing: Bool
    var speed: Double = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Scenes keep breathing while paused, so the picture never looks frozen;
    /// only Reduce Motion stops them.
    private var moving: Bool { !reduceMotion }
    private var chorus: Bool { context.chorus && context.opensOnChorus && playing }
    private var light: Double { v3SceneLight(context.luminance) }
    @State private var linePulse = 0.0
    /// A scene's tint, mixed with the cover's colour so the two read as one picture.
    private func tone(_ base: Color, _ share: Double = 0.4) -> Color { base.v3Mixed(with: context.accent, share) }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                switch scene {
                case .off, .weather, .film:
                    Color.clear
                case .fog:
                    // A grey morning outside the fogged pane.
                    Color(red: 0.75, green: 0.8, blue: 0.86).opacity(0.10 * light).blendMode(.screen)
                case .aurora:
                    // A darker sky so the light has somewhere to glow.
                    tone(Color(red: 0.02, green: 0.04, blue: 0.12), 0.3).opacity(0.3 + 0.3 * context.luminance).blendMode(.multiply)
                    V3Aurora(size: size, accent: context.accent,
                             energy: (0.95 + (chorus ? 0.45 : 0) + 0.35 * linePulse) * max(0.75, light), running: moving)
                case .water:
                    tone(Color(red: 0.05, green: 0.30, blue: 0.42), 0.3).opacity(0.35).blendMode(.multiply)
                case .rain, .clearNight:
                    // A cooler, darker night, the window's cross cast over the picture, and the lamp.
                    tone(Color(red: 0.05, green: 0.08, blue: 0.16)).opacity(0.28).blendMode(.multiply)
                    V3WindowShadow(size: size)
                    RadialGradient(colors: [Color(red: 1, green: 0.70, blue: 0.40).opacity(0.30 * light), .clear],
                                   center: UnitPoint(x: 1.0, y: 1.0), startRadius: 0, endRadius: max(size.width, size.height) * 0.6)
                        .blendMode(.screen)
                    if scene == .clearNight { V3Speckle(seed: 41, count: 90, color: .white, opacity: 0.5).mask(LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .center)) }
                    if scene == .rain, chorus { V3Lightning(running: moving) }
                case .train:
                    tone(Color(red: 0.03, green: 0.04, blue: 0.08)).opacity(0.35).blendMode(.multiply)
                    V3PassingLights(playing: moving, size: size, speed: speed * (chorus ? 1.25 : 1), density: chorus ? 2 : 1)
                    if chorus {
                        // The bridge: the city spread out below.
                        LinearGradient(colors: [.clear, Color(red: 1, green: 0.72, blue: 0.38).opacity(0.28)], startPoint: .center, endPoint: .bottom)
                            .blendMode(.screen).transition(.opacity)
                    }
                case .snow:
                    tone(Color(red: 0.55, green: 0.65, blue: 0.85)).opacity(0.10).blendMode(.screen)
                    V3Firelight(size: size)
                case .book:
                    // Old paper under a lamp: sepia, grain, warm light from the upper left.
                    tone(Color(red: 0.62, green: 0.48, blue: 0.30), 0.3).opacity(0.30).blendMode(.multiply)
                    V3Speckle(seed: 31, count: 1500, color: Color(red: 0.95, green: 0.85, blue: 0.65), opacity: 0.10)
                    RadialGradient(colors: [Color(red: 1, green: 0.85, blue: 0.6).opacity(0.28), .clear],
                                   center: UnitPoint(x: 0.1, y: 0.0), startRadius: 0, endRadius: max(size.width, size.height) * 0.8)
                        .blendMode(.screen)
                case .polaroid:
                    // A faded print: lifted blacks and a warm cast over the whole picture.
                    Color(red: 1, green: 0.93, blue: 0.80).opacity(0.08).blendMode(.screen)
                    Color(red: 1, green: 0.86, blue: 0.68).opacity(0.14).blendMode(.multiply)
                case .stars:
                    tone(Color(red: 0.02, green: 0.03, blue: 0.10), 0.35).opacity(0.55).blendMode(.multiply)
                    V3Speckle(seed: 9, count: 320, color: .white, opacity: 0.55)
                    V3Constellation(size: size, seed: context.trackKey, count: context.lineCount,
                                    current: context.lineIndex, playing: moving)
                    if chorus { V3ShootingStar(size: size, running: moving) }
                }
                if scene.isRoom { V3DaylightTint(room: scene) }
            }
            .frame(width: size.width, height: size.height)
            .animation(.easeInOut(duration: 1.2), value: chorus)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: context.lineIndex) { _, index in
            guard index != nil, scene == .aurora, !reduceMotion else { return }
            linePulse = 1
            withAnimation(.easeOut(duration: 2.4)) { linePulse = 0 }
        }
    }
}

/// Over the foreground cover. Only the keepsake tray takes clicks.
struct V3SceneCoverLayer: View {
    let scene: V3Room
    let context: V3RoomContext
    /// The foreground cover, when one is shown and large enough.
    let cover: CGRect?
    /// The player card, which the polaroid's strip must not cover.
    var player: CGRect = .null
    @State private var shutterAt: Date?

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment: .topLeading) {
                if let cover {
                    V3CoverBlend(scene: scene, cover: cover, accent: context.accent)
                    switch scene {
                    case .polaroid:
                        V3PolaroidMount(cover: cover, line: context.currentLine, shutterAt: shutterAt,
                                        room: V3PolaroidMount.room(below: cover, player: player))
                    case .film: V3FilmFrame(cover: cover)
                    case .book: V3BookPlate(cover: cover)
                    default: EmptyView()
                    }
                }
                if scene == .polaroid, cover == nil {
                    V3MiniPolaroid(artworkURL: context.artworkURL, line: context.currentLine)
                        .position(x: 92, y: size.height - 110)
                }
                if scene == .polaroid || scene == .stars {
                    let anchor = cover.map { CGPoint(x: $0.maxX - 6, y: $0.maxY + (scene == .polaroid ? $0.width * 0.13 : 22)) }
                        ?? CGPoint(x: scene == .polaroid ? 160 : 34, y: size.height - (scene == .polaroid ? 46 : 30))
                    V3KeepsakeTray(kind: scene == .polaroid ? .polaroid : .stars)
                        .position(x: min(size.width - 20, anchor.x), y: min(size.height - 16, anchor.y))
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
        }
        .onChange(of: context.chorus && context.opensOnChorus) { _, now in
            if now, scene == .polaroid { shutterAt = Date() }
        }
    }
}

/// On top of everything, never catching the pointer.
struct V3SceneGlassLayer: View {
    let scene: V3Room
    let context: V3RoomContext
    let playing: Bool
    /// The foreground cover: the glass thins out over it so the cover stays itself.
    var cover: CGRect? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var turnedAt: Date?
    @State private var flareAt: Date?
    private var moving: Bool { !reduceMotion }
    private var chorus: Bool { context.chorus && context.opensOnChorus && playing }
    private var light: Double { v3SceneLight(context.luminance) }
    @State private var canvasSize = CGSize.zero

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                switch scene {
                case .rain:
                    V3MistedEdges(size: size, strength: 0.09)
                    V3RainLens(size: size, artworkURL: context.artworkURL, running: moving, heavy: chorus)
                    if chorus { V3ParticleView(kind: .rain, running: moving).opacity(0.55) }
                case .fog:
                    V3FogGlass(size: size, thin: chorus, running: moving)
                case .water:
                    V3WaterCaustics(size: size, accent: context.accent, strength: 0.6 * light, running: moving)
                case .clearNight:
                    V3MistedEdges(size: size, strength: 0.07)
                case .snow:
                    V3ParticleView(kind: .snow, running: moving).opacity(0.8)
                    if chorus { V3ParticleView(kind: .snow, running: moving).opacity(0.6).scaleEffect(1.4) }
                    V3Frost(size: size)
                case .train:
                    // The double glazing's faint reflection of the carriage.
                    LinearGradient(colors: [.white.opacity(0.06), .clear, .clear, .white.opacity(0.03)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing).blendMode(.screen)
                case .film:
                    V3FilmGrain(playing: moving, size: size)
                    if let flareAt { V3Flash(at: flareAt, color: Color(red: 1, green: 0.95, blue: 0.85), peak: 0.16, duration: 1.4) }
                case .book:
                    RadialGradient(colors: [.clear, Color(red: 0.25, green: 0.15, blue: 0.05).opacity(0.35)], center: .center,
                                   startRadius: min(size.width, size.height) * 0.4, endRadius: max(size.width, size.height) * 0.75)
                    if chorus {
                        // The chorus is marked like a passage underlined in pencil: a warm wash at the edge.
                        LinearGradient(colors: [Color(red: 1, green: 0.85, blue: 0.4).opacity(0.14), .clear], startPoint: .leading, endPoint: .init(x: 0.12, y: 0.5))
                            .blendMode(.screen).transition(.opacity)
                    }
                    if let turnedAt {
                        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
                            let progress = min(1, timeline.date.timeIntervalSince(turnedAt) / 0.9)
                            V3PageSweep(progress: progress).opacity(progress >= 1 ? 0 : 1)
                        }
                    }
                case .off, .weather, .polaroid, .stars, .aurora:
                    Color.clear
                }
            }
            .frame(width: size.width, height: size.height)
            .mask {
                ZStack {
                    Rectangle().fill(.white)
                    if let cover {
                        // A soft hole where the cover is; a quarter of the effect still crosses it.
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(.black.opacity(0.75))
                            .frame(width: cover.width + 16, height: cover.height + 16)
                            .position(x: cover.midX, y: cover.midY)
                            .blur(radius: 12)
                            .blendMode(.destinationOut)
                    }
                }
                .compositingGroup()
            }
            .onChange(of: size, initial: true) { _, next in canvasSize = next }
            .animation(.easeInOut(duration: 1.2), value: chorus)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: context.lineIndex) { _, index in
            // 水面: each new line drops into the water near the lyrics.
            guard scene == .water, index != nil, !reduceMotion else { return }
            V3SceneInput.shared.ripple(at: CGPoint(x: canvasSize.width * CGFloat.random(in: 0.55...0.75),
                                                   y: canvasSize.height * CGFloat.random(in: 0.42...0.56)))
        }
        .onChange(of: context.stanza) { old, new in
            if scene == .book, moving, new > old { turnedAt = Date() }
        }
        .onChange(of: chorus) { _, now in
            if now, scene == .film { flareAt = Date() }
        }
    }
}

/// Keeps the scene's outside world running: the weather, the song's tempo, and the
/// print left when a song played in 拍立得 or 星座 ends.
struct V3SceneDriver: ViewModifier {
    let scene: V3Room
    let context: V3RoomContext
    @Binding var bpm: Double?
    @State private var reached = (key: "", line: -1)

    func body(content: Content) -> some View {
        content
            .onChange(of: scene, initial: true) { _, next in V3WeatherWatcher.shared.setActive(next == .weather) }
            .task(id: scene == .train ? context.spotifyTrackID : nil) {
                bpm = nil
                guard scene == .train, let id = context.spotifyTrackID else { return }
                let found = await Task.detached(priority: .utility) { SpotifyTrackAnalysis.load(trackID: id).bpm }.value
                if !Task.isCancelled { bpm = found.map { min(180, max(60, $0)) } }
            }
            .onChange(of: context.lineIndex) { _, index in
                guard let song = context.song, let index else { return }
                if reached.key != song.trackKey { reached = (song.trackKey, index) } else { reached.line = max(reached.line, index) }
            }
            .onChange(of: context.song) { previous, _ in
                guard let previous, scene == .polaroid || scene == .stars, reached.key == previous.trackKey,
                      previous.lineCount > 0, Double(reached.line + 1) / Double(previous.lineCount) >= 0.6 else { return }
                let kind: V3Keepsakes.Print.Kind = scene == .polaroid ? .polaroid : .stars
                reached = ("", -1)
                Task { await V3Keepsakes.shared.develop(kind: kind, song: previous) }
            }
    }
}

// MARK: - Pieces

/// The window's cross, cast by the lamp onto the picture: two wide, soft bands
/// with no hard edge, slightly off centre as if the lamp were to one side.
private struct V3WindowShadow: View {
    let size: CGSize
    var body: some View {
        ZStack {
            LinearGradient(stops: [.init(color: .clear, location: 0.5), .init(color: .black.opacity(0.16), location: 0.6),
                                   .init(color: .clear, location: 0.7)], startPoint: .leading, endPoint: .trailing)
            LinearGradient(stops: [.init(color: .clear, location: 0.28), .init(color: .black.opacity(0.14), location: 0.38),
                                   .init(color: .clear, location: 0.48)], startPoint: .top, endPoint: .bottom)
        }
        .frame(width: size.width, height: size.height)
    }
}

/// Breath on cold glass, thickest at the corners and gone towards the middle.
private struct V3MistedEdges: View {
    let size: CGSize
    let strength: Double
    var body: some View {
        RadialGradient(stops: [.init(color: .clear, location: 0.55), .init(color: .white.opacity(strength), location: 1)],
                       center: .center, startRadius: 0, endRadius: hypot(size.width, size.height) / 2)
            .frame(width: size.width, height: size.height)
    }
}

/// A distant flash now and then during the chorus.
private struct V3Lightning: View {
    let running: Bool
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !running)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 7.3)
            let flash = t < 0.08 ? 0.22 : (t > 0.16 && t < 0.24) ? 0.14 : 0
            Color(red: 0.85, green: 0.9, blue: 1).opacity(flash).blendMode(.screen)
        }
    }
}

/// One streak across the sky every few seconds during the chorus.
private struct V3ShootingStar: View {
    let size: CGSize
    let running: Bool
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !running)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let cycle = t.truncatingRemainder(dividingBy: 6) / 1.1
            Canvas { context, canvas in
                guard cycle < 1 else { return }
                var generator = SeededRandom(seed: UInt64(t / 6))
                let start = CGPoint(x: canvas.width * (0.35 + 0.6 * generator.next()), y: canvas.height * 0.05 * generator.next())
                let head = CGPoint(x: start.x - canvas.width * 0.35 * cycle, y: start.y + canvas.height * 0.25 * cycle)
                let tail = CGPoint(x: head.x + canvas.width * 0.08, y: head.y - canvas.height * 0.057)
                var path = Path(); path.move(to: tail); path.addLine(to: head)
                context.stroke(path, with: .linearGradient(Gradient(colors: [.clear, .white.opacity(0.9 * (1 - cycle))]),
                                                           startPoint: tail, endPoint: head), lineWidth: 1.6)
            }
            .frame(width: size.width, height: size.height)
        }
    }
}

/// A brief light that fades: the polaroid's shutter, the projector's lamp.
private struct V3Flash: View {
    let at: Date
    let color: Color
    let peak: Double
    let duration: Double
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: Date().timeIntervalSince(at) > duration)) { timeline in
            let progress = timeline.date.timeIntervalSince(at) / duration
            color.opacity(progress < 1 ? peak * (1 - progress) * (1 - progress) : 0).blendMode(.screen)
        }
    }
}

/// 拍立得: the cover gets a white mount, wider below, with the sung line written
/// on it by hand, and a strip of tape at the top.
struct V3PolaroidMount: View {
    let cover: CGRect
    let line: String
    let shutterAt: Date?
    /// Space below the cover before the player card; nil when nothing is below.
    var room: CGFloat? = nil

    static func room(below cover: CGRect, player: CGRect) -> CGFloat? {
        guard !player.isNull, player.minY >= cover.maxY - 1, player.minX < cover.maxX, player.maxX > cover.minX else { return nil }
        return player.minY - cover.maxY - 4
    }

    var body: some View {
        let border = max(8, cover.width * 0.055)
        // Wider than the sides, as on a real print, but narrow enough to stay in the
        // usual gap above the player card.
        let caption = min(border * 2.4, max(20, room ?? .infinity))
        let mount = CGRect(x: cover.minX - border, y: cover.minY - border,
                           width: cover.width + border * 2, height: cover.height + border + caption)
        ZStack(alignment: .topLeading) {
            Path { path in path.addRect(mount); path.addRect(cover) }
                .fill(Color(red: 0.97, green: 0.96, blue: 0.93), style: FillStyle(eoFill: true))
                .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
            Rectangle().fill(Color(red: 0.95, green: 0.92, blue: 0.80).opacity(0.8))
                .frame(width: cover.width * 0.28, height: border * 1.7)
                .rotationEffect(.degrees(-4))
                .offset(x: mount.midX - cover.width * 0.14, y: mount.minY - border * 0.85)
            Text(line.isEmpty ? " " : line)
                .font(V3SceneHand.font(size: min(18, max(11, caption * 0.5))))
                .foregroundStyle(Color(red: 0.16, green: 0.17, blue: 0.24).opacity(0.86))
                .lineLimit(1).minimumScaleFactor(0.45)
                .frame(width: cover.width - 8, height: caption)
                .offset(x: cover.minX + 4, y: cover.maxY)
                .id(line).transition(.opacity)
                .animation(.easeInOut(duration: 0.5), value: line)
            if let shutterAt {
                V3Flash(at: shutterAt, color: .white, peak: 0.85, duration: 0.6)
                    .frame(width: cover.width, height: cover.height).offset(x: cover.minX, y: cover.minY)
            }
        }
        .allowsHitTesting(false)
    }
}

/// 老电影: the cover sits in a strip of 35 mm film, holes above and below.
private struct V3FilmFrame: View {
    let cover: CGRect
    var body: some View {
        let band = max(14, cover.width * 0.09)
        Canvas { context, _ in
            for y in [cover.minY - band, cover.maxY] {
                let strip = CGRect(x: cover.minX - band * 0.4, y: y, width: cover.width + band * 0.8, height: band)
                context.fill(Path(roundedRect: strip, cornerRadius: 2), with: .color(Color(red: 0.07, green: 0.06, blue: 0.05).opacity(0.92)))
                let hole = CGSize(width: band * 0.42, height: band * 0.5)
                var x = strip.minX + hole.width
                while x < strip.maxX - hole.width {
                    context.fill(Path(roundedRect: CGRect(x: x, y: strip.midY - hole.height / 2, width: hole.width, height: hole.height), cornerRadius: 1.5),
                                 with: .color(Color(red: 0.86, green: 0.82, blue: 0.72).opacity(0.8)))
                    x += hole.width * 2
                }
            }
            context.stroke(Path(cover), with: .color(.black.opacity(0.9)), lineWidth: 2)
        }
        .allowsHitTesting(false)
    }
}

/// 书页: the cover becomes a plate tipped into the book, with a thin rule and a caption line.
private struct V3BookPlate: View {
    let cover: CGRect
    var body: some View {
        let inset: CGFloat = -10
        ZStack(alignment: .topLeading) {
            Rectangle().strokeBorder(Color(red: 0.92, green: 0.86, blue: 0.72).opacity(0.75), lineWidth: 1)
                .frame(width: cover.width - inset * 2, height: cover.height - inset * 2)
                .offset(x: cover.minX + inset, y: cover.minY + inset)
            Rectangle().fill(Color(red: 0.62, green: 0.48, blue: 0.30).opacity(0.18)).blendMode(.multiply)
                .frame(width: cover.width, height: cover.height).offset(x: cover.minX, y: cover.minY)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - The 情境 panel

/// Cards for each scene. Hovering a card previews it on the real picture;
/// clicking keeps it.
struct V3ScenePicker: View {
    @ObservedObject var settings: AppSettingsStore
    @Binding var preview: V3Room?
    @ObservedObject private var weather = V3WeatherWatcher.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            V3PanelSection(title: "情境")
            card(.off)
            V3PanelSection(title: "窗")
            grid(V3Room.rooms)
            V3PanelSection(title: "光影")
            grid(V3Room.lights)
            V3PanelSection(title: "材质")
            grid(V3Room.materials)
            let shown = preview ?? settings.v3Room
            if shown != .off {
                Text(shown == .weather ? shown.detail + "。现在：" + weather.room.title : shown.detail)
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
                Toggle("整套换装", isOn: $settings.v3RoomRestyles)
                    .help("开：情境同时换上自己的版式、歌词位置与效果、播放栏和控件质感。关：只加情境本身，版式保持你自己的设置。画面或文字手动调整后立即生效，重新选择情境可恢复整套搭配。")
                Toggle("副歌时刻", isOn: $settings.v3RoomOpensOnChorus)
                    .help("唱到副歌时，情境有自己的变化：雨更大、开上桥、划过流星、按下快门……")
            }
        }
        .onDisappear { preview = nil }
    }

    private func grid(_ scenes: [V3Room]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            ForEach(scenes) { card($0) }
        }
    }

    private func card(_ scene: V3Room) -> some View {
        let selected = settings.v3Room == scene
        return Button { settings.selectV3Room(scene); preview = nil } label: {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Self.swatch(scene))
                    Image(systemName: Self.symbol(scene)).font(.system(size: 14, weight: .medium)).foregroundStyle(.white.opacity(0.92))
                }
                .frame(width: 38, height: 30)
                Text(scene == .off ? "不使用情境" : scene.title).font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(5)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(selected ? 0.13 : 0.04)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.primary.opacity(selected ? 0.35 : 0), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { preview = scene } else if preview == scene { preview = nil }
        }
        .accessibilityLabel(scene == .off ? "不使用情境" : scene.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(scene.detail)
    }

    static func symbol(_ scene: V3Room) -> String {
        switch scene {
        case .off: return "circle.slash"
        case .rain: return "cloud.rain"
        case .train: return "tram"
        case .snow: return "snowflake"
        case .weather: return "location"
        case .book: return "book"
        case .polaroid: return "photo"
        case .stars: return "sparkles"
        case .fog: return "hand.draw"
        case .aurora: return "wind"
        case .water: return "water.waves"
        case .film: return "film"
        case .clearNight: return "moon.stars"
        }
    }

    static func swatch(_ scene: V3Room) -> LinearGradient {
        let colors: [Color]
        switch scene {
        case .off: colors = [Color(white: 0.45), Color(white: 0.3)]
        case .rain, .clearNight: colors = [Color(red: 0.16, green: 0.22, blue: 0.38), Color(red: 0.55, green: 0.38, blue: 0.22)]
        case .train: colors = [Color(red: 0.08, green: 0.1, blue: 0.2), Color(red: 0.75, green: 0.55, blue: 0.25)]
        case .snow: colors = [Color(red: 0.55, green: 0.65, blue: 0.82), Color(red: 0.7, green: 0.38, blue: 0.18)]
        case .weather: colors = [Color(red: 0.25, green: 0.45, blue: 0.7), Color(red: 0.4, green: 0.6, blue: 0.75)]
        case .book: colors = [Color(red: 0.62, green: 0.5, blue: 0.32), Color(red: 0.38, green: 0.27, blue: 0.16)]
        case .polaroid: colors = [Color(red: 0.85, green: 0.78, blue: 0.66), Color(red: 0.6, green: 0.5, blue: 0.42)]
        case .stars: colors = [Color(red: 0.05, green: 0.06, blue: 0.2), Color(red: 0.2, green: 0.15, blue: 0.4)]
        case .film: colors = [Color(red: 0.25, green: 0.2, blue: 0.15), Color(red: 0.08, green: 0.07, blue: 0.06)]
        case .fog: colors = [Color(white: 0.75), Color(red: 0.45, green: 0.52, blue: 0.62)]
        case .aurora: colors = [Color(red: 0.1, green: 0.75, blue: 0.55), Color(red: 0.35, green: 0.2, blue: 0.6)]
        case .water: colors = [Color(red: 0.1, green: 0.5, blue: 0.65), Color(red: 0.05, green: 0.25, blue: 0.4)]
        }
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

// MARK: - Pointer and ripples

/// Where the pointer has been and where ripples started. Read by the scene's own
/// timeline, never published, so moving the mouse never re-renders the window.
@MainActor
final class V3SceneInput {
    static let shared = V3SceneInput()
    struct Mark { let point: CGPoint; let time: TimeInterval }
    private(set) var trail: [Mark] = []
    private(set) var ripples: [Mark] = []
    private var lastRipple: Mark?

    func pointer(_ point: CGPoint?, scene: V3Room) {
        guard let point else { return }
        let now = Date.timeIntervalSinceReferenceDate
        if scene == .fog {
            if let last = trail.last, hypot(last.point.x - point.x, last.point.y - point.y) < 4 { return }
            trail.append(Mark(point: point, time: now))
            if trail.count > 600 { trail.removeFirst(trail.count - 600) }
        } else if scene == .water {
            if let lastRipple, now - lastRipple.time < 0.22 || hypot(lastRipple.point.x - point.x, lastRipple.point.y - point.y) < 36 { return }
            ripple(at: point)
        }
    }

    func ripple(at point: CGPoint) {
        let mark = Mark(point: point, time: Date.timeIntervalSinceReferenceDate)
        lastRipple = mark
        ripples.append(mark)
        if ripples.count > 24 { ripples.removeFirst(ripples.count - 24) }
    }

    func forget(olderThan age: TimeInterval) {
        let now = Date.timeIntervalSinceReferenceDate
        trail.removeAll { now - $0.time > age }
        ripples.removeAll { now - $0.time > 4 }
    }
}

// MARK: - Light-sensitive helpers

extension Color {
    /// The same colour turned around the hue wheel, kept bright and saturated
    /// enough to read as light.
    func v3Turned(_ hueShift: Double, saturation: Double = 0.55, brightness: Double = 0.95) -> Color {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .systemTeal
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        ns.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let hue = (Double(h) + hueShift).truncatingRemainder(dividingBy: 1)
        return Color(hue: hue < 0 ? hue + 1 : hue, saturation: max(saturation, Double(s)), brightness: brightness)
    }
}

/// How strong added light can be on this cover: bright covers get less, so a
/// scene never washes the picture out.
func v3SceneLight(_ luminance: Double) -> Double { min(1, max(0.45, 1.25 - luminance * 1.1)) }

// MARK: - 雨滴玻璃

// MARK: - 起雾的窗

/// Fog over the whole window: the picture behind is blurred and milky. Where
/// the pointer passes it is wiped clear; the fog closes back in over 20 s, and
/// a few wiped strokes leave drips running down.
struct V3FogGlass: View {
    let size: CGSize
    let thin: Bool
    let running: Bool
    static let regrow: TimeInterval = 20

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !running)) { timeline in
            let now = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Color.white.opacity(thin ? 0.03 : 0.06)
                V3Speckle(seed: 53, count: 700, color: .white, opacity: 0.35)
            }
            .mask {
                Canvas { context, canvas in
                    context.fill(Path(CGRect(origin: .zero, size: canvas)), with: .color(.white))
                    context.blendMode = .destinationOut
                    // Where the lyrics are read, the glass stays half clear, as if breathed on less.
                    let reading = CGRect(x: canvas.width * 0.3, y: canvas.height * 0.12, width: canvas.width * 0.76, height: canvas.height * 0.76)
                    context.fill(Path(CGRect(origin: .zero, size: canvas)), with: .radialGradient(
                        Gradient(stops: [.init(color: .black.opacity(0.55), location: 0), .init(color: .black.opacity(0.4), location: 0.35),
                                         .init(color: .black.opacity(0.2), location: 0.7), .init(color: .clear, location: 1)]),
                        center: CGPoint(x: reading.midX, y: reading.midY), startRadius: 0, endRadius: max(reading.width, reading.height) * 0.95))
                    let trail = V3SceneInput.shared.trail
                    for (index, mark) in trail.enumerated() {
                        let age = now - mark.time
                        guard age < Self.regrow else { continue }
                        let clear = min(1, 1.25 - age / Self.regrow * 1.25)
                        var path = Path()
                        if index > 0, mark.time - trail[index - 1].time < 0.25 {
                            path.move(to: trail[index - 1].point)
                            path.addLine(to: mark.point)
                        } else {
                            path.addEllipse(in: CGRect(x: mark.point.x - 18, y: mark.point.y - 18, width: 36, height: 36))
                        }
                        context.stroke(path, with: .color(.black.opacity(clear)), style: StrokeStyle(lineWidth: 44, lineCap: .round, lineJoin: .round))
                        // Drips from about one point in eight, growing for a few seconds.
                        if index % 8 == 3, age > 1 {
                            let length = min(90, (age - 1) * 18)
                            var drip = Path()
                            drip.move(to: CGPoint(x: mark.point.x, y: mark.point.y + 18))
                            drip.addLine(to: CGPoint(x: mark.point.x + 1, y: mark.point.y + 18 + length))
                            context.stroke(drip, with: .color(.black.opacity(clear * 0.8)), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        }
                    }
                }
                .blur(radius: 6)
            }
            .opacity(thin ? 0.6 : 0.88)
        }
        .frame(width: size.width, height: size.height)
        .onAppear { V3SceneInput.shared.forget(olderThan: Self.regrow) }
    }
}

// MARK: - 极光

/// Curtains of light in the cover's colours, behind the lyrics. Each is a row of
/// rays bright at the lower edge and fading upwards, drifting slowly.
struct V3Aurora: View {
    /// The cover's own colours when it has some; a classic green, teal and violet sky when it does not.
    static func palette(_ accent: Color) -> [Color] {
        let ns = NSColor(accent).usingColorSpace(.sRGB) ?? .white
        if ns.saturationComponent < 0.18 {
            return [Color(hue: 0.38, saturation: 0.75, brightness: 0.95), Color(hue: 0.47, saturation: 0.7, brightness: 0.9),
                    Color(hue: 0.78, saturation: 0.55, brightness: 0.9)]
        }
        return [accent.v3Turned(0, saturation: 0.7), accent.v3Turned(0.14, saturation: 0.7), accent.v3Turned(-0.13, saturation: 0.6)]
    }
    let size: CGSize
    let accent: Color
    let energy: Double
    let running: Bool

    var body: some View {
        let colors = V3Aurora.palette(accent)
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: !running)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, canvas in
                for curtain in 0..<3 {
                    let c = Double(curtain)
                    let base = canvas.height * (0.26 + 0.11 * c)
                    let color = colors[curtain]
                    // The curtain's lower edge waves slowly; its height swells in places,
                    // which reads as the folds of real aurora.
                    func edge(_ u: Double) -> CGFloat {
                        base + canvas.height * CGFloat(0.07 * sin(u * 3.1 + t * 0.11 + c * 1.9) + 0.035 * sin(u * 8.3 - t * 0.17 + c))
                    }
                    func reach(_ u: Double) -> CGFloat {
                        let fold = 0.5 + 0.5 * sin(u * 11 + sin(u * 4 + t * 0.3 + c) * 2 + t * 0.2)
                        return canvas.height * CGFloat(0.12 + 0.2 * fold) * CGFloat(0.7 + 0.5 * energy)
                    }
                    let steps = 80
                    var shape = Path()
                    shape.move(to: CGPoint(x: -20, y: edge(0)))
                    for i in 0...steps {
                        let u = Double(i) / Double(steps)
                        shape.addLine(to: CGPoint(x: -20 + (canvas.width + 40) * CGFloat(u), y: edge(u)))
                    }
                    for i in stride(from: steps, through: 0, by: -1) {
                        let u = Double(i) / Double(steps)
                        shape.addLine(to: CGPoint(x: -20 + (canvas.width + 40) * CGFloat(u), y: edge(u) - reach(u)))
                    }
                    shape.closeSubpath()
                    let alpha = min(0.95, (0.85 - 0.15 * c) * energy)
                    let top = base - canvas.height * 0.45
                    context.fill(shape, with: .linearGradient(
                        Gradient(stops: [.init(color: color.opacity(0), location: 0), .init(color: color.opacity(alpha * 0.45), location: 0.6),
                                         .init(color: color.opacity(alpha), location: 1)]),
                        startPoint: CGPoint(x: 0, y: top), endPoint: CGPoint(x: 0, y: base + canvas.height * 0.08)))
                }
            }
            .blur(radius: 24)
            .blendMode(.screen)
        }
        .frame(width: size.width, height: size.height)
    }
}

// MARK: - 水面

/// Pool light: aqua, leaning towards the cover's hue when it has one.
enum V3WaterLight {
    static func tint(_ accent: Color) -> Color {
        let ns = NSColor(accent).usingColorSpace(.sRGB) ?? .white
        guard ns.saturationComponent >= 0.18 else { return Color(red: 0.45, green: 0.9, blue: 1) }
        // Keep it water: an aqua base nudged a little towards the cover's hue.
        let hue = Double(ns.hueComponent)
        let aqua = 0.52
        let nudged = aqua + max(-0.06, min(0.06, (hue - aqua) * 0.25))
        return Color(hue: nudged, saturation: 0.55, brightness: 1)
    }
}

/// When no foreground cover is shown, 拍立得 pins a small print of the cover in the
/// lower left instead, with the line written on it.
struct V3MiniPolaroid: View {
    let artworkURL: URL?
    let line: String
    @State private var cover: NSImage?
    var body: some View {
        VStack(spacing: 4) {
            Group {
                if let cover { Image(nsImage: cover).resizable().scaledToFill() } else { Color(white: 0.25) }
            }
            .frame(width: 112, height: 112).clipped()
            Text(line.isEmpty ? " " : line).font(V3SceneHand.font(size: 11))
                .foregroundStyle(Color(red: 0.16, green: 0.17, blue: 0.24).opacity(0.86))
                .lineLimit(1).minimumScaleFactor(0.5).frame(width: 112, height: 18)
        }
        .padding(EdgeInsets(top: 7, leading: 7, bottom: 6, trailing: 7))
        .background(Color(red: 0.97, green: 0.96, blue: 0.93))
        .rotationEffect(.degrees(-4))
        .shadow(color: .black.opacity(0.4), radius: 10, y: 5)
        .allowsHitTesting(false)
        .task(id: artworkURL) { if let artworkURL { cover = await ArtworkImageLoader.shared.image(for: artworkURL) } }
    }
}

// MARK: - Each scene's whole look

/// How a scene dresses the controls: the toolbar, player card and edge pill take
/// its material instead of plain glass.
struct V3SceneChrome: Equatable {
    var tint: Color
    var strength: Double
    /// Corner radius for the player card; nil keeps the usual one.
    var cardRadius: CGFloat?
}

private struct V3SceneChromeKey: EnvironmentKey { static let defaultValue: V3SceneChrome? = nil }
extension EnvironmentValues {
    var v3SceneChrome: V3SceneChrome? {
        get { self[V3SceneChromeKey.self] }
        set { self[V3SceneChromeKey.self] = newValue }
    }
}

/// A scene's layout and lyric treatment. Applied only while the scene is on and
/// never written over the user's own choices.
struct V3SceneLook: Equatable {
    var listeningScene: V3ListeningScene?
    var lyricsPosition: String?
    var lyricStyle: V3LyricStyle?
    var playback: V3PlaybackPresentation?
    var progress: V3ProgressStyle?
    var chrome: V3SceneChrome?
    /// 行宽 for this scene; nil keeps the user's.
    var lyricWidth: Double?
}

struct V3RoomOverrides: OptionSet {
    let rawValue: Int

    static let layout = Self(rawValue: 1 << 0)
    static let lyricsPosition = Self(rawValue: 1 << 1)
    static let lyricStyle = Self(rawValue: 1 << 2)
    static let playback = Self(rawValue: 1 << 3)
    static let progress = Self(rawValue: 1 << 4)
    static let lyricWidth = Self(rawValue: 1 << 5)
}

/// Resolved by each listening surface. Reading or previewing a room never changes preferences.
struct V3ListeningPresentation {
    let scene: V3ListeningScene?
    let renderer: V3ArtworkPresentation
    let ambientTreatment: V3AmbientTreatment
    let usesAutomaticAmbient: Bool
    let lyricsPosition: String
    let lyricStyle: V3LyricStyle
    let playback: V3PlaybackPresentation
    let progress: V3ProgressStyle
    let chrome: V3SceneChrome?
    let lyricWidth: Double

    @MainActor
    init(settings: AppSettingsStore, room: V3Room, accent: Color = .white,
         usesSavedRoomChoices: Bool = true,
         artworkPreview: V3ArtworkPresentation? = nil, previewScene: V3ListeningScene? = nil,
         automaticAmbient: V3SceneFamily.Entry? = nil) {
        let look = settings.v3RoomRestyles ? room.look(accent: accent) : V3SceneLook()
        let overrides = usesSavedRoomChoices ? settings.v3RoomOverrides : []
        let roomScene = overrides.contains(.layout) ? nil : look.listeningScene
        let baseScene = settings.v3ListeningScene
        usesAutomaticAmbient = settings.v3AmbientAutomatic && artworkPreview == nil && roomScene == nil
            && V3SceneFamily.cards[0].entries.contains(where: { V3SceneFamily.inUse($0, settings: settings) })
        let coverLook = usesAutomaticAmbient ? automaticAmbient : nil
        scene = artworkPreview == nil ? (roomScene ?? coverLook?.scene ?? baseScene) : previewScene
        ambientTreatment = coverLook?.treatment ?? settings.v3AmbientTreatment
        if let artworkPreview {
            renderer = artworkPreview
        } else if let coverLook {
            renderer = coverLook.renderer
        } else if let roomScene, roomScene != baseScene {
            renderer = settings.v3Renderer(for: roomScene)
        } else {
            renderer = settings.v3ArtworkPresentation
        }
        let roomPosition = artworkPreview == nil && !overrides.contains(.layout)
            && !overrides.contains(.lyricsPosition) ? look.lyricsPosition : nil
        lyricsPosition = roomPosition ?? settings.v3PreviewLyricsPosition(for: renderer, scene: scene)
        lyricStyle = (overrides.contains(.lyricStyle) ? nil : look.lyricStyle) ?? settings.v3LyricStyle
        playback = (overrides.contains(.playback) ? nil : look.playback) ?? settings.v3PlaybackPresentation
        progress = (overrides.contains(.progress) ? nil : look.progress) ?? settings.v3ProgressStyle
        lyricWidth = (overrides.contains(.lyricWidth) ? nil : look.lyricWidth) ?? settings.v3LyricWidth
        chrome = look.chrome
    }
}

extension V3Room {
    /// Chosen so each scene reads as one picture: where the lyrics sit, how the
    /// sung line is drawn, how the player shows, and what the controls are made of.
    func look(accent: Color) -> V3SceneLook {
        switch self {
        case .off, .weather:
            return V3SceneLook()
        case .rain:
            return V3SceneLook(listeningScene: .originalAmbient, lyricsPosition: "right", lyricStyle: .depth, playback: .standard,
                               progress: .waveform, chrome: V3SceneChrome(tint: Color(red: 0.55, green: 0.68, blue: 0.85), strength: 0.22, cardRadius: 20))
        case .clearNight:
            return V3SceneLook(listeningScene: .originalAmbient, lyricsPosition: "right", lyricStyle: .standard, playback: .standard,
                               progress: .standard, chrome: V3SceneChrome(tint: Color(red: 0.45, green: 0.52, blue: 0.75), strength: 0.2, cardRadius: 20))
        case .fog:
            return V3SceneLook(listeningScene: .focusedLyrics, lyricsPosition: "center", lyricStyle: .standard, playback: .onHover,
                               progress: .standard, chrome: V3SceneChrome(tint: .white, strength: 0.28, cardRadius: 24), lyricWidth: 1.35)
        case .snow:
            return V3SceneLook(listeningScene: .originalAmbient, lyricsPosition: "right", lyricStyle: .lightColor, playback: .standard,
                               progress: .standard, chrome: V3SceneChrome(tint: Color(red: 1, green: 0.88, blue: 0.74), strength: 0.24, cardRadius: 22))
        case .train:
            return V3SceneLook(listeningScene: .coverPhoto, lyricsPosition: "left", lyricStyle: .single, playback: .standard,
                               progress: .lyricTicks, chrome: V3SceneChrome(tint: Color(white: 0.55), strength: 0.3, cardRadius: 28), lyricWidth: 1.35)
        case .aurora:
            return V3SceneLook(listeningScene: .flowingField, lyricsPosition: "center", lyricStyle: .lightColor, playback: .onHover,
                               progress: .standard, chrome: V3SceneChrome(tint: accent, strength: 0.2, cardRadius: nil), lyricWidth: 1.35)
        case .water:
            return V3SceneLook(listeningScene: .flowingField, lyricsPosition: "center", lyricStyle: .depth, playback: .onHover,
                               progress: .waveform, chrome: V3SceneChrome(tint: Color(red: 0.45, green: 0.88, blue: 0.95), strength: 0.22, cardRadius: 26), lyricWidth: 1.2)
        case .book:
            return V3SceneLook(listeningScene: .linerNotes, lyricsPosition: nil, lyricStyle: .typewriter, playback: .standard,
                               progress: .lyricTicks, chrome: V3SceneChrome(tint: Color(red: 0.82, green: 0.7, blue: 0.5), strength: 0.34, cardRadius: 6))
        case .polaroid:
            return V3SceneLook(listeningScene: .originalAmbient, lyricsPosition: "right", lyricStyle: .standard, playback: .standard,
                               progress: .standard, chrome: V3SceneChrome(tint: Color(red: 0.97, green: 0.95, blue: 0.9), strength: 0.3, cardRadius: 4))
        case .stars:
            return V3SceneLook(listeningScene: .focusedLyrics, lyricsPosition: "center", lyricStyle: .lightColor, playback: .windowEdge,
                               progress: .standard, chrome: V3SceneChrome(tint: Color(red: 0.2, green: 0.25, blue: 0.55), strength: 0.36, cardRadius: nil), lyricWidth: 1.35)
        case .film:
            return V3SceneLook(listeningScene: .originalAmbient, lyricsPosition: "right", lyricStyle: .single, playback: .standard,
                               progress: .standard, chrome: V3SceneChrome(tint: Color(white: 0.08), strength: 0.5, cardRadius: 3), lyricWidth: 1.2)
        }
    }
}


/// 行宽: how far a lyric line may run before it wraps. 1 is the established
/// 680 pt reading measure; 情境 and the 文字 panel can open it up.
enum V3LyricWidth {
    static let options: [(String, Double)] = [("标准", 1), ("宽", 1.35), ("满幅", 1.9)]
}


extension Color {
    /// This colour with a share of another mixed in.
    func v3Mixed(with other: Color, _ share: Double) -> Color {
        let a = NSColor(self).usingColorSpace(.sRGB) ?? .black
        let b = NSColor(other).usingColorSpace(.sRGB) ?? .black
        let t = CGFloat(min(1, max(0, share)))
        return Color(red: Double(a.redComponent * (1 - t) + b.redComponent * t),
                     green: Double(a.greenComponent * (1 - t) + b.greenComponent * t),
                     blue: Double(a.blueComponent * (1 - t) + b.blueComponent * t))
    }
}

/// The cover takes part in the scene instead of sitting under it: a touch of
/// the scene's weather or light on the cover itself, clipped to its shape.
private struct V3CoverBlend: View {
    let scene: V3Room
    let cover: CGRect
    let accent: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        ZStack {
            switch scene {
            case .rain, .clearNight:
                // Wet glass in front of the print: a sheen across the top corner.
                LinearGradient(colors: [.white.opacity(0.16), .clear, .clear], startPoint: .topLeading, endPoint: .center)
                    .blendMode(.screen)
            case .snow:
                V3Frost(size: cover.size).opacity(0.7)
            case .fog:
                V3MistedEdges(size: cover.size, strength: 0.22)
            case .water:
                V3WaterCaustics(size: cover.size, accent: accent, strength: 0.35, running: !reduceMotion, origin: cover.origin)
            case .train:
                V3PassingReflection(running: !reduceMotion)
            case .aurora:
                LinearGradient(colors: V3Aurora.palette(accent).map { $0.opacity(0.22) }, startPoint: .top, endPoint: .bottom)
                    .blendMode(.screen)
            case .stars:
                Color(red: 0.05, green: 0.06, blue: 0.18).opacity(0.18).blendMode(.multiply)
            default:
                Color.clear
            }
        }
        .frame(width: cover.width, height: cover.height)
        .clipShape(shape)
        // Some scenes also light the cover from outside.
        .background {
            if scene == .aurora {
                shape.fill(Color.clear)
                    .shadow(color: V3Aurora.palette(accent)[1].opacity(0.55), radius: 26)
            } else if scene == .snow {
                shape.fill(Color.clear).shadow(color: Color(red: 1, green: 0.6, blue: 0.3).opacity(0.35), radius: 22, y: 10)
            }
        }
        .position(x: cover.midX, y: cover.midY)
        .allowsHitTesting(false)
    }
}

/// 夜行列车 on the cover: a light from outside sliding across its glass.
private struct V3PassingReflection: View {
    let running: Bool
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !running)) { timeline in
            let cycle = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 5) / 5
            GeometryReader { geometry in
                LinearGradient(colors: [.clear, .white.opacity(0.22), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: geometry.size.width * 0.4)
                    .rotationEffect(.degrees(18))
                    .offset(x: geometry.size.width * (1.3 - cycle * 2))
                    .blendMode(.screen)
            }
        }
    }
}

// MARK: - GPU versions (V3SceneShaders.metal)

/// 雨滴玻璃 on the GPU: thousands of beads and sliding drops, each bending the cover.
struct V3RainLens: View {
    let size: CGSize
    let artworkURL: URL?
    let running: Bool
    var heavy = false
    @State private var cover: NSImage?
    private static let blank = NSImage(size: NSSize(width: 2, height: 2), flipped: false) { rect in
        NSColor(white: 0.3, alpha: 1).setFill(); rect.fill(); return true
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !running)) { timeline in
            let t = Float(timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600))
            Rectangle().fill(.white)
                .colorEffect(ShaderLibrary.v3RainLens(.float2(size), .float(t), .float(heavy ? 1 : 0),
                                                      .image(Image(nsImage: cover ?? Self.blank))))
        }
        .frame(width: size.width, height: size.height)
        .task(id: artworkURL) {
            cover = nil
            if let artworkURL { cover = await ArtworkImageLoader.shared.image(for: artworkURL) }
        }
    }
}

/// 水面 on the GPU: caustic light computed every frame, with the ripples bending it.
struct V3WaterCaustics: View {
    let size: CGSize
    let accent: Color
    let strength: Double
    let running: Bool
    /// Ripples are given in this view's own coordinates; the cover passes its offset.
    var origin: CGPoint = .zero

    var body: some View {
        let tint = V3WaterLight.tint(accent)
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !running)) { timeline in
            let now = timeline.date.timeIntervalSinceReferenceDate
            let t = Float(now.truncatingRemainder(dividingBy: 3600))
            let ripples = V3SceneInput.shared.ripples.suffix(12).flatMap { mark -> [Float] in
                [Float(mark.point.x - origin.x), Float(mark.point.y - origin.y), Float(now - mark.time)]
            }
            Rectangle().fill(.white)
                .colorEffect(ShaderLibrary.v3Caustics(.float2(size), .float(t), .color(tint), .float(Float(strength)),
                                                      .floatArray(ripples.isEmpty ? [0, 0, 99] : ripples)))
                .blendMode(.plusLighter)
        }
        .frame(width: size.width, height: size.height)
    }
}
