import Foundation

private func require(_ condition: Bool, _ message: String) {
    guard condition else { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

private final class FixtureResponses: @unchecked Sendable {
    private let lock = NSLock()
    private var body = Data()
    private var status = 200
    private var calls = 0
    private var error: URLError?
    private var responseURL: URL?
    private var delay: TimeInterval = 0
    func reset(body: Data, status: Int = 200, error: URLError? = nil, responseURL: URL? = nil, delay: TimeInterval = 0) {
        lock.lock(); defer { lock.unlock() }
        self.body = body; self.status = status; self.error = error; self.responseURL = responseURL; self.delay = delay; calls = 0
    }
    func response(_ request: URLRequest) -> (Data, Int, URLError?, URL?, TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        calls += 1
        require(request.url?.absoluteString == "https://open.spotify.com/embed/track/5EgW6VV9LW6xtgJ1sFN5RU", "exact case-sensitive official track URL")
        require(request.value(forHTTPHeaderField: "Authorization") == nil && request.value(forHTTPHeaderField: "Cookie") == nil,
            "public metadata request must not contain credentials")
        require(request.timeoutInterval <= 4, "metadata request must be bounded")
        return (body, status, error, responseURL, delay)
    }
    var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
}

private final class FixtureURLProtocol: URLProtocol {
    static let replies = FixtureResponses()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (body, status, error, responseURL, delay) = Self.replies.response(request)
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        if let error { client?.urlProtocol(self, didFailWithError: error); return }
        let response = HTTPURLResponse(url: responseURL ?? request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "text/html"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func page(id: String = "5EgW6VV9LW6xtgJ1sFN5RU", title: String = "Metadata Song - Remix",
                  duration: Double = 318500, artists: [String] = ["Alice", "Bob"], uri: String? = nil) -> Data {
    let entity: [String: Any] = ["type": "track", "id": id, "uri": uri ?? "spotify:track:\(id)",
        "title": title, "duration": duration, "artists": artists.enumerated().map { offset, name in
            ["name": name, "uri": "spotify:artist:" + String(repeating: offset == 0 ? "A" : "B", count: 22)]
        }]
    let data = try! JSONSerialization.data(withJSONObject: ["props": ["pageProps": ["state": ["data": ["entity": entity]]]]])
    return Data(("<html><script id=\"__NEXT_DATA__\" type=\"application/json\">" + String(decoding: data, as: UTF8.self) + "</script></html>").utf8)
}

private func resolver() -> SpotifyTrackArtistResolver {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [FixtureURLProtocol.self]
    return SpotifyTrackArtistResolver(session: URLSession(configuration: config))
}

private actor ProviderCalls {
    private var count = 0
    func record() { count += 1 }
    func value() -> Int { count }
}

private struct FixtureProvider: LyricsProvider {
    let name = "offline-artist-fixture"
    let executionLane: LyricsProviderExecutionLane = .local
    var artists = "Alice, Bob"
    var title = "Metadata Song (Remix)"
    var spotifyID: String?
    var calls = ProviderCalls()
    func lookup(track: Track, identity: TrackIdentity) async -> LyricsLookupResult {
        await calls.record()
        return .candidates([LyricsCandidate(
            id: "complete-artists", identity: identity, title: title,
            artist: artists, album: "Fixture Album", duration: 318.5,
            lines: [LyricLine(timestamp: 1, originalText: "A self-authored test line")],
            isSynchronized: true, source: .qqExperimental, confidence: 0.75, spotifyTrackID: spotifyID
        )])
    }
}

@main
@MainActor
struct SpotifyArtistEnrichmentContract {
    static func main() async {
        if CommandLine.arguments.contains("--live") {
            let live = Track(title: "百日草 - Remix", artist: "茉ひる", album: "百日草 - Remix", duration: 318.5,
                spotifyId: "spotify:track:5EgW6VV9LW6xtgJ1sFN5RU")
            let names = await SpotifyTrackArtistResolver.shared.artists(for: live)
            require(names == ["茉ひる", "李芷婷"], "official live metadata could not be verified")
            print("PASS live official exact-track metadata: 茉ひる, 李芷婷; duration 318.5; one metadata request, no lyrics/model requests")
            return
        }
        let track = Track(title: "Metadata Song - Remix", artist: "Alice", album: "Fixture Album",
            duration: 318.5, spotifyId: "5EgW6VV9LW6xtgJ1sFN5RU")
        FixtureURLProtocol.replies.reset(body: page())
        let source = FixtureProvider()
        let verified = resolver()
        let manager = LyricsSearchManager(providers: [source], spotifyArtistResolver: verified)
        let outcome = await manager.search(track: track, identity: TrackIdentity(track: track))
        guard case .match(let document) = outcome.result else {
            require(false, "a verified complete Spotify artist list did not allow automatic adoption"); return
        }
        require(document.identity == TrackIdentity(track: track) && document.lines.first?.timestamp == 1, "enrichment changed playback identity or timing")
        require(outcome.automaticDecision?.reasons.contains("spotifyArtistsVerified") == true, "automatic result lacks official evidence")
        require(outcome.alternatives.count == 1, "automatic adoption must retain the version switch candidate")
        require(await source.calls.value() == 1 && FixtureURLProtocol.replies.count == 1, "metadata re-evaluation must reuse the existing lyric result")
        _ = await manager.search(track: track, identity: TrackIdentity(track: track))
        require(FixtureURLProtocol.replies.count == 1, "successful metadata must be cached")
        print("PASS verified artists enable automatic selection; identity, timing, alternatives and successful cache preserved")

        for (label, body) in [
            ("wrong ID", page(id: "0000000000000000000000")),
            ("wrong URI", page(uri: "spotify:track:0000000000000000000000")),
            ("wrong title", page(title: "A different song")),
            ("wrong primary", page(artists: ["Mallory", "Bob"])),
            ("missing artists", page(artists: [])),
            ("malformed page", Data("<html>unavailable</html>".utf8))
        ] {
            FixtureURLProtocol.replies.reset(body: body)
            let invalid = resolver()
            require(await invalid.artists(for: track) == nil, "accepted \(label)")
            require(await invalid.artists(for: track) == nil && FixtureURLProtocol.replies.count == 1, "invalid metadata must not cause repeated polling: \(label)")
        }
        for error in [URLError(.timedOut), URLError(.notConnectedToInternet)] {
            FixtureURLProtocol.replies.reset(body: page(), error: error)
            let failed = resolver()
            let outcome = await LyricsSearchManager(providers: [FixtureProvider()], spotifyArtistResolver: failed).search(track: track, identity: TrackIdentity(track: track))
            guard case .candidates = outcome.result else { require(false, "failed enrichment must keep candidates"); return }
            require(await failed.artists(for: track) == nil && FixtureURLProtocol.replies.count == 1, "failure must be cached")
        }
        FixtureURLProtocol.replies.reset(body: page(), responseURL: URL(string: "https://example.test/track"))
        require(await resolver().artists(for: track) == nil, "redirected response must not attest Spotify identity")
        FixtureURLProtocol.replies.reset(body: page(), status: 429)
        require(await resolver().artists(for: track) == nil, "rate limit must not become metadata")
        print("PASS incorrect IDs, title, duration, primary artist, malformed/redirected responses, offline, timeout and rate-limit fail closed")

        FixtureURLProtocol.replies.reset(body: page())
        let shared = resolver()
        async let first = shared.artists(for: track)
        async let second = shared.artists(for: track)
        let joined = await (first, second)
        require(joined.0 == ["Alice", "Bob"] && joined.1 == ["Alice", "Bob"] && FixtureURLProtocol.replies.count == 1, "concurrent requests must share one metadata fetch")

        FixtureURLProtocol.replies.reset(body: page())
        let completeTrack = Track(title: track.title, artist: "Alice, Mallory", album: track.album, duration: track.duration, spotifyId: track.spotifyId)
        require(await resolver().artists(for: completeTrack) == nil, "official response must not silently discard already-known guest")
        for source in [FixtureProvider(artists: "Alice, Mallory"), FixtureProvider(title: "Metadata Song (Remix) - Live"), FixtureProvider(spotifyID: "different-recording")] {
            FixtureURLProtocol.replies.reset(body: page())
            let outcome = await LyricsSearchManager(providers: [source], spotifyArtistResolver: resolver()).search(track: track, identity: TrackIdentity(track: track))
            if case .match = outcome.result { require(false, "official enrichment bypassed wrong guest/recording/ID protection") }
        }
        FixtureURLProtocol.replies.reset(body: page())
        let manual = await LyricsSearchManager(providers: [FixtureProvider()], spotifyArtistResolver: resolver())
            .search(track: track, identity: TrackIdentity(track: track), queryOverride: "Metadata Song")
        if case .match = manual.result { require(false, "manual search must not auto-adopt") }
        require(FixtureURLProtocol.replies.count == 0, "manual search must not perform automatic enrichment")
        print("PASS request coalescing; existing guest, recording, ID and manual-selection barriers preserved")

        FixtureURLProtocol.replies.reset(body: page(), delay: 0.2)
        let delayed = resolver()
        let pending = Task {
            await LyricsSearchManager(providers: [FixtureProvider()], spotifyArtistResolver: delayed)
                .search(track: track, identity: TrackIdentity(track: track))
        }
        for _ in 0..<100 where FixtureURLProtocol.replies.count == 0 { try? await Task.sleep(nanoseconds: 5_000_000) }
        require(FixtureURLProtocol.replies.count == 1, "cancellation fixture never reached metadata lookup")
        pending.cancel()
        guard case .failed(.cancelled) = await pending.value.result else { require(false, "cancelled metadata lookup adopted lyrics"); return }

        for returnToA in [false, true] {
            FixtureURLProtocol.replies.reset(body: page(), delay: 0.2)
            let session = LyricsSessionController(providers: [FixtureProvider()], spotifyArtistResolver: resolver())
            session.begin(track: track, identity: TrackIdentity(track: track))
            for _ in 0..<100 where FixtureURLProtocol.replies.count == 0 { try? await Task.sleep(nanoseconds: 5_000_000) }
            require(FixtureURLProtocol.replies.count == 1, "track switch fixture never reached metadata lookup")
            let next = Track(title: "Other Song", artist: "Other Artist", album: "Other Album", duration: 200)
            session.begin(track: next, identity: TrackIdentity(track: next), automaticallySearch: false)
            if returnToA { session.begin(track: track, identity: TrackIdentity(track: track), automaticallySearch: false) }
            try? await Task.sleep(nanoseconds: 300_000_000)
            let expectedIdentity = TrackIdentity(track: returnToA ? track : next)
            require(session.activeIdentity == expectedIdentity && session.lyrics.isEmpty && session.availableCandidates.isEmpty
                && session.activeDocument == nil && !session.isSearchInProgress,
                "late official metadata contaminated a new track or a newer same-track session")
        }
        let localized = Track(title: "Evening Fixture", artist: "Fixture Artist", album: "", duration: 318.5,
            spotifyId: "5EgW6VV9LW6xtgJ1sFN5RU")
        FixtureURLProtocol.replies.reset(body: page(title: "夕景の試験", artists: ["試験作者"]))
        let localizedOutcome = await LyricsSearchManager(providers: [FixtureProvider(artists: "試験作者", title: "夕景の試験")], spotifyArtistResolver: resolver())
            .search(track: localized, identity: TrackIdentity(track: localized))
        guard case .match = localizedOutcome.result else { require(false, "exact official entity aliases did not resolve localized names"); return }
        require(localizedOutcome.automaticDecision?.reasons.contains("titleExact") == true,
            "localized automatic selection lacks official title evidence")
        require(FixtureURLProtocol.replies.count == 1, "localized matching should reuse one official metadata response")
        FixtureURLProtocol.replies.reset(body: page(title: "夕景の試験", duration: 500000, artists: ["試験作者"]))
        let wrongDuration = await LyricsSearchManager(providers: [FixtureProvider(artists: "試験作者", title: "夕景の試験")], spotifyArtistResolver: resolver())
            .search(track: localized, identity: TrackIdentity(track: localized))
        if case .match = wrongDuration.result { require(false, "unverified duration was accepted as a localized alias") }
        print("PASS localized official identity aliases; wrong duration still rejected")
        print("PASS cancellation, A-to-B and A-to-B-to-A block late metadata adoption")
    }
}
