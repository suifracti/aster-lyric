import AppKit
import SwiftUI

/// Draws playback progress around the main window and keeps transport controls
/// anchored to the current approaching edge, without publishing every mouse move.
struct V3WindowEdgePlaybackOverlay: View {
    @V3ContentPlaybackState var state: PlaybackState
    let colorHex: String
    let colorMode: String
    let exitPoint: CGPoint?
    let pointerInsideWindow: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.v3PlaybackInteractionChanged) private var interactionChanged
    @State private var edgeInteraction = V3WindowEdgeInteractionState()
    @State private var draftFraction: Double?
    @State private var dragTrackKey: String?
    @State private var windowVisible = false
    @State private var coverAccent = Color.accentColor
    @State private var colorElapsed: TimeInterval = 0
    @State private var colorStartedAt: Date?

    private let borderInset: CGFloat = 1.5
    private let borderRadius: CGFloat = 12
    private var controlsVisible: Bool {
        edgeInteraction.isVisible && edgeInteraction.pointerInside
    }
    private var animatesColor: Bool { colorMode == "flow" && !reduceMotion && state.isPlaying && windowVisible }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let songHue = V3WindowEdgeSongColor.hue(for: state.currentTrackIdentity?.stableKey ?? "no-track")
            let controlPosition = edgeInteraction.layout(size: size, fallbackExitPoint: exitPoint)

            ZStack(alignment: .topLeading) {
                // Only the thin edge band takes pointer events; the lyric canvas stays interactive.
                V3WindowEdgeHitBand(inset: borderInset, cornerRadius: borderRadius)
                    .fill(Color.clear)
                    .contentShape(V3WindowEdgeHitBand(inset: borderInset, cornerRadius: borderRadius))
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                        .onChanged { value in updateDraft(at: value.location, size: size) }
                        .onEnded { value in finishSeek(at: value.location, size: size) })
                    .accessibilityLabel("窗口边缘播放进度")
                    .accessibilityValue("\(Int(progressFraction * 100))%")
                    .accessibilityAdjustableAction { direction in
                        guard canSeek else { return }
                        let delta: Double = direction == .increment ? 5 : -5
                        state.seek(to: min(max(0, Double(progressFraction) * state.currentTrack.duration + delta),
                                           state.currentTrack.duration), source: "v3-edge-progress-keyboard")
                    }

                // One local timeline/color value for both the progress and its
                // buttons. The transparent hit band remains separate and narrow.
                TimelineView(.animation(
                    minimumInterval: reduceMotion ? 0.5 : 1.0 / 30.0,
                    paused: !windowVisible || (!state.isPlaying && !animatesColor)
                )) { context in
                    let color = accent(at: context.date, songHue: songHue)
                    ZStack(alignment: .topLeading) {
                        ZStack {
                            border.stroke(color.opacity(0.22), style: StrokeStyle(lineWidth: 2.1, lineCap: .round))
                            border.trim(from: 0, to: progressFraction)
                                .stroke(color, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                        }
                        .transaction { $0.animation = nil }
                        .allowsHitTesting(false).accessibilityHidden(true)
                        V3WindowEdgeTransportButtons(state: state, accent: color,
                                                     isVertical: controlPosition.isVertical)
                            .frame(width: controlPosition.baseSize.width, height: controlPosition.baseSize.height)
                            .scaleEffect(controlPosition.scale)
                            .opacity(controlsVisible ? 1 : 0)
                            .allowsHitTesting(controlsVisible)
                            .accessibilityHidden(!controlsVisible)
                            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: controlsVisible)
                            .position(controlPosition.center)
                    }
                }

            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(V3WindowEdgePointerTracker { point in
                updatePointer(point, size: size, dragging: draftFraction != nil)
            })
            .background(alignment: .topLeading) {
                V3WindowVisibilityProbe(isVisible: $windowVisible).frame(width: 0, height: 0)
            }
        }
        .onChange(of: pointerInsideWindow) { _, inside in
            // The local activeAlways tracker is authoritative for non-key windows.
            if !inside && !edgeInteraction.pointerInside {
                clearPointer()
            }
        }
        .onChange(of: state.currentTrackIdentity) { _, _ in
            if dragTrackKey != nil {
                // Keep the original gesture identity until release so a track
                // change cannot redirect an unfinished drag onto the new song.
                draftFraction = nil
                interactionChanged(false)
            }
        }
        .task(id: "\(state.currentTrack.artworkURL?.absoluteString ?? "none")|\(colorMode == "artwork")") {
            guard colorMode == "artwork" else { return }
            let palette = await LyricIslandArtworkColors.palette(for: state.currentTrack.artworkURL)
            guard !Task.isCancelled else { return }
            coverAccent = LyricIslandArtworkColors.edgeAccent(palette)
        }
        .onChange(of: animatesColor) { _, active in
            if let colorStartedAt { colorElapsed += max(0, Date().timeIntervalSince(colorStartedAt)) }
            colorStartedAt = active ? .now : nil
        }
        .onChange(of: windowVisible) { _, visible in if !visible { clearPointer() } }
        .onDisappear {
            colorStartedAt = nil
            cancelDraft()
            clearPointer()
        }
    }

    private func updatePointer(_ point: CGPoint?, size: CGSize, dragging: Bool) {
        // Keep per-pixel input local. Only a visibility/anchor transition writes
        // SwiftUI state, so idle/lyric-region mouse motion does not redraw views.
        let next = edgeInteraction.updating(point: point, size: size, dragging: dragging)
        if next != edgeInteraction { edgeInteraction = next }
    }

    private func clearPointer() {
        let next = edgeInteraction.hiding()
        if next != edgeInteraction { edgeInteraction = next }
    }

    private var border: V3WindowEdgeRoundedRectShape {
        V3WindowEdgeRoundedRectShape(inset: borderInset, cornerRadius: borderRadius)
    }

    private var canSeek: Bool {
        state.currentTrackIdentity != nil && state.canInteractWithPlayback
            && state.currentTrack.duration.isFinite && state.currentTrack.duration > 0
    }

    private var progressFraction: CGFloat {
        if let draftFraction { return CGFloat(draftFraction) }
        let duration = state.currentTrack.duration
        guard duration.isFinite, duration > 0 else { return 0 }
        let position = state.presentationClock.playbackTime(at: ProcessInfo.processInfo.systemUptime)
        guard position.isFinite else { return 0 }
        return CGFloat(min(max(position / duration, 0), 1))
    }

    private func updateDraft(at point: CGPoint, size: CGSize) {
        guard canSeek, let fraction = V3ResponsiveGeometry.edgeProgressFraction(at: point, canvasSize: size) else { return }
        if dragTrackKey == nil {
            dragTrackKey = state.currentTrackIdentity?.stableKey
            interactionChanged(true)
        }
        guard dragTrackKey == state.currentTrackIdentity?.stableKey else { return }
        draftFraction = fraction
        updatePointer(point, size: size, dragging: true)
    }

    private func finishSeek(at point: CGPoint, size: CGSize) {
        defer {
            cancelDraft()
            updatePointer(point, size: size, dragging: false)
        }
        guard canSeek, dragTrackKey == state.currentTrackIdentity?.stableKey,
              let fraction = V3ResponsiveGeometry.edgeProgressFraction(at: point, canvasSize: size) else { return }
        state.seek(to: fraction * state.currentTrack.duration, source: "v3-edge-progress")
    }

    private func cancelDraft() {
        if dragTrackKey != nil { interactionChanged(false) }
        draftFraction = nil
        dragTrackKey = nil
    }

    private func accent(at date: Date, songHue: Double) -> Color {
        switch colorMode {
        case "randomSong": return Color(hue: songHue, saturation: 0.68, brightness: 0.98)
        case "flow":
            let running = colorStartedAt.map { max(0, date.timeIntervalSince($0)) } ?? 0
            let hue = reduceMotion ? songHue : (songHue + (colorElapsed + running) / 36).truncatingRemainder(dividingBy: 1)
            return Color(hue: hue, saturation: 0.68, brightness: 0.98)
        case "artwork": return coverAccent
        default: return V3WindowEdgeColor.color(from: colorHex)
        }
    }
}

/// Tracking stays active for an inactive window; this view never takes clicks.
private struct V3WindowEdgePointerTracker: NSViewRepresentable {
    let onMove: (CGPoint?) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onMove = onMove
        return view
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {
        nsView.onMove = onMove
    }

    final class TrackingView: NSView {
        var onMove: (CGPoint?) -> Void = { _ in }
        private var area: NSTrackingArea?
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let area { removeTrackingArea(area) }
            let next = NSTrackingArea(rect: .zero,
                options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .enabledDuringMouseDrag],
                owner: self, userInfo: nil)
            addTrackingArea(next)
            area = next
            // AppKit can update tracking during layout; defer SwiftUI state writes.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard let window = self.window, window.isVisible,
                      NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0) == window.windowNumber
                else { self.onMove(nil); return }
                self.report(window.mouseLocationOutsideOfEventStream)
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            updateTrackingAreas()
        }
        override func mouseEntered(with event: NSEvent) { report(event.locationInWindow) }
        override func mouseMoved(with event: NSEvent) { report(event.locationInWindow) }
        override func mouseExited(with event: NSEvent) { onMove(nil) }

        private func report(_ windowPoint: CGPoint) {
            guard window != nil else { onMove(nil); return }
            let local = convert(windowPoint, from: nil)
            onMove(bounds.contains(local) ? local : nil)
        }
    }
}

private struct V3WindowEdgeHitBand: Shape {
    let inset: CGFloat
    let cornerRadius: CGFloat
    func path(in rect: CGRect) -> Path {
        V3WindowEdgeRoundedRectShape(inset: inset, cornerRadius: cornerRadius)
            .path(in: rect).strokedPath(StrokeStyle(lineWidth: 22))
    }
}

@MainActor
private enum V3WindowEdgeSongColor {
    private static var trackKey: String?
    private static var currentHue = Double.random(in: 0..<1)
    static func hue(for key: String) -> Double {
        if key != trackKey {
            // Pick once per song; opening a panel or toggling the border must not recolor it.
            currentHue = (currentHue + Double.random(in: 0.19...0.81)).truncatingRemainder(dividingBy: 1)
            trackKey = key
        }
        return currentHue
    }
}

struct V3WindowEdgeProgressSettings: View {
    @Binding var enabled: Bool
    @Binding var colorHex: String
    @Binding var colorMode: String
    var showsModeToggle = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsModeToggle { Toggle("窗口边缘播放进度", isOn: $enabled) }
            Picker("颜色模式", selection: $colorMode) {
                Text("固定颜色").tag("manual")
                Text("自动流转").tag("flow")
                Text("每首随机").tag("randomSong")
                Text("跟随封面").tag("artwork")
            }
            .disabled(!enabled)
            if colorMode == "manual" {
                ColorPicker("进度颜色", selection: Binding(
                    get: { V3WindowEdgeColor.color(from: colorHex) },
                    set: { colorHex = V3WindowEdgeColor.hex(from: $0, keepPrefix: colorHex.hasPrefix("#")) }
                ), supportsOpacity: false)
                .disabled(!enabled)
            }
            Text("进度常驻显示；靠近边缘时显示播放按钮，点击或拖动边缘可跳转。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct V3WindowEdgeTransportButtons: View {
    @V3ContentPlaybackState var state: PlaybackState
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
                .foregroundStyle((primary ? V3WindowEdgeColor.foreground(on: accent) : .white)
                    .opacity(enabled ? 0.96 : 0.40))
                .frame(width: 30, height: 30)
                .background(
                    Circle().fill(primary ? accent.opacity(enabled ? 0.92 : 0.34) : Color.clear)
                )
                .overlay(
                    Circle().strokeBorder(
                        Color.white.opacity(isHovered ? 0.32 : 0),
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

// BEGIN EDGE INTERACTION PURE CORE
// Foundation geometry only. Tests compile this exact section on macOS/Linux.
private enum V3WindowEdgeControlPositioner {
    enum Edge: Equatable {
        case top, right, bottom, left

        var isVertical: Bool { self == .left || self == .right }
    }

    struct Layout {
        let center: CGPoint
        let isVertical: Bool
        let baseSize: CGSize
        let scale: CGFloat
    }

    static func layout(size: CGSize, exitPoint: CGPoint?, preferredEdge: Edge? = nil) -> Layout {
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
            edge = preferredEdge ?? distances.min(by: { $0.1 < $1.1 })?.0 ?? .bottom
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

/// No timer, display link, publisher, artwork access or text-layout work.
/// The state contains only meaningful UI transitions, not the raw pointer stream.
private struct V3WindowEdgeInteractionState: Equatable {
    typealias Edge = V3WindowEdgeControlPositioner.Edge

    struct Anchor: Equatable {
        let edge: Edge
        let fraction: CGFloat

        func point(in size: CGSize) -> CGPoint {
            switch edge {
            case .top: return CGPoint(x: size.width * fraction, y: 0)
            case .right: return CGPoint(x: size.width, y: size.height * fraction)
            case .bottom: return CGPoint(x: size.width * fraction, y: size.height)
            case .left: return CGPoint(x: 0, y: size.height * fraction)
            }
        }
    }

    // Design starting values in points, not claims of native hand-feel validation.
    static let revealDistance: CGFloat = 30
    static let keepDistance: CGFloat = 46
    static let controlCorridor: CGFloat = 12
    static let reanchorDistance: CGFloat = 96
    static let cornerHysteresis: CGFloat = 6

    private(set) var pointerInside = false
    private(set) var isVisible = false
    private(set) var anchor: Anchor?

    func layout(size: CGSize, fallbackExitPoint: CGPoint?) -> V3WindowEdgeControlPositioner.Layout {
        V3WindowEdgeControlPositioner.layout(
            size: size,
            exitPoint: anchor?.point(in: size) ?? fallbackExitPoint,
            preferredEdge: anchor?.edge
        )
    }

    func hiding() -> Self {
        var result = self
        result.pointerInside = false
        result.isVisible = false
        // Remember the last anchor for disappearance, but a real new approach
        // always replaces it. A historical point can never override current input.
        return result
    }

    func updating(point: CGPoint?, size: CGSize, dragging: Bool) -> Self {
        guard size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0,
              let point, point.x.isFinite, point.y.isFinite,
              point.x >= 0, point.y >= 0,
              point.x <= size.width, point.y <= size.height else {
            return hiding()
        }

        var result = self
        result.pointerInside = true

        // Do not summon a player over the existing traffic-light area.
        // This changes passive discovery only; the seek hit band is untouched.
        if point.x < 88 && point.y < 74 && !dragging {
            result.isVisible = false
            return result
        }

        if isVisible, let anchor {
            if dragging { return result } // Keep the active gesture's anchor.
            let positioned = layout(size: size, fallbackExitPoint: nil)
            let width = positioned.baseSize.width * positioned.scale
            let height = positioned.baseSize.height * positioned.scale
            let corridor = CGRect(
                x: positioned.center.x - width / 2,
                y: positioned.center.y - height / 2,
                width: width, height: height
            ).insetBy(dx: -Self.controlCorridor, dy: -Self.controlCorridor)
            if corridor.contains(point) { return result } // Buttons must not evade clicks.

            let nearest = Self.nearestEdge(point: point, size: size)
            let currentDistance = Self.distance(to: anchor.edge, point: point, size: size)
            let nearestDistance = Self.distance(to: nearest, point: point, size: size)
            let chosen = currentDistance <= nearestDistance + Self.cornerHysteresis ? anchor.edge : nearest

            if chosen == anchor.edge && currentDistance <= Self.keepDistance {
                let oldPoint = anchor.point(in: size)
                let displacement = anchor.edge.isVertical ? abs(point.y - oldPoint.y) : abs(point.x - oldPoint.x)
                // Reposition only after the pointer has clearly left this control
                // cluster, never for the small movements required to click it.
                if currentDistance <= Self.revealDistance && displacement > Self.reanchorDistance {
                    result.anchor = Self.makeAnchor(edge: chosen, point: point, size: size)
                }
                return result
            }
            if nearestDistance <= Self.revealDistance {
                result.anchor = Self.makeAnchor(edge: nearest, point: point, size: size)
                return result
            }
            result.isVisible = false
            return result
        }

        let nearest = Self.nearestEdge(point: point, size: size)
        if dragging || Self.distance(to: nearest, point: point, size: size) <= Self.revealDistance {
            result.anchor = Self.makeAnchor(edge: nearest, point: point, size: size)
            result.isVisible = true
        }
        return result
    }

    private static func makeAnchor(edge: Edge, point: CGPoint, size: CGSize) -> Anchor {
        let fraction = edge.isVertical ? point.y / size.height : point.x / size.width
        return Anchor(edge: edge, fraction: min(max(fraction, 0), 1))
    }

    private static func nearestEdge(point: CGPoint, size: CGSize) -> Edge {
        var edge = Edge.top
        var distance = point.y
        let right = size.width - point.x
        if right < distance { edge = .right; distance = right }
        let bottom = size.height - point.y
        if bottom < distance { edge = .bottom; distance = bottom }
        if point.x < distance { edge = .left }
        return edge
    }

    private static func distance(to edge: Edge, point: CGPoint, size: CGSize) -> CGFloat {
        switch edge {
        case .top: return point.y
        case .right: return size.width - point.x
        case .bottom: return size.height - point.y
        case .left: return point.x
        }
    }
}
// END EDGE INTERACTION PURE CORE

private enum V3WindowEdgeColor {
    static func foreground(on color: Color) -> Color {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return .white }
        let brightness = rgb.redComponent * 0.2126 + rgb.greenComponent * 0.7152 + rgb.blueComponent * 0.0722
        return brightness > 0.58 ? .black : .white
    }

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
