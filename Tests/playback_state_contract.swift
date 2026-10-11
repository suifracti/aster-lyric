import Foundation

/// The playback slice contract does not compile the capture/alignment graph.
/// Keep a protocol-shaped stand-in so PlaybackState can still be tested in
/// isolation when it notifies the product controller.
@MainActor
final class AutomaticAlignmentJobController {
    static let shared = AutomaticAlignmentJobController()

    func bind(playback: PlaybackState) {}
    func notePlaybackContextChanged() {}
    func notifySeek(from: TimeInterval, to: TimeInterval) {}
    func notifyTrackChanged(previousKey: String?, nextKey: String) {}
    func notifyPlaybackSourceChanged(previous: PlaybackSourceIdentity, next: PlaybackSourceIdentity) {}
}

/// The playback contract does not exercise audio capture. Keep its unrelated
/// Assist collaborator isolated so this focused slice does not compile or run
/// the ScreenCaptureKit pipeline.
struct PartialAlignmentReport {
    struct Candidate {
        let captureSessionID: UUID
    }

    let candidate: Candidate
}

@MainActor
final class LiveCaptureCoordinator {
    enum State { case idle, running, stopping, failed }
    enum PartialAlignmentFailureKind: String {
        case startIgnored, unsupportedSource, captureFailed, noCompletedSession
        case noWavSegments, noLyrics, noPlayback, speechFailed, alignmentFailed
        case cancelled, emptyTranscript, insufficientSuggestions, unknown
    }
    enum StopReason { case userStop, trackChanged }

    struct PartialAlignmentHandoff {
        let generation: UInt64
        let report: PartialAlignmentReport?
        let failureKind: PartialAlignmentFailureKind?
        let message: String?
    }

    static let shared = LiveCaptureCoordinator()
    var state: State = .idle
    var lastError: String?
    var lastStartedGeneration: UInt64 = 0
    var lastAlignmentHandoff: PartialAlignmentHandoff?
    var lastPartialReport: PartialAlignmentReport?

    func bind(playback: PlaybackState) {}
    func start(autoStopAfter: TimeInterval, runPartialAlignment: Bool) async {}
    func waitUntilIdle(timeoutSeconds: TimeInterval) async {}
    func stop(reason: StopReason) async {}
}

enum AssistedCandidateMerger {
    static func merge(report: PartialAlignmentReport, plainLines: [LyricLine]) -> AssistedAlignmentDraft {
        AssistedAlignmentDraft(
            trackIdentityDigest: "",
            captureSessionID: report.candidate.captureSessionID,
            plainLineCount: plainLines.count,
            lines: [],
            usedConstrainedAlignment: false,
            s3bFallbackReason: nil,
            judgment: "not exercised by playback state contract"
        )
    }
}

@MainActor
private final class ScriptedPlaybackProvider: PlaybackProvider {
    let displayName = "scripted-playback"
    private(set) var commandLog: [String] = []
    private(set) var refreshCalls = 0
    var snapshot: PlaybackSnapshot

    init(snapshot: PlaybackSnapshot) {
        self.snapshot = snapshot
    }

    func refresh() async -> PlaybackSnapshot {
        refreshCalls += 1
        return snapshot
    }

    func play() async throws {
        commandLog.append("play")
        snapshot = PlaybackSnapshot(
            status: snapshot.status,
            track: snapshot.track,
            position: snapshot.position,
            isPlaying: true
        )
    }

    func pause() async throws {
        commandLog.append("pause")
        snapshot = PlaybackSnapshot(
            status: snapshot.status,
            track: snapshot.track,
            position: snapshot.position,
            isPlaying: false
        )
    }

    func previous() async throws {
        commandLog.append("previous")
    }

    func next() async throws {
        commandLog.append("next")
    }

    func seek(to position: TimeInterval) async throws {
        commandLog.append("seek:\(Int(position))")
        snapshot = PlaybackSnapshot(
            status: snapshot.status,
            track: snapshot.track,
            position: position,
            isPlaying: snapshot.isPlaying
        )
    }
}

private actor CountingLyricsProvider: LyricsProvider {
    nonisolated let name = "counting-lyrics-test"
    private(set) var lookupCalls = 0
    private let lookupStartedStream: AsyncStream<Void>
    private let lookupStartedContinuation: AsyncStream<Void>.Continuation

    init() {
        let lookupStarted = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.lookupStartedStream = lookupStarted.stream
        self.lookupStartedContinuation = lookupStarted.continuation
    }

    func lookup(track: Track, identity: TrackIdentity) async -> LyricsLookupResult {
        lookupCalls += 1
        lookupStartedContinuation.yield(())
        lookupStartedContinuation.finish()
        return .noLyrics
    }

    func waitForLookup(timeoutNanoseconds: UInt64) async -> Bool {
        let stream = lookupStartedStream
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in stream {
                    return true
                }
                return false
            }
            group.addTask {
                do {
                    try await Task.sleep(nanoseconds: timeoutNanoseconds)
                    return false
                } catch {
                    return false
                }
            }

            let didLookupStart = await group.next() ?? false
            group.cancelAll()
            return didLookupStart
        }
    }
}

@MainActor
private final class DelayedRefreshProvider: PlaybackProvider {
    let displayName = "delayed-refresh"
    let staleSnapshot: PlaybackSnapshot
    var latestSnapshot: PlaybackSnapshot
    private var refreshCount = 0

    init(staleSnapshot: PlaybackSnapshot, latestSnapshot: PlaybackSnapshot) {
        self.staleSnapshot = staleSnapshot
        self.latestSnapshot = latestSnapshot
    }

    func refresh() async -> PlaybackSnapshot {
        refreshCount += 1
        if refreshCount == 1 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            return staleSnapshot
        }
        return latestSnapshot
    }

    func play() async throws {}
    func pause() async throws {}
    func previous() async throws {}
    func next() async throws {}
    func seek(to position: TimeInterval) async throws {}
}

private struct NoLyricsProvider: LyricsProvider {
    var name: String { "no-lyrics-test" }

    func lookup(track: Track, identity: TrackIdentity) async -> LyricsLookupResult {
        .noLyrics
    }
}

private struct NetworkFailureLyricsProvider: LyricsProvider {
    var name: String { "network-failure-test" }

    func lookup(track: Track, identity: TrackIdentity) async -> LyricsLookupResult {
        .failed(.networkUnavailable)
    }
}

@main
@MainActor
struct PlaybackStateContract {
    static func main() async {
        guard let rootPath = ProcessInfo.processInfo.environment["LYRICSQ_M1_PLAYBACK_ROOT"] else {
            fatalError("task-private playback root required")
        }
        let root = URL(fileURLWithPath: rootPath).resolvingSymlinksInPath()
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath()
        precondition(root.lastPathComponent.hasPrefix("lyricsq-m1-playback-"))
        precondition(FileManager.default.fileExists(atPath: root.path))
        precondition(home == root.appendingPathComponent("home"), "preferences must be task isolated")
        let actualDatabase = SQLiteLyricsRepository.defaultDatabaseURL
        let actualParent = actualDatabase.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let normalizedDatabase = actualParent.appendingPathComponent(actualDatabase.lastPathComponent, isDirectory: false)
        let expectedDatabase = root.appendingPathComponent("contract.sqlite3", isDirectory: false)
        let rootAttributes = try! FileManager.default.attributesOfItem(atPath: root.path)
        let homeAttributes = try! FileManager.default.attributesOfItem(atPath: home.path)
#if DEBUG
        print("PREFLIGHT DEBUG=true overrideSet=\(ProcessInfo.processInfo.environment["SPOTIFYLYRICS_DATABASE_PATH"] != nil)")
#else
        fatalError("playback isolation requires DEBUG")
#endif
        print("PREFLIGHT actualRaw=\(actualDatabase.path) actualNormalized=\(normalizedDatabase.path) expectedNormalized=\(expectedDatabase.path) home=\(home.path) rootUID=\(rootAttributes[.ownerAccountID]!)")
        precondition((rootAttributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid())
        precondition((homeAttributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid())
        precondition((rootAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        precondition((homeAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        precondition(actualParent.pathComponents == root.pathComponents && normalizedDatabase.pathComponents == expectedDatabase.pathComponents)
        precondition(!FileManager.default.fileExists(atPath: actualDatabase.path), "contract requires a fresh task database")
        precondition(normalizedDatabase.pathComponents != DebugDatabaseSafety.status().formalDatabaseURL.standardizedFileURL.pathComponents)
        precondition(SpotifyOAuthConfiguration.resolved().clientID == nil, "OAuth must be unconfigured before auth initialization")
        print("PASS playback isolation preflight: private home/database; OAuth unconfigured, no token loading")
        let trackA = ProviderTrack(
            id: "spotify:track:a",
            title: "Track A",
            artist: "Artist A",
            album: "Album A",
            duration: 240,
            artworkURL: URL(string: "https://example.test/a.jpg")
        )
        let trackB = ProviderTrack(
            id: "spotify:track:b",
            title: "Track B",
            artist: "Artist B",
            album: "Album B",
            duration: 300,
            artworkURL: URL(string: "https://example.test/b.jpg")
        )

        let startupSuite = ProcessInfo.processInfo.environment["LYRICSQ_PLAYBACK_CONTRACT_SUITE"]
            ?? "LyricsQPlaybackStateContract-\(UUID().uuidString)"
        let startupDefaults = UserDefaults(suiteName: startupSuite)!
        let startupSettings = AppSettingsStore(defaults: startupDefaults)
        startupSettings.playbackSourceMode = .spotify
        startupSettings.autoSearchLyricsOnTrackChange = true
        let startupLyricsProvider = CountingLyricsProvider()
        let startupProvider = ScriptedPlaybackProvider(
            snapshot: PlaybackSnapshot(status: .ready, track: trackA, position: 12, isPlaying: true)
        )
        let startupState = PlaybackState(
            provider: startupProvider,
            lyricsProvider: startupLyricsProvider,
            settings: startupSettings
        )
        startupState.startProvider(connectSpotify: false)
        try? await Task.sleep(nanoseconds: 1_300_000_000)
        precondition(startupProvider.refreshCalls == 0, "disabled Spotify startup must not refresh on timer ticks")
        precondition(!startupState.hasLiveTrack, "disabled Spotify startup must not adopt a live track")
        precondition(startupState.currentTrackIdentity == nil, "disabled Spotify startup must not create a live identity")
        let startupLookupCalls = await startupLyricsProvider.lookupCalls
        precondition(startupLookupCalls == 0, "disabled Spotify startup must not query lyrics")

        startupState.reconnectSpotify()
        for _ in 0..<50 {
            if startupProvider.refreshCalls > 0, startupState.hasLiveTrack {
                break
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        precondition(startupProvider.refreshCalls > 0, "explicit reconnect must refresh the provider")
        precondition(startupState.hasLiveTrack, "explicit reconnect must adopt the authorized track")
        precondition(startupState.currentTrack.title == "Track A")
        precondition(
            startupState.currentTrackIdentity?.stableKey.contains("spotify-id:a") == true,
            "explicit reconnect must adopt Track A identity"
        )
        let lookupStarted = await startupLyricsProvider.waitForLookup(timeoutNanoseconds: 3_000_000_000)
        let reconnectLookupCalls = await startupLyricsProvider.lookupCalls
        let reconnectIdentity = startupState.currentTrackIdentity?.stableKey ?? "none"
        precondition(
            lookupStarted,
            "stage=explicit-reconnect.await-fake-lookup-entry timeout=3s lookupCalls=\(reconnectLookupCalls) " +
                "refreshCalls=\(startupProvider.refreshCalls) hasLiveTrack=\(startupState.hasLiveTrack) " +
                "track=\(startupState.currentTrack.title) identity=\(reconnectIdentity) " +
                "sessionRevision=\(startupState.lyricsSession.revision) " +
                "sessionState=\(String(describing: startupState.lyricsSession.state)) " +
                "autoSearch=\(startupSettings.autoSearchLyricsOnTrackChange) " +
                "activeLyricsDocument=\(startupState.lyricsSession.activeDocument != nil) " +
                "database=isolated-fresh-SQLite generation=not-publicly-exposed"
        )
        precondition(reconnectLookupCalls > 0, "explicit reconnect must preserve automatic lyrics search")
        startupDefaults.removePersistentDomain(forName: startupSuite)

        for sourceMode in [PlaybackSourceMode.auto, .appleMusic] {
            let suite = "LyricsQPlaybackStateContract-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            let settings = AppSettingsStore(defaults: defaults)
            settings.playbackSourceMode = sourceMode
            let sourceIdentity: PlaybackSourceIdentity = sourceMode == .appleMusic ? .appleMusic : .spotifyDesktop
            let modeProvider = ScriptedPlaybackProvider(
                snapshot: PlaybackSnapshot(
                    status: .ready,
                    track: trackA,
                    position: 12,
                    isPlaying: true,
                    sourceIdentity: sourceIdentity
                )
            )
            let modeState = PlaybackState(
                provider: modeProvider,
                lyricsProvider: NoLyricsProvider(),
                settings: settings
            )
            modeState.startProvider(connectSpotify: false)
            for _ in 0..<90 {
                if modeProvider.refreshCalls > 0, modeState.hasLiveTrack {
                    break
                }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            precondition(modeProvider.refreshCalls > 0, "\(sourceMode.rawValue) startup must retain provider discovery")
            precondition(modeState.hasLiveTrack, "\(sourceMode.rawValue) startup must retain track adoption")
            defaults.removePersistentDomain(forName: suite)
        }

        let provider = ScriptedPlaybackProvider(
            snapshot: PlaybackSnapshot(status: .ready, track: trackA, position: 12, isPlaying: true)
        )
        let state = PlaybackState(provider: provider, lyricsProvider: NoLyricsProvider())
        state.startProvider()
        try? await Task.sleep(nanoseconds: 60_000_000)

        precondition(state.hasLiveTrack)
        precondition(state.currentTrack.title == "Track A")
        precondition(state.currentTrackIdentity?.stableKey.contains("spotify-id:a") == true)
        precondition(state.currentTime >= 12)

        state.togglePlayPause()
        try? await Task.sleep(nanoseconds: 320_000_000)
        precondition(provider.commandLog.contains("pause"))
        precondition(!state.isPlaying)

        state.togglePlayPause()
        try? await Task.sleep(nanoseconds: 320_000_000)
        precondition(provider.commandLog.contains("play"))
        precondition(state.isPlaying)

        state.seek(to: 88)
        try? await Task.sleep(nanoseconds: 320_000_000)
        precondition(provider.commandLog.contains("seek:88"))
        precondition(abs(state.currentTime - 88) < 2)

        let timeBeforeInvalidSeek = state.currentTime
        state.seek(to: .nan, source: "invalid-test")
        state.seek(to: 999, source: "invalid-test")
        try? await Task.sleep(nanoseconds: 120_000_000)
        precondition(abs(state.currentTime - timeBeforeInvalidSeek) < 1)

        let recoveryState = PlaybackState(provider: provider, lyricsProvider: NetworkFailureLyricsProvider())
        recoveryState.startProvider()
        try? await Task.sleep(nanoseconds: 80_000_000)
        let recoveryTime = recoveryState.currentTime
        precondition(recoveryState.lyricsState.identity == recoveryState.currentTrackIdentity)
        recoveryState.retryLyrics()
        try? await Task.sleep(nanoseconds: 30_000_000)
        precondition(abs(recoveryState.currentTime - recoveryTime) < 1)

        provider.snapshot = PlaybackSnapshot(status: .ready, track: trackB, position: 4, isPlaying: false)
        state.nextTrack()
        try? await Task.sleep(nanoseconds: 320_000_000)
        precondition(provider.commandLog.contains("next"))
        precondition(state.currentTrack.title == "Track B")
        precondition(state.currentTrackIdentity?.stableKey.contains("spotify-id:b") == true)
        precondition(state.currentTime == 4)
        precondition(state.lyrics.isEmpty)

        provider.snapshot = PlaybackSnapshot(status: .ready, track: trackA, position: 3, isPlaying: false)
        state.previousTrack()
        try? await Task.sleep(nanoseconds: 320_000_000)
        precondition(provider.commandLog.contains("previous"))
        precondition(state.currentTrack.title == "Track A")

        provider.snapshot = PlaybackSnapshot(status: .notRunning, track: nil, position: 0, isPlaying: false)
        state.reconnectSpotify()
        precondition(!state.hasLiveTrack)
        precondition(state.lyrics.isEmpty)
        try? await Task.sleep(nanoseconds: 80_000_000)
        precondition(!state.hasLiveTrack)
        precondition(state.lyrics.isEmpty)

        provider.snapshot = PlaybackSnapshot(status: .ready, track: trackB, position: 9, isPlaying: true)
        state.reconnectSpotify()
        try? await Task.sleep(nanoseconds: 80_000_000)
        precondition(state.hasLiveTrack)
        precondition(state.currentTrack.title == "Track B")
        precondition(state.currentTime >= 9)

        let raceProvider = DelayedRefreshProvider(
            staleSnapshot: PlaybackSnapshot(status: .ready, track: trackA, position: 1, isPlaying: false),
            latestSnapshot: PlaybackSnapshot(status: .ready, track: trackB, position: 7, isPlaying: false)
        )
        let raceState = PlaybackState(provider: raceProvider, lyricsProvider: NoLyricsProvider())
        raceState.startProvider()
        try? await Task.sleep(nanoseconds: 20_000_000)
        raceProvider.latestSnapshot = PlaybackSnapshot(status: .ready, track: trackB, position: 7, isPlaying: false)
        raceState.reconnectSpotify()
        try? await Task.sleep(nanoseconds: 450_000_000)
        precondition(raceState.currentTrack.title == "Track B")
        precondition(raceState.currentTime == 7)

        print("playback state contract passed")
    }
}
