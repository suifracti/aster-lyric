#if DEBUG
import SwiftUI
import AppKit

/// DEBUG experimental product host — binds real PlaybackState + AutoAlign into Direction D.
/// Not the default main window. No Preview Matrix tabs.
struct DirectionDExperimentalProductHost: View {
    @EnvironmentObject private var playback: PlaybackState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @StateObject private var adapter = DirectionDProductStateAdapter()
    @State private var router: DirectionDActionRouter
    @State private var isSearchPresented = false

    init() {
        // Placeholder router; rebuilt on appear with playback.
        _router = State(initialValue: DirectionDActionRouter())
    }

    var body: some View {
        DirectionDProductStateHostView(adapter: adapter, router: router)
            .onAppear {
                router = Self.makeRouter(
                    playback: playback,
                    onOpenManualLyricsSearch: { isSearchPresented = true },
                    onOpenSettings: { openSettings() },
                    onOpenEditor: { openWindow(id: "lyrics-editor") }
                )
                adapter.forcedPresentationOverride =
                    ProcessInfo.processInfo.environment["SPOTIFYLYRICS_DIRECTION_D_HOST_STATE"]
                adapter.bind(playback: playback)
            }
            .onChange(of: playback.hasLiveTrack) { _, _ in
                adapter.refreshFromProduct()
            }
            .frame(minWidth: 900, minHeight: 620)
            .preferredColorScheme(.dark)
            .accessibilityIdentifier("directionD.experimentalProductHost")
            .popover(isPresented: $isSearchPresented, arrowEdge: .top) {
                SongSearchPopover(manager: playback.songSearchManager, playbackState: playback)
            }
    }

    static func makeRouter(
        playback: PlaybackState,
        onOpenManualLyricsSearch: (() -> Void)? = nil,
        onOpenSettings: (() -> Void)? = nil,
        onOpenEditor: (() -> Void)? = nil
    ) -> DirectionDActionRouter {
        DirectionDActionRouter(
            canPresentWindowActions: onOpenManualLyricsSearch != nil && onOpenSettings != nil && onOpenEditor != nil,
            onOpenSpotify: {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") {
                    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                }
            },
            onOpenSystemSettings: {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                    NSWorkspace.shared.open(url)
                }
            },
            onRetryPlaybackDetection: {
                playback.startProvider(connectSpotify: true)
            },
            onRetryLyricsSearch: {
                playback.retryLyrics()
            },
            onOpenManualLyricsSearch: {
                onOpenManualLyricsSearch?()
            },
            onImportLyrics: {
                guard let onOpenEditor else { return }
                DirectionDActionRouter.performManualLyricsImport(
                    prepare: { playback.prepareManualLyricsFromTXT() },
                    openEditor: onOpenEditor
                )
            },
            onOpenSongWorkbench: {
                // Inspector toggle is local UI; no second business owner.
            },
            onOpenSettings: { onOpenSettings?() },
            onRetryAutomaticAlignment: {
                AutomaticAlignmentJobController.shared.retry()
            },
            onStopAutomaticAlignment: {
                AutomaticAlignmentJobController.shared.cancelCurrentJob(userInitiated: true)
            }
        )
    }
}

/// The separately selectable Debug scene uses the same live projection and
/// supplies window presentation actions from its own SwiftUI environment.
struct DirectionDDebugMainWindowSceneHost: View {
    @ObservedObject var playback: PlaybackState
    @ObservedObject var adapter: DirectionDProductStateAdapter
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var isSearchPresented = false

    var body: some View {
        DirectionDMainWindowPresentationFactory.makeMainWindow(
            stableID: "mainWindow.directionD.v4",
            playbackState: playback,
            adapter: adapter,
            router: DirectionDExperimentalProductHost.makeRouter(
                playback: playback,
                onOpenManualLyricsSearch: { isSearchPresented = true },
                onOpenSettings: { openSettings() },
                onOpenEditor: { openWindow(id: "lyrics-editor") }
            )
        )
        .popover(isPresented: $isSearchPresented, arrowEdge: .top) {
            SongSearchPopover(manager: playback.songSearchManager, playbackState: playback)
        }
    }
}
#endif
