import Foundation
import XCTest
import Combine
@testable import SpotifyLyrics

private final class SongSearchStubSession: LRCLIBSession, @unchecked Sendable {
    let responseData: Data
    let statusCode: Int
    private(set) var requests: [URLRequest] = []

    init(responseData: Data, statusCode: Int = 200) {
        self.responseData = responseData
        self.statusCode = statusCode
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        guard let responseURL = request.url ?? URL(string: "https://lrclib.net/api/get"),
              let response = HTTPURLResponse(
                url: responseURL,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: nil
              ) else {
            throw NSError(domain: "SongSearchContractTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create HTTP fixture response"])
        }
        return (responseData, response)
    }
}

private struct SongSearchFixedTrackProvider: TrackSearchProvider {
    let name: String
    let results: [TrackSearchResult]
    func search(query: TrackSearchQuery) async throws -> [TrackSearchResult] { results }
}

private struct SongSearchUnavailableCatalog: TrackSearchProvider {
    let name = "unavailable online catalog"
    let error: SongSearchError
    func search(query: TrackSearchQuery) async throws -> [TrackSearchResult] { throw error }
}

private struct SongSearchDelayedTrackProvider: TrackSearchProvider {
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

@MainActor
private final class SongSearchFixedPlaybackProvider: PlaybackProvider {
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
final class SongSearchContractTests: XCTestCase {
    func testSameSongAppearsOnceWithSavedResultPreferred() {
        let localTrack = Track(title: "Light source", artist: "kyiku", album: "Single", duration: 246,
            spotifyId: "spotify:track:4yqIha5lZw4ymk8ZxrP3kA")
        let onlineTrack = Track(title: "Light source", artist: "kyiku", album: "Album", duration: 247,
            spotifyId: "4yqIha5lZw4ymk8ZxrP3kA")
        let online = SongSearchResult(id: "online", source: .spotifyCatalog, track: onlineTrack, confidence: 1)
        let saved = SongSearchResult(id: "saved", source: .local, track: localTrack, confidence: 1)
        let input = [online, saved, online]
        XCTAssertEqual(SongSearchResultGroup.uniqueSongs(input).map(\.id), ["saved"])
        XCTAssertEqual(SongSearchResultGroup.panelGroups(input).flatMap(\.results).map(\.id), ["saved"])
        XCTAssertEqual(V3SearchPanel.otherSongs(input, current: nil).map(\.id), ["saved"])
    }

    func testPanelGroupsKeepSavedBadgesWhenOnlineWinsTheMerge() async throws {
        let track = Track(title: "Saved", artist: "Artist", album: "Album", duration: 180, spotifyId: "saved-track")
        let entry = PersonalLyricsLibraryEntry(trackStableKey: "saved-track", spotifyTrackID: "saved-track",
            isrc: nil, title: track.title, artist: track.artist, album: track.album, duration: track.duration,
            artworkURL: nil, lyricsVersionCount: 1, translationVersionCount: 2, readingVersionCount: 1,
            timingVersionCount: 0, hasLockedLyrics: false, hasLockedTranslation: false, hasManualLyrics: false,
            hasManualTranslation: true, hasReading: true, hasFineTiming: false, lastModifiedAt: Date(),
            activeLyricsVersionID: UUID(), activeTranslationVersionID: UUID())
        let manager = TrackSearchManager(providers: [SongSearchFixedTrackProvider(name: "metadata", results: [
            TrackSearchResult(id: "saved", source: .local, track: track, confidence: 0.6, savedLibraryEntry: entry),
            TrackSearchResult(id: "online", source: .spotifyCatalog, track: track, confidence: 1)
        ])])
        await manager.search(query: SongSearchQuery(text: "Saved"))?.value
        guard case .results(_, let results) = manager.state else { return XCTFail("Missing results") }
        let hit = try XCTUnwrap(results.first).asSongSearchResult()
        XCTAssertEqual(hit.source, .spotifyCatalog)
        XCTAssertEqual(hit.savedLayerLabels, ["词", "译", "读"])
        XCTAssertTrue(hit.isSavedLocally)
        XCTAssertEqual(hit.asTrackSearchResult().savedLibraryEntry, entry)
        let many = (0..<6).flatMap { index in
            [SongSearchResult(id: "local-\(index)", source: .local, track: Track(title: "Saved \(index)", artist: "Local", album: "", duration: 180), confidence: 1),
             SongSearchResult(id: "online-\(index)", source: .spotifyCatalog, track: Track(title: "Online \(index)", artist: "Online", album: "", duration: 180), confidence: 1)]
        }
        let groups = SongSearchResultGroup.panelGroups(many)
        XCTAssertEqual(groups.map(\.title), ["本地已存", "在线"])
        XCTAssertEqual(groups.map { $0.results.count }, [5, 5])
    }

    func testSearchPublishesLocalBeforeSlowOnline() async throws {
        let local = LocalSearchProvider(searchDirectories: [], savedSearch: { _ in
            [TrackSearchResult(id: "saved", source: .local,
                track: Track(title: "Saved result", artist: "Local", album: "", duration: 180), confidence: 0.9)]
        })
        let query = SongSearchQuery(text: "Saved result")
        let online = SongSearchDelayedTrackProvider(name: "slow online", delay: 100_000_000,
            acceptedQuery: query.text,
            result: TrackSearchResult(id: "online", source: .spotifyCatalog,
                track: Track(title: "Online result", artist: "Online", album: "", duration: 180), confidence: 0.5))
        let manager = SongSearchManager(providers: [online, local] as [TrackSearchProvider])
        var firstBatch: [SongSearchResult]?
        let observation = manager.$state.sink { state in
            if case .results(_, let results) = state, firstBatch == nil { firstBatch = results }
        }
        await manager.search(query: query, debounceNanoseconds: 50_000_000)?.value
        XCTAssertEqual(firstBatch?.map(\.id), ["saved"], "Local results must be published before the online provider")
        guard case .results(_, let complete) = manager.state else { return XCTFail("Expected merged search results") }
        XCTAssertEqual(Set(complete.map(\.id)), Set(["saved", "online"]))
        observation.cancel()
    }

    func testLocalSearchAndProviderFailuresStayDistinct() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("song-search-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("Search Song.lrc")
        let body = """
        [ti:Search Song]
        [ar:Search Artist]
        [al:Search Album]
        [00:01.00]one
        [00:02.00]two
        """
        try body.write(to: file, atomically: true, encoding: .utf8)
        let originalData = try Data(contentsOf: file)

        let index = LocalLyricsIndex(searchDirectories: [root])
        let local = LocalSearchProvider(index: index)
        let localTrackResults = try await local.search(query: SongSearchQuery(text: "Search Song Search Artist"))
        XCTAssertEqual(localTrackResults.count, 1)
        let localTrack = try XCTUnwrap(localTrackResults.first)
        XCTAssertEqual(localTrack.source, .local)
        let localResult = localTrack.asSongSearchResult()
        XCTAssertNil(localResult.lyrics, "Track search must not embed lyrics bodies")
        XCTAssertEqual(localResult.track.title, "Search Song")
        XCTAssertEqual(try Data(contentsOf: file), originalData)

        for error in [SongSearchError.notConfigured, .unauthorized] {
            let offline = TrackSearchManager(providers: [local, SongSearchUnavailableCatalog(error: error)])
            let foundTask = offline.search(query: SongSearchQuery(text: "Search Song"))
            await foundTask?.value
            guard case .results(_, let found) = offline.state else {
                XCTFail("Catalog configuration must not block local search; got \(offline.state)")
                return
            }
            XCTAssertEqual(found.first?.source, .local)

            let emptyTask = offline.search(query: SongSearchQuery(text: "No such local song"))
            await emptyTask?.value
            guard case .noResults = offline.state else {
                XCTFail("Unconfigured catalog is not a local search failure; got \(offline.state)")
                return
            }
        }

        let broken = TrackSearchManager(providers: [SongSearchUnavailableCatalog(error: .networkUnavailable)])
        let brokenTask = broken.search(query: SongSearchQuery(text: "Search Song"))
        await brokenTask?.value
        guard case .failed = broken.state else {
            XCTFail("Real search failure must remain visible; got \(broken.state)")
            return
        }

        let savedTrack = Track(title: "Saved Library Song", artist: "Saved Artist", album: "Saved Album", duration: 180)
        let savedProvider = LocalSearchProvider(index: index, savedSearch: { query in
            guard query.text == "a line only in saved lyrics" else { return [] }
            return [TrackSearchResult(id: "library:fixture", source: .local, track: savedTrack, confidence: 0.6)]
        })
        let saved = try await savedProvider.search(query: SongSearchQuery(text: "a line only in saved lyrics"))
        XCTAssertEqual(saved.map(\.id), ["library:fixture"])
        XCTAssertTrue(saved.allSatisfy { $0.asSongSearchResult().lyrics == nil })
        let unavailableLibrary = LocalSearchProvider(index: index, savedSearch: { _ in
            throw SongSearchError.unknown("library unavailable")
        })
        let localDespiteReadFailure = try await unavailableLibrary.search(query: SongSearchQuery(text: "Search Song"))
        XCTAssertEqual(localDespiteReadFailure.first?.track.title, "Search Song")

        let payload = """
        {
          "id": 42,
          "trackName": "Search Song",
          "artistName": "Search Artist",
          "albumName": "Search Album",
          "duration": 200,
          "syncedLyrics": "[00:01.00]online"
        }
        """.data(using: .utf8) ?? Data()
        let lrclib = LRCLIBLyricsProvider(session: SongSearchStubSession(responseData: payload), maxAutomaticRetries: 0)
        let track = Track(title: "Search Song", artist: "Search Artist", album: "Search Album", duration: 200)
        let identity = TrackIdentity(track: track)
        let lyricsResult = await lrclib.lookup(track: track, identity: identity)
        guard case .match(let document) = lyricsResult else {
            XCTFail("Expected LRCLIB lyrics match, got \(lyricsResult)")
            return
        }
        XCTAssertEqual(document.lines.first?.originalText, "online")
        let disabledTrackSearch = try await LRCLIBProvider().search(query: SongSearchQuery(text: "Search Song"))
        XCTAssertTrue(disabledTrackSearch.isEmpty)

        let playback = SongSearchFixedPlaybackProvider(track: Track(
            title: "Search Song", artist: "Search Artist", album: "Search Album", duration: 200,
            spotifyId: "spotify:track:search"
        ))
        let current = CurrentTrackResolver(playbackProvider: playback)
        let currentResults = try await current.search(query: SongSearchQuery(text: "Search Artist"))
        XCTAssertEqual(currentResults.count, 1)
        let currentResult = try XCTUnwrap(currentResults.first)
        XCTAssertEqual(currentResult.source, .spotifyCurrentTrack)
        XCTAssertEqual(currentResult.track.title, "Search Song")

        let duplicateManager = TrackSearchManager(providers: [
            SongSearchFixedTrackProvider(name: "duplicates", results: [
                TrackSearchResult(
                    id: "a", source: .local,
                    track: Track(title: "Search Song", artist: "Search Artist", album: "Search Album", duration: 200),
                    confidence: 0.9
                ),
                TrackSearchResult(
                    id: "b", source: .local,
                    track: Track(title: "Search Song", artist: "Search Artist", album: "Alternate Release", duration: 199),
                    confidence: 0.4
                )
            ])
        ])
        let duplicateTask = duplicateManager.search(query: SongSearchQuery(text: "Search Song"))
        await duplicateTask?.value
        guard case .results(_, let deduplicatedResults) = duplicateManager.state else {
            XCTFail("Expected de-duplicated search results; got \(duplicateManager.state)")
            return
        }
        XCTAssertEqual(deduplicatedResults.count, 1)

        let old = TrackSearchResult(id: "old", source: .local, track: track, confidence: 0.5)
        let latestTrack = Track(title: "Latest", artist: "Artist", album: "Album", duration: 180)
        let latest = TrackSearchResult(id: "latest", source: .local, track: latestTrack, confidence: 0.9)
        let manager = SongSearchManager(providers: [
            SongSearchDelayedTrackProvider(name: "slow", delay: 250_000_000, acceptedQuery: "old", result: old),
            SongSearchDelayedTrackProvider(name: "fast", delay: 20_000_000, acceptedQuery: "latest", result: latest)
        ])
        let firstTask = manager.search(query: SongSearchQuery(text: "old"))
        _ = manager.search(query: SongSearchQuery(text: "latest"))
        await firstTask?.value
        try await Task.sleep(nanoseconds: 350_000_000)
        guard case .results(_, let results) = manager.state else {
            XCTFail("Expected latest search results; got \(manager.state)")
            return
        }
        XCTAssertEqual(results.map(\.id), ["latest"])
        XCTAssertTrue(results.allSatisfy { $0.lyrics == nil })
    }
}
