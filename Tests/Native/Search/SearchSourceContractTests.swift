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

    /// The same lyric line reaches the reading engine once per candidate,
    /// query variant and final document. Only the first may start MeCab.
    func testRepeatedLyricLineStartsTheReadingProcessOnce() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mecab-reuse-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let runs = directory.appendingPathComponent("runs")
        let script = directory.appendingPathComponent("mecab")
        try """
        #!/bin/sh
        cat >/dev/null
        echo run >> '\(runs.path)'
        printf '君\\tキミ\\t君\\t名詞-代名詞-一般\\t\\t\\nEOS\\n'
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        func runCount() -> Int {
            ((try? String(contentsOf: runs, encoding: .utf8)) ?? "").split(separator: "\n").count
        }

        let engine = JapaneseMeCabEngine(executableURL: script)
        let first = try engine.tokenize("君")
        XCTAssertEqual(first.first?.readingKatakana, "キミ")
        XCTAssertEqual(try engine.tokenize("君"), first)
        XCTAssertEqual(try JapaneseMeCabEngine(executableURL: script).tokenize("君"), first)
        XCTAssertEqual(runCount(), 1, "a repeated line must reuse the first result")

        _ = try engine.tokenize("僕")
        XCTAssertEqual(runCount(), 2, "a different line still runs the engine")
        _ = try engine.tokenizations("君", maximumCount: 2)
        XCTAssertEqual(runCount(), 3, "N-best output is a different request")

        let broken = directory.appendingPathComponent("broken")
        try "#!/bin/sh\ncat >/dev/null\necho run >> '\(runs.path)'\nexit 1\n"
            .write(to: broken, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: broken.path)
        let failing = JapaneseMeCabEngine(executableURL: broken)
        XCTAssertThrowsError(try failing.tokenize("君"))
        XCTAssertThrowsError(try failing.tokenize("君"))
        XCTAssertEqual(runCount(), 5, "a failure is retried, never remembered")
    }

    func testHostUsesPrivateStorageAndNoKeychain() {
        XCTAssertTrue(NativeTestRuntime.isEnabled)
        XCTAssertTrue(UserDefaults.lyricsQ === NativeTestRuntime.defaults)
        XCTAssertEqual(ProcessInfo.processInfo.environment["SPOTIFYLYRICS_DISABLE_KEYCHAIN"], "1")
        XCTAssertEqual(DebugDatabaseSafety.status().configuredDatabaseURL?.deletingLastPathComponent().path, NativeTestRuntime.root.path)
        XCTAssertEqual(LyricsQStorage.homeDirectory, NativeTestRuntime.root)
    }
}
