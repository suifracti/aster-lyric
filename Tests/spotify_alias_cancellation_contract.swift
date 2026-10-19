import Foundation

private final class DelayedSpotifyMetadata: URLProtocol {
    private static let lock = NSLock()
    private static var starts = 0
    static func reset() { lock.lock(); starts = 0; lock.unlock() }
    static func count() -> Int { lock.lock(); defer { lock.unlock() }; return starts }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "open.spotify.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.starts += 1; Self.lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.8) { [self] in
            let id = request.url!.lastPathComponent
            let entity: [String: Any] = ["type": "track", "id": id, "uri": "spotify:track:\(id)",
                "title": "Metadata fixture", "duration": 180_000,
                "artists": [["name": "Fixture artist", "uri": "spotify:artist:" + String(repeating: "A", count: 22)]]]
            let data = try! JSONSerialization.data(withJSONObject: ["props": ["pageProps": ["state": ["data": ["entity": entity]]]]])
            let html = "<script id=\"__NEXT_DATA__\">" + String(decoding: data, as: UTF8.self) + "</script>"
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: ["Content-Type": "text/html"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(html.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

private struct NoLyricsFixture: LyricsProvider {
    let name = "No lyrics fixture"
    let executionLane: LyricsProviderExecutionLane = .network
    func lookup(track: Track, identity: TrackIdentity) async -> LyricsLookupResult { .noMatch }
}

@main struct SpotifyAliasCancellationContract {
    static func main() async {
        var failures = 0
        func expect(_ condition: Bool, _ reason: String) {
            print("\(condition ? "PASS" : "FAIL") \(reason)")
            if !condition { failures += 1 }
        }
        func resolver() -> SpotifyTrackArtistResolver {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [DelayedSpotifyMetadata.self]
            return SpotifyTrackArtistResolver(session: URLSession(configuration: config))
        }
        func awaitRequest() async {
            for _ in 0..<1000 {
                if DelayedSpotifyMetadata.count() > 0 { return }
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            fatalError("metadata fixture did not receive its request")
        }
        let track = Track(title: "Metadata fixture", artist: "Fixture artist", album: "Fixture", duration: 180,
            spotifyId: String(repeating: "B", count: 22))

        DelayedSpotifyMetadata.reset()
        let shared = resolver()
        let first = Task { await shared.artists(for: track) }
        await awaitRequest()
        let survivor = Task { await shared.aliases(for: track) }
        let cancelledAt = Date()
        first.cancel()
        let cancelled = await first.value
        let elapsed = Date().timeIntervalSince(cancelledAt)
        expect(elapsed < 0.3, "cancelled metadata consumer returns promptly: \(elapsed)s")
        expect(cancelled == nil, "cancelled metadata is not published")
        let aliases = await survivor.value
        expect(Set(aliases.map(\.value)) == ["Metadata fixture", "Fixture artist"],
            "other shared consumer still receives verified aliases")
        let cachedArtists = await shared.artists(for: track)
        expect(cachedArtists == ["Fixture artist"] && DelayedSpotifyMetadata.count() == 1,
            "shared request stays deduplicated and successful metadata is cached")

        DelayedSpotifyMetadata.reset()
        let lone = resolver()
        let abandoned = Task { await lone.aliases(for: track) }
        await awaitRequest()
        let abandonedAt = Date()
        abandoned.cancel()
        let abandonedAliases = await abandoned.value
        expect(Date().timeIntervalSince(abandonedAt) < 0.3 && abandonedAliases.isEmpty,
            "last cancelled consumer can leave without waiting for HTTP")
        try? await Task.sleep(nanoseconds: 900_000_000)
        let recovered = await lone.artists(for: track)
        expect(recovered == ["Fixture artist"] && DelayedSpotifyMetadata.count() == 1,
            "shared completion cleans up and caches even after every consumer leaves")

        DelayedSpotifyMetadata.reset()
        let manager = LyricsSearchManager(providers: [NoLyricsFixture()], spotifyArtistResolver: resolver())
        let search = Task { await manager.search(track: track, identity: TrackIdentity(track: track)) }
        await awaitRequest()
        let searchCancelledAt = Date()
        search.cancel()
        let outcome = await search.value
        expect(Date().timeIntervalSince(searchCancelledAt) < 0.3,
            "whole lyric search cancels promptly during official alias enrichment")
        if case .failed(.cancelled) = outcome.result { expect(true, "cancelled search cannot adopt metadata") }
        else { expect(false, "cancelled search cannot adopt metadata") }
        try? await Task.sleep(nanoseconds: 900_000_000)
        print("SPOTIFY_ALIAS_CANCELLATION_FAILURES=\(failures)")
        if failures > 0 { exit(1) }
    }
}
