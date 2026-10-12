import Foundation
import Combine
import SwiftUI
import AppKit

/// Pure presentation adapter for Direction D (Phase 3.3).
/// Consumes real product publishers — does not own a second business state machine.
@MainActor
public final class DirectionDProductStateAdapter: ObservableObject {
    @Published public private(set) var primaryState: DirectionDPrimaryState = .waitingForPlayback
    @Published public private(set) var secondaryState: DirectionDSecondaryState = .none
    @Published public private(set) var activePresentationState: DirectionDPresentationState = .waitingForPlayback
    @Published public private(set) var currentTrackId: String?
    @Published public private(set) var lyricsLines: [LyricLine] = []
    @Published public private(set) var trackTitle: String = ""
    @Published public private(set) var trackArtist: String = ""
    @Published public private(set) var trackAlbum: String = ""

    /// Whether the summary metadata belongs to a live or explicit preview
    /// track, rather than an unbound/empty adapter state.
    public var hasTrackForDisplay: Bool {
        guard let playback else { return false }
        return playback.hasLiveTrack || playback.isMockPreviewMode
    }

    private var lastAnnouncedState: DirectionDPresentationState?
    private var cancellables = Set<AnyCancellable>()
    private weak var playback: PlaybackState?

    /// Optional controlled override for host screenshots / acceptance (same Host + Adapter path).
    /// Values: permissionRequired, spotifyNotRunning, waitingForPlayback, loadingLyrics, noLyrics,
    /// networkNoCache, networkWithCache, syncRunning, syncProgress, syncCompleted, normal
    public var forcedPresentationOverride: String?

    public init() {}

    /// Bind to live product sources. Call once from experimental product host.
    public func bind(playback: PlaybackState) {
        self.playback = playback
        cancellables.removeAll()
        playback.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.scheduleRefresh()
            }
            .store(in: &cancellables)
        AutomaticAlignmentJobController.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.scheduleRefresh()
            }
            .store(in: &cancellables)
        refreshFromProduct()
    }

    /// Releases the adapter's view-lifetime subscriptions without touching
    /// PlaybackState, LyricsSession, alignment, or any persistence.
    public func unbind() {
        refreshWorkItem?.cancel()
        refreshWorkItem = nil
        cancellables.removeAll()
        playback = nil
    }

    private var refreshWorkItem: DispatchWorkItem?
    private func scheduleRefresh() {
        refreshWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.refreshFromProduct() }
        }
        refreshWorkItem = item
        // Throttle — PlaybackState ticks ~5Hz via currentTime.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
    }

    /// Pull inputs from real PlaybackState + AutomaticAlignmentJobController.
    public func refreshFromProduct() {
#if DEBUG
        let acceptanceOverride = forcedPresentationOverride
            ?? ProcessInfo.processInfo.environment["SPOTIFYLYRICS_DIRECTION_D_HOST_STATE"]
#else
        let acceptanceOverride: String? = nil
#endif
        if let forced = acceptanceOverride,
           Self.isAcceptanceFixtureKey(forced) {
            applyForcedOverride(forced)
            if let playback {
                applyTrackMetadata(from: playback)
            }
            return
        }
        guard let playback else {
            updateState(
                hasPermission: true,
                isSpotifyRunning: false,
                isSpotifyAvailable: false,
                isPlayingOrPaused: false,
                trackId: nil,
                isLoadingLyrics: false,
                hasLyrics: false,
                isCachedLyrics: false,
                isNetworkAvailable: true,
                alignmentJobState: nil
            )
            lyricsLines = []
            return
        }
        applyTrackSnapshot(from: playback)

        let status = playback.providerStatus
        let hasPermission = status != .permissionDenied
        let isSpotifyRunning: Bool = {
            switch status {
            case .notInstalled, .notRunning: return false
            default: return true
            }
        }()
        let isSpotifyAvailable: Bool = {
            switch status {
            case .ready, .noTrack, .connecting, .mockPreview: return true
            case .unavailable: return false
            case .permissionDenied, .notInstalled, .notRunning: return false
            }
        }()
        let hasTrack = playback.liveTrackIdentity != nil
        let isPlayingOrPaused = hasTrack // pause keeps track; idle only when no track
        let lyricsState = playback.liveLyricsState
        let documentMatchesTrack = playback.liveLyricsDocumentMatchesCurrentTrack
        let isLoading: Bool = {
            if hasTrack && !documentMatchesTrack { return true }
            if case .loading = lyricsState { return true }
            return false
        }()
        let lines = documentMatchesTrack ? playback.liveLyrics : []
        let hasLyrics = !lines.isEmpty
        let isCached: Bool = {
            // Local / previously persisted session content counts as cache for secondary banner.
            if let source = playback.liveLyricsSource {
                switch source {
                case .local, .manualImport, .manualCreate, .manualEdit, .automaticAlignment:
                    return true
                default:
                    return false
                }
            }
            return hasLyrics && !isLoading
        }()
        let networkOK = NetworkPathProbe.isSatisfied
        let jobToken = DirectionDStatePriority.alignmentToken(
            from: AutomaticAlignmentJobController.shared.state.rawValue
        )

        updateState(
            hasPermission: hasPermission,
            isSpotifyRunning: isSpotifyRunning,
            isSpotifyAvailable: isSpotifyAvailable || status == .permissionDenied,
            isPlayingOrPaused: isPlayingOrPaused,
            trackId: playback.liveTrackIdentity?.stableKey,
            isLoadingLyrics: isLoading,
            hasLyrics: hasLyrics,
            isCachedLyrics: isCached || hasLyrics,
            isNetworkAvailable: networkOK,
            alignmentJobState: jobToken
        )
        lyricsLines = lines
    }

    private func applyTrackMetadata(from playback: PlaybackState) {
        trackTitle = playback.currentTrack.title
        trackArtist = playback.currentTrack.artist
        trackAlbum = playback.currentTrack.album
    }

    private func applyTrackSnapshot(from playback: PlaybackState) {
        applyTrackMetadata(from: playback)
        let nextTrackID = playback.liveTrackIdentity?.stableKey
        if nextTrackID != currentTrackId {
            currentTrackId = nextTrackID
            lyricsLines = []
        }
        lyricsLines = playback.liveLyricsDocumentMatchesCurrentTrack ? playback.liveLyrics : []
    }

    /// Only these keys replace the live product-state inputs with a controlled
    /// acceptance fixture.  Layout-only keys (`normal`, `wide-inspector`, and
    /// `small-sheet`) must continue through the live path.
    public static func isAcceptanceFixtureKey(_ raw: String) -> Bool {
        switch raw.lowercased().replacingOccurrences(of: "-", with: "_") {
        case "permissionrequired", "permission",
             "spotifynotrunnung", "spotifynorunning", "spotify_not_running",
             "waitingforplayback", "idle", "loading", "loadinglyrics",
             "nolyric", "nolyrics", "networknocache", "network_no_cache",
             "networkwithcache", "network_with_cache", "syncrunning", "sync_running",
             "automaticsyncrunning", "syncprogress", "sync_progress", "progresssaved",
             "synccompleted", "sync_completed", "completed", "longlyrics", "long_lyrics",
             "reducetransparency", "normalyrics":
            return true
        default:
            return false
        }
    }

    /// Controlled host acceptance: inject presentation inputs through the same Adapter.
    @discardableResult
    public func applyForcedOverride(_ key: String) -> Bool {
        switch key.lowercased() {
        case "permissionrequired", "permission":
            updateState(hasPermission: false, isSpotifyRunning: true, isSpotifyAvailable: true,
                        isPlayingOrPaused: false, trackId: nil, hasLyrics: false)
            lyricsLines = []
            return true
        case "spotifynotrunnung", "spotifynorunning", "spotify_not_running":
            updateState(hasPermission: true, isSpotifyRunning: false, isSpotifyAvailable: false,
                        isPlayingOrPaused: false, trackId: nil, hasLyrics: false)
            lyricsLines = []
            return true
        case "waitingforplayback", "idle":
            updateState(hasPermission: true, isSpotifyRunning: true, isSpotifyAvailable: true,
                        isPlayingOrPaused: false, trackId: nil, hasLyrics: false)
            lyricsLines = []
            return true
        case "loading", "loadinglyrics":
            updateState(hasPermission: true, isSpotifyRunning: true, isSpotifyAvailable: true,
                        isPlayingOrPaused: true, trackId: "t1", isLoadingLyrics: true, hasLyrics: false)
            lyricsLines = []
            return true
        case "nolyric", "nolyrics":
            updateState(hasPermission: true, isSpotifyRunning: true, isSpotifyAvailable: true,
                        isPlayingOrPaused: true, trackId: "t1", hasLyrics: false, isNetworkAvailable: true)
            lyricsLines = []
            return true
        case "networknocache", "network_no_cache":
            updateState(hasPermission: true, isSpotifyRunning: true, isSpotifyAvailable: true,
                        isPlayingOrPaused: true, trackId: "t1", hasLyrics: false, isNetworkAvailable: false)
            lyricsLines = []
            return true
        case "networkwithcache", "network_with_cache":
            updateState(hasPermission: true, isSpotifyRunning: true, isSpotifyAvailable: true,
                        isPlayingOrPaused: true, trackId: "t1", hasLyrics: true, isCachedLyrics: true,
                        isNetworkAvailable: false)
            if lyricsLines.isEmpty { lyricsLines = Self.fixtureLines }
            return true
        case "syncrunning", "sync_running", "automaticsyncrunning":
            updateState(hasPermission: true, isSpotifyRunning: true, isSpotifyAvailable: true,
                        isPlayingOrPaused: true, trackId: "t1", hasLyrics: true, isCachedLyrics: false,
                        isNetworkAvailable: true, alignmentJobState: "running")
            if lyricsLines.isEmpty { lyricsLines = Self.fixtureLines }
            return true
        case "syncprogress", "sync_progress", "progresssaved":
            updateState(hasPermission: true, isSpotifyRunning: true, isSpotifyAvailable: true,
                        isPlayingOrPaused: true, trackId: "t1", hasLyrics: true,
                        isNetworkAvailable: true, alignmentJobState: "accumulating")
            if lyricsLines.isEmpty { lyricsLines = Self.fixtureLines }
            return true
        case "synccompleted", "sync_completed", "completed":
            updateState(hasPermission: true, isSpotifyRunning: true, isSpotifyAvailable: true,
                        isPlayingOrPaused: true, trackId: "t1", hasLyrics: true,
                        isNetworkAvailable: true, alignmentJobState: "completed")
            if lyricsLines.isEmpty { lyricsLines = Self.fixtureLines }
            return true
        case "longlyrics", "long_lyrics":
            updateState(hasPermission: true, isSpotifyRunning: true, isSpotifyAvailable: true,
                        isPlayingOrPaused: true, trackId: "t1", hasLyrics: true)
            lyricsLines = Self.longFixtureLines
            return true
        case "reducetransparency", "normal", "normalyrics":
            updateState(hasPermission: true, isSpotifyRunning: true, isSpotifyAvailable: true,
                        isPlayingOrPaused: true, trackId: "t1", hasLyrics: true)
            if lyricsLines.isEmpty { lyricsLines = Self.fixtureLines }
            return true
        default:
            return false
        }
    }

    private static let fixtureLines: [LyricLine] = [
        LyricLine(
            id: UUID(),
            timestamp: 15,
            originalText: "東京は夜七時 慌ただしい街に雨が降り出す",
            translationText: "东京晚上七点 匆忙的街头开始下起了雨",
            romajiText: "Tokyo wa yoru shichiji",
            kanaText: "とうきょう は よる しちじ"
        )
    ]

    /// DEBUG-only acceptance fixture for the small-window long-document
    /// capture.  It is reachable only through the controlled environment
    /// override; the normal main-window path always uses liveLyrics.
    private static let longFixtureLines: [LyricLine] = [
        LyricLine(
            id: UUID(),
            timestamp: 15,
            originalText: "東京は夜七時 慌ただしい街に雨が降り出して長い影が窓辺をゆっくり横切る",
            translationText: "东京晚上七点，匆忙街头的雨落下来，长长的影子慢慢掠过窗边",
            romajiText: "Tokyo wa yoru shichiji awatadashii machi ni ame ga furidashite",
            kanaText: "とうきょう は よる しちじ あわただしい まち に あめ が ふりだして"
        ),
        LyricLine(
            id: UUID(),
            timestamp: 22,
            originalText: "まだ名前のない明日を待ちながら静かな灯りを見つめている",
            translationText: "一边等待还没有名字的明天，一边凝视着安静的灯光",
            romajiText: "Mada namae no nai ashita o machinagara",
            kanaText: "まだ なまえ の ない あした を まちながら"
        ),
        LyricLine(
            id: UUID(),
            timestamp: 30,
            originalText: "遠い街の音が途切れて夜の余白だけが静かに残る",
            translationText: "远方城市的声音渐渐停下，只留下夜晚的空白",
            romajiText: "Tooi machi no oto ga togirete",
            kanaText: "とおい まち の おと が とぎれて"
        )
    ]

    public func updateState(
        hasPermission: Bool = true,
        isSpotifyRunning: Bool = true,
        isSpotifyAvailable: Bool = true,
        isPlayingOrPaused: Bool = true,
        trackId: String? = nil,
        isLoadingLyrics: Bool = false,
        hasLyrics: Bool = false,
        isCachedLyrics: Bool = false,
        isNetworkAvailable: Bool = true,
        alignmentJobState: String? = nil
    ) {
        // Track change: clear previous identity secondary by full re-resolve.
        if trackId != currentTrackId {
            currentTrackId = trackId
        }

        let resolved = DirectionDStatePriority.resolve(
            hasPermission: hasPermission,
            isSpotifyRunning: isSpotifyRunning,
            isSpotifyAvailable: isSpotifyAvailable,
            isPlayingOrPaused: isPlayingOrPaused,
            hasTrack: trackId != nil,
            isLoadingLyrics: isLoadingLyrics,
            hasLyrics: hasLyrics,
            isCachedLyrics: isCachedLyrics,
            isNetworkAvailable: isNetworkAvailable,
            alignmentJobState: alignmentJobState
        )

        primaryState = resolved.primary
        secondaryState = resolved.secondary
        activePresentationState = mapToActivePresentationState(
            primary: resolved.primary,
            secondary: resolved.secondary
        )
        announceAccessibilityIfNeeded(newState: activePresentationState)
    }

    private func mapToActivePresentationState(
        primary: DirectionDPrimaryState,
        secondary: DirectionDSecondaryState
    ) -> DirectionDPresentationState {
        switch primary {
        case .permissionRequired: return .permissionRequired
        case .spotifyNotRunning: return .spotifyNotRunning
        case .spotifyUnavailable: return .spotifyUnavailable
        case .waitingForPlayback: return .waitingForPlayback
        case .loadingLyrics: return .loadingLyrics
        case .noLyrics: return .noLyrics
        case .networkUnavailableNoCache: return .networkUnavailable
        case .showingLyrics:
            switch secondary {
            case .networkUnavailableWithCache: return .usingCachedLyrics
            case .automaticSyncRunning: return .automaticSyncRunning
            case .automaticSyncProgressSaved: return .automaticSyncProgressSaved
            case .automaticSyncWaiting: return .automaticSyncWaiting
            case .automaticSyncCompleted: return .automaticSyncCompleted
            case .automaticSyncUnreliable: return .automaticSyncUnreliable
            case .automaticSyncUnavailable: return .automaticSyncUnavailable
            case .none: return .normalLyrics
            }
        }
    }

    private func announceAccessibilityIfNeeded(newState: DirectionDPresentationState) {
        guard newState != lastAnnouncedState else { return }
        lastAnnouncedState = newState
        let msg = newState.userFacingMessage
        guard !msg.isEmpty else { return }
        DispatchQueue.main.async {
            NSAccessibility.post(
                element: NSApp as Any,
                notification: .announcementRequested,
                userInfo: [.announcement: msg]
            )
        }
    }
}

/// Lightweight network probe shared with product host (no second poller service).
enum NetworkPathProbe {
    static var isSatisfied: Bool {
        // Prefer NWPathMonitor if already running elsewhere; fall back optimistic true
        // so offline-only failures come from lyrics session failure mapping.
        if let override = ProcessInfo.processInfo.environment["SPOTIFYLYRICS_FORCE_NETWORK_OFF"] {
            return override != "1"
        }
        return true
    }
}
