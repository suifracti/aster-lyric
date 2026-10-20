import Foundation
import XCTest
@testable import SpotifyLyrics

private struct SearchModelsDelayedTrackProvider: TrackSearchProvider {
    let name: String
    let delay: UInt64
    let acceptedQuery: String
    let result: TrackSearchResult

    func search(query: TrackSearchQuery) async throws -> [TrackSearchResult] {
        try await Task.sleep(nanoseconds: delay)
        try Task.checkCancellation()
        guard query.text == acceptedQuery else { return [] }
        return [result]
    }
}

private struct SearchModelsFailingTrackProvider: TrackSearchProvider {
    let name: String
    let error: SongSearchError
    func search(query: TrackSearchQuery) async throws -> [TrackSearchResult] { throw error }
}

@MainActor
private final class SearchModelsFixedPlaybackProvider: PlaybackProvider {
    let displayName = "fixed-playback"
    let track: Track
    init(track: Track) { self.track = track }
    func refresh() async -> PlaybackSnapshot {
        PlaybackSnapshot(
            status: .ready,
            track: ProviderTrack(
                id: track.spotifyId,
                title: track.title,
                artist: track.artist,
                album: track.album,
                duration: track.duration,
                artworkURL: track.artworkURL,
                spotifyURL: track.spotifyURL,
                isrc: track.isrc
            ),
            position: 1,
            isPlaying: true
        )
    }
    func play() async throws {}
    func pause() async throws {}
    func previous() async throws {}
    func next() async throws {}
    func seek(to position: TimeInterval) async throws {}
}

@MainActor
final class SearchModelsContractTests: XCTestCase {
    func testSearchModelsKeepLyricsOutOfCatalogResults() async throws {
        let track = Track(title: "Isolation Song", artist: "Isolation Artist", album: "Album", duration: 200)
        let trackResult = TrackSearchResult(id: "track-1", source: .local, track: track, confidence: 0.9)
        let bridged = trackResult.asSongSearchResult()
        XCTAssertNil(bridged.lyrics, "Track search bridge must drop lyrics bodies")
        XCTAssertEqual(bridged.track.title, track.title)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("search-models-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("Isolation Song.lrc")
        let original = """
        [ti:Isolation Song]
        [ar:Isolation Artist]
        [al:Album]
        [00:01.00]line one
        [00:02.00]line two
        """
        try original.write(to: file, atomically: true, encoding: .utf8)
        let originalData = try Data(contentsOf: file)
        let index = LocalLyricsIndex(searchDirectories: [root])
        let local = LocalSearchProvider(index: index)
        let localTrackResults = try await local.search(query: SongSearchQuery(text: "Isolation Song"))
        XCTAssertEqual(localTrackResults.count, 1)
        let localTrack = try XCTUnwrap(localTrackResults.first)
        XCTAssertEqual(localTrack.source, .local)
        XCTAssertEqual(localTrack.track.title, "Isolation Song")
        XCTAssertNil(localTrack.asSongSearchResult().lyrics)

        _ = index.entries()
        XCTAssertTrue(index.hasScanned)
        XCTAssertEqual(index.entries().count, 1)
        XCTAssertTrue(index.fileBytesUnchanged(relativeTo: [file: originalData]))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), original)

        let lyricsProvider = LocalLyricsProvider(index: index)
        let identity = TrackIdentity(track: track)
        let lookup = await lyricsProvider.lookup(track: track, identity: identity)
        guard case .match(let document) = lookup else {
            XCTFail("Expected local lyrics match, got \(lookup)")
            return
        }
        XCTAssertEqual(document.identity, identity)
        XCTAssertEqual(document.lines.count, 2)
        XCTAssertTrue(index.fileBytesUnchanged(relativeTo: [file: originalData]))

        let playback = SearchModelsFixedPlaybackProvider(track: Track(
            title: "Now Playing", artist: "Live Artist", album: "Live Album", duration: 180,
            spotifyId: "spotify:track:live"
        ))
        let resolver = CurrentTrackResolver(playbackProvider: playback)
        let hit = try await resolver.search(query: SongSearchQuery(text: "Live Artist"))
        XCTAssertEqual(hit.count, 1)
        XCTAssertEqual(hit.first?.source, .spotifyCurrentTrack)
        let miss = try await resolver.search(query: SongSearchQuery(text: "totally unrelated query zzqq"))
        XCTAssertTrue(miss.isEmpty)

        let disabled = LRCLIBProvider()
        let lrclibTrackResults = try await disabled.search(query: SongSearchQuery(text: "Isolation Song"))
        XCTAssertTrue(lrclibTrackResults.isEmpty)
    }

    func testSearchManagerKeepsProviderFailuresAndCancelsStaleQueries() async throws {
        let slow = SearchModelsDelayedTrackProvider(
            name: "slow-local", delay: 200_000_000, acceptedQuery: "old",
            result: TrackSearchResult(
                id: "old", source: .local,
                track: Track(title: "Old", artist: "A", album: "B", duration: 100), confidence: 0.5
            )
        )
        let fast = SearchModelsDelayedTrackProvider(
            name: "fast-local", delay: 10_000_000, acceptedQuery: "latest",
            result: TrackSearchResult(
                id: "latest", source: .local,
                track: Track(title: "Latest", artist: "A", album: "B", duration: 100), confidence: 0.9
            )
        )
        let failing = SearchModelsFailingTrackProvider(name: "broken", error: .networkUnavailable)
        let manager = TrackSearchManager(providers: [slow, fast, failing])
        let firstTask = manager.search(query: SongSearchQuery(text: "old"))
        _ = manager.search(query: SongSearchQuery(text: "latest"))
        await firstTask?.value
        try await Task.sleep(nanoseconds: 250_000_000)
        guard case .results(_, let results) = manager.state else {
            XCTFail("Expected latest results despite partial provider failure; got \(manager.state)")
            return
        }
        XCTAssertEqual(results.map(\.id), ["latest"])

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("search-models-compatibility-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Isolation Song.lrc")
        try "[ti:Isolation Song]\n[ar:Isolation Artist]\n[00:01.00]line\n".write(to: file, atomically: true, encoding: .utf8)
        let local = LocalSearchProvider(index: LocalLyricsIndex(searchDirectories: [root]))
        let songManager = SongSearchManager(providers: [local])
        let task = songManager.search(query: SongSearchQuery(text: "Isolation"))
        await task?.value
        guard case .results(_, let songResults) = songManager.state else {
            XCTFail("Expected compatibility song manager results; got \(songManager.state)")
            return
        }
        XCTAssertTrue(songResults.allSatisfy { $0.lyrics == nil })
    }
}
