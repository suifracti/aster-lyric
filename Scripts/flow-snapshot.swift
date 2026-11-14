// Renders the bundled 流动 page (Resources/Butterchurn/index.html) off screen with
// a synthetic beat and saves the canvas, so presets can be checked without Spotify.
// Usage: swift Scripts/flow-snapshot.swift SpotifyLyrics/Resources/Butterchurn/index.html out.png
// Each run picks a random preset. Test-only injections: preserveDrawingBuffer, and a
// timer in place of animation frames (an off-screen view gets none). CSS filters on
// the canvas (the brightness cap) are not in the saved image.
import AppKit
import WebKit

final class Driver: NSObject, WKNavigationDelegate {
    let web: WKWebView
    let window: NSWindow
    let out: String
    var tick = 0
    init(page: URL, out: String) {
        self.out = out
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        // Test only: keep the WebGL picture so the canvas can be read back.
        config.userContentController.addUserScript(WKUserScript(source: """
            const original = HTMLCanvasElement.prototype.getContext;
            HTMLCanvasElement.prototype.getContext = function(type, attrs) {
                return original.call(this, type, Object.assign({}, attrs || {}, { preserveDrawingBuffer: true }));
            };
            window.__frames = 0;
            const raf = window.requestAnimationFrame.bind(window);
            // An off-screen view gets no animation frames; drive them with a timer.
            window.requestAnimationFrame = function(cb) { return setTimeout(function() { window.__frames++; cb(performance.now()); }, 16); };
            """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 500), configuration: config)
        web.setValue(false, forKey: "drawsBackground")
        window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 800, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.backgroundColor = .black
        window.contentView = web
        super.init()
        web.navigationDelegate = self
        window.orderFrontRegardless()
        web.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript("window.asterError || (window.asterReady ? 'ready' : 'not ready')") { r, _ in print("page:", r ?? "nil") }
        webView.evaluateJavaScript("window.asterRun(true)")
        Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { _ in self.feed() }
        Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { _ in self.shoot() }
    }
    func feed() {
        tick += 1
        let t = Double(tick) / 30
        let beat = exp(-fmod(t, 0.5) * 8)   // a kick twice a second
        let bytes = (0..<1024).map { i -> UInt8 in
            let x = Double(i) / 48000
            let v = 0.8 * beat * sin(2 * .pi * 60 * x + t) + 0.25 * sin(2 * .pi * 880 * x) + 0.1 * sin(2 * .pi * 3000 * x * (1 + 0.1 * sin(t)))
            return UInt8(max(0, min(255, 128 + v * 110)))
        }
        web.evaluateJavaScript("window.asterFeed('\(Data(bytes).base64EncodedString())')")
    }
    func shoot() {
        web.evaluateJavaScript("window.__frames") { r, _ in print("frames:", r ?? "nil") }
        web.evaluateJavaScript("document.getElementById('c').toDataURL('image/png')") { result, error in
            if let url = result as? String, let comma = url.firstIndex(of: ","),
               let data = Data(base64Encoded: String(url[url.index(after: comma)...])) {
                try? data.write(to: URL(fileURLWithPath: self.out)); print("saved", data.count)
            } else { print("read failed", error as Any) }
            NSApp.terminate(nil)
        }
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let driver = Driver(page: URL(fileURLWithPath: CommandLine.arguments[1]), out: CommandLine.arguments[2])
Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { _ in print("timeout"); NSApp.terminate(nil) }
app.run()
_ = driver
