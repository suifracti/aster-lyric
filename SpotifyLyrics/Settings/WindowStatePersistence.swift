import AppKit
import Combine
import Foundation
import SwiftUI

/// Keeps window frame and level persistence outside the SwiftUI view tree.
/// Notification observers are attached once per NSWindow and do not replace
/// SwiftUI's own window delegate.
public final class WindowStatePersistence {
    public static let shared = WindowStatePersistence()

    private let lock = NSLock()
    private var observedWindows = Set<ObjectIdentifier>()
    private var observations: [ObjectIdentifier: [NSObjectProtocol]] = [:]
    private var settingsCancellables: [ObjectIdentifier: AnyCancellable] = [:]
    private weak var mainWindow: NSWindow?
    private var mainSettings: AppSettingsStore?

    /// The main window is the anchor used by auxiliary windows that follow
    /// the user's current display.  It remains weak and is populated only
    /// after the real SwiftUI window has been attached.
    public var attachedMainWindow: NSWindow? { mainWindow }

    private init() {}

    public func attach(window: NSWindow, settings: AppSettingsStore) {
        let identifier = ObjectIdentifier(window)
        lock.lock()
        let alreadyAttached = observedWindows.contains(identifier)
        if !alreadyAttached {
            observedWindows.insert(identifier)
        }
        lock.unlock()

        mainWindow = window
        mainSettings = settings
        if !alreadyAttached {
            if !window.styleMask.contains(.fullSizeContentView) {
                window.styleMask.insert(.fullSizeContentView)
            }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            restoreFrameIfNeeded(window: window, settings: settings)
            applyWindowLevel(window: window, keepOnTop: settings.keepMainWindowOnTop)
            let center = NotificationCenter.default
            let moved = center.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main) { [weak self, weak window] _ in
                guard let self, let window else { return }
                self.saveFrame(window: window, settings: settings)
            }
            let resized = center.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self, weak window] _ in
                guard let self, let window else { return }
                self.saveFrame(window: window, settings: settings)
            }
            let closed = center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self, weak window] _ in
                guard let self, let window else { return }
                self.saveFrame(window: window, settings: settings)
            }
            lock.lock()
            observations[identifier] = [moved, resized, closed]
            lock.unlock()

            let cancellable = settings.$keepMainWindowOnTop.sink { [weak self, weak window] value in
                guard let self, let window else { return }
                self.applyWindowLevel(window: window, keepOnTop: value)
            }
            lock.lock()
            settingsCancellables[identifier] = cancellable
            lock.unlock()
        }
    }

    public func resetWindowFrame() {
        guard let window = mainWindow else { return }
        window.center()
    }

    private func restoreFrameIfNeeded(window: NSWindow, settings: AppSettingsStore) {
        #if DEBUG
        if ProcessInfo.processInfo.environment["SPOTIFYLYRICS_WINDOW_SIZE"] != nil {
            return
        }
        #endif
        guard settings.restoreWindowState,
              let value = settings.savedWindowFrame else { return }
        let frame = NSRectFromString(value)
        guard frame.width >= 400, frame.height >= 300 else { return }
        window.setFrame(frame, display: false)
    }

    private func saveFrame(window: NSWindow, settings: AppSettingsStore) {
        guard settings.restoreWindowState else { return }
        UserDefaults.lyricsQ.set(NSStringFromRect(window.frame), forKey: AppSettingsStore.Key.mainWindowFrame)
    }

    private func applyWindowLevel(window: NSWindow, keepOnTop: Bool) {
        window.level = keepOnTop ? .floating : .normal
    }
}

struct WindowStateAccessor: NSViewRepresentable {
    let settings: AppSettingsStore

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            #if DEBUG
            if let envSize = ProcessInfo.processInfo.environment["SPOTIFYLYRICS_WINDOW_SIZE"] {
                let parts = envSize.split(separator: "x")
                if parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]) {
                    window.setFrame(NSRect(x: window.frame.origin.x, y: window.frame.origin.y, width: CGFloat(w), height: CGFloat(h)), display: true)
                }
            }
            #endif
            WindowStatePersistence.shared.attach(window: window, settings: settings)
        }
    }
}

/// Keeps the native Settings window out of the Stage Manager primary-window
/// group. SwiftUI's `Settings` scene otherwise becomes the app's active stage
/// on some macOS configurations, which sends the main window to the Stage
/// Manager strip when Settings is opened.
struct SettingsWindowBehavior: NSViewRepresentable {
    func makeNSView(context: Context) -> SettingsWindowProbeView {
        SettingsWindowProbeView()
    }

    func updateNSView(_ nsView: SettingsWindowProbeView, context: Context) {
        nsView.configureWindow()
    }
}

final class SettingsWindowProbeView: NSView {
    private let visualEffectView = NSVisualEffectView()

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureWindow()
    }

    func configureWindow() {
        guard let window, let contentView = window.contentView else { return }
        window.collectionBehavior = [.canJoinAllApplications, .moveToActiveSpace]
        window.hidesOnDeactivate = false

        visualEffectView.material = .sidebar
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.state = .active
        visualEffectView.translatesAutoresizingMaskIntoConstraints = false
        if visualEffectView.superview == nil {
            contentView.addSubview(visualEffectView, positioned: .below, relativeTo: nil)
            NSLayoutConstraint.activate([
                visualEffectView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                visualEffectView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                visualEffectView.topAnchor.constraint(equalTo: contentView.topAnchor),
                visualEffectView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
            ])
        }
    }
}
