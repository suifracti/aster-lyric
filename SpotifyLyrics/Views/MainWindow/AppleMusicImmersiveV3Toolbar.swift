import Foundation
import SwiftUI
import AppKit
import Combine
import os

/// Unlike a transient system popover, an application-defined popover does
/// not swallow the first click on its own toolbar anchor. Hover lifetime is
/// owned by the existing hover state; outside clicks and Escape still dismiss.
extension View {
    func v3ToolPopover<Content: View>(isPresented: Binding<Bool>, onAnchorPress: @escaping () -> Void, @ViewBuilder content: () -> Content) -> some View {
        background(
            V3ToolPopoverAnchor(
                isPresented: isPresented,
                onAnchorPress: onAnchorPress,
                // Closed panels must not construct/copy every settings page on
                // each playback tick. Keep the anchor, build the page on demand.
                content: isPresented.wrappedValue
                    ? v3HoverToolPanelRoot(content())
                    : AnyView(EmptyView())
            )
        )
    }
}

/// SwiftUI's hosting view ignores the click that activates an inactive
/// window, so a toolbar button needed two clicks after switching from
/// Spotify. This overlay only takes the click in that state; once the window
/// is key and active it is transparent and the SwiftUI button handles input.
extension View {
    func v3FirstClick(_ action: @escaping () -> Void) -> some View {
        overlay(V3FirstClickCatcher(action: action))
    }
}

private struct V3FirstClickCatcher: NSViewRepresentable {
    let action: () -> Void
    func makeNSView(context: Context) -> V3FirstClickView { V3FirstClickView() }
    func updateNSView(_ view: V3FirstClickView, context: Context) { view.action = action }
}

private final class V3FirstClickView: NSView {
    var action: () -> Void = {}
    private var pressed = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let window, !(NSApp.isActive && window.isKeyWindow) else { return nil }
        return super.hitTest(point)
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseUp(with event: NSEvent) {
        defer { pressed = false }
        guard pressed, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        V3ToolbarLog.logger.notice("first click caught")
        window?.makeKeyAndOrderFront(nil)
        action()
    }
}

#if DEBUG
extension Notification.Name {
    static let v3ToolbarDebugCommand = Notification.Name("V3ToolbarDebugCommand")
}
#endif

enum V3ToolbarLog {
    static let logger = Logger(subsystem: "com.spotifylyrics.app", category: "toolbar")
}

/// The listening canvas forces dark, which every child window would inherit.
/// Tool panels read the user's system choice directly instead.
private enum V3SystemAppearance {
    static var colorScheme: ColorScheme {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" ? .dark : .light
    }

    static var current: NSAppearance {
        NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua) ?? NSAppearance(named: .aqua)!
    }
}

/// The main lyric surface forces dark mode. Tool windows use the system
/// appearance, so explicitly reset SwiftUI's inherited color scheme at the
/// hosted root as well as setting the AppKit window appearance.
private func v3ToolPanelRoot<Content: View>(_ content: Content) -> AnyView {
    AnyView(content.environment(\.colorScheme, V3SystemAppearance.colorScheme))
}

/// Hover popovers keep their original dark frosted-glass treatment. Fixed
/// panels use the user's system appearance through `v3ToolPanelRoot` instead.
private func v3HoverToolPanelRoot<Content: View>(_ content: Content) -> AnyView {
    AnyView(content.preferredColorScheme(.dark).environment(\.colorScheme, .dark))
}

final class V3ToolAnchorView: NSView {
    var onWindowAttachment: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { onWindowAttachment?() }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Hover panels can receive their first control click before AppKit has made
/// the popover window key. NSHostingView's default rejects that click, which
/// makes SwiftUI controls look inert until the panel has been clicked again.
private final class V3ToolPopoverHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class V3ToolPopoverHostingController: NSHostingController<AnyView> {
    override func loadView() {
        let hostingView = V3ToolPopoverHostingView(rootView: rootView)
        hostingView.sizingOptions = []
        view = hostingView
    }
}

enum V3HoverPanelPlacement {
    static func frame(_ frame: CGRect, inside owner: CGRect) -> CGRect {
        var result = frame
        result.origin.x = min(max(owner.minX, frame.minX), max(owner.minX, owner.maxX - frame.width))
        result.origin.y = min(max(owner.minY, frame.minY), max(owner.minY, owner.maxY - frame.height))
        return result
    }
}

private struct V3ToolPopoverAnchor: NSViewRepresentable {
    @Binding var isPresented: Bool
    let onAnchorPress: () -> Void
    let content: AnyView

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeNSView(context: Context) -> V3ToolAnchorView { V3ToolAnchorView() }

    func updateNSView(_ anchor: V3ToolAnchorView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.anchor = anchor
        guard isPresented, anchor.window != nil else {
            coordinator.close()
            return
        }
        if let hosting = coordinator.hosting {
            hosting.rootView = content
            hosting.view.appearance = coordinator.popover.appearance
        } else {
            let hosting = V3ToolPopoverHostingController(rootView: content)
            hosting.view.appearance = coordinator.popover.appearance
            coordinator.hosting = hosting
            coordinator.popover.contentViewController = hosting
        }
        let height = min(700, max(260, (anchor.window?.screen?.visibleFrame.height ?? 800) - 100))
        // The panel contains its own scroll view. Measuring the entire hosted
        // tree for every playback tick causes synchronous layout on main.
        if !coordinator.popover.isShown || coordinator.measuredHeight != height {
            coordinator.measuredHeight = height
            if let size = coordinator.hosting?.sizeThatFits(in: CGSize(width: 420, height: height)) {
                let rounded = CGSize(width: ceil(size.width), height: ceil(size.height))
                if coordinator.popover.contentSize != rounded { coordinator.popover.contentSize = rounded }
            }
        }
        if !coordinator.popover.isShown {
            // Position in the owner canvas, rather than the tiny button bounds:
            // AppKit clips positioning rectangles to their positioning view.
            guard let positioningView = anchor.window?.contentView else { return }
            var buttonRect = anchor.bounds
            if !anchor.isFlipped { buttonRect.origin.y -= 4 }
            buttonRect.size.height += 4
            let rect = anchor.convert(buttonRect, to: positioningView)
            coordinator.popover.show(relativeTo: rect, of: positioningView,
                                     preferredEdge: positioningView.isFlipped ? .maxY : .minY)
            if let window = coordinator.hosting?.view.window, let owner = anchor.window {
                let frame = V3HoverPanelPlacement.frame(window.frame, inside: owner.frame)
                let dx = frame.minX - window.frame.minX
                let dy = frame.minY - window.frame.minY
                coordinator.popover.positioningRect = rect.offsetBy(dx: dx, dy: positioningView.isFlipped ? -dy : dy)
            }
            coordinator.startMonitoring()
        }
    }

    static func dismantleNSView(_ nsView: V3ToolAnchorView, coordinator: Coordinator) {
        coordinator.close()
    }

    final class Coordinator: NSObject, NSPopoverDelegate {
        var parent: V3ToolPopoverAnchor
        weak var anchor: NSView?
        let popover = NSPopover()
        var measuredHeight: CGFloat?
        var hosting: V3ToolPopoverHostingController?
        private var localMonitor: Any?
        private var observers: [NSObjectProtocol] = []
        private var trackingMenus = 0
        private var forwardingWindow: NSWindow?

        private func forward(_ event: NSEvent, to window: NSWindow) {
            guard let source = event.window else { return }
            let screenPoint = source.convertPoint(toScreen: event.locationInWindow)
            guard let moved = NSEvent.mouseEvent(
                with: event.type, location: window.convertPoint(fromScreen: screenPoint),
                modifierFlags: event.modifierFlags, timestamp: event.timestamp,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: event.eventNumber, clickCount: event.clickCount, pressure: event.pressure
            ) else { return }
            window.sendEvent(moved)
        }

        init(parent: V3ToolPopoverAnchor) {
            self.parent = parent
            super.init()
            popover.behavior = .applicationDefined
            popover.animates = false
            popover.appearance = NSAppearance(named: .darkAqua)
            popover.delegate = self
        }

        func startMonitoring() {
            guard localMonitor == nil else { return }
            localMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .keyDown]
            ) { [weak self] event in
                guard let self else { return event }
                return self.handle(event)
            }
            let center = NotificationCenter.default
            observers = [
                center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                    self?.trackingMenus += 1
                },
                center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                    guard let self else { return }
                    self.trackingMenus = max(0, self.trackingMenus - 1)
                },
                center.addObserver(forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main) { [weak self] _ in
                    self?.dismiss()
                }
            ]
        }

        func handle(_ event: NSEvent) -> NSEvent? {
            // Finish a click that started on the popover's transparent chrome
            // in the window underneath, so that window sees a whole click.
            if let target = forwardingWindow,
               event.type == .leftMouseDragged || event.type == .leftMouseUp {
                forward(event, to: target)
                if event.type == .leftMouseUp {
                    forwardingWindow = nil
                    if !popover.isShown { stopMonitoring() }
                }
                return nil
            }
            if event.type == .leftMouseDragged || event.type == .leftMouseUp { return event }
            guard trackingMenus == 0 else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { dismiss(); return nil }
                return event
            }
            guard event.type == .leftMouseDown, let anchor, let anchorWindow = anchor.window,
                  let eventWindow = event.window else {
                if event.type != .leftMouseDown { return event }
                dismiss(); return event
            }
            let screenPoint = eventWindow.convertPoint(toScreen: event.locationInWindow)
            let anchorRect = anchorWindow.convertToScreen(anchor.convert(anchor.bounds, to: nil))
            // When the popover overlaps the anchor, AppKit routes the click
            // to the popover window; handle it here because the toolbar button
            // cannot receive it. A click routed to the owner window must reach
            // the SwiftUI button, or both paths toggle the same panel.
            if anchorRect.contains(screenPoint) {
                // Keep the hover panel alive until mouse-up. The owner-window
                // button pins it on release; closing here would remove that
                // button mid-click and make the action intermittent.
                if eventWindow === anchorWindow {
                    V3ToolbarLog.logger.notice("toolbar anchor click delivered to owner window")
                    return event
                }
                V3ToolbarLog.logger.notice("anchor click → pin")
                parent.onAnchorPress()
                return nil
            }
            if let contentView = popover.contentViewController?.view, eventWindow === contentView.window {
                let contentRect = eventWindow.convertToScreen(contentView.convert(contentView.bounds, to: nil))
                // The popover window is larger than its visible panel (arrow,
                // shadow). A click there was meant for the toolbar below it.
                if !contentRect.contains(screenPoint), anchorWindow.frame.contains(screenPoint) {
                    V3ToolbarLog.logger.notice("click on popover chrome → forwarded")
                    // Set before dismissing so the monitor survives until mouse up.
                    forwardingWindow = anchorWindow
                    dismiss()
                    forward(event, to: anchorWindow)
                    return nil
                }
                return event
            }
            dismiss()
            return event
        }

        private func dismiss() {
            if parent.isPresented { parent.isPresented = false }
            close()
        }

        func close() {
            stopMonitoring()
            popover.performClose(nil)
        }

        func popoverDidClose(_ notification: Notification) { stopMonitoring() }

        private func stopMonitoring() {
            guard forwardingWindow == nil else { return }
            if let localMonitor { NSEvent.removeMonitor(localMonitor) }
            localMonitor = nil
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            trackingMenus = 0
        }
    }
}

/// A single external tool window; presenting it never changes the main canvas.
struct V3PinnedInspectorPanelHost<Content: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    let title: String
    let content: Content
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeNSView(context: Context) -> V3ToolAnchorView { V3ToolAnchorView() }
    func updateNSView(_ anchor: V3ToolAnchorView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.anchor = anchor
        anchor.onWindowAttachment = { [weak coordinator] in coordinator?.updatePanel() }
        coordinator.updatePanel()
    }
    static func dismantleNSView(_ nsView: V3ToolAnchorView, coordinator: Coordinator) {
        nsView.onWindowAttachment = nil
        coordinator.close(notifyBinding: false)
    }

    final class Coordinator: NSObject, NSWindowDelegate {
        var parent: V3PinnedInspectorPanelHost
        weak var anchor: NSView?
        private var panel: NSPanel?
        private var hosting: NSHostingController<AnyView>?
        private var escapeMonitor: Any?
        private var observers: [NSObjectProtocol] = []
        private var userPositioned = false
        private var settingFrame = false
        private weak var observedOwner: NSWindow?
        init(parent: V3PinnedInspectorPanelHost) { self.parent = parent; super.init() }

        func updatePanel() {
            guard parent.isPresented else {
                close(notifyBinding: false); return
            }
            guard let owner = anchor?.window else {
                V3ToolbarLog.logger.notice("pinned panel waiting for owner window attachment")
                return
            }
            if let hosting { hosting.rootView = v3ToolPanelRoot(parent.content) }
            else {
                let controller = NSHostingController(rootView: v3ToolPanelRoot(parent.content))
                controller.sizingOptions = []
                controller.view.appearance = V3SystemAppearance.current
                hosting = controller
            }
            if panel == nil {
                let candidate = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 720),
                                        styleMask: [.titled, .closable, .utilityWindow, .resizable],
                                        backing: .buffered, defer: false)
                candidate.isReleasedWhenClosed = false
                candidate.isFloatingPanel = true
                candidate.hidesOnDeactivate = false
                // Only text fields take key focus, so the main window stays active
                // and the next toolbar click works the first time.
                candidate.becomesKeyOnlyIfNeeded = true
                candidate.level = .floating
                candidate.collectionBehavior = [.fullScreenAuxiliary]
                candidate.minSize = NSSize(width: 320, height: 360)
                candidate.contentViewController = hosting
                candidate.delegate = self
                panel = candidate
                observe(owner)
                positionBeside(owner)
            }
            guard let panel else { return }
            let system = V3SystemAppearance.current
            if panel.appearance?.name != system.name {
                panel.appearance = system
                hosting?.view.appearance = system
            }
            panel.title = parent.title
            if !panel.isVisible {
                positionBeside(owner)
                panel.orderFront(nil)
                V3ToolbarLog.logger.notice("pinned panel presented")
                startEscapeMonitoring()
            }
        }
        private func positionBeside(_ owner: NSWindow) {
            guard let panel, !userPositioned, let screen = owner.screen else { return }
            let requested = CGSize(width: 360, height: min(780, max(420, owner.frame.height)))
            let frame = LyricIslandPanelPlacement.frame(owner: owner.frame,
                                                        visible: screen.visibleFrame, requested: requested)
            guard panel.frame != frame else { return }
            settingFrame = true
            panel.setFrame(frame, display: true, animate: false)
            settingFrame = false
        }
        private func observe(_ owner: NSWindow) {
            guard observedOwner !== owner else { return }
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            observedOwner = owner
            for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                         NSWindow.didChangeScreenNotification, NSWindow.didEnterFullScreenNotification,
                         NSWindow.didExitFullScreenNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: owner, queue: .main) {
                    [weak self, weak owner] _ in
                    guard let self, let owner else { return }
                    self.positionBeside(owner)
                })
            }
        }
        func windowDidMove(_ notification: Notification) {
            if !settingFrame, panel?.isVisible == true { userPositioned = true }
        }
        func windowWillClose(_ notification: Notification) { close(notifyBinding: true) }
        func close(notifyBinding: Bool) {
            let old = panel
            old?.delegate = nil
            panel = nil; hosting = nil; observedOwner = nil; userPositioned = false
            observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
            if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
            escapeMonitor = nil
            old?.contentViewController = nil
            old?.close()
            if notifyBinding, parent.isPresented { parent.isPresented = false }
        }
        private func startEscapeMonitoring() {
            guard escapeMonitor == nil else { return }
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.keyCode == 53,
                      event.window === self.panel || event.window === self.anchor?.window else { return event }
                self.close(notifyBinding: true)
                return nil
            }
        }
    }
}

struct QuietToolbarButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.60 : hovering ? 1 : 0.86)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onHover { hovering = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hovering)
    }
}
