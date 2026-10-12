import SwiftUI
import Combine
struct ProbeTrack { var title = ""; var artist = ""; var artworkURL: URL? }
struct ProbePreferences { var showTranslation = true }
struct ProbeLine { var originalText = ""; var translationText: String? }
enum ProbeLoadState { case loading, noLyrics, noSelection, noMatch, failed, loaded, alignmentQueued, alignmentRunning, alignmentPreview, idle, candidates, mockPreview }
@MainActor public final class PlaybackState: ObservableObject {
    @Published var selectedLibraryToolTab = Tab.library
    enum Tab { case library }
    var preferences = ProbePreferences()
    var hasLiveTrack = false
    var isMockPreviewMode = false
    var currentTrack = ProbeTrack()
    var isPlaying = false
    var liveLyricsDocumentMatchesCurrentTrack = false
    var liveLyricsState = ProbeLoadState.idle
    var liveLyrics: [ProbeLine] = []
    var liveLyricsAreSynchronized = false
    var liveCurrentLineIndex: Int?
    func togglePlayPause() {}
    func previousTrack() {}
    func nextTrack() {}
}
struct MenuBarLyricsPopoverView: View {
    var controller: MenuBarLyricsController
    var body: some View { EmptyView() }
}
