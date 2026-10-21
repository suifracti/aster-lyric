import AppKit
import XCTest
@testable import SpotifyLyrics

@MainActor
private final class EventPlaybackProvider: PlaybackProvider {
    let displayName = "Event fixture"
    var snapshot = PlaybackSnapshot(status: .ready,
        track: ProviderTrack(id: "spotify:track:AAAAAAAAAAAAAAAAAAAAAA", title: "Initial", artist: "Fixture", album: "Cache", duration: 240),
        position: 10, isPlaying: true, sourceIdentity: .spotifyDesktop)
    var refreshes = 0
    var modes = PlayerPlaybackModes(shuffle: false, repeatMode: .off)
    var nativeRepeatWrites: [PlayerRepeatMode] = []
    var restartedTrackIDs: [String] = []
    func playbackModes(shuffle: Bool?, repeatMode: PlayerRepeatMode?) async throws -> PlayerPlaybackModes {
        if let shuffle { modes.shuffle = shuffle }
        if let repeatMode { modes.repeatMode = repeatMode; nativeRepeatWrites.append(repeatMode) }
        return modes
    }
    func restartTrack(id: String) async throws -> Bool {
        guard id == snapshot.track?.id else { return false }
        restartedTrackIDs.append(id)
        return true
    }
    var holdNext = false
    var pending: CheckedContinuation<PlaybackSnapshot, Never>?
    func refresh() async -> PlaybackSnapshot {
        refreshes += 1
        if holdNext {
            holdNext = false
            return await withCheckedContinuation { pending = $0 }
        }
        return snapshot
    }
    func play() async throws {}
    func pause() async throws {}
    func next() async throws {}
    func previous() async throws {}
    var seeks: [TimeInterval] = []
    func seek(to position: TimeInterval) async throws { seeks.append(position) }
}

private struct EventOfflineLyrics: LyricsProvider {
    let name = "Offline event fixture"
    let executionLane = LyricsProviderExecutionLane.local
    func lookup(track: Track, identity: TrackIdentity) async -> LyricsLookupResult { .noMatch }
}

@MainActor
final class DesktopPlaybackEventTests: XCTestCase {
    func testSpotifySingleRepeatCyclesAndRestartsTheSameTrackAtItsEnd() async throws {
        let desktop = SpotifyDesktopProvider(scriptRunner: { script, _ in
            XCTAssertTrue(script.contains("if (id of current track as text) is not \"spotify:track:AAAAAAAAAAAAAAAAAAAAAA\" then return \"false\""))
            XCTAssertTrue(script.contains("set player position to 0"))
            var compileError: NSDictionary?
            XCTAssertTrue(NSAppleScript(source: script)!.compileAndReturnError(&compileError), "\(String(describing: compileError))")
            return "true"
        }, applicationIsInstalled: { true }, applicationIsRunning: { true })
        let restarted = try await desktop.restartTrack(id: "spotify:track:AAAAAAAAAAAAAAAAAAAAAA")
        XCTAssertTrue(restarted)
        let (state, provider, _, center) = fixture()
        state.startProvider()
        try await wait { state.playerModes != nil }
        state.togglePlayerMode(shuffle: false)
        try await wait { state.playerModes?.repeatMode == .all }
        state.togglePlayerMode(shuffle: false)
        try await wait { state.playerModes?.repeatMode == .one }
        center.post(name: DesktopPlaybackEvents.spotifyPlaybackChanged, object: nil,
                    userInfo: ["Player State": "Playing", "Playback Position": 240])
        try await wait { !provider.restartedTrackIDs.isEmpty }
        XCTAssertEqual(provider.restartedTrackIDs, ["spotify:track:AAAAAAAAAAAAAAAAAAAAAA"])
        XCTAssertLessThan(state.currentTime, 1)
        XCTAssertTrue(state.isPlaying)
        state.togglePlayerMode(shuffle: false)
        try await wait { state.playerModes?.repeatMode == .off }
        XCTAssertEqual(provider.nativeRepeatWrites, [.all, .off, .off])
    }

    func testLyricLineRepeatsUntilCancelledAndStopsOnTrackChange() async throws {
        let (state, provider, _, center) = fixture()
        state.startProvider()
        try await wait { state.hasLiveTrack }
        let identity = try XCTUnwrap(state.currentTrackIdentity)
        let lines = [LyricLine(timestamp: 10, originalText: "One"), LyricLine(timestamp: 20, originalText: "Two")]
        state.lyricsSession.adopt(document: LyricsDocument(identity: identity, title: "Initial", artist: "Fixture",
            album: "Cache", duration: 240, lines: lines, isSynchronized: true, source: .manualCreate, confidence: 1))
        state.toggleLyricLineLoop(lineID: lines[0].id, documentIdentity: identity, documentRevision: state.liveLyricsSessionRevision)
        try await wait { provider.seeks.count == 1 }
        center.post(name: DesktopPlaybackEvents.spotifyPlaybackChanged, object: nil,
            userInfo: ["Player State": "Playing", "Playback Position": 20])
        try await wait { provider.seeks.count == 2 }
        XCTAssertEqual(provider.seeks, [10, 10])
        state.cancelLyricLineLoop()
        XCTAssertNil(state.loopedLyricLineID)
        state.toggleLyricLineLoop(lineID: lines[0].id, documentIdentity: identity, documentRevision: state.liveLyricsSessionRevision)
        center.post(name: DesktopPlaybackEvents.spotifyPlaybackChanged, object: nil, userInfo: payload())
        try await wait { state.currentTrack.title == "Event B" }
        XCTAssertNil(state.loopedLyricLineID)
    }

    private func payload(_ title: String = "Event B", state: String = "Playing", position: Double = 32) -> [AnyHashable: Any] {
        ["Player State": state, "Track ID": "spotify:track:BBBBBBBBBBBBBBBBBBBBBB",
         "Name": title, "Artist": "Fixture", "Album": "Cache", "Duration": 240_000,
         "Playback Position": position]
    }

    private func fixture(running: @escaping (PlaybackSourceIdentity) -> Bool = { _ in true },
                         visible: @escaping () -> Bool = { true }) -> (PlaybackState, EventPlaybackProvider, DesktopPlaybackEvents, NotificationCenter) {
        let suite = "lyricsq-events-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(false, forKey: AppSettingsStore.Key.autoSearchLyricsOnTrackChange)
        defaults.set(false, forKey: AppSettingsStore.Key.aiAutoTranslateNewLyrics)
        let settings = AppSettingsStore(defaults: defaults)
        settings.playbackSourceMode = .auto
        let root = NativeTestRuntime.root.appendingPathComponent(UUID().uuidString)
        let repository = SQLiteLyricsRepository(databaseURL: root.appendingPathComponent("test.sqlite3"),
            alignmentProvenanceDirectory: root.appendingPathComponent("provenance"))
        let center = NotificationCenter()
        let events = DesktopPlaybackEvents(center: center, workspaceCenter: NotificationCenter(),
            windowCenter: NotificationCenter(), applicationIsRunning: running)
        let provider = EventPlaybackProvider()
        let state = PlaybackState(provider: provider, lyricsProvider: EventOfflineLyrics(),
            lyricsRepository: repository, settings: settings, desktopEvents: events, lyricsWindowsVisible: visible)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return (state, provider, events, center)
    }

    private func wait(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Event did not arrive", file: file, line: line)
    }

    func testSongNotificationSwitchesTrackWithoutPolling() async throws {
        let (state, provider, _, center) = fixture()
        state.startProvider(connectSpotify: false)
        try await wait { state.hasLiveTrack }
        let initialRefreshes = provider.refreshes
        center.post(name: DesktopPlaybackEvents.spotifyPlaybackChanged, object: nil, userInfo: payload())
        try await wait { state.currentTrack.title == "Event B" }
        XCTAssertEqual(state.currentTime, 32, accuracy: 0.2)
        XCTAssertEqual(state.currentTrack.duration, 240)
        center.post(name: DesktopPlaybackEvents.musicPlayerInfo, object: nil,
            userInfo: ["Player State": "Playing", "PersistentID": "ABC", "Name": "Music C",
                       "Artist": "Fixture", "Total Time": 125_000, "Player Position": 7])
        try await wait { state.currentTrack.title == "Music C" }
        XCTAssertEqual(state.playbackSourceIdentity, .appleMusic)
        XCTAssertEqual(state.currentTrack.duration, 125)
        XCTAssertEqual(state.currentTime, 7, accuracy: 0.2)
        XCTAssertEqual(provider.refreshes, initialRefreshes)
    }

    func testPauseNotificationStopsPollingAndResumeRestartsClock() async throws {
        let (state, provider, _, center) = fixture()
        state.startProvider()
        try await wait { state.hasLiveTrack }
        let initialRefreshes = provider.refreshes
        let identity = state.currentTrackIdentity
        let revision = state.lyricsSession.revision
        // Spotify sent different display metadata on pause, with the same recording ID, artist and duration.
        var paused = payload("Stale display title", state: "Paused", position: 34)
        paused["Track ID"] = provider.snapshot.track!.id!
        paused["Album"] = "Stale display album"
        center.post(name: DesktopPlaybackEvents.spotifyPlaybackChanged, object: nil, userInfo: paused)
        try await wait { !state.isPlaying }
        XCTAssertEqual(state.currentTrack.title, "Initial")
        XCTAssertEqual(state.currentTime, 34, accuracy: 0.2)
        XCTAssertNil(state.timer)
        XCTAssertNil(state.calibrationTimer)
        await state.calibratePlaybackPositionIfNeeded()
        XCTAssertEqual(provider.refreshes, initialRefreshes)
        var resumed = paused
        resumed["Player State"] = "Playing"
        resumed["Playback Position"] = 35
        center.post(name: DesktopPlaybackEvents.spotifyPlaybackChanged, object: nil, userInfo: resumed)
        try await wait { state.isPlaying }
        XCTAssertNotNil(state.timer)
        XCTAssertEqual(state.currentTime, 35, accuracy: 0.2)
        XCTAssertEqual(state.currentTrackIdentity, identity)
        XCTAssertEqual(state.lyricsSession.revision, revision, "pause/resume must retain the loaded lyric document")
    }

    func testHiddenWindowsStopClockAndShowingCatchesUpImmediately() async throws {
        var visible = true
        let (state, _, _, _) = fixture(visible: { visible })
        state.startProvider()
        try await wait { state.hasLiveTrack }
        XCTAssertNotNil(state.timer)
        visible = false
        state.updatePlaybackVisibility()
        XCTAssertNil(state.timer)
        let before = state.currentTime
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(state.currentTime, before)
        visible = true
        state.updatePlaybackVisibility()
        XCTAssertNotNil(state.timer)
        XCTAssertGreaterThan(state.currentTime, before + 0.15)
        visible = false
        state.updatePlaybackVisibility()
        XCTAssertNil(state.timer)
    }

    func testStoppedPlayerDoesNotCalibrateAndTerminationClearsImmediately() async throws {
        var running = true
        let (state, provider, events, _) = fixture(running: { _ in running })
        state.startProvider()
        try await wait { state.hasLiveTrack }
        running = false
        await state.calibratePlaybackPositionIfNeeded()
        XCTAssertEqual(provider.refreshes, 1)
        events.applicationChanged(source: .spotifyDesktop, isRunning: false)
        XCTAssertFalse(state.hasLiveTrack)
        XCTAssertEqual(state.providerStatus, .notRunning)
        XCTAssertNil(state.timer)
        XCTAssertNil(state.calibrationTimer)
    }

    func testNewNotificationWinsOverAnInflightOldPoll() async throws {
        let (state, provider, _, center) = fixture()
        state.startProvider()
        try await wait { state.hasLiveTrack }
        provider.holdNext = true
        let refresh = Task { await state.calibratePlaybackPositionIfNeeded() }
        try await wait { provider.pending != nil }
        await state.calibratePlaybackPositionIfNeeded()
        XCTAssertEqual(provider.refreshes, 2, "calibration remains single-flight")
        center.post(name: DesktopPlaybackEvents.spotifyPlaybackChanged, object: nil, userInfo: payload(state: "Paused"))
        try await wait { state.currentTrack.title == "Event B" && !state.isPlaying }
        provider.pending?.resume(returning: provider.snapshot)
        provider.pending = nil
        await refresh.value
        XCTAssertEqual(state.currentTrack.title, "Event B")
        XCTAssertFalse(state.isPlaying)
        XCTAssertEqual(provider.refreshes, 2, "notification must not queue another AppleScript read")
    }
}
