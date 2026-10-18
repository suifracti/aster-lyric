import AppKit
import SwiftUI

/// Draws playback progress around the main window and keeps transport controls
/// close to the point where the pointer last left the window.
struct V3WindowEdgePlaybackOverlay: View {
    @ObservedObject var state: PlaybackState
    let colorHex: String
    let exitPoint: CGPoint?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let borderInset: CGFloat = 1.5
    private let borderRadius: CGFloat = 12

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let accent = V3WindowEdgeColor.color(from: colorHex)
            let controlPosition = V3WindowEdgeControlPositioner.layout(
                size: size,
                exitPoint: exitPoint
            )

            ZStack(alignment: .topLeading) {
                V3WindowEdgeRoundedRectShape(inset: borderInset, cornerRadius: borderRadius)
                    .stroke(
                        accent.opacity(0.22),
                        style: StrokeStyle(lineWidth: 2.1, lineCap: .round, lineJoin: .round)
                    )
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)

                TimelineView(.animation(
                    minimumInterval: reduceMotion ? 0.5 : 1.0 / 30.0,
                    paused: !state.isPlaying
                )) { _ in
                    V3WindowEdgeRoundedRectShape(inset: borderInset, cornerRadius: borderRadius)
                        .trim(from: 0, to: progressFraction)
                        .stroke(
                            accent,
                            style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round)
                        )
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .transaction { $0.animation = nil }

                V3WindowEdgeTransportButtons(
                    state: state,
                    accent: accent,
                    isVertical: controlPosition.isVertical
                )
                .frame(width: controlPosition.baseSize.width, height: controlPosition.baseSize.height)
                .scaleEffect(controlPosition.scale)
                .position(controlPosition.center)
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
        }
    }

    private var progressFraction: CGFloat {
        let duration = state.currentTrack.duration
        guard duration.isFinite, duration > 0 else { return 0 }

        let position = state.presentationClock.playbackTime(
            at: ProcessInfo.processInfo.systemUptime
        )
        guard position.isFinite else { return 0 }
        return CGFloat(min(max(position / duration, 0), 1))
    }
}

/// Settings content that can be embedded alongside the existing playback
/// preferences without coupling this view to AppSettingsStore.
struct V3WindowEdgeProgressSettings: View {
    @Binding var enabled: Bool
    @Binding var colorHex: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("窗口边缘播放进度", isOn: $enabled)

            ColorPicker("进度颜色", selection: Binding(
                get: { V3WindowEdgeColor.color(from: colorHex) },
                set: { colorHex = V3WindowEdgeColor.hex(from: $0, keepPrefix: colorHex.hasPrefix("#")) }
            ), supportsOpacity: false)
            .disabled(!enabled)
        }
    }
}

private struct V3WindowEdgeTransportButtons: View {
    @ObservedObject var state: PlaybackState
    let accent: Color
    let isVertical: Bool

    @ViewBuilder
    var body: some View {
        Group {
            if isVertical {
                VStack(spacing: 5) {
                    previousButton
                    playPauseButton
                    nextButton
                }
            } else {
                HStack(spacing: 5) {
                    previousButton
                    playPauseButton
                    nextButton
                }
            }
        }
        .padding(4)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.22), lineWidth: 0.8))
    }

    private var previousButton: some View {
        transportButton(
            image: "backward.fill",
            label: "上一首",
            enabled: state.canControlSpotify,
            primary: false
        ) {
            state.previousTrack()
        }
    }

    private var playPauseButton: some View {
        transportButton(
            image: state.isPlaying ? "pause.fill" : "play.fill",
            label: state.isPlaying ? "暂停" : "播放",
            enabled: state.canInteractWithPlayback,
            primary: true
        ) {
            state.togglePlayPause()
        }
    }

    private var nextButton: some View {
        transportButton(
            image: "forward.fill",
            label: "下一首",
            enabled: state.canControlSpotify,
            primary: false
        ) {
            state.nextTrack()
        }
    }

    private func transportButton(
        image: String,
        label: String,
        enabled: Bool,
        primary: Bool,
        action: @escaping () -> Void
    ) -> some View {
        V3WindowEdgeTransportButton(
            image: image,
            label: label,
            enabled: enabled,
            primary: primary,
            accent: accent,
            action: action
        )
    }
}

private struct V3WindowEdgeTransportButton: View {
    let image: String
    let label: String
    let enabled: Bool
    let primary: Bool
    let accent: Color
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: image)
                .font(.system(size: primary ? 14 : 12, weight: .semibold))
                .foregroundStyle(.white.opacity(enabled ? 0.96 : 0.40))
                .frame(width: 30, height: 30)
                .background(
                    Circle().fill(primary ? accent.opacity(enabled ? 0.92 : 0.34) : Color.black.opacity(0.28))
                )
                .overlay(
                    Circle().strokeBorder(
                        Color.white.opacity(isHovered ? 0.46 : 0.14),
                        lineWidth: 0.8
                    )
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
        .help(label)
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }
}

private struct V3WindowEdgeRoundedRectShape: Shape {
    let inset: CGFloat
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let bounds = rect.insetBy(dx: inset, dy: inset)
        guard bounds.width > 0, bounds.height > 0 else { return Path() }

        let radius = min(cornerRadius, min(bounds.width, bounds.height) / 2)
        let curve = radius * 0.55228475
        let minX = bounds.minX
        let minY = bounds.minY
        let maxX = bounds.maxX
        let maxY = bounds.maxY

        var path = Path()
        // Start at the top midpoint and proceed clockwise.
        let topMidpoint = (minX + maxX) / 2
        path.move(to: CGPoint(x: topMidpoint, y: minY))
        path.addLine(to: CGPoint(x: maxX - radius, y: minY))
        path.addCurve(
            to: CGPoint(x: maxX, y: minY + radius),
            control1: CGPoint(x: maxX - radius + curve, y: minY),
            control2: CGPoint(x: maxX, y: minY + radius - curve)
        )
        path.addLine(to: CGPoint(x: maxX, y: maxY - radius))
        path.addCurve(
            to: CGPoint(x: maxX - radius, y: maxY),
            control1: CGPoint(x: maxX, y: maxY - radius + curve),
            control2: CGPoint(x: maxX - radius + curve, y: maxY)
        )
        path.addLine(to: CGPoint(x: minX + radius, y: maxY))
        path.addCurve(
            to: CGPoint(x: minX, y: maxY - radius),
            control1: CGPoint(x: minX + radius - curve, y: maxY),
            control2: CGPoint(x: minX, y: maxY - radius + curve)
        )
        path.addLine(to: CGPoint(x: minX, y: minY + radius))
        path.addCurve(
            to: CGPoint(x: minX + radius, y: minY),
            control1: CGPoint(x: minX, y: minY + radius - curve),
            control2: CGPoint(x: minX + radius - curve, y: minY)
        )
        path.addLine(to: CGPoint(x: topMidpoint, y: minY))
        return path
    }
}

private enum V3WindowEdgeControlPositioner {
    private enum Edge {
        case top, right, bottom, left

        var isVertical: Bool { self == .left || self == .right }
    }

    struct Layout {
        let center: CGPoint
        let isVertical: Bool
        let baseSize: CGSize
        let scale: CGFloat
    }

    static func layout(size: CGSize, exitPoint: CGPoint?) -> Layout {
        let width = max(0, size.width.isFinite ? size.width : 0)
        let height = max(0, size.height.isFinite ? size.height : 0)
        let defaultCenter = CGPoint(x: width / 2, y: height / 2)

        guard width > 0, height > 0 else {
            return Layout(center: defaultCenter, isVertical: false, baseSize: .zero, scale: 0)
        }

        let edge: Edge
        let point: CGPoint
        if let exitPoint, exitPoint.x.isFinite, exitPoint.y.isFinite {
            point = CGPoint(
                x: min(max(exitPoint.x, 0), width),
                y: min(max(exitPoint.y, 0), height)
            )
            let distances: [(Edge, CGFloat)] = [
                (.top, point.y),
                (.right, width - point.x),
                (.bottom, height - point.y),
                (.left, point.x)
            ]
            edge = distances.min(by: { $0.1 < $1.1 })?.0 ?? .bottom
        } else {
            point = CGPoint(x: width / 2, y: height)
            edge = .bottom
        }

        let isVertical = edge.isVertical
        let baseSize = CGSize(width: isVertical ? 38 : 108, height: isVertical ? 108 : 38)
        let availableLong = isVertical ? height : width
        let availableShort = isVertical ? width : height
        let baseLong = isVertical ? baseSize.height : baseSize.width
        let baseShort = isVertical ? baseSize.width : baseSize.height
        let scale = min(1, min(availableLong / baseLong, availableShort / baseShort))
        let halfLength = (isVertical ? baseSize.height : baseSize.width) * scale / 2
        let halfThickness = (isVertical ? baseSize.width : baseSize.height) * scale / 2

        let center: CGPoint
        switch edge {
        case .top:
            center = CGPoint(
                x: clamped(point.x, lower: 88 + halfLength, upper: width - halfLength, fallback: width / 2),
                y: clamped(31, lower: halfThickness + 2, upper: height - halfThickness - 2, fallback: height / 2)
            )
        case .right:
            center = CGPoint(
                x: clamped(width - 22, lower: halfThickness + 2, upper: width - halfThickness - 2, fallback: width / 2),
                y: clamped(point.y, lower: halfLength + 2, upper: height - halfLength - 2, fallback: height / 2)
            )
        case .bottom:
            center = CGPoint(
                x: clamped(point.x, lower: halfLength + 2, upper: width - halfLength - 2, fallback: width / 2),
                y: clamped(height - 22, lower: halfThickness + 2, upper: height - halfThickness - 2, fallback: height / 2)
            )
        case .left:
            center = CGPoint(
                x: clamped(22, lower: halfThickness + 2, upper: width - halfThickness - 2, fallback: width / 2),
                y: clamped(point.y, lower: 74 + halfLength, upper: height - halfLength - 2, fallback: height / 2)
            )
        }

        return Layout(center: center, isVertical: isVertical, baseSize: baseSize, scale: scale)
    }

    private static func clamped(_ value: CGFloat, lower: CGFloat, upper: CGFloat, fallback: CGFloat) -> CGFloat {
        guard lower.isFinite, upper.isFinite, lower <= upper else { return fallback }
        return min(max(value, lower), upper)
    }
}

private enum V3WindowEdgeColor {
    static func color(from hex: String) -> Color {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        if value.count == 3 {
            value = value.map { "\($0)\($0)" }.joined()
        }
        guard value.count == 6, let rgb = UInt64(value, radix: 16) else {
            return Color(red: 30.0 / 255.0, green: 215.0 / 255.0, blue: 96.0 / 255.0)
        }
        return Color(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }

    static func hex(from color: Color, keepPrefix: Bool) -> String {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else {
            return keepPrefix ? "#1ED760" : "1ED760"
        }
        let hex = String(
            format: "%02X%02X%02X",
            Int((rgb.redComponent * 255).rounded()),
            Int((rgb.greenComponent * 255).rounded()),
            Int((rgb.blueComponent * 255).rounded())
        )
        return keepPrefix ? "#\(hex)" : hex
    }
}
