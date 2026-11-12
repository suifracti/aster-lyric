import AppKit
import SwiftUI

/// Hover that also works while another app is in front. SwiftUI's `onHover`
/// reports only while this app is active (Lyrimuse found the same), but
/// desktop lyrics, the capsule and the outside toolbar mostly float over
/// other apps. An AppKit tracking area with `.activeAlways` reports anyway.
/// It only tracks; clicks pass through to the controls above it.
struct V3AlwaysHoverTracker: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> V3AlwaysHoverView {
        let view = V3AlwaysHoverView()
        view.onChange = onChange
        return view
    }
    func updateNSView(_ view: V3AlwaysHoverView, context: Context) { view.onChange = onChange }
}

final class V3AlwaysHoverView: NSView {
    var onChange: (Bool) -> Void = { _ in }
    private var area: NSTrackingArea?
    private var inside = false

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let next = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(next)
        area = next
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // A tracking area added under the pointer reports no entry.
        guard let window else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        report(bounds.contains(point))
    }

    override func mouseEntered(with event: NSEvent) { report(true) }
    override func mouseExited(with event: NSEvent) { report(false) }

    private func report(_ value: Bool) {
        guard value != inside else { return }
        inside = value
        onChange(value)
    }
}

extension View {
    /// `onHover` that keeps working while the app is in the background.
    func v3OnHover(_ action: @escaping (Bool) -> Void) -> some View {
        background(V3AlwaysHoverTracker(onChange: action))
    }
}
