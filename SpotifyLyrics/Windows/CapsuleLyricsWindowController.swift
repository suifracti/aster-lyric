import AppKit
import Combine
import SwiftUI

private final class CapsuleLyricsPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Fixed-envelope host for the top-attached island. The
/// AppKit window remains transparent outside the internal island; returning
/// nil here keeps the host from producing an interactive hit target in that
/// region. A second global mouse monitor below toggles `ignoresMouseEvents`
/// so the event is delivered to the application underneath as well.
private final class CapsuleEnvelopeHostingView: NSView {
    private let hostedView: NSView
    var interactivePointProvider: ((NSPoint) -> Bool)?

    init(hostedView: NSView) {
        self.hostedView = hostedView
        super.init(frame: .zero)
        addSubview(hostedView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        hostedView.frame = bounds
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard interactivePointProvider?(point) == true else {
            return nil
        }
        return super.hitTest(point)
    }
}

/// Owns the single top capsule panel.  It is a window lifecycle owner only:
/// playback, lyrics, translation and the current row remain in PlaybackState
/// and its shared session controllers.
@MainActor
final class CapsuleLyricsWindowController: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var isVisible = false
    @Published private(set) var presentationState: CapsulePresentationState = .collapsed

    private let persistence = CapsuleLyricsWindowPersistence.shared
    private var panel: CapsuleLyricsPanel?
    private weak var playbackState: PlaybackState?
    private var settings: AppSettingsStore?
    private var selectionObserver: AnyCancellable?
    private var outsideClickMonitor: Any?
    private var localClickMonitor: Any?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var envelopeHostingView: CapsuleEnvelopeHostingView?
    private var screenChangeObserver: NSObjectProtocol?
    private var hoverCollapseTask: Task<Void, Never>?
    private var hoverExpandTask: Task<Void, Never>?
    private var hitRegionTask: Task<Void, Never>?
    private var settledHitState: CapsulePresentationState = .collapsed
    private var pointerIsInside = false
    private var expansionInteraction = CapsuleExpansionInteraction()
    private var isSeeking = false
    @Published private(set) var menuIsPresented = false
    @Published private(set) var notchGeometry = CapsuleNotchGeometry(screenFrame: .zero, safeTopInset: 0)
    private var didRestore = false
    private var isApplyingFrame = false
#if DEBUG
    private var debugAnchor: CapsuleDebugAnchor = .topCenter
    private(set) var debugTopAttachedEnvelope = ProcessInfo.processInfo.arguments.contains(
        "--debug-capsule-v4-top-attached"
    )
    @Published private(set) var debugPresentation: CapsuleLyricsPresentationVersion? =
        ProcessInfo.processInfo.arguments.contains("--debug-capsule-v4")
            || ProcessInfo.processInfo.arguments.contains("--debug-capsule-v4-top-attached")
        ? .dynamicIslandDarkV4
        : nil
#endif

    override init() {
        super.init()
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.repositionForCurrentScreen()
            }
        }
    }

    deinit {
        hitRegionTask?.cancel()
        hoverCollapseTask?.cancel()
        hoverExpandTask?.cancel()
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
        }
        if let localClickMonitor {
            NSEvent.removeMonitor(localClickMonitor)
        }
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
        }
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
        }
        if let screenChangeObserver {
            NotificationCenter.default.removeObserver(screenChangeObserver)
        }
    }

    func toggle(state: PlaybackState, settings: AppSettingsStore) {
        configure(state: state, settings: settings)
        isVisible ? hide() : show()
    }

    func restoreIfConfigured(state: PlaybackState, settings: AppSettingsStore) {
        configure(state: state, settings: settings)
        guard !didRestore else { return }
        didRestore = true
        guard settings.restoreWindowState, settings.capsuleWindowWasVisible else { return }
        show()
    }

    func show(state: PlaybackState, settings: AppSettingsStore) {
        configure(state: state, settings: settings)
        show()
    }

    func hide() {
        expansionInteraction.reset()
        menuIsPresented = false
        hitRegionTask?.cancel()
        hoverCollapseTask?.cancel()
        hoverExpandTask?.cancel()
        removeOutsideClickMonitors()
        removeMouseMonitors()
        savePosition()
        panel?.ignoresMouseEvents = false
        panel?.orderOut(nil)
        panel?.contentView = nil
        envelopeHostingView = nil
        isVisible = false
        presentationState = .collapsed
        settings?.capsuleWindowWasVisible = false
        playbackState?.showCapsulePlayer = false
    }

    /// Temporary fullscreen orchestration keeps the user's persisted
    /// visibility and frame untouched.  It is deliberately separate from
    /// `hide()`, which is the user's explicit hide action.
    func temporarilyHideForFullScreen() {
        guard isVisible else { return }
        menuIsPresented = false
        hitRegionTask?.cancel()
        cancelHoverCollapse()
        removeOutsideClickMonitors()
        removeMouseMonitors()
        panel?.ignoresMouseEvents = false
        panel?.orderOut(nil)
        panel?.contentView = nil
        envelopeHostingView = nil
        isVisible = false
        playbackState?.showCapsulePlayer = false
    }

    func restoreAfterFullScreen() {
        guard let panel, !isVisible else { return }
        if panel.contentView == nil, let state = playbackState { installContent(on: panel, state: state) }
        settledHitState = presentationState
        if let settings { applyFrame(for: presentationState, settings: settings) }
        panel.isMovable = !isTopAttachedEnvelope && presentationState == .expanded
        panel.isMovableByWindowBackground = panel.isMovable
        panel.level = effectivePanelLevel
        panel.orderFrontRegardless()
        isVisible = true
        pointerIsInside = false
        if isTopAttachedEnvelope { installMouseMonitors(); updateMousePassThrough() }
        if presentationState == .expanded { installOutsideClickMonitors() }
        playbackState?.showCapsulePlayer = true
    }

    func expand() { expand(explicit: true) }

    private func expand(explicit: Bool) {
        guard isVisible else { return }
        cancelHoverCollapse()
        let physicallyInside: Bool
        if let panel, isTopAttachedEnvelope {
            physicallyInside = notchGeometry.contains(panel.convertPoint(fromScreen: NSEvent.mouseLocation),
                state: presentationState, envelopeSize: envelopeSize)
        } else { physicallyInside = pointerIsInside }
        expansionInteraction.expanded(explicit: explicit, pointerInside: physicallyInside)
        setPresentationState(.expanded)
        installOutsideClickMonitors()
    }

    func collapse() {
        guard isVisible else { return }
        menuIsPresented = false
        expansionInteraction.reset()
        cancelHoverCollapse()
        removeOutsideClickMonitors()
        setPresentationState(.collapsed)
    }

    func toggleExpanded() { presentationState == .expanded ? collapse() : expand() }

#if DEBUG
    func setDebugAnchor(_ anchor: CapsuleDebugAnchor) {
        debugAnchor = anchor
        if isVisible, let settings { applyFrame(for: presentationState, settings: settings) }
    }
    func setDebugPresentation(_ presentation: CapsuleLyricsPresentationVersion?) {
        debugPresentation = presentation
        if isVisible, let settings { applyFrame(for: presentationState, settings: settings) }
    }
#endif

    var activePresentation: CapsuleLyricsPresentationVersion {
#if DEBUG
        if let debugPresentation { return debugPresentation }
#endif
        let raw = settings?.presentationSelections.currentStableID(for: .capsule)
        return raw.flatMap(CapsuleLyricsPresentationVersion.init(rawValue:)) ?? .current
    }

    var isTopAttachedEnvelope: Bool { activePresentation == .dynamicIslandDarkV4 }
    private var effectivePanelLevel: NSWindow.Level { isTopAttachedEnvelope ? .statusBar : .floating }
    var envelopeSize: CGSize { panel?.contentView?.bounds.size ?? CapsuleDynamicIslandDarkV4.debugEnvelopeSize }
    var islandSize: CGSize { notchGeometry.islandFrame(for: presentationState, envelopeSize: envelopeSize).size }

    func setMenuPresented(_ presented: Bool) {
        guard menuIsPresented != presented else { return }
        menuIsPresented = presented
        if presented {
            cancelHoverCollapse()
        } else if !pointerIsInside {
            pointerExited()
        }
    }

    func setSeeking(_ seeking: Bool) {
        isSeeking = seeking
        if seeking { cancelHoverCollapse() }
        else if !pointerIsInside { pointerExited() }
    }

    func pointerEntered() { handlePointerEntry(releasesExplicitExpansion: true) }

    private func handlePointerEntry(releasesExplicitExpansion: Bool) {
        guard isVisible else { return }
        if releasesExplicitExpansion { expansionInteraction.pointerEntered() }
        pointerIsInside = true
        cancelHoverCollapse()
        guard presentationState != .expanded else { return }
        setPresentationState(.hover)
        hoverExpandTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 140_000_000)
            guard !Task.isCancelled, let self, self.pointerIsInside else { return }
            self.expand(explicit: false)
        }
    }

    func pointerExited() {
        pointerIsInside = false
        hoverExpandTask?.cancel()
        guard presentationState != .collapsed, expansionInteraction.permitsHoverCollapse(menuPresented: menuIsPresented),
              !isSeeking, hoverCollapseTask == nil else { return }
        hoverCollapseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard !Task.isCancelled, let self, !self.pointerIsInside,
                  self.expansionInteraction.permitsHoverCollapse(menuPresented: self.menuIsPresented) else { return }
            self.collapse()
        }
    }

    private func configure(state: PlaybackState, settings: AppSettingsStore) {
        playbackState = state
        self.settings = settings
        if selectionObserver == nil {
            selectionObserver = settings.presentationSelections.$persistedSelections
                .dropFirst().sink { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self, let settings = self.settings else { return }
                        self.cancelHoverCollapse()
                        self.presentationState = .collapsed
                        self.expansionInteraction.reset()
                        self.menuIsPresented = false
                        self.hitRegionTask?.cancel()
                        self.settledHitState = .collapsed
                        self.objectWillChange.send()
                        self.applyFrame(for: .collapsed, settings: settings)
                        self.panel?.level = self.effectivePanelLevel
                        self.panel?.hasShadow = !self.isTopAttachedEnvelope
                        self.panel?.isMovable = false
                        self.panel?.isMovableByWindowBackground = false
                        self.removeOutsideClickMonitors()
                        self.pointerIsInside = false
                        if self.isTopAttachedEnvelope, self.isVisible {
                            self.installMouseMonitors()
                            self.updateMousePassThrough()
                        } else {
                            self.removeMouseMonitors()
                            self.panel?.ignoresMouseEvents = false
                        }
                    }
                }
        }
    }

    private func makePanel(state: PlaybackState) -> CapsuleLyricsPanel {
        let frame = isTopAttachedEnvelope ? topAttachedEnvelopeFrame() : restoredFrame(
            for: .collapsed, settings: settings ?? AppSettingsStore.shared)
        let panel = CapsuleLyricsPanel(contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = !isTopAttachedEnvelope
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = effectivePanelLevel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications]
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        installContent(on: panel, state: state)
        return panel
    }

    private func installContent(on panel: NSPanel, state: PlaybackState) {
        let hostedView = NSHostingView(rootView: CapsuleLyricsView(state: state, windowController: self))
        let envelopeView = CapsuleEnvelopeHostingView(hostedView: hostedView)
        envelopeView.interactivePointProvider = { [weak self] point in
            guard let self else { return false }
            return !self.isTopAttachedEnvelope || self.acceptsClick(at: point)
        }
        envelopeHostingView = envelopeView
        panel.contentView = envelopeView
    }

    private func show() {
        guard let settings, let state = playbackState else { return }
        if panel == nil { panel = makePanel(state: state) }
        guard let panel else { return }
        if panel.contentView == nil, let state = playbackState { installContent(on: panel, state: state) }
        cancelHoverCollapse()
        removeOutsideClickMonitors()
        pointerIsInside = false
        expansionInteraction.reset()
        settledHitState = .collapsed
        hitRegionTask?.cancel()
        presentationState = .collapsed
        applyFrame(for: .collapsed, settings: settings)
        panel.level = effectivePanelLevel
        // A nonactivating panel may be ordered behind the main SwiftUI window
        // when it is created from a menu command.  Ordering it regardless
        // does not make it key or activate another application.
        panel.orderFrontRegardless()
        isVisible = true
        if isTopAttachedEnvelope {
            installMouseMonitors()
            updateMousePassThrough()
        }
        settings.capsuleWindowWasVisible = true
        playbackState?.showCapsulePlayer = true
    }

    private func setPresentationState(_ newState: CapsulePresentationState) {
        guard newState != presentationState else { return }
        hitRegionTask?.cancel()
        if notchGeometry.size(for: newState).height <= notchGeometry.size(for: settledHitState).height {
            settledHitState = newState
        }
        presentationState = newState
        if isTopAttachedEnvelope {
            hitRegionTask = Task { @MainActor [weak self] in
                let delay: UInt64 = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 140_000_000 : 400_000_000
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled, let self else { return }
                self.settledHitState = newState
                self.updateMousePassThrough()
            }
        } else { settledHitState = newState }
        if let settings {
            applyFrame(for: newState, settings: settings)
        }
        panel?.isMovable = isTopAttachedEnvelope ? false : newState == .expanded
        panel?.isMovableByWindowBackground = isTopAttachedEnvelope ? false : newState == .expanded
        if isTopAttachedEnvelope {
            updateMousePassThrough()
        }
    }

    private func applyFrame(for state: CapsulePresentationState, settings: AppSettingsStore) {
        guard let panel else { return }
        if isTopAttachedEnvelope {
            let frame = topAttachedEnvelopeFrame()
            guard !panel.frame.equalTo(frame) else { return }
            isApplyingFrame = true
            panel.setFrame(frame, display: true, animate: false)
            isApplyingFrame = false
            return
        }
        let frame = restoredFrame(for: state, settings: settings)
        isApplyingFrame = true
        panel.setFrame(frame, display: true, animate: isVisible)
        isApplyingFrame = false
    }

    private func topAttachedEnvelopeFrame() -> NSRect {
        let screen = persistence.targetScreen(
            mainWindow: WindowStatePersistence.shared.attachedMainWindow
        ) ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else {
            return NSRect(origin: .zero, size: CapsuleDynamicIslandDarkV4.debugEnvelopeSize)
        }
        notchGeometry = CapsuleNotchGeometry(screenFrame: screen.frame,
            safeTopInset: screen.safeAreaInsets.top,
            auxiliaryLeft: screen.auxiliaryTopLeftArea, auxiliaryRight: screen.auxiliaryTopRightArea)
        return CapsuleDynamicIslandDarkV4.topAttachedEnvelopeFrame(
            screenFrame: screen.frame
        )
    }

    private func debugIslandFrameInEnvelope() -> NSRect {
        let contentSize = panel?.contentView?.bounds.size ?? .zero
        let envelopeSize = contentSize.width > 0 && contentSize.height > 0
            ? contentSize
            : CapsuleDynamicIslandDarkV4.debugEnvelopeSize
        return notchGeometry.islandFrame(
            for: presentationState,
            envelopeSize: envelopeSize
        )
    }

    private func debugIslandFrameInScreen() -> NSRect {
        guard let panel else { return .zero }
        let localFrame = debugIslandFrameInEnvelope()
        return panel.convertToScreen(localFrame)
    }

    private func installMouseMonitors() {
        guard isTopAttachedEnvelope else { return }
        if globalMouseMonitor == nil {
            globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.mouseMoved, .leftMouseDragged]
            ) { [weak self] _ in
                self?.updateMousePassThrough(pointerMoved: true)
            }
        }
        if localMouseMonitor == nil {
            localMouseMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.mouseMoved, .leftMouseDragged]
            ) { [weak self] event in
                self?.updateMousePassThrough(pointerMoved: true)
                return event
            }
        }
    }

    private func removeMouseMonitors() {
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }
    }

    private func acceptsClick(at point: CGPoint) -> Bool {
        notchGeometry.contains(point, state: presentationState,
            restrictingTo: settledHitState, envelopeSize: envelopeSize)
    }

    private func updateMousePassThrough(pointerMoved: Bool = false) {
        guard isTopAttachedEnvelope, let panel, isVisible else { return }
        let local = panel.convertPoint(fromScreen: NSEvent.mouseLocation)
        let inside = notchGeometry.contains(local, state: presentationState, envelopeSize: envelopeSize)
        if inside, pointerMoved { expansionInteraction.pointerEntered() }
        if inside != pointerIsInside {
            if inside { handlePointerEntry(releasesExplicitExpansion: pointerMoved) }
            else { pointerExited() }
        }
        panel.ignoresMouseEvents = !acceptsClick(at: local) && !isSeeking
    }

    private func restoredFrame(
        for state: CapsulePresentationState,
        settings: AppSettingsStore
    ) -> NSRect {
#if DEBUG
        return persistence.restoreFrame(
            for: state,
            settings: settings,
            mainWindow: WindowStatePersistence.shared.attachedMainWindow,
            debugAnchor: debugAnchor,
            presentation: activePresentation
        )
#else
        return persistence.restoreFrame(
            for: state,
            settings: settings,
            mainWindow: WindowStatePersistence.shared.attachedMainWindow,
            presentation: activePresentation
        )
#endif
    }

    private func savePosition() {
        guard !isTopAttachedEnvelope else { return }
        guard let panel, let settings else { return }
#if DEBUG
        guard !isTopAttachedEnvelope else { return }
        // Do not turn a comparison anchor's derived frame into the user's
        // normal centered horizontal offset.
        guard debugAnchor == .topCenter else { return }
#endif
        let screen = panel.screen
            ?? persistence.targetScreen(mainWindow: WindowStatePersistence.shared.attachedMainWindow)
        guard let screen else { return }
        let safe = persistence.clampTopFrame(panel.frame, screen: screen)
        if safe != panel.frame {
            isApplyingFrame = true
            panel.setFrame(safe, display: false)
            isApplyingFrame = false
        }
        settings.capsuleWindowHorizontalOffset = Double(
            persistence.horizontalOffset(for: safe, screen: screen)
        )
        settings.capsuleWindowScreenID = persistence.screenIdentifier(screen)
    }

    private func repositionForCurrentScreen() {
        guard isVisible, let settings else { return }
        applyFrame(for: presentationState, settings: settings)
        if isTopAttachedEnvelope {
            updateMousePassThrough()
            return
        }
        savePosition()
    }

    private func installOutsideClickMonitors() {
        guard outsideClickMonitor == nil, localClickMonitor == nil else { return }
        let handler: (NSEvent) -> NSEvent? = { [weak self] event in
            guard let self, self.presentationState == .expanded, !self.menuIsPresented else { return event }
            if event.window !== self.panel {
                self.collapse()
            }
            return event
        }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown],
            handler: { [weak self] event in
                guard let self, self.presentationState == .expanded, !self.menuIsPresented else { return }
                if event.window !== self.panel { self.collapse() }
            }
        )
        localClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown],
            handler: handler
        )
    }

    private func removeOutsideClickMonitors() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
        if let localClickMonitor {
            NSEvent.removeMonitor(localClickMonitor)
            self.localClickMonitor = nil
        }
    }

    private func cancelHoverCollapse() {
        hoverCollapseTask?.cancel()
        hoverExpandTask?.cancel()
        hoverCollapseTask = nil
    }

    func windowDidMove(_ notification: Notification) {
        guard !isApplyingFrame, presentationState == .expanded else { return }
        savePosition()
        // The capsule is a top window, not a freely movable desktop panel.
        if let settings { applyFrame(for: presentationState, settings: settings) }
    }

    func windowWillClose(_ notification: Notification) {
        hide()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }
}
