import SwiftUI
import WebKit

/// 流动: MilkDrop presets (butterchurn, bundled, MIT) drawn behind the
/// lyrics and driven by the sound 随音乐律动 already hears. The page is
/// local, has no network access, and never takes the pointer.
struct V3FlowLayer: NSViewRepresentable {
    let running: Bool

    final class PassthroughWebView: WKWebView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func scrollWheel(with event: NSEvent) { nextResponder?.scrollWheel(with: event) }
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var web: WKWebView?
        var timer: Timer?
        var loaded = false
        var running = false

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            apply()
            webView.evaluateJavaScript("window.asterError || (window.asterReady ? 'ready' : 'not ready')") { result, _ in
                LyricsE2ELog.log("FLOW page \(result as? String ?? "no answer")")
            }
        }

        /// Only the bundled page: anything else is refused.
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            navigationAction.request.url?.isFileURL == true ? .allow : .cancel
        }

        func apply() {
            guard loaded, let web else { return }
            web.evaluateJavaScript("window.asterRun && window.asterRun(\(running))", completionHandler: nil)
            timer?.invalidate()
            timer = nil
            guard running else { return }
            let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.feed() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }

        private func feed() {
            guard let web else { return }
            let levels = V3MusicPulse.levels
            let fresh = ProcessInfo.processInfo.systemUptime - levels.updatedAt < 0.5
            let bytes = fresh && !levels.waveform.isEmpty ? levels.waveform : V3FlowLayer.silence
            web.evaluateJavaScript("window.asterFeed && window.asterFeed('\(Data(bytes).base64EncodedString())')", completionHandler: nil)
        }

        func stop() { timer?.invalidate(); timer = nil }
    }

    static let silence = [UInt8](repeating: 128, count: 1024)

    static var pageURL: URL? {
        Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Butterchurn")
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = PassthroughWebView(frame: .zero, configuration: configuration)
        web.setValue(false, forKey: "drawsBackground")
        web.navigationDelegate = context.coordinator
        context.coordinator.web = web
        context.coordinator.running = running
        if let page = Self.pageURL {
            web.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        }
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        guard context.coordinator.running != running else { return }
        context.coordinator.running = running
        context.coordinator.apply()
    }

    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) {
        coordinator.stop()
        web.evaluateJavaScript("window.asterRun && window.asterRun(false)", completionHandler: nil)
    }
}
