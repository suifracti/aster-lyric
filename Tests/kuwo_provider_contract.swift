import Foundation

private final class KuwoFixtureProtocol: URLProtocol, @unchecked Sendable {
    static var rawBody: Data?
    static var failLyricID: String?
    static var search = ""
    static var lyric = ""
    static var status = 200
    static var error: URLError?
    static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        if let error = Self.error { client?.urlProtocol(self, didFailWithError: error); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: request.url!.query == "musicId=" + (Self.failLyricID ?? "") ? 503 : Self.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.rawBody ?? Data((request.url!.host == "search.kuwo.cn" ? Self.search : Self.lyric).utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct KuwoProviderContract {
    static func main() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [KuwoFixtureProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let provider = KuwoExperimentalLyricsProvider(session: session, timeout: 2)
        let track = Track(title: "Requested title", artist: "Requested artist", album: "Request album", duration: 250)
        let identity = TrackIdentity(track: track)
        let song = "{\"MUSICRID\":\"MUSIC_123\",\"SONGNAME\":\"Actual title\",\"ARTIST\":\"Actual artist\",\"ALBUM\":\"Actual album\",\"DURATION\":\"243\"}"
        func reset(search: String? = nil, lyric: String? = nil) {
            KuwoFixtureProtocol.search = search ?? "{\"abslist\":[\(song)]}"
            KuwoFixtureProtocol.lyric = lyric ?? "{\"data\":{\"lrclist\":[{\"time\":\"1.25\",\"lineLyric\":\"First\"},{\"time\":\"4.50\",\"lineLyric\":\"第二行\"}]}}"
            KuwoFixtureProtocol.rawBody = nil; KuwoFixtureProtocol.failLyricID = nil
            KuwoFixtureProtocol.status = 200; KuwoFixtureProtocol.error = nil; KuwoFixtureProtocol.requests = []
        }
        reset()
        guard case .candidates(let candidates) = await provider.lookup(track: track, identity: identity), let c = candidates.first else { fatalError("real lyrics candidates") }
        precondition(c.title == "Actual title" && c.artist == "Actual artist" && c.album == "Actual album" && c.duration == 243)
        precondition(c.providerSourceID == "kuwo:123" && c.spotifyTrackID == nil && c.isrc == nil)
        precondition(c.lines.map(\.timestamp) == [1.25, 4.5] && c.lines.map(\.originalText) == ["First", "第二行"] && c.isSynchronized)
        precondition(KuwoFixtureProtocol.requests.count == 2)
        precondition(KuwoFixtureProtocol.requests.last!.url!.query == "musicId=123")
        precondition(KuwoFixtureProtocol.requests.allSatisfy { $0.timeoutInterval == 2 })
        for bad in ["", "MUSIC_", "MUSIC_../1"] {
            reset(search: "{\"abslist\":[\(song.replacingOccurrences(of: "MUSIC_123", with: bad))]}")
            guard case .noMatch = await provider.lookup(track: track, identity: identity) else { fatalError("invalid ID") }
            precondition(KuwoFixtureProtocol.requests.count == 1)
        }
        for field in ["Actual title", "Actual artist", "243"] {
            reset(search: "{\"abslist\":[\(song.replacingOccurrences(of: field, with: ""))]}")
            guard case .noMatch = await provider.lookup(track: track, identity: identity) else { fatalError("missing metadata must not borrow query") }
        }
        reset(search: "{\"abslist\":[" + (1...8).map { song.replacingOccurrences(of: "123", with: String($0)) }.joined(separator: ",") + "]}")
        guard case .candidates(let limited) = await provider.lookup(track: track, identity: identity) else { fatalError("bounded bodies") }
        precondition(limited.count == 3 && KuwoFixtureProtocol.requests.count == 4)
        reset(search: "{\"abslist\":[" + song + "," + song.replacingOccurrences(of: "123", with: "456") + "]}")
        KuwoFixtureProtocol.failLyricID = "123"
        guard case .candidates(let partial) = await provider.lookup(track: track, identity: identity) else { fatalError("one failure must not discard another body") }
        precondition(partial.count == 1 && partial[0].providerSourceID == "kuwo:456")
        for time in ["NaN", "-1", "bad"] {
            reset(lyric: "{\"data\":{\"lrclist\":[{\"time\":\"\(time)\",\"lineLyric\":\"No fake zero\"}]}}")
            guard case .noMatch = await provider.lookup(track: track, identity: identity) else { fatalError("invalid times") }
        }
        // Captured from getlyric?musicId=528460531: HTTP 200, success, no lyric body.
        reset(lyric: "{\"code\":200,\"msg\":\"success\",\"data\":{},\"success\":true}")
        guard case .noMatch = await provider.lookup(track: track, identity: identity) else { fatalError("Kuwo's empty successful response is noMatch, not a parse failure") }
        reset(lyric: "{\"data\":{\"lrclist\":[]}}")
        guard case .noMatch = await provider.lookup(track: track, identity: identity) else { fatalError("empty lyric") }
        for code in [403, 429, 503] {
            reset(); KuwoFixtureProtocol.status = code
            guard case .failed = await provider.lookup(track: track, identity: identity) else { fatalError("HTTP failure") }
        }
        reset(); KuwoFixtureProtocol.error = URLError(.timedOut)
        guard case .failed(.timedOut) = await provider.lookup(track: track, identity: identity) else { fatalError("timeout") }
        reset(search: String(repeating: "x", count: 524289))
        guard case .failed(.parseFailure) = await provider.lookup(track: track, identity: identity) else { fatalError("body cap") }
        reset(search: "not JSON")
        guard case .failed(.parseFailure) = await provider.lookup(track: track, identity: identity) else { fatalError("malformed JSON") }
        reset(); KuwoFixtureProtocol.rawBody = Data([0xff, 0xfe, 0xfd])
        guard case .failed(.parseFailure) = await provider.lookup(track: track, identity: identity) else { fatalError("non UTF8") }
        reset()
        let cancelled = Task { () -> LyricsLookupResult in
            try? await Task.sleep(nanoseconds: 20_000_000)
            return await provider.lookup(track: track, identity: identity)
        }
        cancelled.cancel()
        guard case .failed(.cancelled) = await cancelled.value else { fatalError("cancellation") }
        precondition(KuwoFixtureProtocol.requests.isEmpty)
        print("PASS Kuwo real metadata/times, bounded fetches/body, invalid metadata/time, HTTP errors and timeout")
    }
}
