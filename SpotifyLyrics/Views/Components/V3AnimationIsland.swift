import AppKit
import SwiftUI

/// A fixed-size AppKit boundary. Its clock invalidates only this small view graph,
/// never the main window's layout or intrinsic size.
struct V3AnimationIsland<Content: View>: NSViewRepresentable {
    @Environment(\.self) private var environment
    @ViewBuilder var content: () -> Content

    func makeNSView(context: Context) -> V3AnimationIslandView {
        V3AnimationIslandView(root: AnyView(content().environment(\.self, environment)))
    }
    func updateNSView(_ view: V3AnimationIslandView, context: Context) {
        view.host.rootView = AnyView(content().environment(\.self, environment))
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: V3AnimationIslandView, context: Context) -> CGSize? {
        if let width = proposal.width, let height = proposal.height { return CGSize(width: width, height: height) }
        return proposal.replacingUnspecifiedDimensions(by: .zero)
    }
}

final class V3AnimationIslandView: NSView {
    let host: NSHostingView<AnyView>
    init(root: AnyView) {
        host = NSHostingView(rootView: root)
        super.init(frame: .zero)
        host.sizingOptions = []
        addSubview(host)
        host.autoresizingMask = [.width, .height]
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        host.frame = bounds
    }
}
