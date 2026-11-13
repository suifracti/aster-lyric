import SwiftUI

/// What the hour adds to the backdrop: nothing by day, a cool wash at dawn,
/// a warm one at dusk, a deep blue late at night.
enum V3DayTint {
    struct Wash: Equatable {
        let red: Double, green: Double, blue: Double, opacity: Double
        var color: Color { Color(red: red, green: green, blue: blue) }
    }

    /// `hour` is the local time as a fraction (17.5 = 17:30). Each band fades
    /// in and out over its first and last half hour.
    static func wash(hour: Double) -> Wash? {
        let h = hour.truncatingRemainder(dividingBy: 24)
        func strength(_ start: Double, _ end: Double) -> Double {
            guard h >= start, h < end else { return 0 }
            return min(1, min(h - start, end - h) / 0.5)
        }
        let dawn = strength(5, 8)
        if dawn > 0 { return Wash(red: 0.72, green: 0.85, blue: 1.0, opacity: 0.12 * dawn) }
        let dusk = strength(16.5, 19.5)
        if dusk > 0 { return Wash(red: 1.0, green: 0.68, blue: 0.40, opacity: 0.14 * dusk) }
        // Late night runs past midnight: 23:00–04:30.
        let night = h >= 23 ? min(1, (h - 23) / 0.5) : (h < 4.5 ? min(1, (4.5 - h) / 0.5) : 0)
        if night > 0 { return Wash(red: 0.22, green: 0.30, blue: 0.62, opacity: 0.16 * night) }
        return nil
    }

    static func hour(of date: Date, calendar: Calendar = .current) -> Double {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return Double(parts.hour ?? 12) + Double(parts.minute ?? 0) / 60
    }
}

/// Where the backdrop sits for a pointer position: it leans away from the
/// pointer by at most `reach` points, and not at all with the pointer centred.
enum V3BackdropParallax {
    static let reach: CGFloat = 12
    /// Enlarged just enough that the lean never shows an edge.
    static func scale(for size: CGSize) -> CGFloat {
        guard size.width > 0, size.height > 0 else { return 1 }
        return 1 + 2 * reach / min(size.width, size.height)
    }
    static func offset(pointer: CGPoint?, in size: CGSize) -> CGSize {
        guard let pointer, size.width > 0, size.height > 0 else { return .zero }
        let x = min(1, max(0, pointer.x / size.width)) - 0.5
        let y = min(1, max(0, pointer.y / size.height)) - 0.5
        return CGSize(width: -x * 2 * reach, height: -y * 2 * reach)
    }
}

/// 鼠标视差 and 随时段调色 on the backdrop. Both keep their state here, so a
/// moving pointer redraws nothing but this wrapper's transform.
struct V3BackdropAmbience: ViewModifier {
    let parallax: Bool
    let dayTint: Bool
    @State private var pointer: CGPoint?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        GeometryReader { geometry in
            let leans = parallax && !reduceMotion
            let lean = leans ? V3BackdropParallax.offset(pointer: pointer, in: geometry.size) : .zero
            content
                .scaleEffect(leans ? V3BackdropParallax.scale(for: geometry.size) : 1)
                .offset(lean)
                .animation(.interpolatingSpring(stiffness: 55, damping: 15), value: lean)
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
                .overlay {
                    if dayTint {
                        TimelineView(.periodic(from: .now, by: 300)) { context in
                            if let wash = V3DayTint.wash(hour: V3DayTint.hour(of: context.date)) {
                                wash.color.opacity(wash.opacity).blendMode(.softLight)
                            }
                        }
                        .allowsHitTesting(false)
                    }
                }
                .onContinuousHover(coordinateSpace: .local) { phase in
                    guard leans else { return }
                    switch phase {
                    case .active(let point):
                        // A few points of pointer travel change nothing visible.
                        if let pointer, abs(pointer.x - point.x) < 6, abs(pointer.y - point.y) < 6 { return }
                        pointer = point
                    case .ended: pointer = nil
                    }
                }
        }
    }
}
