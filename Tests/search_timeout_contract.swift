import Foundation

// Only HTTP is substituted. The publisher catalog, search scheduling,
// cancellation and matching all execute their production implementations.
private final class DelayedPublisherResponse: URLProtocol {
    private static let lock = NSLock()
    private static var starts = 0
    static func reset() { lock.lock(); starts = 0; lock.unlock() }
    static func count() -> Int { lock.lock(); defer { lock.unlock() }; return starts }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "www.tunecore.co.jp"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.starts += 1; Self.lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.8) { [self] in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: ["Content-Type": "text/html"])!
            let html = #"<script id="__NEXT_DATA__" type="application/json">{"props":{"pageProps":{"artistList":[]}}}</script>"#
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(html.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

private struct PublisherWithShortDeadline: LyricsProvider {
    let provider: LinkCoreLyricsProvider
    let timeoutInterval: TimeInterval
    var name: String { provider.name }
    var executionLane: LyricsProviderExecutionLane { .network }
    func lookup(track: Track, identity: TrackIdentity) async -> LyricsLookupResult {
        await provider.lookup(track: track, identity: identity)
    }
}

private struct ReadySource: LyricsProvider {
    let name = "Ready fixture"
    let executionLane: LyricsProviderExecutionLane = .network
    func lookup(track: Track, identity: TrackIdentity) async -> LyricsLookupResult {
        do { try await Task.sleep(nanoseconds: 50_000_000) }
        catch { return .failed(.cancelled) }
        return .match(LyricsDocument(identity: identity, title: track.title,
            artist: track.artist, album: track.album, duration: track.duration,
            lines: [LyricLine(timestamp: 1, originalText: "Self-authored fixture")],
            source: .lrclib, providerSourceID: "ready-fixture"))
    }
}

@main struct SearchTimeoutContract {
    static func main() async {
        var failures = 0
        func expect(_ condition: Bool, _ message: String) {
            print("\(condition ? "PASS" : "FAIL") \(message)")
            if !condition { failures += 1 }
        }
        let track = Track(title: "Timeout fixture", artist: "Fixture artist", album: "Fixture", duration: 180)
        let identity = TrackIdentity(track: track)
        func publisher() -> LinkCoreLyricsProvider {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [DelayedPublisherResponse.self]
            return LinkCoreLyricsProvider(session: URLSession(configuration: config))
        }
        func awaitRequest() async {
            for _ in 0..<1000 {
                if DelayedPublisherResponse.count() > 0 { return }
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            fatalError("publisher fixture did not receive its request")
        }

        // A deadline must release the search even while a shared HTTP task is
        // still resolving. It must not become a cached no-match result.
        DelayedPublisherResponse.reset()
        let deadlineStart = Date()
        let timeout = await LyricsSearchManager(providers: [PublisherWithShortDeadline(
            provider: publisher(), timeoutInterval: 0.1)]).search(track: track, identity: identity)
        let deadlineElapsed = Date().timeIntervalSince(deadlineStart)
        expect(deadlineElapsed < 0.4, "deadline returns promptly: \(deadlineElapsed)s")
        if case .failed(.timedOut) = timeout.result { expect(true, "deadline remains a timeout") }
        else { expect(false, "deadline remains a timeout") }

        DelayedPublisherResponse.reset()
        let readyStart = Date()
        let ready = await LyricsSearchManager(providers: [ReadySource(), publisher()])
            .search(track: track, identity: identity)
        let readyElapsed = Date().timeIntervalSince(readyStart)
        expect(readyElapsed < 0.4, "ready lyrics do not wait for cancelled publisher: \(readyElapsed)s")
        if case .match(let document) = ready.result {
            expect(document.identity == identity && document.providerSourceID == "ready-fixture",
                "ready result keeps the selected recording")
        } else { expect(false, "ready result keeps the selected recording") }

        DelayedPublisherResponse.reset()
        let cancelledTask = Task {
            await LyricsSearchManager(providers: [publisher()]).search(track: track, identity: identity)
        }
        await awaitRequest()
        let cancelStart = Date()
        cancelledTask.cancel()
        let cancelled = await cancelledTask.value
        let cancelElapsed = Date().timeIntervalSince(cancelStart)
        expect(cancelElapsed < 0.4, "track cancellation returns promptly: \(cancelElapsed)s")
        if case .failed(.cancelled) = cancelled.result { expect(true, "cancelled search cannot adopt lyrics") }
        else { expect(false, "cancelled search cannot adopt lyrics") }

        // Cancelling one search must not cancel another consumer's shared
        // publisher request or cause a duplicate HTTP request.
        DelayedPublisherResponse.reset()
        let shared = publisher()
        let survivor = Task { await shared.lookup(track: track, identity: identity) }
        await awaitRequest()
        let first = await LyricsSearchManager(providers: [ReadySource(), shared])
            .search(track: track, identity: identity)
        if case .match = first.result { expect(true, "first search still selects ready lyrics") }
        else { expect(false, "first search still selects ready lyrics") }
        let survivingResult = await survivor.value
        if case .noMatch = survivingResult { expect(true, "other shared consumer completes normally") }
        else { expect(false, "other shared consumer completes normally") }
        expect(DelayedPublisherResponse.count() == 1, "shared publisher request remains deduplicated")

        // Let bounded test HTTP work drain; no windows, personal data or live network.
        try? await Task.sleep(nanoseconds: 850_000_000)
        print("SEARCH_TIMEOUT_FAILURES=\(failures)")
        if failures > 0 { exit(1) }
    }
}
