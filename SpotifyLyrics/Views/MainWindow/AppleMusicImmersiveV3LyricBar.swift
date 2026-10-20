import SwiftUI
import AppKit

/// The lyric bar, gestures and keyboard all change the existing listening preferences.
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

    func offset(_ delta: Double?) -> String? {
        let store = settings.lyricsOffsetStore
        guard store.setActiveValue(delta.map { store.activeOffset + $0 } ?? 0) else { return nil }
        return String(format: "偏移 %+.1fs", store.activeOffset)
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

struct V3LyricBar: View {
    @ObservedObject var settings: AppSettingsStore
    @ObservedObject var offsetStore: ScopedLyricsOffsetStore
    let hasReading: Bool
    let notice: (String?) -> Void

    private var actions: V3LyricActions { V3LyricActions(settings: settings) }

    var body: some View {
        HStack(spacing: 6) {
            barButton("A−", "缩小字号（Command + 减号）") { notice(actions.fontSize(-2)) }
            barButton("A+", "放大字号（Command + 加号）") { notice(actions.fontSize(2)) }
            Divider().frame(height: 14)
            barButton("◀", "歌词提前 0.1 秒（Option + 左方向键）") { notice(actions.offset(0.1)) }
                .disabled(offsetStore.activeScope == nil)
            barButton(String(format: "%+.1fs", offsetStore.activeOffset), "偏移归零") { notice(actions.offset(nil)) }
                .disabled(offsetStore.activeScope == nil)
            barButton("▶", "歌词延后 0.1 秒（Option + 右方向键）") { notice(actions.offset(-0.1)) }
                .disabled(offsetStore.activeScope == nil)
            Divider().frame(height: 14)
            layer("原", "原文", \.showOriginal)
            layer("译", "译文", \.showTranslation)
            layer("读", "读音", \.showKana).disabled(!hasReading)
            Divider().frame(height: 14)
            ForEach(["left", "center", "right"], id: \.self) { alignment in
                Button {
                    settings.v3LyricsPosition = alignment
                    notice(alignment == "left" ? "左对齐" : alignment == "center" ? "居中" : "右对齐")
                } label: {
                    Image(systemName: alignment == "left" ? "text.alignleft" : alignment == "right" ? "text.alignright" : "text.aligncenter")
                        .foregroundStyle(settings.v3LyricsPosition == alignment ? Color.accentColor : .white)
                }
                .help(alignment == "left" ? "左对齐" : alignment == "right" ? "右对齐" : "居中")
            }
            Divider().frame(height: 14)
            barButton("‹", "上一场景（Command + 左方向键）") { notice(actions.scene(-1)) }
            Text(actions.family.title).lineLimit(1)
            barButton("›", "下一场景（Command + 右方向键）") { notice(actions.scene(1)) }
        }
        .font(.system(size: 11, weight: .medium))
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .fixedSize()
        .accessibilityIdentifier("v3.lyricBar")
    }

    private func barButton(_ title: String, _ tooltip: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action).help(tooltip)
    }

    private func layer(_ title: String, _ name: String, _ keyPath: WritableKeyPath<DisplayPreferences, Bool>) -> some View {
        Button {
            var display = settings.displayPreferences
            display[keyPath: keyPath].toggle()
            settings.displayPreferences = display
            notice(name + (display[keyPath: keyPath] ? "显示" : "隐藏"))
        } label: {
            Text(title).foregroundStyle(settings.displayPreferences[keyPath: keyPath] ? Color.accentColor : .white.opacity(0.45))
        }
        .help("显示或隐藏" + name)
    }
}

struct V3LyricShortcuts: View {
    let settings: AppSettingsStore
    let notice: (String?) -> Void
    private var actions: V3LyricActions { V3LyricActions(settings: settings) }

    var body: some View {
        Group {
            Button("放大字号") { notice(actions.fontSize(2)) }.keyboardShortcut("+", modifiers: .command)
            Button("放大字号") { notice(actions.fontSize(2)) }.keyboardShortcut("=", modifiers: .command)
            Button("缩小字号") { notice(actions.fontSize(-2)) }.keyboardShortcut("-", modifiers: .command)
            Button("上一场景") { notice(actions.scene(-1)) }.keyboardShortcut(.leftArrow, modifiers: .command)
            Button("下一场景") { notice(actions.scene(1)) }.keyboardShortcut(.rightArrow, modifiers: .command)
            Button("歌词提前") { notice(actions.offset(0.1)) }.keyboardShortcut(.leftArrow, modifiers: .option)
            Button("歌词延后") { notice(actions.offset(-0.1)) }.keyboardShortcut(.rightArrow, modifiers: .option)
        }
        .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
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
    }
    static func dismantleNSView(_ view: V3ToolAnchorView, coordinator: Coordinator) { coordinator.stop() }

    final class Coordinator {
        weak var view: NSView?
        var enabled = true
        var onSwipe: ((Int) -> Void)?
        var swipe = V3SceneSwipe()
        var monitor: Any?
        func start() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let view = self.view, self.enabled,
                      event.window === view.window, view.window != nil,
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
