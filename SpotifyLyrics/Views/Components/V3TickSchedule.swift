import SwiftUI

/// A timeline that fires exactly every `interval` seconds, and not at all while paused.
///
/// `TimelineView(.animation(minimumInterval:))` limits how often its content is
/// rebuilt, but measured on macOS (2026-11-19) its hosting view still asked for
/// an update every display frame. The player's 0.25 s time label alone drove
/// about 200 layout passes a second through the main window, and the main thread
/// sat at 70%. Anything that changes a few times a second — a clock, a progress
/// bar, a slow texture — uses this instead; real motion keeps `.animation`.
struct V3TickSchedule: TimelineSchedule {
    let interval: TimeInterval
    var paused = false

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        if paused {
            var given = false
            return AnyIterator { defer { given = true }; return given ? nil : startDate }
        }
        let step = max(1.0 / 60.0, interval)
        var next = startDate
        return AnyIterator {
            defer { next = next.addingTimeInterval(step) }
            return next
        }
    }
}

extension TimelineSchedule where Self == V3TickSchedule {
    /// Every `seconds`, or never while `paused`.
    static func v3Every(_ seconds: TimeInterval, paused: Bool = false) -> V3TickSchedule {
        V3TickSchedule(interval: seconds, paused: paused)
    }
}
