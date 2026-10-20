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
        center.post(name: DesktopPlaybackEvents.spotifyPlaybackChanged, object: nil,
            userInfo: ["Player State": "Paused", "Playback Position": 34])
        try await wait { !state.isPlaying }
        XCTAssertEqual(state.currentTrack.title, "Initial")
        XCTAssertEqual(state.currentTime, 34, accuracy: 0.2)
        XCTAssertNil(state.timer)
        XCTAssertNil(state.calibrationTimer)
        await state.calibratePlaybackPositionIfNeeded()
        XCTAssertEqual(provider.refreshes, initialRefreshes)
        center.post(name: DesktopPlaybackEvents.spotifyPlaybackChanged, object: nil, userInfo: payload(state: "Playing", position: 35))
        try await wait { state.isPlaying }
        XCTAssertNotNil(state.timer)
        XCTAssertEqual(state.currentTime, 35, accuracy: 0.2)
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
