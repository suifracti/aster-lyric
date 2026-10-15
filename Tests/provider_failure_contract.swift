import Foundation

private final class StubLRCLIBSession: LRCLIBSession, @unchecked Sendable {
    struct Response {
        let data: Data
        let statusCode: Int
        let headers: [String: String]
        let error: Error?
        let delay: UInt64
    }

    private let responses: [Response]
    private(set) var requests: [URLRequest] = []
    private var index = 0

    init(responses: [Response]) {
        self.responses = responses
    }

    convenience init(data: Data, statusCode: Int = 200, headers: [String: String] = [:], delay: UInt64 = 0) {
        self.init(responses: [Response(data: data, statusCode: statusCode, headers: headers, error: nil, delay: delay)])
    }

    convenience init(error: Error, delay: UInt64 = 0) {
        self.init(responses: [Response(data: Data(), statusCode: 0, headers: [:], error: error, delay: delay)])
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let response: Response
        if index < responses.count {
            response = responses[index]
            index += 1
        } else {
            response = responses.last!
        }
        if response.delay > 0 {
            try await Task.sleep(nanoseconds: response.delay)
        }
        try Task.checkCancellation()
        if let error = response.error {
            throw error
        }
        let url = request.url ?? URL(string: "https://lrclib.net/api/get")!
        let http = HTTPURLResponse(
            url: url,
            statusCode: response.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: response.headers
        )!
        return (response.data, http)
    }
}

private struct FixedLyricsProvider: LyricsProvider {
    let name: String
    let result: LyricsLookupResult
    func lookup(track: Track, identity: TrackIdentity) async -> LyricsLookupResult { result }
}

private struct DelayedLyricsProvider: LyricsProvider {
    let name: String
    let delay: UInt64
    let result: LyricsLookupResult
    func lookup(track: Track, identity: TrackIdentity) async -> LyricsLookupResult {
        try? await Task.sleep(nanoseconds: delay)
        if Task.isCancelled { return .failed(.cancelled) }
        return result
    }
}

private struct CountingLyricsProvider: LyricsProvider {
    let name: String
    let result: LyricsLookupResult
    let counter: Counter
    func lookup(track: Track, identity: TrackIdentity) async -> LyricsLookupResult {
        counter.value += 1
        return result
    }
}

private final class Counter: @unchecked Sendable {
    var value = 0
}

@main
struct ProviderFailureContract {
    static func main() async {
        let track = Track(
            title: "LRCLIB Song",
            artist: "LRCLIB Artist",
            album: "LRCLIB Album",
            duration: 210
        )
        let identity = TrackIdentity(track: track)

        // 200 success with synced lyrics
        let okPayload = """
        {
          "id": 1,
          "trackName": "LRCLIB Song",
          "artistName": "LRCLIB Artist",
          "albumName": "LRCLIB Album",
          "duration": 210,
          "syncedLyrics": "[00:01.00]hello\\n[00:02.00]world"
        }
        """.data(using: .utf8)!
        let okSession = StubLRCLIBSession(data: okPayload, statusCode: 200)
        let okResult = await LRCLIBLyricsProvider(session: okSession, maxAutomaticRetries: 0)
            .lookup(track: track, identity: identity)
        guard case .match(let document) = okResult else {
            fatalError("expected 200 match, got \(okResult)")
        }
        precondition(document.identity == identity)
        precondition(document.isSynchronized)
        precondition(document.source == .lrclib)
        precondition(okSession.requests.first?.url?.absoluteString.contains("track_name=LRCLIB%20Song") == true)

        // Empty search records are not proof that the requested song has no vocals.
        for (label, title, artist, duration, instrumental) in [
            ("unrelated instrumental", "Other Song", "Other Artist", 210.0, true),
            ("different version", "LRCLIB Song (Instrumental)", "LRCLIB Artist", 210.0, true),
            ("different duration", "LRCLIB Song", "LRCLIB Artist", 300.0, true),
            ("empty vocal record", "LRCLIB Song", "LRCLIB Artist", 210.0, false)
        ] {
            let body = try! JSONSerialization.data(withJSONObject: ["id": 8, "trackName": title,
                "artistName": artist, "duration": duration, "instrumental": instrumental])
            let outcome = await LRCLIBLyricsProvider(session: StubLRCLIBSession(data: body), maxAutomaticRetries: 0)
                .lookup(track: track, identity: identity)
            guard case .noMatch = outcome else { fatalError("\(label) must not declare requested song lyric-free: \(outcome)") }
        }
        let instrumentalBody = try! JSONSerialization.data(withJSONObject: ["id": 9, "trackName": track.title,
            "artistName": track.artist, "duration": track.duration, "instrumental": true])
        let explicitNoLyrics = await LRCLIBLyricsProvider(session: StubLRCLIBSession(data: instrumentalBody), maxAutomaticRetries: 0)
            .lookup(track: track, identity: identity)
        guard case .noLyrics = explicitNoLyrics else { fatalError("exact instrumental metadata should retain noLyrics result") }
        print("PASS unrelated/empty instrumental records do not classify the requested recording")

        // 404 -> noMatch (via search empty)
        let notFoundSession = StubLRCLIBSession(responses: [
            .init(data: Data(), statusCode: 404, headers: [:], error: nil, delay: 0),
            .init(data: Data("[]".utf8), statusCode: 200, headers: [:], error: nil, delay: 0)
        ])
        let notFound = await LRCLIBLyricsProvider(session: notFoundSession, maxAutomaticRetries: 0)
            .lookup(track: track, identity: identity)
        guard case .noMatch = notFound else {
            fatalError("expected 404/noMatch, got \(notFound)")
        }

        // 400 bad request
        let badRequest = await LRCLIBLyricsProvider(
            session: StubLRCLIBSession(data: Data(), statusCode: 400),
            maxAutomaticRetries: 0
        ).lookup(track: track, identity: identity)
        guard case .failed(.serverError(400)) = badRequest else {
            fatalError("expected 400 failure, got \(badRequest)")
        }

        // timeout
        let timeout = await LRCLIBLyricsProvider(
            session: StubLRCLIBSession(error: URLError(.timedOut)),
            maxAutomaticRetries: 0
        ).lookup(track: track, identity: identity)
        guard case .failed(.timedOut) = timeout else {
            fatalError("expected timeout, got \(timeout)")
        }

        // network unavailable
        let network = await LRCLIBLyricsProvider(
            session: StubLRCLIBSession(error: URLError(.notConnectedToInternet)),
            maxAutomaticRetries: 0
        ).lookup(track: track, identity: identity)
        guard case .failed(.networkUnavailable) = network else {
            fatalError("expected network failure, got \(network)")
        }

        // 429 rate limited with limited automatic retry then failure
        let rateSession = StubLRCLIBSession(responses: [
            .init(data: Data(), statusCode: 429, headers: ["Retry-After": "0"], error: nil, delay: 0),
            .init(data: Data(), statusCode: 429, headers: ["Retry-After": "0"], error: nil, delay: 0)
        ])
        let rateLimited = await LRCLIBLyricsProvider(session: rateSession, maxAutomaticRetries: 1)
            .lookup(track: track, identity: identity)
        guard case .failed(.rateLimited) = rateLimited else {
            fatalError("expected rateLimited, got \(rateLimited)")
        }
        precondition(rateSession.requests.count == 2)

        // parse failure
        let parse = await LRCLIBLyricsProvider(
            session: StubLRCLIBSession(data: Data("not-json".utf8), statusCode: 200),
            maxAutomaticRetries: 0
        ).lookup(track: track, identity: identity)
        guard case .failed(.parseFailure) = parse else {
            fatalError("expected parse failure, got \(parse)")
        }

        // Automatic retry recovers once.
        let recoverSession = StubLRCLIBSession(responses: [
            .init(data: Data(), statusCode: 0, headers: [:], error: URLError(.timedOut), delay: 0),
            .init(data: okPayload, statusCode: 200, headers: [:], error: nil, delay: 0)
        ])
        let recovered = await LRCLIBLyricsProvider(session: recoverSession, maxAutomaticRetries: 1)
            .lookup(track: track, identity: identity)
        guard case .match = recovered else {
            fatalError("expected retry recovery, got \(recovered)")
        }
        precondition(recoverSession.requests.count == 2)

        // Fast identity switch cancels/suppresses stale lyrics.
        let slowDoc = LyricsDocument(
            identity: identity,
            title: track.title,
            artist: track.artist,
            album: track.album,
            duration: track.duration,
            lines: [LyricLine(timestamp: 1, originalText: "stale")],
            source: .lrclib
        )
        let trackB = Track(title: "Track B", artist: "Artist B", album: "Album", duration: 180)
        let identityB = TrackIdentity(track: trackB)
        let freshDoc = LyricsDocument(
            identity: identityB,
            title: trackB.title,
            artist: trackB.artist,
            album: trackB.album,
            duration: trackB.duration,
            lines: [LyricLine(timestamp: 1, originalText: "fresh")],
            source: .local
        )
        let controller = LyricsSessionController(
            provider: DelayedLyricsProvider(name: "slow", delay: 120_000_000, result: .match(slowDoc))
        )
        controller.begin(track: track, identity: identity)
        // Replace provider path by beginning a new identity quickly with a local match provider.
        let fastController = LyricsSessionController(
            provider: FixedLyricsProvider(name: "fast", result: .match(freshDoc))
        )
        fastController.begin(track: track, identity: identity)
        fastController.begin(track: trackB, identity: identityB)
        try? await Task.sleep(nanoseconds: 20_000_000)
        guard let loaded = fastController.state.document else {
            fatalError("expected fresh loaded state")
        }
        precondition(loaded.identity == identityB)
        precondition(loaded.lines.first?.originalText == "fresh")
        precondition(fastController.lyrics.first?.originalText == "fresh")

        // Partial provider failure must not hide a healthy local match.
        let localMatch = LyricsDocument(
            identity: identity,
            title: track.title,
            artist: track.artist,
            album: track.album,
            duration: track.duration,
            lines: [LyricLine(timestamp: 0, originalText: "local")],
            source: .local,
            confidence: 0.95
        )
        let localCounter = Counter()
        let remoteCounter = Counter()
        let manager = LyricsSearchManager(providers: [
            CountingLyricsProvider(name: "local", result: .match(localMatch), counter: localCounter),
            CountingLyricsProvider(name: "lrclib-fail", result: .failed(.networkUnavailable), counter: remoteCounter)
        ])
        let outcome = await manager.search(track: track, identity: identity)
        guard case .match(let matched) = outcome.result else {
            fatalError("local success must win despite remote failure")
        }
        precondition(matched.source == .local)
        precondition(localCounter.value == 1)
        // Local match short-circuits before remote; remote failure isolation still holds when local misses.
        let remoteOnly = LyricsSearchManager(providers: [
            FixedLyricsProvider(name: "local-miss", result: .noMatch),
            FixedLyricsProvider(name: "lrclib-fail", result: .failed(.timedOut)),
            FixedLyricsProvider(
                name: "local-second",
                result: .match(localMatch)
            )
        ])
        let isolated = await remoteOnly.search(track: track, identity: identity)
        guard case .match(let isolatedMatch) = isolated.result else {
            fatalError("later provider success must survive earlier failure, got \(isolated.result)")
        }
        precondition(isolatedMatch.source == .local)
        precondition(isolated.diagnostics.contains { diagnostic in
            if case .failed(.timedOut) = diagnostic.outcome { return true }
            return false
        })

        let conflicting = LyricsCandidate(id: "wrong-artist", identity: identity, title: track.title,
            artist: "Unrelated Singer", album: track.album, duration: track.duration,
            lines: [LyricLine(timestamp: 0, originalText: "Self-authored wrong-artist fixture")],
            source: .lrclib, confidence: 1)
        let unconfirmed = await LyricsSearchManager(providers: [
            FixedLyricsProvider(name: "wrong-artist", result: .candidates([conflicting])),
            FixedLyricsProvider(name: "limited-source", result: .failed(.rateLimited(1)))
        ]).search(track: track, identity: identity)
        guard case .failed(let identityFailure) = unconfirmed.result,
              case .identityUnconfirmed(let rejectedCount, let sourceError) = identityFailure else {
            fatalError("rejected identity must stay distinct from unavailable service")
        }
        precondition(rejectedCount > 0 && sourceError.contains("限流"))
        precondition(identityFailure.userFacingTitle == "歌词身份待确认")
        precondition(identityFailure.recoveryMessage.contains("未能确认") && identityFailure.recoveryMessage.contains("限流"))
        precondition(unconfirmed.alternatives.isEmpty && unconfirmed.automaticDecision == nil,
            "presentation repair must not expose or auto-adopt a hard-rejected wrong artist")
        let onlyLimited = await LyricsSearchManager(providers: [
            FixedLyricsProvider(name: "limited-source", result: .failed(.rateLimited(1)))
        ]).search(track: track, identity: identity)
        guard case .failed(let networkFailure) = onlyLimited.result, case .rateLimited = networkFailure else {
            fatalError("HTTP 429 must remain a real provider failure")
        }
        precondition(networkFailure.userFacingTitle == "歌词暂不可用" && networkFailure.recoveryMessage.contains("限流"))
        print("PASS identity confirmation has its own presentation; hard rejection and HTTP 429 remain unchanged")

        // Lyrics search requires confirmed identity and never writes files.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-failure-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("marker.txt")
        try! "keep".write(to: marker, atomically: true, encoding: .utf8)
        let before = try! Data(contentsOf: marker)
        _ = await LRCLIBLyricsProvider(session: okSession, maxAutomaticRetries: 0)
            .lookup(track: track, identity: identity)
        let after = try! Data(contentsOf: marker)
        precondition(before == after, "LRCLIB must not persist or mutate local files")

        print("provider failure contract passed")
    }
}
