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
    var holdNext = false
    var pending: CheckedContinuation<PlaybackSnapshot, Never>?
    var artwork: URL?
    var artworkRequests = 0
    func artworkURL(for track: ProviderTrack, source: PlaybackSourceIdentity) async -> URL? {
        artworkRequests += 1
        return artwork
    }
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
    func seek(to position: TimeInterval) async throws {}
}

private struct EventOfflineLyrics: LyricsProvider {
    let name = "Offline event fixture"
    let executionLane = LyricsProviderExecutionLane.local
    func lookup(track: Track, identity: TrackIdentity) async -> LyricsLookupResult { .noMatch }
}

@MainActor
final class DesktopPlaybackEventTests: XCTestCase {
    func testDistributedTransportDeliversAnIsolatedPrivateNotification() async throws {
        let center = DistributedNotificationCenter.default()
        let name = Notification.Name("com.lyricsq.tests.\(UUID().uuidString)")
        let delivery = expectation(description: "distributed transport")
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in delivery.fulfill() }
        defer { center.removeObserver(token) }
        center.postNotificationName(name, object: nil, userInfo: ["fixture": true], deliverImmediately: true)
        await fulfillment(of: [delivery], timeout: 3)
    }

    func testSparseCaptureSamplesDoNotTurnNormalProgressIntoASeek() {
        XCTAssertFalse(CaptureContinuityPolicy.isSeek(previousPosition: 10, position: 20,
            elapsed: 10, wasPlaying: true))
        XCTAssertTrue(CaptureContinuityPolicy.isSeek(previousPosition: 10, position: 3,
            elapsed: 10, wasPlaying: true))
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

    func testSpotifyAndMusicNotificationMetadataAndUnits() throws {
        let spotify = try XCTUnwrap(DesktopPlaybackUpdate.decode(name: DesktopPlaybackEvents.spotifyPlaybackChanged, userInfo: payload()))
        let snapshot = try XCTUnwrap(spotify.snapshot(previous: nil, estimatedPosition: 0))
        XCTAssertEqual(snapshot.track?.duration, 240)
        XCTAssertEqual(snapshot.position, 32)
        XCTAssertEqual(snapshot.sourceIdentity, .spotifyDesktop)
        let music = try XCTUnwrap(DesktopPlaybackUpdate.decode(name: DesktopPlaybackEvents.musicPlayerInfo,
            userInfo: ["Player State": "Paused", "PersistentID": "A1B2C3D4", "Name": "Music", "Artist": "Singer", "Total Time": 125_000, "Player Position": 17]))
        let m = try XCTUnwrap(music.snapshot(previous: nil, estimatedPosition: 17))
        XCTAssertEqual(m.track?.id, "applemusic:A1B2C3D4")
        XCTAssertEqual(m.track?.duration, 125)
        XCTAssertFalse(m.isPlaying)
        XCTAssertEqual(m.position, 17)
        XCTAssertNil(DesktopPlaybackUpdate.decode(name: DesktopPlaybackEvents.spotifyPlaybackChanged,
            userInfo: ["Player State": "unknown"]))
    }

    func testActualNotificationDeliveryChangesTrackAndPauseWithoutPolling() async throws {
        let (state, provider, _, center) = fixture()
        state.startProvider()
        try await wait { state.hasLiveTrack }
        let initialRefreshes = provider.refreshes
        center.post(name: DesktopPlaybackEvents.spotifyPlaybackChanged, object: nil, userInfo: payload())
        try await wait { state.currentTrack.title == "Event B" }
        XCTAssertEqual(state.currentTime, 32, accuracy: 0.2)
        center.post(name: DesktopPlaybackEvents.spotifyPlaybackChanged, object: nil, userInfo: payload(state: "Paused", position: 34))
        try await wait { !state.isPlaying }
        XCTAssertNil(state.timer)
        XCTAssertNil(state.calibrationTimer)
        await state.calibratePlaybackPositionIfNeeded()
        XCTAssertEqual(provider.refreshes, initialRefreshes)
        center.post(name: DesktopPlaybackEvents.spotifyPlaybackChanged, object: nil, userInfo: payload(state: "Playing", position: 35))
        try await wait { state.isPlaying }
        XCTAssertNotNil(state.timer)
        XCTAssertEqual(state.currentTime, 35, accuracy: 0.2)
    }

    func testAutoModeBootstrapsWhenSpotifyOnlyLaunchConnectionIsDisabled() async throws {
        let (state, provider, _, _) = fixture()
        state.startProvider(connectSpotify: false)
        try await wait { state.hasLiveTrack }
        XCTAssertEqual(provider.refreshes, 1)
        XCTAssertEqual(state.playbackSourceIdentity, .spotifyDesktop)
    }

    func testTrackEventLoadsMissingArtworkOnceWithoutStatusPolling() async throws {
        let (state, provider, _, center) = fixture()
        state.startProvider()
        try await wait { state.hasLiveTrack }
        provider.artwork = URL(string: "https://example.invalid/fixture.jpg")
        center.post(name: DesktopPlaybackEvents.spotifyPlaybackChanged, object: nil, userInfo: payload())
        try await wait { state.currentTrack.artworkURL == provider.artwork }
        center.post(name: DesktopPlaybackEvents.spotifyPlaybackChanged, object: nil, userInfo: payload())
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(provider.artworkRequests, 1)
        XCTAssertEqual(provider.refreshes, 1, "cover loading must not restart status polling")
    }

    func testHiddenWindowsStopClockAndShowingCatchesUpImmediately() async throws {
        var visible = false
        let (state, _, _, _) = fixture(visible: { visible })
        state.startProvider()
        try await wait { state.hasLiveTrack }
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

    func testCalibrationCannotReplaceEventIdentityOrPlaybackState() async throws {
        let (state, provider, _, center) = fixture()
        state.startProvider()
        try await wait { state.hasLiveTrack }
        center.post(name: DesktopPlaybackEvents.spotifyPlaybackChanged, object: nil, userInfo: payload())
        try await wait { state.currentTrack.title == "Event B" }
        await state.calibratePlaybackPositionIfNeeded()
        XCTAssertEqual(provider.refreshes, 2)
        XCTAssertEqual(state.currentTrack.title, "Event B", "old-track calibration cannot retarget the session")
        XCTAssertEqual(state.currentTime, 32, accuracy: 0.3)
    }

    func testCalibrationCanRecoverAMissedPauseForTheSameRecording() async throws {
        let (state, provider, _, _) = fixture()
        state.startProvider()
        try await wait { state.hasLiveTrack }
        provider.snapshot = PlaybackSnapshot(status: .ready, track: provider.snapshot.track,
            position: 12, isPlaying: false, sourceIdentity: .spotifyDesktop)
        await state.calibratePlaybackPositionIfNeeded()
        XCTAssertFalse(state.isPlaying)
        XCTAssertEqual(state.currentTime, 12, accuracy: 0.01)
        XCTAssertNil(state.timer)
        XCTAssertNil(state.calibrationTimer)
    }

    func testPartialPauseUsesCachedMetadataAndAutoIgnoresOtherPausedPlayer() async throws {
        let (state, provider, _, center) = fixture()
        state.startProvider()
        try await wait { state.hasLiveTrack }
        center.post(name: DesktopPlaybackEvents.musicPlayerInfo, object: nil,
            userInfo: ["Player State": "Paused", "PersistentID": "ABC", "Name": "Background", "Artist": "Other", "Total Time": 100_000])
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(state.playbackSourceIdentity, .spotifyDesktop)
        center.post(name: DesktopPlaybackEvents.spotifyPlaybackChanged, object: nil,
            userInfo: ["Player State": "Paused", "Playback Position": 12])
        try await wait { !state.isPlaying }
        XCTAssertEqual(state.currentTrack.title, "Initial")
        XCTAssertEqual(state.currentTime, 12, accuracy: 0.01)
        center.post(name: DesktopPlaybackEvents.musicPlayerInfo, object: nil,
            userInfo: ["Player State": "Playing", "PersistentID": "ABC", "Name": "Foreground", "Artist": "Other", "Total Time": 100_000])
        try await wait { state.playbackSourceIdentity == .appleMusic }
        XCTAssertEqual(state.currentTrack.title, "Foreground")
        XCTAssertEqual(state.currentTime, 0, accuracy: 0.1, "a new recording cannot inherit the other player's position")
        XCTAssertEqual(provider.refreshes, 1)
    }

    func testPauseAndTerminationStillApplyAfterATransientSourceFailure() async throws {
        let (state, provider, events, center) = fixture()
        state.startProvider()
        try await wait { state.hasLiveTrack }
        provider.snapshot = PlaybackSnapshot(status: .unavailable("timeout"), track: nil,
            position: 0, isPlaying: false, sourceIdentity: .spotifyDesktop)
        await state.calibratePlaybackPositionIfNeeded()
        XCTAssertEqual(state.playbackSourceIdentity, .unknown)
        try await Task.sleep(nanoseconds: 250_000_000)
        let beforePause = state.currentTime
        center.post(name: DesktopPlaybackEvents.spotifyPlaybackChanged, object: nil,
            userInfo: ["Player State": "Paused"])
        try await wait { !state.isPlaying }
        XCTAssertGreaterThan(state.currentTime, beforePause - 0.05,
            "a partial pause must retain elapsed time after an unverified-source interval")
        center.post(name: DesktopPlaybackEvents.spotifyPlaybackChanged, object: nil, userInfo: payload())
        try await wait { state.isPlaying }
        await state.calibratePlaybackPositionIfNeeded()
        events.applicationChanged(source: .spotifyDesktop, isRunning: false)
        XCTAssertFalse(state.hasLiveTrack)
        XCTAssertNil(state.timer)
        XCTAssertNil(state.calibrationTimer)
    }

    func testUnidentifiedNewRecordingDoesNotInheritPreviousPosition() throws {
        let previous = PlaybackSnapshot(status: .ready,
            track: ProviderTrack(id: nil, title: "Old", artist: "Artist", album: "", duration: 240),
            position: 100, isPlaying: true, sourceIdentity: .spotifyDesktop)
        let update = try XCTUnwrap(DesktopPlaybackUpdate.decode(name: DesktopPlaybackEvents.spotifyPlaybackChanged,
            userInfo: ["Player State": "Playing", "Name": "New", "Artist": "Artist", "Duration": 240_000]))
        XCTAssertEqual(update.snapshot(previous: previous, estimatedPosition: 100)?.position, 0)
    }

    func testTransientCalibrationFailureRetainsGraceAndCanRecover() async throws {
        let (state, provider, _, _) = fixture()
        state.startProvider()
        try await wait { state.hasLiveTrack }
        let good = provider.snapshot
        provider.snapshot = PlaybackSnapshot(status: .unavailable("timeout fixture"), track: nil,
            position: 0, isPlaying: false, sourceIdentity: .spotifyDesktop)
        await state.calibratePlaybackPositionIfNeeded()
        XCTAssertTrue(state.hasLiveTrack, "a transient failure keeps the existing bounded grace")
        XCTAssertEqual(state.playbackSourceIdentity, .unknown, "an unverified source must not authorize live capture")
        XCTAssertNotNil(state.calibrationTimer, "a transient outage must not permanently disconnect the provider")
        provider.snapshot = good
        await state.calibratePlaybackPositionIfNeeded()
        XCTAssertEqual(provider.refreshes, 3)
        XCTAssertEqual(state.playbackSourceIdentity, .spotifyDesktop)
        XCTAssertTrue(state.hasLiveTrack)
    }
}
