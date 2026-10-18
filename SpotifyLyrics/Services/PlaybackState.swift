import Combine
import AppKit
import UniformTypeIdentifiers
import Foundation
import Network
#if DEBUG
import os
#endif

public enum LibraryToolTab: String, CaseIterable, Identifiable {
    case library = "我的歌词库"
    case history = "最近播放"
    case statistics = "听歌统计"

    public var id: String { rawValue }
}

@MainActor
public final class PlaybackState: ObservableObject {
#if DEBUG
    private static let seekLogger = Logger(subsystem: "com.spotifylyrics.app", category: "seek")
#endif
    @Published public private(set) var currentTrack: Track = .emptyPlaybackPlaceholder
    @Published public private(set) var currentTime: TimeInterval = 0
    /// Current-time subscribers still receive every tick. Large surfaces can
    /// ignore only this synchronous objectWillChange; real content events remain live.
    public private(set) var isPublishingPlaybackClockTick = false
    /// Published only when the playhead crosses a lyric-line boundary, on
    /// seek/pause/resume/track change, or when the lyric document changes.
    /// Not updated by the 5 Hz `currentTime` tick.
    @Published public private(set) var liveCurrentLineIndex: Int? = nil
    @Published public private(set) var isPlaying = false
    @Published public var currentMode: LyricsDisplayMode = .mainWindow
    @Published public var preferences: DisplayPreferences = DisplayPreferences()
    @Published public private(set) var providerStatus: PlaybackProviderState = .connecting
    /// Source identity reported by the active playback provider. This is not
    /// inferred from process existence or track metadata and is the source
    /// capability input for automatic live capture.
    @Published public private(set) var playbackSourceIdentity: PlaybackSourceIdentity = .unknown
    @Published public private(set) var isMockPreviewMode = false
    @Published public private(set) var hasLiveTrack = false
    @Published public private(set) var songSearchSelectionMessage = ""
    @Published public private(set) var searchPreviewTrack: Track?
    @Published public private(set) var listeningHistory: [ListeningHistoryEntry] = []
    @Published public private(set) var listeningStatistics: ListeningStatistics?
    @Published public private(set) var isListeningHistoryLoading = false
    @Published public private(set) var isListeningStatisticsLoading = false
    @Published public private(set) var listeningHistoryError: String?
    @Published public private(set) var listeningStatisticsError: String?
    @Published public var selectedLibraryToolTab: LibraryToolTab = .library

    // Auxiliary display states remain available to the existing window manager.
    @Published public var showFloatingWindow = false
    @Published public var showCapsulePlayer = false
    @Published public var showFullScreen = false

    private let provider: PlaybackProvider
    /// Shared lyrics session (product auto-align reuses adopt/save paths).
    public let lyricsSession: LyricsSessionController
    private let searchPreviewSession: LyricsSessionController
    private let translationSession: TranslationSessionController
    public let readingSession: ReadingSessionController
    public let lyricsEditorSession: LyricsEditorSessionController
    private let lyricsRepository: (any LyricsRepository)
    private let settingsStore: AppSettingsStore
    private var lyricsOffsetScopeBinding: LyricsOffsetScopeBinding?
    private let usesConfiguredLyricsProviders: Bool
    private let alignmentService: any AlignmentService
    public let songSearchManager: SongSearchManager
    public let spotifyAuthorizationManager: SpotifyAuthorizationManager
    private var lyricsSessionCancellable: AnyCancellable?
    private var searchPreviewSessionCancellable: AnyCancellable?
    private var translationSessionCancellable: AnyCancellable?
    private var readingSessionCancellable: AnyCancellable?
    private var lyricsEditorSessionCancellable: AnyCancellable?
    private var spotifyAuthorizationCancellable: AnyCancellable?
    private var settingsCancellables: Set<AnyCancellable> = []
    private var timer: Timer?
    private var isProviderStarted = false
    private var automaticSpotifyConnectionEnabled = true
    /// The launch toggle gates only explicitly selected Spotify. `.auto`
    /// retains its existing player discovery path, including Apple Music.
    private var canRefreshSelectedProvider: Bool {
        settingsStore.playbackSourceMode != .spotify || automaticSpotifyConnectionEnabled
    }
    private var isRefreshingProvider = false
    private var providerRefreshGeneration: UInt64 = 0
    private var refreshRequestedWhileBusy = false
    private var providerRefreshTask: Task<Void, Never>?
    private var persistencePreparationTask: Task<Void, Never>?
    private var searchPreviewTask: Task<Void, Never>?
    private var listeningHistorySession: ListeningHistorySession?
    private var listeningHistoryWriteTask: Task<Void, Never>?
    private var listeningHistoryLoadTask: Task<Void, Never>?
    private var listeningStatisticsLoadTask: Task<Void, Never>?
    private var searchPreviewGeneration: UInt64 = 0
    private var networkRecoveryMonitor: NWPathMonitor?
    private var networkWasSatisfied = false
    private var playbackAnchorPosition: TimeInterval = 0
    private var playbackAnchorDate = Date()
    private var playbackAnchorMonotonic: TimeInterval = ProcessInfo.processInfo.systemUptime
    private var lineBoundaryTask: Task<Void, Never>?
    private var lineBoundaryGeneration: UInt64 = 0
    private var confirmedLineIndex: Int?
    private var confirmedLineStart: TimeInterval?
    private var confirmedCrossMonotonic: TimeInterval = 0
    private var lastProviderRefreshDate = Date.distantPast
    private var transientProviderFailureStartedAt: Date?
    // Apple Events can fail for several polling cycles while Spotify remains
    // open and playing. Retain the last confirmed state for a bounded window
    // longer than the observed transient burst, but still clear a persistent
    // provider outage.
    private let transientProviderFailureGracePeriod: TimeInterval = 20
#if DEBUG
    /// Optional acceptance harness: when `SPOTIFYLYRICS_ACCEPTANCE_CONTROL_PATH`
    /// is set, a short timer applies mode / retry commands from that file.
    /// Production launches never set the env, so this stays inert.
    private var acceptanceControlTimer: Timer?
    private var acceptanceControlLastPayload = ""
#endif
    private struct LyricsProjectionCacheKey: Equatable {
        let identityKey: String?
        let revision: UInt64
        let translationVersionID: UUID?
        let translationSelectionIsEmpty: Bool
        let lyricsVersionID: UUID?
        let sourceContentHash: String?
        let lineCount: Int
        let readingRevision: UInt64
    }
    private struct PendingManualLyricsAdoption {
        let requestID: UUID
        let session: LyricsSessionController
        let track: Track
        let document: LyricsDocument
        let identity: TrackIdentity
        let lockedVersionIDs: [UUID]
        let clearSearchPreviewGeneration: UInt64?
    }
    private var pendingManualLyricsAdoption: PendingManualLyricsAdoption?
    private var liveLyricsProjectionCache: (key: LyricsProjectionCacheKey, lines: [LyricLine])?
    private var previewLyricsProjectionCache: (key: LyricsProjectionCacheKey, lines: [LyricLine])?
    private let tickInterval: TimeInterval = 0.2
    // Track changes need a quicker observation path than the old two-second
    // calibration heartbeat, while the single-flight guard still prevents
    // overlapping Apple Events requests.
    private let calibrationInterval: TimeInterval = 1.0

    public init(
        provider: PlaybackProvider? = nil,
        lyricsProvider: LyricsProvider? = nil,
        lyricsRepository: (any LyricsRepository)? = nil,
        settings: AppSettingsStore? = nil,
        alignmentService: (any AlignmentService)? = nil
    ) {
        let resolvedSettings = settings ?? AppSettingsStore()
        self.settingsStore = resolvedSettings
        self.lyricsOffsetScopeBinding = LyricsOffsetScopeBinding(store: resolvedSettings.lyricsOffsetStore)
        self.preferences = resolvedSettings.displayPreferences
        let resolvedProvider = provider ?? ActivePlaybackProvider(settings: resolvedSettings)
        self.provider = resolvedProvider
        let sharedIndex = LocalLyricsIndex.shared
        let authorizationManager = SpotifyAuthorizationManager()
        self.spotifyAuthorizationManager = authorizationManager
        let lyricsProviders: [LyricsProvider]
        if let lyricsProvider {
            lyricsProviders = [lyricsProvider]
        } else {
            lyricsProviders = Self.makeDefaultLyricsProviders(
                index: sharedIndex,
                configuration: resolvedSettings.lyricsProviderConfiguration,
                mode: resolvedSettings.lyricsSourceMode
            )
        }
        self.usesConfiguredLyricsProviders = lyricsProvider == nil
        self.alignmentService = alignmentService ?? SpeechForcedAlignmentService()
        let resolvedRepository: any LyricsRepository = lyricsRepository ?? SQLiteLyricsRepository()
        LyricsE2ELog.reset()
        LyricsE2ELog.log("PlaybackState init providers=" + lyricsProviders.map { $0.name }.joined(separator: ","))
        self.lyricsRepository = resolvedRepository
        let session = LyricsSessionController(
            providers: lyricsProviders,
            repository: resolvedRepository,
            spotifyArtistResolver: lyricsProvider == nil ? .shared : nil
        )
        let previewSession = LyricsSessionController(
            providers: lyricsProviders,
            repository: resolvedRepository,
            spotifyArtistResolver: lyricsProvider == nil ? .shared : nil
        )
        let translationRepository = (resolvedRepository as? any TranslationRepository)
            ?? UnavailableTranslationRepository()
        let translation = TranslationSessionController(
            repository: translationRepository,
            selectionDefaults: resolvedSettings.translationSelectionDefaults
        )
        let readingRepository = (resolvedRepository as? any ReadingRepository)
            ?? UnavailableReadingRepository()
        let reading = ReadingSessionController(repository: readingRepository, settings: resolvedSettings)
        let editor = LyricsEditorSessionController(
            repository: resolvedRepository as? any LyricsEditingRepository
        )
        self.lyricsSession = session
        self.searchPreviewSession = previewSession
        self.translationSession = translation
        self.readingSession = reading
        self.lyricsEditorSession = editor
        // Track search is metadata-only: saved library, local index and current track.
        // LRCLIB stays isolated inside the lyrics session path.
        self.songSearchManager = SongSearchManager(providers: [
            LocalSearchProvider(index: sharedIndex, savedSearch: { query in
                guard let library = resolvedRepository as? SQLiteLyricsRepository else { return [] }
                let entries = try await library.loadPersonalLibraryEntries(searchQuery: query.text)
                return entries.map { entry in
                    let track = Track(id: "library:\(entry.trackStableKey)", title: entry.title, artist: entry.artist,
                        album: entry.album ?? "", duration: entry.duration, isrc: entry.isrc,
                        spotifyId: entry.spotifyTrackID, artworkURL: entry.artworkURL, spotifyURL: entry.spotifyURI.flatMap(URL.init(string:)))
                    return TrackSearchResult(id: "library:\(entry.trackStableKey)", source: .local, track: track,
                        confidence: max(0.6, SongSearchScoring.score(track: track, query: query)), artworkURL: entry.artworkURL)
                }
            }),
            CurrentTrackResolver(playbackProvider: resolvedProvider),
            SpotifySearchProvider(authorization: authorizationManager)
        ] as [TrackSearchProvider])
        self.lyricsSessionCancellable = nil
        self.searchPreviewSessionCancellable = nil
        self.translationSessionCancellable = nil
        self.readingSessionCancellable = nil
        self.lyricsEditorSessionCancellable = nil
        self.spotifyAuthorizationCancellable = nil
        session.$activeLyricsVersionID
            .dropFirst()
            .sink { [weak self] versionID in
                // @Published emits the next value before the session stores
                // it. Invalidate/retarget the offset binding synchronously so
                // an older resolver completion cannot revive the previous
                // saved-version scope in this will-set window.
                self?.syncLiveLyricsOffsetScope(lyricsVersionID: versionID)
            }
            .store(in: &self.settingsCancellables)
        self.lyricsSessionCancellable = session.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
            // `@Published` emits objectWillChange before the session property
            // is mutated. Forwarding only that pre-change pulse can leave a
            // paused UI showing the previous loading/no-match state forever;
            // publish once on the next main-actor turn after the mutation too.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.objectWillChange.send()
                self.syncTranslationSession()
                self.syncPublishedLineIndex(source: .lyricsSession)
                self.syncLiveLyricsOffsetScope()
                // Product auto-align must re-evaluate after lyrics settle
                // (plain document / version id), not only on willChange races.
                AutomaticAlignmentJobController.shared.notePlaybackContextChanged()
            }
        }
        self.searchPreviewSessionCancellable = previewSession.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.objectWillChange.send()
                self?.syncTranslationSession()
            }
        }
        self.translationSessionCancellable = translation.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        self.readingSessionCancellable = reading.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        self.lyricsEditorSessionCancellable = editor.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        editor.onSaved = { [weak self] result, identity in
            self?.applyLyricsEditorResult(result, identity: identity)
        }
        editor.isStillCurrent = { [weak self, weak editor] in
            guard let self, let editor else { return false }
            return self.hasLiveTrack
                && !self.isMockPreviewMode
                && self.currentTrackIdentity == editor.currentIdentity
                && self.lyricsSession.revision == editor.currentSourceRevision
        }
        // The search popover observes PlaybackState. Forward the nested
        // authorization manager's state changes so Client ID, authorizing,
        // authorized, failure, and disconnect states become visible without
        // requiring the popover to be recreated.
        self.spotifyAuthorizationCancellable = authorizationManager.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }

        resolvedSettings.$displayPreferences
            .sink { [weak self] preferences in
                guard let self, self.preferences != preferences else { return }
                self.preferences = preferences
            }
            .store(in: &self.settingsCancellables)
        // AppSettingsStore is the single user-facing source of truth. The
        // legacy LyricsPreferencesPopover remains source-compatible, but is
        // no longer a live entry point; keeping a second reverse publisher
        // here creates a synchronous Published feedback loop when a Picker or
        // Toggle mutates a value-type DisplayPreferences.
        resolvedSettings.$keepMainWindowOnTop
            .sink { [weak self] keepOnTop in
                guard let self, self.preferences.alwaysOnTop != keepOnTop else { return }
                self.preferences.alwaysOnTop = keepOnTop
            }
            .store(in: &self.settingsCancellables)
        resolvedSettings.$lyricsProviderConfiguration
            .dropFirst()
            .sink { [weak self] configuration in
                guard let self, self.usesConfiguredLyricsProviders else { return }
                self.applyLyricsProviderConfiguration(
                    configuration,
                    mode: resolvedSettings.lyricsSourceMode
                )
            }
            .store(in: &self.settingsCancellables)
        resolvedSettings.$lyricsSourceModeRawValue
            .dropFirst()
            .sink { [weak self] rawValue in
                guard let self, self.usesConfiguredLyricsProviders else { return }
                // Use the emitted raw value — not a re-read that can race with
                // batched settings updates during acceptance / UI toggles.
                let mode = LyricsSourceMode(rawValue: rawValue) ?? .default
                self.applyLyricsProviderConfiguration(
                    resolvedSettings.lyricsProviderConfiguration,
                    mode: mode
                )
            }
            .store(in: &self.settingsCancellables)
        resolvedSettings.$aiTranslationConfiguration
            .dropFirst()
            .sink { [weak self] configuration in
                guard let self else { return }
                self.syncTranslationSession(configuration: configuration)
            }
            .store(in: &self.settingsCancellables)
        resolvedSettings.$readingPreferences
            .dropFirst()
            .sink { [weak self] preferences in
                guard let self else { return }
                // Published emits before storage changes; the asynchronous
                // reload observes the new preferences. Only the separate
                // automatic-AI opt-in may generate on an AI permission change.
                self.readingSession.reload(allowAutomaticGeneration:
                    preferences.automaticAIOptimization ||
                    preferences.aiAssistedCandidate == resolvedSettings.readingPreferences.aiAssistedCandidate)
                self.objectWillChange.send()
            }
            .store(in: &self.settingsCancellables)
        resolvedSettings.$connectSpotifyOnLaunch
            .dropFirst()
            .sink { [weak self] shouldConnect in
                guard let self, shouldConnect else { return }
                self.reconnectSpotify()
            }
            .store(in: &self.settingsCancellables)
        resolvedSettings.$playbackSourceMode
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                self.reconnectSpotify()
            }
            .store(in: &self.settingsCancellables)
        resolvedSettings.lyricsOffsetStore.$activeOffset
            .dropFirst()
            .sink { [weak self] newOffset in
                guard let self else { return }
                // @Published invokes this closure during its will-set window;
                // the settings getter may still expose the old value here.
                // Carry the emitted value explicitly into the lyric projection.
                self.syncPublishedLineIndex(
                    source: .presentationOffset,
                    presentationOffset: newOffset
                )
                self.objectWillChange.send()
            }
            .store(in: &self.settingsCancellables)
    }


    private static func makeDefaultLyricsProviders(
        index: LocalLyricsIndex,
        configuration: LyricsProviderConfiguration,
        mode: LyricsSourceMode = .default
    ) -> [LyricsProvider] {
        var providers: [LyricsProvider] = []
        // Mode is the hard gate: experimental IDs never enter the chain under
        // standard free, even if still listed as "enabled" in preferences.
        for id in configuration.orderedEnabledIDs(for: mode) {
            switch id {
            case .localFiles:
                providers.append(LocalLyricsProvider(index: index))
            case .sqliteDatabase:
                // SQLite is consulted by LyricsSessionController before this
                // manager; it is kept in the order model for clear UI state.
                continue
            case .amll:
                guard ProcessInfo.processInfo.environment["SPOTIFYLYRICS_DISABLE_AMLL"] != "1" else {
                    LyricsE2ELog.log("Lyrics provider disabled by environment: AMLL")
                    continue
                }
                providers.append(AMLLLyricsProvider())
            case .lrclib:
                guard ProcessInfo.processInfo.environment["SPOTIFYLYRICS_DISABLE_LRCLIB"] != "1" else {
                    LyricsE2ELog.log("Lyrics provider disabled by environment: LRCLIB")
                    continue
                }
                providers.append(LRCLIBLyricsProvider())
            case .netEaseExperimental:
                guard ProcessInfo.processInfo.environment["SPOTIFYLYRICS_DISABLE_NETEASE"] != "1" else {
                    continue
                }
                providers.append(NetEaseExperimentalLyricsProvider())
            case .qqExperimental:
                guard ProcessInfo.processInfo.environment["SPOTIFYLYRICS_DISABLE_QQ"] != "1" else {
                    continue
                }
                providers.append(QQExperimentalLyricsProvider())
            case .linkcore:
                guard ProcessInfo.processInfo.environment["SPOTIFYLYRICS_DISABLE_LINKCORE"] != "1" else { continue }
                providers.append(LinkCoreLyricsProvider())
            case .lyricsOVH:
                guard ProcessInfo.processInfo.environment["SPOTIFYLYRICS_DISABLE_LYRICSOVH"] != "1" else { continue }
                providers.append(LyricsOVHProvider())
            case .kuwoExperimental:
                guard ProcessInfo.processInfo.environment["SPOTIFYLYRICS_DISABLE_KUWO"] != "1" else { continue }
                providers.append(KuwoExperimentalLyricsProvider())
            case .kugouExperimental:
                guard ProcessInfo.processInfo.environment["SPOTIFYLYRICS_DISABLE_KUGOU"] != "1" else { continue }
                providers.append(KugouExperimentalLyricsProvider())
            }
        }
        // A corrupted/legacy preference must not remove the read-only local
        // source from the runtime chain.
        if !providers.contains(where: { $0 is LocalLyricsProvider }) {
            providers.insert(LocalLyricsProvider(index: index), at: 0)
        }
        LyricsE2ELog.log(
            "Lyrics providers for mode=\(mode.rawValue): " + providers.map(\.name).joined(separator: ",")
        )
        return providers
    }

    deinit {
        timer?.invalidate()
        providerRefreshTask?.cancel()
        persistencePreparationTask?.cancel()
        networkRecoveryMonitor?.cancel()
        lyricsSessionCancellable?.cancel()
        searchPreviewSessionCancellable?.cancel()
        translationSessionCancellable?.cancel()
        readingSessionCancellable?.cancel()
        lyricsEditorSessionCancellable?.cancel()
        spotifyAuthorizationCancellable?.cancel()
        searchPreviewTask?.cancel()
    }

    /// Lyrics preview for a searched track is kept separate from the live
    /// Spotify session. This prevents selecting a catalog result from changing
    /// the current-track identity, playback position, or Desktop commands.
    public var isShowingSearchPreview: Bool { searchPreviewTrack != nil }
    public var displayedTrack: Track { searchPreviewTrack ?? currentTrack }
    public var lyrics: [LyricLine] {
        if isShowingSearchPreview {
            return projectedLyrics(
                base: searchPreviewSession.lyrics,
                session: searchPreviewSession,
                cache: &previewLyricsProjectionCache
            )
        }
        return liveLyrics
    }

    /// The only lyric projection that a secondary window may consume.  It
    /// deliberately ignores search-preview state so an unplayed catalog
    /// result can never appear in the floating window.
    public var liveLyrics: [LyricLine] {
        guard liveLyricsDocumentMatchesCurrentTrack else { return [] }
        return projectedLyrics(
            base: lyricsSession.lyrics,
            session: lyricsSession,
            cache: &liveLyricsProjectionCache
        )
    }
    public var lyricsState: LyricsLoadState {
        isShowingSearchPreview ? searchPreviewSession.state : lyricsSession.state
    }
    public var isAutomaticSearchDisabledForDisplayedSession: Bool {
        !isShowingSearchPreview && lyricsSession.automaticSearchDisabledForCurrentTrack
    }
    public var lyricsAreSynchronized: Bool {
        isShowingSearchPreview ? searchPreviewSession.isSynchronized : lyricsSession.isSynchronized
    }
    public var lyricsSessionRevision: UInt64 {
        isShowingSearchPreview ? searchPreviewSession.revision : lyricsSession.revision
    }
    /// Identity of the current Desktop playback snapshot, independent from
    /// the session's last adopted document.  During the synchronous handoff
    /// between a provider track update and `lyricsSession.begin`, these two
    /// identities can briefly differ; live projections must fail closed then.
    public var liveTrackIdentity: TrackIdentity? {
        guard hasLiveTrack, !isMockPreviewMode else { return nil }
        return TrackIdentity(track: currentTrack)
    }

    /// Shared source/identity capability boundary for the existing live
    /// capture implementation. Local-file alignment intentionally does not
    /// consult this gate.
    public func liveCaptureEligibility(requiresPlaying: Bool = true) -> AutomaticLiveCaptureEligibility {
        AutomaticLiveCaptureSourceGate.evaluate(
            AutomaticLiveCaptureContext(
                source: playbackSourceIdentity,
                providerIsReady: providerStatus.isReady,
                hasLiveTrack: hasLiveTrack,
                isMockPreview: isMockPreviewMode,
                isPlaying: isPlaying,
                identityKey: liveTrackIdentity?.stableKey
            ),
            requiresPlaying: requiresPlaying
        )
    }

    public var liveLyricsDocumentMatchesCurrentTrack: Bool {
        guard let liveTrackIdentity else { return false }
        return lyricsSession.activeIdentity == liveTrackIdentity
    }

    public var liveLyricsState: LyricsLoadState {
        guard liveLyricsDocumentMatchesCurrentTrack else {
            guard let identity = liveTrackIdentity else { return .idle }
            return .loading(identity)
        }
        return lyricsSession.state
    }
    public var liveLyricsAreSynchronized: Bool {
        liveLyricsDocumentMatchesCurrentTrack && lyricsSession.isSynchronized
    }
    public var liveTrackIsMarkedInstrumental: Bool {
        liveLyricsDocumentMatchesCurrentTrack && lyricsSession.isMarkedInstrumental
    }
    public var liveLyricsSessionRevision: UInt64 { lyricsSession.revision }
    public var liveLyricsLanguage: String? {
        liveLyricsDocumentMatchesCurrentTrack ? lyricsSession.activeDocument?.language : nil
    }
    public var liveLyricsVersionID: UUID? {
        liveLyricsDocumentMatchesCurrentTrack ? lyricsSession.activeLyricsVersionID : nil
    }
    public var liveLyricsSource: LyricsSource? {
        liveLyricsDocumentMatchesCurrentTrack ? lyricsSession.activeDocument?.source : nil
    }
    public var isLyricsSelectionEmpty: Bool {
        lyricsSession.isNoSelection || lyricsSession.activeLyricsVersionID == nil
    }
    public var currentTrackIdentity: TrackIdentity? {
        guard hasLiveTrack, !isMockPreviewMode else { return nil }
        return lyricsSession.activeIdentity
    }

    /// A lyric row may seek only when its displayed document belongs to the
    /// current playback identity. Search preview remains displayable, but it
    /// must not control another track that is currently playing.
    public var canSeekDisplayedLyrics: Bool {
        guard isShowingSearchPreview else { return true }
        guard let liveTrackIdentity else { return false }
        return TrackIdentity(track: displayedTrack) == liveTrackIdentity
    }

    /// Revisions belong to separate live and search-preview sessions. The
    /// origin selects which session to check, never bypassing the preview gate.
    public enum LyricsSeekDocumentSource {
        case live
        case searchPreview
    }

    /// Shared lyric-row seek boundary for V3 and the classic canvas. A row
    /// carries the identity/revision captured when its document was rendered.
    /// Ordinary transport controls still use `seek(to:source:)` directly.
    @discardableResult
    public func seekFromDisplayedLyrics(
        to position: TimeInterval,
        documentIdentity: TrackIdentity,
        documentRevision: UInt64,
        documentSource: LyricsSeekDocumentSource,
        source: String
    ) -> Bool {
        guard canSeekDisplayedLyrics,
              documentIdentity == TrackIdentity(track: currentTrack) else { return false }
        let activeIdentity: TrackIdentity?
        let currentRevision: UInt64
        switch documentSource {
        case .live:
            // Explicit Mock Preview has no session identity, but retains its
            // existing local row-seeking capability and revision boundary.
            activeIdentity = isMockPreviewMode
                ? TrackIdentity(track: currentTrack)
                : lyricsSession.activeIdentity
            currentRevision = lyricsSession.revision
        case .searchPreview:
            guard isShowingSearchPreview else { return false }
            activeIdentity = searchPreviewSession.activeIdentity
            currentRevision = searchPreviewSession.revision
        }
        guard activeIdentity == documentIdentity,
              currentRevision == documentRevision else { return false }
        seek(to: position, source: source)
        return true
    }

    public var translationState: TranslationSessionState { translationSession.state }
    public var translationVersions: [StoredTranslationVersion] { translationSession.availableVersions }
    public var selectedTranslation: StoredTranslationVersion? { translationSession.selectedVersion }
    public var translationSessionPendingCandidate: StoredTranslationVersion? { translationSession.pendingCandidate }
    public var translationProgressMessage: String { translationSession.progressMessage }
    public var isTranslationSelectionEmpty: Bool { translationSession.isNoSelection }
    public var readingProjection: ReadingProjection { readingSession.projection }
    public var readingVersions: [StoredReadingVersion] { readingSession.availableVersions }
    public var selectedReadingVersion: StoredReadingVersion? { readingSession.selectedVersion }
    public var isReadingGenerating: Bool { readingSession.isGenerating }
    public var readingMessage: String { readingSession.message }

    public var canOpenLyricsEditor: Bool {
        hasLiveTrack && !isMockPreviewMode && lyricsSession.activeIdentity != nil &&
            lyricsSession.activeDocument != nil && lyricsSession.activeLyricsVersionID != nil &&
            lyricsSession.activeSourceContentHash != nil
    }

    /// A no-body/no-match session still has a stable current TrackIdentity,
    /// so the user can create a local source without pretending that a
    /// Provider found lyrics.
    public var canCreateManualLyrics: Bool {
        guard hasLiveTrack, !isMockPreviewMode, lyricsSession.activeIdentity != nil else { return false }
        switch lyricsSession.state {
        case .noLyrics, .noSelection, .noMatch, .failed, .candidates:
            return true
        default:
            return false
        }
    }

    public var lyricsEditor: LyricsEditorSessionController { lyricsEditorSession }

    /// Reads the saved lyric versions for the live track without changing the
    /// current projection. Unsupported repositories fail closed as an empty
    /// list so the caller cannot invent a version source.
    public func loadCurrentLyricsVersions() async throws -> [StoredEditableLyricsVersion] {
        guard hasLiveTrack,
              let identity = currentTrackIdentity,
              liveTrackIdentity == identity,
              let repository = lyricsRepository as? any LyricsEditingRepository else {
            return []
        }
        return try await repository.loadEditableVersions(track: currentTrack, identity: identity)
    }

    /// Persists and applies one existing version for the current track. The
    /// document is loaded and identity-checked before the live session changes,
    /// so repository failures leave the current lyrics untouched.
    @discardableResult
    public func adoptCurrentLyricsVersion(versionID: UUID) async throws -> Bool {
        guard !isShowingSearchPreview, hasLiveTrack,
              let identity = currentTrackIdentity,
              liveTrackIdentity == identity,
              let repository = lyricsRepository as? any LyricsEditingRepository else {
            return false
        }

        let track = currentTrack
        let revision = lyricsSession.revision
        guard let stored = try await repository.loadEditableVersion(
            versionID: versionID,
            track: track,
            identity: identity
        ),
        stored.document.identity == identity,
        currentTrackIdentity == identity, lyricsSession.revision == revision else {
            return false
        }

        try await repository.adoptLyricsVersion(
            trackStableKey: identity.stableKey,
            lyricsVersionID: stored.record.id
        )

        guard currentTrackIdentity == identity, lyricsSession.revision == revision else { return false }
        applyLyricsEditorResult(
            LyricsEditSaveResult(lyricsVersion: stored, translationVersion: nil),
            identity: identity
        )
        return true
    }

    public func openLibraryTool(tab: LibraryToolTab = .library) {
        selectedLibraryToolTab = tab
    }

    public func prepareLyricsEditorForOpening() {
        guard hasLiveTrack else {
            lyricsEditorSession.beginDetached()
            return
        }

        if canOpenLyricsEditor {
            prepareLyricsEditor()
        } else if canCreateManualLyrics {
            prepareBlankLyricsEditor()
        }
    }

    public func prepareLyricsEditor() {
        guard canOpenLyricsEditor,
              let identity = lyricsSession.activeIdentity,
              let document = lyricsSession.activeDocument,
              let versionID = lyricsSession.activeLyricsVersionID,
              let sourceHash = lyricsSession.activeSourceContentHash else {
            songSearchSelectionMessage = "当前歌词版本还未完成保存，稍后再打开编辑器"
            return
        }
        lyricsEditorSession.begin(
            track: currentTrack,
            identity: identity,
            document: document,
            lyricsVersionID: versionID,
            sourceContentHash: sourceHash,
            revision: lyricsSession.revision,
            translations: translationSession.availableVersions,
            selectedTranslation: translationSession.selectedVersion,
            configuration: settingsStore.aiTranslationConfiguration
        )
    }

    @discardableResult
    public func prepareBlankLyricsEditor() -> Bool {
        guard canCreateManualLyrics,
              let identity = lyricsSession.activeIdentity else {
            songSearchSelectionMessage = "当前歌曲仍有可用歌词版本，或尚未确认当前歌曲"
            return false
        }
        let document = LyricsDocument(
            identity: identity,
            title: currentTrack.title,
            artist: currentTrack.artist,
            album: currentTrack.album,
            duration: currentTrack.duration,
            lines: [LyricLine(timestamp: 0, originalText: "")],
            isSynchronized: false,
            source: .manualCreate,
            confidence: 1,
            spotifyTrackID: identity.spotifyTrackID,
            isrc: identity.isrc
        )
        lyricsEditorSession.beginNew(
            track: currentTrack,
            identity: identity,
            document: document,
            source: .manualCreate,
            revision: lyricsSession.revision,
            configuration: settingsStore.aiTranslationConfiguration
        )
        return true
    }

    @discardableResult
    public func prepareManualLyricsFromClipboard() -> Bool {
        guard let text = NSPasteboard.general.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              prepareBlankLyricsEditor() else {
            songSearchSelectionMessage = "剪贴板中没有可导入的歌词文本"
            return false
        }
        lyricsEditorSession.prepareTextImport(text, source: .manualCreate)
        return lyricsEditorSession.pendingTextImport != nil
    }

    @discardableResult
    public func prepareManualLyricsFromTXT() -> Bool {
        guard canCreateManualLyrics else {
            songSearchSelectionMessage = "当前歌曲还没有进入无歌词恢复状态"
            return false
        }
        let panel = NSOpenPanel()
        panel.title = "导入纯文本歌词"
        panel.message = "选择 TXT 文件；原文件不会被修改"
        panel.allowedContentTypes = [UTType.plainText, UTType.text]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            let data = try Data(contentsOf: url)
            guard prepareBlankLyricsEditor() else { return false }
            lyricsEditorSession.prepareTextImport(data: data, source: .manualImport)
            return lyricsEditorSession.pendingTextImport != nil
        } catch {
            songSearchSelectionMessage = "TXT 读取失败：\(error.localizedDescription)"
            return false
        }
    }

    /// Opens the existing LRC parser from the same no-source recovery entry
    /// point.  The file is read into the editor preview only; the original
    /// file is never copied, renamed, or modified here.
    @discardableResult
    public func prepareManualLyricsFromLRC() -> Bool {
        guard canCreateManualLyrics else {
            songSearchSelectionMessage = "当前歌曲还没有进入无歌词恢复状态"
            return false
        }
        let panel = NSOpenPanel()
        panel.title = "导入同步歌词"
        panel.message = "选择 LRC 文件；原文件不会被修改"
        panel.allowedContentTypes = [UTType(filenameExtension: "lrc") ?? .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            let data = try Data(contentsOf: url)
            let content = try Self.decodeTextFile(data)
            guard prepareBlankLyricsEditor() else { return false }
            lyricsEditorSession.prepareImport(content)
            return lyricsEditorSession.pendingImport != nil
        } catch {
            songSearchSelectionMessage = "LRC 读取失败：\(error.localizedDescription)"
            return false
        }
    }

    private static func decodeTextFile(_ data: Data) throws -> String {
        if let result = try? TextLyricsImportParser.parse(data) {
            return result.normalizedText
        }
        throw TextLyricsImportError.unsupportedEncoding
    }

    private func applyLyricsEditorResult(_ result: LyricsEditSaveResult, identity: TrackIdentity) {
        guard hasLiveTrack, currentTrackIdentity == identity else {
            lyricsEditorSession.markStale()
            return
        }
        if let stored = result.lyricsVersion {
            lyricsSession.adoptPersisted(
                document: stored.document,
                versionID: stored.record.id,
                sourceContentHash: stored.sourceContentHash
            )
        }
        translationSession.reloadCurrentContext()
        lyricsEditorSession.updateSourceRevision(lyricsSession.revision)
        objectWillChange.send()
    }

    public func translateCurrentLyrics() { translationSession.translateCurrentLyrics() }
    public func retranslateCurrentLyrics() { translationSession.retranslateCurrentLyrics() }
    public func selectTranslation(versionID: UUID) { translationSession.select(versionID: versionID) }
    public func selectNoTranslationVersion() { translationSession.selectNone() }
    public var liveLyricsCandidates: [LyricsCandidate] {
        guard liveLyricsDocumentMatchesCurrentTrack else { return [] }
        if !lyricsSession.availableCandidates.isEmpty || !lyricsSession.additionalVersionsMessage.isEmpty {
            return lyricsSession.availableCandidates
        }
        if case .candidates(_, let candidates) = lyricsSession.state { return candidates }
        return []
    }
    public var isSearchingAdditionalLyricsVersions: Bool {
        liveLyricsDocumentMatchesCurrentTrack && lyricsSession.isSearchingAdditionalVersions
    }
    public var additionalLyricsVersionsMessage: String {
        liveLyricsDocumentMatchesCurrentTrack ? lyricsSession.additionalVersionsMessage : ""
    }
    public func searchAdditionalLyricsVersions() {
        guard !isShowingSearchPreview, hasLiveTrack, let identity = liveTrackIdentity,
              currentTrackIdentity == identity else { return }
        lyricsSession.searchAdditionalVersions(track: currentTrack, identity: identity)
    }
    public var originalLiveLyrics: [LyricLine] {
        liveLyricsDocumentMatchesCurrentTrack ? (lyricsSession.activeDocument?.lines ?? []) : []
    }
    public func lockSelectedTranslation() { translationSession.lockSelected() }
    public func deleteSelectedTranslation() { translationSession.deleteSelected() }
    public func adoptTranslation(versionID: UUID) { translationSession.adoptTranslation(versionID: versionID) }
    public func archiveTranslation(versionID: UUID) { translationSession.archiveTranslation(versionID: versionID) }
    public func cancelTranslation() { translationSession.cancel() }
    public func restoreRecommendedTranslation() { translationSession.restoreRecommended() }

    /// Explicitly clears the live lyric projection for this session without
    /// deleting any stored LyricsVersion.
    @discardableResult
    public func revokeCurrentLyricsVersion(versionID: UUID) async throws -> Bool {
        guard let identity = currentTrackIdentity, liveTrackIdentity == identity else { return false }
        return try await lyricsSession.revokeCurrentVersion(identity: identity, versionID: versionID)
    }

    public func selectNoLyricsVersion() {
        guard let identity = currentTrackIdentity else { return }
        lyricsSession.selectNoVersion(identity: identity)
    }

    public func markCurrentTrackAsInstrumental() {
        guard !isShowingSearchPreview, let identity = liveTrackIdentity, currentTrackIdentity == identity else { return }
        lyricsSession.markAsInstrumental(identity: identity)
        objectWillChange.send()
    }

    public func clearCurrentInstrumentalMark() {
        guard !isShowingSearchPreview, let identity = liveTrackIdentity, currentTrackIdentity == identity else { return }
        lyricsSession.clearInstrumentalMark(identity: identity)
    }

    public func selectNoReadingVersion() { readingSession.selectNone() }
    public func selectReadingVersion(versionID: UUID) { readingSession.select(versionID: versionID) }
    public func generateCurrentReading(representationID: ReadingRepresentationID? = nil) {
        readingSession.generateCurrentReading(representationID: representationID)
    }
    public func requestAIReadingCandidate() {
        guard !isShowingSearchPreview else { return }
        readingSession.generateCurrentReading(allowAICandidate: true)
    }
    public func lockSelectedReading() { readingSession.lockSelected() }
    public func archiveReading(versionID: UUID) { readingSession.archive(versionID: versionID) }
    public func deleteReading(versionID: UUID) { readingSession.delete(versionID: versionID) }
    public func restoreRecommendedReading() { readingSession.restoreRecommended() }

    private func syncTranslationSession(configuration incoming: AITranslationConfiguration? = nil) {
        let configuration = incoming ?? settingsStore.aiTranslationConfiguration
        translationSession.setEngine(
            TranslationEngineRegistry.make(stableID: configuration.engineID)
        )
        translationSession.synchronize(
            document: lyricsSession.activeDocument,
            lyricsVersionID: lyricsSession.activeLyricsVersionID,
            sourceContentHash: lyricsSession.activeSourceContentHash,
            configuration: configuration
        )
        syncReadingSession()
    }

    private func syncReadingSession() {
        guard let document = lyricsSession.activeDocument,
              let versionID = lyricsSession.activeLyricsVersionID,
              let sourceHash = lyricsSession.activeSourceContentHash else {
            readingSession.clear()
            return
        }
        readingSession.synchronize(
            lyricsVersionID: versionID,
            sourceContentHash: sourceHash,
            lines: document.lines,
            language: document.language,
            trackStableKey: lyricsSession.activeIdentity?.stableKey,
            artistDisplay: document.artist
        )
    }

    public var canControlSpotify: Bool {
        providerStatus.isReady && hasLiveTrack && !isMockPreviewMode
    }

    /// True only after the user explicitly enters Mock Preview.
    public var isUsingMockPreview: Bool { isMockPreviewMode }

    public var canInteractWithPlayback: Bool {
        canControlSpotify || isMockPreviewMode
    }

    public var providerStatusMessage: String {
        if isMockPreviewMode {
            return "Mock Preview"
        }
        let message = providerStatus.userFacingMessage(for: provider.displayName)
        if providerStatus.isReady, hasLiveTrack {
            return message
        }
        return "\(message) · 未进入 Mock Preview"
    }

    public var lyricsStatusMessage: String {
        let session = isShowingSearchPreview ? searchPreviewSession : lyricsSession
        return statusMessage(for: session)
    }

    public var liveLyricsStatusMessage: String {
        statusMessage(for: lyricsSession)
    }

    private func statusMessage(for session: LyricsSessionController) -> String {
        if let persistenceStatus = session.persistenceStatusMessage, !persistenceStatus.isEmpty {
            let stateMessage = session.state.userFacingMessage
            return stateMessage.isEmpty ? persistenceStatus : "\(stateMessage) · \(persistenceStatus)"
        }
        if let document = session.activeDocument,
            document.source == .automaticAlignment,
            session.alignmentProvenanceAvailability == .unavailable {
            return "\(session.state.userFacingMessage.isEmpty ? "已加载排轴歌词" : session.state.userFacingMessage) · provenance unavailable"
        }
        return session.state.userFacingMessage
    }

    public func refreshListeningHistory() {
        listeningHistoryLoadTask?.cancel()
        isListeningHistoryLoading = true
        listeningHistoryError = nil
        let repository = lyricsRepository
        listeningHistoryLoadTask = Task { @MainActor [weak self, repository] in
            do {
                let entries = try await repository.loadListeningHistory(limit: 100)
                guard !Task.isCancelled, let self else { return }
                self.listeningHistory = Self.mergeHistoryEntries(entries, with: self.listeningHistory)
                self.isListeningHistoryLoading = false
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.listeningHistoryError = "无法读取最近播放记录，请重试。"
                self.isListeningHistoryLoading = false
            }
        }
    }

    public func refreshListeningStatistics(for timeRange: ListeningStatisticsTimeRange) {
        listeningStatisticsLoadTask?.cancel()
        isListeningStatisticsLoading = true
        listeningStatisticsError = nil
        let repository = lyricsRepository
        let pendingWrite = listeningHistoryWriteTask
        listeningStatisticsLoadTask = Task { @MainActor [weak self, repository] in
            do {
                await pendingWrite?.value
                let statistics = try await repository.loadListeningStatistics(for: timeRange)
                guard !Task.isCancelled, let self else { return }
                self.listeningStatistics = statistics
                self.isListeningStatisticsLoading = false
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.listeningStatisticsError = "无法读取听歌统计，请重试。"
                self.isListeningStatisticsLoading = false
            }
        }
    }

    private func publishListeningHistory(_ entry: ListeningHistoryEntry) {
        listeningHistory = Self.mergeHistoryEntries(listeningHistory, with: [entry])

        let previousTask = listeningHistoryWriteTask
        let repository = lyricsRepository
        listeningHistoryWriteTask = Task { [previousTask, repository] in
            _ = await previousTask?.value
            try? await repository.upsertListeningHistory(entry)
        }
    }

    private static func mergeHistoryEntries(
        _ loaded: [ListeningHistoryEntry],
        with current: [ListeningHistoryEntry]
    ) -> [ListeningHistoryEntry] {
        var entriesByID: [UUID: ListeningHistoryEntry] = [:]
        for entry in loaded {
            entriesByID[entry.sessionID] = entry
        }
        for entry in current {
            var enriched = entry
            enriched.artworkURL = entry.artworkURL ?? entriesByID[entry.sessionID]?.artworkURL
            entriesByID[entry.sessionID] = enriched
        }
        return entriesByID.values.sorted { lhs, rhs in
            if lhs.startedAt != rhs.startedAt {
                return lhs.startedAt > rhs.startedAt
            }
            return lhs.sessionID.uuidString > rhs.sessionID.uuidString
        }
    }

    public func startProvider() {
        startProvider(connectSpotify: true)
    }

    public func startProvider(connectSpotify: Bool) {
        guard !isProviderStarted else { return }
        isProviderStarted = true
        automaticSpotifyConnectionEnabled = connectSpotify
        startTimer()
        startNetworkRecoveryMonitor()
        refreshListeningHistory()
        persistencePreparationTask = Task { [weak self, lyricsRepository] in
            do {
                try await lyricsRepository.prepare()
                LyricsE2ELog.log("PERSISTENCE startup ready")
            } catch {
                LyricsE2ELog.log("PERSISTENCE startup failed error=\(error.localizedDescription)")
                await MainActor.run {
                    self?.objectWillChange.send()
                }
            }
        }
        if connectSpotify {
            providerRefreshTask = Task { @MainActor [weak self] in
                await self?.refreshProvider()
            }
        } else {
            providerStatus = .unavailable("已在设置中关闭启动连接")
        }
        // Zero-operation automatic alignment (product path; independent of Assist).
        AutomaticAlignmentJobController.shared.bind(playback: self)
#if DEBUG
        startAcceptanceControlPollingIfNeeded()
#endif
    }

#if DEBUG
    private func startAcceptanceControlPollingIfNeeded() {
        let path = ProcessInfo.processInfo.environment["SPOTIFYLYRICS_ACCEPTANCE_CONTROL_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !path.isEmpty else { return }
        LyricsE2ELog.log("ACCEPTANCE control polling path=\(path)")
        acceptanceControlTimer?.invalidate()
        acceptanceControlTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollAcceptanceControlFile(path: path)
            }
        }
    }

    private func pollAcceptanceControlFile(path: String) {
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        let payload = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty, payload != acceptanceControlLastPayload else { return }
        acceptanceControlLastPayload = payload
        LyricsE2ELog.log("ACCEPTANCE control apply payload=\(payload.replacingOccurrences(of: "\n", with: " | "))")

        var wantsRetry = false
        var wantsAssistStart = false
        var wantsAssistCancel = false
        var wantsAssistSave = false
        var assistSeconds: TimeInterval = 55
        var assistMarkCount = 0
        for line in payload.split(whereSeparator: \.isNewline) {
            let token = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { continue }
            let lower = token.lowercased()
            if lower == "retry" {
                wantsRetry = true
                continue
            }
            if lower == "a" || lower == "standard" || token == LyricsSourceMode.standardFree.rawValue {
                applyAcceptanceMode(.standardFree)
                continue
            }
            if lower == "b" || lower == "experimental" || token == LyricsSourceMode.experimentalFree.rawValue {
                applyAcceptanceMode(.experimentalFree)
                continue
            }
            // DEBUG-only acceptance harness for Assist E2E (no product UI change).
            if lower == "assist" || lower == "assist_start" {
                wantsAssistStart = true
                continue
            }
            if lower == "assist_cancel" {
                wantsAssistCancel = true
                continue
            }
            if lower == "assist_save" {
                wantsAssistSave = true
                continue
            }
            if lower.hasPrefix("assist_seconds=") {
                let raw = String(lower.dropFirst("assist_seconds=".count))
                if let v = Double(raw), v >= 20 { assistSeconds = v }
                continue
            }
            if lower.hasPrefix("assist_mark=") {
                let raw = String(lower.dropFirst("assist_mark=".count))
                if let v = Int(raw), v > 0 { assistMarkCount = min(v, 40) }
                continue
            }
            if lower == "assist_make_plain" {
                acceptanceAssistMakePlain()
                continue
            }
            if lower == "assist_undo" {
                lyricsEditorSession.undo()
                LyricsE2ELog.log("ACCEPTANCE control assist_undo")
                continue
            }
            if lower == "assist_redo" {
                lyricsEditorSession.redo()
                LyricsE2ELog.log("ACCEPTANCE control assist_redo")
                continue
            }
            LyricsE2ELog.log("ACCEPTANCE control ignore token=\(token)")
        }
        // Mode rebuild must finish before a retry so the next MANAGER start
        // uses the gate that was just selected.
        if wantsRetry {
            let posBefore = currentTime
            let identityBefore = currentTrackIdentity?.stableKey ?? ""
            retryLyrics()
            LyricsE2ELog.log(
                "ACCEPTANCE control retry done identity=\(identityBefore) posBefore=\(posBefore) posAfter=\(currentTime)"
            )
        }
        if wantsAssistCancel {
            cancelListeningAssist()
            LyricsE2ELog.log("ACCEPTANCE control assist_cancel")
        }
        if wantsAssistStart {
            // Skip explain sheet in harness; product UI still shows sheet for humans.
            confirmListeningAssistAndCapture(seconds: assistSeconds)
            LyricsE2ELog.log("ACCEPTANCE control assist_start seconds=\(assistSeconds)")
        }
        if assistMarkCount > 0 {
            acceptanceAssistMark(count: assistMarkCount)
        }
        if wantsAssistSave {
            let timed = lyricsEditorSession.draft?.timedNonBlankLineCount ?? -1
            let untimed = lyricsEditorSession.draft?.untimedNonBlankLineCount ?? -1
            let dirty = lyricsEditorSession.hasUnsavedChanges
            let canSave = lyricsEditorSession.canSave
            LyricsE2ELog.log(
                "ACCEPTANCE control assist_save precheck timed=\(timed) untimed=\(untimed) dirty=\(dirty) canSave=\(canSave) draft=\(lyricsEditorSession.draft != nil) stale=\(lyricsEditorSession.isStale)"
            )
            lyricsEditorSession.confirmPartialSave = { t, u in
                LyricsE2ELog.log("ACCEPTANCE control assist_save partial timed=\(t) untimed=\(u)")
                return true
            }
            // forceCopy: treat timed draft as a new child version even if
            // projection equality edge-cases skip lyricsChanged.
            lyricsEditorSession.save(forceCopy: true)
            LyricsE2ELog.log(
                "ACCEPTANCE control assist_save invoked state=\(String(describing: lyricsEditorSession.state)) msg=\(lyricsEditorSession.message ?? "")"
            )
        }
    }

    /// Acceptance harness: mark next untimed lines with times that stay
    /// strictly between neighboring timed lines (keeps timeline validator happy).
    private func acceptanceAssistMark(count: Int) {
        guard let lines = lyricsEditorSession.draft?.lines, !lines.isEmpty else {
            LyricsE2ELog.log("ACCEPTANCE assist_mark skipped no draft")
            return
        }
        var marked = 0
        var focusID = lyricsEditorSession.draft?.nextUntimedLineID(after: nil)
        for _ in 0..<count {
            guard let lineID = focusID,
                  let index = lines.firstIndex(where: { $0.id == lineID }) else { break }
            // Bound by previous / next existing times on the draft.
            let prevTime = lines.prefix(index).reversed().compactMap(\.startTime).first
            let nextTime = lines.suffix(from: index + 1).compactMap(\.startTime).first
            let lo = (prevTime ?? -0.05) + 0.05
            let hi = (nextTime ?? (currentTrack.duration + 1)) - 0.05
            var pos = min(max(0, currentTime), max(0, currentTrack.duration))
            if hi > lo {
                pos = min(max(pos, lo), hi)
            } else if let prevTime {
                pos = prevTime + 0.05
            }
            _ = lyricsEditorSession.markLineAtPlayback(lineID: lineID, position: pos, advance: false)
            marked += 1
            focusID = lyricsEditorSession.draft?.nextUntimedLineID(after: lineID)
            seek(to: min(currentTrack.duration, pos + 0.5), source: "acceptance-assist-mark")
        }
        let issues = lyricsEditorSession.validation.errors.map(\.message).joined(separator: ";")
        LyricsE2ELog.log(
            "ACCEPTANCE assist_mark done marked=\(marked) timed=\(lyricsEditorSession.draft?.timedNonBlankLineCount ?? -1) untimed=\(lyricsEditorSession.draft?.untimedNonBlankLineCount ?? -1) canSave=\(lyricsEditorSession.canSave) errors=\(issues)"
        )
    }

    /// Acceptance harness: strip all line times and save as plain/unsynced child version
    /// so Assist can run when only a synced provider document is loaded (sample B).
    private func acceptanceAssistMakePlain() {
        prepareLyricsEditor()
        guard let lines = lyricsEditorSession.draft?.lines, !lines.isEmpty else {
            LyricsE2ELog.log("ACCEPTANCE assist_make_plain skipped no draft")
            return
        }
        for line in lines {
            lyricsEditorSession.updateLine(line.id) { row in
                row.startTime = nil
                row.endTime = nil
            }
        }
        lyricsEditorSession.confirmPartialSave = { _, _ in true }
        lyricsEditorSession.save()
        LyricsE2ELog.log(
            "ACCEPTANCE assist_make_plain saved timed=\(lyricsEditorSession.draft?.timedNonBlankLineCount ?? -1) untimed=\(lyricsEditorSession.draft?.untimedNonBlankLineCount ?? -1)"
        )
    }

    private func applyAcceptanceMode(_ mode: LyricsSourceMode) {
        settingsStore.lyricsSourceMode = mode
        // Explicit rebuild: do not rely solely on the Combine sink order when
        // the same control payload also requests RETRY.
        if usesConfiguredLyricsProviders {
            applyLyricsProviderConfiguration(
                settingsStore.lyricsProviderConfiguration,
                mode: mode
            )
        }
        LyricsE2ELog.log("ACCEPTANCE control mode=\(mode.rawValue)")
    }
#endif

    private func applyLyricsProviderConfiguration(
        _ configuration: LyricsProviderConfiguration,
        mode: LyricsSourceMode
    ) {
        let providers = Self.makeDefaultLyricsProviders(
            index: LocalLyricsIndex.shared,
            configuration: configuration,
            mode: mode
        )
        lyricsSession.updateProviders(providers)
        searchPreviewSession.updateProviders(providers)
        objectWillChange.send()
    }

    public func reconnectSpotify() {
        guard !isMockPreviewMode else { return }
        automaticSpotifyConnectionEnabled = true
        providerRefreshGeneration &+= 1
        refreshRequestedWhileBusy = true
        providerStatus = .connecting
        clearLiveTrackIfNeeded()
        providerRefreshTask?.cancel()
        providerRefreshTask = Task { @MainActor [weak self] in
            await self?.refreshProvider()
        }
    }

    public func reconnectProvider() {
        reconnectSpotify()
    }

    public func enterMockPreview() {
        providerRefreshGeneration &+= 1
        refreshRequestedWhileBusy = false
        providerRefreshTask?.cancel()
        alignmentTask?.cancel()
        clearSearchPreview()
        lyricsOffsetScopeBinding?.clear()
        isMockPreviewMode = true
        hasLiveTrack = false
        updatePlaybackSourceIdentity(.mockPreview)
        providerStatus = .mockPreview
        currentTrack = MockData.sampleTrack
        lyricsSession.enterMockPreview(lines: MockData.sampleLyrics)
        isPlaying = false
        resetPlaybackAnchor(to: 0, source: .reset)
    }

    public func exitMockPreview() {
        providerRefreshGeneration &+= 1
        refreshRequestedWhileBusy = true
        alignmentTask?.cancel()
        clearSearchPreview()
        lyricsOffsetScopeBinding?.clear()
        isMockPreviewMode = false
        hasLiveTrack = false
        updatePlaybackSourceIdentity(.unknown)
        currentTrack = .emptyPlaybackPlaceholder
        lyricsSession.clear()
        isPlaying = false
        resetPlaybackAnchor(to: 0, source: .reset)
        providerStatus = .connecting
        providerRefreshTask?.cancel()
        providerRefreshTask = Task { @MainActor [weak self] in
            await self?.refreshProvider()
        }
    }

    public func togglePlayPause() {
        if isMockPreviewMode {
            isPlaying.toggle()
            resetPlaybackAnchor(to: currentTime, source: .pauseResume)
            return
        }

        guard canControlSpotify else { return }
        invalidateProviderRefresh()
        let shouldPlay = !isPlaying
        isPlaying = shouldPlay
        resetPlaybackAnchor(to: currentTime, source: .pauseResume)
        providerRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if shouldPlay {
                    try await self.provider.play()
                } else {
                    try await self.provider.pause()
                }
                await self.refreshProvider()
            } catch {
                self.handleProviderError(error)
            }
        }
    }

    public func previousTrack() {
        guard canControlSpotify else { return }
        runProviderCommand { provider in
            try await provider.previous()
        }
    }

    public func nextTrack() {
        guard canControlSpotify else { return }
        runProviderCommand { provider in
            try await provider.next()
        }
    }

    public func seek(to time: TimeInterval, source: String = "programmatic") {
        guard canInteractWithPlayback else { return }
        guard time.isFinite,
              time >= 0,
              currentTrack.duration.isFinite,
              currentTrack.duration > 0,
              time <= currentTrack.duration else {
            #if DEBUG
            Self.seekLogger.debug("rejected source=\(source, privacy: .public) time=\(time, privacy: .public) duration=\(self.currentTrack.duration, privacy: .public) identity=\(self.currentTrackIdentity?.stableKey ?? "none", privacy: .public)")
            #endif
            return
        }

        listeningHistorySession?.noteExplicitSeek()
        let seekTime = time
        let previousPosition = currentTime
        #if DEBUG
        Self.seekLogger.debug("accepted source=\(source, privacy: .public) time=\(String(format: "%.3f", seekTime), privacy: .public) identity=\(self.currentTrackIdentity?.stableKey ?? "none", privacy: .public)")
        #endif
        // Product path: capture continuity + auto-align must see seeks outside DEBUG.
        AutomaticAlignmentJobController.shared.notifySeek(from: previousPosition, to: seekTime)
        resetPlaybackAnchor(to: seekTime, source: .seek, previousTime: previousPosition)

        guard canControlSpotify else { return }
        invalidateProviderRefresh()
        runProviderCommand { provider in
            try await provider.seek(to: seekTime)
        }
    }

    public func retryLyrics(queryOverride: String? = nil) {
        if let previewTrack = searchPreviewTrack {
            let identity = TrackIdentity(track: previewTrack)
            searchPreviewSession.retry(
                track: previewTrack,
                identity: identity,
                queryOverride: queryOverride
            )
            songSearchSelectionMessage = "正在重新搜索所选歌曲歌词…"
        } else {
            guard hasLiveTrack, let identity = currentTrackIdentity else { return }
            let posBefore = currentTime
            lyricsSession.retry(
                track: currentTrack,
                identity: identity,
                queryOverride: queryOverride
            )
            LyricsE2ELog.log("UI retryLyrics dispatched queryOverride=\(queryOverride ?? "") posBefore=\(posBefore) (must not seek)")
        }
    }

    /// Product default: one-button lyrics auto-complete for the live TrackIdentity.
    public func autoCompleteLyrics() {
        guard hasLiveTrack, let identity = currentTrackIdentity else { return }
        LyricsE2ELog.log("UI autoCompleteLyrics identity=\(identity.stableKey) title=\(currentTrack.title) pos=\(currentTime)")
        let posBefore = currentTime
        lyricsSession.autoComplete(track: currentTrack, identity: identity)
        LyricsE2ELog.log("UI autoCompleteLyrics dispatched posBefore=\(posBefore) (must not seek)")
    }

    /// noTextSource fallback: pick a local audio file and build an ASR lyrics draft.

    private var alignmentTask: Task<Void, Never>?

#if DEBUG
    public enum AssistCapturePhase: String, Equatable, Sendable {
        case idle
        case explaining
        case capturing
        case merging
        case ready
        case failed
        case cancelled
    }

    @Published public private(set) var assistPhase: AssistCapturePhase = .idle
    @Published public private(set) var assistStatusMessage = ""
    @Published public private(set) var assistDraft: AssistedAlignmentDraft?
    /// Single source of truth for the explain sheet. Hosted once on
    /// `MainLyricsWindowView` (shared by V3 and classic layouts).
    @Published public var isAssistExplainSheetPresented = false
    /// Pulsed when Assist draft is ready so the main window can open the editor.
    @Published public private(set) var assistEditorOpenToken: UInt64 = 0
    private var assistTask: Task<Void, Never>?
    private var assistSessionGuard: AlignmentSessionGuard?
    private var assistIdentityKey: String?

    /// Preconditions for starting Assist (track + plain saved lyrics), independent of phase.
    public var listeningAssistBaseEligibility: Bool {
        guard hasLiveTrack, !isMockPreviewMode else { return false }
        guard let plain = lyricsSession.state.plainDocument ?? lyricsSession.state.document else { return false }
        guard !plain.isSynchronized else { return false }
        guard plain.lines.contains(where: {
            !$0.originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else { return false }
        guard lyricsSession.activeLyricsVersionID != nil else { return false }
        guard currentTrackIdentity != nil else { return false }
        return true
    }

    /// Whether product UI may show the primary「边听边排轴」start control.
    public var canStartListeningAssist: Bool {
        guard listeningAssistBaseEligibility else { return false }
        // explaining: sheet is up (do not offer a second start); capturing/merging use cancel UI.
        return assistPhase == .idle || assistPhase == .failed || assistPhase == .cancelled || assistPhase == .ready
    }

    /// Whether the current-song panel should keep the Assist block visible.
    public var showsListeningAssistControls: Bool {
        listeningAssistBaseEligibility
            || assistPhase == .explaining
            || assistPhase == .capturing
            || assistPhase == .merging
            || assistPhase == .ready
            || assistPhase == .failed
    }

    /// Step 1: show explain sheet (no capture yet).
    public func presentListeningAssistExplanation() {
        guard canStartListeningAssist else {
            songSearchSelectionMessage = "边听边排轴需要：当前歌曲、纯文本歌词、已保存版本"
            return
        }
        isAssistExplainSheetPresented = true
        assistPhase = .explaining
        assistStatusMessage = "请阅读说明后选择开始或取消"
        LyricsE2ELog.log("ASSIST present explanation sheet")
    }

    /// Sheet dismissed without starting (Esc, click-outside, or binding set false).
    /// Must leave a re-startable idle state — never stick in `explaining`.
    public func dismissListeningAssistExplanation() {
        isAssistExplainSheetPresented = false
        guard assistPhase == .explaining else { return }
        assistPhase = .idle
        assistStatusMessage = ""
        songSearchSelectionMessage = ""
        LyricsE2ELog.log("ASSIST explanation dismissed -> idle")
    }

    /// Step 2: user confirmed sheet → capture Spotify audio and build Assist draft.
    public func confirmListeningAssistAndCapture(seconds: TimeInterval = 55) {
        isAssistExplainSheetPresented = false
        guard hasLiveTrack, let identity = currentTrackIdentity else {
            resetAssistToFailed(message: "需要当前 Spotify 歌曲")
            return
        }
        guard let plain = lyricsSession.state.plainDocument ?? lyricsSession.state.document,
              !plain.isSynchronized,
              let sourceVersionID = lyricsSession.activeLyricsVersionID else {
            resetAssistToFailed(message: "无法开始边听边排轴")
            return
        }
        let sourceHash = lyricsSession.activeSourceContentHash
            ?? LyricsPersistenceMapper.sourceContentHash(document: plain)
        let guardToken = AlignmentSessionGuard(
            identity: identity,
            sourceVersionID: sourceVersionID,
            sourceContentHash: sourceHash,
            revision: lyricsSession.revision
        )
        assistSessionGuard = guardToken
        assistIdentityKey = identity.stableKey
        assistDraft = nil
        assistPhase = .capturing
        assistStatusMessage = "正在临时分析当前歌曲音频…"
        songSearchSelectionMessage = "边听边排轴：捕获中（确认前不会保存时间轴）"
        LyricsE2ELog.log("ASSIST confirm capture seconds=\(seconds)")

        LiveCaptureCoordinator.shared.bind(playback: self)
        assistTask?.cancel()
        assistTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let genBefore = LiveCaptureCoordinator.shared.lastStartedGeneration
            await LiveCaptureCoordinator.shared.start(
                autoStopAfter: max(25, seconds),
                runPartialAlignment: true
            )
            let startedGen = LiveCaptureCoordinator.shared.lastStartedGeneration
            // Generation must advance for this Assist attempt to own the session.
            // If start was ignored (busy) or never booted, fail immediately —
            // do not wait on another session's idle.
            if startedGen == genBefore {
                let handoff = LiveCaptureCoordinator.shared.lastAlignmentHandoff
                self.resetAssistToFailed(
                    kind: handoff?.failureKind ?? .startIgnored,
                    message: handoff?.message
                        ?? LiveCaptureCoordinator.shared.lastError
                        ?? "无法开始捕获"
                )
                return
            }
            // Wait until capture + partial alignment handoff is published (not just idle).
            await LiveCaptureCoordinator.shared.waitUntilIdle(timeoutSeconds: 200)
            // Cancelled while waiting.
            if Task.isCancelled || self.assistPhase == .cancelled {
                return
            }
            guard let token = self.assistSessionGuard,
                  token.accepts(
                    identity: self.currentTrackIdentity ?? identity,
                    sourceVersionID: self.lyricsSession.activeLyricsVersionID ?? sourceVersionID,
                    sourceContentHash: self.lyricsSession.activeSourceContentHash ?? sourceHash,
                    revision: self.lyricsSession.revision
                  ),
                  self.currentTrackIdentity?.stableKey == self.assistIdentityKey else {
                self.assistPhase = .cancelled
                self.assistStatusMessage = "歌曲已切换，草稿已丢弃"
                self.songSearchSelectionMessage = "边听边排轴已取消（切歌）"
                self.assistDraft = nil
                LyricsE2ELog.log("ASSIST drop stale identity")
                return
            }
            let handoff = LiveCaptureCoordinator.shared.lastAlignmentHandoff
            // Reject stale handoff from a previous song/session.
            if let handoff, handoff.generation != startedGen {
                LyricsE2ELog.log(
                    "ASSIST reject stale handoff gen=\(handoff.generation) expected=\(startedGen)"
                )
                self.resetAssistToFailed(
                    kind: .cancelled,
                    message: "会话结果已过期，请重试"
                )
                return
            }
            if LiveCaptureCoordinator.shared.state == .failed {
                self.resetAssistToFailed(
                    kind: handoff?.failureKind ?? .captureFailed,
                    message: handoff?.message
                        ?? LiveCaptureCoordinator.shared.lastError
                        ?? "音频捕获失败"
                )
                return
            }
            guard let report = handoff?.report ?? LiveCaptureCoordinator.shared.lastPartialReport else {
                self.resetAssistToFailed(
                    kind: handoff?.failureKind ?? .unknown,
                    message: handoff?.message
                        ?? LiveCaptureCoordinator.shared.lastError
                        ?? "未能生成建议时间"
                )
                return
            }
            self.assistPhase = .merging
            self.assistStatusMessage = "正在整理时间建议…"
            let plainLines = plain.lines
            let draft = AssistedCandidateMerger.merge(report: report, plainLines: plainLines)
            guard self.currentTrackIdentity?.stableKey == self.assistIdentityKey else {
                self.assistPhase = .cancelled
                self.assistDraft = nil
                return
            }
            self.assistDraft = draft
            self.assistPhase = .ready
            if draft.suggestedCount == 0 {
                // Report exists — this is NOT a lifecycle failure.
                self.assistStatusMessage =
                    "识别完成，但可靠建议不足（未排 \(draft.unresolvedCount) 行）。可打开编辑器查看或重试。"
                LyricsE2ELog.log(
                    "ASSIST draft ready suggested=0 unresolved=\(draft.unresolvedCount) session=\(report.candidate.captureSessionID.uuidString.prefix(8)) insufficient"
                )
            } else {
                self.assistStatusMessage =
                    "建议 \(draft.suggestedCount) 行 · 未排 \(draft.unresolvedCount) 行（确认前不写库）"
                LyricsE2ELog.log(
                    "ASSIST draft ready suggested=\(draft.suggestedCount) unresolved=\(draft.unresolvedCount) session=\(report.candidate.captureSessionID.uuidString.prefix(8))"
                )
            }
            self.songSearchSelectionMessage = self.assistStatusMessage
            // Open existing editor and apply suggestions (still draft only — no auto-save).
            self.openListeningAssistEditorWithDraft(draft)
        }
    }

    /// Apply draft into the existing lyrics editor and request its window.
    public func openListeningAssistEditorWithDraft(_ draft: AssistedAlignmentDraft? = nil) {
        let draft = draft ?? assistDraft
        guard let draft else {
            songSearchSelectionMessage = "还没有可编辑的时间建议"
            return
        }
        prepareLyricsEditor()
        lyricsEditorSession.applyAssistedDraft(draft)
        assistEditorOpenToken &+= 1
        // Best-effort focus if the window is already open.
        if let editor = NSApp.windows.first(where: {
            $0.identifier?.rawValue == "lyrics-editor" || $0.title.contains("歌词编辑")
        }) {
            editor.makeKeyAndOrderFront(nil)
        }
        LyricsE2ELog.log("ASSIST open editor token=\(assistEditorOpenToken)")
    }

    public func cancelListeningAssist() {
        assistTask?.cancel()
        assistTask = nil
        isAssistExplainSheetPresented = false
        Task { @MainActor in
            if LiveCaptureCoordinator.shared.state == .running
                || LiveCaptureCoordinator.shared.state == .stopping {
                await LiveCaptureCoordinator.shared.stop(reason: .userStop)
            }
        }
        assistPhase = .cancelled
        assistDraft = nil
        assistSessionGuard = nil
        assistIdentityKey = nil
        assistStatusMessage = "已取消边听边排轴"
        songSearchSelectionMessage = assistStatusMessage
        lyricsEditorSession.clearAssistSuggestions()
        LyricsE2ELog.log("ASSIST cancelled by user")
    }

    /// Drop unconfirmed Assist draft when track changes (no auto-save).
    public func invalidateAssistOnTrackChange(previousKey: String?, nextKey: String?) {
        guard let prev = previousKey, let next = nextKey, prev != next else { return }
        guard assistPhase == .capturing || assistPhase == .merging || assistPhase == .ready
                || assistPhase == .explaining else { return }
        assistTask?.cancel()
        assistTask = nil
        isAssistExplainSheetPresented = false
        Task { @MainActor in
            if LiveCaptureCoordinator.shared.state == .running {
                await LiveCaptureCoordinator.shared.stop(reason: .trackChanged)
            }
        }
        assistPhase = .cancelled
        assistDraft = nil
        assistSessionGuard = nil
        assistIdentityKey = nil
        assistStatusMessage = "切歌：未确认的建议已丢弃"
        songSearchSelectionMessage = assistStatusMessage
        lyricsEditorSession.clearAssistSuggestions()
        LyricsE2ELog.log("ASSIST invalidate trackChanged prev=\(prev.prefix(24)) next=\(next.prefix(24))")
    }

    private func resetAssistToFailed(
        kind: LiveCaptureCoordinator.PartialAlignmentFailureKind? = nil,
        message: String
    ) {
        isAssistExplainSheetPresented = false
        assistPhase = .failed
        let display = Self.assistUserFacingMessage(kind: kind, fallback: message)
        assistStatusMessage = display
        songSearchSelectionMessage = display
        assistDraft = nil
        LyricsE2ELog.log(
            "ASSIST failed kind=\(kind?.rawValue ?? "none") message=\(message) display=\(display)"
        )
    }

    /// Maps internal failure kinds to concise product copy (logs keep full detail).
    private static func assistUserFacingMessage(
        kind: LiveCaptureCoordinator.PartialAlignmentFailureKind?,
        fallback: String
    ) -> String {
        switch kind {
        case .unsupportedSource:
            return "当前播放来源不支持 Spotify live capture"
        case .noCompletedSession, .noWavSegments, .captureFailed:
            return "没有捕获到有效音频"
        case .speechFailed:
            return "识别失败或引擎不可用"
        case .noLyrics:
            return "当前没有可对齐的歌词"
        case .cancelled:
            return "已取消"
        case .startIgnored:
            return "捕获仍在进行中，请稍后再试"
        case .emptyTranscript:
            return "识别完成，但未得到有效文字"
        case .insufficientSuggestions:
            return "识别完成，但可靠建议不足"
        case .alignmentFailed:
            return "识别有结果，但无法可靠匹配歌词"
        case .noPlayback:
            return "当前没有可用的播放会话"
        case .unknown, .none:
            return fallback.isEmpty ? "未能生成建议" : fallback
        }
    }
#endif

    /// Known plain lyrics + local audio -> line-level forced alignment preview.
    public func alignCurrentLyricsWithLocalAudio() {
        guard hasLiveTrack, let identity = currentTrackIdentity, !isMockPreviewMode else {
            songSearchSelectionMessage = "需要当前播放歌曲"
            return
        }
        guard let plain = lyricsSession.state.plainDocument ?? lyricsSession.state.document else {
            songSearchSelectionMessage = "当前没有可排轴的歌词正文"
            return
        }
        guard !plain.isSynchronized else {
            songSearchSelectionMessage = "当前歌词已有时间轴，请先创建纯文本副本再排轴"
            return
        }
        guard !plain.lines.isEmpty,
              plain.lines.contains(where: { !$0.originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              let sourceVersionID = lyricsSession.activeLyricsVersionID else {
            songSearchSelectionMessage = "当前歌词版本尚未完成保存，无法安全绑定排轴"
            return
        }
        let sourceContentHash = lyricsSession.activeSourceContentHash
            ?? LyricsPersistenceMapper.sourceContentHash(document: plain)
        let trackSnapshot = currentTrack

        let url: URL
        if let override = ProcessInfo.processInfo.environment["SPOTIFYLYRICS_ALIGN_AUDIO"],
           !override.isEmpty {
            url = URL(fileURLWithPath: override)
            guard FileManager.default.isReadableFile(atPath: url.path) else {
                songSearchSelectionMessage = "排轴音频不可读：\(override)"
                return
            }
        } else {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.allowedContentTypes = [
                .mp3, .wav, .aiff, .mpeg4Audio,
                UTType(filenameExtension: "flac")
            ].compactMap { $0 }
            panel.title = "选择本地音频（逐行自动排轴）"
            panel.message = "不会修改原音频，也不会从播放器取流。确认前不会覆盖当前歌词。"
            guard panel.runModal() == .OK, let picked = panel.url else { return }
            url = picked
        }

        alignmentTask?.cancel()
        alignmentTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var sessionGuard: AlignmentSessionGuard?
            do {
                let metadata = try await AudioPCMConverter.inspectMetadata(audioURL: url)
                guard self.currentTrackIdentity == identity,
                      self.lyricsSession.activeLyricsVersionID == sourceVersionID,
                      self.lyricsSession.activeSourceContentHash == sourceContentHash else {
                    LyricsE2ELog.log("UI align drop preflight identity=\(identity.stableKey)")
                    return
                }
                guard !metadata.hasHardMetadataMismatch(title: trackSnapshot.title, artist: trackSnapshot.artist) else {
                    throw AlignmentError.invalidAudio("音频内嵌标题或艺人与当前歌曲不一致")
                }
                let acceptedMissingMetadata = metadata.missingEmbeddedTitleOrArtist
                guard self.confirmAlignmentAudioMetadata(
                    metadata,
                    track: trackSnapshot,
                    fileName: url.lastPathComponent
                ) else {
                    throw AlignmentError.cancelled
                }

                let posBefore = self.currentTime
                LyricsE2ELog.log(
                    "UI align start identity=\(identity.stableKey) audio=\(url.lastPathComponent) duration=\(metadata.duration) hash=\(metadata.sha256.prefix(12)) pos=\(posBefore)"
                )
                self.lyricsSession.beginAlignment(identity: identity, plain: plain)
                let alignmentRevision = self.lyricsSession.revision
                let capturedGuard = AlignmentSessionGuard(
                    identity: identity,
                    sourceVersionID: sourceVersionID,
                    sourceContentHash: sourceContentHash,
                    revision: alignmentRevision
                )
                sessionGuard = capturedGuard
                let request = AlignmentRequest(
                    identity: identity,
                    track: trackSnapshot,
                    plainLines: plain.lines,
                    audioURL: url,
                    durationHint: trackSnapshot.duration,
                    sourceVersionID: sourceVersionID,
                    sourceContentHash: sourceContentHash,
                    sourceIsSynchronized: plain.isSynchronized,
                    allowMissingEmbeddedMetadata: acceptedMissingMetadata || !metadata.missingEmbeddedTitleOrArtist
                )
                let report = try await self.alignmentService.align(request) { prog in
                    Task { @MainActor [weak self] in
                        guard let self,
                              capturedGuard.accepts(
                                  identity: self.currentTrackIdentity,
                                  sourceVersionID: self.lyricsSession.activeLyricsVersionID,
                                  sourceContentHash: self.lyricsSession.activeSourceContentHash,
                                  revision: self.lyricsSession.revision
                              ) else { return }
                        let value: Double
                        switch prog {
                        case .preparingAudio(let p): value = 0.05 + 0.15 * p
                        case .recognizing(let p): value = 0.20 + 0.45 * p
                        case .aligning(let p): value = 0.65 + 0.25 * p
                        case .scoring(let p): value = 0.90 + 0.09 * p
                        case .finished: value = 1
                        }
                        self.lyricsSession.updateAlignmentProgress(identity: identity, plain: plain, progress: value)
                        self.songSearchSelectionMessage = "自动排轴 \(Int(value * 100))%"
                    }
                }
                guard !Task.isCancelled,
                      capturedGuard.accepts(
                          identity: self.currentTrackIdentity,
                          sourceVersionID: self.lyricsSession.activeLyricsVersionID,
                          sourceContentHash: self.lyricsSession.activeSourceContentHash,
                          revision: self.lyricsSession.revision
                      ) else {
                    LyricsE2ELog.log("UI align drop stale result identity=\(identity.stableKey) currentRevision=\(self.lyricsSession.revision)")
                    return
                }
                let timed = report.makeDocument(base: plain, source: .automaticAlignment)
                self.lyricsSession.presentAlignmentPreview(
                    identity: identity,
                    plain: plain,
                    timed: timed,
                    report: report
                )
                self.songSearchSelectionMessage = String(
                    format: "排轴预览：总置信度 %.0f%%，低置信 %d 行。确认后保存。",
                    report.overallConfidence * 100,
                    report.lowConfidenceCount
                )
                LyricsE2ELog.log("UI align preview ready overall=\(report.overallConfidence) low=\(report.lowConfidenceCount) pos=\(self.currentTime) before=\(posBefore)")
            } catch {
                guard let capturedGuard = sessionGuard,
                      capturedGuard.accepts(
                          identity: self.currentTrackIdentity,
                          sourceVersionID: self.lyricsSession.activeLyricsVersionID,
                          sourceContentHash: self.lyricsSession.activeSourceContentHash,
                          revision: self.lyricsSession.revision
                      ) else {
                    if self.currentTrackIdentity == identity, !(error is AlignmentError && (error as? AlignmentError) == .identityMismatch) {
                        self.songSearchSelectionMessage = Task.isCancelled || error is CancellationError
                            ? "已取消排轴"
                            : "自动排轴预检失败：\(error.localizedDescription)"
                    }
                    return
                }
                if case .alignmentRunning(_, let runningPlain, _) = self.lyricsSession.state {
                    self.lyricsSession.cancelAlignmentPreview(identity: identity, plain: runningPlain)
                }
                self.songSearchSelectionMessage = Task.isCancelled || error is CancellationError
                    ? "已取消排轴"
                    : "自动排轴失败：\(error.localizedDescription)"
                LyricsE2ELog.log("UI align failed \(error.localizedDescription)")
            }
        }
    }

    private func confirmAlignmentAudioMetadata(
        _ metadata: AudioInputMetadata,
        track: Track,
        fileName: String
    ) -> Bool {
        let alert = NSAlert()
        alert.messageText = metadata.missingEmbeddedTitleOrArtist
            ? "确认用于当前歌曲的本地音频"
            : "确认本地音频元数据"
        let embeddedTitle = metadata.embeddedTitle ?? "未标注"
        let embeddedArtist = metadata.embeddedArtist ?? "未标注"
        alert.informativeText = String(
            format: "文件：%@\n当前歌曲：%@ / %@\n音频标签：%@ / %@\n时长 %.1f 秒 · %.0f Hz · %d 声道\nSHA-256 %@…\n请确认这是完整、对应当前歌曲的录音版本的本地音频。",
            fileName,
            track.title,
            track.artist,
            embeddedTitle,
            embeddedArtist,
            metadata.duration,
            metadata.sampleRate,
            metadata.channels,
            String(metadata.sha256.prefix(12))
        )
        alert.alertStyle = metadata.missingEmbeddedTitleOrArtist ? .warning : .informational
        alert.addButton(withTitle: "开始排轴")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    public func confirmAlignmentPreview(saveLocal: Bool = true) {
        guard hasLiveTrack, let identity = currentTrackIdentity else { return }
        guard case .alignmentPreview(_, _, let timed, let report) = lyricsSession.state else { return }
        let posBefore = currentTime
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let url = try await self.lyricsSession.confirmAlignment(
                    identity: identity,
                    timed: timed,
                    report: report,
                    saveLocal: saveLocal
                )
                if let url {
                    self.songSearchSelectionMessage = "已确认并保存：\(url.lastPathComponent)"
                } else {
                    self.songSearchSelectionMessage = "已确认排轴结果"
                }
                LyricsE2ELog.log("UI align confirmed save=\(saveLocal) posBefore=\(posBefore) posAfter=\(self.currentTime)")
            } catch {
                self.songSearchSelectionMessage = "保存失败：\(error.localizedDescription)"
            }
        }
    }

    public func cancelAlignmentPreview() {
        guard hasLiveTrack, let identity = currentTrackIdentity else { return }
        if case .alignmentPreview(_, let plain, _, _) = lyricsSession.state {
            lyricsSession.cancelAlignmentPreview(identity: identity, plain: plain)
            songSearchSelectionMessage = "已返回未排轴歌词"
            return
        }
        if case .alignmentRunning(_, let plain, _) = lyricsSession.state {
            alignmentTask?.cancel()
            lyricsSession.cancelAlignmentPreview(identity: identity, plain: plain)
            songSearchSelectionMessage = "已取消排轴"
        }
    }

    public func importLocalAudioForASR() {
        guard hasLiveTrack, let identity = currentTrackIdentity, !isMockPreviewMode else {
            songSearchSelectionMessage = "需要当前 Spotify 歌曲身份才能生成 ASR 草稿"
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.mp3, .wav, .aiff, .mpeg4Audio]
        panel.title = "选择本地音频（ASR 歌词草稿）"
        panel.message = "不会从 Spotify 取受保护音频。生成结果为机器草稿，需人工校正。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { @MainActor in
            await self.runLocalAudioASR(url: url, identity: identity)
        }
    }

    public func runLocalAudioASR(url: URL, identity: TrackIdentity) async {
        guard hasLiveTrack, currentTrackIdentity == identity else { return }
        lyricsSession.beginLoadingPlaceholder(identity: identity, message: "ASR 识别中…")
        do {
            let service = LocalAudioASRService()
            let document = try await service.makeLyricsDocument(
                audioURL: url,
                identity: identity,
                track: currentTrack
            )
            guard currentTrackIdentity == identity else { return }
            lyricsSession.adopt(document: document)
            if case .alignmentQueued = lyricsSession.state {
                songSearchSelectionMessage = "ASR 草稿已生成（待对齐/待校正）"
            } else {
                songSearchSelectionMessage = "ASR 草稿已生成（机器生成，待校正）"
            }
        } catch {
            guard currentTrackIdentity == identity else { return }
            lyricsSession.fail(identity: identity, failure: .unknown("ASR 失败：\(error.localizedDescription)"))
            songSearchSelectionMessage = "ASR 失败：\(error.localizedDescription)"
        }
    }


    /// Starts a lyrics preview for a selected catalog result. The preview uses
    /// its own session, so selecting arbitrary Spotify catalog metadata never
    /// changes the Desktop playback track or its time anchor.
    public func loadSearchResult(_ result: SongSearchResult) {
        guard !isMockPreviewMode else {
            songSearchSelectionMessage = "请先退出 Mock Preview，再加载真实歌曲歌词"
            return
        }
        searchPreviewGeneration &+= 1
        let generation = searchPreviewGeneration
        searchPreviewTask?.cancel()

        let identity = TrackIdentity(track: result.track)
        let metadata = TrackMetadata.bootstrap(
            from: result.track,
            catalogMetadata: result.catalogMetadata
        )

        // Searching for the song that is actually playing should return to the
        // live session so synchronized scrolling continues to follow Spotify.
        // It still goes through the same SQLite-first path and never seeks.
        if hasLiveTrack, let currentIdentity = currentTrackIdentity, identity == currentIdentity {
            clearSearchPreview()
            songSearchSelectionMessage = "已确认当前播放歌曲，正在读取 SQLite 与歌词；播放位置未改变"
            searchPreviewTask = Task { @MainActor [weak self, lyricsRepository] in
                guard let self else { return }
                try? await lyricsRepository.saveTrackMetadata(metadata)
                guard !Task.isCancelled, self.currentTrackIdentity == currentIdentity else { return }
                self.lyricsSession.begin(track: self.currentTrack, identity: currentIdentity)
            }
            return
        }

        searchPreviewTrack = result.track
        searchPreviewSession.beginLoadingPlaceholder(
            identity: identity,
            message: "正在读取 SQLite 与歌词 Provider…"
        )
        songSearchSelectionMessage = "已选择「\(result.track.title)」，正在读取歌词；播放位置未改变"

        // Persist catalog metadata first, then start the session. This records
        // the TrackRecord/aliases even when every lyrics provider returns no
        // text, while never creating an empty LyricsVersion.
        searchPreviewTask = Task { @MainActor [weak self, lyricsRepository] in
            guard let self else { return }
            do {
                try await lyricsRepository.saveTrackMetadata(metadata)
            } catch {
                guard self.searchPreviewGeneration == generation else { return }
                self.songSearchSelectionMessage = "歌词读取继续进行，但歌曲元数据未能写入 SQLite"
            }
            guard !Task.isCancelled,
                  self.searchPreviewGeneration == generation,
                  self.searchPreviewTrack == result.track else { return }

            self.searchPreviewSession.begin(track: result.track, identity: identity)

            // Legacy callers may still supply a body. Track search itself never
            // does; when it does, only apply it to the isolated preview.
            if let legacyLyrics = result.lyrics, !legacyLyrics.lines.isEmpty {
                let document = LyricsDocument(
                    identity: identity,
                    title: legacyLyrics.title ?? result.track.title,
                    artist: legacyLyrics.artist ?? result.track.artist,
                    album: legacyLyrics.album ?? result.track.album,
                    duration: legacyLyrics.duration ?? result.track.duration,
                    lines: legacyLyrics.lines,
                    isSynchronized: legacyLyrics.isSynchronized,
                    source: legacyLyrics.source,
                    confidence: min(result.confidence, legacyLyrics.confidence),
                    providerSourceID: legacyLyrics.providerSourceID
                )
                self.searchPreviewSession.adopt(document: document)
            }
        }
    }

    public func clearSearchPreview() {
        searchPreviewGeneration &+= 1
        searchPreviewTask?.cancel()
        searchPreviewTask = nil
        searchPreviewTrack = nil
        searchPreviewSession.clear()
        songSearchSelectionMessage = ""
    }

    public func adoptLyricsCandidate(_ candidate: LyricsCandidate) async throws -> LyricsPersistenceSaveResult {
        let identity = candidate.identity
        let target: (track: Track, session: LyricsSessionController)
        if let previewTrack = searchPreviewTrack {
            guard TrackIdentity(track: previewTrack) == identity else {
                return LyricsPersistenceSaveResult(versionID: nil,
                    disposition: .rejected("搜索预览期间不采用当前播放歌曲的旧候选"))
            }
            target = (previewTrack, searchPreviewSession)
        } else if currentTrackIdentity == identity {
            target = (currentTrack, lyricsSession)
        } else {
            return LyricsPersistenceSaveResult(
                versionID: nil,
                disposition: .rejected("候选歌曲已变化，未采用")
            )
        }

        let document = candidate.makeDocument()
        return try await startManualLyricsAdoption(
            document: document,
            track: target.track,
            session: target.session,
            clearSearchPreviewGeneration: nil
        )
    }

    private func startManualLyricsAdoption(
        document: LyricsDocument,
        track: Track,
        session: LyricsSessionController,
        clearSearchPreviewGeneration: UInt64?
    ) async throws -> LyricsPersistenceSaveResult {
        let identity = document.identity
        guard TrackIdentity(track: track) == identity else {
            return LyricsPersistenceSaveResult(
                versionID: nil,
                disposition: .rejected("候选歌曲身份与目标歌曲不一致")
            )
        }

        if let previous = pendingManualLyricsAdoption {
            previous.session.cancelManualAdoptionRequest(
                identity: previous.identity,
                requestID: previous.requestID
            )
        }
        let requestID = UUID()
        guard try await session.beginManualAdoptionRequest(identity: identity, requestID: requestID) else {
            return LyricsPersistenceSaveResult(
                versionID: nil,
                disposition: .rejected("候选歌曲已变化，未采用")
            )
        }
        let pending = PendingManualLyricsAdoption(
            requestID: requestID,
            session: session,
            track: track,
            document: document,
            identity: identity,
            lockedVersionIDs: [],
            clearSearchPreviewGeneration: clearSearchPreviewGeneration
        )
        pendingManualLyricsAdoption = pending

        let result: LyricsPersistenceSaveResult
        do {
            result = try await session.adoptManually(
                document: document,
                track: track,
                requestID: requestID
            )
        } catch {
            if pendingManualLyricsAdoption?.requestID == requestID {
                pendingManualLyricsAdoption = nil
            }
            throw error
        }

        if case .lockedConflict = result.disposition {
            if pendingManualLyricsAdoption?.requestID == requestID {
                pendingManualLyricsAdoption = PendingManualLyricsAdoption(
                    requestID: requestID,
                    session: session,
                    track: track,
                    document: document,
                    identity: identity,
                    lockedVersionIDs: result.conflictingLockedVersionIDs,
                    clearSearchPreviewGeneration: clearSearchPreviewGeneration
                )
            }
        } else if pendingManualLyricsAdoption?.requestID == requestID {
            pendingManualLyricsAdoption = nil
        }
        if result.versionID != nil,
           result.disposition == .inserted || result.disposition == .duplicate {
            clearSearchPreviewIfCurrent(generation: clearSearchPreviewGeneration)
        }
        return result
    }

    private func clearSearchPreviewIfCurrent(generation: UInt64?) {
        guard let generation, searchPreviewGeneration == generation else { return }
        clearSearchPreview()
    }

    public func confirmPendingManualLyricsAdoption() async throws -> LyricsPersistenceSaveResult? {
        guard let pending = pendingManualLyricsAdoption else { return nil }
        if let previewGeneration = pending.clearSearchPreviewGeneration {
            // This confirmation belongs to an explicit preview-to-live action.
            // It must still refer to the same preview and the same live song.
            guard isShowingSearchPreview, searchPreviewGeneration == previewGeneration,
                  pending.session === lyricsSession,
                  liveTrackIdentity == pending.identity,
                  currentTrackIdentity == pending.identity else { return nil }
        } else {
            guard !isShowingSearchPreview || pending.session === searchPreviewSession else { return nil }
        }
        let result: LyricsPersistenceSaveResult
        do {
            result = try await pending.session.adoptManually(
                document: pending.document,
                track: pending.track,
                requestID: pending.requestID,
                confirmedLockedVersionIDs: pending.lockedVersionIDs
            )
        } catch {
            if pendingManualLyricsAdoption?.requestID == pending.requestID {
                pendingManualLyricsAdoption = nil
            }
            throw error
        }

        if case .lockedConflict = result.disposition {
            if pendingManualLyricsAdoption?.requestID == pending.requestID {
                pendingManualLyricsAdoption = PendingManualLyricsAdoption(
                    requestID: pending.requestID,
                    session: pending.session,
                    track: pending.track,
                    document: pending.document,
                    identity: pending.identity,
                    lockedVersionIDs: result.conflictingLockedVersionIDs,
                    clearSearchPreviewGeneration: pending.clearSearchPreviewGeneration
                )
            }
        } else {
            if pendingManualLyricsAdoption?.requestID == pending.requestID {
                pendingManualLyricsAdoption = nil
            }
            if result.versionID != nil,
               result.disposition == .inserted || result.disposition == .duplicate {
                clearSearchPreviewIfCurrent(generation: pending.clearSearchPreviewGeneration)
            }
        }
        return result
    }

    public func cancelPendingManualLyricsAdoption() {
        guard let pending = pendingManualLyricsAdoption else { return }
        pending.session.cancelManualAdoptionRequest(identity: pending.identity, requestID: pending.requestID)
        pendingManualLyricsAdoption = nil
    }

    public var pendingManualLyricsAdoptionLockedVersionCount: Int {
        pendingManualLyricsAdoption?.lockedVersionIDs.count ?? 0
    }

    /// Adopts the lyrics currently loaded in search preview to the live playback session.
    public func adoptSearchPreviewLyrics() async throws -> LyricsPersistenceSaveResult? {
        guard hasLiveTrack, let liveIdentity = currentTrackIdentity else { return nil }
        guard let previewDocument = searchPreviewSession.activeDocument,
              !previewDocument.lines.isEmpty else { return nil }

        let adoptedDocument = LyricsDocument(
            identity: liveIdentity,
            title: previewDocument.title ?? currentTrack.title,
            artist: previewDocument.artist ?? currentTrack.artist,
            album: previewDocument.album ?? currentTrack.album,
            duration: previewDocument.duration ?? currentTrack.duration,
            lines: previewDocument.lines,
            isSynchronized: previewDocument.isSynchronized,
            source: previewDocument.source,
            confidence: previewDocument.confidence,
            providerSourceID: previewDocument.providerSourceID,
            spotifyTrackID: previewDocument.spotifyTrackID,
            isrc: previewDocument.isrc,
            language: previewDocument.language,
            explicitlyTimedLineIndices: previewDocument.explicitlyTimedLineIndices,
            timingVersionID: previewDocument.timingVersionID
        )
        return try await startManualLyricsAdoption(
            document: adoptedDocument,
            track: currentTrack,
            session: lyricsSession,
            clearSearchPreviewGeneration: searchPreviewGeneration
        )
    }

    public var currentLineIndex: Int? {
        guard !isShowingSearchPreview else { return nil }
        return liveCurrentLineIndex
    }

    private func projectedLyrics(
        base: [LyricLine],
        session: LyricsSessionController,
        cache: inout (key: LyricsProjectionCacheKey, lines: [LyricLine])?
    ) -> [LyricLine] {
        let key = LyricsProjectionCacheKey(
            identityKey: session.activeIdentity?.stableKey,
            revision: session.revision,
            translationVersionID: translationSession.selectedVersion?.record.id,
            translationSelectionIsEmpty: translationSession.isNoSelection,
            lyricsVersionID: session.activeLyricsVersionID,
            sourceContentHash: session.activeSourceContentHash,
            lineCount: base.count,
            readingRevision: session === lyricsSession ? readingSession.currentRevision : 0
        )
        if let cache, cache.key == key {
            return cache.lines
        }

        let projected: [LyricLine]
        if let identity = session.activeIdentity {
            let translated = translationSession.project(
                onto: base,
                identity: identity,
                lyricsVersionID: session.activeLyricsVersionID,
                sourceContentHash: session.activeSourceContentHash
            )
            projected = session === lyricsSession ? readingSession.project(onto: translated) : translated
        } else {
            projected = base
        }
        cache = (key: key, lines: projected)
        return projected
    }

    private func refreshProvider() async {
        guard !isMockPreviewMode, canRefreshSelectedProvider else { return }
        guard !isRefreshingProvider else {
            refreshRequestedWhileBusy = true
            return
        }

        let generation = providerRefreshGeneration
        isRefreshingProvider = true
        refreshRequestedWhileBusy = false
        defer {
            // A cancelled or failed refresh must release the single-flight
            // guard as well. Otherwise a stale Apple Events task can leave
            // the state permanently disconnected.
            isRefreshingProvider = false
        }
        let refreshStart = ProcessInfo.processInfo.systemUptime
        let snapshot = await provider.refresh()
        let refreshEnd = ProcessInfo.processInfo.systemUptime
        let rtt = refreshEnd - refreshStart
        let latencyCompensatedMonotonic = refreshStart + min(rtt * 0.5, 0.15)
        // Throttle from the end of every bounded attempt, including an
        // unavailable/timeout result. Do not start a new task every timer tick
        // while a previous Apple Events request is unwinding.
        lastProviderRefreshDate = Date()

        let shouldApply = !Task.isCancelled &&
            generation == providerRefreshGeneration &&
            !isMockPreviewMode &&
            canRefreshSelectedProvider
        if shouldApply {
            synchronize(with: snapshot, observedAtMonotonic: latencyCompensatedMonotonic)
        }

        let shouldQueueRefresh = refreshRequestedWhileBusy
        refreshRequestedWhileBusy = false
        if shouldQueueRefresh && !isMockPreviewMode && canRefreshSelectedProvider {
            providerRefreshTask = Task { @MainActor [weak self] in
                await self?.refreshProvider()
            }
        }
    }

    private func synchronize(with snapshot: PlaybackSnapshot, observedAtMonotonic: TimeInterval? = nil) {
        // A refresh that was already in flight when Mock Preview was entered
        // must not be allowed to resurrect a real Spotify session.
        guard !isMockPreviewMode else { return }
        let nextSource = snapshot.status.isReady && snapshot.track != nil
            ? snapshot.sourceIdentity
            : .unknown
        updatePlaybackSourceIdentity(nextSource)
        guard snapshot.status.isReady, let providerTrack = snapshot.track else {
            guard hasLiveTrack else {
                transientProviderFailureStartedAt = nil
                if providerStatus != snapshot.status { providerStatus = snapshot.status }
                clearLiveTrackIfNeeded()
                return
            }

            let now = Date()
            let failureStartedAt = transientProviderFailureStartedAt ?? now
            transientProviderFailureStartedAt = failureStartedAt
            let elapsed = now.timeIntervalSince(failureStartedAt)
            guard elapsed >= transientProviderFailureGracePeriod else {
                return
            }

            transientProviderFailureStartedAt = nil
            if providerStatus != snapshot.status { providerStatus = snapshot.status }
            clearLiveTrackIfNeeded()
            return
        }

        transientProviderFailureStartedAt = nil
        if providerStatus != snapshot.status { providerStatus = snapshot.status }

        let nextTrack = Track(providerTrack: providerTrack)
        let nextIdentity = TrackIdentity(track: nextTrack)
        let identityChanged = !hasLiveTrack || lyricsSession.activeIdentity != nextIdentity
        let observedAt = Date()

        if let session = listeningHistorySession,
           session.stableKey != nextIdentity.stableKey {
            settleListeningHistorySession(at: observedAt)
        }

        if identityChanged {
            lyricsOffsetScopeBinding?.clear()
            alignmentTask?.cancel()
            clearSearchPreview()
            let previousKey = lyricsSession.activeIdentity?.stableKey
#if DEBUG
            invalidateAssistOnTrackChange(previousKey: previousKey, nextKey: nextIdentity.stableKey)
#endif
            AutomaticAlignmentJobController.shared.notifyTrackChanged(
                previousKey: previousKey,
                nextKey: nextIdentity.stableKey
            )
            hasLiveTrack = true
            isMockPreviewMode = false
            currentTrack = nextTrack
            songSearchSelectionMessage = ""
            LyricsE2ELog.log("Playback trackChange identity=\(nextIdentity.stableKey) title=\(nextTrack.title) artist=\(nextTrack.artist) duration=\(nextTrack.duration)")
#if DEBUG
            let previousGeneration = lyricsSession.revision
#endif
            lyricsSession.begin(
                track: nextTrack,
                identity: nextIdentity,
                automaticallySearch: settingsStore.autoSearchLyricsOnTrackChange
            )
#if DEBUG
            let newGeneration = lyricsSession.revision
            let nowIso = ISO8601DateFormatter().string(from: Date())
            let sid = TrackIdentity.canonicalSpotifyTrackID(nextTrack.spotifyId) ?? nextTrack.spotifyId ?? "none"
            print("[RuntimeTrackObserved] timestamp=\(nowIso) spotifyTrackID=\(sid) previousGeneration=\(previousGeneration) sessionGeneration=\(newGeneration) title=\"\(nextTrack.title)\" artist=\"\(nextTrack.artist)\" position=\(snapshot.position)")
#endif
            lyricsEditorSession.observePlayback(identity: nextIdentity, revision: lyricsSession.revision)
        } else if currentTrack != nextTrack {
            // Metadata/artwork may change without a lyric identity change. The
            // background view receives the new artwork URL and rekeys itself.
            currentTrack = nextTrack
        }

        let wasPlaying = isPlaying
        if isPlaying != snapshot.isPlaying { isPlaying = snapshot.isPlaying }
        // S2 live-capture continuity: Desktop position can jump after a user
        // seek without going through seek(to:). Product auto-align reuses this.
        let previousPosition = currentTime
        let incoming = snapshot.position
        let desktopJump = abs(incoming - previousPosition) > 1.5
        if hasLiveTrack, desktopJump {
            AutomaticAlignmentJobController.shared.notifySeek(from: previousPosition, to: incoming)
        }
        let anchorSource: LineIndexSource
        if identityChanged {
            anchorSource = .reset
        } else if desktopJump {
            anchorSource = .seek
        } else {
            anchorSource = .poll
        }
        resetPlaybackAnchor(
            to: snapshot.position,
            source: anchorSource,
            previousTime: previousPosition,
            observedAtMonotonic: observedAtMonotonic
        )
        if let session = listeningHistorySession,
           session.stableKey == nextIdentity.stableKey {
            updateListeningHistorySession(
                at: observedAt,
                position: snapshot.position,
                isPlaying: snapshot.isPlaying
            )
        } else {
            beginListeningHistorySession(
                track: nextTrack,
                identity: nextIdentity,
                at: Date(),
                position: snapshot.position,
                isPlaying: snapshot.isPlaying
            )
        }
        if wasPlaying != snapshot.isPlaying || identityChanged {
            AutomaticAlignmentJobController.shared.notePlaybackContextChanged()
        }
    }

    private func clearLiveTrackIfNeeded() {
        guard !isMockPreviewMode else { return }
        lyricsOffsetScopeBinding?.clear()
        updatePlaybackSourceIdentity(.unknown)
        transientProviderFailureStartedAt = nil
        pauseListeningHistorySession(at: Date())
        alignmentTask?.cancel()
        cancelLineBoundaryWake()
        clearSearchPreview()
        let hadLiveState = hasLiveTrack || lyricsSession.activeIdentity != nil || !lyrics.isEmpty
        lyricsEditorSession.markStale()
        hasLiveTrack = false
        if hadLiveState {
            currentTrack = .emptyPlaybackPlaceholder
            lyricsSession.clear()
        }
        songSearchSelectionMessage = ""
        isPlaying = false
        resetPlaybackAnchor(to: 0, source: .reset)
    }

    private func updatePlaybackSourceIdentity(_ next: PlaybackSourceIdentity) {
        guard playbackSourceIdentity != next else { return }
        let previous = playbackSourceIdentity
        playbackSourceIdentity = next
        AutomaticAlignmentJobController.shared.notifyPlaybackSourceChanged(
            previous: previous,
            next: next
        )
    }

    private func beginListeningHistorySession(
        track: Track,
        identity: TrackIdentity,
        at date: Date,
        position: TimeInterval,
        isPlaying: Bool
    ) {
        // A selected but paused song has not started a playback occurrence.
        guard isPlaying else { return }
        var session = ListeningHistorySession(track: track, identity: identity, startedAt: date)
        if let completed = session.observe(at: date, position: position, isPlaying: isPlaying) {
            publishListeningHistory(completed)
        }
        listeningHistorySession = session
        publishListeningHistory(session.entry)
    }

    private func updateListeningHistorySession(
        at date: Date,
        position: TimeInterval,
        isPlaying: Bool
    ) {
        guard var session = listeningHistorySession else { return }
        session.updateArtwork(currentTrack.artworkURL)
        if let completed = session.observe(at: date, position: position, isPlaying: isPlaying) {
            publishListeningHistory(completed)
        }
        listeningHistorySession = session
        publishListeningHistory(session.entry)
    }

    private func pauseListeningHistorySession(at date: Date) {
        guard listeningHistorySession != nil else { return }
        updateListeningHistorySession(
            at: date,
            position: currentTime,
            isPlaying: false
        )
    }

    private func settleListeningHistorySession(at date: Date) {
        guard var session = listeningHistorySession else { return }
        session.observe(at: date, position: currentTime, isPlaying: isPlaying)
        listeningHistorySession = nil
        publishListeningHistory(session.entry)
    }

    private func runProviderCommand(_ command: @escaping @MainActor (PlaybackProvider) async throws -> Void) {
        invalidateProviderRefresh()
        providerRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await command(self.provider)
                try? await Task.sleep(nanoseconds: 250_000_000)
                await self.refreshProvider()
            } catch {
                self.handleProviderError(error)
            }
        }
    }

    private func invalidateProviderRefresh() {
        providerRefreshGeneration &+= 1
        if isRefreshingProvider {
            refreshRequestedWhileBusy = true
        }
    }

    private func handleProviderError(_ error: Error) {
        if let providerError = error as? PlaybackProviderError {
            switch providerError {
            case .notInstalled:
                providerStatus = .notInstalled
            case .notRunning:
                providerStatus = .notRunning
            case .permissionDenied:
                providerStatus = .permissionDenied
            case .noTrack:
                providerStatus = .noTrack
            case .commandFailed(let message):
                providerStatus = .unavailable(message)
            }
        } else {
            providerStatus = .unavailable(error.localizedDescription)
        }
        clearLiveTrackIfNeeded()
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
    }

    private func startNetworkRecoveryMonitor() {
        guard networkRecoveryMonitor == nil else { return }

        let monitor = NWPathMonitor()
        networkRecoveryMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let isSatisfied = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self else { return }
                let wasSatisfied = self.networkWasSatisfied
                self.networkWasSatisfied = isSatisfied
                guard isSatisfied, !wasSatisfied else { return }
                self.retryLyricsAfterNetworkRecovery()
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.spotifylyrics.network-recovery"))
    }

    private func retryLyricsAfterNetworkRecovery() {
        guard hasLiveTrack,
              let identity = currentTrackIdentity else { return }
        _ = lyricsSession.retryAfterNetworkRecovery(track: currentTrack, identity: identity)
    }

    private func tick() {
        if isMockPreviewMode {
            publishTickTime(min(currentTrack.duration, currentTime + (isPlaying ? tickInterval : 0)))
            if PlaybackTickTimeUpdatePolicy.shouldFinishMockPlayback(
                isPlaying: isPlaying,
                currentTime: currentTime,
                duration: currentTrack.duration
            ) {
                isPlaying = false
                resetPlaybackAnchor(to: currentTrack.duration, source: .reset)
            }
        } else if providerStatus.isReady, hasLiveTrack {
            if isPlaying {
                let elapsed = Date().timeIntervalSince(playbackAnchorDate)
                publishTickTime(min(currentTrack.duration, playbackAnchorPosition + elapsed))
                if currentTime >= currentTrack.duration {
                    isPlaying = false
                    resetPlaybackAnchor(to: currentTrack.duration, source: .reset)
                }
            } else {
                publishTickTime(playbackAnchorPosition)
            }
        } else {
            publishTickTime(0)
        }

        if isMockPreviewMode {
            syncPublishedLineIndex(source: .mockTick)
        }

        let shouldRefreshProvider = !isMockPreviewMode &&
            canRefreshSelectedProvider &&
            Date().timeIntervalSince(lastProviderRefreshDate) >= calibrationInterval
        if shouldRefreshProvider && !isRefreshingProvider {
            providerRefreshTask = Task { @MainActor [weak self] in
                await self?.refreshProvider()
            }
        }
    }

    private func publishTickTime(_ nextTime: TimeInterval) {
        guard PlaybackTickTimeUpdatePolicy.shouldPublish(currentTime: currentTime, nextTime: nextTime) else {
            return
        }
        isPublishingPlaybackClockTick = true
        defer { isPublishingPlaybackClockTick = false }
        currentTime = nextTime
    }

    private enum LineIndexSource: String {
        case poll
        case seek
        case boundary
        case lyricsSession = "lyrics-session"
        case pauseResume = "pause-resume"
        case presentationOffset = "presentation-offset"
        case reset
        case mockTick = "mock-tick"
    }

    private func resetPlaybackAnchor(
        to position: TimeInterval,
        source: LineIndexSource,
        previousTime: TimeInterval? = nil,
        observedAtMonotonic: TimeInterval? = nil
    ) {
        let previous = previousTime ?? currentTime
        playbackAnchorPosition = max(0, min(position, currentTrack.duration))
        playbackAnchorDate = Date()
        playbackAnchorMonotonic = observedAtMonotonic ?? ProcessInfo.processInfo.systemUptime
        if source == .poll {
            // Ordinary calibration updates the clock and its time subscribers,
            // not the whole reading surface. Boundary publication stays outside.
            publishTickTime(playbackAnchorPosition)
        } else {
            currentTime = playbackAnchorPosition
        }
        syncPublishedLineIndex(
            source: source,
            previousTime: previous,
            incomingTime: presentationTimeNow
        )
    }

    private var presentationTimeNow: TimeInterval {
        presentationTimeNow(usingPresentationOffset: nil)
    }

    private func presentationTimeNow(usingPresentationOffset offset: TimeInterval?) -> TimeInterval {
        if isMockPreviewMode {
            return currentTime
        }
        let clock = presentationClock
        if let offset {
            return clock
                .withPresentationOffset(offset)
                .presentationTime(at: ProcessInfo.processInfo.systemUptime)
        }
        return clock.presentationTime(at: ProcessInfo.processInfo.systemUptime)
    }

    private func cancelLineBoundaryWake() {
        lineBoundaryGeneration &+= 1
        lineBoundaryTask?.cancel()
        lineBoundaryTask = nil
    }

    private func rememberConfirmedLine(index: Int?, lines: [LyricLine], at monotonic: TimeInterval) {
        confirmedLineIndex = index
        if let index, lines.indices.contains(index) {
            confirmedLineStart = lines[index].timestamp
            confirmedCrossMonotonic = monotonic
        } else {
            confirmedLineStart = nil
            confirmedCrossMonotonic = 0
        }
    }

    private func syncPublishedLineIndex(
        source: LineIndexSource,
        previousTime: TimeInterval? = nil,
        incomingTime: TimeInterval? = nil,
        presentationOffset: TimeInterval? = nil
    ) {
        let lines = liveLyrics
        let synchronized = liveLyricsAreSynchronized
        let time = incomingTime ?? presentationTimeNow(usingPresentationOffset: presentationOffset)
        let newIndex = LyricsTimeline.activeLineIndex(
            lines: lines,
            time: time,
            isSynchronized: synchronized
        )
        let nowMono = ProcessInfo.processInfo.systemUptime
        let previous = previousTime ?? time
        let delta = time - previous

        let suppress = source == .poll && LyricIndexAntiRegression.shouldSuppressPollRegression(
            isPlaying: isPlaying,
            proposedIndex: newIndex,
            currentIndex: liveCurrentLineIndex,
            confirmedIndex: confirmedLineIndex,
            confirmedLineStart: confirmedLineStart,
            incomingTime: time,
            nowMonotonic: nowMono,
            confirmedAtMonotonic: confirmedCrossMonotonic
        )

#if DEBUG
        if newIndex != liveCurrentLineIndex || suppress {
            let lineStart = (suppress ? liveCurrentLineIndex : newIndex).flatMap { index -> TimeInterval? in
                guard lines.indices.contains(index) else { return nil }
                return lines[index].timestamp
            }
            let startText = lineStart.map { String(format: "%.3f", $0) } ?? "nil"
            let timeText = String(format: "%.3f", time)
            let prevText = String(format: "%.3f", previous)
            let deltaText = String(format: "%.3f", delta)
            let monoText = String(format: "%.3f", nowMono)
            let oldText = liveCurrentLineIndex.map(String.init) ?? "nil"
            let newText = newIndex.map(String.init) ?? "nil"
            LyricsE2ELog.log(
                "[LINE_INDEX] reason=\(source.rawValue) suppress=\(suppress) previousTime=\(prevText) incoming=\(timeText) delta=\(deltaText) LINE_START_TIME=\(startText) PRESENTATION_CLOCK_CROSS_TIME=\(timeText) INDEX_CHANGE_TIME=\(monoText) STATE_PUBLISH_TIME=\(monoText) old=\(oldText) proposed=\(newText)"
            )
        }
#endif

        if suppress {
            scheduleLineBoundaryWake(lines: lines, synchronized: synchronized, time: time)
            return
        }

        if source == .seek || source == .reset || source == .lyricsSession {
            rememberConfirmedLine(index: newIndex, lines: lines, at: nowMono)
        }

        if newIndex != liveCurrentLineIndex {
            liveCurrentLineIndex = newIndex
            if let newIndex, let old = confirmedLineIndex {
                if newIndex >= old {
                    rememberConfirmedLine(index: newIndex, lines: lines, at: nowMono)
                } else if source != .poll {
                    rememberConfirmedLine(index: newIndex, lines: lines, at: nowMono)
                }
            } else {
                rememberConfirmedLine(index: newIndex, lines: lines, at: nowMono)
            }
        }

        scheduleLineBoundaryWake(lines: lines, synchronized: synchronized, time: time)
    }

    private func scheduleLineBoundaryWake(
        lines: [LyricLine],
        synchronized: Bool,
        time: TimeInterval
    ) {
        cancelLineBoundaryWake()
        guard !isMockPreviewMode, isPlaying, synchronized, hasLiveTrack else { return }
        guard let boundary = LyricsTimeline.nextBoundaryTime(
            lines: lines,
            currentIndex: liveCurrentLineIndex,
            isSynchronized: synchronized
        ) else {
            return
        }
        let delay = boundary - time
        let generation = lineBoundaryGeneration
        guard delay > 0.0005 else { return }
        let nanoseconds = UInt64(min(delay, 3600) * 1_000_000_000)
        lineBoundaryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            guard let self, self.lineBoundaryGeneration == generation else { return }
            self.syncPublishedLineIndex(source: .boundary)
        }
    }

    public var presentationClock: LyricsPresentationClock {
        LyricsPresentationClock(
            authoritativePosition: playbackAnchorPosition,
            receivedAtMonotonicTime: playbackAnchorMonotonic,
            isPlaying: isPlaying,
            trackID: currentTrack.id,
            trackDuration: currentTrack.duration,
            presentationOffset: settingsStore.lyricsOffsetStore.activeOffset
        )
    }

    private func syncLiveLyricsOffsetScope() {
        syncLiveLyricsOffsetScope(lyricsVersionID: lyricsSession.activeLyricsVersionID)
    }

    private func syncLiveLyricsOffsetScope(lyricsVersionID: UUID?) {
        guard hasLiveTrack,
              !isMockPreviewMode,
              let identity = lyricsSession.activeIdentity,
              identity == liveTrackIdentity,
              let versionID = lyricsVersionID else {
            lyricsOffsetScopeBinding?.clear()
            return
        }
        lyricsOffsetScopeBinding?.bind(
            trackStableKey: identity.stableKey,
            lyricsVersionID: versionID,
            sessionRevision: lyricsSession.revision,
            resolver: lyricsRepository
        )
    }
}

private extension Track {
    static let emptyPlaybackPlaceholder = Track(
        id: "no-live-track",
        title: "等待 Spotify 播放",
        artist: "Spotify Desktop",
        album: "",
        duration: 0,
        artworkName: "music.note"
    )

    init(providerTrack: ProviderTrack) {
        let fallbackID = TrackIdentity.metadataFingerprint(
            title: providerTrack.title,
            artist: providerTrack.artist,
            album: providerTrack.album,
            duration: providerTrack.duration
        )
        self.init(
            id: providerTrack.id ?? "metadata-\(fallbackID)",
            title: providerTrack.title,
            artist: providerTrack.artist,
            album: providerTrack.album,
            duration: providerTrack.duration,
            artworkName: "music.note",
            isrc: providerTrack.isrc,
            spotifyId: providerTrack.id,
            artworkURL: providerTrack.artworkURL,
            spotifyURL: providerTrack.spotifyURL
        )
    }
}
