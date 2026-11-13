import SwiftUI

/// The bass right now as 0…1: up at once on a hit, back down over about a
/// fifth of a second. Stale levels (paused, capture off) read as 0.
struct V3BassFollower {
    private(set) var value = 0.0
    private var lastTime: TimeInterval?

    /// How far a bass level (1.0 = this song's usual) lifts the envelope.
    static func hit(bass: Double) -> Double { min(1, max(0, (bass - 1.0) / 0.55)) }

    mutating func step(bass: Double?, now: TimeInterval) -> Double {
        let elapsed = lastTime.map { min(0.1, max(0, now - $0)) } ?? 0
        lastTime = now
        let fallen = value * exp(-elapsed / 0.22)
        value = min(1, max(bass.map(Self.hit) ?? 0, fallen))
        return value
    }

    /// The live bass level, or nil when nothing fresh is arriving.
    static var liveBass: Double? {
        let levels = V3MusicPulse.levels
        return ProcessInfo.processInfo.systemUptime - levels.updatedAt < 0.5 ? levels.bass : nil
    }
}

/// Holds a follower across TimelineView ticks without publishing changes.
private final class V3BassFollowerBox {
    var follower = V3BassFollower()
    func step() -> Double { follower.step(bass: V3BassFollower.liveBass, now: ProcessInfo.processInfo.systemUptime) }
}

/// 封面呼吸: the foreground cover swells by up to 2% with the bass.
struct V3CoverBreath: ViewModifier {
    @ObservedObject private var settings = AppSettingsStore.shared
    @State private var box = V3BassFollowerBox()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let active = settings.v3CoverBreath && settings.v3MusicMotionEnabled && !reduceMotion
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !active)) { _ in
            content.scaleEffect(active ? 1 + 0.02 * box.step() : 1)
        }
    }
}

/// 四边灯带: a soft light along the window's four edges, in the cover's
/// colour, that brightens with the bass and is nearly gone between hits.
struct V3EdgeLights: View {
    let accent: Color
    let running: Bool
    @State private var box = V3BassFollowerBox()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !running)) { _ in
            let level = running ? box.step() : 0
            Rectangle()
                .strokeBorder(accent, lineWidth: 26)
                .blur(radius: 22)
                .blendMode(.screen)
                .opacity(0.06 + 0.5 * level)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
