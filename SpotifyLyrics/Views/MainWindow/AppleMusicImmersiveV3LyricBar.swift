import SwiftUI
import AppKit

/// Gestures change the existing listening preferences.
@MainActor
struct V3LyricActions {
    let settings: AppSettingsStore

    var family: V3SceneFamily {
        settings.v3ListeningScene.map(V3SceneFamily.family(of:))
            ?? V3SceneFamily.family(ofClassic: settings.v3ArtworkPresentation)
    }

    func fontSize(_ delta: CGFloat) -> String {
        var display = settings.displayPreferences
        display.fontSize = min(42, max(14, display.fontSize + delta))
        if display != settings.displayPreferences { settings.displayPreferences = display }
        return "字号 \(Int(display.fontSize))"
    }

    func scene(_ direction: Int) -> String {
        let families = V3SceneFamily.allCases
        let index = families.firstIndex(of: family)!
        let next = families[(index + direction + families.count) % families.count]
        let target = next.target(settings: settings)
        if let scene = target.0 { settings.selectV3Scene(scene, renderer: target.1) }
        else { settings.selectLegacyV3Presentation(target.1) }
        return next.title
    }
}

/// Space belongs to playback only while the canvas has focus, never a text editor.
enum V3SpacePlayback {
    static func handles(_ event: NSEvent, in window: NSWindow) -> Bool {
        event.keyCode == 49 && !event.isARepeat
            && event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
            && !(window.firstResponder is NSText) && !(window.firstResponder is NSTextField)
    }
}

/// One scene change per horizontal two-finger scroll gesture; vertical lyric scrolling stays intact.
struct V3SceneSwipe {
    private var distance: CGFloat = 0
    private var switched = false

    mutating func begin() { distance = 0; switched = false }
    mutating func move(x: CGFloat, y: CGFloat) -> Int? {
        guard !switched, abs(x) > abs(y) else { return nil }
        distance += x
        guard abs(distance) >= 60 else { return nil }
        switched = true
        return distance < 0 ? 1 : -1
    }
}

struct V3CanvasSceneSwipe: NSViewRepresentable {
    let enabled: Bool
    let onPlayPause: () -> Void
    let onSwipe: (Int) -> Void
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> V3ToolAnchorView {
        let view = V3ToolAnchorView()
        context.coordinator.view = view
        context.coordinator.start()
        return view
    }
    func updateNSView(_ view: V3ToolAnchorView, context: Context) {
        context.coordinator.enabled = enabled
        context.coordinator.onSwipe = onSwipe
        context.coordinator.onPlayPause = onPlayPause
    }
    static func dismantleNSView(_ view: V3ToolAnchorView, coordinator: Coordinator) { coordinator.stop() }

    final class Coordinator {
        weak var view: NSView?
        var enabled = true
        var onSwipe: ((Int) -> Void)?
        var onPlayPause: (() -> Void)?
        var swipe = V3SceneSwipe()
        var monitor: Any?
        func start() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .keyDown]) { [weak self] event in
                guard let self, let view = self.view, let window = view.window,
                      event.window === window else { return event }
                if event.type == .keyDown {
                    guard V3SpacePlayback.handles(event, in: window) else { return event }
                    self.onPlayPause?()
                    return nil
                }
                guard self.enabled,
                      view.bounds.contains(view.convert(event.locationInWindow, from: nil)),
                      event.hasPreciseScrollingDeltas, event.momentumPhase.isEmpty else { return event }
                if event.phase.contains(.began) { self.swipe.begin() }
                if event.phase.contains(.ended) || event.phase.contains(.cancelled) { self.swipe.begin(); return event }
                if let direction = self.swipe.move(x: event.scrollingDeltaX, y: event.scrollingDeltaY) {
                    self.onSwipe?(direction)
                    return nil
                }
                return event
            }
        }
        func stop() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
    }
}
