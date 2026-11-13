import AppKit
import QuartzCore
import SwiftUI

/// Draws playback progress around the main window and keeps transport controls
/// anchored to the current approaching edge, without publishing every mouse move.
struct V3WindowEdgePlaybackOverlay: View {
    @V3ContentPlaybackState var state: PlaybackState
    let colorHex: String
    let colorMode: String
    let coverLuminance: Double
    let exitPoint: CGPoint?
    let pointerInsideWindow: Bool
    /// The toolbar or an open panel owns the pointer; only the rail stays.
    var suppressControls = false
    var toolbarBounds = CGRect.zero
    /// The foreground cover, when progress is drawn as a halo around it.
    var haloTarget: V3ForegroundCoverFrame?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.v3PlaybackInteractionChanged) private var interactionChanged
    @State private var edgeInteraction = V3WindowEdgeInteractionState()
    @State private var pointerOverToolbar = false
    private struct RailHover: Equatable { let point: CGPoint; let fraction: Double }
    @State private var railHover: RailHover?
    @State private var cursorPushed = false
    /// The pill as drawn. It follows the pointer state at once when showing,
    /// and lingers briefly when the pointer moves away, so a small overshoot
    /// on the way to a button or the scrubber does not make it vanish.
    @State private var playerShown = false
    @State private var lingerTask: Task<Void, Never>?
    @State private var lastCanvasSize = CGSize.zero
    @State private var draftFraction: Double?
    @State private var dragTrackKey: String?
    @State private var windowVisible = false
    @State private var coverAccent = Color.accentColor
    @State private var colorElapsed: TimeInterval = 0
    @State private var colorStartedAt: Date?

    private var controlsVisible: Bool {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--edge-player-expanded") { return true }
#endif
        return playerShown && !suppressControls && !pointerOverToolbar
    }
    private var pointerWantsPlayer: Bool { edgeInteraction.isVisible && edgeInteraction.pointerInside }
    private var animatesColor: Bool { colorMode == "flow" && !reduceMotion && state.isPlaying && windowVisible }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let songHue = V3WindowEdgeSongColor.hue(for: state.currentTrackIdentity?.stableKey ?? "no-track")
            let controlPosition = controlsLayout(size: size)
            let playerVisible = controlsVisible && !controlPosition.frame.intersects(toolbarExclusion)
            let track = progressTrack(size: size)

            ZStack(alignment: .topLeading) {
                // The seek band: a ring around the cover, or 8–24 pt inside the
                // window edge. The outer 8 pt stay free for resizing; the
                // toolbar and the pill sit above it and keep their clicks.
                V3ProgressHitBand(track: track)
                    .fill(Color.clear, style: FillStyle(eoFill: true))
                    .contentShape(V3ProgressHitBand(track: track), eoFill: true)
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                        .onChanged { value in
                            guard canSeek, let fraction = track.fraction(at: value.location) else { return }
                            setDraft(fraction)
                            setHover(RailHover(point: value.location, fraction: fraction))
                        }
                        .onEnded { value in
                            if let fraction = track.fraction(at: value.location) { finishSeek(fraction: fraction) }
                            else { cancelDraft() }
                            updatePointer(value.location, size: size, dragging: false)
                        })
                    .accessibilityLabel("播放进度")
                    .accessibilityValue("\(Int(progressFraction * 100))%")
                    .accessibilityAdjustableAction { direction in
                        guard canSeek else { return }
                        let delta: Double = direction == .increment ? 5 : -5
                        state.seek(to: min(max(0, Double(progressFraction) * state.currentTrack.duration + delta),
                                           state.currentTrack.duration), source: "v3-edge-progress-keyboard")
                    }

                if animatesColor {
                    V3AnimationIsland {
                        TimelineView(.animation(minimumInterval: reduceMotion ? 0.5 : 1.0 / 30.0,
                            paused: !animatesColor)) { context in
                            railPresentation(at: context.date, songHue: songHue, size: size)
                        }
                    }.allowsHitTesting(false)
                } else {
                    railPresentation(at: .now, songHue: songHue, size: size)
                }
                if let hover = railHover {
                    Text(v3EdgeTimeText(hover.fraction * state.currentTrack.duration))
                        .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .modifier(V3ControlBarSurface())
                        .modifier(V3SystemAppearanceModifier())
                        .position(track.labelPosition(for: hover.point))
                        .allowsHitTesting(false).accessibilityHidden(true)
                }


                // Keep popover/state ownership alive when hidden, without ticking its controls.
                V3AnimationIsland {
                    TimelineView(.animation(
                        minimumInterval: reduceMotion ? 0.5 : 1.0 / 30.0,
                        paused: !playerVisible || !windowVisible || (!state.isPlaying && !animatesColor)
                    )) { context in
                        V3WindowEdgeTransportButtons(state: state,
                            accent: accent(at: context.date, songHue: songHue),
                            edge: controlPosition.edge,
                            elapsed: v3EdgeTimeText(state.presentationClock.playbackTime(at: ProcessInfo.processInfo.systemUptime)),
                            total: v3EdgeTimeText(state.currentTrack.duration),
                            progress: Double(progressFraction),
                            duration: state.currentTrack.duration,
                            canSeek: canSeek,
                            onScrub: { setDraft($0) },
                            onScrubEnd: { finishSeek(fraction: $0) })
                    }
                }
                .frame(width: controlPosition.baseSize.width, height: controlPosition.baseSize.height)
                // Drawn around the island, not inside it: the island clips to
                // its bounds, and its size must stay the pill's own size so
                // the drawn pill is exactly the frame the layout computed.
                .modifier(V3ControlBarSurface())
                .modifier(V3SystemAppearanceModifier())
                .scaleEffect(controlPosition.scale * (playerVisible || reduceMotion ? 1 : 0.92))
                .opacity(playerVisible ? 1 : 0)
                .allowsHitTesting(playerVisible)
                .accessibilityHidden(!playerVisible)
                .position(controlPosition.center)
                .animation(.easeOut(duration: playerVisible ? 0.18 : 0.24), value: playerVisible)
                .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 1), value: controlPosition.center)
                .id(controlPosition.edge)
                .transition(.opacity)
                .animation(.easeOut(duration: 0.18), value: controlPosition.edge)


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
        .onChange(of: pointerWantsPlayer) { _, wants in
            lingerTask?.cancel()
            if wants {
                playerShown = true
                // One line per appearance, to compare the drawn pill with the toolbar.
                let frame = edgeInteraction.layout(size: lastCanvasSize, fallbackExitPoint: exitPoint, toolbarBounds: toolbarBounds).frame
                LyricsE2ELog.log("EDGE pill show frame=\(frame.integral) toolbar=\(toolbarBounds.integral) canvas=\(lastCanvasSize)")
                return
            }
            // Leaving the window is a clear exit; drifting away inside it may
            // be an overshoot, so wait a little longer there.
            let delay = edgeInteraction.pointerInside ? 600 : 300
            lingerTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(delay))
                if !Task.isCancelled { playerShown = false }
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
            coverAccent = LyricIslandArtworkColors.listeningAccent(palette) ?? .white
        }
        .onChange(of: animatesColor) { _, active in
            if let colorStartedAt { colorElapsed += max(0, Date().timeIntervalSince(colorStartedAt)) }
            colorStartedAt = active ? .now : nil
        }
        .onChange(of: windowVisible) { _, visible in if !visible { clearPointer() } }
        .onDisappear {
            colorStartedAt = nil
            lingerTask?.cancel()
            setHover(nil)
            cancelDraft()
            clearPointer()
        }
    }

    private func controlsLayout(size: CGSize) -> V3WindowEdgeControlPositioner.Layout {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--edge-player-vertical") {
            return V3WindowEdgeControlPositioner.layout(size: size, exitPoint: CGPoint(x: 0, y: size.height / 2), preferredEdge: .left)
        }
#endif
        return edgeInteraction.layout(size: size, fallbackExitPoint: exitPoint, toolbarBounds: toolbarBounds)
    }

    private func updatePointer(_ point: CGPoint?, size: CGSize, dragging: Bool) {
        // Keep per-pixel input local. Only a visibility/anchor transition writes
        // SwiftUI state, so idle/lyric-region mouse motion does not redraw views.
        if lastCanvasSize != size { lastCanvasSize = size }
        let next = edgeInteraction.updating(point: point, size: size, dragging: dragging, toolbarBounds: toolbarBounds,
                                            lingering: playerShown)
        if next != edgeInteraction { edgeInteraction = next }
        let overToolbar = point.map { toolbarExclusion.contains($0) } ?? false
        if pointerOverToolbar != overToolbar { pointerOverToolbar = overToolbar }
        var hover: RailHover?
        if canSeek, let point, !overToolbar {
            let track = progressTrack(size: size)
            let pill = controlsVisible ? controlsLayout(size: size).frame : .null
            if dragging || (track.contains(point) && !pill.contains(point)),
               let fraction = track.fraction(at: point) {
                hover = RailHover(point: point, fraction: draftFraction ?? fraction)
            }
        }
        setHover(hover)
    }

    private func setHover(_ hover: RailHover?) {
        if railHover != hover { railHover = hover }
        // A pointing hand says the line can be clicked; balanced push/pop.
        if (hover != nil) != cursorPushed {
            if hover != nil { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            cursorPushed = hover != nil
        }
    }

    private var activeHalo: V3ForegroundCoverFrame? {
        haloTarget.flatMap { $0.isLargeEnough ? $0 : nil }
    }

    private func progressTrack(size: CGSize) -> V3ProgressTrack {
        V3ProgressTrack(canvas: size, halo: activeHalo)
    }

    private func clearPointer() {
        pointerOverToolbar = false
        setHover(nil)
        let next = edgeInteraction.hiding()
        if next != edgeInteraction { edgeInteraction = next }
    }

    private var toolbarExclusion: CGRect {
        toolbarBounds.isEmpty ? .null : toolbarBounds.insetBy(dx: -8, dy: -8)
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

    private func setDraft(_ fraction: Double) {
        guard canSeek else { return }
        if dragTrackKey == nil {
            dragTrackKey = state.currentTrackIdentity?.stableKey
            interactionChanged(true)
        }
        guard dragTrackKey == state.currentTrackIdentity?.stableKey else { return }
        draftFraction = min(1, max(0, fraction))
    }

    /// Release on the pill's scrubber. A song change during the drag leaves
    /// `dragTrackKey` on the old song, so the new song is never seeked.
    private func finishSeek(fraction: Double) {
        defer { cancelDraft() }
        guard canSeek, dragTrackKey == state.currentTrackIdentity?.stableKey else { return }
        state.seek(to: state.lyricSnappedSeekTarget(min(1, max(0, fraction)) * state.currentTrack.duration),
                   source: "v3-edge-progress")
    }

    private func cancelDraft() {
        if dragTrackKey != nil { interactionChanged(false) }
        draftFraction = nil
        dragTrackKey = nil
    }

    private func railPresentation(at date: Date, songHue: Double, size: CGSize) -> some View {
        let color = accent(at: date, songHue: songHue)
        return V3NativeProgressRail(clock: state.presentationClock, draft: draftFraction,
                active: windowVisible, color: color, halo: activeHalo,
                highlighted: railHover != nil || draftFraction != nil)
            .allowsHitTesting(false).accessibilityHidden(true)
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

/// Where the foreground cover is drawn, in the window canvas.
struct V3ForegroundCoverFrame: Equatable {
    var frame: CGRect
    var cornerRadius: CGFloat
    /// Thumbnails are not a place for the progress halo.
    var isLargeEnough: Bool { min(frame.width, frame.height) >= 120 }
}

struct V3ForegroundCoverPreferenceKey: PreferenceKey {
    static let defaultValue: V3ForegroundCoverFrame? = nil
    static func reduce(value: inout V3ForegroundCoverFrame?, nextValue: () -> V3ForegroundCoverFrame?) {
        value = value ?? nextValue()
    }
}

extension View {
    /// Reports this cover's drawn frame, including any scale applied outside.
    func v3ReportsForegroundCover(cornerRadiusRatio: CGFloat) -> some View {
        background(GeometryReader { geometry in
            let frame = geometry.frame(in: .named("v3-window-canvas"))
            // Whole points: a resize or scale animation should not publish
            // a new value for every sub-point step.
            let rounded = CGRect(x: frame.minX.rounded(), y: frame.minY.rounded(),
                                 width: frame.width.rounded(), height: frame.height.rounded())
            Color.clear.preference(key: V3ForegroundCoverPreferenceKey.self,
                value: V3ForegroundCoverFrame(frame: rounded, cornerRadius: (rounded.width * cornerRadiusRatio).rounded()))
        })
        // 封面呼吸 rides on every foreground cover; the reported frame stays the resting one.
        .modifier(V3CoverBreath())
    }
}

/// Where the progress line runs: around the foreground cover when there is
/// one, otherwise along the window edge. Drawing, seeking and the time label
/// all read this one description.
struct V3ProgressTrack: Equatable {
    /// The rectangle the line follows, and its corner radius.
    let ring: CGRect
    let cornerRadius: CGFloat
    let isHalo: Bool
    let canvas: CGSize

    /// Distance from the window edge kept free for resizing, and the band's inner edge.
    static let edgeBand: ClosedRange<CGFloat> = 8...24
    /// Half the width of the band around the halo.
    static let haloReach: CGFloat = 6

    init(canvas: CGSize, halo: V3ForegroundCoverFrame?) {
        self.canvas = canvas
        if let halo {
            ring = halo.frame.insetBy(dx: -6, dy: -6)
            cornerRadius = halo.cornerRadius + 6
            isHalo = true
        } else {
            ring = CGRect(origin: .zero, size: canvas).insetBy(dx: 1.5, dy: 1.5)
            cornerRadius = 12
            isHalo = false
        }
    }

    var hitPath: Path {
        var path = Path()
        if isHalo {
            let reach = Self.haloReach
            path.addRoundedRect(in: ring.insetBy(dx: -reach, dy: -reach),
                                cornerSize: CGSize(width: cornerRadius + reach, height: cornerRadius + reach))
            path.addRoundedRect(in: ring.insetBy(dx: reach, dy: reach),
                                cornerSize: CGSize(width: max(0, cornerRadius - reach), height: max(0, cornerRadius - reach)))
        } else {
            let bounds = CGRect(origin: .zero, size: canvas)
            path.addRect(bounds.insetBy(dx: Self.edgeBand.lowerBound, dy: Self.edgeBand.lowerBound))
            path.addRect(bounds.insetBy(dx: Self.edgeBand.upperBound, dy: Self.edgeBand.upperBound))
        }
        return path
    }

    func contains(_ point: CGPoint) -> Bool { hitPath.contains(point, eoFill: true) }

    /// Position along the line, clockwise from the top middle.
    func fraction(at point: CGPoint) -> Double? {
        let origin = CGPoint(x: ring.minX - 1.5, y: ring.minY - 1.5)
        return V3ResponsiveGeometry.edgeProgressFraction(
            at: CGPoint(x: point.x - origin.x, y: point.y - origin.y),
            canvasSize: CGSize(width: ring.width + 3, height: ring.height + 3),
            inset: 1.5, cornerRadius: cornerRadius)
    }

    /// The time label sits beside the pointer, away from the line: inward
    /// from the window edge, outward from the cover.
    func labelPosition(for point: CGPoint) -> CGPoint {
        let distances: [(CGFloat, CGVector)] = [
            (abs(point.y - ring.minY), CGVector(dx: 0, dy: -1)),
            (abs(ring.maxX - point.x), CGVector(dx: 1, dy: 0)),
            (abs(ring.maxY - point.y), CGVector(dx: 0, dy: 1)),
            (abs(point.x - ring.minX), CGVector(dx: -1, dy: 0))
        ]
        let outward = distances.min { $0.0 < $1.0 }?.1 ?? CGVector(dx: 0, dy: -1)
        let away: CGFloat = isHalo ? 24 : -40
        let x = point.x + outward.dx * away
        let y = point.y + outward.dy * away
        return CGPoint(x: min(max(x, 36), max(36, canvas.width - 36)),
                       y: min(max(y, 16), max(16, canvas.height - 16)))
    }
}

struct V3ProgressHitBand: Shape {
    let track: V3ProgressTrack
    func path(in rect: CGRect) -> Path { track.hitPath }
}

func v3EdgeTimeText(_ seconds: TimeInterval) -> String {
    let value = Int(max(0, seconds.isFinite ? seconds : 0))
    return String(format: "%d:%02d", value / 60, value % 60)
}

/// The seek control of the edge pill: a thin line on the pill's inner side.
/// It sits well inside the window, so a click here can never start a resize.
struct V3EdgePillScrubber: View {
    let isVertical: Bool
    let progress: Double
    let accent: Color
    let enabled: Bool
    let onHover: (Double?) -> Void
    let onDrag: (Double) -> Void
    let onRelease: (Double) -> Void
    @State private var hovering = false

    /// Thickness of the pointer target; the visible line is thinner.
    static let hitThickness: CGFloat = 10

    static func fraction(at position: CGFloat, length: CGFloat) -> Double {
        guard length.isFinite, length > 0, position.isFinite else { return 0 }
        return Double(min(max(position / length, 0), 1))
    }

    var body: some View {
        GeometryReader { geometry in
            let length = isVertical ? geometry.size.height : geometry.size.width
            let filled = length * CGFloat(min(max(progress, 0), 1))
            let line: CGFloat = hovering && enabled ? 4 : 2.5
            let fraction: (CGPoint) -> Double = { Self.fraction(at: isVertical ? $0.y : $0.x, length: length) }
            ZStack(alignment: isVertical ? .top : .leading) {
                Capsule().fill(Color.primary.opacity(0.2))
                Capsule().fill(accent)
                    .frame(width: isVertical ? nil : filled, height: isVertical ? filled : nil)
            }
            .frame(width: isVertical ? line : nil, height: isVertical ? nil : line)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    guard enabled else { return }
                    onDrag(fraction(value.location)); onHover(fraction(value.location))
                }
                .onEnded { value in
                    guard enabled else { return }
                    onRelease(fraction(value.location)); onHover(nil)
                })
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hovering = true; if enabled { onHover(fraction(point)) }
                case .ended: hovering = false; onHover(nil)
                }
            }
            .animation(.easeOut(duration: 0.12), value: hovering)
        }
        .accessibilityElement()
        .accessibilityLabel("播放进度")
        .accessibilityValue("\(Int(progress * 100))%")
        .accessibilityAdjustableAction { direction in
            guard enabled else { return }
            onRelease(min(1, max(0, progress + (direction == .increment ? 0.03 : -0.03))))
        }
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
    var showsExplanation = true

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
            if showsExplanation {
                Text("有前景封面时进度绕着封面发光，没有时沿窗口边缘；两处和播放按钮旁的进度条都可点击或拖动跳转。")
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .help("有前景封面时进度绕着封面发光，没有时沿窗口边缘；两处和播放按钮旁的进度条都可点击或拖动跳转。")
    }
}

private struct V3WindowEdgeTransportButtons: View {
    @V3ContentPlaybackState var state: PlaybackState
    let accent: Color
    let edge: V3WindowEdgeControlPositioner.Edge
    let elapsed: String
    let total: String
    let progress: Double
    let duration: TimeInterval
    let canSeek: Bool
    let onScrub: (Double) -> Void
    let onScrubEnd: (Double) -> Void
    @State private var showsPlaylistPicker = false
    /// Where a click on the scrubber would land; replaces the elapsed time.
    @State private var scrubFraction: Double?
    private var isVertical: Bool { edge.isVertical }

    private var scrubber: some View {
        V3EdgePillScrubber(isVertical: isVertical, progress: progress, accent: accent, enabled: canSeek,
            onHover: { scrubFraction = $0 }, onDrag: onScrub, onRelease: onScrubEnd)
    }

    var body: some View {
        let pill = V3WindowEdgeControlPositioner.pillSize(vertical: isVertical)
        return Group {
            if isVertical {
                // The scrubber is on the side facing the canvas.
                HStack(spacing: 0) {
                    if edge == .right { scrubber.frame(width: V3EdgePillScrubber.hitThickness, height: pill.height - 56) }
                    controls.frame(width: 40)
                    if edge != .right { scrubber.frame(width: V3EdgePillScrubber.hitThickness, height: pill.height - 56) }
                }
                .padding(.horizontal, 2)
            } else {
                VStack(spacing: 0) {
                    if edge == .bottom { scrubber.frame(width: pill.width - 48, height: V3EdgePillScrubber.hitThickness) }
                    controls.frame(height: 36)
                    if edge != .bottom { scrubber.frame(width: pill.width - 48, height: V3EdgePillScrubber.hitThickness) }
                }
                .padding(.vertical, 2)
            }
        }
        .frame(width: pill.width, height: pill.height)
        .accessibilityLabel("已播 \(elapsed)，总长 \(total)")
    }

    @ViewBuilder
    private var controls: some View {
        Group {
            if isVertical {
                VStack(spacing: 8) {
                    VStack(spacing: 0) {
                        likeButton
                        if state.canPickPlaylists { playlistButton }
                    }
                    VStack(spacing: 0) {
                        V3PlayerModeButton(state: state, shuffle: true, size: .edge)
                        previousButton
                        playPauseButton
                        nextButton
                        V3PlayerModeButton(state: state, shuffle: false, size: .edge)
                    }
                    VStack(spacing: 0) { elapsedLabel; totalLabel }
                }
            } else {
                HStack(spacing: 8) {
                    HStack(spacing: 0) {
                        likeButton
                        if state.canPickPlaylists { playlistButton }
                    }
                    HStack(spacing: 0) {
                        V3PlayerModeButton(state: state, shuffle: true, size: .edge)
                        previousButton
                        playPauseButton
                        nextButton
                        V3PlayerModeButton(state: state, shuffle: false, size: .edge)
                    }
                    HStack(spacing: 3) {
                        elapsedLabel
                        Text("/").font(.system(size: 10)).foregroundStyle(Color.primary.opacity(0.55))
                        totalLabel
                    }
                    .fixedSize()
                }
            }
        }
    }

    private var elapsedLabel: some View {
        Text(scrubFraction.map { v3EdgeTimeText($0 * duration) } ?? elapsed)
            .font(.system(size: 10, weight: scrubFraction == nil ? .regular : .semibold).monospacedDigit())
            .foregroundStyle(Color.primary.opacity(scrubFraction == nil ? 0.9 : 1)).fixedSize()
    }
    private var totalLabel: some View {
        Text(total).font(.system(size: 10).monospacedDigit())
            .foregroundStyle(Color.primary.opacity(0.55)).fixedSize()
    }

    private var likeButton: some View {
        transportButton(image: state.isTrackLiked == true ? "heart.fill" : "heart",
                        label: state.isTrackLiked == true ? "取消喜欢 (S)" : "喜欢 (S)",
                        enabled: state.hasLiveTrack, primary: false) {
            state.toggleTrackLike()
        }
    }

    private var playlistButton: some View {
        transportButton(image: "text.badge.plus", label: "添加到歌单",
                        enabled: true, primary: false) {
            showsPlaylistPicker = true
        }
        .v3ToolPopover(isPresented: $showsPlaylistPicker, onAnchorPress: { showsPlaylistPicker.toggle() }, width: 380) {
            PlaylistPickerPopover(model: state.playlistPicker, onClose: { showsPlaylistPicker = false })
        }
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

    var body: some View {
        // Shares the main player's transport look; the primary disc takes the
        // edge progress colour so the controls read as part of the rail.
        IslandTransportButton(
            systemImage: image, label: label, enabled: enabled,
            primary: primary, size: .edge, tint: accent, glyph: Color.primary.opacity(0.72), action: action
        )
    }
}

/// Core Animation advances the existing rail path without a SwiftUI layout each frame.
private struct V3NativeProgressRail: NSViewRepresentable {
    let clock: LyricsPresentationClock
    let draft: Double?
    let active: Bool
    let color: Color
    var halo: V3ForegroundCoverFrame?
    var highlighted = false
    func makeNSView(context: Context) -> V3EdgeRailView { V3EdgeRailView() }
    func updateNSView(_ view: V3EdgeRailView, context: Context) {
        view.configure(clock: clock, draft: draft, active: active, color: NSColor(color).cgColor,
                       halo: halo, highlighted: highlighted)
    }
}

final class V3EdgeRailView: NSView {
    let trackLayer = CAShapeLayer()
    let progressLayer = CAShapeLayer()
    private var clock: LyricsPresentationClock?
    /// When set, the line runs around this cover instead of the window.
    private(set) var halo: V3ForegroundCoverFrame?
    private(set) var highlighted = false
    private var draft: Double?
    private var active = false
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for shape in [trackLayer, progressLayer] {
            shape.fillColor = nil
            shape.lineCap = .round
            layer?.addSublayer(shape)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() {
        super.layout()
        updateGeometry()
    }
    private func updateGeometry() {
        // The shape insets its rectangle by 1.5 pt, so the halo sits 6 pt
        // outside the cover and follows its corners.
        let rect = halo.map { $0.frame.insetBy(dx: -7.5, dy: -7.5) } ?? bounds
        let radius = halo.map { $0.cornerRadius + 6 } ?? 12
        let path = V3WindowEdgeRoundedRectShape(cornerRadius: radius).path(in: rect).cgPath
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (shape, width) in [(trackLayer, CGFloat(2.1)), (progressLayer, CGFloat(2.2))] {
            shape.frame = bounds
            shape.path = path
            // Under the pointer the line thickens in place; it never moves.
            shape.lineWidth = highlighted ? 4 : (halo == nil ? width : 3)
        }
        // The played part glows in its own colour; the window-edge line does not.
        progressLayer.shadowOffset = .zero
        progressLayer.shadowRadius = 9
        progressLayer.shadowOpacity = halo == nil ? 0 : 0.9
        CATransaction.commit()
    }
    func configure(clock: LyricsPresentationClock, draft: Double?, active: Bool, color: CGColor,
                   halo: V3ForegroundCoverFrame? = nil, highlighted: Bool = false) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        trackLayer.strokeColor = color.copy(alpha: halo == nil ? 0.22 : 0.16)
        progressLayer.strokeColor = color
        progressLayer.shadowColor = color
        CATransaction.commit()
        if self.halo != halo || self.highlighted != highlighted {
            self.halo = halo
            self.highlighted = highlighted
            updateGeometry()
        }
        guard self.clock != clock || self.draft != draft || self.active != active else { return }
        self.clock = clock; self.draft = draft; self.active = active
        let duration = clock.trackDuration
        let fraction = draft ?? (duration > 0 ? clock.playbackTime(at: ProcessInfo.processInfo.systemUptime) / duration : 0)
        let start = min(1, max(0, fraction))
        let running = active && clock.isPlaying && draft == nil && duration > 0 && start < 1
        progressLayer.removeAnimation(forKey: "playhead")
        CATransaction.begin(); CATransaction.setDisableActions(true)
        progressLayer.strokeEnd = running ? 1 : start
        CATransaction.commit()
        if running {
            let animation = CABasicAnimation(keyPath: "strokeEnd")
            animation.fromValue = start; animation.toValue = 1
            animation.duration = duration * (1 - start)
            animation.timingFunction = CAMediaTimingFunction(name: .linear)
            progressLayer.add(animation, forKey: "playhead")
        }
    }
}

private struct V3WindowEdgeRoundedRectShape: Shape {
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let bounds = rect.insetBy(dx: 1.5, dy: 1.5)
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
enum V3WindowEdgeControlPositioner {
    enum Edge: Equatable, Hashable {
        case top, right, bottom, left

        var isVertical: Bool { self == .left || self == .right }
    }

    /// Distance between the pill and the window edge: the toolbar's own inset.
    static let edgeInset: CGFloat = 18

    /// Buttons plus the scrubber line on the pill's inner side.
    static func pillSize(vertical: Bool) -> CGSize {
        vertical ? CGSize(width: 54, height: 248) : CGSize(width: 304, height: 50)
    }

    struct Layout {
        let edge: Edge
        let center: CGPoint
        let isVertical: Bool
        let baseSize: CGSize
        let scale: CGFloat
        var frame: CGRect {
            CGRect(x: center.x - baseSize.width * scale / 2, y: center.y - baseSize.height * scale / 2,
                   width: baseSize.width * scale, height: baseSize.height * scale)
        }
    }

    static func layout(size: CGSize, exitPoint: CGPoint?, preferredEdge: Edge? = nil, avoiding toolbar: CGRect = .zero) -> Layout {
        let width = max(0, size.width.isFinite ? size.width : 0)
        let height = max(0, size.height.isFinite ? size.height : 0)
        let defaultCenter = CGPoint(x: width / 2, y: height / 2)

        guard width > 0, height > 0 else {
            return Layout(edge: .bottom, center: defaultCenter, isVertical: false, baseSize: .zero, scale: 0)
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
        let baseSize = pillSize(vertical: isVertical)
        let availableLong = isVertical ? height : width
        let availableShort = isVertical ? width : height
        let baseLong = isVertical ? baseSize.height : baseSize.width
        let baseShort = isVertical ? baseSize.width : baseSize.height
        let scale = max(0, min(1, min((availableLong - 52) / baseLong, (availableShort - 52) / baseShort)))
        let halfLength = (isVertical ? baseSize.height : baseSize.width) * scale / 2
        let halfThickness = (isVertical ? baseSize.width : baseSize.height) * scale / 2

        let center: CGPoint
        switch edge {
        case .top:
            center = CGPoint(
                x: clamped(point.x, lower: 88 + halfLength, upper: width - halfLength - 26, fallback: width / 2),
                y: edgeInset + halfThickness
            )
        case .right:
            center = CGPoint(
                x: width - edgeInset - halfThickness,
                y: clamped(point.y, lower: halfLength + 26, upper: height - halfLength - 26, fallback: height / 2)
            )
        case .bottom:
            center = CGPoint(
                x: clamped(point.x, lower: halfLength + 26, upper: width - halfLength - 26, fallback: width / 2),
                y: height - edgeInset - halfThickness
            )
        case .left:
            center = CGPoint(
                x: edgeInset + halfThickness,
                y: clamped(point.y, lower: 74 + halfLength, upper: height - halfLength - 26, fallback: height / 2)
            )
        }

        let result = Layout(edge: edge, center: center, isVertical: isVertical, baseSize: baseSize, scale: scale)
        guard !toolbar.isEmpty else { return result }
        let blocked = toolbar.insetBy(dx: -8, dy: -8)
        guard result.frame.intersects(blocked) else { return result }
        if edge == .top {
            let leftCenter = toolbar.minX - 12 - halfLength
            if leftCenter - halfLength >= 90 {
                return Layout(edge: .top, center: CGPoint(x: leftCenter, y: center.y),
                              isVertical: false, baseSize: baseSize, scale: scale)
            }
            return layout(size: size, exitPoint: CGPoint(x: point.x, y: height), preferredEdge: .bottom)
        }
        var candidates: [Layout] = []
        let topSpace = blocked.minX - 88 - 1
        if topSpace > 0 {
            let base = pillSize(vertical: false)
            let factor = min(1, topSpace / base.width, max(0, height - 52) / base.height)
            let half = base.width * factor / 2
            let x = clamped(point.x, lower: 88 + half, upper: blocked.minX - half - 1, fallback: 88 + half)
            let candidate = Layout(edge: .top, center: CGPoint(x: x, y: edgeInset + base.height * factor / 2), isVertical: false, baseSize: base, scale: factor)
            if !candidate.frame.intersects(blocked) { candidates.append(candidate) }
        }
        let rightSpace = height - blocked.maxY - 27
        if rightSpace > 0 {
            let base = pillSize(vertical: true)
            let factor = min(1, rightSpace / base.height, max(0, width - 52) / base.width)
            let half = base.height * factor / 2
            let y = clamped(point.y, lower: blocked.maxY + half + 1, upper: height - half - 26, fallback: height - half - 26)
            let candidate = Layout(edge: .right, center: CGPoint(x: width - edgeInset - base.width * factor / 2, y: y), isVertical: true, baseSize: base, scale: factor)
            if !candidate.frame.intersects(blocked) { candidates.append(candidate) }
        }
        return candidates.min { a, b in
            let da = pow(a.center.x - point.x, 2) + pow(a.center.y - point.y, 2)
            let db = pow(b.center.x - point.x, 2) + pow(b.center.y - point.y, 2)
            return da < db
        } ?? layout(size: size, exitPoint: CGPoint(x: point.x, y: height), preferredEdge: .bottom)
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
    /// Wide enough to call the pill without sliding onto the resize border,
    /// narrow enough that passing near an edge does not call it.
    static let revealDistance: CGFloat = 44
    /// The pill reaches 68 pt into the window (18 pt inset + 50 pt). The keep
    /// zone goes a little deeper, so the pointer can reach every part of the
    /// pill, and pass slightly beyond it, without the pill hiding.
    static let keepDistance: CGFloat = 84
    static let controlCorridor: CGFloat = 12
    /// Extra travel past the pill's end before it follows the pointer.
    static let followMargin: CGFloat = 20
    static let cornerHysteresis: CGFloat = 6

    private(set) var pointerInside = false
    private(set) var isVisible = false
    private(set) var anchor: Anchor?

    func layout(size: CGSize, fallbackExitPoint: CGPoint?, toolbarBounds: CGRect = .zero) -> V3WindowEdgeControlPositioner.Layout {
        V3WindowEdgeControlPositioner.layout(
            size: size,
            exitPoint: anchor?.point(in: size) ?? fallbackExitPoint,
            preferredEdge: anchor?.edge,
            avoiding: toolbarBounds
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

    /// `lingering`: the view still shows the pill after this state hid it.
    /// Coming back to the pill, or to its edge zone, during that time keeps
    /// it where it is instead of waiting for a fresh approach to the edge.
    func updating(point: CGPoint?, size: CGSize, dragging: Bool, toolbarBounds: CGRect = .zero,
                  lingering: Bool = false) -> Self {
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
            let positioned = layout(size: size, fallbackExitPoint: nil, toolbarBounds: toolbarBounds)
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
                let displacement = anchor.edge.isVertical ? abs(point.y - positioned.center.y) : abs(point.x - positioned.center.x)
                // Follow only once the pointer has passed the end of the pill.
                // While it is level with the pill, the pill stays put, so the
                // movements needed to reach a button never make it jump.
                let halfLength = (anchor.edge.isVertical ? height : width) / 2
                if currentDistance <= Self.revealDistance && displacement > halfLength + Self.followMargin {
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

        if lingering, let anchor {
            let positioned = layout(size: size, fallbackExitPoint: nil, toolbarBounds: toolbarBounds)
            let pill = positioned.frame.insetBy(dx: -Self.controlCorridor, dy: -Self.controlCorridor)
            let alongEdge = anchor.edge.isVertical
                ? pill.minY...pill.maxY ~= point.y : pill.minX...pill.maxX ~= point.x
            if pill.contains(point)
                || (alongEdge && Self.distance(to: anchor.edge, point: point, size: size) <= Self.keepDistance) {
                result.isVisible = true
                return result
            }
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
