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
    var artworkResult: URL?
    func artworkURL(for track: ProviderTrack, source: PlaybackSourceIdentity) async -> URL? { artworkResult ?? track.artworkURL }
    var modes = PlayerPlaybackModes(shuffle: false, repeatMode: .off)
    var modeReadFails = false
    var nativeShuffleWrites: [Bool] = []
    var nativeRepeatWrites: [PlayerRepeatMode] = []
    var webReadbackOverride: PlayerPlaybackModes?
    var webWriteError: Error?
    var webRepeatWrites: [PlayerRepeatMode] = []
    var webShuffleWrites: [Bool] = []
    func playbackModes(shuffle: Bool?, repeatMode: PlayerRepeatMode?) async throws -> PlayerPlaybackModes {
        if let shuffle { modes.shuffle = shuffle; modes.smartShuffle = false; nativeShuffleWrites.append(shuffle) }
        if let repeatMode { modes.repeatMode = repeatMode; nativeRepeatWrites.append(repeatMode) }
        return modes
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
    func testSpotifyWebRepeatUsesThreeNativeStatesWithoutSeeking() async throws {
        let (state, provider, _, center) = fixture()
        state.startProvider()
        try await wait { state.playerModes != nil }
        for mode in [PlayerRepeatMode.all, .one, .off] {
            state.togglePlayerMode(shuffle: false)
            try await wait { state.playerModes?.repeatMode == mode }
        }
        XCTAssertEqual(provider.webRepeatWrites, [.all, .one, .off])
        XCTAssertTrue(provider.nativeRepeatWrites.isEmpty)
        center.post(name: DesktopPlaybackEvents.spotifyPlaybackChanged, object: nil,
                    userInfo: ["Player State": "Playing", "Playback Position": 240])
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(provider.seeks.isEmpty)
        // HTTP 403 falls back to the script's two repeat states.
        provider.webWriteError = SpotifyCatalogError.forbidden
        state.togglePlayerMode(shuffle: false)
        try await wait { state.playerModes?.repeatMode == .all }
        state.togglePlayerMode(shuffle: false)
        try await wait { state.playerModes?.repeatMode == .off }
        XCTAssertEqual(provider.nativeRepeatWrites, [.all, .off])
        XCTAssertEqual(state.playbackNotice, "单曲循环需要在设置里补充 Spotify 授权")
    }

    func testWebWriteKeepsWrittenModesUntilNormalRefreshAndDoesNotRetry() async throws {
        let (state, provider, _, _) = fixture()
        state.startProvider()
        try await wait { state.playerModes != nil }
        provider.webReadbackOverride = PlayerPlaybackModes(shuffle: false, repeatMode: .off)
        state.togglePlayerMode(shuffle: true)
        try await wait { state.playbackNotice != nil }
        XCTAssertEqual(provider.webShuffleWrites, [true])
        XCTAssertEqual(state.playerModes?.shuffle, true)
        state.togglePlayerMode(shuffle: false)
        try await wait { state.playerModes?.repeatMode == .all }
        XCTAssertEqual(provider.webRepeatWrites, [.all])
        // Spotify still reports the old values; only a normal refresh applies them.
        state.refreshPlayerModes()
        try await wait { state.playerModes?.shuffle == false && state.playerModes?.repeatMode == .off }
        provider.webWriteError = URLError(.notConnectedToInternet)
        state.togglePlayerMode(shuffle: true)
        try await wait { state.playbackNotice == URLError(.notConnectedToInternet).localizedDescription }
        XCTAssertTrue(provider.nativeShuffleWrites.isEmpty)
    }

    func testUnknownModesFirstClickEnablesAndSmartShuffleOnlyTurnsOff() async throws {
        let (state, provider, _, _) = fixture()
        provider.webWriteError = SpotifyAuthorizationError.notAuthorized
        provider.modeReadFails = true
        state.startProvider()
        try await wait { state.hasLiveTrack }
        state.togglePlayerMode(shuffle: true)
        try await wait { !provider.nativeShuffleWrites.isEmpty }
        XCTAssertEqual(provider.nativeShuffleWrites, [true], "An unknown state must enable, never invert the desktop echo")
        state.togglePlayerMode(shuffle: false)
        try await wait { !provider.nativeRepeatWrites.isEmpty }
        XCTAssertEqual(provider.nativeRepeatWrites, [.all])
        provider.modeReadFails = false
        provider.modes = PlayerPlaybackModes(shuffle: true, repeatMode: .all, smartShuffle: true)
        state.refreshPlayerModes()
        try await wait { state.playerModes?.smartShuffle == true }
        XCTAssertEqual(state.playerModes?.shuffleLabel, "智能随机")
        state.togglePlayerMode(shuffle: true)
        try await wait { provider.nativeShuffleWrites.count == 2 }
        XCTAssertEqual(provider.nativeShuffleWrites, [true, false])
        XCTAssertEqual(state.playerModes?.smartShuffle, false)
    }

    func testModesCycleFromTheLastKnownStateWhenReadsFail() async throws {
        let (state, provider, _, _) = fixture()
        state.startProvider()
        try await wait { state.playerModes != nil }

        // The account read is gone for the rest of the test: no token, or 204.
        provider.webWriteError = SpotifyAuthorizationError.notAuthorized
        provider.modeReadFails = true

        state.togglePlayerMode(shuffle: true)
        try await wait { provider.nativeShuffleWrites.count == 1 }
        state.togglePlayerMode(shuffle: true)
        try await wait { provider.nativeShuffleWrites.count == 2 }
        XCTAssertEqual(provider.nativeShuffleWrites, [true, false],
                       "第二次点击必须把随机关掉，而不是又被未知重置成开")

        state.togglePlayerMode(shuffle: false)
        try await wait { provider.nativeRepeatWrites.count == 1 }
        state.togglePlayerMode(shuffle: false)
        try await wait { provider.nativeRepeatWrites.count == 2 }
        XCTAssertEqual(provider.nativeRepeatWrites, [.all, .off],
                       "脚本回退只切换列表循环和不循环")
        XCTAssertEqual(state.playerModes?.repeatMode, .off)

        state.refreshPlayerModes()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(state.playerModes?.repeatMode, .off,
                       "读取失败不能把已知状态抹回未知")
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

    func testVocalCountdownUsesIntroAndTimedInstrumentalGapsOnly() {
        let lines = [LyricLine(timestamp: 10, originalText: "One"),
            LyricLine(timestamp: 20, originalText: ""), LyricLine(timestamp: 30, originalText: "Two")]
        XCTAssertEqual(LyricsTimeline.vocalCountdownWindow(lines: lines, currentIndex: nil, isSynchronized: true)?.end, 10)
        XCTAssertEqual(LyricsTimeline.vocalCountdownWindow(lines: lines, currentIndex: 1, isSynchronized: true)?.start, 20)
        XCTAssertNil(LyricsTimeline.vocalCountdownWindow(lines: lines, currentIndex: 0, isSynchronized: true))
        XCTAssertNil(LyricsTimeline.vocalCountdownWindow(lines: lines, currentIndex: nil, isSynchronized: false))
        XCTAssertNil(LyricsTimeline.vocalCountdownWindow(lines: [LyricLine(timestamp: 3, originalText: "Short")], currentIndex: nil, isSynchronized: true))
    }

    private func payload(_ title: String = "Event B", state: String = "Playing", position: Double = 32) -> [AnyHashable: Any] {
        ["Player State": state, "Track ID": "spotify:track:BBBBBBBBBBBBBBBBBBBBBB",
         "Name": title, "Artist": "Fixture", "Album": "Cache", "Duration": 240_000,
         "Playback Position": position]
    }

    private func fixture(running: @escaping (PlaybackSourceIdentity) -> Bool = { _ in true },
                         visible: @escaping () -> Bool = { true },
                         repository suppliedRepository: SQLiteLyricsRepository? = nil) -> (PlaybackState, EventPlaybackProvider, DesktopPlaybackEvents, NotificationCenter) {
        let suite = "lyricsq-events-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(false, forKey: AppSettingsStore.Key.autoSearchLyricsOnTrackChange)
        defaults.set(false, forKey: AppSettingsStore.Key.aiAutoTranslateNewLyrics)
        let settings = AppSettingsStore(defaults: defaults)
        settings.playbackSourceMode = .auto
        let root = NativeTestRuntime.root.appendingPathComponent(UUID().uuidString)
        let repository = suppliedRepository ?? SQLiteLyricsRepository(databaseURL: root.appendingPathComponent("test.sqlite3"),
            alignmentProvenanceDirectory: root.appendingPathComponent("provenance"))
        let center = NotificationCenter()
        let events = DesktopPlaybackEvents(center: center, workspaceCenter: NotificationCenter(),
            windowCenter: NotificationCenter(), applicationIsRunning: running)
        let provider = EventPlaybackProvider()
        let state = PlaybackState(provider: provider, lyricsProvider: EventOfflineLyrics(),
            lyricsRepository: repository, settings: settings, desktopEvents: events, lyricsWindowsVisible: visible,
            spotifyPlaybackModesReader: {
                if provider.modeReadFails { throw SpotifyCatalogError.unauthorized }
                return provider.modes
            }, spotifyPlaybackModesWriter: { shuffle, repeatMode in
                if let error = provider.webWriteError { throw error }
                if let shuffle {
                    provider.webShuffleWrites.append(shuffle)
                    provider.modes.shuffle = shuffle
                    provider.modes.smartShuffle = false
                }
                if let repeatMode {
                    provider.webRepeatWrites.append(repeatMode)
                    provider.modes.repeatMode = repeatMode
                }
                if let observed = provider.webReadbackOverride { provider.modes = observed }
            })
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

    func testLightSourceAdoptionSurvivesColdStartPauseAndMetadataRefresh() async throws {
        let root = NativeTestRuntime.root.appendingPathComponent(UUID().uuidString)
        let repo = SQLiteLyricsRepository(databaseURL: root.appendingPathComponent("test.sqlite3"),
            alignmentProvenanceDirectory: root.appendingPathComponent("provenance"))
        try await repo.prepare()
        // Real notification/catalog mismatch, 2026-10-21: one Spotify ID, two titles/albums.
        let id = "spotify:track:4cTnxwbzLd90onQ9bKm9V6"
        let saved = Track(title: "些細な幸福だけで灯っていた。", artist: "kyiku", album: "やどり", duration: 246.49, spotifyId: id)
        let identity = TrackIdentity(track: saved)
        let document = LyricsDocument(identity: identity, title: saved.title, artist: saved.artist,
            album: saved.album, duration: saved.duration,
            lines: [LyricLine(timestamp: 1, originalText: "採用済み")], isSynchronized: true, source: .qqExperimental, confidence: 1)
        let version = try await repo.save(track: saved, identity: identity, document: document)
        let versionID = try XCTUnwrap(version.versionID)
        try await repo.adoptLyricsVersion(trackStableKey: identity.stableKey, lyricsVersionID: versionID)
        let reopened = SQLiteLyricsRepository(databaseURL: repo.databaseURL,
            alignmentProvenanceDirectory: root.appendingPathComponent("provenance"))
        let (state, provider, _, center) = fixture(repository: reopened)
        provider.snapshot = PlaybackSnapshot(status: .ready,
            track: ProviderTrack(id: id, title: "Light source", artist: "kyiku", album: "Even if it was a small prayer", duration: 246.49),
            position: 10, isPlaying: true, sourceIdentity: .spotifyDesktop)
        state.startProvider()
        try await wait { state.liveLyricsVersionID == versionID }
        let revision = state.lyricsSession.revision
        let artwork = URL(string: "https://example.com/light-source-artwork.jpg")!
        provider.artworkResult = artwork
        for (status, title, artist, album) in [("Paused", saved.title, "kyiku", saved.album),
                                              ("Playing", "Light source", "kyiku refreshed", "Even if it was a small prayer")] {
            center.post(name: DesktopPlaybackEvents.spotifyPlaybackChanged, object: nil, userInfo:
                ["Player State": status, "Track ID": id, "Name": title, "Artist": artist,
                 "Album": album, "Duration": 246_490, "Playback Position": 12])
            try await wait { state.isPlaying == (status == "Playing") }
            try await wait { state.currentTrack.artworkURL == artwork }
            XCTAssertEqual(state.currentTrack.artworkURL, artwork)
            XCTAssertEqual(state.liveLyricsVersionID, versionID)
            XCTAssertEqual(state.lyricsSession.revision, revision)
            XCTAssertEqual(state.liveLyrics.first?.originalText, "採用済み")
        }
        // The observed key must still resolve the adopted asset for editor/offset/version actions.
        let observed = TrackIdentity(title: "Light source", artist: "kyiku", album: "Even if it was a small prayer", duration: 246.49, spotifyTrackID: id)
        let editable = try await reopened.loadEditableVersion(versionID: versionID, track: saved, identity: observed)
        XCTAssertEqual(editable?.record.id, versionID)
        // Music's existing persistent IDs are stored in spotify_id, with no schema change.
        let music = Track(title: saved.title, artist: saved.artist, album: saved.album, duration: saved.duration, spotifyId: "applemusic:ABCDEF")
        let musicIdentity = TrackIdentity(track: music)
        let musicDoc = LyricsDocument(identity: musicIdentity, title: music.title, artist: music.artist, album: music.album, duration: music.duration, lines: document.lines, isSynchronized: true, source: .qqExperimental, confidence: 1)
        let musicVersion = try await repo.save(track: music, identity: musicIdentity, document: musicDoc)
        try await repo.adoptLyricsVersion(trackStableKey: musicIdentity.stableKey, lyricsVersionID: XCTUnwrap(musicVersion.versionID))
        let changedMusic = Track(title: "Changed Music metadata", artist: "Changed artist", album: "Changed album", duration: 247, spotifyId: "applemusic:ABCDEF")
        let loadedMusic = try await repo.loadBestStored(track: changedMusic, identity: TrackIdentity(track: changedMusic))
        XCTAssertEqual(loadedMusic?.versionID, musicVersion.versionID)
    }

    func testPauseNotificationStopsPollingAndResumeRestartsClock() async throws {
        let (state, provider, _, center) = fixture()
        state.startProvider()
        try await wait { state.hasLiveTrack }
        let initialRefreshes = provider.refreshes
        // With no adopted version, metadata updates may start a new search identity.
        var paused = payload("Stale display title", state: "Paused", position: 34)
        paused["Track ID"] = provider.snapshot.track!.id!
        paused["Album"] = "Stale display album"
        center.post(name: DesktopPlaybackEvents.spotifyPlaybackChanged, object: nil, userInfo: paused)
        try await wait { !state.isPlaying }
        XCTAssertEqual(state.currentTrack.title, "Stale display title")
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
        XCTAssertEqual(state.currentTrack.title, "Stale display title")
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
