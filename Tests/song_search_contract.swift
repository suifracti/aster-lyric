import Foundation

private final class StubSearchSession: LRCLIBSession, @unchecked Sendable {
    let responseData: Data
    let statusCode: Int
    private(set) var requests: [URLRequest] = []

    init(responseData: Data, statusCode: Int = 200) {
        self.responseData = responseData
        self.statusCode = statusCode
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://lrclib.net/api/get")!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return (responseData, response)
    }
}

private struct FixedTrackProvider: TrackSearchProvider {
    let name: String
    let results: [TrackSearchResult]
    func search(query: TrackSearchQuery) async throws -> [TrackSearchResult] { results }
}

private struct UnavailableCatalog: TrackSearchProvider {
    let name = "unavailable online catalog"
    let error: SongSearchError
    func search(query: TrackSearchQuery) async throws -> [TrackSearchResult] { throw error }
}

private struct DelayedTrackProvider: TrackSearchProvider {
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
private final class FixedPlaybackProvider: PlaybackProvider {
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

@main
struct SongSearchContract {
    static func main() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("song-search-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("Search Song.lrc")
        let body = """
        [ti:Search Song]
        [ar:Search Artist]
        [al:Search Album]
        [00:01.00]one
        [00:02.00]two
        """
        try! body.write(to: file, atomically: true, encoding: .utf8)
        let originalData = try! Data(contentsOf: file)

        let index = LocalLyricsIndex(searchDirectories: [root])
        let local = LocalSearchProvider(index: index)
        let localTrackResults = try! await local.search(query: SongSearchQuery(text: "Search Song Search Artist"))
        precondition(localTrackResults.count == 1)
        precondition(localTrackResults[0].source == .local)
        let localResults = localTrackResults.map { $0.asSongSearchResult() }
        precondition(localResults[0].lyrics == nil, "track search must not embed lyrics bodies")
        precondition(localResults[0].track.title == "Search Song")
        precondition((try! Data(contentsOf: file)) == originalData)

        for error in [SongSearchError.notConfigured, .unauthorized] {
            let offline = TrackSearchManager(providers: [local, UnavailableCatalog(error: error)])
            await offline.search(query: SongSearchQuery(text: "Search Song"))?.value
            guard case .results(_, let found) = offline.state else { fatalError("catalog configuration must not block local search") }
            precondition(found.first?.source == .local)
            await offline.search(query: SongSearchQuery(text: "No such local song"))?.value
            guard case .noResults = offline.state else { fatalError("unconfigured catalog is not a local search failure") }
        }
        let broken = TrackSearchManager(providers: [UnavailableCatalog(error: .networkUnavailable)])
        await broken.search(query: SongSearchQuery(text: "Search Song"))?.value
        guard case .failed = broken.state else { fatalError("real search failure must remain visible") }
        print("PASS local search works without Spotify configuration; no results and network failure stay distinct")
        let savedTrack = Track(title: "Saved Library Song", artist: "Saved Artist", album: "Saved Album", duration: 180)
        let savedProvider = LocalSearchProvider(index: index, savedSearch: { query in
            guard query.text == "a line only in saved lyrics" else { return [] }
            return [TrackSearchResult(id: "library:fixture", source: .local, track: savedTrack, confidence: 0.6)]
        })
        let saved = try! await savedProvider.search(query: SongSearchQuery(text: "a line only in saved lyrics"))
        precondition(saved.map(\.id) == ["library:fixture"] && saved.allSatisfy { $0.asSongSearchResult().lyrics == nil })
        let unavailableLibrary = LocalSearchProvider(index: index, savedSearch: { _ in throw SongSearchError.unknown("library unavailable") })
        let localDespiteReadFailure = try! await unavailableLibrary.search(query: SongSearchQuery(text: "Search Song"))
        precondition(localDespiteReadFailure.first?.track.title == "Search Song")
        print("PASS saved-library metadata participates in local search; unreadable library preserves LRC results")

        // LRCLIB remains available for lyrics lookup, not track catalog search.
        let payload = """
        {
          "id": 42,
          "trackName": "Search Song",
          "artistName": "Search Artist",
          "albumName": "Search Album",
          "duration": 200,
          "syncedLyrics": "[00:01.00]online"
        }
        """.data(using: .utf8)!
        let lrclib = LRCLIBLyricsProvider(session: StubSearchSession(responseData: payload), maxAutomaticRetries: 0)
        let track = Track(title: "Search Song", artist: "Search Artist", album: "Search Album", duration: 200)
        let identity = TrackIdentity(track: track)
        let lyricsResult = await lrclib.lookup(track: track, identity: identity)
        guard case .match(let document) = lyricsResult else {
            fatalError("expected LRCLIB lyrics match")
        }
        precondition(document.lines.first?.originalText == "online")
        let disabledTrackSearch = try! await LRCLIBProvider().search(query: SongSearchQuery(text: "Search Song"))
        precondition(disabledTrackSearch.isEmpty)

        let playback = FixedPlaybackProvider(
            track: Track(
                title: "Search Song",
                artist: "Search Artist",
                album: "Search Album",
                duration: 200,
                spotifyId: "spotify:track:search"
            )
        )
        let current = CurrentTrackResolver(playbackProvider: playback)
        let currentResults = try! await current.search(query: SongSearchQuery(text: "Search Artist"))
        precondition(currentResults.count == 1)
        precondition(currentResults[0].source == .spotifyCurrentTrack)
        precondition(currentResults[0].track.title == "Search Song")

        let duplicateManager = TrackSearchManager(providers: [
            FixedTrackProvider(name: "duplicates", results: [
                TrackSearchResult(
                    id: "a",
                    source: .local,
                    track: Track(title: "Search Song", artist: "Search Artist", album: "Search Album", duration: 200),
                    confidence: 0.9
                ),
                TrackSearchResult(
                    id: "b",
                    source: .local,
                    track: Track(title: "Search Song", artist: "Search Artist", album: "Alternate Release", duration: 199),
                    confidence: 0.4
                )
            ])
        ])
        let duplicateTask = duplicateManager.search(query: SongSearchQuery(text: "Search Song"))
        await duplicateTask?.value
        guard case .results(_, let deduplicatedResults) = duplicateManager.state else {
            fatalError("expected de-duplicated search results")
        }
        precondition(deduplicatedResults.count == 1)

        let old = TrackSearchResult(
            id: "old",
            source: .local,
            track: track,
            confidence: 0.5
        )
        let latestTrack = Track(title: "Latest", artist: "Artist", album: "Album", duration: 180)
        let latest = TrackSearchResult(
            id: "latest",
            source: .local,
            track: latestTrack,
            confidence: 0.9
        )
        let manager = SongSearchManager(providers: [
            DelayedTrackProvider(name: "slow", delay: 250_000_000, acceptedQuery: "old", result: old),
            DelayedTrackProvider(name: "fast", delay: 20_000_000, acceptedQuery: "latest", result: latest)
        ] as [TrackSearchProvider])
        let firstTask = manager.search(query: SongSearchQuery(text: "old"))
        _ = manager.search(query: SongSearchQuery(text: "latest"))
        await firstTask?.value
        try? await Task.sleep(nanoseconds: 350_000_000)
        guard case .results(_, let results) = manager.state else {
            fatalError("expected manager results")
        }
        precondition(results.map(\.id) == ["latest"])
        precondition(results.allSatisfy { $0.lyrics == nil })

        print("song search contract passed")
    }
}
