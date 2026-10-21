import SwiftUI
import AppKit

/// Gestures change the existing listening preferences.
@MainActor
struct V3LyricActions {
    let settings: AppSettingsStore

    var family: V3SceneFamily {
        settings.v3ListeningScene.map(V3SceneFamily.family(of:))
            ?? V3SceneFamily.family(ofLegacy: settings.v3ArtworkPresentation)
    }

    func fontSize(_ delta: CGFloat) -> String {
        var display = settings.displayPreferences
        display.fontSize = min(42, max(14, display.fontSize + delta))
        if display != settings.displayPreferences { settings.displayPreferences = display }
        return "字号 \(Int(display.fontSize))"
    }

    static func nextBlurPreset(after value: Double) -> Double {
        [0.0, 25, 50, 75, 100].first { $0 > value } ?? 0
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

/// Main-window listening keys; text entry and system key combinations pass through.
enum V3ListeningKey: Equatable {
    case playPause, previous, next, like, resetOffset, focus, help, escape
    case offset(Double), blurFine(Double), blurCycle

    static func resolve(_ text: String, modifiers: NSEvent.ModifierFlags, repeating: Bool,
                        focused: Bool, editing: Bool) -> Self? {
        guard focused, !editing, modifiers.intersection([.command, .option, .control]).isEmpty else { return nil }
        let key = text.lowercased()
        if repeating && !["z", "c", ",", ".", "<", ">"].contains(key) { return nil }
        switch key {
        case " ": return .playPause
        case "a": return .previous
        case "d": return .next
        case "s": return .like
        case "z": return .offset(-0.1)
        case "c": return .offset(0.1)
        case "x": return .resetOffset
        case "/", "?": return modifiers.contains(.shift) ? .help : .blurCycle
        case ",", "<": return .blurFine(-5)
        case ".", ">": return .blurFine(5)
        case "f": return .focus
        case "\u{1b}": return .escape
        default: return nil
        }
    }
}

struct V3LikeConfirmation {
    private var pending: (track: String, time: TimeInterval)?
    mutating func target(isLiked: Bool, track: String, now: TimeInterval) -> Bool? {
        if !isLiked { pending = nil; return true }
        if let pending, pending.track == track, now - pending.time < 3 {
            self.pending = nil
            return false
        }
        pending = (track, now)
        return nil
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
    let onKey: (V3ListeningKey) -> Void
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
        context.coordinator.onKey = onKey
    }
    static func dismantleNSView(_ view: V3ToolAnchorView, coordinator: Coordinator) { coordinator.stop() }

    final class Coordinator {
        weak var view: NSView?
        var enabled = true
        var onSwipe: ((Int) -> Void)?
        var onKey: ((V3ListeningKey) -> Void)?
        var swipe = V3SceneSwipe()
        var monitor: Any?
        func start() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .keyDown]) { [weak self] event in
                guard let self, let view = self.view, let window = view.window,
                      event.window === window else { return event }
                if event.type == .keyDown {
                    guard let key = V3ListeningKey.resolve(event.characters ?? "", modifiers: event.modifierFlags,
                        repeating: event.isARepeat, focused: window.isKeyWindow && NSApp.isActive,
                        editing: window.firstResponder is NSText || window.firstResponder is NSTextField) else { return event }
                    self.onKey?(key)
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
