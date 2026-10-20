import Foundation
import XCTest
@testable import SpotifyLyrics

final class SearchSourceContractTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    func testSearchProviderBoundariesRemainConnected() throws {
        func source(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }
        for (path, declaration) in [
            ("Search/TrackSearchModels.swift", "struct TrackSearchResult"),
            ("Search/TrackSearchManager.swift", "class TrackSearchManager"),
            ("Search/CurrentTrackResolver.swift", "class CurrentTrackResolver"),
            ("Lyrics/LyricsSearchManager.swift", "class LyricsSearchManager"),
            ("Search/LocalLyricsIndex.swift", "class LocalLyricsIndex")
        ] {
            XCTAssertTrue(try source("SpotifyLyrics/" + path).contains(declaration), path)
        }
        let state = try source("SpotifyLyrics/Services/PlaybackState.swift")
        XCTAssertFalse(state.contains("LRCLIBProvider()"), "lyric search must not be registered as track search")
        XCTAssertTrue(state.contains("CurrentTrackResolver") || state.contains("LocalSearchProvider"))
        let lrclib = try source("SpotifyLyrics/Lyrics/LRCLIBLyricsProvider.swift")
        for marker in ["maxAutomaticRetries", "rateLimited", ".cancelled"] {
            XCTAssertTrue(lrclib.contains(marker), marker)
        }
        XCTAssertTrue(try source("SpotifyLyrics/Search/LocalLyricsIndex.swift").contains("#if DEBUG"))
    }

    func testHostUsesPrivateStorageAndNoKeychain() {
        XCTAssertTrue(NativeTestRuntime.isEnabled)
        XCTAssertTrue(UserDefaults.lyricsQ === NativeTestRuntime.defaults)
        XCTAssertEqual(ProcessInfo.processInfo.environment["SPOTIFYLYRICS_DISABLE_KEYCHAIN"], "1")
        XCTAssertEqual(DebugDatabaseSafety.status().configuredDatabaseURL?.deletingLastPathComponent().path, NativeTestRuntime.root.path)
        XCTAssertEqual(LyricsQStorage.homeDirectory, NativeTestRuntime.root)
    }
}
