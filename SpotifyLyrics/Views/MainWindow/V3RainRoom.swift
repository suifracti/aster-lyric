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
    case off = "", rain, train, snow, weather, book, polaroid, stars, film
    /// 跟随天气 on a dry night: the rain room's window without rain.
    case clearNight
    var id: String { rawValue }

    /// What the picker offers, in groups: rooms, then materials.
    static let rooms: [V3Room] = [.rain, .train, .snow, .weather]
    static let materials: [V3Room] = [.book, .polaroid, .stars, .film]

    var title: String {
        switch self {
        case .off: return "关闭"
        case .rain: return "雨夜窗边"
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
    var isRoom: Bool { [.rain, .train, .snow, .weather, .clearNight].contains(self) }
    var detail: String {
        switch self {
        case .off: return "只有听歌画面"
        case .rain: return "雨顺着玻璃往下淌，窗棂的影子落在画面上，台灯从右下角照过来。副歌时雨更大，远处闪电"
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
    @MainActor func resolved(_ weather: V3WeatherWatcher = .shared) -> V3Room { self == .weather ? weather.room : self }
}

/// Between the backdrop and the lyrics: the scene's light and what is behind the glass.
struct V3SceneBackLayer: View {
    let scene: V3Room
    let context: V3RoomContext
    let playing: Bool
    var speed: Double = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var moving: Bool { playing && !reduceMotion }
    private var chorus: Bool { context.chorus && context.opensOnChorus }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                switch scene {
                case .off, .weather, .film:
                    Color.clear
                case .rain, .clearNight:
                    // A cooler, darker night, the window's cross cast over the picture, and the lamp.
                    Color(red: 0.05, green: 0.08, blue: 0.16).opacity(0.28).blendMode(.multiply)
                    V3WindowShadow(size: size)
                    RadialGradient(colors: [Color(red: 1, green: 0.70, blue: 0.40).opacity(0.30), .clear],
                                   center: UnitPoint(x: 1.0, y: 1.0), startRadius: 0, endRadius: max(size.width, size.height) * 0.6)
                        .blendMode(.screen)
                    if scene == .clearNight { V3Speckle(seed: 41, count: 90, color: .white, opacity: 0.5).mask(LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .center)) }
                    if scene == .rain, chorus { V3Lightning(running: moving) }
                case .train:
                    Color(red: 0.03, green: 0.04, blue: 0.08).opacity(0.35).blendMode(.multiply)
                    V3PassingLights(playing: moving, size: size, speed: speed * (chorus ? 1.25 : 1), density: chorus ? 2 : 1)
                    if chorus {
                        // The bridge: the city spread out below.
                        LinearGradient(colors: [.clear, Color(red: 1, green: 0.72, blue: 0.38).opacity(0.28)], startPoint: .center, endPoint: .bottom)
                            .blendMode(.screen).transition(.opacity)
                    }
                case .snow:
                    Color(red: 0.55, green: 0.65, blue: 0.85).opacity(0.10).blendMode(.screen)
                    V3Firelight(size: size)
                case .book:
                    // Old paper under a lamp: sepia, grain, warm light from the upper left.
                    Color(red: 0.62, green: 0.48, blue: 0.30).opacity(0.30).blendMode(.multiply)
                    V3Speckle(seed: 31, count: 1500, color: Color(red: 0.95, green: 0.85, blue: 0.65), opacity: 0.10)
                    RadialGradient(colors: [Color(red: 1, green: 0.85, blue: 0.6).opacity(0.28), .clear],
                                   center: UnitPoint(x: 0.1, y: 0.0), startRadius: 0, endRadius: max(size.width, size.height) * 0.8)
                        .blendMode(.screen)
                case .polaroid:
                    // A faded print: lifted blacks and a warm cast over the whole picture.
                    Color(red: 1, green: 0.93, blue: 0.80).opacity(0.08).blendMode(.screen)
                    Color(red: 1, green: 0.86, blue: 0.68).opacity(0.14).blendMode(.multiply)
                case .stars:
                    Color(red: 0.02, green: 0.03, blue: 0.10).opacity(0.55).blendMode(.multiply)
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
                    switch scene {
                    case .polaroid:
                        V3PolaroidMount(cover: cover, line: context.currentLine, shutterAt: shutterAt,
                                        room: V3PolaroidMount.room(below: cover, player: player))
                    case .film: V3FilmFrame(cover: cover)
                    case .book: V3BookPlate(cover: cover)
                    default: EmptyView()
                    }
                }
                if scene == .polaroid || scene == .stars {
                    let anchor = cover.map { CGPoint(x: $0.maxX - 6, y: $0.maxY + (scene == .polaroid ? $0.width * 0.24 : 22)) }
                        ?? CGPoint(x: 34, y: size.height - 30)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var turnedAt: Date?
    @State private var flareAt: Date?
    private var moving: Bool { playing && !reduceMotion }
    private var chorus: Bool { context.chorus && context.opensOnChorus }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                switch scene {
                case .rain:
                    V3ParticleView(kind: .rain, running: moving).opacity(chorus ? 0.95 : 0.6)
                    if chorus { V3ParticleView(kind: .rain, running: moving).opacity(0.5).scaleEffect(1.3) }
                    V3MistedEdges(size: size, strength: 0.09)
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
                case .off, .weather, .polaroid, .stars:
                    Color.clear
                }
            }
            .frame(width: size.width, height: size.height)
            .animation(.easeInOut(duration: 1.2), value: chorus)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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
            V3PanelSection(title: "材质")
            grid(V3Room.materials)
            let shown = preview ?? settings.v3Room
            if shown != .off {
                Text(shown == .weather ? shown.detail + "。现在：" + weather.room.title : shown.detail)
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
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
        return Button { settings.v3Room = scene; preview = nil } label: {
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
        }
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
