import SwiftUI
import AppKit

@main
enum SpotifyLyricsEntryPoint {
    @MainActor
    static func main() {
#if DEBUG
        if NativeTestRuntime.isEnabled {
            NativeTestRuntime.prepare()
            let application = NSApplication.shared
            application.setActivationPolicy(.prohibited)
            application.run()
            return
        }
#endif
        SpotifyLyricsApp.main()
    }
}

struct SpotifyLyricsApp: App {
    @StateObject private var appSettings: AppSettingsStore
    @StateObject private var playbackState: PlaybackState
    @StateObject private var settingsData: SettingsDataController
    /// Shared projection adapter used by the formal Direction D V4 main
    /// window and the DEBUG acceptance host. It does not own playback or a
    /// second lyric session.
    @StateObject private var directionDMainWindowAdapter: DirectionDProductStateAdapter
    @Environment(\.openWindow) private var openWindow
#if DEBUG
    @NSApplicationDelegateAdaptor(DirectionDMainWindowDebugDelegate.self)
    private var directionDMainWindowDebugDelegate
#endif

    init() {
#if DEBUG
        // This must run before any StateObject can construct a repository.
        // A command-line v4 run without a temporary database exits here,
        // before the formal Application Support database can be opened.
        DebugAcceptanceDataIsolation.prepareBeforeStateObjectsIfNeeded()
        DebugDatabaseSafety.failClosedForCommandLineV4IfNeeded()
#endif
        let settings = AppSettingsStore.shared
        let playback = PlaybackState(settings: settings)
        _appSettings = StateObject(wrappedValue: settings)
        _playbackState = StateObject(wrappedValue: playback)
        _settingsData = StateObject(wrappedValue: SettingsDataController())
        _directionDMainWindowAdapter = StateObject(wrappedValue: DirectionDProductStateAdapter())

        MenuBarLyricsController.shared.bind(playbackState: playback)
        if let iconUrl = Bundle.main.url(forResource: "SpotifyLyrics", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconUrl) {
            NSApplication.shared.applicationIconImage = icon
        }
#if DEBUG
        DirectionDMainWindowDebugDelegate.configure(
            playbackState: playback,
            adapter: directionDMainWindowAdapter,
            router: DirectionDExperimentalProductHost.makeRouter(playback: playback)
        )
#endif
    }

    var body: some Scene {
        // The player is a single stateful surface. A WindowGroup can create
        // duplicate main windows, which makes shared playback/layout state
        // race while the user is resizing one of them.
        Window("Lyric Island", id: "main-window") {
            MainLyricsWindowView()
                .environmentObject(playbackState)
                .environmentObject(appSettings)
                .environmentObject(directionDMainWindowAdapter)
                .appleSystemTranslationHost()
                .onAppear {
                    // Product path: zero-operation automatic alignment observes playback.
                    AutomaticAlignmentJobController.shared.bind(playback: playbackState)
                    MenuBarLyricsController.shared.bind(playbackState: playbackState)
#if DEBUG
                    // A command-line v4 run is a controlled visual harness.
                    // Showing the existing capsule after the main scene is
                    // ready keeps the harness deterministic without adding a
                    // second window, timer or business-state owner.
                    if DebugDatabaseSafety.isForcedPresentationArgument {
                        WindowManager.shared.setCapsuleDebugPresentation(
                            .dynamicIslandDarkV4,
                            state: playbackState
                        )
                    }
                    // Diagnostic harness only — env-driven SCK spikes.
                    if !DebugAcceptanceDataIsolation.isRequested {
                        LiveCaptureCoordinator.shared.bind(playback: playbackState)
                        let spike = SpotifyScreenCaptureAudioSpike.shared
                        spike.bind(playback: playbackState)
                    }
#endif
                }
#if DEBUG
                .background(DirectionDMatrixLaunchHook())
#endif
        }
        .defaultSize(width: 1152, height: 720)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .commands {
            appCommands
        }

        Window("歌词编辑", id: "lyrics-editor") {
            LyricsEditorWindowView()
                .environmentObject(playbackState)
                .environmentObject(appSettings)
        }
        .defaultSize(width: 1100, height: 720)

        Window("歌词库与收听记录", id: "personal-library-activity") {
            UnifiedLibraryHistoryWindowView()
                .environmentObject(playbackState)
                .environmentObject(appSettings)
                .environmentObject(settingsData)
        }
        .defaultSize(width: 1000, height: 680)

#if DEBUG
        // Real Direction D main-window entry.  The root view is the formal
        // DirectionDMainWindowView, not the Phase 3.3 product-state host or
        // Preview Matrix.  It is debug-reachable and remains experimental.
        Window("Lyric Island", id: "direction-d-main-window") {
            DirectionDDebugMainWindowSceneHost(
                playback: playbackState,
                adapter: directionDMainWindowAdapter
            )
            .background(DirectionDMainWindowWindowIdentifier())
            .environmentObject(playbackState)
            .environmentObject(appSettings)
        }
        .defaultSize(width: 1_200, height: 760)

        Window("Presentation Preview Lab", id: "presentation-preview-lab") {
            PresentationPreviewLabView()
                .environmentObject(playbackState)
                .environmentObject(appSettings)
        }
        .defaultSize(width: 1_060, height: 680)

        // Design-system matrix only — no formal DB / no Spotify / no providers required.
        Window("Direction D Preview Matrix", id: "direction-d-preview-matrix") {
            DirectionDPreviewMatrixView()
        }
        .defaultSize(width: 1_040, height: 720)

        // Experimental product host — real PlaybackState + Adapter (not default main window).
        Window("Direction D Experimental Host", id: "direction-d-experimental-host") {
            DirectionDExperimentalProductHost()
                .environmentObject(playbackState)
                .environmentObject(appSettings)
        }
        .defaultSize(width: 1_100, height: 720)
#endif

        Settings {
            SettingsRootView()
                .environmentObject(appSettings)
                .environmentObject(playbackState)
                .environmentObject(settingsData)
        }
        .defaultSize(width: 860, height: 580)

#if DEBUG
        .commands {
            PresentationPreviewCommands()
        }
#endif
    }

    @CommandsBuilder
    private var appCommands: some Commands {
        CommandGroup(replacing: .appSettings) {
            SettingsLink {
                Text("设置…")
            }
            .keyboardShortcut(",", modifiers: .command)
        }
        // Register once, alongside native window actions; never add a second Window menu.
        CommandGroup(after: .windowArrangement) {
            Button("菜单栏歌词与播放") {
                MenuBarLyricsController.shared.togglePopover()
            }
            .keyboardShortcut("b", modifiers: [.command, .shift])

            Button("歌词编辑器") {
                playbackState.prepareLyricsEditorForOpening()
                openWindow(id: "lyrics-editor")
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])

            Button("歌词库与收听记录") {
                playbackState.selectedLibraryToolTab = .library
                openWindow(id: "personal-library-activity")
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])

            Divider()

            Button("显示/隐藏悬浮歌词") {
                WindowManager.shared.toggleFloatingLyrics(state: playbackState)
            }
            .keyboardShortcut("f", modifiers: [.command, .option])

            Button("显示/隐藏顶部胶囊") {
                WindowManager.shared.toggleCapsule(state: playbackState)
            }
            .keyboardShortcut("c", modifiers: [.command, .option])

            Button("显示/隐藏全屏歌词") {
                WindowManager.shared.toggleFullScreen(state: playbackState)
            }
            .keyboardShortcut("g", modifiers: [.command, .option])

            Button("收起顶部胶囊") {
                WindowManager.shared.collapseCapsulePlayer()
            }
            Button("展开顶部胶囊") {
                WindowManager.shared.expandCapsulePlayer()
            }

            Button("解除悬浮歌词鼠标穿透") {
                WindowManager.shared.restoreFloatingInteractiveMode(state: playbackState)
            }
            .keyboardShortcut("l", modifiers: [.command, .option])
            .help("即使悬浮歌词已鼠标穿透，也可用此命令直接恢复交互")

            Divider()

            Button("锁定悬浮歌词") {
                WindowManager.shared.setFloatingInteractionMode(.locked, state: playbackState)
            }
            Button("启用悬浮歌词鼠标穿透") {
                WindowManager.shared.setFloatingInteractionMode(.passThrough, state: playbackState)
            }
            Button("恢复悬浮歌词可编辑") {
                WindowManager.shared.setFloatingInteractionMode(.interactive, state: playbackState)
            }
        }
#if DEBUG
        if Self.shouldShowDebugMenus {
            CommandMenu("胶囊锚点（调试）") {
                Button("左上") {
                    WindowManager.shared.setCapsuleDebugAnchor(.topLeft)
                }
                Button("顶部居中") {
                    WindowManager.shared.setCapsuleDebugAnchor(.topCenter)
                }
                Button("右上") {
                    WindowManager.shared.setCapsuleDebugAnchor(.topRight)
                }
            }
            CommandMenu("胶囊呈现（调试）") {
                Button("验证 v4 外壳与尺寸") {
                    activateDebugCapsuleV4()
                }
                Button("恢复当前正式呈现") {
                    WindowManager.shared.setCapsuleDebugPresentation(
                        nil,
                        state: playbackState
                    )
                }
            }
            CommandMenu("排轴捕获 Spike（调试）") {
                Button("开始 Spotify 音频 Spike (S1)") {
                    Task { await SpotifyScreenCaptureAudioSpike.shared.start(autoStopAfter: 25) }
                }
                Button("停止 Spotify 音频 Spike (S1)") {
                    Task { await SpotifyScreenCaptureAudioSpike.shared.stop(reason: "menu") }
                }
                Divider()
                Button("开始 Live Capture (S2)") {
                    LiveCaptureCoordinator.shared.bind(playback: playbackState)
                    Task { await LiveCaptureCoordinator.shared.start(autoStopAfter: 90, runPartialAlignment: false) }
                }
                Button("开始 Partial 对齐 (S3A)") {
                    LiveCaptureCoordinator.shared.bind(playback: playbackState)
                    Task { await LiveCaptureCoordinator.shared.start(autoStopAfter: 75, runPartialAlignment: true) }
                }
                Button("停止 Live Capture / S3A") {
                    Task { await LiveCaptureCoordinator.shared.stop(reason: .userStop) }
                }
            }
        }
#endif
    }

#if DEBUG
    static var shouldShowDebugMenus: Bool {
        ProcessInfo.processInfo.arguments.contains("--debug-menus")
            || ProcessInfo.processInfo.environment["SHOW_DEBUG_MENUS"] == "1"
            || UserDefaults.lyricsQ.bool(forKey: "debug.showMenus")
    }

    private func activateDebugCapsuleV4() {
        if let refusal = DebugDatabaseSafety.menuActivationRefusalMessage() {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "已阻止 v4 调试呈现"
            alert.informativeText = refusal + "\n\n请使用临时数据库路径重新启动 Debug App。"
            alert.addButton(withTitle: "知道了")
            alert.runModal()
            return
        }

        WindowManager.shared.setCapsuleDebugPresentation(
            .dynamicIslandDarkV4,
            state: playbackState
        )
    }
#endif
}

#if DEBUG
private struct PresentationPreviewCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        if SpotifyLyricsApp.shouldShowDebugMenus {
            CommandMenu("预览实验室") {
                Button("打开 Presentation Preview Lab") {
                    openWindow(id: "presentation-preview-lab")
                }
                .keyboardShortcut("p", modifiers: [.command, .option])
                Button("打开 Direction D 矩阵") {
                    openWindow(id: "direction-d-preview-matrix")
                }
                .keyboardShortcut("d", modifiers: [.command, .option])
                Button("打开 Direction D Experimental Host") {
                    openWindow(id: "direction-d-experimental-host")
                }
                .keyboardShortcut("e", modifiers: [.command, .option])
            }
        }
    }
}

/// Opens Direction D matrix when launched with `--debug-direction-d-matrix` (TEMP DB only).
private struct DirectionDMatrixLaunchHook: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                let args = ProcessInfo.processInfo.arguments
                if args.contains("--debug-direction-d-main-window") {
                    // The DEBUG delegate below owns the isolated visual host
                    // for this argument. Do not also open the SwiftUI Window
                    // scene: two same-title hosts race their frame fitting
                    // and make the evidence window collapse to a status view.
                    return
                }
                if args.contains("--debug-direction-d-experimental-host") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        openWindow(id: "direction-d-experimental-host")
                    }
                    return
                }
                guard args.contains("--debug-direction-d-matrix") else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    openWindow(id: "direction-d-preview-matrix")
                }
            }
    }
}

/// DEBUG-only window identification aid for isolated CGWindow captures.
/// It changes no product state and is not present in Release builds.
private struct DirectionDMainWindowWindowIdentifier: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            window.title = "Lyric Island"
            window.identifier = NSUserInterfaceItemIdentifier("direction-d-main-window")
        }
    }
}

/// Direct-executable fallback for isolated Debug acceptance runs.
///
/// A SwiftUI `Window` scene is still the normal Debug entry point.  Some
/// macOS launches from an absolute executable do not instantiate a
/// `WindowGroup` until the app receives an external reopen event, which makes
/// window-only evidence impossible to capture.  This DEBUG-only delegate
/// presents the same injected DirectionDMainWindowView without creating a
/// second business state owner or a WindowController.  It is activated only
/// by `--debug-direction-d-main-window` and never exists in Release.
@MainActor
private final class DirectionDMainWindowDebugDelegate: NSObject, NSApplicationDelegate {
    private static var configuredPlaybackState: PlaybackState?
    private static var configuredAdapter: DirectionDProductStateAdapter?
    private static var configuredRouter = DirectionDActionRouter()
    private var window: NSWindow?

    static func configure(
        playbackState: PlaybackState,
        adapter: DirectionDProductStateAdapter,
        router: DirectionDActionRouter
    ) {
        configuredPlaybackState = playbackState
        configuredAdapter = adapter
        configuredRouter = router
    }

    nonisolated func applicationDidFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.arguments.contains("--debug-direction-d-main-window") else {
            return
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            self?.showMainWindowIfNeeded()
        }
    }

    private func showMainWindowIfNeeded() {
        guard let playbackState = Self.configuredPlaybackState,
              let adapter = Self.configuredAdapter else { return }
        // The normal MainLyricsWindowView starts the shared provider from its
        // task.  A direct-executable Direction D acceptance run intentionally
        // has no default WindowGroup instance, so start the same idempotent
        // provider path here; PlaybackState guards against a second timer.
        playbackState.startProvider(connectSpotify: true)
        // Bind explicitly before installing the hosting view.  AppKit-hosted
        // SwiftUI roots can defer `onAppear`, while the acceptance window must
        // still expose the live projection as soon as the first real snapshot
        // arrives.  `bind` is single-flight and removes any prior adapter
        // subscriptions, so this does not add a second observer or timer.
        adapter.bind(playback: playbackState)
        // The direct-executable DEBUG bridge can install its AppKit hosting
        // view before the first persistence-backed lyrics projection settles.
        // Re-read once after that initial handoff; ongoing changes continue
        // through the existing PlaybackState publisher.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak adapter] in
            adapter?.refreshFromProduct()
        }
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let content = DirectionDMainWindowPresentationFactory.makeMainWindow(
            stableID: "mainWindow.directionD.v4",
            playbackState: playbackState,
            adapter: adapter,
            router: Self.configuredRouter
        )

        var initialWidth: CGFloat = 1_200
        var initialHeight: CGFloat = 760
        if let envSize = ProcessInfo.processInfo.environment["SPOTIFYLYRICS_WINDOW_SIZE"] {
            let parts = envSize.split(separator: "x")
            if parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]) {
                initialWidth = CGFloat(w)
                initialHeight = CGFloat(h)
            }
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: initialWidth, height: initialHeight),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Lyric Island"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.identifier = NSUserInterfaceItemIdentifier("direction-d-main-window")
        window.isReleasedWhenClosed = false
        // Keep the direct DEBUG host at the visual envelope used for the
        // responsive presentation. Without an AppKit content minimum,
        // SwiftUI can fit the window to a transient empty/status view when
        // the first live playback snapshot arrives, making visual evidence
        // unusable. This does not affect the production SwiftUI Window.
        window.contentMinSize = NSSize(width: 520, height: 520)
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        let hostingView = NSHostingView(rootView: content)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: container.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        window.contentView = container
        window.center()
        if ProcessInfo.processInfo.environment["SPOTIFYLYRICS_WINDOW_SIZE"] != nil {
            window.setFrame(NSRect(x: 100, y: 100, width: initialWidth, height: initialHeight), display: true)
        }
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
#endif
