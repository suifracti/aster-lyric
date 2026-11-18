import CoreLocation
import SwiftUI

/// 情境 (A13, after Tauon's room, reworked 2026-11-18). The first 雨夜房间 drew
/// the listening view at 62% as a monitor on a desk, which left the lyrics tiny.
/// Now the listening view stays close to full size and is the glass (or page,
/// photo, film frame) of the scene: the scene lives in a thin margin and on top
/// of the glass, never under the pointer. Layout and hit-testing inside are
/// unchanged, and switching scenes only redraws the surroundings.
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
        case .rain: return "画面是一扇夜里的木窗：雨顺着玻璃往下淌，台灯的暖光从右下角漫进来"
        case .train: return "画面是夜车的车窗：窗外的灯一串串掠过，快慢跟着这首歌的节拍"
        case .snow: return "画面是雪夜小屋的窗：窗外落雪，玻璃四角结霜，炉火在下方轻轻跳动"
        case .weather: return "按你所在地现在的天气，在雨夜、雪夜和晴夜的窗之间切换；需要大致位置"
        case .book: return "画面摊在一本书上：纸边、书脊的阴影，唱完一段翻一页"
        case .polaroid: return "画面是一张拍立得，正在唱的一句手写在下方的白边上"
        case .stars: return "每句歌词是一颗星，唱过的星连成线，一首歌唱完留下它自己的星图"
        case .film: return "画面放在一条胶片上：两侧齿孔，颗粒、偶尔的划痕和放映机的轻微闪烁"
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

struct V3RoomModifier: ViewModifier {
    let room: V3Room
    let playing: Bool
    var context = V3RoomContext()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var weather = V3WeatherWatcher.shared
    @State private var bpm: Double?

    /// The scene actually drawn: 跟随天气 becomes one of the windows; a room
    /// opens during a chorus when the user leaves that on.
    private var look: V3Room {
        if room == .weather { return weather.room }
        return room
    }
    private var opened: Bool { look.isRoom && context.opensOnChorus && context.chorus }

    /// The margin the scene takes around the glass, in points.
    static func margin(for size: CGSize) -> CGFloat {
        min(54, max(22, min(size.width, size.height) * 0.06))
    }

    /// The glass keeps 82–92% of the window, so lyrics stay readable.
    static func glass(in size: CGSize, room: V3Room) -> CGRect {
        guard room != .off, size.width > 0, size.height > 0 else { return CGRect(origin: .zero, size: size) }
        let m = margin(for: size)
        let side: CGFloat, top: CGFloat, bottom: CGFloat
        switch room {
        case .film: (side, top, bottom) = (max(m, 34), m * 0.45, m * 0.45)
        case .train: (side, top, bottom) = (m, m, m)
        case .book: (side, top, bottom) = (m * 1.1, m * 0.8, m * 1.2)
        case .polaroid: (side, top, bottom) = (m * 0.7, m * 0.7, max(56, size.height * 0.13))
        case .stars: (side, top, bottom) = (m * 0.7, m * 0.7, m * 0.7)
        default: (side, top, bottom) = (m, m, m * 1.35)
        }
        let scale = min((size.width - 2 * side) / size.width, (size.height - top - bottom) / size.height)
        let width = size.width * scale, height = size.height * scale
        return CGRect(x: (size.width - width) / 2, y: top + (size.height - top - bottom - height) / 2, width: width, height: height)
    }

    static func cornerRadius(_ room: V3Room) -> CGFloat {
        switch room {
        case .off: return 0
        case .train: return 30
        case .rain, .snow, .weather, .clearNight: return 6
        case .film, .polaroid: return 3
        case .book: return 2
        case .stars: return 18
        }
    }

    func body(content: Content) -> some View {
        GeometryReader { geometry in
            let size = geometry.size
            let shown: V3Room = opened ? .off : look
            let glass = Self.glass(in: size, room: shown)
            let scale = glass.width / max(1, size.width)
            let radius = Self.cornerRadius(shown)
            let moving = playing && !reduceMotion
            ZStack(alignment: .topLeading) {
                V3RoomWall(room: look, size: size, glass: glass)
                    .overlay { if look.isRoom { V3DaylightTint(room: look) } }
                    .opacity(opened ? 0 : 1)
                content
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: radius / max(scale, 0.01), style: .continuous))
                    .scaleEffect(scale, anchor: .topLeading)
                    .offset(x: glass.minX, y: glass.minY)
                V3RoomGlass(room: look, playing: moving, glass: glass, radius: radius, context: context,
                            speed: (bpm ?? 110) / 110)
                V3RoomFrame(room: look, size: size, glass: glass, radius: radius, context: context)
                    .opacity(opened ? 0 : 1)
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.6, dampingFraction: 0.92), value: look)
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 1.1, dampingFraction: 0.95), value: opened)
        }
        .onChange(of: room, initial: true) { _, next in weather.setActive(next == .weather) }
        // 夜行列车 runs at the song's tempo when Spotify has it in its cache.
        .task(id: room == .train ? context.spotifyTrackID : nil) {
            bpm = nil
            guard room == .train, let id = context.spotifyTrackID else { return }
            let found = await Task.detached(priority: .utility) { SpotifyTrackAnalysis.load(trackID: id).bpm }.value
            if !Task.isCancelled { bpm = found.map { min(180, max(60, $0)) } }
        }
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
            case .rain, .clearNight, .weather:
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
            case .book:
                // The desk the book lies open on.
                LinearGradient(colors: [Color(red: 0.24, green: 0.16, blue: 0.10), Color(red: 0.12, green: 0.08, blue: 0.05)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [Color(red: 1, green: 0.8, blue: 0.5).opacity(0.25), .clear],
                               center: UnitPoint(x: 0.15, y: 0.0), startRadius: 0, endRadius: max(size.width, size.height) * 0.7)
                ZStack(alignment: .topLeading) {
                // The page block: a few page edges peeking out under the open page.
                ForEach(0..<4, id: \.self) { index in
                    let inset = CGFloat(index + 1) * 2.5
                    Rectangle()
                        .fill(Color(red: 0.93, green: 0.89, blue: 0.80).opacity(1 - Double(index) * 0.18))
                        .frame(width: glass.width + inset * 2, height: glass.height + inset * 2)
                        .offset(x: glass.minX - inset, y: glass.minY - inset * 0.4)
                        .shadow(color: .black.opacity(index == 3 ? 0.5 : 0), radius: 10, y: 6)
                }
                }
                .frame(width: size.width, height: size.height, alignment: .topLeading)
            case .polaroid:
                // A corkboard under a warm light.
                LinearGradient(colors: [Color(red: 0.42, green: 0.31, blue: 0.21), Color(red: 0.26, green: 0.18, blue: 0.12)],
                               startPoint: .top, endPoint: .bottom)
                V3Speckle(seed: 5, count: 1400, color: .black, opacity: 0.18)
                RadialGradient(colors: [.clear, .black.opacity(0.45)], center: .center,
                               startRadius: min(size.width, size.height) * 0.3, endRadius: max(size.width, size.height) * 0.75)
            case .stars:
                LinearGradient(colors: [Color(red: 0.03, green: 0.04, blue: 0.10), Color(red: 0.06, green: 0.05, blue: 0.14)],
                               startPoint: .top, endPoint: .bottom)
                V3Speckle(seed: 9, count: 260, color: .white, opacity: 0.55)
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
    var context = V3RoomContext()
    /// 夜行列车's speed: the song's tempo over 110 BPM.
    var speed: Double = 1

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
                V3PassingLights(playing: playing, size: glass.size, speed: speed)
                // The double glazing's faint reflection of the carriage.
                LinearGradient(colors: [.white.opacity(0.07), .clear, .clear, .white.opacity(0.04)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .blendMode(.screen)
            case .snow:
                V3ParticleView(kind: .snow, running: playing).opacity(0.85)
                V3Frost(size: glass.size)
            case .film:
                V3FilmGrain(playing: playing, size: glass.size)
            case .clearNight, .weather:
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 22).blur(radius: 16)
                RadialGradient(colors: [Color(red: 1, green: 0.72, blue: 0.42).opacity(0.14), .clear],
                               center: UnitPoint(x: 1, y: 1), startRadius: 0, endRadius: glass.width * 0.45)
                    .blendMode(.screen)
            case .book:
                V3BookPage(size: glass.size, stanza: context.stanza, animate: playing)
            case .polaroid:
                // Faded print: lifted blacks and a warm cast.
                Color(red: 1, green: 0.93, blue: 0.80).opacity(0.10).blendMode(.screen)
                Color(red: 1, green: 0.88, blue: 0.70).opacity(0.12).blendMode(.multiply)
                RadialGradient(colors: [.clear, .black.opacity(0.22)], center: .center,
                               startRadius: min(glass.width, glass.height) * 0.4, endRadius: max(glass.width, glass.height) * 0.75)
            case .stars:
                V3Constellation(size: glass.size, seed: context.trackKey, count: context.lineCount,
                                current: context.lineIndex, playing: playing)
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
    var speed: Double = 1

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
    var context = V3RoomContext()

    var body: some View {
        ZStack(alignment: .topLeading) {
            switch room {
            case .off:
                Color.clear
            case .rain, .clearNight, .weather:
                woodenFrame(dark: Color(red: 0.16, green: 0.10, blue: 0.07), light: Color(red: 0.32, green: 0.21, blue: 0.13))
            case .book:
                Color.clear
            case .polaroid:
                V3PolaroidMount(size: size, glass: glass, line: context.currentLine)
            case .stars:
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                    .frame(width: glass.width, height: glass.height)
                    .offset(x: glass.minX, y: glass.minY)
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

/// Fixed specks: dust on a corkboard, faint stars around the sky's frame.
private struct V3Speckle: View {
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

/// 书页: paper grain, the gutter's shadow down the middle, and a page turning
/// across the glass each time a new stanza starts.
private struct V3BookPage: View {
    let size: CGSize
    let stanza: Int
    let animate: Bool
    @State private var turnedAt: Date?

    var body: some View {
        ZStack {
            V3Speckle(seed: 31, count: 900, color: Color(red: 0.45, green: 0.35, blue: 0.2), opacity: 0.10)
            Color(red: 1, green: 0.95, blue: 0.84).opacity(0.06).blendMode(.screen)
            // The gutter: the two pages curve down into the spine.
            LinearGradient(stops: [.init(color: .clear, location: 0.44), .init(color: .black.opacity(0.28), location: 0.5),
                                   .init(color: .clear, location: 0.56)], startPoint: .leading, endPoint: .trailing)
            LinearGradient(stops: [.init(color: .white.opacity(0.06), location: 0.38), .init(color: .clear, location: 0.47),
                                   .init(color: .clear, location: 0.53), .init(color: .white.opacity(0.06), location: 0.62)],
                           startPoint: .leading, endPoint: .trailing)
            if let turnedAt {
                TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
                    let progress = min(1, timeline.date.timeIntervalSince(turnedAt) / 0.9)
                    V3PageSweep(progress: progress).opacity(progress >= 1 ? 0 : 1)
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .onChange(of: stanza) { old, new in
            guard animate, new > old else { return }
            turnedAt = Date()
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

/// 拍立得: the white mount, wider at the bottom, where the line being sung is
/// written by hand.
private struct V3PolaroidMount: View {
    let size: CGSize
    let glass: CGRect
    let line: String

    private static let handFont: Font = {
        for name in ["Klee-Medium", "HannotateSC-W5", "KaitiSC-Regular", "BradleyHandITCTT-Bold"]
            where NSFont(name: name, size: 20) != nil {
            return .custom(name, size: 20)
        }
        return .system(size: 20, weight: .regular, design: .serif).italic()
    }()

    var body: some View {
        let border = min(glass.minX, glass.minY) * 0.85
        let mount = CGRect(x: glass.minX - border, y: glass.minY - border, width: glass.width + border * 2,
                           height: size.height - border * 0.5 - (glass.minY - border))
        ZStack(alignment: .topLeading) {
            // One white card with the photo's window cut out, so the glass stays clickable.
            Path { path in
                path.addRect(mount)
                path.addRect(glass)
            }
            .fill(Color(red: 0.97, green: 0.96, blue: 0.93), style: FillStyle(eoFill: true))
            .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
            // A strip of tape holding it to the board.
            Rectangle().fill(Color(red: 0.95, green: 0.92, blue: 0.80).opacity(0.75))
                .frame(width: 90, height: 22)
                .rotationEffect(.degrees(-4))
                .offset(x: mount.midX - 45, y: max(0, mount.minY - 11))
            Text(line.isEmpty ? " " : line)
                .font(Self.handFont)
                .foregroundStyle(Color(red: 0.16, green: 0.17, blue: 0.24).opacity(0.86))
                .lineLimit(1).minimumScaleFactor(0.5)
                .frame(width: glass.width - 40, height: mount.maxY - glass.maxY, alignment: .center)
                .offset(x: glass.minX + 20, y: glass.maxY)
                .id(line)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.5), value: line)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
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

    private static func points(seed: String, count: Int) -> [CGPoint] {
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
        let points = Self.points(seed: seed, count: count)
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !playing)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, canvas in
                let place = { (p: CGPoint) in CGPoint(x: p.x * canvas.width, y: p.y * canvas.height) }
                let sung = current.map { min($0, points.count - 1) } ?? -1
                if sung > 0 {
                    var path = Path()
                    path.move(to: place(points[0]))
                    for index in 1...sung { path.addLine(to: place(points[index])) }
                    context.stroke(path, with: .color(.white.opacity(0.35)), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
                }
                for (index, point) in points.enumerated() {
                    let p = place(point)
                    let lit = index <= sung
                    let isNow = index == sung
                    let r: CGFloat = isNow ? 4 + 1.2 * CGFloat(sin(t * 4)) : lit ? 2.4 : 1.3
                    if lit {
                        context.fill(Path(ellipseIn: CGRect(x: p.x - r * 3, y: p.y - r * 3, width: r * 6, height: r * 6)),
                                     with: .radialGradient(Gradient(colors: [.white.opacity(isNow ? 0.45 : 0.22), .clear]),
                                                           center: p, startRadius: 0, endRadius: r * 3))
                    }
                    context.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                                 with: .color(.white.opacity(lit ? 0.95 : 0.28)))
                }
            }
        }
        .blendMode(.screen)
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
