import os
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

/// 封面轮廓光: the foreground cover's outline lights up with the bass.
struct V3CoverRimLight: View {
    let cover: V3ForegroundCoverFrame
    let accent: Color
    let running: Bool
    @State private var box = V3BassFollowerBox()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !running)) { _ in
            let level = running ? box.step() : 0
            let shape = RoundedRectangle(cornerRadius: cover.cornerRadius, style: .continuous)
            ZStack {
                shape.stroke(accent, lineWidth: 5).blur(radius: 9).opacity(0.85 * level)
                shape.stroke(Color.white, lineWidth: 1.2).opacity(0.75 * level)
            }
            .frame(width: cover.frame.width, height: cover.frame.height)
            .position(x: cover.frame.midX, y: cover.frame.midY)
            .blendMode(.screen)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// 封面题句: the line being sung, set along the cover's lower edge like the
/// tagline on a poster. `text` nil shows nothing.
struct V3CoverCaption: View {
    let cover: V3ForegroundCoverFrame
    let text: String?
    let lineIndex: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func fontSize(coverWidth: CGFloat) -> CGFloat { min(22, max(11, coverWidth * 0.048)) }

    var body: some View {
        let shown = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        ZStack(alignment: .bottom) {
            if !shown.isEmpty {
                LinearGradient(colors: [.clear, .black.opacity(0.62)], startPoint: .top, endPoint: .bottom)
                    .frame(height: cover.frame.height * 0.34)
                    .transition(.opacity)
                Text(shown)
                    .font(.system(size: Self.fontSize(coverWidth: cover.frame.width), weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                    .padding(.horizontal, cover.frame.width * 0.07)
                    .padding(.bottom, cover.frame.height * 0.055)
                    .id(lineIndex)
                    .transition(.opacity)
            }
        }
        .frame(width: cover.frame.width, height: cover.frame.height, alignment: .bottom)
        .clipShape(RoundedRectangle(cornerRadius: cover.cornerRadius, style: .continuous))
        .position(x: cover.frame.midX, y: cover.frame.midY)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: lineIndex)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: shown.isEmpty)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// 人声包络: when no sound is heard and the song has no beat grid, the light
/// follows the starts of the sung words instead (Lyrimuse does the same).
/// The window view publishes the current line's word starts here.
enum V3VocalOnsets {
    private static let state = OSAllocatedUnfairLock(initialState: [TimeInterval]())

    static var current: [TimeInterval] {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }

    /// Word starts of a line, in lyric time, sorted; empty without word timing.
    static func onsets(of line: LyricLine?) -> [TimeInterval] {
        (line?.timedSpans ?? []).map(\.startTime).sorted()
    }

    /// The index of the word that began within the last `window` seconds, if any.
    static func index(at time: TimeInterval, in onsets: [TimeInterval], window: TimeInterval = 0.12) -> Int? {
        guard let index = onsets.lastIndex(where: { $0 <= time }), time - onsets[index] < window else { return nil }
        return index
    }
}

/// 换气: through the last two seconds of a long gap the line about to be
/// sung comes up — a glow and a slight swell — so the entry is not a surprise.
struct V3BreathIn: ViewModifier {
    let window: LyricsTimeline.VocalCountdownWindow?
    let clock: LyricsPresentationClock
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let lead: TimeInterval = 2

    /// 0 until `lead` seconds before the voice, then rising to 1 at the entry.
    static func level(time: TimeInterval, end: TimeInterval) -> Double {
        let remaining = end - time
        guard remaining >= 0, remaining < lead else { return 0 }
        let t = 1 - remaining / lead
        return t * t * (3 - 2 * t)
    }

    func body(content: Content) -> some View {
        if let window, !reduceMotion {
            TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !clock.isPlaying)) { _ in
                let level = Self.level(time: clock.presentationTime(at: ProcessInfo.processInfo.systemUptime), end: window.end)
                content
                    .shadow(color: .white.opacity(0.7 * level), radius: 10)
                    .brightness(0.25 * level)
                    .scaleEffect(1 + 0.02 * level, anchor: .leading)
            }
        } else {
            content
        }
    }
}
