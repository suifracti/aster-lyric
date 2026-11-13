import AppKit
import Combine
import SwiftUI

private final class FullScreenLyricsWindow: NSWindow {
    var onExitRequested: (() -> Void)?
    override func cancelOperation(_ sender: Any?) {
        // Sheets and popovers have their own responder chains. Do not close
        // the underlying presentation while a sheet is being dismissed.
        guard attachedSheet == nil else { return }
        onExitRequested?()
    }
}

/// One retained native fullscreen window over the shared live playback state.
@MainActor
final class FullScreenLyricsWindowController: NSObject, ObservableObject, NSWindowDelegate {
    enum Phase { case hidden, entering, visible, exiting }
    @Published private(set) var phase: Phase = .hidden
    var isVisible: Bool { phase != .hidden }
    private(set) var window: NSWindow?
    private weak var playbackState: PlaybackState?
    private var exitRequested = false
    var onDidHide: (() -> Void)?

    func toggle(state: PlaybackState) {
        if isVisible { hide() } else { _ = show(state: state) }
    }

    @discardableResult
    func show(state: PlaybackState, settings: AppSettingsStore? = nil) -> Bool {
        guard phase == .hidden else { return true }
        guard let screen = targetScreen() else { return false }
        playbackState = state
        if window == nil { window = makeWindow(state: state, settings: settings ?? .shared) }
        guard let window else { return false }
        // Seed the desired display before AppKit owns the fullscreen frame.
        window.setFrame(screen.visibleFrame.insetBy(dx: 40, dy: 40), display: false)
        exitRequested = false
        phase = .entering
        state.showFullScreen = true
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.toggleFullScreen(nil)
        return true
    }

    func hide() {
        switch phase {
        case .hidden, .exiting: return
        case .entering: exitRequested = true
        case .visible:
            exitRequested = true
            phase = .exiting
            window?.toggleFullScreen(nil)
        }
    }

    private func finishHide() {
        guard phase != .hidden else { return }
        window?.orderOut(nil)
        phase = .hidden
        exitRequested = false
        playbackState?.showFullScreen = false
        onDidHide?()
    }

    private func makeWindow(state: PlaybackState, settings: AppSettingsStore) -> NSWindow {
        let window = FullScreenLyricsWindow(contentRect: .zero,
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.title = "全屏歌词"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .black
        window.level = .normal
        window.collectionBehavior = [.fullScreenPrimary, .fullScreenDisallowsTiling]
        window.acceptsMouseMovedEvents = true
        window.onExitRequested = { [weak self] in self?.hide() }
        window.contentView = NSHostingView(rootView: FullScreenLyricsView(state: state, settings: settings))
        return window
    }

    private func targetScreen() -> NSScreen? {
        let home = WindowStatePersistence.shared.attachedMainWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first
        let screens = NSScreen.screens
        guard let index = Self.targetIndex(home: home.flatMap { screens.firstIndex(of: $0) }, count: screens.count,
                                           prefersOther: AppSettingsStore.shared.fullScreenPrefersOtherScreen) else { return home }
        return screens[index]
    }

    /// Which display 全屏歌词 opens on: the main window's own, or — when asked
    /// and there is more than one — the next display after it.
    nonisolated static func targetIndex(home: Int?, count: Int, prefersOther: Bool) -> Int? {
        guard count > 0 else { return nil }
        let base = home.flatMap { (0..<count).contains($0) ? $0 : nil } ?? 0
        return prefersOther && count > 1 ? (base + 1) % count : base
    }

    func window(_ window: NSWindow, willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions) -> NSApplication.PresentationOptions {
        // Window-scoped options are restored by AppKit when fullscreen ends.
        var options = proposedOptions
        options.remove([.hideDock, .hideMenuBar])
        options.formUnion([.autoHideDock, .autoHideMenuBar])
        return options
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        guard phase != .hidden else { return }
        phase = .visible
        if exitRequested { hide() }
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        guard phase != .hidden else { return }
        phase = .exiting
    }

    func windowDidExitFullScreen(_ notification: Notification) { finishHide() }
    func windowDidFailToEnterFullScreen(_ window: NSWindow) { finishHide() }
    func windowDidFailToExitFullScreen(_ window: NSWindow) {
        phase = .visible
        exitRequested = false
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { hide(); return false }
    func windowWillClose(_ notification: Notification) { finishHide() }
}
