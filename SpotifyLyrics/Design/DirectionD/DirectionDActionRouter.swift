import Foundation
import AppKit

/// Direction D User Action Router (Phase 3.3).
/// Routes UI actions to existing business controllers/handlers without executing direct DB or network operations inside Views.
public struct DirectionDActionRouter {
    /// AppKit's direct screenshot host has no SwiftUI window presentation
    /// environment. Views use this to disable search, Settings and TXT import.
    public var canPresentWindowActions: Bool
    /// TXT import only creates an editor draft. Present the editor after a
    /// successful preparation so cancellation never looks like an import.
    @MainActor
    public static func performManualLyricsImport(
        prepare: () -> Bool,
        openEditor: () -> Void
    ) {
        if prepare() { openEditor() }
    }

    public var onOpenSpotify: () -> Void
    public var onOpenSystemSettings: () -> Void
    public var onRetryPlaybackDetection: () -> Void
    public var onRetryLyricsSearch: () -> Void
    public var onOpenManualLyricsSearch: () -> Void
    public var onImportLyrics: () -> Void
    public var onOpenSongWorkbench: () -> Void
    public var onOpenSettings: () -> Void
    public var onRetryAutomaticAlignment: () -> Void
    public var onStopAutomaticAlignment: () -> Void

    public init(
        canPresentWindowActions: Bool = true,
        onOpenSpotify: @escaping () -> Void = {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            }
        },
        onOpenSystemSettings: @escaping () -> Void = {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                NSWorkspace.shared.open(url)
            }
        },
        onRetryPlaybackDetection: @escaping () -> Void = {},
        onRetryLyricsSearch: @escaping () -> Void = {},
        onOpenManualLyricsSearch: @escaping () -> Void = {},
        onImportLyrics: @escaping () -> Void = {},
        onOpenSongWorkbench: @escaping () -> Void = {},
        onOpenSettings: @escaping () -> Void = {},
        onRetryAutomaticAlignment: @escaping () -> Void = {},
        onStopAutomaticAlignment: @escaping () -> Void = {}
    ) {
        self.canPresentWindowActions = canPresentWindowActions
        self.onOpenSpotify = onOpenSpotify
        self.onOpenSystemSettings = onOpenSystemSettings
        self.onRetryPlaybackDetection = onRetryPlaybackDetection
        self.onRetryLyricsSearch = onRetryLyricsSearch
        self.onOpenManualLyricsSearch = onOpenManualLyricsSearch
        self.onImportLyrics = onImportLyrics
        self.onOpenSongWorkbench = onOpenSongWorkbench
        self.onOpenSettings = onOpenSettings
        self.onRetryAutomaticAlignment = onRetryAutomaticAlignment
        self.onStopAutomaticAlignment = onStopAutomaticAlignment
    }
}
