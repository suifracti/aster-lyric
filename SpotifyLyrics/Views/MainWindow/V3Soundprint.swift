import SwiftUI

/// 声纹圈 (B12, after Plexamp's Soundprint): the song's loudness drawn as a
/// loop of short bars just outside the foreground cover, one turn per song, filled
/// in as it is heard. Kept per song (Caches/Soundprints), so a song heard
/// before shows its whole ring. Needs 随音乐律动; nothing is guessed.
@MainActor
final class V3SoundprintStore {
    static let shared = V3SoundprintStore()
    static let bins = 180

    private var prints: [String: [Float]] = [:]
    private var dirty: Set<String> = []
    private lazy var folder: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appendingPathComponent(Bundle.main.bundleIdentifier ?? "SpotifyLyrics", isDirectory: true)
        .appendingPathComponent("Soundprints", isDirectory: true)

    func print(for key: String) -> [Float] {
        if let existing = prints[key] { return existing }
        var loaded = Array(repeating: Float(-1), count: Self.bins)
        if let url = file(key), let data = try? Data(contentsOf: url),
           let values = try? JSONDecoder().decode([Float].self, from: data), values.count == Self.bins {
            loaded = values
        }
        prints[key] = loaded
        return loaded
    }

    /// Records a reading (0…1) at a fraction of the song; a bin keeps a
    /// running blend so one loud moment does not define it.
    func record(_ value: Double, at fraction: Double, for key: String) {
        guard fraction >= 0, fraction < 1 else { return }
        var values = print(for: key)
        let index = min(Self.bins - 1, Int(fraction * Double(Self.bins)))
        let v = Float(min(1, max(0, value)))
        values[index] = values[index] < 0 ? v : values[index] * 0.7 + v * 0.3
        prints[key] = values
        dirty.insert(key)
    }

    func save() {
        guard let folder else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for key in dirty {
            guard let values = prints[key], let url = file(key), let data = try? JSONEncoder().encode(values) else { continue }
            try? data.write(to: url, options: .atomic)
        }
        dirty.removeAll()
    }

    private func file(_ key: String) -> URL? {
        let safe = key.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "_" }.joined()
        return folder?.appendingPathComponent(String(safe.prefix(80)) + ".json")
    }
}

struct V3SoundprintRing: View {
    let state: PlaybackState
    @ObservedObject var settings: AppSettingsStore
    let cover: CGRect
    let accent: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var key: String { state.currentTrackIdentity?.stableKey ?? state.currentTrack.id }

    var body: some View {
        let listening = settings.v3MusicMotionEnabled && state.isPlaying
        TimelineView(.animation(minimumInterval: 0.1, paused: !listening)) { _ in
            Canvas { ctx, _ in
                let duration = max(1, state.currentTrack.duration)
                let fraction = min(1, max(0, state.presentationClock.playbackTime(at: ProcessInfo.processInfo.systemUptime) / duration))
                if listening {
                    let levels = V3MusicPulse.levels
                    if ProcessInfo.processInfo.systemUptime - levels.updatedAt < 1 {
                        V3SoundprintStore.shared.record(V3VUMeterFace.reading((levels.bass + levels.mid + levels.treble) / 3),
                                                        at: fraction, for: key)
                    }
                }
                draw(&ctx, values: V3SoundprintStore.shared.print(for: key), fraction: fraction)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: key) { _, _ in V3SoundprintStore.shared.save() }
        .onChange(of: state.isPlaying) { _, playing in if !playing { V3SoundprintStore.shared.save() } }
        .onDisappear { V3SoundprintStore.shared.save() }
    }

    /// A point on the loop just outside the cover, starting at the top
    /// centre and going clockwise (like the edge progress), with the outward
    /// direction there. A rectangle, not a circle, so it hugs the cover and
    /// stays clear of the player card below it.
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

    private func draw(_ ctx: inout GraphicsContext, values: [Float], fraction: Double) {
        let loop = cover.insetBy(dx: -9, dy: -9)
        let reach: CGFloat = 16
        let count = values.count
        // The quiet track: one faint outline.
        ctx.stroke(Path(roundedRect: loop, cornerRadius: 6), with: .color(.white.opacity(0.12)), lineWidth: 1)
        for i in 0..<count where values[i] >= 0 {
            let t = (Double(i) + 0.5) / Double(count)
            let (p, n) = Self.loopPoint(t, around: loop)
            let length = 2 + reach * CGFloat(values[i])
            var bar = Path()
            bar.move(to: p)
            bar.addLine(to: CGPoint(x: p.x + n.dx * length, y: p.y + n.dy * length))
            ctx.stroke(bar, with: .color(t <= fraction ? accent.opacity(0.85) : .white.opacity(0.28)),
                       style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }
        // Where the song is now.
        let now = Self.loopPoint(fraction, around: loop).point
        ctx.fill(Path(ellipseIn: CGRect(x: now.x - 3, y: now.y - 3, width: 6, height: 6)), with: .color(.white.opacity(0.9)))
    }
}
