import AppKit
import Combine
import SwiftUI

private final class FloatingLyricsPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class FloatingLyricsStylePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns exactly one retained floating panel. Hiding orders it out instead of
/// closing or releasing the panel, so repeated toggles cannot create a second
/// window or a second SwiftUI state tree.
@MainActor
final class FloatingLyricsWindowController: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var isVisible = false
    @Published private(set) var interactionMode: FloatingLyricsInteractionMode = .interactive
    @Published private(set) var isStylePanelVisible = false

    private let persistence = FloatingLyricsWindowPersistence.shared
    private var panel: FloatingLyricsPanel?
    private var stylePanel: FloatingLyricsStylePanel?
    private weak var playbackState: PlaybackState?
    private var settings: AppSettingsStore?
    private var settingsCancellables: Set<AnyCancellable> = []
    private var screenChangeObserver: NSObjectProtocol?
    private var didRestore = false

    override init() {
        super.init()
        observeScreenChanges()
    }

    deinit {
        if let screenChangeObserver {
            NotificationCenter.default.removeObserver(screenChangeObserver)
        }
        settingsCancellables.forEach { $0.cancel() }
    }

    func toggle(state: PlaybackState, settings: AppSettingsStore) {
        configure(state: state, settings: settings)
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    func show(state: PlaybackState, settings: AppSettingsStore) {
        configure(state: state, settings: settings)
        show()
    }

    func restoreIfConfigured(state: PlaybackState, settings: AppSettingsStore) {
        configure(state: state, settings: settings)
        guard !didRestore else { return }
        didRestore = true
        guard settings.restoreWindowState, settings.floatingWindowWasVisible else { return }
        show()
    }

    func setInteractionMode(_ mode: FloatingLyricsInteractionMode) {
        interactionMode = mode
        settings?.floatingWindowInteractionMode = mode
        applyInteractionMode()
    }

    func toggleInteractionMode() {
        switch interactionMode {
        case .interactive: setInteractionMode(.locked)
        case .locked, .passThrough: setInteractionMode(.interactive)
        }
    }

    /// A dedicated native drag area avoids competition with the lyric
    /// ribbon's horizontal reading gesture and the toolbar buttons.
    func beginDragging(with event: NSEvent) {
        guard interactionMode == .interactive,
              let panel, panel.isMovable, !panel.ignoresMouseEvents,
              event.window === panel, event.type == .leftMouseDown else { return }
        panel.performDrag(with: event)
    }

    func close() {
        hideStylePanel()
        panel?.orderOut(nil)
        isVisible = false
        settings?.floatingWindowWasVisible = false
        playbackState?.showFloatingWindow = false
    }

    /// Temporary fullscreen orchestration does not change the user's
    /// persisted visibility preference or frame.  WindowManager calls these
    /// only for the duration of the fullscreen surface.
    func temporarilyHideForFullScreen() {
        guard isVisible else { return }
        hideStylePanel()
        panel?.orderOut(nil)
        isVisible = false
        playbackState?.showFloatingWindow = false
    }

    func restoreAfterFullScreen() {
        guard let panel, !isVisible else { return }
        applyInteractionMode()
        applyWindowLevel()
        panel.orderFrontRegardless()
        isVisible = true
        playbackState?.showFloatingWindow = true
    }

    func restoreInteractiveMode() {
        setInteractionMode(.interactive)
    }

    func toggleStylePanel(settings: AppSettingsStore) {
        self.settings = settings
        if isStylePanelVisible {
            hideStylePanel()
        } else {
            showStylePanel(settings: settings)
        }
    }

    private func showStylePanel(settings: AppSettingsStore) {
        guard let panel else { return }
        let stylePanel = self.stylePanel ?? makeStylePanel(settings: settings)
        self.stylePanel = stylePanel
        positionStylePanel(stylePanel, relativeTo: panel)
        stylePanel.orderFrontRegardless()
        isStylePanelVisible = true
    }

    private func makeStylePanel(settings: AppSettingsStore) -> FloatingLyricsStylePanel {
        let stylePanel = FloatingLyricsStylePanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 660),
            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        stylePanel.title = "桌面歌词设置"
        stylePanel.delegate = self
        stylePanel.isReleasedWhenClosed = false
        stylePanel.isFloatingPanel = true
        stylePanel.hidesOnDeactivate = false
        stylePanel.hasShadow = true
        stylePanel.backgroundColor = .clear
        stylePanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        stylePanel.contentView = NSHostingView(
            rootView: FloatingLyricsStylePanelView(settings: settings)
        )
        applyWindowLevel(to: stylePanel, settings: settings)
        return stylePanel
    }

    private func hideStylePanel() {
        stylePanel?.orderOut(nil)
        isStylePanelVisible = false
    }

    private func positionStylePanel(_ stylePanel: NSPanel, relativeTo panel: NSWindow) {
        guard let visibleFrame = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame,
              let settings else { return }
        let contentHeight = min(620, max(420, visibleFrame.height - 80))
        stylePanel.setContentSize(NSSize(width: 360, height: contentHeight))
        let layout = FloatingLyricsStylePanelLayout(
            lyricsFrame: panel.frame,
            panelSize: stylePanel.frame.size,
            visibleFrame: visibleFrame
        )
        stylePanel.setFrame(layout.frame, display: false)
        applyWindowLevel(to: stylePanel, settings: settings)
    }

    private func configure(state: PlaybackState, settings: AppSettingsStore) {
        playbackState = state
        self.settings = settings

        if panel == nil {
            let panel = makePanel(state: state, settings: settings)
            self.panel = panel
            interactionMode = settings.floatingWindowInteractionMode
            applyInteractionMode()
        }

        if settingsCancellables.isEmpty {
            settings.$floatingWindowAlwaysOnTop
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.applyWindowLevel() }
                .store(in: &settingsCancellables)
            settings.$floatingWindowInteractionModeRawValue
                .receive(on: RunLoop.main)
                .sink { [weak self] rawValue in
                    guard let self,
                          let mode = FloatingLyricsInteractionMode(rawValue: rawValue),
                          mode != self.interactionMode else { return }
                    self.interactionMode = mode
                    self.applyInteractionMode()
                }
                .store(in: &settingsCancellables)
            settings.$floatingDesktopKeepsTextOpaque
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.applyOpacity() }
                .store(in: &settingsCancellables)
            settings.$floatingWindowOpacity
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.applyOpacity() }
                .store(in: &settingsCancellables)
            settings.$floatingLyricsPresentationRawValue
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.applyPresentation() }
                .store(in: &settingsCancellables)
            settings.$floatingLyricsSurfaceStyleRawValue
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.applyPresentation() }
                .store(in: &settingsCancellables)
        }
    }

    private func makePanel(state: PlaybackState, settings: AppSettingsStore) -> FloatingLyricsPanel {
        let frame = persistence.restoreFrame(settings: settings)
        let panel = FloatingLyricsPanel(
            contentRect: frame,
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = persistence.minimumSize
        panel.maxSize = persistence.maximumSize
        panel.contentView = NSHostingView(
            rootView: FloatingLyricsView(state: state, windowController: self)
                .environmentObject(settings)
        )
        applyWindowLevel(to: panel, settings: settings)
        panel.alphaValue = CGFloat(FloatingDesktopTypography.panelOpacity(value: settings.floatingWindowOpacity, transparent: settings.floatingLyricsPresentation == .transparentV2, keepsTextOpaque: settings.floatingDesktopKeepsTextOpaque))
        return panel
    }

    private func show() {
        guard let panel else { return }
        if let settings {
            panel.setFrame(persistence.restoreFrame(settings: settings), display: false)
            applyWindowLevel(to: panel, settings: settings)
            settings.floatingWindowWasVisible = true
        }
        applyInteractionMode()
        panel.orderFrontRegardless()
        isVisible = true
        playbackState?.showFloatingWindow = true
    }

    func hide() {
        guard let panel else { return }
        hideStylePanel()
        saveFrame(panel)
        panel.orderOut(nil)
        isVisible = false
        settings?.floatingWindowWasVisible = false
        playbackState?.showFloatingWindow = false
    }

    private func applyInteractionMode() {
        guard let panel else { return }
        let editable = interactionMode == .interactive
        panel.isMovable = editable
        panel.isMovableByWindowBackground = editable
        if editable {
            panel.styleMask.insert(.resizable)
        } else {
            panel.styleMask.remove(.resizable)
        }
        panel.ignoresMouseEvents = interactionMode == .passThrough
        if !editable, panel.isKeyWindow {
            panel.resignKey()
        }
    }

    private func applyWindowLevel() {
        guard let panel, let settings else { return }
        applyWindowLevel(to: panel, settings: settings)
    }

    private func applyWindowLevel(to panel: NSPanel, settings: AppSettingsStore) {
        // `.floating` stays below system alerts and menus; no statusBar or
        // modalPanel level is used for the lyric window.
        panel.level = settings.floatingWindowAlwaysOnTop ? .floating : .normal
    }

    private func applyOpacity() {
        guard let panel, let settings else { return }
        panel.alphaValue = CGFloat(FloatingDesktopTypography.panelOpacity(value: settings.floatingWindowOpacity, transparent: settings.floatingLyricsPresentation == .transparentV2, keepsTextOpaque: settings.floatingDesktopKeepsTextOpaque))
    }

    private func applyPresentation() {
        applyOpacity()
        // FloatingLyricsView observes the same settings object. The controller
        // observes these values too so an existing panel invalidates its
        // content immediately without changing any window state.
        panel?.contentView?.needsLayout = true
        panel?.contentView?.needsDisplay = true
    }

    private func saveFrame(_ panel: NSWindow) {
        guard let settings else { return }
        persistence.save(frame: panel.frame, settings: settings)
    }

    func windowDidMove(_ notification: Notification) {
        if let movedWindow = notification.object as? NSWindow, movedWindow === stylePanel {
            return
        }
        guard let panel else { return }
        saveFrame(panel)
        if isStylePanelVisible, let stylePanel {
            positionStylePanel(stylePanel, relativeTo: panel)
        }
    }

    func windowDidResize(_ notification: Notification) {
        if let resizedWindow = notification.object as? NSWindow, resizedWindow === stylePanel {
            return
        }
        guard let panel else { return }
        let safe = persistence.clamp(panel.frame, to: panel.screen?.visibleFrame ?? panel.frame)
        if safe != panel.frame {
            panel.setFrame(safe, display: false)
        }
        saveFrame(panel)
        if isStylePanelVisible, let stylePanel {
            positionStylePanel(stylePanel, relativeTo: panel)
        }
    }

    func windowShouldClose(_ window: NSWindow) -> Bool {
        if window === stylePanel {
            hideStylePanel()
            return false
        }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        if let closingWindow = notification.object as? NSWindow, closingWindow === stylePanel {
            isStylePanelVisible = false
            return
        }
        // A user/system close is treated as a hide. The retained panel can be
        // reopened without creating another controller or state tree.
        if let panel { saveFrame(panel) }
        isVisible = false
        settings?.floatingWindowWasVisible = false
        playbackState?.showFloatingWindow = false
    }

    private func observeScreenChanges() {
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                self?.clampToCurrentScreen()
            }
        }
    }

    private func clampToCurrentScreen() {
        guard let panel else { return }
        let visible = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            ?? NSScreen.screens.first?.visibleFrame
        guard let visible else { return }
        let safe = persistence.clamp(panel.frame, to: visible)
        if safe != panel.frame {
            panel.setFrame(safe, display: true)
        }
        saveFrame(panel)
        if isStylePanelVisible, let stylePanel {
            positionStylePanel(stylePanel, relativeTo: panel)
        }
    }
}
