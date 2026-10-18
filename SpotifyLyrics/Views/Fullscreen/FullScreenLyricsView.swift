import SwiftUI

/// Fullscreen uses the maintained three-style player, restricted to live
/// playback even while the main window displays a catalog search preview.
struct FullScreenLyricsView: View {
    @ObservedObject var state: PlaybackState
    @ObservedObject var settings: AppSettingsStore

    private var layoutBinding: Binding<String> {
        Binding(get: { settings.mainWindowLayoutStyleRawValue }, set: { rawValue in
            guard let style = MainWindowLayoutStyle(rawValue: rawValue) else { return }
            _ = settings.applyPresentationSelection(category: .mainWindow, stableID: style.presentationStableID)
        })
    }

    var body: some View {
        GeometryReader { geometry in
            AppleMusicImmersiveV3WindowView(state: state, settings: settings,
                layoutStyleRawValue: layoutBinding, liveOnly: true)
                .equatable()
                .environmentObject(settings)
                .environment(\.lyricPresentationScale, min(1.5, max(1, geometry.size.height / 900)))
        }
    }
}
