import XCTest
@testable import SpotifyLyrics

private actor CalibrationScriptFixture {
    var result: String
    var scripts: [String] = []
    init(_ result: String) { self.result = result }
    func run(_ script: String) -> String { scripts.append(script); return result }
    func set(_ result: String) { self.result = result }
    func history() -> [String] { scripts }
}

@MainActor
final class ProviderPositionCalibrationTests: XCTestCase {
    func testArtworkReadIsIdentityScopedAndDoesNotWakeAStoppedApp() async throws {
        let scripts = CalibrationScriptFixture("spotify:track:OTHER\u{1e}https://example.invalid/wrong.jpg")
        var running = true
        let provider = SpotifyDesktopProvider(scriptRunner: { script, _ in await scripts.run(script) },
            applicationIsInstalled: { true }, applicationIsRunning: { running })
        let track = try XCTUnwrap(snapshot(source: .spotifyDesktop, id: "spotify:track:AAAAAAAAAAAAAAAAAAAAAA").track)
        let wrong = await provider.artworkURL(for: track, source: .spotifyDesktop)
        XCTAssertNil(wrong)
        await scripts.set("spotify:track:AAAAAAAAAAAAAAAAAAAAAA\u{1e}https://example.invalid/right.jpg")
        let matching = await provider.artworkURL(for: track, source: .spotifyDesktop)
        XCTAssertEqual(matching?.lastPathComponent, "right.jpg")
        running = false
        let stopped = await provider.artworkURL(for: track, source: .spotifyDesktop)
        XCTAssertNil(stopped)
        let calls = await scripts.history()
        XCTAssertEqual(calls.count, 2)
        XCTAssertFalse(calls[0].contains("player position"), "asset reads do not poll playback state")
    }

    private func snapshot(source: PlaybackSourceIdentity, id: String, playing: Bool = true) -> PlaybackSnapshot {
        PlaybackSnapshot(status: .ready, track: ProviderTrack(id: id, title: "Cached", artist: "Fixture", album: "Album", duration: 200),
                         position: 12, isPlaying: playing, sourceIdentity: source)
    }

    func testSpotifyCalibrationReadsOnlyPositionStateAndIdentityAndDoesNotWakeStoppedApp() async throws {
        let fields = "playing\u{1e}23.5\u{1e}spotify:track:AAAAAAAAAAAAAAAAAAAAAA"
        let scripts = CalibrationScriptFixture(fields)
        var running = true
        let provider = SpotifyDesktopProvider(scriptRunner: { script, _ in await scripts.run(script) },
            applicationIsInstalled: { true }, applicationIsRunning: { running })
        provider.acceptDesktopSnapshot(snapshot(source: .spotifyDesktop, id: "spotify:track:AAAAAAAAAAAAAAAAAAAAAA"))
        let corrected = await provider.calibratePosition()
        XCTAssertEqual(corrected.position, 23.5)
        let first = await scripts.history()
        XCTAssertEqual(first.count, 1)
        XCTAssertFalse(first[0].contains("artwork"))
        XCTAssertFalse(first[0].contains("name of"))
        XCTAssertTrue(first[0].contains("is not running"))
        running = false
        let stopped = await provider.calibratePosition()
        XCTAssertEqual(stopped.status, .notRunning)
        let after = await scripts.history()
        XCTAssertEqual(after.count, 1)
    }

    func testMusicPausedCacheDoesNotPollAndAChangedRecordingCannotReceiveOldPosition() async throws {
        let scripts = CalibrationScriptFixture("playing\u{1e}80\u{1e}DIFFERENT")
        let provider = AppleMusicDesktopProvider(scriptRunner: { script, _ in await scripts.run(script) },
            applicationIsInstalled: { true }, applicationIsRunning: { true })
        provider.acceptDesktopSnapshot(snapshot(source: .appleMusic, id: "applemusic:ABC", playing: false))
        let paused = await provider.calibratePosition()
        XCTAssertFalse(paused.isPlaying)
        let none = await scripts.history()
        XCTAssertTrue(none.isEmpty)
        provider.acceptDesktopSnapshot(snapshot(source: .appleMusic, id: "applemusic:ABC"))
        let changed = await provider.calibratePosition()
        XCTAssertFalse(changed.status.isReady)
        XCTAssertNil(changed.track)
        let reads = await scripts.history()
        XCTAssertEqual(reads.count, 1)
        XCTAssertFalse(reads[0].contains("artwork"))
        XCTAssertFalse(reads[0].contains("trackName"))
    }

    func testShortSpotifyTrackUsesTheSameMillisecondDurationAsItsNotification() async {
        let read = "playing\u{1e}1\u{1e}Short\u{1e}Fixture\u{1e}Cache\u{1e}8000\u{1e}\u{1e}\u{1e}spotify:track:AAAAAAAAAAAAAAAAAAAAAA"
        let provider = SpotifyDesktopProvider(scriptRunner: { _, _ in read },
            applicationIsInstalled: { true }, applicationIsRunning: { true })
        let metadata = await provider.refresh()
        XCTAssertEqual(metadata.track?.duration, 8)
    }

    func testAutoProviderRoutesCommandsToTheLatestEventSource() {
        let defaults = UserDefaults(suiteName: "lyricsq-active-source-\(UUID())")!
        let active = ActivePlaybackProvider(settings: AppSettingsStore(defaults: defaults))
        active.acceptDesktopSnapshot(snapshot(source: .appleMusic, id: "applemusic:ABC"))
        XCTAssertTrue(active.activeProvider === active.appleMusicProvider)
        active.acceptDesktopSnapshot(snapshot(source: .spotifyDesktop, id: "spotify:track:AAAAAAAAAAAAAAAAAAAAAA"))
        XCTAssertTrue(active.activeProvider === active.spotifyProvider)
    }
}
