import AppKit
import SwiftUI

/// Shared behind-window glass, independent of artwork tint and system popover chrome.
struct V3PanelGlass: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        V3PanelBlur()
            .overlay((scheme == .dark ? Color.black : .white).opacity(scheme == .dark ? 0.10 : 0.06))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct V3PanelBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        if #available(macOS 26.0, *) {
            let view = NSGlassEffectView()
            view.style = .clear
            view.cornerRadius = 14
            view.tintColor = NSColor.windowBackgroundColor.withAlphaComponent(0.28)
            return view
        }
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
}

private final class V3GlassPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Small adapter preserving the toolbar's existing hover/outside-click coordinator.
@MainActor
final class V3GlassPopover {
    private let panel = V3GlassPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private weak var anchor: NSView?
    var onClose: (() -> Void)?
    var isShown: Bool { panel.isVisible }
    var appearance: NSAppearance? {
        get { panel.appearance }
        set { panel.appearance = newValue }
    }
    var contentViewController: NSViewController? {
        get { panel.contentViewController }
        set { panel.contentViewController = newValue }
    }
    var contentSize = CGSize(width: 360, height: 520) {
        didSet { if isShown { position() } }
    }
    var positioningRect = CGRect.zero {
        didSet { if isShown { position() } }
    }
    init() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .floating
        panel.collectionBehavior = [.fullScreenAuxiliary]
    }
    func show(relativeTo rect: CGRect, of view: NSView, preferredEdge: NSRectEdge) {
        anchor = view
        positioningRect = rect
        position()
        if let owner = view.window { owner.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
        panel.initialFirstResponder = nil
        panel.makeFirstResponder(nil)
    }
    private func position() {
        guard let anchor, let owner = anchor.window, let screen = owner.screen else { return }
        let rect = owner.convertToScreen(anchor.convert(positioningRect, to: nil))
        var frame = CGRect(x: rect.midX - contentSize.width / 2, y: rect.minY - contentSize.height - 6,
                           width: contentSize.width, height: contentSize.height)
        if frame.minY < screen.visibleFrame.minY { frame.origin.y = rect.maxY + 6 }
        frame = V3HoverPanelPlacement.frame(frame, inside: owner.frame)
        panel.setFrame(frame, display: true)
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.cornerRadius = 14
        panel.contentView?.layer?.masksToBounds = true
    }
    func performClose(_ sender: Any?) {
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(sender)
        onClose?()
    }
}
