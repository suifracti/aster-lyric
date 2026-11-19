import SwiftUI
import AppKit

/// Window lifecycle façade for the auxiliary lyrics surfaces.  Each surface
/// has one retained controller, while PlaybackState remains the single owner
/// of playback, lyric, translation and current-line state.
@MainActor
public final class WindowManager: ObservableObject {
    public static let shared = WindowManager()

    /// Actual exposure, rather than a command toggle or app activation.
    var hasExposedLyricsWindow: Bool {
        guard !NSApp.isHidden else { return false }
        let main = MainWindowWorkspaceMode.shared.destination == .workbench ? nil : WindowStatePersistence.shared.attachedMainWindow
        let windows = [main,
                       floatingController?.playbackWindow, capsuleController?.playbackWindow,
                       fullScreenController?.window]
        return windows.contains { window in
            guard let window else { return false }
            return window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
        } || MenuBarLyricsController.shared.isLyricsPopoverShown
    }

    private struct FullScreenAuxiliaryVisibilitySnapshot {
        let floatingWasVisible: Bool
        let capsuleWasVisible: Bool
    }

    private var floatingController: FloatingLyricsWindowController?
    private var capsuleController: CapsuleLyricsWindowController?
    private var listeningLyricsWindow: NSWindow?
    private var libraryVersionsWindow: VersionsWindow?
    private var translationComparisonWindow: VersionsWindow?
    private var translationComparisonID: UUID?
    private var returnToMainAfterFullScreen = false
    private var fullScreenController: FullScreenLyricsWindowController?
    private var fullScreenAuxiliaryVisibilitySnapshot: FullScreenAuxiliaryVisibilitySnapshot?
    private var terminationObserver: NSObjectProtocol?

    private init() {
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Never resurrect auxiliary windows while the application is
            // terminating.  The snapshot is transient and never persisted.
            self?.fullScreenAuxiliaryVisibilitySnapshot = nil
            self?.fullScreenController?.onDidHide = nil
        }
    }

    deinit {
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
    }

    public func showFloatingLyrics(state: PlaybackState) {
        guard fullScreenController?.isVisible != true else { return }
        if floatingController == nil {
            floatingController = FloatingLyricsWindowController()
        }
        floatingController?.show(state: state, settings: AppSettingsStore.shared)
    }

    public func hideFloatingLyrics() {
        floatingController?.hide()
    }

    func showListeningLyrics(_ lyrics: ListeningLyricsSnapshot) {
        let window: NSWindow
        if let listeningLyricsWindow {
            window = listeningLyricsWindow
        } else {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 520),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "完整歌词"
            window.identifier = .init("listening-lyrics-reader")
            window.minSize = NSSize(width: 360, height: 360)
            window.isReleasedWhenClosed = false
            window.center()
            listeningLyricsWindow = window
        }
        window.contentView = NSHostingView(rootView: ListeningLyricsReader(
            lyrics: lyrics, closeTitle: "关闭阅读", closeSymbol: "xmark",
            openArchive: { MenuBarLyricsController.shared.openSettings(at: .init(reading: $0)) },
            close: { [weak window] in window?.close() }
        ))
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showLibraryVersions(_ request: PersonalLyricsLibraryService.VersionSearch,
                             library: PersonalLyricsLibraryService, playback: PlaybackState) {
        let window = libraryVersionsWindow ?? VersionsWindow(title: "歌词版本", identifier: "lyric-versions")
        libraryVersionsWindow = window
        window.show(LibraryVersionsWorkspace(
            request: request, library: library, playback: playback, close: { [weak window] in window?.close() }
        ))
    }

    func showTranslationComparison(_ request: LibraryCompareRequest, library: PersonalLyricsLibraryService,
                                   adopt: @escaping (UUID) -> Void, edit: @escaping (LibraryTranslationRevisionDraft) -> Void) {
        translationComparisonWindow?.close()
        let window = translationComparisonWindow ?? VersionsWindow(title: "对比译文", identifier: "translation-compare")
        translationComparisonWindow = window
        translationComparisonID = request.id
        window.didClose = { [weak library] in
            if library?.comparison?.id == request.id { library?.comparison = nil }
        }
        window.show(LibraryVersionCompareView(request: request, library: library, adopt: adopt,
            close: { [weak window] in window?.close() }, edit: edit))
    }

    func closeTranslationComparison(id: UUID) {
        guard translationComparisonID == id else { return }
        translationComparisonID = nil
        translationComparisonWindow?.close()
    }

    private final class VersionsWindow: NSWindow {
        var didClose: (() -> Void)?

        init(title: String, identifier: String) {
            let available = (NSApp.keyWindow?.screen ?? NSScreen.main)?.visibleFrame.size ?? NSSize(width: 1200, height: 800)
            let size = NSSize(width: min(1120, available.width * 0.92), height: min(720, available.height * 0.87))
            super.init(contentRect: NSRect(origin: .zero, size: size),
                       styleMask: [.titled, .closable, .miniaturizable, .resizable],
                       backing: .buffered, defer: false)
            self.title = title
            self.identifier = .init(identifier)
            contentMinSize = NSSize(width: 680, height: 420)
            collectionBehavior.insert(.fullScreenPrimary)
            isReleasedWhenClosed = false
            center()
        }

        func show<Content: View>(_ view: Content) {
            contentView = NSHostingView(rootView: view)
            if isMiniaturized { deminiaturize(nil) }
            makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }

        override func close() {
            super.close()
            contentView = nil
            let action = didClose
            didClose = nil
            action?()
        }
    }

    func dockFloatingLyrics(_ place: FloatingLyricsDock, state: PlaybackState) {
        guard !fullScreenWindowIsVisible else { return }
        if !floatingWindowIsVisible { showFloatingLyrics(state: state) }
        floatingController?.dock(place)
    }

    func moveFloatingLyrics(to displayID: String, state: PlaybackState) {
        guard !fullScreenWindowIsVisible, let screen = NSScreen.lyricsScreen(for: displayID) else { return }
        if !floatingWindowIsVisible { showFloatingLyrics(state: state) }
        floatingController?.move(to: screen)
    }

    public func toggleFloatingLyrics(state: PlaybackState) {
        guard fullScreenController?.isVisible != true else { return }
        if floatingController == nil {
            floatingController = FloatingLyricsWindowController()
        }
        floatingController?.toggle(state: state, settings: AppSettingsStore.shared)
    }

    /// Compatibility entry point for callers outside the current production
    /// surface. New production call sites use `toggleFloatingLyrics`.
    public func toggleFloatingWindow(state: PlaybackState) {
        toggleFloatingLyrics(state: state)
    }

    public func restoreFloatingWindowIfConfigured(state: PlaybackState) {
        guard fullScreenController?.isVisible != true else { return }
        if floatingController == nil {
            floatingController = FloatingLyricsWindowController()
        }
        floatingController?.restoreIfConfigured(state: state, settings: AppSettingsStore.shared)
    }

    public var floatingWindowIsVisible: Bool {
        floatingController?.isVisible == true
    }

    public var floatingInteractionMode: FloatingLyricsInteractionMode {
        floatingController?.interactionMode ?? AppSettingsStore.shared.floatingWindowInteractionMode
    }

    public func setFloatingInteractionMode(_ mode: FloatingLyricsInteractionMode, state: PlaybackState) {
        let settings = AppSettingsStore.shared
        settings.floatingWindowInteractionMode = mode
        if floatingController == nil {
            floatingController = FloatingLyricsWindowController()
        }
        floatingController?.setInteractionMode(mode)
        state.showFloatingWindow = floatingController?.isVisible == true
    }

    public func restoreFloatingInteractiveMode(state: PlaybackState) {
        setFloatingInteractionMode(.interactive, state: state)
    }

    public func showCapsule(state: PlaybackState) {
        guard fullScreenController?.isVisible != true else { return }
        if capsuleController == nil {
            capsuleController = CapsuleLyricsWindowController()
        }
        capsuleController?.show(state: state, settings: AppSettingsStore.shared)
    }

    public func hideCapsule() {
        capsuleController?.hide()
    }

    public func toggleCapsule(state: PlaybackState) {
        guard fullScreenController?.isVisible != true else { return }
        if capsuleController == nil {
            capsuleController = CapsuleLyricsWindowController()
        }
        capsuleController?.toggle(state: state, settings: AppSettingsStore.shared)
    }

    /// Compatibility entry point for callers outside the current production
    /// surface. New production call sites use `toggleCapsule`.
    public func toggleCapsulePlayer(state: PlaybackState) {
        toggleCapsule(state: state)
    }

    public func restoreCapsuleWindowIfConfigured(state: PlaybackState) {
        guard fullScreenController?.isVisible != true else { return }
        if capsuleController == nil {
            capsuleController = CapsuleLyricsWindowController()
        }
        capsuleController?.restoreIfConfigured(state: state, settings: AppSettingsStore.shared)
    }

    public func collapseCapsulePlayer() {
        capsuleController?.collapse()
    }

    public func expandCapsulePlayer() {
        capsuleController?.expand()
    }

#if DEBUG
    /// Design-review-only anchor comparison. The controller remains the
    /// single owner of the panel and its normal persisted frame.
    func setCapsuleDebugAnchor(_ anchor: CapsuleDebugAnchor) {
        if capsuleController == nil {
            capsuleController = CapsuleLyricsWindowController()
        }
        capsuleController?.setDebugAnchor(anchor)
    }

    /// Debug-only presentation injection for v4 geometry verification. It
    /// reuses the existing capsule controller and never persists a version.
    func setCapsuleDebugPresentation(
        _ presentation: CapsuleLyricsPresentationVersion?,
        state: PlaybackState
    ) {
        if capsuleController == nil {
            capsuleController = CapsuleLyricsWindowController()
        }
        capsuleController?.setDebugPresentation(presentation)
        if presentation != nil, capsuleController?.isVisible != true {
            capsuleController?.show(state: state, settings: AppSettingsStore.shared)
        }
    }
#endif

    public var capsuleWindowIsVisible: Bool {
        capsuleController?.isVisible == true
    }

    var fullScreenWindow: NSWindow? { fullScreenController?.window }

    public var fullScreenWindowIsVisible: Bool {
        fullScreenController?.isVisible == true
    }

    public func toggleFullScreen(state: PlaybackState, settings: AppSettingsStore? = nil) {
        if fullScreenController?.isVisible == true {
            hideFullScreen()
        } else {
            showFullScreen(state: state, settings: settings)
        }
    }

    public func showFullScreen(state: PlaybackState, settings: AppSettingsStore? = nil) {
        guard fullScreenController?.isVisible != true else { return }
        captureAndHideAuxiliaryWindows()

        let controller = makeFullScreenController()
        guard controller.show(state: state, settings: settings) else {
            restoreFloatingSurfacesAfterFullscreen()
            return
        }
    }

    public func hideFullScreen() {
        guard let controller = fullScreenController else {
            restoreFloatingSurfacesAfterFullscreen()
            return
        }
        controller.hide()
        // `hide()` normally invokes the callback.  This fallback also covers
        // a controller that had no visible panel but still held a snapshot.
        if !controller.isVisible {
            restoreFloatingSurfacesAfterFullscreen()
        }
    }

    private func makeFullScreenController() -> FullScreenLyricsWindowController {
        if let fullScreenController { return fullScreenController }
        let controller = FullScreenLyricsWindowController()
        controller.onDidHide = { [weak self] in
            self?.finishFullScreenHide()
        }
        fullScreenController = controller
        return controller
    }

    private func captureAndHideAuxiliaryWindows() {
        guard fullScreenAuxiliaryVisibilitySnapshot == nil else { return }
        let snapshot = FullScreenAuxiliaryVisibilitySnapshot(
            floatingWasVisible: floatingController?.isVisible == true,
            capsuleWasVisible: capsuleController?.isVisible == true
        )
        fullScreenAuxiliaryVisibilitySnapshot = snapshot
        floatingController?.temporarilyHideForFullScreen()
        capsuleController?.temporarilyHideForFullScreen()
    }

    public func exitFullScreenToMainWindow() {
        returnToMainAfterFullScreen = true
        hideFullScreen()
        if fullScreenController?.isVisible != true { finishFullScreenHide() }
    }

    private func finishFullScreenHide() {
        restoreFloatingSurfacesAfterFullscreen()
        if returnToMainAfterFullScreen {
            returnToMainAfterFullScreen = false
            NSApp.activate(ignoringOtherApps: true)
            MenuBarLyricsController.shared.openMainWindow()
            WindowStatePersistence.shared.attachedMainWindow?.makeKeyAndOrderFront(nil)
        }
    }

    public func restoreFloatingSurfacesAfterFullscreen() {
        guard let snapshot = fullScreenAuxiliaryVisibilitySnapshot else { return }
        fullScreenAuxiliaryVisibilitySnapshot = nil

        if snapshot.floatingWasVisible {
            floatingController?.restoreAfterFullScreen()
        }
        if snapshot.capsuleWasVisible {
            capsuleController?.restoreAfterFullScreen()
        }
    }
}
